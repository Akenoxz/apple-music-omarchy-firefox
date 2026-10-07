#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export MOCK_LOG="$TEST_DIR/hyprctl.log"

MOCK_HYPRCTL="$TEST_DIR/hyprctl"
cat >"$MOCK_HYPRCTL" <<'MOCK'
#!/bin/bash
set -euo pipefail

if [[ ${1:-} == "-j" && ${2:-} == "clients" ]]; then
  printf '[{"address":"0xabc","class":"chrome-music.apple.com__-Default","initialClass":"chrome-music.apple.com__-Default","pid":4242,"monitor":0,"workspace":{"id":2,"name":"%s"},"size":[900,700],"at":[10,20]}]' "${MOCK_CLIENT_WORKSPACE:-2}"
elif [[ ${1:-} == "-j" && ${2:-} == "monitors" ]]; then
  printf '[{"id":0,"name":"DP-5","width":5120,"height":2880,"scale":2,"x":0,"y":0,"reserved":[0,26,0,0],"activeWorkspace":{"id":2,"name":"2"},"specialWorkspace":{"id":0,"name":""}}]'
elif [[ ${1:-} == "-j" && ${2:-} == "cursorpos" ]]; then
  printf '{"x":2100,"y":13}'
else
  printf '%s\n' "$*" >>"$MOCK_LOG"
fi
MOCK
chmod +x "$MOCK_HYPRCTL"

PATH="$TEST_DIR:$PATH" MOCK_CLIENT_WORKSPACE="special:melonamin-apple-music" \
  "$ROOT/control.sh" state | jq -e '.open == false and .openScreen == ""' >/dev/null

PATH="$TEST_DIR:$PATH" MOCK_CLIENT_WORKSPACE="2" \
  "$ROOT/control.sh" state | jq -e '.open == true and .openScreen == "DP-5"' >/dev/null

: >"$MOCK_LOG"
PATH="$TEST_DIR:$PATH" "$ROOT/control.sh" show 0xabc DP-5 1200 80 900 700
grep -F 'hl.dsp.window.float({ window = "address:0xabc", action = "enable" })' "$MOCK_LOG" >/dev/null
! grep -F 'action = "set"' "$MOCK_LOG" >/dev/null
grep -F 'hl.dsp.window.move({ window = "address:0xabc", workspace = "2", follow = false })' "$MOCK_LOG" >/dev/null
grep -F 'hl.dsp.window.resize({ window = "address:0xabc", x = 900, y = 700, relative = false })' "$MOCK_LOG" >/dev/null
grep -F 'hl.dsp.window.move({ window = "address:0xabc", x = 1200, y = 80, relative = false })' "$MOCK_LOG" >/dev/null
grep -F 'hl.dsp.cursor.move({ x = 2100, y = 13 })' "$MOCK_LOG" >/dev/null
[[ $(sed -n '1p' "$MOCK_LOG") == *'hl.dsp.window.float('* ]]

: >"$MOCK_LOG"
PATH="$TEST_DIR:$PATH" "$ROOT/control.sh" hide 0xabc
grep -F 'hl.dsp.window.move({ window = "address:0xabc", workspace = "special:melonamin-apple-music", follow = false })' "$MOCK_LOG" >/dev/null

: >"$MOCK_LOG"
PATH="$TEST_DIR:$PATH" "$ROOT/control.sh" focus 0xabc
grep -F 'hl.dsp.focus({ window = "address:0xabc" })' "$MOCK_LOG" >/dev/null
grep -F 'hl.dsp.cursor.move({ x = 2100, y = 13 })' "$MOCK_LOG" >/dev/null

revision=$(XDG_DATA_HOME="$TEST_DIR/data" XDG_RUNTIME_DIR="$TEST_DIR/runtime" "$ROOT/control.sh" theme \
  '#222222' '#c2c2b0' '#78824b' '#78824b' '#666666' '#685742' dark)
[[ $revision =~ ^[0-9]+$ ]]

RUNTIME_EXTENSION="$TEST_DIR/runtime/omarchy-apple-music/extension"
for name in manifest.json theme-model.js player-model.js player-bridge.js content.js content.css theme.json spectrum.json; do
  [[ -f $RUNTIME_EXTENSION/$name ]]
done
jq -e --arg revision "$revision" '
  .schemaVersion == 1
  and .revision == $revision
  and .mode == "dark"
  and .colors.background == "#222222"
  and .colors.foreground == "#c2c2b0"
  and .colors.border == "#78824b"
  and .colors.accent == "#78824b"
  and .colors.muted == "#666666"
  and .colors.urgent == "#685742"
' "$RUNTIME_EXTENSION/theme.json" >/dev/null
jq -e '.schemaVersion == 1 and .active == false and .bands == []' "$RUNTIME_EXTENSION/spectrum.json" >/dev/null

# Chromium mode never bakes a Firefox stylesheet.
[[ ! -e $TEST_DIR/data/omarchy-apple-music/firefox/AppleMusic/chrome/userContent.css ]] ||
  { echo "chromium theme publish must not create firefox userContent.css" >&2; exit 1; }

touch "$RUNTIME_EXTENSION/background.js"
XDG_DATA_HOME="$TEST_DIR/data" XDG_RUNTIME_DIR="$TEST_DIR/runtime" "$ROOT/control.sh" theme \
  '#222222' '#c2c2b0' '#78824b' '#78824b' '#666666' '#685742' dark >/dev/null
[[ ! -e $RUNTIME_EXTENSION/background.js ]]
[[ -f $RUNTIME_EXTENSION/theme.json ]]

grep -F 'load_extension_paths' "$ROOT/control.sh" >/dev/null
grep -F 'chromium-flags.conf' "$ROOT/control.sh" >/dev/null

MOCK_SYSTEMD_RUN="$TEST_DIR/systemd-run"
cat >"$MOCK_SYSTEMD_RUN" <<'MOCK'
#!/bin/bash
set -euo pipefail
# Log the invocation, then run the wrapped command exactly as systemd would:
# every argument until the command line is a --option.
printf '%s\n' "$*" >>"${MOCK_SYSTEMD_RUN_LOG:-/dev/null}"
while [[ ${1:-} == --* ]]; do shift; done
exec "$@"
MOCK
chmod +x "$MOCK_SYSTEMD_RUN"

MOCK_UWSM_APP="$TEST_DIR/uwsm-app"
cat >"$MOCK_UWSM_APP" <<'MOCK'
#!/bin/bash
set -euo pipefail
# uwsm-app runs its arguments through the Wayland session startup protocol;
# the mock just drops the -- separator and executes the command.
if [[ ${1:-} == -- ]]; then shift; fi
exec "$@"
MOCK
chmod +x "$MOCK_UWSM_APP"

MOCK_CHROMIUM="$TEST_DIR/chromium"
cat >"$MOCK_CHROMIUM" <<'MOCK'
#!/bin/bash
exit 0
MOCK
chmod +x "$MOCK_CHROMIUM"

# The Firefox mock lives in its own PATH directory so individual blocks below
# can add or remove firefox from the environment.
MOCK_FIREFOX="$TEST_DIR/ffbin/firefox"
mkdir -p "$TEST_DIR/ffbin"
cat >"$MOCK_FIREFOX" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >>"$MOCK_FIREFOX_LOG"
exit 0
MOCK
chmod +x "$MOCK_FIREFOX"
export MOCK_FIREFOX_LOG="$TEST_DIR/firefox-args.log"
: >"$MOCK_FIREFOX_LOG"

XDG_DATA_HOME="$TEST_DIR/launch-data" XDG_RUNTIME_DIR="$TEST_DIR/launch-runtime" PATH="$TEST_DIR:$PATH" "$ROOT/control.sh" launch
PROFILE_PREFERENCES="$TEST_DIR/launch-data/omarchy-apple-music/chromium/Default/Preferences"
jq -e '.partition.default_zoom_level.x == -0.5778829311823857' "$PROFILE_PREFERENCES" >/dev/null

CORRUPT_PREFERENCES="$TEST_DIR/corrupt-data/omarchy-apple-music/chromium/Default/Preferences"
mkdir -p "$(dirname "$CORRUPT_PREFERENCES")"
printf 'not json\n' >"$CORRUPT_PREFERENCES"
XDG_DATA_HOME="$TEST_DIR/corrupt-data" XDG_RUNTIME_DIR="$TEST_DIR/corrupt-runtime" PATH="$TEST_DIR:$PATH" "$ROOT/control.sh" launch
jq -e '.partition.default_zoom_level.x == -0.5778829311823857' "$CORRUPT_PREFERENCES" >/dev/null

if XDG_DATA_HOME="$TEST_DIR/data" XDG_RUNTIME_DIR="$TEST_DIR/runtime" "$ROOT/control.sh" theme \
  red '#c2c2b0' '#78824b' '#78824b' '#666666' '#685742' dark 2>/dev/null; then
  echo "invalid colors must be rejected" >&2
  exit 1
fi

# --- Opt-in Firefox mode -----------------------------------------------------

# ffbin must come first so the mock wins over any real Firefox on the machine,
# while keeping the system directories the Chromium fallback needs (jq, etc.).
FIREFOX_PATH="$TEST_DIR/ffbin:$TEST_DIR:$PATH"

# Selecting Firefox creates and registers the dedicated profile, then launches
# it with the AppleMusic profile and a fresh app window.
FIREFOX_DATA="$TEST_DIR/firefox-mode"
mkdir -p "$FIREFOX_DATA/omarchy-apple-music"
printf 'firefox\n' >"$FIREFOX_DATA/omarchy-apple-music/browser-mode"
: >"$MOCK_FIREFOX_LOG"
XDG_DATA_HOME="$FIREFOX_DATA" XDG_RUNTIME_DIR="$FIREFOX_DATA/runtime" \
HOME="$TEST_DIR/firefox-home" PATH="$FIREFOX_PATH" "$ROOT/control.sh" launch
grep -F -- '-P AppleMusic' "$MOCK_FIREFOX_LOG" >/dev/null
grep -F -- '--new-window' "$MOCK_FIREFOX_LOG" >/dev/null

FF_PROFILE_DIR="$FIREFOX_DATA/omarchy-apple-music/firefox/AppleMusic"
[[ -d $FF_PROFILE_DIR ]] || { echo "firefox profile directory missing" >&2; exit 1; }
grep -F 'media.eme.enabled' "$FF_PROFILE_DIR/prefs.js" >/dev/null
grep -F 'media.gmp-widevinecdm.enabled' "$FF_PROFILE_DIR/prefs.js" >/dev/null
grep -F 'browser.shell.checkDefaultBrowser' "$FF_PROFILE_DIR/prefs.js" >/dev/null
grep -F 'toolkit.legacyUserProfileCustomizations.stylesheets' "$FF_PROFILE_DIR/prefs.js" >/dev/null
[[ -f $FF_PROFILE_DIR/chrome/userChrome.css ]] ||
  { echo "userChrome.css missing" >&2; exit 1; }

# The page theme is baked into userContent.css from the default palette (this
# fresh data dir has no published theme.json), with the Chromium-only gate
# stripped and the injected-UI rules left out.
FF_USER_CONTENT="$FF_PROFILE_DIR/chrome/userContent.css"
[[ -f $FF_USER_CONTENT ]] || { echo "userContent.css missing" >&2; exit 1; }
grep -F -- '@-moz-document domain(music.apple.com)' "$FF_USER_CONTENT" >/dev/null
grep -F -- '--omarchy-background: #1f1f1f;' "$FF_USER_CONTENT" >/dev/null
grep -F -- '--omarchy-elevated: #282828;' "$FF_USER_CONTENT" >/dev/null
grep -F -- '--omarchy-divider: rgba(85, 85, 85, 0.42);' "$FF_USER_CONTENT" >/dev/null
grep -F -- ':root .navigation {' "$FF_USER_CONTENT" >/dev/null
grep -q 'data-omarchy-theme' "$FF_USER_CONTENT" &&
  { echo "chromium-only theme gate leaked into userContent.css" >&2; exit 1; }
grep -q 'omarchy-apple-music-ui' "$FF_USER_CONTENT" &&
  { echo "injected-UI rules must not ship to Firefox" >&2; exit 1; }

FF_REGISTRY="$TEST_DIR/firefox-home/.mozilla/firefox/profiles.ini"
[[ -f $FF_REGISTRY ]] || { echo "firefox profile was not registered" >&2; exit 1; }
profile_entry_count() {
  awk -v name="$1" 'tolower($0) ~ /^name=/ && substr($0, 6) == name { n++ } END { print n + 0 }' "$FF_REGISTRY"
}
[[ $(profile_entry_count AppleMusic) == 1 ]] ||
  { echo "firefox registry must contain exactly one AppleMusic entry" >&2; exit 1; }

# A repeated launch must not duplicate the registry entry.
XDG_DATA_HOME="$FIREFOX_DATA" XDG_RUNTIME_DIR="$FIREFOX_DATA/runtime" \
HOME="$TEST_DIR/firefox-home" PATH="$FIREFOX_PATH" "$ROOT/control.sh" launch
[[ $(profile_entry_count AppleMusic) == 1 ]] ||
  { echo "firefox registry entry was duplicated" >&2; exit 1; }
[[ $(grep -c '@-moz-document' "$FF_USER_CONTENT") == 1 ]] ||
  { echo "userContent.css was duplicated on relaunch" >&2; exit 1; }

# A theme publish in Firefox mode re-bakes the palette into userContent.css
# with the same derived colors the theme-model computes for the extension.
XDG_DATA_HOME="$FIREFOX_DATA" XDG_RUNTIME_DIR="$FIREFOX_DATA/runtime" PATH="$FIREFOX_PATH" \
  "$ROOT/control.sh" theme '#111111' '#eeeeee' '#444444' '#34c759' '#777777' '#ff3b30' dark >/dev/null
grep -F -- '--omarchy-accent: #34c759;' "$FF_USER_CONTENT" >/dev/null
grep -F -- '--omarchy-accent-rgb: 52, 199, 89;' "$FF_USER_CONTENT" >/dev/null
grep -F -- '--omarchy-selected: rgba(52, 199, 89, 0.18);' "$FF_USER_CONTENT" >/dev/null
grep -F -- '--omarchy-elevated: #1a1a1a;' "$FF_USER_CONTENT" >/dev/null

# A pre-existing, user-owned AppleMusic profile must never be touched: launch
# refuses instead of reusing or modifying it.
CONFLICT_DATA="$TEST_DIR/firefox-conflict"
mkdir -p "$CONFLICT_DATA/omarchy-apple-music" "$TEST_DIR/conflict-home/.mozilla/firefox/user-owned"
printf 'firefox\n' >"$CONFLICT_DATA/omarchy-apple-music/browser-mode"
printf '%s\n' '[General]' 'StartWithLastProfile=1' '' '[Profile0]' \
  'Name=AppleMusic' 'IsRelative=0' \
  "Path=$TEST_DIR/conflict-home/.mozilla/firefox/user-owned" \
  >"$TEST_DIR/conflict-home/.mozilla/firefox/profiles.ini"
: >"$MOCK_FIREFOX_LOG"
if XDG_DATA_HOME="$CONFLICT_DATA" XDG_RUNTIME_DIR="$CONFLICT_DATA/runtime" \
  HOME="$TEST_DIR/conflict-home" PATH="$FIREFOX_PATH" \
  "$ROOT/control.sh" launch 2>/dev/null; then
  echo "launch must refuse when the AppleMusic profile name is taken" >&2
  exit 1
fi
[[ $(wc -l <"$MOCK_FIREFOX_LOG") == 0 ]] ||
  { echo "firefox must not run when the AppleMusic profile name is taken" >&2; exit 1; }

# Without the mode marker, launch stays on Chromium even when Firefox exists.
NO_MODE_DATA="$TEST_DIR/no-mode"
mkdir -p "$NO_MODE_DATA"
XDG_DATA_HOME="$NO_MODE_DATA" XDG_RUNTIME_DIR="$NO_MODE_DATA/runtime" \
HOME="$TEST_DIR/firefox-home" PATH="$FIREFOX_PATH" "$ROOT/control.sh" launch
[[ -d $NO_MODE_DATA/omarchy-apple-music/firefox ]] &&
  { echo "firefox profile must not be created in default chromium mode" >&2; exit 1; }

# With the marker but no firefox executable, launch falls back to Chromium.
# A real /usr/bin/firefox cannot be hidden by trimming PATH, so the fallback
# runs against a minimal PATH built from explicit symlinks.
NO_BINARY_DATA="$TEST_DIR/no-binary"
mkdir -p "$NO_BINARY_DATA/omarchy-apple-music" "$TEST_DIR/nofirefox-bin"
printf 'firefox\n' >"$NO_BINARY_DATA/omarchy-apple-music/browser-mode"
for tool in jq date mktemp mkdir install chmod mv rm tr tail grep sed awk dirname; do
  ln -sf "$(command -v "$tool")" "$TEST_DIR/nofirefox-bin/$tool"
done
XDG_DATA_HOME="$NO_BINARY_DATA" XDG_RUNTIME_DIR="$NO_BINARY_DATA/runtime" \
HOME="$TEST_DIR/empty-home" PATH="$TEST_DIR/nofirefox-bin:$TEST_DIR" "$ROOT/control.sh" launch
jq -e '.partition.default_zoom_level.x == -0.5778829311823857' \
  "$NO_BINARY_DATA/omarchy-apple-music/chromium/Default/Preferences" >/dev/null

# In Firefox mode the spectrum analyser must not run: the bundled MV3
# extension is Chromium-only, so nothing consumes the spectrum JSON.
SPECTRUM_DATA="$TEST_DIR/firefox-spectrum"
mkdir -p "$SPECTRUM_DATA/omarchy-apple-music"
printf 'firefox\n' >"$SPECTRUM_DATA/omarchy-apple-music/browser-mode"
XDG_DATA_HOME="$SPECTRUM_DATA" XDG_RUNTIME_DIR="$SPECTRUM_DATA/runtime" \
HOME="$TEST_DIR/firefox-home" PATH="$FIREFOX_PATH" timeout 10 \
  "$ROOT/control.sh" spectrum 4242
jq -e '.schemaVersion == 1 and .active == false and .bands == []' \
  "$SPECTRUM_DATA/runtime/omarchy-apple-music/extension/spectrum.json" >/dev/null

# --- Widget bridge ----------------------------------------------------------

BRIDGE_DATA="$TEST_DIR/bridge-data"
BRIDGE_RUNTIME="$TEST_DIR/bridge-runtime"
BRIDGE_CMD_DIR="$BRIDGE_DATA/omarchy-apple-music/bridge-commands"
BRIDGE_REPLY_DIR="$BRIDGE_RUNTIME/omarchy-apple-music/bridge/replies"
mkdir -p "$BRIDGE_CMD_DIR" "$BRIDGE_REPLY_DIR"

# A stub bridge answers queued commands through the same file protocol
# bridge.mjs uses: cmd-<id>.json in, reply-<id>.json out. The envelope id is
# read from `cmdId`, with `id` kept as the fallback older callers used; every
# queued command is appended to $4 so tests can assert on the payload.
STUB_BRIDGE="$TEST_DIR/stub-bridge"
cat >"$STUB_BRIDGE" <<'MOCK'
#!/bin/bash
set -euo pipefail
cmd_dir=$1 reply_dir=$2 mode=$3 log=${4:-}
for (( i = 0; i < 400; i++ )); do
  for cmd in "$cmd_dir"/cmd-*.json; do
    [[ -e $cmd ]] || continue
    if [[ -n $log ]]; then jq -c . "$cmd" >>"$log"; fi
    id=$(jq -r '.cmdId // .id' "$cmd")
    op=$(jq -r .op "$cmd")
    case $mode in
      ok) printf '{"ok":true,"op":"%s"}\n' "$op" >"$reply_dir/reply-$id.json" ;;
      fail) printf '{"ok":false,"error":"boom"}\n' >"$reply_dir/reply-$id.json" ;;
    esac
    rm -f -- "$cmd"
    exit 0
  done
  sleep 0.05
done
MOCK
chmod +x "$STUB_BRIDGE"

BRIDGE_ENV=(XDG_DATA_HOME="$BRIDGE_DATA" XDG_RUNTIME_DIR="$BRIDGE_RUNTIME")

# A successful command exits 0 and prints the bridge reply verbatim.
"$STUB_BRIDGE" "$BRIDGE_CMD_DIR" "$BRIDGE_REPLY_DIR" ok &
stub_pid=$!
set +e
reply_out=$(env "${BRIDGE_ENV[@]}" "$ROOT/control.sh" bridge '{"op":"toggle"}')
reply_status=$?
set -e
wait "$stub_pid" 2>/dev/null || true
[[ $reply_status == 0 ]] || { echo "bridge must exit 0 on a successful reply" >&2; exit 1; }
jq -e '.ok == true and .op == "toggle"' <<<"$reply_out" >/dev/null ||
  { echo "bridge must print the successful reply" >&2; exit 1; }
[[ -z $(find "$BRIDGE_CMD_DIR" "$BRIDGE_REPLY_DIR" -type f -print -quit) ]] ||
  { echo "bridge must clean up command and reply files" >&2; exit 1; }

# The wrapper's envelope id must never overwrite the payload's own id: a row
# click carries a song/album/playlist id, and clobbering it made every click
# ask MusicKit for a nonexistent item (mk-007 NOT_FOUND).
BRIDGE_SEEN_LOG="$TEST_DIR/bridge-seen.log"
: >"$BRIDGE_SEEN_LOG"
"$STUB_BRIDGE" "$BRIDGE_CMD_DIR" "$BRIDGE_REPLY_DIR" ok "$BRIDGE_SEEN_LOG" &
stub_pid=$!
set +e
reply_out=$(env "${BRIDGE_ENV[@]}" "$ROOT/control.sh" bridge '{"op":"playSong","id":"617154366"}')
reply_status=$?
set -e
wait "$stub_pid" 2>/dev/null || true
[[ $reply_status == 0 ]] || { echo "playSong must succeed through the stub" >&2; exit 1; }
queued=$(tail -n1 "$BRIDGE_SEEN_LOG")
jq -e '.op == "playSong" and .id == "617154366" and (.cmdId | type == "string")' <<<"$queued" >/dev/null ||
  { echo "bridge must keep the payload id and carry the envelope id in cmdId" >&2; exit 1; }

# A failed reply still prints the payload but exits non-zero.
"$STUB_BRIDGE" "$BRIDGE_CMD_DIR" "$BRIDGE_REPLY_DIR" fail &
stub_pid=$!
set +e
reply_out=$(env "${BRIDGE_ENV[@]}" "$ROOT/control.sh" bridge '{"op":"play"}')
reply_status=$?
set -e
wait "$stub_pid" 2>/dev/null || true
[[ $reply_status == 1 ]] || { echo "bridge must exit 1 on a failed reply" >&2; exit 1; }
jq -e '.ok == false and .error == "boom"' <<<"$reply_out" >/dev/null ||
  { echo "bridge must print the failed reply" >&2; exit 1; }

# With no bridge consuming commands the call times out with a JSON error.
set +e
reply_out=$(env "${BRIDGE_ENV[@]}" OMARCHY_APPLE_MUSIC_BRIDGE_ATTEMPTS=2 \
  "$ROOT/control.sh" bridge '{"op":"next"}')
reply_status=$?
set -e
[[ $reply_status == 1 ]] || { echo "bridge timeout must exit 1" >&2; exit 1; }
jq -e '.ok == false and .error == "bridge timeout"' <<<"$reply_out" >/dev/null
[[ -z $(find "$BRIDGE_CMD_DIR" -type f -print -quit) ]] ||
  { echo "timed out command must be cleaned up" >&2; exit 1; }

# Malformed payloads are rejected before anything is queued.
set +e
env "${BRIDGE_ENV[@]}" "$ROOT/control.sh" bridge 'not json' 2>/dev/null
reply_status=$?
set -e
[[ $reply_status == 2 ]] || { echo "bridge must reject malformed payloads with exit 2" >&2; exit 1; }
set +e
env "${BRIDGE_ENV[@]}" "$ROOT/control.sh" bridge 2>/dev/null
reply_status=$?
set -e
[[ $reply_status == 2 ]] || { echo "bridge without a payload must exit 2" >&2; exit 1; }

# bridge-state reports the live snapshot when present and a not-ready stub
# when the bridge has never written one.
state_out=$(env "${BRIDGE_ENV[@]}" "$ROOT/control.sh" bridge-state)
jq -e '.ready == false' <<<"$state_out" >/dev/null
printf '{"ready":true,"playing":true,"title":"Test"}\n' \
  >"$BRIDGE_RUNTIME/omarchy-apple-music/bridge/state.json"
state_out=$(env "${BRIDGE_ENV[@]}" "$ROOT/control.sh" bridge-state)
jq -e '.ready == true and .title == "Test"' <<<"$state_out" >/dev/null
