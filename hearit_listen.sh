#!/bin/bash
# Step of the "Grand Theft Audio" shortcut that runs right before Recognize Music
# (which runs hidden). Opens the orb window in its listening state.
#
# The window follows a file (ytprogress --watch), so each later step can add lines to
# it: HearItOwnIt.scpt, then ytmusic.sh through $HEARIT_HUD. The file's path goes in
# $dir/current for HearItOwnIt.scpt to pick up. The window closes itself on DONE or
# CLOSE, or after a minute with nothing new. This step never stops the shortcut.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

dev="$HOME/Developer/Projects/Grand Theft Audio"
if [[ -f "$dev/hearit.sh" ]]; then
  app="$dev"
  # Running from the source folder: if the window's source changed, rebuild it in the
  # background for the next run (this run keeps the binary it has, so listening isn't held up).
  if [[ "$app/ytprogress.swift" -nt "$app/ytprogress" ]] && xcrun --find swiftc > /dev/null 2>&1; then
    ( tmp="$(mktemp -t ytprogress)" &&
      xcrun swiftc -O "$app/ytprogress.swift" -o "$tmp" &&
      codesign -fs - "$tmp" &&
      mv -f "$tmp" "$app/ytprogress" ) < /dev/null > /dev/null 2>&1 &
  fi
else
  app="$HOME/Library/Application Support/HearItOwnItRedesign"
fi

dir="$HOME/Library/Caches/HearItOwnItRedesign"
mkdir -p "$dir"
rm -f "$dir/current"
find "$dir" -name 'hud.*' -mtime +1 -delete 2> /dev/null

# ytprogress is a universal binary for macOS 12+ (Intel and Apple Silicon).
if [[ ! -x "$app/ytprogress" ]]; then
  exit 0
fi

# The process running this Shortcut: a BackgroundShortcutRunner started for this run
# only. The window watches it, so stopping the Shortcut removes the window.
owner=()
pid=$PPID
while [[ "$pid" -gt 1 ]]; do
  if [[ "$(ps -o comm= -p "$pid")" == *BackgroundShortcutRunner ]]; then
    owner=(--while "$pid")
    break
  fi
  pid="$(ps -o ppid= -p "$pid" | tr -d ' ')"
done
# Not an ancestor (the step ran in a helper): the newest runner is this run's.
if [[ ${#owner[@]} -eq 0 ]]; then
  pid="$(pgrep -n -x BackgroundShortcutRunner)" && owner=(--while "$pid")
fi

hud="$(mktemp "$dir/hud.XXXXXX")" || exit 0
printf 'LISTEN Play the song near your Mac.\n' > "$hud"
# Detached, so it outlives this step.
nohup "$app/ytprogress" --watch "$hud" ${owner[@]+"${owner[@]}"} < /dev/null > /dev/null 2>&1 &
printf '%s\n' "$hud" > "$dir/current"
exit 0
