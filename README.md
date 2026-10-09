# Apple Music for Omarchy

Apple Music in the Omarchy bar: a player panel with playlist picking, catalog browsing, search, lyrics, and continuous playback — over the full `music.apple.com` site in a dedicated, theme-matched browser window.

**Firefox is the browser this plugin is built around.** Chromium is supported as an opt-in.

![Apple Music player panel themed by Omarchy](preview.png)

## Features

- Player panel under the bar widget: artwork, seek bar, transport, shuffle and repeat, and **Playlists** / **Browse** / **Search** tabs fed by the signed-in page
- Search across artists, songs, albums, and playlists — artists first, and an artist row opens their profile with top songs and albums
- **Albums** sections list albums only: singles are filtered out of both search and artist profiles
- Playlists and artists drill in; a song picked there becomes the queue and keeps playing when the track ends
- Lyrics for the current track, in a font and size you choose, without ever hiding the tabs, the search field, or the player
- Options popup (the gear): lyrics on/off, lyrics font and size, and a scroll-speed multiplier for the wheel and the arrow keys
- Dedicated Firefox profile with the Omarchy palette baked into the page, app-like chrome (no tab bar or URL bar), and DRM ready
- Full keyboard control, waiting and error states in the panel, and a page bridge that restarts itself when it dies

## Requirements

- Omarchy 4 (Quattro) or newer, running `omarchy-shell` on Hyprland
- Firefox — `omarchy-pkg install firefox`. This is the default browser mode
- `jq`, which ships with Omarchy
- Node.js on `PATH` — optional, and needed only for the page bridge (the plugin ships no npm dependencies). Without it the panel still plays, pauses, and skips through the browser's MPRIS interface, but the Playlists, Browse, and Search tabs stay empty

In Chromium mode, playback depends on Chromium's codec and DRM support: a build without a working Widevine CDM loads the site but refuses protected tracks.

## Install

**1 — Add the plugin:**

```bash
omarchy plugin add https://github.com/Akenoxz/apple-music-omarchy-firefox.git --enable
```

The shell discovers the plugin and adds the widget to the right of the bar. After a later update (`omarchy plugin update melonamin.apple-music`), run `omarchy-restart-shell` so the bar loads the new code.

**2 — Install Firefox:**

```bash
omarchy-pkg install firefox
```

**3 — Sign in:**

Click the widget, then **Open Apple Music**. The plugin creates a dedicated `AppleMusic` profile and opens `music.apple.com` in its own window with the tab bar and URL bar hidden. Sign in once — the session lives in that profile and survives restarts. If Apple Music asks to enable DRM, allow it; Firefox downloads Widevine on first use and protected tracks play once that finishes.

## Browser modes

Firefox is used automatically and needs no configuration.

**Opt in to Chromium:**

```bash
mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-apple-music"
printf 'chromium\n' >"${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-apple-music/browser-mode"
```

Close the Apple Music window first (click into it, then `Ctrl+Q`), then click the widget again.

**Return to Firefox:**

```bash
rm "${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-apple-music/browser-mode"
```

If Firefox is selected but not installed, launching falls back to Chromium instead of failing. No shell or compositor restart is needed to switch.

### Firefox mode

- Dedicated profile at `$XDG_DATA_HOME/omarchy-apple-music/firefox/AppleMusic` (where `$XDG_DATA_HOME` falls back to `~/.local/share`), registered as a single entry in `~/.mozilla/firefox/profiles.ini`. Your own Firefox profiles are never read or modified. If an `AppleMusic` profile that you own already exists, launching refuses with an error rather than reusing it.
- Profile preferences enable DRM and Widevine and suppress the default-browser and session-restore prompts.
- `chrome/userChrome.css` hides the tab bar, URL bar, and navigation controls so the window reads as an app; delete that file to restore the full browser UI in that window.
- `chrome/userContent.css` applies the active Omarchy palette to `music.apple.com`.
- Launched as `firefox -P AppleMusic --new-window --remote-debugging-port=62229 https://music.apple.com` with a dedicated remoting identity, so the window carries the `melonamin.apple-music` class Hyprland matches and coexists with a normal Firefox session.

Known limits:

- **Theme changes need a relaunch.** Firefox reads `userContent.css` at startup, so after switching Omarchy themes, close the window (`Ctrl+Q`) and reopen it.
- The **Full** / **Queue** switch is not injected into the page — use Apple's own interface.
- No audio visualizer; the extension that consumes it is Chromium-only.
- Bar metadata comes from Firefox's MPRIS and can be sparser than Chromium's.

### Chromium mode

- Profile at `$XDG_DATA_HOME/omarchy-apple-music/chromium`.
- The bundled Manifest V3 extension is staged under `$XDG_RUNTIME_DIR/omarchy-apple-music/extension`, loaded only into the app window and scoped to `https://music.apple.com/*`.
- Adds the **Full** / **Queue** switch — Apple's full interface or a compact listening view with a live spectrum — plus live theme sync.
- The app window opens at a fixed 90% zoom with `--class=melonamin.apple-music`.

## Use

| Input | Icon view | Player view |
|---|---|---|
| Left click | Open the player panel | Play / pause |
| Right click | Open the player panel | Open the player panel |
| Middle click | Switch to the player view | Switch to the icon view |
| Scroll up / down | Previous / next track | Previous / next track |

The panel stays open while you pick tracks: the row you clicked, and whatever the page reports as playing, stay highlighted in the accent color. Only the bar icon, a click outside, or `Esc` closes it. Clicking another window hides the panel without interrupting playback, and **Open Apple Music** closes the panel and focuses the browser window.

- **Playlists** — your library playlists. Open one to list its songs; picking a song starts the playlist at that track and keeps going.
- **Browse** — recently added albums and Apple's top playlists.
- **Search** — artists, songs, albums, and playlists. A song picked from the results queues the rest of them, so the next result follows when the track ends.
- **Lyrics** — the note button next to the tabs swaps the list for the current track's lyrics. The tabs, search field, and transport stay on screen; picking a tab, searching, opening a playlist or artist, or pressing `Esc` leaves the lyrics view.
- **Options** — the gear opens the settings popup.
- The refresh button refetches the lists, and the current search term while Search is open.

**Keyboard:** `Up`/`Down` (or `j`/`k`) walk the rows, `Left`/`Right` (or `h`/`l`) switch tabs, `Enter` plays the selection (play/pause when nothing is selected), `Space` play/pauses, `s` opens search, `Esc` backs out one step (playlist or artist → lyrics → panel), and `Tab` moves to the next bar panel. While the search field is focused, keys go to the field.

## Settings

`display` selects the bar presentation — `icon` (default) or `player`:

```bash
omarchy bar set melonamin.apple-music display player
omarchy bar set melonamin.apple-music display icon
```

The legacy values `status`, `mini`, and `miniplayer` are aliases for `player`. Middle-clicking the widget toggles between the two.

The options popup writes the same store. Numbers and booleans need `--json` to keep their type:

```bash
omarchy bar set melonamin.apple-music lyrics true --json        # show lyrics
omarchy bar set melonamin.apple-music lyricsFont "Noto Serif"   # empty = the bar's font
omarchy bar set melonamin.apple-music lyricsSize 20 --json      # 12–32
omarchy bar set melonamin.apple-music scrollSpeed 2 --json      # 0.5–4
```

## IPC

```bash
omarchy-shell apple-music status
omarchy-shell apple-music open | show | hide | close | toggle
omarchy-shell apple-music playPause | next | previous
omarchy-shell apple-music refreshTheme
omarchy-shell apple-music ping
```

## Privacy

- Apple credentials never leave the page. The bar reads sanitized metadata — title, artist, album, artwork URL, duration, position, repeat, shuffle, queue — over the browser's standard MPRIS interface.
- The panel talks to the page through `bridge.mjs`, a dependency-free Node process attached over WebDriver BiDi on `127.0.0.1:62229`. It reads catalog data (names, artists, artwork URLs, lyrics lines) and sends playback commands. Authorization tokens and credentials never cross it.
- The latest snapshot is rewritten every 400 ms to `$XDG_RUNTIME_DIR/omarchy-apple-music/bridge/state.json` (tmpfs). Queued commands live briefly in `$XDG_DATA_HOME/omarchy-apple-music/bridge-commands` and are deleted once consumed.
- The visualizer (Chromium only) monitors the app's own PipeWire stream, reduces it to 32 bands in memory, publishes only the band levels, and discards the PCM. It runs only while the dropdown is open and playback is active.
- Nothing is downloaded at runtime: the extension and the spectrum analyzer ship with the plugin.

Three environment variables tune the bridge: `OMARCHY_APPLE_MUSIC_BRIDGE_PORT` (default `62229`), `OMARCHY_APPLE_MUSIC_BRIDGE_CONNECT_MS` (default `120000`, covering a cold browser launch), and `OMARCHY_APPLE_MUSIC_BRIDGE_ATTEMPTS` (default `400`, about 8 seconds per command).

## How it works

```text
bar widget ──▶ Service.qml ──▶ browser window (Firefox, or Chromium app)
     ▲               │                      │
     └── MPRIS ──────┘        theme palette + page-local MusicKit state
                     │
                     ├── bridge.mjs (WebDriver BiDi) ── playlists, browse, search, lyrics, transport
                     └── PipeWire monitor ── 32-band spectrum (Chromium only)
```

The bar widget never polls: `bridge.mjs` publishes its snapshot file and `Service.qml` watches it, so playback state reaches the bar without a process per update. The panel's Playlists and Browse tabs fill in a single round trip whose page-side catalog requests run in parallel. A bridge that dies is restarted on the next action whenever the Apple Music window exists — and never when no window is open — and it re-binds after a page navigation, so a stalled bridge heals instead of leaving every action to time out.

The browser window stays alive on the Hyprland special workspace `special:melonamin-apple-music` while hidden, so playback and the signed-in session continue. Showing it moves and focuses the same window at the current bar edge; hiding it parks the window again. Window rules are installed at runtime, so your compositor configuration is never edited.

## Remove

```bash
omarchy plugin remove melonamin.apple-music
hyprctl reload      # drops the runtime-only window rule
```

Saved sessions are retained so that uninstalling or updating never destroys your Apple login. Delete `$XDG_DATA_HOME/omarchy-apple-music` to remove the dedicated profiles and local state, then drop any leftover `AppleMusic` entry from `~/.mozilla/firefox/profiles.ini`.

## Tests

```bash
node --test tests/          # model, extension, player, panel, and bridge suites
tests/spectrum.test.sh      # a 1 kHz tone lands in the expected band
tests/control.test.sh       # launch, browser modes, and the bridge protocol
tests/integration.sh        # manifests, bar markup, and live shell state

OMARCHY_APPLE_MUSIC_E2E=1 tests/integration.sh   # opt-in live launch/hide/close
```

`tests/control.test.sh` drives the real `control.sh` against mocked browsers and Hyprland, and covers both browser modes: the Firefox default with no marker, the `chromium` opt-out, the fallback when Firefox is missing, refusal to touch a user-owned `AppleMusic` profile, profile registration idempotency, the generated `userContent.css`, and the disabled spectrum path. Its bridge blocks run against a stub on a throwaway port, so a test run can never attach to a live browser session. The end-to-end run pins Chromium, so it never registers anything in your real Firefox profile registry, and it skips itself when an Apple Music window is already open.

## License

MIT.

Built by Thomas Laranjo.

Apple and Apple Music are trademarks of Apple Inc. This project is independent and is not affiliated with or endorsed by Apple.
