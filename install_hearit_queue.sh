#!/bin/bash
# Installs the LaunchAgent that runs hearit_queue.sh at login and whenever the
# "Hear it Later" iPhone shortcut saves a song to iCloud Drive → Shortcuts → HearIt.
# Run again after moving this folder. `install_hearit_queue.sh --uninstall` removes it.
#
# The agent runs HearItQueue.app (a tiny background applet that runs hearit_queue.sh)
# rather than bash itself: macOS only lets background jobs into iCloud Drive with your
# OK, and this way you give it to "HearItQueue" once instead of to every bash script.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
label=com.kobykodes.hearitqueue
plist="$HOME/Library/LaunchAgents/$label.plist"
root="$HOME/Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/HearIt"
domain="gui/$(id -u)"
# launchd can't start programs or write logs in protected folders like Desktop, so the
# applet and launchd's log live in ~/Library. The applet itself may use this folder.
app="$HOME/Library/Application Support/HearItQueue/HearItQueue.app"
launchd_log="$HOME/Library/Logs/HearItQueue.log"
fast="$HOME/Library/Application Support/HearItQueue/Fast"  # songs sent over Wi-Fi (hearit_now.sh)

launchctl bootout "$domain/$label" 2> /dev/null || true
if [[ "${1:-}" == --uninstall ]]; then
  rm -f "$plist"
  echo "Removed. (Queued songs stay in iCloud Drive → Shortcuts → HearIt.)"
  exit 0
fi

mkdir -p "$root/Queue" "$root/Failed" "$fast" "$HOME/Library/LaunchAgents"
cp "$here/.recent_playlists" "$root/playlists.txt" 2> /dev/null || touch "$root/playlists.txt"

# Rebuilding the app makes macOS ask for permission again, so keep it unless the folder moved.
if [[ "$(cat "$app/Contents/Resources/queue_path" 2> /dev/null)" != "$here/hearit_queue.sh" ]]; then
  rm -rf "$app"
  mkdir -p "$(dirname "$app")"
  osacompile -o "$app" -e "do shell script \"/bin/bash \" & quoted form of \"$here/hearit_queue.sh\""
  plutil -replace LSUIElement -bool true "$app/Contents/Info.plist"         # no Dock icon
  plutil -replace CFBundleIdentifier -string "$label" "$app/Contents/Info.plist"
  echo "$here/hearit_queue.sh" > "$app/Contents/Resources/queue_path"
  codesign --force --sign - "$app"
fi

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$app/Contents/MacOS/applet</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>WatchPaths</key>
	<array>
		<string>$root/Queue</string>
		<string>$fast</string>
	</array>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>StandardOutPath</key>
	<string>$launchd_log</string>
	<key>StandardErrorPath</key>
	<string>$launchd_log</string>
</dict>
</plist>
EOF
plutil -lint -s "$plist"
launchctl bootstrap "$domain" "$plist"
echo "Installed. Songs saved on your iPhone now download here automatically."
echo "If macOS asks whether HearItQueue may access iCloud Drive or Music, click Allow."
