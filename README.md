# Spotify to YTM

Your friends keep sending Spotify links. You don't have Spotify.

Spotify to YTM is a tiny macOS menu bar app that watches your clipboard. Copy a Spotify link and it quietly swaps it for the matching YouTube Music link, so you just paste and play.

[Watch the 46 second explainer](media/spotify-to-ytm.mp4)

## What it does

- Works with tracks, albums, artists and playlists, plus `spotify.link` short links
- If you copy a whole message with a link in it, only the link gets swapped
- Menu bar toggles: Auto-Convert on Copy, Show Notification Banner, Auto-Open in Browser
- "Convert Current Clipboard Now" for a manual run
- Keeps your last 10 conversions in the menu (click to copy, Option-click to open)

## Install

Needs macOS 13 or later and the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/GhostInTheBus/spotify-to-ytm.git
cd spotify-to-ytm
./install.sh
```

That builds `/Applications/Spotify to YTM.app` and adds a LaunchAgent so it starts at login. A music note shows up in the menu bar.

## How it works

1. Watch: every 0.4 s it checks whether the clipboard changed. If the new text has no Spotify link, nothing happens.
2. Read: it opens the Spotify link and reads the page's `og:title` and artist tags.
3. Match: it searches YouTube Music for title plus artist and builds a `music.youtube.com` link from the top result.

No accounts, no API keys, no logins.

## Do I need YouTube Music Premium?

No. The links open on the free, ad supported tier of YouTube Music. On phones, playing in the background needs Premium.

## Privacy

Everything runs on your Mac. The only things sent anywhere are the Spotify link itself (to Spotify, to read the song name) and the song name (to YouTube Music, to search). Nothing else you copy leaves your machine. Conversion history stays in the app's local preferences, and "Clear History" wipes it.

## Python version

`spotify_to_ytm.py` does the same thing as a plain script with no build step:

```sh
python3 spotify_to_ytm.py            # watch the clipboard
python3 spotify_to_ytm.py --test URL # convert one link and print it
```

## Uninstall

```sh
launchctl unload ~/Library/LaunchAgents/com.ghostinthebus.spotify-to-ytm.plist
rm ~/Library/LaunchAgents/com.ghostinthebus.spotify-to-ytm.plist
rm -rf "/Applications/Spotify to YTM.app"
```

## Heads up

This leans on YouTube Music's web search and Spotify's public page tags. If either one changes, matching can break. Not affiliated with Spotify or YouTube.
