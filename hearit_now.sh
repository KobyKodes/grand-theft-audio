#!/bin/bash
# The fast lane for "Hear it Later": the iPhone shortcut runs this over SSH when
# your Mac is on the same Wi-Fi, so the song starts downloading right away instead
# of waiting for iCloud to sync the queue file.
#
# stdin, from the shortcut:
#   line 1: the queue file's name (yyyyMMdd-HHmmss.txt, same name the phone saved)
#   line 2: Artist|Title|Playlist
# The song goes into a local folder the LaunchAgent watches (install_hearit_queue.sh),
# so it downloads in your login session like any queued song. The iCloud copy of the
# same file is skipped when it arrives (hearit_queue.sh remembers the name).
set -euo pipefail

fast="${HEARIT_FAST_DIR:-$HOME/Library/Application Support/HearItQueue/Fast}"

IFS= read -r name || true
IFS= read -r line || true
name="${name%$'\r'}"
line="${line%$'\r'}"

if [[ ! "$name" =~ ^[0-9]{8}-[0-9]{6}\.txt$ || "$line" != *"|"* ]]; then
  echo "Hear it: bad input" >&2
  exit 2
fi

mkdir -p "$fast"
printf '%s\n' "$line" > "$fast/.$name.tmp"
mv "$fast/.$name.tmp" "$fast/$name"  # appears whole, so the watcher never sees half a file
echo "OK"
