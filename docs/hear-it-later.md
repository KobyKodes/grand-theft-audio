# Hear it Later

Shazam a song on your iPhone. Your Mac downloads it into Music, in the playlist you
picked on the phone.

```
iPhone: Hear it Later ──► iCloud Drive/Shortcuts/HearIt/Queue/<time>.txt ──► Mac downloads it
                    └──► over SSH, when the Mac is on the same Wi-Fi ──────► right away
```

- The phone saves each song as a small text file (`Artist|Title|Playlist`) in iCloud
  Drive. A background agent on the Mac notices it and runs it through the same pipeline
  as **Hear it → Own it**. If the Mac is off or away, the song waits until it's back.
- On your home Wi-Fi the phone can also send the song straight to the Mac over SSH, so it
  starts downloading within seconds instead of waiting for iCloud to sync. The iCloud copy
  then gets skipped.
- The phone's playlist list is your Mac's recently used playlists, plus **New playlist…**.
- A song that fails 3 times moves to `HearIt/Failed` in iCloud Drive, and the Mac tells you.

## Requirements

- Everything from the main [README](../README.md#requirements)
- An iPhone signed in to the same iCloud account, with iCloud Drive on for both
- Homebrew tools on the Mac. The background agent runs the scripts from the cloned folder
  instead of the shortcut's own install:

  ```bash
  brew install yt-dlp ffmpeg
  pip3 install mutagen
  ```

## Set up

Do this in the cloned folder, and keep the folder where it is: the background agent runs
the scripts from there. If you move it, run the install again.

### 1. Install the Mac agent

```bash
bash install_hearit_queue.sh
```

This creates `~/Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/HearIt`
(**iCloud Drive → Shortcuts → HearIt**) and starts a LaunchAgent that runs at login and
whenever a song arrives. The first time a song comes in, macOS asks whether
**HearItQueue** may access iCloud Drive and control Music: click **Allow**.

### 2. Build and add the iPhone shortcut

```bash
python3 build_hearit_later.py
open "Hear it Later.shortcut"
```

Add it on the Mac. It syncs to your iPhone through iCloud. On the phone you can add it to
the Home Screen, the Action button, Control Center or Back Tap.

### 3. Optional: the Wi-Fi fast lane

Without this step everything still works through iCloud Drive, usually within a minute or so.

1. On the Mac: **System Settings → General → Sharing → Remote Login** on.
2. On the iPhone: open **Hear it Later** in Shortcuts, tap the **Run Script Over SSH**
   action, then **SSH Key → Share Public Key**, and send the key to your Mac (AirDrop or Notes).
3. On the Mac, add that one line to `~/.ssh/authorized_keys`:

   ```bash
   mkdir -p ~/.ssh && pbpaste >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
   ```

The shortcut is built for this Mac: it uses the Mac's local network name and your user
name. To use a different one, set `HEARIT_SSH_HOST` and/or `HEARIT_SSH_USER` before you
build it.

The first time you use the shortcut on a Wi-Fi network, it asks whether your Mac is on that
network too, and remembers the answer in `HearIt/wifi.txt`. To change an answer, edit that
file in the Files app.

## Use

Run **Hear it Later** on the iPhone, let Shazam hear the song, and pick a playlist. You get
**Downloading on your Mac** (Wi-Fi fast lane) or **Saved for your Mac** (iCloud). The song
shows up in Music on the Mac.

## Troubleshooting

- **Songs don't arrive.** Look at `.hearit_queue.log` in the cloned folder, and
  `~/Library/Logs/HearItQueue.log`. Check that the agent is loaded:
  `launchctl print gui/$(id -u)/com.kobykodes.hearitqueue`.
- **The phone can't find `HearIt/playlists.txt`.** Run `install_hearit_queue.sh` once on the
  Mac (it creates the folder), and give iCloud a moment to sync. If it still fails, open the
  shortcut on the phone, tap each **Get File** action and choose the **Shortcuts** folder in
  iCloud Drive again.
- **The SSH step fails.** Check that Remote Login is on, that the phone's key is in
  `~/.ssh/authorized_keys`, and that both devices are on the same Wi-Fi. The song is still
  saved to iCloud and downloads from there.
- **A song keeps failing.** It's in `HearIt/Failed`. Run it through **Hear it → Own it**
  instead, or download a specific upload with `./ytmusic.sh <url>`.

## Uninstall

```bash
bash install_hearit_queue.sh --uninstall
rm -rf ~/Library/Application\ Support/HearItQueue
```

Then delete the **Hear it Later** shortcut. Songs still waiting stay in
**iCloud Drive → Shortcuts → HearIt**: delete that folder if you don't need them.
