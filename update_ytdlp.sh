#!/bin/bash
# Usage: update_ytdlp.sh [--if-stale]
# Updates yt-dlp, which stops working with YouTube every few weeks until updated.
# Exits 0 only if a newer version was installed, so a caller can retry a failed download.
#   --if-stale   only if the last check was over a week ago
#
# Updates the shortcut's own install (hearit_setup.sh) with uv, or a Homebrew yt-dlp
# with brew. Run in the background by hearit_setup.sh while Shazam listens, then by
# hearit.sh before a download (which waits here if that update is still running) and
# again after a failed one. Only one copy updates at once; others wait for it.
set -uo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

here="$(cd "$(dirname "$0")" && pwd)"
stamp="${YTDLP_STAMP:-$here/.ytdlp_checked}"
lock="${YTDLP_LOCK:-$here/.ytdlp_updating}"
if [[ -d "$here/.venv" ]]; then
  export PATH="$here/.venv/bin:$PATH"  # tools installed by hearit_setup.sh
fi

stale() { [[ ! -f "$stamp" || -n "$(find "$stamp" -mtime +6 2> /dev/null)" ]]; }

[[ "${1:-}" == --if-stale ]] && ! stale && exit 1

# ---- one copy at a time (a lock left by a crashed run is ignored) ----
waited=0
until mkdir "$lock" 2> /dev/null; do
  holder="$(cat "$lock/pid" 2> /dev/null)"
  # No pid yet: the holder has only just made the lock, unless it's a minute old.
  if [[ -n "$holder" ]] && ! kill -0 "$holder" 2> /dev/null \
     || [[ -z "$holder" && -n "$(find "$lock" -maxdepth 0 -mmin +1 2> /dev/null)" ]]; then
    rm -rf "$lock"
    continue
  fi
  [[ $waited -ge 300 ]] && exit 1
  sleep 1
  waited=$((waited + 1))
done
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT

# Waited for another copy that just checked: nothing more to do.
[[ "${1:-}" == --if-stale ]] && ! stale && exit 1
touch "$stamp"  # also when offline, so a weekly check doesn't repeat on every run

before="$(yt-dlp --version 2> /dev/null)"
if [[ -x "$here/tools/uv" && -x "$here/.venv/bin/python" ]]; then
  tools="$here/tools"
  # deno (yt-dlp's JavaScript runtime) is a large download: only in the weekly
  # background check, not while a failed song waits for a retry (yt-dlp alone takes seconds).
  pkgs=("yt-dlp[default]")
  [[ "${1:-}" == --if-stale ]] && pkgs+=(deno)
  UV_PYTHON_INSTALL_DIR="$tools/python" UV_CACHE_DIR="$tools/cache" UV_NO_CONFIG=1 UV_HTTP_TIMEOUT=30 \
    "$tools/uv" pip install -q --upgrade --python "$here/.venv/bin/python" "${pkgs[@]}" > /dev/null 2>&1
  rm -rf "$tools/cache"
elif [[ "$(command -v yt-dlp)" == /opt/homebrew/* || "$(command -v yt-dlp)" == /usr/local/* ]] && command -v brew > /dev/null; then
  HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 brew upgrade -q yt-dlp > /dev/null 2>&1
fi
after="$(yt-dlp --version 2> /dev/null)"

[[ -n "$after" && "$after" != "$before" ]] || exit 1
echo "Updated yt-dlp ${before:-?} → $after" >&2
