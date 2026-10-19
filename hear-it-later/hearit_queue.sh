#!/bin/bash
# Downloads the songs saved by the "Hear it Later" iPhone shortcut.
# The phone drops one file per song into iCloud Drive → Shortcuts → HearIt → Queue,
# holding one line: Artist|Title|Playlist (playlist empty or "No playlist" = none).
# Each song goes through HearItOwnIt.scpt, same as running Grand Theft Audio.
#
# Run by the LaunchAgent (install_hearit_queue.sh) at login and whenever the queue
# folder changes, and by Grand Theft Audio after each run. Only one copy works at once.
# A song that fails 3 times moves to HearIt/Failed.
#
# When the phone's Mac is on the same Wi-Fi, the shortcut also sends the song over SSH
# (hearit_now.sh), which drops it in $fast right away. Those go first, and the iCloud
# copy that arrives later under the same name is deleted unplayed (see $handled_file).
set -uo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export LANG=en_US.UTF-8

here="$(cd "$(dirname "$0")/.." && pwd)"  # the project folder (this script is in hear-it-later/)
root="${HEARIT_QUEUE_ROOT:-$HOME/Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/HearIt}"
state="${HEARIT_STATE_DIR:-$here}"
recents="${HEARIT_RECENTS:-$here/.recent_playlists}"
lock="${HEARIT_QUEUE_LOCK:-${TMPDIR:-/tmp}/hearit_queue.lock}"
queue="$root/Queue"
failed="$root/Failed"
fast="${HEARIT_FAST_DIR:-$HOME/Library/Application Support/HearItQueue/Fast}"
tries_file="$state/.hearit_queue_attempts"
handled_file="$state/.hearit_queue_handled"  # names already downloaded or given up on
log="$state/.hearit_queue.log"
max_tries=3
sync_wait="${HEARIT_SYNC_WAIT:-60}"  # seconds to wait for iCloud to fill in a new file

mkdir -p "$queue" "$failed" "$fast" "$state"

say() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$log"; }
notify() {
  [[ -n "${HEARIT_QUIET:-}" ]] && return
  osascript -e 'on run {t, m}' -e 'display notification m with title t' -e 'end run' "Hear it Later" "$1" > /dev/null 2>&1 || true
}

# ---- one copy at a time (a lock left by a crashed run is ignored) ----
take_lock() {
  if ! mkdir "$lock" 2> /dev/null; then
    if kill -0 "$(cat "$lock/pid" 2> /dev/null)" 2> /dev/null; then return 1; fi
    rm -rf "$lock"
    mkdir "$lock" 2> /dev/null || return 1
  fi
  echo $$ > "$lock/pid"
}
release_lock() {  # only our own: another copy may hold it by now
  [[ "$(cat "$lock/pid" 2> /dev/null)" == "$$" ]] && rm -rf "$lock"
  return 0
}
take_lock || exit 0
trap release_lock EXIT

# The phone picks from the playlists you used last on the Mac.
if [[ -f "$recents" ]] && ! cmp -s "$recents" "$root/playlists.txt"; then
  cp "$recents" "$root/playlists.txt"
fi

# Keep the compiled script current (same rule as hearit_setup.sh).
if [[ -z "${HEARIT_RUNNER:-}" && "$here/HearItOwnIt.applescript" -nt "$here/HearItOwnIt.scpt" ]]; then
  osacompile -o "$here/HearItOwnIt.scpt" "$here/HearItOwnIt.applescript"
fi

run_song() {  # run_song "Artist|Title" playlist → prints HearItOwnIt's result
  if [[ -n "${HEARIT_RUNNER:-}" ]]; then
    "$HEARIT_RUNNER" "$1" "$2"
  else
    osascript "$here/HearItOwnIt.scpt" "$1" "$here" "$2"
  fi
}

# iCloud creates a new file first and fills it in a moment later, so an empty
# file usually means "still syncing". Waits up to $sync_wait seconds for a line.
read_song() {  # read_song file → prints its first line (empty if it never arrived)
  local line="" waited=0
  while :; do
    brctl download "$1" > /dev/null 2>&1
    line="$(head -n 1 "$1" 2> /dev/null | tr -d '\r')"
    [[ -n "$line" || $waited -ge $((sync_wait * 2)) ]] && break
    sleep 0.5
    waited=$((waited + 1))
  done
  printf '%s' "$line"
}

tries_of() { awk -F'\t' -v f="$1" '$1 == f { n = $2 } END { print n + 0 }' "$tries_file" 2> /dev/null || echo 0; }
set_tries() {  # set_tries name count (0 = forget)
  { grep -v "^$1"$'\t' "$tries_file" 2> /dev/null; [[ $2 -gt 0 ]] && printf '%s\t%s\n' "$1" "$2"; } > "$tries_file.tmp"
  mv "$tries_file.tmp" "$tries_file"
}

handled() { grep -qxF "$1" "$handled_file" 2> /dev/null; }
mark_handled() {  # keeps the last 500 names
  { tail -n 499 "$handled_file" 2> /dev/null; printf '%s\n' "$1"; } > "$handled_file.tmp"
  mv "$handled_file.tmp" "$handled_file"
}
give_up() {  # give_up file label
  mv "$1" "$failed/"
  mark_handled "${1##*/}"
  failed_names+=("$2")
}

failed_names=()
tried=" "  # files handled this run, so a failing one isn't retried in a loop
pick_next() {  # sets $next to the next song file to try, or ""
  next=""
  local f
  for f in "$fast"/*.txt "$queue"/*.txt; do  # Wi-Fi songs first, then oldest first
    [[ -e "$f" ]] || continue
    if [[ "$f" == "$queue"/* ]] && handled "${f##*/}"; then
      rm -f "$f"  # already came in over Wi-Fi
      say "SKIP ${f##*/} (already handled over Wi-Fi)"
      continue
    fi
    [[ "$tried" != *" ${f##*/} "* ]] || continue
    next="$f"
    return
  done
}
while :; do
  # iCloud may still be downloading a song the phone just saved: ask for it now,
  # the folder change will start this script again when it arrives.
  for p in "$queue"/.*.icloud; do
    [[ -e "$p" ]] && brctl download "$p" > /dev/null 2>&1
  done

  pick_next
  if [[ -z "$next" ]]; then
    # Queue looks empty. A song sent right now would find the lock taken and its
    # run would quit, so let go of the lock first, then look once more.
    release_lock
    pick_next
    [[ -n "$next" ]] && take_lock || break
  fi
  name="${next##*/}"
  tried+="$name "

  line="$(read_song "$next")"
  if [[ -z "$line" ]]; then
    # Still empty: leave it for the next run (when it finishes syncing, the folder
    # changes and this script runs again). Give up only on a day-old empty file.
    if [[ -n "$(find "$next" -mmin +1440 2> /dev/null)" ]]; then
      say "EMPTY $name, giving up"
      give_up "$next" "$name"
    else
      say "WAIT $name (still syncing from iCloud)"
    fi
    continue
  fi
  artist="${line%%|*}"
  rest="${line#*|}"
  playlist=""
  if [[ "$rest" == *"|"* ]]; then
    playlist="${rest##*|}"
    rest="${rest%|*}"
  fi
  title="$rest"
  if [[ "$line" != *"|"* || -z "$artist" || -z "$title" ]]; then
    say "BAD $name: $line"
    give_up "$next" "$name"
    continue
  fi

  say "START $artist - $title (playlist: ${playlist:-none})"
  result="$(run_song "$artist|$title" "$playlist" 2>> "$log")"
  say "RESULT $result"
  if [[ "$result" == DOWNLOADED\|* || "$result" == EXISTS\|* ]]; then
    rm -f "$next"
    set_tries "$name" 0
    mark_handled "$name"
  else
    n=$(( $(tries_of "$name") + 1 ))
    if [[ $n -ge $max_tries ]]; then
      set_tries "$name" 0
      give_up "$next" "$title"
    else
      set_tries "$name" "$n"
    fi
  fi
done

# Each song already said "now you own it", so only failures get a summary.
if [[ ${#failed_names[@]} -gt 0 ]]; then
  notify "Gave up on ${#failed_names[@]} (see HearIt/Failed in iCloud Drive)."
fi
