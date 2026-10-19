#!/bin/bash
# First step of the "Grand Theft Audio" shortcut (Run Shell Script, input to stdin).
# stdin: base64 tar.gz of the scripts, embedded in the shortcut by build_hearit_shortcut.py.
#
# - On the Mac these scripts were written on (~/Developer/Projects/Grand Theft Audio/hearit.sh
#   exists), uses those files and only recompiles the AppleScript if it changed.
# - Anywhere else, unpacks the scripts into ~/Library/Application Support/GrandTheftAudio
#   and, the first time, installs Python + yt-dlp + ffmpeg + deno there with uv.
#   No Homebrew, no Xcode tools, no password.
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

notify() { osascript -e "display notification \"$1\" with title \"Grand Theft Audio\"" >/dev/null 2>&1 || true; }

dev="$HOME/Developer/Projects/Grand Theft Audio"
if [[ -f "$dev/hearit.sh" ]]; then
  app="$dev"
  cat > /dev/null
else
  app="$HOME/Library/Application Support/GrandTheftAudio"
  mkdir -p "$app"
  bundle="$(mktemp -t hearit)"
  trap 'rm -f "$bundle"' EXIT
  base64 -D > "$bundle"
  version="$(shasum "$bundle" | cut -c1-12)"
  if [[ "$(cat "$app/.version" 2>/dev/null)" != "$version" ]]; then
    # The bundle ships HearItOwnIt.scpt already compiled. Remove any source left by an
    # older version, or the recompile check below would overwrite the new script with it.
    rm -f "$app/HearItOwnIt.applescript"
    tar -xzf "$bundle" -C "$app"
    xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
    echo "$version" > "$app/.version"
  fi
fi

if [[ "$app/HearItOwnIt.applescript" -nt "$app/HearItOwnIt.scpt" ]]; then
  osacompile -o "$app/HearItOwnIt.scpt" "$app/HearItOwnIt.applescript"
fi

# Tools already there? (find_python.sh exits non-zero if anything is missing)
if (here="$app"; source "$app/find_python.sh") 2>/dev/null; then
  # Once a week, update yt-dlp while Shazam listens (hearit.sh waits for it to finish).
  nohup "$app/update_ytdlp.sh" --if-stale < /dev/null > /dev/null 2>&1 &
  exit 0
fi

notify "First-time setup: downloading tools (about 250 MB). This takes a few minutes…"
case "$(uname -m)" in
  arm64) arch=aarch64 ;;
  *) arch=x86_64 ;;
esac
tools="$app/tools"
mkdir -p "$tools" "$app/bin"
export UV_PYTHON_INSTALL_DIR="$tools/python" UV_CACHE_DIR="$tools/cache" UV_NO_CONFIG=1

if [[ ! -x "$tools/uv" ]]; then
  curl -fsSL "https://github.com/astral-sh/uv/releases/latest/download/uv-$arch-apple-darwin.tar.gz" \
    | tar -xz -C "$tools" --strip-components 1
fi
"$tools/uv" venv -q --allow-existing --python 3.12 "$app/.venv"
"$tools/uv" pip install -q --upgrade --python "$app/.venv/bin/python" \
  mutagen "yt-dlp[default]" imageio-ffmpeg deno
ln -sf "$("$app/.venv/bin/python" -c 'import imageio_ffmpeg as i; print(i.get_ffmpeg_exe())')" "$app/bin/ffmpeg"
rm -rf "$tools/cache"
touch "$app/.ytdlp_checked"  # just installed: next yt-dlp update in a week (update_ytdlp.sh)

if ! (here="$app"; source "$app/find_python.sh"); then
  notify "Setup failed. Check your internet connection and run the shortcut again."
  exit 1
fi
notify "Setup done. Finding your song…"
