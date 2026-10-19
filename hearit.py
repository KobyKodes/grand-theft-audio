#!/usr/bin/env python3
"""Helper for hearit.sh (the "Grand Theft Audio" shortcut).

  hearit.py pick <artist> <title>
      Searches YouTube and prints the URL of the best upload of that song,
      favouring videos as long as the song is on iTunes (skips long intros, live
      and extended versions). With $HEARIT_HUD set, first puts the album cover on
      the window (COVER <file>).

  hearit.py retag <path> <artist> <title>
      Writes Shazam's exact artist/title into a fresh download, adds the album,
      album artist, track/disc number, release year and album cover
      (iTunes) if found and lyrics if missing, renames to "Artist - Title.m4a",
      prints the new path.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_m4a import fetch_artwork, fetch_length, fetch_release, fetch_lyrics, norm, safe_filename  # noqa: E402

from mutagen.mp4 import MP4, MP4Cover  # noqa: E402

YTDLP = shutil.which("yt-dlp", path="/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "")) or "yt-dlp"
UNWANTED = ["live", "cover", "remix", "karaoke", "slowed", "reverb", "8d", "sped up",
            "nightcore", "instrumental", "reaction", "tutorial", "lesson", "مباشر"]


# ---------- pick mode ----------

def score(entry: dict, artist: str, title: str, length=None) -> float:
    name = (entry.get("title") or "").casefold()
    channel = entry.get("channel") or entry.get("uploader") or ""
    n_name, n_artist, n_title, n_channel = norm(name), norm(artist), norm(title), norm(channel)
    s = 0.0
    if n_title and n_title in n_name:
        s += 4
    if n_artist and n_artist in n_name:
        s += 1
    if channel.endswith(" - Topic") and n_artist and n_artist in n_channel:
        s += 5  # YouTube's auto-generated "Artist - Topic" upload = album audio
    elif n_artist and n_channel and (n_artist in n_channel or n_channel in n_artist):
        s += 3
    elif "vevo" in n_channel:
        s += 2
    if "official audio" in name:
        s += 1.5
    wanted = title.casefold()
    for word in UNWANTED:
        if re.search(rf"\b{re.escape(word)}\b", name) and word not in wanted:
            s -= 4
    dur = entry.get("duration") or 0
    if dur and (dur < 60 or dur > 900):
        s -= 3
    if dur and length:
        off = abs(dur - length)
        s += 3 if off <= 3 else 1.5 if off <= 10 else 0 if off <= 30 else -3
    return s


def fetch_cover(artist: str, title: str, dest: str, done: list):
    """Saves the album cover (iTunes, 600px: it's for the window) to `dest`."""
    url = fetch_release(artist, title).get("artwork")
    data = fetch_artwork(url.replace("/1400x1400cc.", "/600x600cc.")) if url else None
    if data:
        with open(dest + ".tmp", "wb") as f:
            f.write(data)
        os.replace(dest + ".tmp", dest)  # whole or not at all, if the wait gives up on it
        done.append(dest)


def pick(artist: str, title: str):
    # In the shortcut, the album cover goes on the window's record before the download
    # starts. It's fetched alongside the search, in a daemon thread so a slow lookup is
    # dropped instead of holding up the download.
    hud = os.environ.get("HEARIT_HUD")
    cover, cover_thread = [], None
    if hud and os.path.exists(hud + ".cover.jpg"):  # a retry: already fetched
        cover.append(hud + ".cover.jpg")
    elif hud:
        cover_thread = threading.Thread(target=fetch_cover, args=(artist, title, hud + ".cover.jpg", cover),
                                        daemon=True)
        cover_thread.start()
    with ThreadPoolExecutor(1) as pool:
        length_future = pool.submit(fetch_length, artist, title)
        out = subprocess.run(
            [YTDLP, "--flat-playlist", "--no-warnings", "-J", f"ytsearch8:{artist} {title}"],
            capture_output=True, text=True,
        )
        length = length_future.result()
    if cover_thread:
        cover_thread.join(timeout=3)
    if cover:
        with open(hud, "a", encoding="utf-8") as f:
            f.write(f"COVER {cover[0]}\n")
    try:
        entries = [e for e in json.loads(out.stdout).get("entries") or [] if e.get("id")]
    except ValueError:
        entries = []
    if not entries:
        print(f"No YouTube match for {title}", file=sys.stderr)
        sys.exit(1)
    # YouTube's own ranking breaks ties.
    best = max(enumerate(entries), key=lambda ie: score(ie[1], artist, title, length) - ie[0] * 0.2)[1]
    print(f"picked: {best.get('title')} [{best.get('channel')}] {best.get('duration')}s"
          f" (song: {round(length) if length else '?'}s)", file=sys.stderr)
    print(f"https://www.youtube.com/watch?v={best['id']}")


# ---------- retag mode ----------

def retag(path: str, artist: str, title: str):
    audio = MP4(path)
    duration = int(audio.info.length)
    with ThreadPoolExecutor(2) as pool:
        release_future = pool.submit(fetch_release, artist, title, duration)
        lyrics_future = None
        if not (audio.tags or {}).get("\xa9lyr"):
            lyrics_future = pool.submit(fetch_lyrics, artist, title, duration)
        audio["\xa9nam"] = [title]
        audio["\xa9ART"] = [artist]
        release = release_future.result()
        album, year = release.get("album"), release.get("year")
        cover_future = pool.submit(fetch_artwork, release["artwork"]) if release.get("artwork") else None
        if album:
            audio["\xa9alb"] = [album]
        if year:
            audio["\xa9day"] = [year]
        if release.get("album_artist"):
            audio["aART"] = [release["album_artist"]]
        if release.get("compilation"):
            audio["cpil"] = True
        if release.get("track"):
            audio["trkn"] = [release["track"]]
        if release.get("disc"):
            audio["disk"] = [release["disc"]]
        cover = cover_future.result() if cover_future else None
        if cover:  # replaces the cropped YouTube thumbnail
            audio["covr"] = [MP4Cover(cover, imageformat=MP4Cover.FORMAT_JPEG)]
        lyrics = lyrics_future.result() if lyrics_future else None
        if lyrics:
            audio["\xa9lyr"] = [lyrics]
        audio.save()
    track = release.get("track")
    print(f"album: {album or 'none'}, track: {'%d/%d' % track if track else 'none'}, "
          f"year: {year or 'none'}, "
          f"cover: {'iTunes' if cover else 'YouTube'}", file=sys.stderr)

    final = os.path.join(os.path.dirname(path), safe_filename(f"{artist} - {title}") + ".m4a")
    if final != path and not os.path.exists(final):
        os.replace(path, final)
    else:
        final = path
    print(final)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "pick":
        pick(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 5 and sys.argv[1] == "retag":
        retag(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
