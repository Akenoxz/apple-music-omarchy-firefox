# Apple Music for Omarchy

Apple Music in the Omarchy bar: an Omarchy-style player panel with playlist picking, catalog browsing, search, and continuous playback; a theme-aware browser dropdown for the full site; and an optional mini-player that stays within reach. Chromium is the default browser; an opt-in Firefox mode runs Apple Music in a dedicated Firefox profile.

![Apple Music Queue view themed by Omarchy](preview.png)

## Features

- Omarchy-style player panel under the bar widget: artwork, seek bar, transport with shuffle and repeat, and **Playlists** / **Browse** / **Search** tabs driven by the signed-in page
- Starting a row keeps the panel open: the row you clicked and the track the page reports as playing stay highlighted in the accent color with a play/pause glyph, so a search result is not a one-shot
- Click into a playlist to see its songs and pick any one of them; the playlist becomes the queue and keeps playing from the track you chose
- A song started from search plays on through the rest of the results: when one ends the next begins, the way Apple Music advances through a list
- Search covers artists, songs, albums, and playlists, with the **Artists** section first — artist rows are round avatars and open the artist's profile (top songs and albums), the way Apple Music does
- The **Albums** sections hold albums only: singles stay out of both the search results and an artist's profile, so a discography reads as albums
- Lyrics for the playing track, fetched from the Apple Music catalog and rendered in a font and size you choose, in their own scroll area — the lyrics view never hides the tabs, the search field, or the player
- An options popup of its own (the gear next to the tabs): the lyrics on/off toggle, the lyrics font and size, and a scroll-speed multiplier shared by the mouse wheel and the arrow keys
- A seek bar that keeps moving between bridge publishes (100 ms interpolation), fixed-width time labels that never shift the layout, and track lengths that always arrive in seconds
- Waiting states in the panel itself: **Loading…** while lists or search results are in flight, **Reconnecting to the player…** when the snapshot stops refreshing, and a one-line page error with a **Retry** button
- Full keyboard navigation in the panel: rows, tabs, play, and search without touching the mouse (arrows or `hjkl`, `Enter`, `Space`, `s`, `Esc`)
- Playlists and Browse fill in one round trip whose page-side catalog requests run in parallel
- A self-healing page bridge: it restarts when it dies, re-binds after a page navigation, and never leaves a click waiting on a dead process
- Full `music.apple.com` interface in a bar-anchored browser app window
- Compact Queue view with artwork, progress, playback controls, live Up Next selection, and a real system-audio spectrum clipped into Omarchy's pixel wordmark (Chromium mode)
- Explicit, persistent **Full** / **Queue** switch plus a shared catalog-search action (Chromium mode)
- Compact monochrome bar icon or inline now-playing controls, switchable without opening settings
- Playback continues when the dropdown is hidden on its named Hyprland special workspace
- Dropdown positioning for bars on every edge, with multi-monitor geometry and small-screen clamping
- Pointer remains on the bar when the dropdown receives focus
- Live colors from the active Omarchy theme, including fast transitions between light and dark palettes (Chromium mode)
- Dedicated browser profile for a stable Apple session and isolated media metadata
- Runtime-only Hyprland rules, with no edits to the user's compositor configuration
- Fixed 90% profile zoom that keeps Apple's desktop layout active at dropdown width without Chromium's zoom popup
- Optional Firefox mode with a dedicated `AppleMusic` profile, DRM enabled, the browser UI hidden for an app-like window, and the page themed with the active Omarchy palette

## Install

### Step 1: Add the plugin

```bash
omarchy plugin add https://github.com/Akenoxz/omarchy-apple-music-firefox.git --enable
```

The shell discovers the plugin and adds its widget to the right side of the bar. No extra packages are required.

When updating the plugin later (`omarchy plugin update melonamin.apple-music`), run `omarchy-restart-shell` afterwards so the bar loads the new widget and service code.

Built by Thomas Laranjo.

### Step 2: Open Apple Music and sign in

Click the widget to open the player panel, then press **Open Apple Music** (or run `omarchy-shell apple-music show`). The plugin creates a dedicated Chromium profile, launches `music.apple.com` in an app window, and pins the window to the bar edge. Sign in to Apple Music the first time the window opens; the session is kept in the dedicated profile and survives restarts. Once signed in, the panel's playlists, browse, and search tabs read from the same session.

### Step 3 (optional): Use Firefox instead of Chromium

Chromium stays the default. To run Apple Music in Firefox:

1. Install Firefox if it is missing:

   ```bash
   omarchy-pkg install firefox
   ```

2. Opt in to Firefox mode:

   ```bash
   mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-apple-music"
   printf 'firefox\n' >"${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-apple-music/browser-mode"
   ```

3. Close the Apple Music window if it is open (click inside it and press `Ctrl+Q`), then click the widget again. The plugin now creates a dedicated `AppleMusic` Firefox profile, registers it in Firefox's profile list, and opens Apple Music in its own window with the tab bar, URL bar, and navigation controls hidden. The page is styled with the current Omarchy theme colors.

4. On the first launch Apple Music may ask to enable DRM. Allow it. Firefox downloads Widevine automatically on first use; protected tracks play once that download finishes.

If Firefox is missing, launching silently falls back to Chromium. The user's normal Firefox profile is never touched: the `AppleMusic` profile lives at `$XDG_DATA_HOME/omarchy-apple-music/firefox/AppleMusic` and is only linked into Firefox's own profile registry.

### Step 4: Switch back to Chromium

```bash
rm "${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-apple-music/browser-mode"
```

Close the Apple Music window first; the next launch uses Chromium again. No restart of the shell or the compositor is needed.

### Remove the plugin

```bash
omarchy plugin remove melonamin.apple-music
hyprctl reload      # drops the runtime-only window rule
```

The dedicated browser profiles are retained so uninstalling or updating the plugin does not destroy the saved Apple session. Delete `$XDG_DATA_HOME/omarchy-apple-music` separately if you also want to remove that local state; that also removes the Firefox `AppleMusic` profile and its entry in Firefox's profile registry can then be deleted from `~/.mozilla/firefox/profiles.ini`.

## Requirements

Omarchy 4 (Quattro) or newer, running `omarchy-shell` on Hyprland.

The stock Omarchy installation already provides Chromium, `jq`, Hyprland, Quickshell, PipeWire's Pulse compatibility layer, `parec`, `od`, and `awk`, so the plugin adds no package dependencies. The player panel's page bridge additionally wants Node.js 22 or newer (`node` on `PATH`, no npm packages); without it the panel still plays, pauses, and skips through the browser's MPRIS interface, but the playlists, browse, and search tabs stay empty. Apple Music playback still depends on the browser's codec and DRM support; a Chromium build without a working Widevine CDM may load the site but refuse protected tracks. Firefox is optional and only used when the `browser-mode` marker from Step 3 exists.

## Firefox mode specifics

The dedicated `AppleMusic` profile is created on first Firefox launch with:

- DRM and Widevine enabled (`media.eme.enabled`, `media.gmp-widevinecdm.enabled`)
- No default-browser prompt and no session-restore prompt
- A minimal `userChrome.css` that hides the tab bar, URL bar, and navigation controls; delete `$XDG_DATA_HOME/omarchy-apple-music/firefox/AppleMusic/chrome/userChrome.css` to restore the full browser UI in that window
- A generated `chrome/userContent.css` that restyles `music.apple.com` with the active Omarchy palette — the same page rules and derived colors the Chromium extension applies

Launches use `firefox -P AppleMusic --new-window https://music.apple.com` with a dedicated remoting identity (`MOZ_APP_REMOTINGNAME`), so the window carries the `melonamin.apple-music` class Hyprland matches, opens as its own window rather than a tab of normal Firefox, and can coexist with a running Firefox session. A user-owned `AppleMusic` profile that predates the plugin is never reused or modified; in that case launching reports the conflict and keeps using Chromium.

The player panel works the same in both modes: it reaches the signed-in page through a local WebDriver BiDi bridge, which modern Firefox serves on the same remote-debugging port as Chromium.

Compared with Chromium mode, Firefox mode has known limitations:

- Theming is static: Firefox reads `userContent.css` at startup, so it always matches the theme that was active when the window last launched. After switching Omarchy themes, close the Apple Music window (`Ctrl+Q`) and click the widget again to pick up the new palette
- The **Full** / **Queue** switch buttons are not injected; use Apple's own interface
- The audio spectrum visualizer is disabled, since nothing consumes its output
- Playback state on the bar comes from Firefox's MPRIS support and may show less metadata than Chromium's

## Use

| Input | Compact icon | Mini-player |
|---|---|---|
| Left click | Open the player panel | Play or pause |
| Right click | Open the player panel | Open the player panel |
| Middle click | Switch to mini-player | Switch to compact icon |
| Scroll up / down | Previous / next track | Previous / next track |

The player panel is the popup: current track with artwork and a seek bar, transport controls with shuffle and repeat, and three tabs — **Playlists** from your library, **Browse** (recently added albums plus top playlists), and **Search** across artists, songs, albums, and playlists. The refresh button next to the tabs refetches the lists, and the current search term as well while the Search tab is open.

Activating a row starts it in the signed-in page and leaves the panel open: the row you clicked, and whatever the page then reports as playing, stay highlighted in the accent color with a play/pause glyph, so a search result or a playlist is not a one-shot. Only the bar icon, a click outside the panel, or `Esc` closes it. **Open Apple Music** closes the panel and shows the full browser window.

Clicking a playlist opens it: the panel lists the playlist's songs in place of the current list, with a back arrow (or `Esc`) returning to it. Choosing a song starts the playlist at that track and continues through the list, so a playlist behaves like a queue rather than a single click. A song picked from **Search** does the same across the results: the next result follows when the current track ends. Clicking an artist opens their profile the same way — **Top Songs** and **Albums** — and picking a top song plays through the rest of that list. The **Albums** sections show albums only: Apple's lists mix in singles (and do not flag every one of them), so the panel drops anything marked as a single or titled "… - Single" from both the artist profile and the search results.

The player panel also has a **lyrics** view and an **options** popup. The lyric-note button next to the tabs (or the toggle in options) swaps the song list for the playing track's lyrics, fetched from the Apple Music catalog and rendered in the font and size chosen in options; the lyrics scroll in their own area, so the player above stays put. Lyrics are always a view *beside* the lists, never a replacement for the panel: the tabs, the search field, and the transport stay on screen, and picking a tab, searching, opening a playlist or artist, or pressing `Esc` leaves the lyrics view (a second `Esc` closes the panel). The gear button opens the options popup, which also holds the **scroll-speed** slider that scales both the mouse wheel and the arrow keys when you are hunting through a long list.

The panel tells waiting apart from empty. Lists show **Loading…** while a request is in flight; an idle Search tab says "Search your catalog" and an empty one "No results"; a snapshot older than four seconds shows "Reconnecting to the player…"; and a page-side failure appears as a single error line with a **Retry** button. Seek works as soon as the bridge reports a duration, and both time labels keep one width for the whole track so nothing shifts while it plays.

The keyboard works throughout: `Up`/`Down` (or `j`/`k`) walk the rows, `Left`/`Right` (or `h`/`l`) switch tabs, `Enter` plays the selection, `Space` plays the selection too or play/pauses when no row is selected, `s` jumps to search, `Esc` backs out of an open playlist or closes the panel, and `Tab` moves to the next bar panel. While the search field has focus, typing goes to the field instead.

Clicking another window hides the panel without interrupting playback. Inside the browser window, **Full** opens Apple's complete interface and **Queue** opens the compact listening view; the choice is remembered explicitly between sessions (Chromium mode only).

The Queue visualizer follows play and pause state and uses the active theme accent. While the browser window is visible and Apple Music is playing, it monitors only the dedicated browser app's PipeWire stream, reduces it to 32 frequency bands, and draws those bands inside the official Omarchy wordmark. If that stream is unavailable, the wordmark falls back to a synthetic animation.

## Bar setting

The default presentation is the fixed-width monochrome icon. Set the presentation directly with `omarchy bar set`:

```bash
omarchy bar set melonamin.apple-music display player
omarchy bar set melonamin.apple-music display icon
```

`display` accepts `icon` or `player`; the legacy values `status`, `mini`, and `miniplayer` are aliases for `player`, and anything unknown falls back to `icon`. Middle-clicking the widget toggles between the two.

The options popup writes the same store, so the player settings can also be set from a terminal (numbers and booleans need `--json` to keep their type):

```bash
omarchy bar set melonamin.apple-music lyrics true --json       # show lyrics
omarchy bar set melonamin.apple-music lyricsFont "Noto Serif"  # empty = the bar's font
omarchy bar set melonamin.apple-music lyricsSize 20 --json
omarchy bar set melonamin.apple-music scrollSpeed 2 --json     # 0.5–4, wheel and arrows
```

## State and privacy

The Chromium profile lives at `$XDG_DATA_HOME/omarchy-apple-music/chromium`, falling back to `~/.local/share/omarchy-apple-music/chromium`. In Firefox mode the dedicated profile lives at `$XDG_DATA_HOME/omarchy-apple-music/firefox/AppleMusic`. They contain the Apple login session and normal site data for the dedicated app. Firefox's profile registry (`~/.mozilla/firefox/profiles.ini`) only receives one entry pointing at that directory.

The plugin stages its bundled Manifest V3 extension under `$XDG_RUNTIME_DIR/omarchy-apple-music/extension`, falling back to the plugin's data directory only when no runtime directory exists. The extension runs only on `https://music.apple.com/*`, requests local extension storage only to remember the selected Full/Queue view, and reads local theme and spectrum files generated by the plugin. High-frequency spectrum updates therefore stay in tmpfs instead of writing to persistent storage.

The compact view uses Apple Music's page-local MusicKit player to expose sanitized playback state: title, artist, album, artwork URL, duration, position, play state, repeat, shuffle, and queue entries. Account credentials and authorization tokens never cross that bridge. The bar uses the browser's standard MPRIS interface.

The player panel talks to the page through `bridge.mjs`, a small dependency-free Node process attached to the dedicated browser window over WebDriver BiDi on `127.0.0.1:62229`. It reads sanitized playback state and catalog data — names, artists, artwork URLs, lyrics lines — and sends playback commands; account credentials and authorization tokens never cross it. Lyrics are fetched from the catalog with the same signed-in page token the panel already uses and reduced to plain timed lines before they reach the bar; nothing is stored. The latest snapshot is rewritten every 400 ms to `$XDG_RUNTIME_DIR/omarchy-apple-music/bridge/state.json` (tmpfs), and queued commands live briefly in `$XDG_DATA_HOME/omarchy-apple-music/bridge-commands` with their replies in the runtime bridge directory, all deleted once consumed. Commands are picked up within about 40 ms of landing, so transport clicks feel immediate.

Three environment variables tune the bridge: `OMARCHY_APPLE_MUSIC_BRIDGE_PORT` overrides the BiDi port (default `62229`), `OMARCHY_APPLE_MUSIC_BRIDGE_CONNECT_MS` sets how long the bridge waits for the browser's port to open before giving up (default `120000`, covering a cold browser launch), and `OMARCHY_APPLE_MUSIC_BRIDGE_ATTEMPTS` sets how many 20 ms polls a single command waits for its reply (default `400`, about 8 seconds).

The panel watches that snapshot file directly through Quickshell's file watching, so playback state reaches the bar without a process per update, and the Playlists and Browse tabs load in a single round trip whose page-side catalog requests run in parallel. A bridge that is not running is started again on the next action whenever the Apple Music window exists — and never when no window is open — it re-binds after a page navigation, and one that cannot find the page for 15 seconds exits so the next action starts a clean one. A stopped or crashed bridge therefore heals itself instead of leaving every action to time out as "the page bridge did not answer"; while the snapshot is stale the panel says "Reconnecting to the player…" rather than freezing on the last known track. Durations reach the panel in seconds whatever unit MusicKit reports, and the seek bar interpolates between the 400 ms publishes so playback looks live.

MPRIS carries controls and metadata, not audio samples. For the visualizer, the service finds the PipeWire/Pulse sink input whose process belongs to the dedicated Apple Music browser tree and monitors that stream directly. PCM is downmixed in memory to 24 kHz mono, transformed into 32 normalized bands, and immediately discarded. Only the numeric band levels are published to the runtime extension; no PCM is persisted, sent over the network, or mixed with other applications' audio. Capture starts only while the dropdown is open and playback is active, and stops when it is hidden or paused. In Firefox mode capture never starts, because the extension that would consume the band data is Chromium-only.

## How it works

```text
Omarchy bar widget ──▶ Service.qml ──▶ Hyprland-managed browser app
        ▲                    │                       │
        └──── MPRIS state ───┘              bundled MV3 extension
                             │                       │
                             ├── theme palette ──────┤
                             │                       └── local MusicKit state
                             │
                             ├── bridge.mjs (WebDriver BiDi)
                             │        └── playlists, browse, search, transport
                             │
                             └── PipeWire app monitor ──▶ 32-band runtime spectrum
```

The bridge publishes its snapshot to `bridge/state.json`, which `Service.qml` watches as a file; the panel reads the service's view of it, so the UI follows the bridge's 400 ms cadence with no per-update process of its own.

The browser window remains alive on `special:melonamin-apple-music` when hidden. Showing it moves and focuses the same window at the current bar edge; hiding it parks the window again, so playback and the signed-in session continue uninterrupted.

The browser is selected at launch time from `$XDG_DATA_HOME/omarchy-apple-music/browser-mode`: anything other than `firefox`, or a system without a Firefox executable, launches the default Chromium app window. Firefox launches through the same Hyprland window rules, matched by the dedicated remoting class instead of Chromium's app class.

Theme changes are published as a small local palette and applied to an open dropdown during Omarchy's own transition. In Firefox mode the same palette plus the page rules shared with the extension are regenerated into the dedicated profile's `userContent.css`, which Firefox applies the next time the Apple Music window launches. The extension and spectrum analyzer are bundled with the plugin and are never downloaded at runtime.

## IPC

```bash
omarchy-shell apple-music status
omarchy-shell apple-music open
omarchy-shell apple-music show
omarchy-shell apple-music hide
omarchy-shell apple-music toggle
omarchy-shell apple-music playPause
omarchy-shell apple-music next
omarchy-shell apple-music previous
omarchy-shell apple-music refreshTheme
omarchy-shell apple-music ping
```

## Tests

```bash
node --test tests/
tests/spectrum.test.sh
tests/control.test.sh
tests/integration.sh
```

The model suites cover window matching, scaled monitor geometry, every bar edge, small displays, PID-scoped MPRIS selection, palette validation, click and display rules, player-state normalization, and MusicKit command routing. The panel-model suite covers the player view: state normalization (including millisecond durations from an older bridge), row and search-section mapping, one browse reply filling both list tabs, command shaping, artwork URLs, seek rounding, time formatting, the queue a song carries when it is picked from a list, and the artist profile view. The bridge suite runs `bridge.mjs` against a fake BiDi server and covers state polling, commands and replies, the envelope `cmdId` keeping a payload's song/album/playlist id intact, millisecond duration normalization, the one-shot browse load, playlist track listing, artist profiles, lyrics fetching, the queue a search song plays through, command-file ordering, zombie-session recovery, waiting for the browser's BiDi port and giving up within its budget, and clean shutdown. The spectrum test feeds a known 1 kHz tone through the analyzer and verifies its dominant band. The integration script validates that both manifests declare the same version, checks the bar widget's markup, and inspects live shell/compositor state without launching or closing Apple Music.

The control-script suite exercises the launch path end to end with mocked browsers: Chromium profile setup, opt-in Firefox profile creation and registry registration, the generated Firefox `userContent.css` (palette, derived colors, gate stripping, and relaunch idempotency, plus re-baking on theme changes), refusal to touch a user-owned `AppleMusic` profile, fallback to Chromium when Firefox is absent, and the disabled spectrum path in Firefox mode. It also drives the bridge protocol through the real `control.sh`: the `cmdId` envelope preserving payload ids, replies, timeouts, malformed-payload rejection, restarting a dead bridge when a window exists (never starting a live one twice, and never starting one with no window open), and `bridge-state` reporting the live snapshot. The suite points its mocked bridges at a throwaway port with no connect budget, so a test run can never attach to a live browser session.

An opt-in end-to-end run uses a disposable browser profile, parks its window on the special workspace, and closes it again. It skips itself if a real Apple Music window is open.

```bash
OMARCHY_APPLE_MUSIC_E2E=1 tests/integration.sh
```

## License

MIT

Apple and Apple Music are trademarks of Apple Inc. This project is independent and is not endorsed by or affiliated with Apple.
