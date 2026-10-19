#!/usr/bin/env python3
"""Adds what Hear it → Own it now tags new downloads with to the songs you already
have: album, album artist, track and disc number, year, compilation flag and the
iTunes album cover.

  backfill_tags.py [folder]            preview: lists what would change, writes nothing
  backfill_tags.py [folder] --apply    writes the tags, then has Music re-read them
  backfill_tags.py [folder] --undo     puts back what the last --apply changed

folder defaults to ~/Music/YoutubeDownloads (its songs and Music's copies under
Music/). Only fills in missing tags: nothing you already have is overwritten,
except covers under 1000px wide (the cropped YouTube thumbnail), which get replaced.
If a song already has a different album, only the year is added, since the track
number and cover would belong to the other album.

iTunes allows about 20 lookups a minute, so the first run takes roughly 3 seconds a
song. Lookups are saved in <folder>/.release_cache.json, so --apply after a preview
(or a second run) doesn't repeat them.
"""
import glob
import json
import os
import subprocess
import sys
import time
import urllib.error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tag_m4a  # noqa: E402
from tag_m4a import clean_title, fetch_artwork, fetch_release, norm  # noqa: E402

from mutagen.mp4 import MP4, MP4Cover  # noqa: E402

CACHE = ".release_cache.json"
UNDO = ".backfill_undo.json"
BACKUP = ".backfill_covers"
MIN_COVER = 1000
GAP = 3.1  # seconds between iTunes lookups

# ---------- iTunes, politely ----------

_search = tag_m4a.itunes_search
_last = [0.0]
lookup_failed = [False]


def paced_search(term, limit=10):
    """tag_m4a.itunes_search, spaced out and retried when iTunes says slow down.
    fetch_release swallows errors, so a lookup that never got through is flagged
    here and left out of the cache."""
    for attempt in range(5):
        wait = _last[0] + GAP - time.time()
        if wait > 0:
            time.sleep(wait)
        _last[0] = time.time()
        try:
            return _search(term, limit)
        except urllib.error.HTTPError as e:
            if e.code not in (403, 429, 503):
                raise
            print(f"   iTunes asked to slow down, waiting a minute… ({attempt + 1}/5)", file=sys.stderr)
            time.sleep(60)
    lookup_failed[0] = True
    raise RuntimeError("iTunes kept refusing lookups")


tag_m4a.itunes_search = paced_search

# ---------- helpers ----------


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def image_width(data: bytes) -> int:
    """Width of a JPEG or PNG, 0 if unknown."""
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return int.from_bytes(data[16:20], "big")
    i = 2
    while i < len(data) - 9:
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xC0, 0xC1, 0xC2):
            return int.from_bytes(data[i + 7:i + 9], "big")
        i += 2 + int.from_bytes(data[i + 2:i + 4], "big")
    return 0


def artist_and_title(path, tags):
    """From the tags, else from an "Artist - Title" file name. None if unsure."""
    artist = (tags.get("\xa9ART") or [""])[0].strip()
    title = (tags.get("\xa9nam") or [""])[0].strip()
    if artist and title:
        return artist, title
    stem = clean_title(os.path.splitext(os.path.basename(path))[0])
    if " - " in stem:
        a, t = (p.strip() for p in stem.split(" - ", 1))
        if a and t:
            return artist or a, title or t
    return None


def songs(folder):
    files = glob.glob(os.path.join(glob.escape(folder), "*.m4a"))
    files += glob.glob(os.path.join(glob.escape(folder), "Music", "**", "*.m4a"), recursive=True)
    return sorted(files)


# ---------- plan ----------


def plan_for(tags, release):
    """{atom: new value} for one song. Covers are planned as the URL."""
    changes = {}
    have_album = (tags.get("\xa9alb") or [""])[0]
    same_album = not have_album or norm(have_album) == norm(release.get("album"))
    if release.get("year") and not tags.get("\xa9day"):
        changes["\xa9day"] = release["year"]
    if not same_album:
        return changes
    if not have_album and release.get("album"):
        changes["\xa9alb"] = release["album"]
    if release.get("album_artist") and not tags.get("aART"):
        changes["aART"] = release["album_artist"]
    if release.get("compilation") and not tags.get("cpil"):
        changes["cpil"] = True
    if release.get("track") and not tags.get("trkn"):
        changes["trkn"] = tuple(release["track"])
    if release.get("disc") and not tags.get("disk"):
        changes["disk"] = tuple(release["disc"])
    if release.get("artwork"):
        covers = tags.get("covr") or []
        if not covers or image_width(bytes(covers[0])) < MIN_COVER:
            changes["covr"] = release["artwork"]
    return changes


LABELS = {"\xa9day": "year", "\xa9alb": "album", "aART": "album artist", "cpil": "compilation",
          "trkn": "track", "disk": "disc", "covr": "cover"}


def describe(changes):
    out = []
    for k, v in changes.items():
        if k in ("trkn", "disk"):
            out.append(f"{LABELS[k]} {v[0]}/{v[1]}" if v[1] else f"{LABELS[k]} {v[0]}")
        elif k == "covr":
            out.append("cover")
        elif k == "cpil":
            out.append("compilation")
        else:
            out.append(f"{LABELS[k]} {v}")
    return ", ".join(out)


# ---------- write / undo ----------


def write(path, changes, undo, backup_dir, artwork_cache):
    audio = MP4(path)
    tags = audio.tags
    before = {}
    for k, v in changes.items():
        if k == "covr":
            if v not in artwork_cache:
                artwork_cache[v] = fetch_artwork(v)
            cover = artwork_cache[v]
            if not cover:
                continue
            old = tags.get("covr")
            if old:
                os.makedirs(backup_dir, exist_ok=True)
                saved = os.path.join(backup_dir, f"{len(undo)}_{os.path.basename(path)}.img")
                with open(saved, "wb") as f:
                    f.write(bytes(old[0]))
                before["covr"] = saved
            else:
                before["covr"] = None
            tags["covr"] = [MP4Cover(cover, imageformat=MP4Cover.FORMAT_JPEG)]
        else:
            before[k] = None  # only missing tags are ever filled in
            tags[k] = [v] if k != "cpil" else v
    if before:
        audio.save()
        undo.append({"path": path, "before": before})
    return bool(before)


def undo_all(folder):
    undo_file = os.path.join(folder, UNDO)
    entries = load_json(undo_file, [])
    if not entries:
        print("Nothing to undo.")
        return []
    done = []
    for entry in reversed(entries):
        path = entry["path"]
        try:
            audio = MP4(path)
        except Exception as e:
            print(f"skipped {path}: {e}")
            continue
        for k, old in entry["before"].items():
            if k == "covr" and old:
                with open(old, "rb") as f:
                    data = f.read()
                fmt = MP4Cover.FORMAT_PNG if data[:4] == b"\x89PNG" else MP4Cover.FORMAT_JPEG
                audio.tags["covr"] = [MP4Cover(data, imageformat=fmt)]
            else:
                audio.tags.pop(k, None)
        audio.save()
        done.append(path)
    os.replace(undo_file, undo_file + ".undone")
    print(f"Restored {len(done)} songs.")
    return done


# ---------- Music ----------

REFRESH = """
on run argv
	set wanted to paragraphs of (item 1 of argv)
	set n to 0
	tell application "Music"
		set theTracks to every file track of library playlist 1
		set locs to location of every file track of library playlist 1 -- one request, not one per track
		repeat with i from 1 to count of locs
			try
				if (POSIX path of (item i of locs)) is in wanted then
					refresh (item i of theTracks)
					set n to n + 1
				end if
			end try
		end repeat
	end tell
	return n
end run
"""


def refresh_music(paths):
    """Music caches tags, so ask it to re-read the changed files."""
    if not paths:
        return
    print("Asking Music to re-read the changed songs…")
    r = subprocess.run(["osascript", "-e", REFRESH, "\n".join(paths)], capture_output=True, text=True)
    if r.returncode == 0:
        print(f"Music updated {r.stdout.strip()} tracks.")
    else:
        print(f"Couldn't refresh Music ({r.stderr.strip()}). Select the songs in Music and use "
              "File → Library → Update Tags… or just play them.")


# ---------- main ----------


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    if flags - {"--apply", "--undo"} or len(args) > 1:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    folder = os.path.abspath(os.path.expanduser(args[0] if args else "~/Music/YoutubeDownloads"))
    if "--undo" in flags:
        refresh_music(undo_all(folder))
        return
    apply = "--apply" in flags

    cache_file = os.path.join(folder, CACHE)
    cache = load_json(cache_file, {})
    undo_file = os.path.join(folder, UNDO)
    undo = load_json(undo_file, []) if apply else []
    backup_dir = os.path.join(folder, BACKUP)
    artwork_cache = {}
    files = songs(folder)
    counts = {"changed": 0, "done": 0, "nomatch": 0, "unsure": 0, "unreadable": 0}
    changed_paths = []
    print(f"{'Tagging' if apply else 'Preview of'} {len(files)} songs in {folder}"
          f"{'' if apply else ' (nothing is written; add --apply to write)'}\n")

    for i, path in enumerate(files, 1):
        name = os.path.relpath(path, folder)
        try:
            audio = MP4(path)
        except Exception:
            counts["unreadable"] += 1
            continue
        tags = audio.tags or {}
        who = artist_and_title(path, tags)
        if not who:
            counts["unsure"] += 1
            print(f"[{i}/{len(files)}] ? {name}: no artist in the tags or file name, skipped")
            continue
        artist, title = who
        duration = int(audio.info.length)
        key = f"{norm(artist)}|{norm(title)}|{duration // 10}"
        if key not in cache:
            lookup_failed[0] = False
            release = fetch_release(artist, title, duration)
            if lookup_failed[0]:
                print(f"[{i}/{len(files)}] ! {name}: iTunes unavailable, try again later")
                continue
            cache[key] = release
            save_json(cache_file, cache)
        release = cache[key]
        if not release:
            counts["nomatch"] += 1
            print(f"[{i}/{len(files)}] - {name}: no confident iTunes match")
            continue
        changes = plan_for(tags, release)
        if not changes:
            counts["done"] += 1
            continue
        if apply:
            if write(path, changes, undo, backup_dir, artwork_cache):
                save_json(undo_file, undo)
                changed_paths.append(path)
                counts["changed"] += 1
        else:
            counts["changed"] += 1
        print(f"[{i}/{len(files)}] + {name}: {describe(changes)}")

    print(f"\n{'Updated' if apply else 'Would update'} {counts['changed']} songs. "
          f"Already complete: {counts['done']}. No confident match: {counts['nomatch']}. "
          f"No artist to look up: {counts['unsure']}."
          + (f" Unreadable: {counts['unreadable']}." if counts["unreadable"] else ""))
    if apply:
        refresh_music(changed_paths)
        if changed_paths:
            print(f"To put everything back: {os.path.basename(__file__)} --undo")


if __name__ == "__main__":
    main()
