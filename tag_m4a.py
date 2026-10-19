#!/usr/bin/env python3
"""Tagging helper for ytmusic.sh.

  tag_m4a.py check <info.json> <dest>
      Looks for an existing download of the same song. If none, prints NEW.
      If found, adds a missing cover, lyrics and/or genre and prints
      EXISTS|<path>|<what happened>

  tag_m4a.py tag  (yt-dlp after_move JSON on stdin)
      Cleans the title, writes title/artist/year/genre/lyrics in one save, renames,
      prints DOWNLOADED|<path>
"""
import difflib
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

from mutagen.mp4 import MP4, MP4Cover

JUNK_WORDS = r"official|music|video|audio|lyrics?|lyric video|visuali[sz]er|hd|hq|4k|remaster(ed)?|full song|clip officiel"
BRACKETS = re.compile(r"[\(\[【]([^\)\]】]*)[\)\]】]")
UA = {"User-Agent": "yt-music-dl/2.0 (personal use)"}
GENRE_CACHE = ".genre_cache.json"
FFMPEG = shutil.which("ffmpeg", path="/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "")) or "ffmpeg"


# ---------- names ----------

def clean_title(title: str) -> str:
    t = BRACKETS.sub("", title)                                   # "(Official Video)", "[4K]"
    t = re.sub(rf"\b({JUNK_WORDS})\b", "", t, flags=re.IGNORECASE)  # whole words only
    t = re.sub(r"\s*\|\s*.*$", "", t)                             # "Song | extras"
    t = re.sub(r"(\s*[-–—]\s*){2,}", " - ", t)                    # "a - - b"
    t = re.sub(r"\s{2,}", " ", t)
    t = re.sub(r"(\s*-\s*)+$", "", t)
    return t.strip(" -–—")


def split_artist_track(clean: str, info: dict):
    if info.get("artist") and info.get("track"):
        return info["artist"].split(",")[0].strip(), info["track"]
    parts = re.split(r"\s+[-–—]\s+", clean, maxsplit=1)
    if len(parts) == 2 and all(parts):
        return parts[0].strip(), parts[1].strip()
    uploader = re.sub(r"\s*-\s*Topic$|VEVO$", "", info.get("uploader") or "").strip()
    return uploader, clean


def safe_filename(name: str) -> str:
    return re.sub(r'[\\/:*?"<>|]', "", name).strip() or "untitled"


def norm(s: str) -> str:
    """Comparison key: lowercase letters and digits only (works for Arabic too)."""
    return re.sub(r"[\W_]+", "", (s or "").casefold())


def similar(a: str, b: str) -> float:
    """0-1 likeness of two norm()ed strings. Absorbs transliteration spelling
    differences, e.g. "Majida El Roumi" vs iTunes' "Magida El Roumi"."""
    return difflib.SequenceMatcher(None, a, b).ratio() if a and b else 0.0


# ---------- network ----------

def http_get(url: str, timeout=8) -> bytes:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def real_lyrics(entry):
    """Skip placeholder entries like "*Rickrolling*"."""
    text = (entry or {}).get("plainLyrics") or ""
    return text if len(text) > 80 and text.count("\n") >= 3 else None


def fetch_lyrics(artist: str, track: str, duration):
    try:
        q = {"artist_name": artist, "track_name": track}
        if duration:
            q["duration"] = int(duration)
        hit = real_lyrics(json.loads(http_get("https://lrclib.net/api/get?" + urllib.parse.urlencode(q))))
        if hit:
            return hit
    except Exception:
        pass
    try:
        results = json.loads(http_get("https://lrclib.net/api/search?" + urllib.parse.urlencode({"q": f"{artist} {track}"})))
        if duration:
            results.sort(key=lambda r: abs((r.get("duration") or 0) - duration))
        for r in results:
            if real_lyrics(r):
                return r["plainLyrics"]
    except Exception as e:
        print(f"lyrics lookup failed: {e}", file=sys.stderr)
    return None


def itunes_search(term: str, limit=10):
    q = urllib.parse.urlencode({"term": term, "entity": "song", "limit": limit})
    return json.loads(http_get("https://itunes.apple.com/search?" + q)).get("results", [])


def itunes_score(hit: dict, artist: str, track: str, duration) -> int:
    """How well an iTunes result matches what we downloaded."""
    score = 0
    have_artist, have_track = norm(hit.get("artistName")), norm(hit.get("trackName"))
    want_artist, want_track = norm(artist), norm(track)
    if want_track and have_track:
        if similar(want_track, have_track) >= 0.9:
            score += 4
        elif want_track in have_track or have_track in want_track or similar(want_track, have_track) >= 0.7:
            score += 2
    if want_artist and have_artist:
        if similar(want_artist, have_artist) >= 0.9:
            score += 3
        elif want_artist in have_artist or have_artist in want_artist or similar(want_artist, have_artist) >= 0.7:
            score += 1
    if duration and hit.get("trackTimeMillis"):
        off = abs(hit["trackTimeMillis"] / 1000 - duration)
        score += 2 if off <= 5 else (1 if off <= 15 else 0)
    return score


def artist_matches(hit: dict, artist: str) -> bool:
    have, want = norm(hit.get("artistName")), norm(artist)
    return bool(have and want) and (want in have or have in want or similar(want, have) >= 0.75)


def fetch_genre(artist: str, track: str, duration=None):
    """iTunes genre, so the value is one Music already uses. Coarse but reliable."""
    try:
        hits = itunes_search(f"{artist} {track}".strip())
        # Only trust a song hit by the same artist: an exact title match is just
        # as likely to be a tribute or karaoke album.
        mine = [h for h in hits if artist_matches(h, artist)] if norm(artist) else hits
        best, best_score = None, 0
        for hit in mine:
            s = itunes_score(hit, artist, track, duration)
            if s > best_score:
                best, best_score = hit, s
        if best_score >= 3 and best.get("primaryGenreName"):
            return best["primaryGenreName"]

        # No song by this artist: their catalogue is almost always one genre.
        if norm(artist):
            for hit in itunes_search(artist, limit=5):
                if similar(norm(hit.get("artistName")), norm(artist)) >= 0.8 and hit.get("primaryGenreName"):
                    return hit["primaryGenreName"]

        # Last resort, for titles our artist/track split got backwards: take the
        # genre only if the whole result page agrees on it.
        loose = max((itunes_score(h, artist, track, duration) for h in hits), default=0)
        if loose >= 2:
            genres = [h["primaryGenreName"] for h in hits if h.get("primaryGenreName")]
            if genres:
                top = max(set(genres), key=genres.count)
                if genres.count(top) / len(genres) >= 0.6:
                    return top
    except Exception as e:
        print(f"genre lookup failed: {e}", file=sys.stderr)
    return None


def fetch_release(artist: str, track: str, duration=None) -> dict:
    """Album details from iTunes, only for a confident match by the same artist ({} if
    none): album, album_artist, compilation, track and disc ((number, total) or None),
    year, artwork. Prefers the artist's own release over a "Various Artists"
    compilation. The year is the earliest confident match's, so a remaster or best-of
    doesn't win. "artwork" is the chosen album's cover URL, cropped square at 1400x1400.
    (No explicit flag: this API lists every song as clean, even explicit albums.)"""
    try:
        hits = [h for h in itunes_search(f"{artist} {track}".strip())
                if artist_matches(h, artist) and h.get("collectionName")]
        sure = [h for h in hits if itunes_score(h, artist, track, duration) >= 7]
        if not sure:
            return {}
        best = max(sure, key=lambda h: (itunes_score(h, artist, track, duration),
                                        norm(h.get("collectionArtistName")) != "variousartists"))
        years = [h["releaseDate"][:4] for h in sure if re.match(r"\d{4}", h.get("releaseDate") or "")]
        art = best.get("artworkUrl100") or ""
        album_artist = best.get("collectionArtistName") or best.get("artistName")
        return {"album": best["collectionName"], "year": min(years, default=None),
                "album_artist": album_artist,
                "compilation": norm(album_artist) == "variousartists",
                "track": (best["trackNumber"], best.get("trackCount") or 0) if best.get("trackNumber") else None,
                "disc": (best["discNumber"], best.get("discCount") or 0) if best.get("discNumber") else None,
                "artwork": re.sub(r"/\d+x\d+bb\.", "/1400x1400cc.", art) or None}
    except Exception as e:
        print(f"album lookup failed: {e}", file=sys.stderr)
    return {}


def fetch_length(artist: str, track: str):
    """The song's length in seconds per iTunes, or None. Takes the most popular
    confident match (iTunes' first), since that's usually the album version."""
    try:
        for hit in itunes_search(f"{artist} {track}".strip()):
            if (artist_matches(hit, artist) and hit.get("trackTimeMillis")
                    and itunes_score(hit, artist, track, None) >= 7):
                return hit["trackTimeMillis"] / 1000
    except Exception as e:
        print(f"length lookup failed: {e}", file=sys.stderr)
    return None


def fetch_artwork(url: str):
    """Album cover JPEG bytes, or None."""
    try:
        data = http_get(url, timeout=15)
        return data if data[:3] == b"\xff\xd8\xff" else None
    except Exception as e:
        print(f"artwork fetch failed: {e}", file=sys.stderr)
        return None


def genre_cached(artist: str, track: str, duration, dest: str):
    """fetch_genre with an on-disk cache, so backfills don't re-hit the API.
    Misses are cached as "" too; delete .genre_cache.json to retry them."""
    cache_file = os.path.join(dest, GENRE_CACHE)
    key = f"{norm(artist)}|{norm(track)}"
    cache = {}
    try:
        with open(cache_file, encoding="utf-8") as f:
            cache = json.load(f)
    except Exception:
        pass
    if key in cache:
        return cache[key] or None

    genre = fetch_genre(artist, track, duration)
    cache[key] = genre or ""
    try:
        tmp = cache_file + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cache, f, ensure_ascii=False, indent=0)
        os.replace(tmp, cache_file)
    except Exception as e:
        print(f"could not write genre cache: {e}", file=sys.stderr)
    return genre


def fetch_square_cover(info: dict):
    """Download the video thumbnail and center-crop it to a square JPEG."""
    url = info.get("thumbnail")
    if not url:
        return None
    try:
        raw = http_get(url, timeout=15)
        with tempfile.TemporaryDirectory() as tmp:
            src, out = os.path.join(tmp, "in"), os.path.join(tmp, "out.jpg")
            with open(src, "wb") as f:
                f.write(raw)
            subprocess.run(
                [FFMPEG, "-y", "-loglevel", "error", "-i", src,
                 "-vf", "crop='min(iw,ih)':'min(iw,ih)'", "-q:v", "2", out],
                check=True,
            )
            with open(out, "rb") as f:
                return f.read()
    except Exception as e:
        print(f"cover fetch failed: {e}", file=sys.stderr)
        return None


# ---------- check mode ----------

def find_existing(info: dict, dest: str):
    vid = info.get("id") or ""
    clean = clean_title(info.get("title") or "")
    artist, _ = split_artist_track(clean, info)
    want = norm(clean)
    title_match = None
    for path in glob.glob(os.path.join(dest, "*.m4a")):
        try:
            tags = MP4(path).tags or {}
        except Exception:
            continue
        comment = " ".join(tags.get("\xa9cmt", []))
        if vid and vid in comment:
            return path  # same YouTube video: certain match
        stem = os.path.splitext(os.path.basename(path))[0]
        if want and norm(clean_title(stem)) == want:
            # Same name but a different tagged artist means a different song.
            have_artist = norm((tags.get("\xa9ART") or [""])[0])
            if have_artist and norm(artist) and have_artist not in norm(clean) and norm(artist) not in have_artist:
                continue
            title_match = title_match or path
    return title_match


def check(info_path: str, dest: str):
    with open(info_path, encoding="utf-8") as f:
        info = json.load(f)
    path = find_existing(info, dest)
    if not path:
        print("NEW")
        return

    audio = MP4(path)
    tags = audio.tags or {}
    need_cover = not tags.get("covr")
    need_lyrics = not tags.get("\xa9lyr")
    need_genre = not tags.get("\xa9gen")

    if not need_cover and not need_lyrics and not need_genre:
        music_name = (tags.get("\xa9nam") or [os.path.splitext(os.path.basename(path))[0]])[0]
        print(f"EXISTS|{path}|Cover, lyrics and genre already there|{music_name}|0")
        return

    clean = clean_title(info.get("title") or "")
    artist, track = split_artist_track(clean, info)
    artist = (tags.get("\xa9ART") or [artist])[0]
    track = (tags.get("\xa9nam") or [track])[0]

    with ThreadPoolExecutor(3) as pool:
        cover_f = pool.submit(fetch_square_cover, info) if need_cover else None
        lyrics_f = pool.submit(fetch_lyrics, artist, track, info.get("duration")) if need_lyrics else None
        genre_f = pool.submit(genre_cached, artist, track, info.get("duration"), dest) if need_genre else None
        cover = cover_f.result() if cover_f else None
        lyrics = lyrics_f.result() if lyrics_f else None
        genre = genre_f.result() if genre_f else None

    notes = []
    if need_cover:
        if cover:
            audio["covr"] = [MP4Cover(cover, imageformat=MP4Cover.FORMAT_JPEG)]
            notes.append("added cover")
        else:
            notes.append("no cover found")
    if need_lyrics:
        if lyrics:
            audio["\xa9lyr"] = [lyrics]
            notes.append("added lyrics")
        else:
            notes.append("no lyrics found")
    if need_genre:
        if genre:
            audio["\xa9gen"] = [genre]
            notes.append(f"added genre {genre}")
        else:
            notes.append("no genre found")
    if not tags.get("\xa9cmt") and info.get("webpage_url"):
        audio["\xa9cmt"] = [info["webpage_url"]]  # lets future checks match by video ID
    if cover or lyrics or genre or not tags.get("\xa9cmt"):
        audio.save()

    # Music keeps its own copy under <dest>/Music/<Artist>/<Album>/. Update those too.
    music_name = (tags.get("\xa9nam") or [os.path.splitext(os.path.basename(path))[0]])[0]
    if cover or lyrics or genre:
        pattern = os.path.join(glob.escape(os.path.join(dest, "Music")), "**", glob.escape(os.path.basename(path)))
        for copy in glob.glob(pattern, recursive=True):
            try:
                c = MP4(copy)
                if cover and not (c.tags or {}).get("covr"):
                    c["covr"] = [MP4Cover(cover, imageformat=MP4Cover.FORMAT_JPEG)]
                if lyrics and not (c.tags or {}).get("\xa9lyr"):
                    c["\xa9lyr"] = [lyrics]
                if genre and not (c.tags or {}).get("\xa9gen"):
                    c["\xa9gen"] = [genre]
                c.save()
            except Exception as e:
                print(f"could not update library copy {copy}: {e}", file=sys.stderr)

    msg = ", ".join(notes)
    changed = "1" if (cover or lyrics or genre) else "0"
    print(f"EXISTS|{path}|{msg[0].upper() + msg[1:]}|{music_name}|{changed}")


# ---------- tag mode ----------

def tag():
    info = json.loads(sys.stdin.read().strip().splitlines()[-1])
    path = info["filepath"]
    clean = clean_title(info.get("title") or "")
    artist, track = split_artist_track(clean, info)

    with ThreadPoolExecutor(2) as pool:
        lyrics_future = pool.submit(fetch_lyrics, artist, track, info.get("duration"))
        genre_future = pool.submit(genre_cached, artist, track, info.get("duration"), os.path.dirname(path))
        audio = MP4(path)
        audio["\xa9nam"] = [track]
        audio["\xa9ART"] = [artist]
        audio["\xa9cmt"] = [info.get("webpage_url") or ""]
        if info.get("release_year"):
            audio["\xa9day"] = [str(info["release_year"])]  # hearit.py swaps in iTunes' year when it finds one
        lyrics = lyrics_future.result()
        if lyrics:
            audio["\xa9lyr"] = [lyrics]
        genre = genre_future.result()
        if genre:
            audio["\xa9gen"] = [genre]
        audio.save()

    final = os.path.join(os.path.dirname(path), safe_filename(clean) + ".m4a")
    if final != path:
        os.replace(path, final)
    print(("lyrics: yes" if lyrics else "lyrics: none") + f", genre: {genre or 'none'}", file=sys.stderr)
    print(f"DOWNLOADED|{final}")


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "check":
        check(sys.argv[2], sys.argv[3])
    else:
        tag()
