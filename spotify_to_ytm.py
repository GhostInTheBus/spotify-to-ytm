#!/usr/bin/env python3
"""
Spotify -> YouTube Music Auto-Converter (macOS Clipboard Daemon)
Watches the macOS clipboard for Spotify links (open.spotify.com or spotify.link),
resolves the track/album/artist metadata, finds the exact match on YouTube Music,
replaces the clipboard with the music.youtube.com link, and displays a notification.
"""

import html
import json
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

SPOTIFY_REGEX = re.compile(
    r"^https?://(?:open\.spotify\.com/(?:intl-[a-zA-Z-]+/)?(?P<type>track|album|artist|playlist)/(?P<id>[a-zA-Z0-9]+)|spotify\.link/[a-zA-Z0-9]+)(?:\?[^\s]*)?$"
)

YOUTUBE_REGEX = re.compile(
    r"https?://(?:(?:www\.|m\.|music\.)?youtube\.com/(?:watch\?\S*v=[A-Za-z0-9_-]{11}|shorts/[A-Za-z0-9_-]{11}|playlist\?\S*list=[A-Za-z0-9_-]+)|youtu\.be/[A-Za-z0-9_-]{11})\S*"
)

USER_AGENT = "Mozilla/5.0"


def get_clipboard() -> str:
    try:
        res = subprocess.run(
            ["pbpaste"], capture_output=True, text=True, timeout=2
        )
        return res.stdout.strip()
    except Exception:
        return ""


def set_clipboard(text: str) -> None:
    try:
        subprocess.run(
            ["pbcopy"], input=text, text=True, timeout=2, check=True
        )
    except Exception as e:
        print(f"Error setting clipboard: {e}", file=sys.stderr)


def notify(title: str, subtitle: str, message: str) -> None:
    script = 'on run argv\ndisplay notification (item 3 of argv) with title (item 1 of argv) subtitle (item 2 of argv) sound name "Pop"\nend run'
    try:
        subprocess.run(["osascript", "-e", script, title, subtitle, message], timeout=5)
    except Exception as e:
        print(f"Notification error: {e}", file=sys.stderr)


def fetch_spotify_info(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=8) as resp:
        final_url = resp.geturl()
        body = resp.read().decode("utf-8", errors="ignore")

    m_type = "track"
    m_match = re.search(
        r"open\.spotify\.com/(?:intl-[a-zA-Z-]+/)?(track|album|artist|playlist)/",
        final_url,
    )
    if m_match:
        m_type = m_match.group(1)

    og_title = re.search(r'<meta property="og:title" content="([^"]+)"', body)
    og_desc = re.search(r'<meta property="og:description" content="([^"]+)"', body)
    musician = re.search(
        r'<meta name="music:musician_description" content="([^"]+)"', body
    )

    title = html.unescape(og_title.group(1)).strip() if og_title else ""
    desc = html.unescape(og_desc.group(1)).strip() if og_desc else ""
    artist = html.unescape(musician.group(1)).strip() if musician else ""

    # Clean up Spotify's "Listen to X by Y | Spotify" format on some album pages
    title = re.sub(r"^Listen to\s+", "", title)
    title = re.sub(r"\s*\|\s*Spotify$", "", title)

    if not artist and "·" in desc:
        first_part = desc.split("·")[0].strip()
        if first_part.lower() not in ("artist", "playlist", "song"):
            artist = first_part

    return {
        "type": m_type,
        "title": title,
        "artist": artist,
        "final_url": final_url,
    }


def search_ytm(query: str, item_type: str) -> str:
    api_url = "https://music.youtube.com/youtubei/v1/search?prettyPrint=false"
    payload = {
        "context": {
            "client": {
                "clientName": "WEB_REMIX",
                "clientVersion": "1.20240101.01.00",
            }
        },
        "query": query,
    }
    if item_type == "track":
        # Filter specifically to Songs in YouTube Music
        payload["params"] = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"

    req = urllib.request.Request(
        api_url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
    )
    with urllib.request.urlopen(req, timeout=8) as resp:
        data = resp.read().decode("utf-8", errors="ignore")

    if item_type == "track":
        video_ids = re.findall(r'"videoId":"([a-zA-Z0-9_-]{11})"', data)
        if video_ids:
            return f"https://music.youtube.com/watch?v={video_ids[0]}"
    elif item_type == "album":
        browse_ids = re.findall(r'"browseId":"(MPREb_[a-zA-Z0-9_-]+)"', data)
        if browse_ids:
            return f"https://music.youtube.com/browse/{browse_ids[0]}"
    elif item_type == "artist":
        browse_ids = re.findall(r'"browseId":"(UC[a-zA-Z0-9_-]+)"', data)
        if browse_ids:
            return f"https://music.youtube.com/channel/{browse_ids[0]}"

    # Fallback to direct YouTube Music search URL
    return f"https://music.youtube.com/search?q={urllib.parse.quote_plus(query)}"


def convert_spotify_url(url: str) -> tuple[str, str, str]:
    info = fetch_spotify_info(url)
    title = info["title"]
    artist = info["artist"]
    item_type = info["type"]

    if not title:
        raise ValueError("Could not extract title from Spotify URL")

    if artist and artist.lower() not in title.lower():
        query = f"{title} {artist}"
        display_sub = f"{title} — {artist}"
    else:
        query = title
        display_sub = title

    ytm_url = search_ytm(query, item_type)
    return ytm_url, display_sub, item_type


def song_query(title: str, author: str) -> str:
    """Turns a YouTube title and channel into 'song artist' for a Spotify search."""
    t = re.sub(
        r"\s*[\(\[][^\)\]]*(official|video|audio|lyric|visuali[sz]er|hd|4k|remaster(ed)?|mv)[^\)\]]*[\)\]]",
        "", title, flags=re.I,
    )
    t = re.sub(r"\s*\|.*$", "", t).strip()
    a = re.sub(r"\s*-\s*Topic$", "", author)
    a = re.sub(r"VEVO$", "", a, flags=re.I)
    a = re.sub(r"\s*(Official)?\s*$", "", a, flags=re.I).strip()
    if " - " in t or not a or a.lower() in t.lower():
        return t.replace(" - ", " ")
    return f"{t} {a}"


def convert_youtube_url(url: str) -> tuple[str, str]:
    """YouTube -> Spotify. Spotify's Web API now needs a paid Premium developer
    account, so this reads the song name from YouTube's public oEmbed endpoint and
    returns a Spotify search link."""
    api = "https://www.youtube.com/oembed?" + urllib.parse.urlencode({"url": url, "format": "json"})
    req = urllib.request.Request(api, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=8) as resp:
        data = json.loads(resp.read().decode("utf-8", errors="ignore"))
    query = song_query(data.get("title", ""), data.get("author_name", ""))
    if not query:
        raise ValueError("Could not read YouTube title")
    return "https://open.spotify.com/search/" + urllib.parse.quote(query, safe=""), query


def main() -> None:
    reverse = "--reverse" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--reverse"]

    if args[:1] == ["--test"] and len(args) > 1:
        test_url = args[1]
        if reverse:
            sp_url, query = convert_youtube_url(test_url)
            print(f"Matched: {query}")
            print(f"Spotify URL: {sp_url}")
            return
        ytm_url, display_sub, item_type = convert_spotify_url(test_url)
        print(f"Type: {item_type}")
        print(f"Matched: {display_sub}")
        print(f"YouTube Music URL: {ytm_url}")
        return

    if reverse:
        print("Starting YouTube -> Spotify clipboard watcher...")
    else:
        print("Starting Spotify -> YouTube Music clipboard watcher...")
    last_clip = get_clipboard()

    while True:
        try:
            clip = get_clipboard()
            if clip and clip != last_clip:
                last_clip = clip
                if reverse and YOUTUBE_REGEX.match(clip):
                    print(f"Detected YouTube link: {clip}")
                    sp_url, query = convert_youtube_url(clip)
                    set_clipboard(sp_url)
                    last_clip = sp_url
                    notify("Converted to Spotify", query, sp_url)
                    print(f"Replaced clipboard with: {sp_url}")
                    continue
                match = None if reverse else SPOTIFY_REGEX.match(clip)
                if match:
                    print(f"Detected Spotify link: {clip}")
                    ytm_url, display_sub, _ = convert_spotify_url(clip)
                    set_clipboard(ytm_url)
                    last_clip = ytm_url
                    notify(
                        "Converted to YouTube Music",
                        display_sub,
                        ytm_url,
                    )
                    print(f"Replaced clipboard with: {ytm_url}")
        except Exception as e:
            print(f"Error processing clipboard: {e}", file=sys.stderr)

        time.sleep(0.6)


if __name__ == "__main__":
    main()
