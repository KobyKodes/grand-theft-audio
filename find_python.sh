# Sourced by ytmusic.sh and hearit.sh. Sets $py to the first Python 3 that has
# mutagen installed (the shortcut's own install first, then pyenv, then Homebrew
# on Apple Silicon/Intel, then the system one), and checks that yt-dlp and ffmpeg
# are installed.
if [[ -d "$here/.venv" ]]; then
  export PATH="$here/.venv/bin:$here/bin:$PATH"  # tools installed by hearit_setup.sh
fi
py=""
for candidate in "$here/.venv/bin/python3" "$HOME/.pyenv/versions/3.11.0/bin/python3" /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  # Without Xcode's command line tools, /usr/bin/python3 pops up an install dialog.
  if [[ "$candidate" == /usr/bin/python3 ]] && ! xcode-select -p > /dev/null 2>&1; then
    continue
  fi
  if [[ -x "$candidate" ]] && "$candidate" -c "import mutagen" 2>/dev/null; then
    py="$candidate"
    break
  fi
done
if [[ -z "$py" ]]; then
  echo "Python with mutagen not found. Run: pip3 install mutagen" >&2
  exit 1
fi

for tool in yt-dlp ffmpeg; do
  if ! command -v "$tool" > /dev/null; then
    echo "$tool not found. Run: brew install $tool" >&2
    exit 1
  fi
done
