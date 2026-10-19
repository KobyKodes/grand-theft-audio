#!/bin/bash
# Usage: ytmusic.sh <youtube-url>
# Prints one line:
#   DOWNLOADED|<path>
#   EXISTS|<path>|<what happened>[|<music track name>|<changed 1/0>]
# Shows a floating progress window (ytprogress) while it works, or reuses the one
# in $HEARIT_HUD (see hearit_listen.sh).
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
export LANG=en_US.UTF-8
unset http_proxy https_proxy ALL_PROXY

url="$1"
dest="${YTMUSIC_DEST:-$HOME/Music/YoutubeDownloads}"
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/find_python.sh"
mkdir -p "$dest"

work="$(mktemp -d -t ytmusic)"
info="$work/info.json"
trap 'exec 3>&- 2>/dev/null; rm -rf "$work"' EXIT
trap '' PIPE  # if the window is closed early, keep going

# ---- progress window ----
# ytprogress is a universal binary for macOS 12+ (Intel and Apple Silicon).
if [[ -n "${HEARIT_HUD:-}" && -f "$HEARIT_HUD" && -z "${YTMUSIC_NO_HUD:-}" ]]; then
  # The Shortcut's orb window is already up (hearit_listen.sh): keep using it.
  exec 3>> "$HEARIT_HUD"
elif [[ -x "$here/ytprogress" && -z "${YTMUSIC_NO_HUD:-}" ]]; then
  mkfifo "$work/hud"
  "$here/ytprogress" < "$work/hud" > /dev/null 2>&1 &
  exec 3> "$work/hud"
else
  exec 3> /dev/null
fi
hud() { printf '%s\n' "$*" >&3 2>/dev/null || true; }

# Run a command but give up after N seconds (macOS has no `timeout`).
# Used for the Chrome-cookie retry, which waits for a one-time Keychain "Allow" click.
run_limited() {
  local secs=$1; shift
  "$@" & local pid=$!
  # The watcher must NOT inherit fd 3 (the progress window's pipe), or the window
  # stays open until its sleep ends. Its sleep is also killed explicitly below.
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) 3>&- > /dev/null 2>&1 & local watcher=$!
  local rc=0; wait "$pid" || rc=$?
  pkill -P "$watcher" 2>/dev/null || true
  kill "$watcher" 2>/dev/null || true
  return $rc
}

hud "STATUS Looking up video…"

# 1) Look the video up once. The saved info is reused for the download.
#    If YouTube asks "confirm you're not a bot", retry using your Chrome login cookies.
cookies=()
if ! yt-dlp --no-playlist --no-warnings -J "$url" > "$info" 2> "$work/lookup.err"; then
  if grep -qiE "not a bot|cookies|sign in" "$work/lookup.err"; then
    hud "STATUS Login check: click Always Allow if macOS asks…"
    cookies=(--cookies-from-browser chrome)
    if ! run_limited 90 yt-dlp --no-playlist --no-warnings "${cookies[@]}" -J "$url" > "$info" 2> "$work/lookup.err"; then
      cat "$work/lookup.err" >&2
      echo "YouTube bot check: allow Keychain access for Chrome cookies, or wait a few minutes and retry." >&2
      exit 1
    fi
  else
    tail -n 1 "$work/lookup.err" >&2
    exit 1
  fi
fi
hud "TITLE $("$py" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("title",""))' "$info")"

# 2) Already downloaded? Fill in missing cover or lyrics and stop.
hud "STATUS Checking your library…"
status="$("$py" "$here/tag_m4a.py" check "$info" "$dest")"
if [[ "$status" != NEW ]]; then
  hud "DONE Already downloaded"
  echo "$status"
  exit 0
fi

# 3) New song: download with live progress, then cover art, tags, lyrics.
hud "STATUS Starting download…"
yt-dlp --load-info-json "$info" ${cookies[@]+"${cookies[@]}"} --no-mtime --no-warnings --quiet \
  --progress --newline \
  --progress-template 'download:PROG %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s' \
  -f '140/bestaudio[ext=m4a]' \
  --embed-thumbnail --convert-thumbnails jpg \
  --ppa "ThumbnailsConvertor+ffmpeg_o:-c:v mjpeg -vf crop=\"'if(gt(ih,iw),iw,ih)':'if(gt(iw,ih),ih,iw)'\"" \
  -o "$dest/%(id)s.%(ext)s" \
  -O 'after_move:%(.{filepath,title,uploader,artist,track,duration,release_year,webpage_url})j' \
| while IFS= read -r line; do
    if [[ "$line" == PROG\ * ]]; then
      hud "$line"
      read -r _ got total _ _ _ <<< "$line"
      if [[ "$got" == "$total" ]]; then hud "STATUS Adding cover art…"; fi
    else
      hud "STATUS Adding tags and lyrics…"
      printf '%s\n' "$line"
    fi
  done \
| "$py" "$here/tag_m4a.py" tag

hud "DONE Added to your library"
