#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
# Scratch files the foreign-profile check creates outside TEST_DIR: it needs a
# directory this user does not own, and an unprivileged test cannot make one,
# so it points its profile at a root-owned scratch root instead. The EXIT trap
# removes them whether the check passed or failed — a failure inside the check
# must not leave them behind for the next run to dodge.
SCRATCH_FILES=()
cleanup() {
  rm -rf "$TEST_DIR"
  local file
  for file in "${SCRATCH_FILES[@]}"; do
    if [[ -O $file ]]; then
      rm -rf "$file"
    fi
  done
}
trap cleanup EXIT

export MOCK_LOG="$TEST_DIR/hyprctl.log"

# The launch blocks run bridge.mjs for real: the mocked systemd-run executes
# its command, exactly as systemd would. Point those stray bridges at a port
# nothing listens on and give them no connect budget, so a test run can never
# attach to, or leave a session behind on, a live browser's BiDi port.
export OMARCHY_APPLE_MUSIC_BRIDGE_PORT=62599
export OMARCHY_APPLE_MUSIC_BRIDGE_CONNECT_MS=1

MOCK_HYPRCTL="$TEST_DIR/hyprctl"
cat >"$MOCK_HYPRCTL" <<'MOCK'
#!/bin/bash
set -euo pipefail

if [[ ${1:-} == "-j" && ${2:-} == "clients" ]]; then
  [[ -z ${MOCK_CLIENTS_EMPTY:-} ]] || { printf '[]'; exit 0; }
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

PATH="$TEST_DIR:$PATH" MOCK_CLIENT_WORKSPACE="special:akenoxz-apple-music" \
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
grep -F 'hl.dsp.window.move({ window = "address:0xabc", workspace = "special:akenoxz-apple-music", follow = false })' "$MOCK_LOG" >/dev/null

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

# A theme publish must not invent a Firefox profile: with no profile on disk
# yet there is no userContent.css to bake, so none is created.
[[ ! -e $TEST_DIR/data/omarchy-apple-music/firefox/AppleMusic/chrome/userContent.css ]] ||
  { echo "theme publish must not create a firefox profile" >&2; exit 1; }

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
# Record the arguments so the launch blocks can assert on (or against) the
# debugging port, exactly like the Firefox mock does.
printf '%s\n' "$*" >>"${MOCK_CHROMIUM_LOG:-/dev/null}"
exit 0
MOCK
chmod +x "$MOCK_CHROMIUM"
export MOCK_CHROMIUM_LOG="$TEST_DIR/chromium-args.log"

# Firefox is the default browser mode, so the blocks below that want Chromium
# pin it explicitly rather than relying on the machine having no Firefox.
use_chromium() {
  mkdir -p "$1/omarchy-apple-music"
  printf 'chromium\n' >"$1/omarchy-apple-music/browser-mode"
}

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

use_chromium "$TEST_DIR/launch-data"
: >"$MOCK_CHROMIUM_LOG"
XDG_DATA_HOME="$TEST_DIR/launch-data" XDG_RUNTIME_DIR="$TEST_DIR/launch-runtime" PATH="$TEST_DIR:$PATH" "$ROOT/control.sh" launch
# node is on PATH here, so the bridge's BiDi endpoint rides along.
grep -F -- '--remote-debugging-port' "$MOCK_CHROMIUM_LOG" >/dev/null ||
  { echo "chromium must expose the BiDi port when node can run the bridge" >&2; exit 1; }
PROFILE_PREFERENCES="$TEST_DIR/launch-data/omarchy-apple-music/chromium/Default/Preferences"
jq -e '.partition.default_zoom_level.x == -0.5778829311823857' "$PROFILE_PREFERENCES" >/dev/null

CORRUPT_PREFERENCES="$TEST_DIR/corrupt-data/omarchy-apple-music/chromium/Default/Preferences"
mkdir -p "$(dirname "$CORRUPT_PREFERENCES")"
printf 'not json\n' >"$CORRUPT_PREFERENCES"
use_chromium "$TEST_DIR/corrupt-data"
XDG_DATA_HOME="$TEST_DIR/corrupt-data" XDG_RUNTIME_DIR="$TEST_DIR/corrupt-runtime" PATH="$TEST_DIR:$PATH" "$ROOT/control.sh" launch
jq -e '.partition.default_zoom_level.x == -0.5778829311823857' "$CORRUPT_PREFERENCES" >/dev/null

if XDG_DATA_HOME="$TEST_DIR/data" XDG_RUNTIME_DIR="$TEST_DIR/runtime" "$ROOT/control.sh" theme \
  red '#c2c2b0' '#78824b' '#78824b' '#666666' '#685742' dark 2>/dev/null; then
  echo "invalid colors must be rejected" >&2
  exit 1
fi

# --- Firefox mode (the default) ----------------------------------------------

# ffbin must come first so the mock wins over any real Firefox on the machine,
# while keeping the system directories the Chromium fallback needs (jq, etc.).
FIREFOX_PATH="$TEST_DIR/ffbin:$TEST_DIR:$PATH"

# With no browser-mode marker at all, launch picks Firefox: it is the default.
# It creates and registers the dedicated profile, then launches it with the
# AppleMusic profile and a fresh app window.
FIREFOX_DATA="$TEST_DIR/firefox-mode"
: >"$MOCK_FIREFOX_LOG"
XDG_DATA_HOME="$FIREFOX_DATA" XDG_RUNTIME_DIR="$FIREFOX_DATA/runtime" \
HOME="$TEST_DIR/firefox-home" PATH="$FIREFOX_PATH" "$ROOT/control.sh" launch
grep -F -- '-P AppleMusic' "$MOCK_FIREFOX_LOG" >/dev/null
grep -F -- '--new-window' "$MOCK_FIREFOX_LOG" >/dev/null
# node is on PATH here, so the launch carries the bridge's BiDi port.
grep -F -- '--remote-debugging-port' "$MOCK_FIREFOX_LOG" >/dev/null ||
  { echo "firefox must expose the BiDi port when node can run the bridge" >&2; exit 1; }

FF_PROFILE_DIR="$FIREFOX_DATA/omarchy-apple-music/firefox/AppleMusic"
[[ -d $FF_PROFILE_DIR ]] || { echo "firefox profile directory missing" >&2; exit 1; }
grep -F 'media.eme.enabled' "$FF_PROFILE_DIR/prefs.js" >/dev/null
grep -F 'media.gmp-widevinecdm.enabled' "$FF_PROFILE_DIR/prefs.js" >/dev/null
grep -F 'browser.shell.checkDefaultBrowser' "$FF_PROFILE_DIR/prefs.js" >/dev/null
grep -F 'toolkit.legacyUserProfileCustomizations.stylesheets' "$FF_PROFILE_DIR/prefs.js" >/dev/null
grep -F 'user_pref("devtools.debugger.remote-enabled", true);' "$FF_PROFILE_DIR/prefs.js" >/dev/null
grep -F 'user_pref("remote.active-protocols", 3);' "$FF_PROFILE_DIR/prefs.js" >/dev/null
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

# "chromium" in the marker opts out of the default, even when Firefox exists.
CHROMIUM_DATA="$TEST_DIR/chromium-mode"
use_chromium "$CHROMIUM_DATA"
: >"$MOCK_FIREFOX_LOG"
XDG_DATA_HOME="$CHROMIUM_DATA" XDG_RUNTIME_DIR="$CHROMIUM_DATA/runtime" \
HOME="$TEST_DIR/chromium-home" PATH="$FIREFOX_PATH" "$ROOT/control.sh" launch
[[ -d $CHROMIUM_DATA/omarchy-apple-music/firefox ]] &&
  { echo "the chromium marker must not create a firefox profile" >&2; exit 1; }
[[ ! -s $MOCK_FIREFOX_LOG ]] ||
  { echo "the chromium marker must not launch firefox" >&2; exit 1; }
jq -e '.partition.default_zoom_level.x == -0.5778829311823857' \
  "$CHROMIUM_DATA/omarchy-apple-music/chromium/Default/Preferences" >/dev/null

# With Firefox selected (the default) but no firefox executable, launch falls
# back to Chromium. A real /usr/bin/firefox cannot be hidden by trimming PATH,
# so the fallback runs against a minimal PATH built from explicit symlinks.
NO_BINARY_DATA="$TEST_DIR/no-binary"
mkdir -p "$NO_BINARY_DATA" "$TEST_DIR/nofirefox-bin"
for tool in jq date mktemp mkdir install chmod mv rm tr tail grep sed awk dirname; do
  ln -sf "$(command -v "$tool")" "$TEST_DIR/nofirefox-bin/$tool"
done
: >"$MOCK_CHROMIUM_LOG"
XDG_DATA_HOME="$NO_BINARY_DATA" XDG_RUNTIME_DIR="$NO_BINARY_DATA/runtime" \
HOME="$TEST_DIR/empty-home" PATH="$TEST_DIR/nofirefox-bin:$TEST_DIR" "$ROOT/control.sh" launch
jq -e '.partition.default_zoom_level.x == -0.5778829311823857' \
  "$NO_BINARY_DATA/omarchy-apple-music/chromium/Default/Preferences" >/dev/null
# That fallback PATH also has no node on it, so it is the MPRIS-only mode:
# the window opens, but never with a debugging port attached.
grep -F -- '--app=' "$MOCK_CHROMIUM_LOG" >/dev/null ||
  { echo "chromium must still launch without node" >&2; exit 1; }
grep -F -- '--remote-debugging-port' "$MOCK_CHROMIUM_LOG" >/dev/null &&
  { echo "no node: chromium must launch without a debugging port" >&2; exit 1; }

# In the default (Firefox) mode the spectrum analyser must not run: the bundled
# MV3 extension is Chromium-only, so nothing consumes the spectrum JSON.
SPECTRUM_DATA="$TEST_DIR/firefox-spectrum"
XDG_DATA_HOME="$SPECTRUM_DATA" XDG_RUNTIME_DIR="$SPECTRUM_DATA/runtime" \
HOME="$TEST_DIR/firefox-home" PATH="$FIREFOX_PATH" timeout 10 \
  "$ROOT/control.sh" spectrum 4242
jq -e '.schemaVersion == 1 and .active == false and .bands == []' \
  "$SPECTRUM_DATA/runtime/omarchy-apple-music/extension/spectrum.json" >/dev/null

# --- Debug endpoint --------------------------------------------------------
# The bridge's BiDi endpoint exists only for the bridge that uses it. The
# blocks above all ran with node on PATH; here node is absent, which is the
# MPRIS-only mode the README documents, and the browser must launch with
# remote debugging switched off outright — no port on the command line and
# no enabled debugging prefs left in the profile.

NONODE_BIN="$TEST_DIR/nonode-bin"
mkdir -p "$NONODE_BIN"
for tool in jq date mktemp mkdir install chmod mv rm tr tail grep sed awk dirname; do
  ln -sf "$(command -v "$tool")" "$NONODE_BIN/$tool"
done

NO_NODE_DATA="$TEST_DIR/no-node"
NO_NODE_WARNINGS="$TEST_DIR/no-node-warnings.log"
: >"$MOCK_FIREFOX_LOG"
XDG_DATA_HOME="$NO_NODE_DATA" XDG_RUNTIME_DIR="$NO_NODE_DATA/runtime" \
HOME="$TEST_DIR/no-node-home" PATH="$TEST_DIR/ffbin:$NONODE_BIN:$TEST_DIR" \
  "$ROOT/control.sh" launch 2>"$NO_NODE_WARNINGS"
grep -F -- '-P AppleMusic' "$MOCK_FIREFOX_LOG" >/dev/null ||
  { echo "the window must still launch without node" >&2; exit 1; }
grep -F -- '--remote-debugging-port' "$MOCK_FIREFOX_LOG" >/dev/null &&
  { echo "no node: firefox must launch without a debugging port" >&2; exit 1; }
grep -F 'node is required for the widget bridge' "$NO_NODE_WARNINGS" >/dev/null ||
  { echo "the missing bridge must be reported on launch" >&2; exit 1; }
NO_NODE_PREFS="$NO_NODE_DATA/omarchy-apple-music/firefox/AppleMusic/prefs.js"
grep -F 'user_pref("devtools.debugger.remote-enabled", false);' "$NO_NODE_PREFS" >/dev/null ||
  { echo "no node: remote debugging must be switched off in the profile" >&2; exit 1; }
grep -F 'user_pref("devtools.debugger.remote-enabled", true);' "$NO_NODE_PREFS" >/dev/null &&
  { echo "no node: the profile must not keep the debugger enabled" >&2; exit 1; }
grep -F 'user_pref("remote.active-protocols"' "$NO_NODE_PREFS" >/dev/null &&
  { echo "no node: the BiDi protocols pref must not be written" >&2; exit 1; }
grep -F 'user_pref("devtools.debugger.prompt-connection"' "$NO_NODE_PREFS" >/dev/null &&
  { echo "no node: the connection-prompt pref must not be written" >&2; exit 1; }

# A profile directory this user does not own must never get the debugger, even
# with node present: the window still opens, just without the port. Unprivileged
# tests cannot hand a directory to another account, so the profile is a symlink
# into a root-owned scratch directory — enough for its owner to differ from the
# launching user, which is exactly what the guard checks.
FOREIGN_TARGET=""
for scratch in /tmp /var/tmp /dev/shm; do
  [[ -e $scratch/prefs.js || -e $scratch/chrome ]] && continue
  FOREIGN_TARGET=$scratch
  break
done
if [[ -z $FOREIGN_TARGET ]]; then
  echo "skipping the foreign-profile check: every scratch directory is occupied" >&2
else
  FOREIGN_DATA="$TEST_DIR/foreign-data"
  FOREIGN_HOME="$TEST_DIR/foreign-home"
  FOREIGN_WARNINGS="$TEST_DIR/foreign-warnings.log"
  mkdir -p "$FOREIGN_DATA/omarchy-apple-music/firefox" "$FOREIGN_HOME"
  ln -s "$FOREIGN_TARGET" "$FOREIGN_DATA/omarchy-apple-music/firefox/AppleMusic"
  SCRATCH_FILES+=("$FOREIGN_TARGET/prefs.js" "$FOREIGN_TARGET/chrome")
  : >"$MOCK_FIREFOX_LOG"
  XDG_DATA_HOME="$FOREIGN_DATA" XDG_RUNTIME_DIR="$FOREIGN_DATA/runtime" \
  HOME="$FOREIGN_HOME" PATH="$FIREFOX_PATH" \
    "$ROOT/control.sh" launch 2>"$FOREIGN_WARNINGS"
  grep -F -- '-P AppleMusic' "$MOCK_FIREFOX_LOG" >/dev/null ||
    { echo "the window must still launch for a foreign-owned profile" >&2; exit 1; }
  grep -F -- '--remote-debugging-port' "$MOCK_FIREFOX_LOG" >/dev/null &&
    { echo "a profile this user does not own must never expose the debug port" >&2; exit 1; }
  grep -F 'not owned by this user' "$FOREIGN_WARNINGS" >/dev/null ||
    { echo "launch must report why the debug port was skipped" >&2; exit 1; }
  grep -F 'user_pref("devtools.debugger.remote-enabled", false);' \
    "$FOREIGN_TARGET/prefs.js" >/dev/null ||
    { echo "a foreign-owned profile must not keep the debugger enabled" >&2; exit 1; }
  # Leave the scratch directory exactly as it was found (the EXIT trap covers
  # the case where this check fails before reaching this line).
  [[ ! -O $FOREIGN_TARGET/prefs.js ]] || rm -f "$FOREIGN_TARGET/prefs.js"
  [[ ! -O $FOREIGN_TARGET/chrome ]] || rm -rf "$FOREIGN_TARGET/chrome"
fi

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

# Healing a dead bridge starts it again, so the bridge blocks keep that
# hermetic: hyprctl is the mock above (it reports one Apple Music window),
# systemctl reports the unit inactive, and systemd-run only records the
# attempt instead of launching a real bridge against a real browser port.
BRIDGE_BIN="$TEST_DIR/bridge-bin"
mkdir -p "$BRIDGE_BIN"
ln -sf "$MOCK_HYPRCTL" "$BRIDGE_BIN/hyprctl"
cat >"$BRIDGE_BIN/systemctl" <<'MOCK'
#!/bin/bash
set -euo pipefail
# is-active --quiet <unit>: inactive is what a dead bridge looks like, and an
# active unit must be left running.
[[ -z ${MOCK_BRIDGE_ACTIVE:-} ]] || exit 0
exit 3
MOCK
cat >"$BRIDGE_BIN/systemd-run" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_BRIDGE_START_LOG:-/dev/null}"
exit 0
MOCK
chmod +x "$BRIDGE_BIN/systemctl" "$BRIDGE_BIN/systemd-run"
export MOCK_BRIDGE_START_LOG="$TEST_DIR/bridge-start.log"

BRIDGE_ENV=(XDG_DATA_HOME="$BRIDGE_DATA" XDG_RUNTIME_DIR="$BRIDGE_RUNTIME" PATH="$BRIDGE_BIN:$PATH")

# A successful command exits 0 and prints the bridge reply verbatim.
"$STUB_BRIDGE" "$BRIDGE_CMD_DIR" "$BRIDGE_REPLY_DIR" ok &
stub_pid=$!
set +e
reply_out=$(env "${BRIDGE_ENV[@]}" "$ROOT/control.sh" bridge <<<'{"op":"toggle"}')
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
reply_out=$(env "${BRIDGE_ENV[@]}" "$ROOT/control.sh" bridge <<<'{"op":"playSong","id":"617154366"}')
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
reply_out=$(env "${BRIDGE_ENV[@]}" "$ROOT/control.sh" bridge <<<'{"op":"play"}')
reply_status=$?
set -e
wait "$stub_pid" 2>/dev/null || true
[[ $reply_status == 1 ]] || { echo "bridge must exit 1 on a failed reply" >&2; exit 1; }
jq -e '.ok == false and .error == "boom"' <<<"$reply_out" >/dev/null ||
  { echo "bridge must print the failed reply" >&2; exit 1; }

# With no bridge consuming commands the call times out with a JSON error.
set +e
reply_out=$(env "${BRIDGE_ENV[@]}" OMARCHY_APPLE_MUSIC_BRIDGE_ATTEMPTS=2 \
  "$ROOT/control.sh" bridge <<<'{"op":"next"}')
reply_status=$?
set -e
[[ $reply_status == 1 ]] || { echo "bridge timeout must exit 1" >&2; exit 1; }
jq -e '.ok == false and .error == "bridge timeout"' <<<"$reply_out" >/dev/null
[[ -z $(find "$BRIDGE_CMD_DIR" -type f -print -quit) ]] ||
  { echo "timed out command must be cleaned up" >&2; exit 1; }

# A dead bridge with a window on screen is restarted instead of leaving every
# command to time out (the panel's "page bridge did not answer").
: >"$MOCK_BRIDGE_START_LOG"
set +e
env "${BRIDGE_ENV[@]}" OMARCHY_APPLE_MUSIC_BRIDGE_ATTEMPTS=1 \
  "$ROOT/control.sh" bridge <<<'{"op":"next"}' >/dev/null 2>&1
set -e
grep -F 'omarchy-apple-music-bridge' "$MOCK_BRIDGE_START_LOG" >/dev/null ||
  { echo "a dead bridge with a window open must be restarted" >&2; exit 1; }

# A bridge that is already running is never started twice.
: >"$MOCK_BRIDGE_START_LOG"
set +e
env "${BRIDGE_ENV[@]}" MOCK_BRIDGE_ACTIVE=1 OMARCHY_APPLE_MUSIC_BRIDGE_ATTEMPTS=1 \
  "$ROOT/control.sh" bridge <<<'{"op":"next"}' >/dev/null 2>&1
set -e
[[ ! -s $MOCK_BRIDGE_START_LOG ]] ||
  { echo "a running bridge must not be started again" >&2; exit 1; }

# With no Apple Music window there is nothing for a bridge to talk to, so no
# process is started and the command simply times out.
: >"$MOCK_BRIDGE_START_LOG"
set +e
env "${BRIDGE_ENV[@]}" MOCK_CLIENTS_EMPTY=1 OMARCHY_APPLE_MUSIC_BRIDGE_ATTEMPTS=1 \
  "$ROOT/control.sh" bridge <<<'{"op":"next"}' >/dev/null 2>&1
set -e
[[ ! -s $MOCK_BRIDGE_START_LOG ]] ||
  { echo "no bridge may be started when no Apple Music window exists" >&2; exit 1; }

# The command carries what the user typed, so it must never reach a process's
# argv: any local user can read /proc/<pid>/cmdline. The wrapper is given a long
# poll budget and no bridge to answer, so it stays alive for the whole scan
# instead of the check racing it to the finish.
PAYLOAD_MARKER="payload-marker-$$"
leaked=""
leak_scans=0
set +e
env "${BRIDGE_ENV[@]}" OMARCHY_APPLE_MUSIC_BRIDGE_ATTEMPTS=100 \
  "$ROOT/control.sh" bridge <<<"{\"op\":\"search\",\"term\":\"$PAYLOAD_MARKER\"}" >/dev/null 2>&1 &
wrapper=$!
for (( i = 0; i < 100; i++ )); do
  # The scan ends when the wrapper's /proc entry disappears — bash reaps the
  # job as soon as it exits. Until then a missing or empty cmdline is a
  # transient, not a result: the first read right after the spawn races the
  # child's exec, and a zombie keeps its entry but has no cmdline. Such a read
  # costs this iteration an observation, never the whole loop — a wrapper that
  # is really gone stops it, and a wrapper that never shows a cmdline still
  # fails the scans check below. (Testing the size of a /proc file would always
  # say zero: stat reports no size for them.)
  [[ -d /proc/$wrapper ]] || break
  if grep -qa . "/proc/$wrapper/cmdline" 2>/dev/null; then
    leak_scans=$(( leak_scans + 1 ))
    if grep -qa -- "$PAYLOAD_MARKER" /proc/[0-9]*/cmdline 2>/dev/null; then
      leaked=1
      break
    fi
  fi
  sleep 0.02
done
wait "$wrapper" 2>/dev/null
set -e
[[ $leak_scans -gt 0 ]] ||
  { echo "the argv leak check never saw the wrapper running" >&2; exit 1; }
[[ -z $leaked ]] ||
  { echo "the bridge payload must never appear in a process's argv" >&2; exit 1; }

# The command still reaches the bridge: what travelled on stdin is what the
# wrapper queues for it.
: >"$BRIDGE_SEEN_LOG"
"$STUB_BRIDGE" "$BRIDGE_CMD_DIR" "$BRIDGE_REPLY_DIR" ok "$BRIDGE_SEEN_LOG" &
stub_pid=$!
set +e
env "${BRIDGE_ENV[@]}" "$ROOT/control.sh" bridge \
  <<<"{\"op\":\"search\",\"term\":\"$PAYLOAD_MARKER\"}" >/dev/null 2>&1
set -e
wait "$stub_pid" 2>/dev/null || true
jq -e --arg marker "$PAYLOAD_MARKER" \
  '.op == "search" and .term == $marker' <<<"$(tail -n1 "$BRIDGE_SEEN_LOG")" >/dev/null ||
  { echo "the wrapper must forward the command it reads from stdin" >&2; exit 1; }

# Positive control for that scan: the same marker in an argv *is* found, so the
# clean result above is a pass rather than a blind spot. The trailing `:` keeps
# bash from exec'ing the sleep and dropping the argument from its cmdline.
bash -c 'sleep 1; :' "$PAYLOAD_MARKER" &
control_pid=$!
found_in_argv=""
while [[ -d /proc/$control_pid ]]; do
  if grep -qa -- "$PAYLOAD_MARKER" /proc/[0-9]*/cmdline 2>/dev/null; then
    found_in_argv=1
    break
  fi
  sleep 0.01
done
wait "$control_pid" 2>/dev/null || true
[[ -n $found_in_argv ]] ||
  { echo "the argv scan cannot see a payload in argv, so the check above proves nothing" >&2; exit 1; }

# Malformed or missing payloads are rejected before anything is queued.
set +e
env "${BRIDGE_ENV[@]}" "$ROOT/control.sh" bridge <<<'not json' 2>/dev/null
reply_status=$?
set -e
[[ $reply_status == 2 ]] || { echo "bridge must reject malformed payloads with exit 2" >&2; exit 1; }
set +e
env "${BRIDGE_ENV[@]}" "$ROOT/control.sh" bridge </dev/null 2>/dev/null
reply_status=$?
set -e
[[ $reply_status == 2 ]] || { echo "bridge without a payload must exit 2" >&2; exit 1; }
set +e
env "${BRIDGE_ENV[@]}" "$ROOT/control.sh" bridge '{"op":"toggle"}' 2>/dev/null
reply_status=$?
set -e
[[ $reply_status == 2 ]] || { echo "a payload passed as an argument must be refused" >&2; exit 1; }

# bridge-state reports the live snapshot when present and a not-ready stub
# when the bridge has never written one.
state_out=$(env "${BRIDGE_ENV[@]}" "$ROOT/control.sh" bridge-state)
jq -e '.ready == false' <<<"$state_out" >/dev/null
printf '{"ready":true,"playing":true,"title":"Test"}\n' \
  >"$BRIDGE_RUNTIME/omarchy-apple-music/bridge/state.json"
state_out=$(env "${BRIDGE_ENV[@]}" "$ROOT/control.sh" bridge-state)
jq -e '.ready == true and .title == "Test"' <<<"$state_out" >/dev/null
