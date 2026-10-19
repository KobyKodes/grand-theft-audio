#!/bin/bash
# Usage: hearit.sh <artist> <title>     (a Shazam result)
# Finds the song on YouTube, downloads it with ytmusic.sh, then tags it with
# Shazam's exact names. Prints the same line format as ytmusic.sh:
#   DOWNLOADED|<path>
#   EXISTS|<path>|<what happened>[|<music track name>|<changed 1/0>]
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
export LANG=en_US.UTF-8

artist="$1"
title="$2"
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/find_python.sh"

download() {  # prints ytmusic.sh's result line
  local url
  url="$("$py" "$here/hearit.py" pick "$artist" "$title")" && "$here/ytmusic.sh" "$url"
}

# Keep yt-dlp current (weekly; waits if the shortcut's setup step is updating it now).
"$here/update_ytdlp.sh" --if-stale || true

if ! result="$(download)"; then
  # YouTube changes often break an older yt-dlp: if there's a newer one, try once more.
  [[ -n "${HEARIT_HUD:-}" ]] && printf 'STATUS Updating the YouTube downloader\n' >> "$HEARIT_HUD"
  "$here/update_ytdlp.sh" || exit 1
  result="$(download)"
fi

if [[ "$result" == DOWNLOADED\|* ]]; then
  # Tags and lyrics are in: play the success sound now, before the Shazam names
  # are written and the Music import. Alternates sounds/owned.wav / owned2.wav per download,
  # tracked in .owned_next. Glass is the fallback if the sound file is missing.
  if [[ "$(cat "$here/.owned_next" 2>/dev/null)" == 2 ]]; then
    sound="$here/sounds/owned2.wav"; echo 1 > "$here/.owned_next"
  else
    sound="$here/sounds/owned.wav"; echo 2 > "$here/.owned_next"
  fi
  (afplay "$sound" || afplay /System/Library/Sounds/Glass.aiff) < /dev/null > /dev/null 2>&1 &
  path="$("$py" "$here/hearit.py" retag "${result#DOWNLOADED|}" "$artist" "$title")"
  echo "DOWNLOADED|$path"
else
  echo "$result"
fi
