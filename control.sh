#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WINDOW_CLASS="melonamin.apple-music"
SPECIAL_NAME="melonamin-apple-music"
SPECIAL_WORKSPACE="special:$SPECIAL_NAME"
APPLE_MUSIC_URL="https://music.apple.com"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-apple-music"
PROFILE_DIR="$DATA_DIR/chromium"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-$DATA_DIR/runtime}/omarchy-apple-music"
EXTENSION_DIR="$RUNTIME_DIR/extension"
EXTENSION_FILES=(manifest.json theme-model.js player-model.js player-bridge.js content.js content.css)
EXTENSION_MANIFEST_SOURCE="chromium-manifest.json"
DEFAULT_ZOOM_LEVEL="-0.5778829311823857"
# Widget bridge: bridge.mjs talks to the dedicated browser window through
# WebDriver BiDi on this port (Firefox serves BiDi on --remote-debugging-port;
# Chromium serves both CDP and BiDi there). Overridable for tests and clashes.
BIDI_PORT="${OMARCHY_APPLE_MUSIC_BRIDGE_PORT:-62229}"
BRIDGE_DIR="$RUNTIME_DIR/bridge"
BRIDGE_REPLY_DIR="$BRIDGE_DIR/replies"
BRIDGE_STATE_FILE="$BRIDGE_DIR/state.json"
BRIDGE_COMMAND_DIR="$DATA_DIR/bridge-commands"
BRIDGE_UNIT="omarchy-apple-music-bridge"

# Browser mode: "chromium" (default) or "firefox". Firefox is strictly
# opt-in via $XDG_DATA_HOME/omarchy-apple-music/browser-mode; when the marker
# selects Firefox but no Firefox executable is found, launching falls back to
# the default Chromium behavior.
MODE_FILE="$DATA_DIR/browser-mode"
FIREFOX_DATA_ROOT="$DATA_DIR/firefox"
FIREFOX_PROFILE_NAME="AppleMusic"
FIREFOX_CLASS="melonamin.apple-music"
# Passed into the transient systemd unit with --setenv (unit processes do not
# inherit the caller's environment). MOZ_APP_REMOTINGNAME gives every window of
# this instance its own Wayland app_id/X11 class so Hyprland rules and the
# window matcher can find the Apple Music window without touching normal
# Firefox windows.
FIREFOX_LAUNCH_ENV=(
  "MOZ_APP_REMOTINGNAME=$FIREFOX_CLASS"
  "MOZ_ENABLE_WAYLAND=1"
)
# Firefox DRM/behavior prefs for the dedicated AppleMusic profile only.
FIREFOX_PREFS=(
  "user_pref(\"media.eme.enabled\", true);"
  "user_pref(\"media.gmp-widevinecdm.enabled\", true);"
  "user_pref(\"media.gmp-widevinecdm.visible\", true);"
  "user_pref(\"browser.shell.checkDefaultBrowser\", false);"
  "user_pref(\"browser.startup.page\", 0);"
  "user_pref(\"browser.warnOnQuit\", false);"
  "user_pref(\"browser.sessionstore.resume_from_crash\", false);"
  "user_pref(\"toolkit.legacyUserProfileCustomizations.stylesheets\", true);"
  "user_pref(\"browser.uiCustomization.verticalTabBarInitialized\", true);"
  # WebDriver BiDi (the widget bridge) on --remote-debugging-port. Firefox
  # no longer serves CDP on that port; remote.active-protocols 3 keeps both
  # protocols offered where builds still support CDP.
  "user_pref(\"remote.active-protocols\", 3);"
  "user_pref(\"devtools.debugger.remote-enabled\", true);"
  "user_pref(\"devtools.debugger.prompt-connection\", false);"
)
# userChrome.css hides Firefox's tab bar, URL bar, and navigation controls so
# the dedicated profile reads as an app window rather than a browser. It is
# only written to the dedicated profile and can be removed at any time.
FIREFOX_USER_CHROME='/* omarchy-apple-music: app-like chrome for the dedicated AppleMusic profile.
   Delete this file to restore the full Firefox browser UI. */
@namespace url("http://www.mozilla.org/keymaster/gatekeeper/there.is.only.xul");

#TabsToolbar,
#toolbar-menubar,
#nav-bar,
#PersonalToolbar,
#urlbar-container,
#search-container { display: none !important; }'

browser_mode() {
  local mode="chromium"
  if [[ -r $MODE_FILE ]]; then
    mode=$(tr -d '[:space:]' <"$MODE_FILE")
    [[ $mode == "firefox" ]] || mode="chromium"
  fi
  printf '%s' "$mode"
}

firefox_executable() {
  command -v firefox
}

firefox_registry() {
  # Firefox resolves -P <name> through its standard profile registry. The
  # dedicated Apple Music profile is registered there with an absolute path
  # into the plugin's data directory, so its contents stay inside
  # $DATA_DIR and no existing Firefox profile is ever touched.
  printf '%s\n' "$HOME/.mozilla/firefox/profiles.ini"
}

# Prints the registered Path of a profile named $FIREFOX_PROFILE_NAME, or
# nothing when no such profile exists in the registry.
firefox_registered_path() {
  local registry
  registry=$(firefox_registry)
  [[ -f $registry ]] || return 0
  awk -v name="$FIREFOX_PROFILE_NAME" '
    /^\[/ { inprofile = ($0 ~ /^\[Profile[0-9]+\]$/); matched = 0 }
    inprofile && tolower($0) ~ /^name=/ {
      # Firefox matches profile names case-insensitively and writes the
      # keys capitalized, so lowercase both sides before comparing.
      value = tolower($0); sub(/^name=[ \t]*/, "", value)
      matched = (value == tolower(name))
    }
    inprofile && matched && tolower($0) ~ /^path=/ {
      value = $0; sub(/^[Pp]ath=[ \t]*/, "", value)
      print value
      exit
    }
  ' "$registry"
}

firefox_profile_dir() {
  printf '%s\n' "$FIREFOX_DATA_ROOT/$FIREFOX_PROFILE_NAME"
}

# Computes the --omarchy-* variables from the six theme colors: a bash/awk
# port of extension/theme-model.js variables(), so the generated userContent.css
# derives exactly the same elevated/hover/selected/... colors as the Chromium
# extension. All inputs are validated #rrggbb values (see write_firefox_user_content).
firefox_theme_variables() {
  awk -v bg="$1" -v fg="$2" -v border="$3" -v accent="$4" \
      -v muted="$5" -v urgent="$6" '
    function hexval(c) { return index("0123456789abcdef", tolower(c)) - 1 }
    function byte(s, pos) { return hexval(substr(s, pos, 1)) * 16 + hexval(substr(s, pos + 1, 1)) }
    function channel(v) {
      v = v < 0 ? 0 : (v > 255 ? 255 : v)
      return sprintf("%02x", int(v + 0.5))
    }
    function blendHex(a, b, t, i, out, ca, cb) {
      out = "#"
      for (i = 0; i < 3; i++) {
        ca = byte(a, 2 + i * 2); cb = byte(b, 2 + i * 2)
        out = out channel(ca + (cb - ca) * t)
      }
      return out
    }
    function rgbTriplet(c, i, out) {
      out = ""
      for (i = 0; i < 3; i++) out = out (i ? ", " : "") byte(c, 2 + i * 2)
      return out
    }
    function rgba(c, a, i, out) {
      out = ""
      for (i = 0; i < 3; i++) out = out (i ? ", " : "") byte(c, 2 + i * 2)
      return "rgba(" out ", " a ")"
    }
    BEGIN {
      printf "  --omarchy-background: %s;\n", bg
      printf "  --omarchy-background-rgb: %s;\n", rgbTriplet(bg)
      printf "  --omarchy-foreground: %s;\n", fg
      printf "  --omarchy-foreground-rgb: %s;\n", rgbTriplet(fg)
      printf "  --omarchy-border: %s;\n", border
      printf "  --omarchy-accent: %s;\n", accent
      printf "  --omarchy-accent-rgb: %s;\n", rgbTriplet(accent)
      printf "  --omarchy-muted: %s;\n", muted
      printf "  --omarchy-urgent: %s;\n", urgent
      printf "  --omarchy-elevated: %s;\n", blendHex(bg, fg, 0.04)
      printf "  --omarchy-hover: %s;\n", rgba(fg, "0.08")
      printf "  --omarchy-selected: %s;\n", rgba(accent, "0.18")
      printf "  --omarchy-pressed: %s;\n", rgba(accent, "0.22")
      printf "  --omarchy-selection-border: %s;\n", rgba(accent, "0.35")
      printf "  --omarchy-divider: %s;\n", rgba(border, "0.42")
      printf "  --omarchy-secondary: %s;\n", rgba(muted, "0.88")
      printf "  --omarchy-tertiary: %s;\n", rgba(muted, "0.62")
      printf "  --omarchy-disabled: %s;\n", rgba(muted, "0.38")
    }'
}

# Prints the marked page-theme rules from the bundled extension stylesheet
# with the Chromium-only data attribute gate stripped, so the same rules apply
# under Firefox where no content script runs to set data-omarchy-theme.
firefox_page_theme_rules() {
  awk '
    /omarchy:firefox-page-theme-begin/ { capture = 1; next }
    /omarchy:firefox-page-theme-end/ { capture = 0; next }
    capture { sub(/:root\[data-omarchy-theme\]/, ":root"); print }
  ' "$ROOT/extension/content.css"
}

# Regenerates the dedicated profile's userContent.css from the current theme
# (theme.json) plus the marked page-theme rules. Firefox reads userContent.css
# at startup, so a theme change reaches the Apple Music window on its next
# launch. Skipped when the profile does not exist yet; setup_firefox_profile
# generates the first copy.
write_firefox_user_content() {
  local profile_dir file tmp colors key value index
  profile_dir=$(firefox_profile_dir)
  [[ -d $profile_dir ]] || return 0
  mkdir -p "$profile_dir/chrome"
  file="$profile_dir/chrome/userContent.css"
  tmp=$(mktemp "$profile_dir/chrome/.userContent.XXXXXX")

  # Colors come from the published theme.json; defaults match the initial
  # theme prepare_extension writes when no theme has been published yet.
  local names=(background foreground border accent muted urgent)
  local defaults=("#1f1f1f" "#f5f5f7" "#555555" "#fa586a" "#98989d" "#ff453a")
  colors="$EXTENSION_DIR/theme.json"
  local values=()
  for (( index = 0; index < 6; index++ )); do
    key=${names[$index]}
    value=""
    if [[ -r $colors ]]; then
      value=$(jq -r --arg key "$key" '.colors[$key] // empty' "$colors" 2>/dev/null || true)
    fi
    [[ $value =~ ^#[0-9a-fA-F]{6}$ ]] || value=${defaults[$index]}
    values+=("$value")
  done

  {
    printf '%s\n' \
      '/* omarchy-apple-music: generated from the active Omarchy theme.' \
      '   Do not edit; control.sh rewrites this file on theme changes and' \
      '   Firefox applies it when the Apple Music window next launches. */' \
      '@-moz-document domain(music.apple.com) {' \
      ':root {'
    firefox_theme_variables "${values[@]}"
    printf '%s\n' '}' ''
    firefox_page_theme_rules
    printf '%s\n' '}'
  } >"$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$file"
}

# Returns 0 when Firefox mode is active and a Firefox executable exists.
# Non-zero means "use the default Chromium behavior". The dedicated profile is
# created on demand by setup_firefox_profile.
use_firefox() {
  [[ $(browser_mode) == "firefox" ]] || return 1
  firefox_executable >/dev/null || return 1
  return 0
}

setup_firefox_profile() {
  local profile_dir registry section index path
  profile_dir=$(firefox_profile_dir)
  registry=$(firefox_registry)
  umask 077
  mkdir -p "$profile_dir"

  # The DRM, prompt, and session prefs make the first launch behave like an
  # app: Widevine is requested up front, no default-browser nag, no session
  # restore. Appended idempotently; Firefox rewrites prefs.js on shutdown.
  for pref in "${FIREFOX_PREFS[@]}"; do
    grep -qxF "$pref" "$profile_dir/prefs.js" 2>/dev/null || printf '%s\n' "$pref" >>"$profile_dir/prefs.js"
  done

  # userChrome.css hides the tab bar, URL bar, and navigation controls so the
  # window reads as an app instead of a browser. The enabling pref lives in
  # FIREFOX_PREFS; deleting the file restores the full browser UI.
  mkdir -p "$profile_dir/chrome"
  if [[ ! -f $profile_dir/chrome/userChrome.css ]]; then
    printf '%s\n' "$FIREFOX_USER_CHROME" >"$profile_dir/chrome/userChrome.css"
  fi

  # Bake the current theme into userContent.css so the Apple Music page
  # matches the Omarchy theme without the Chromium-only extension.
  write_firefox_user_content

  # Register the profile so -P AppleMusic resolves. A pre-existing AppleMusic
  # profile owned by the user is never reused or modified; failing here makes
  # launch fall back to the default Chromium behavior.
  path=$(firefox_registered_path)
  if [[ -n $path ]]; then
    [[ $path == "$profile_dir" ]] && return 0
    echo "firefox profile '$FIREFOX_PROFILE_NAME' already exists and is not managed by this plugin" >&2
    return 1
  fi

  section="Profile0"
  index=0
  if [[ -f $registry ]]; then
    while grep -q "^\[$section\]$" "$registry"; do
      index=$((index + 1))
      section="Profile$index"
    done
    # Guard against appending straight after an unterminated final line.
    if [[ -s $registry && -n $(tail -c 1 "$registry") ]]; then
      printf '\n' >>"$registry"
    fi
  else
    mkdir -p "${registry%/*}"
    printf '%s\n' '[General]' 'StartWithLastProfile=1' >"$registry"
  fi
  printf '%s\n' "[$section]" \
    "Name=$FIREFOX_PROFILE_NAME" \
    'IsRelative=0' \
    "Path=$profile_dir" >>"$registry"
  return 0
}

launch_firefox() {
  local unit var
  unit="omarchy-apple-music-firefox-$(date +%s%N)"

  setup_firefox_profile || return 1
  ensure_bridge

  # MOZ_APP_REMOTINGNAME gives this instance its own remoting identity and
  # Wayland app_id/X11 class (melonamin.apple-music), so window rules match
  # it and a relaunch never attaches to the user's normal Firefox instance.
  # --new-window opens a dedicated window of this instance instead of a tab.
  local command=(systemd-run --user --quiet --collect --unit="$unit"
    --property=StandardOutput=null --property=StandardError=null)
  for var in "${FIREFOX_LAUNCH_ENV[@]}"; do
    command+=(--setenv="$var")
  done
  # User units receive the user manager's environment, so HOME is pinned to
  # the caller's value: the profile was registered under exactly this HOME.
  command+=(--setenv="HOME=$HOME")
  command+=(uwsm-app -- firefox -P "$FIREFOX_PROFILE_NAME" --new-window
    "--remote-debugging-port=$BIDI_PORT" "$APPLE_MUSIC_URL")

  "${command[@]}"
}

write_theme_file() {
  local background=$1 foreground=$2 border=$3 accent=$4 muted=$5 urgent=$6 mode=$7
  local revision tmp
  revision=$(date +%s%N)
  tmp=$(mktemp "$EXTENSION_DIR/.theme.XXXXXX")

  if ! jq -n \
    --arg revision "$revision" \
    --arg mode "$mode" \
    --arg background "$background" \
    --arg foreground "$foreground" \
    --arg border "$border" \
    --arg accent "$accent" \
    --arg muted "$muted" \
    --arg urgent "$urgent" \
    '{schemaVersion: 1, revision: $revision, mode: $mode, colors: {
      background: $background,
      foreground: $foreground,
      border: $border,
      accent: $accent,
      muted: $muted,
      urgent: $urgent
    }}' >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi

  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$EXTENSION_DIR/theme.json"
  printf '%s\n' "$revision"
}

prepare_extension() {
  local name entry known keep
  umask 077
  mkdir -p "$EXTENSION_DIR"
  for name in "${EXTENSION_FILES[@]}"; do
    if [[ $name == "manifest.json" ]]; then
      install -m 0644 "$ROOT/extension/$EXTENSION_MANIFEST_SOURCE" "$EXTENSION_DIR/$name"
    else
      install -m 0644 "$ROOT/extension/$name" "$EXTENSION_DIR/$name"
    fi
  done

  # Files dropped by newer plugin versions must not linger in deployed profiles.
  for entry in "$EXTENSION_DIR"/*; do
    [[ -e $entry ]] || continue
    name=${entry##*/}
    [[ $name == theme.json || $name == spectrum.json ]] && continue
    keep=false
    for known in "${EXTENSION_FILES[@]}"; do
      [[ $name == "$known" ]] && { keep=true; break; }
    done
    [[ $keep == true ]] || rm -rf -- "$entry"
  done

  if [[ ! -f $EXTENSION_DIR/theme.json ]]; then
    write_theme_file "#1f1f1f" "#f5f5f7" "#555555" "#fa586a" "#98989d" "#ff453a" "dark" >/dev/null
  fi
  if [[ ! -f $EXTENSION_DIR/spectrum.json ]]; then
    printf '{"schemaVersion":1,"active":false,"revision":0,"bands":[]}\n' >"$EXTENSION_DIR/spectrum.json"
    chmod 0600 "$EXTENSION_DIR/spectrum.json"
  fi
}

configure_profile() {
  local preferences="$PROFILE_DIR/Default/Preferences" current tmp
  umask 077
  mkdir -p "$PROFILE_DIR/Default"

  if [[ -f $preferences ]] && current=$(jq -r '.partition.default_zoom_level.x // empty' "$preferences" 2>/dev/null); then
    [[ $current == "$DEFAULT_ZOOM_LEVEL" ]] && return
    tmp=$(mktemp "$PROFILE_DIR/Default/.Preferences.XXXXXX")
    if ! jq --argjson level "$DEFAULT_ZOOM_LEVEL" '.partition.default_zoom_level.x = $level' "$preferences" >"$tmp"; then
      rm -f -- "$tmp"
      return 1
    fi
  else
    tmp=$(mktemp "$PROFILE_DIR/Default/.Preferences.XXXXXX")
    if ! jq -n --argjson level "$DEFAULT_ZOOM_LEVEL" '{partition: {default_zoom_level: {x: $level}}}' >"$tmp"; then
      rm -f -- "$tmp"
      return 1
    fi
  fi

  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$preferences"
}

publish_theme() {
  (( $# == 7 )) || { echo "usage: $0 theme <background> <foreground> <border> <accent> <muted> <urgent> <dark|light>" >&2; return 2; }
  local color
  for color in "${@:1:6}"; do
    [[ $color =~ ^#[0-9a-fA-F]{6}$ ]] || { echo "invalid theme color: $color" >&2; return 2; }
  done
  [[ $7 == "dark" || $7 == "light" ]] || { echo "invalid theme mode: $7" >&2; return 2; }

  prepare_extension
  write_theme_file "$1" "$2" "$3" "$4" "$5" "$6" "$7"

  # Firefox mode has no extension host, so the page theme is baked into the
  # dedicated profile's userContent.css on every theme publish. Best-effort:
  # the Chromium theme.json is already updated and Firefox applies the
  # stylesheet on the window's next launch either way.
  if [[ $(browser_mode) == "firefox" ]]; then
    write_firefox_user_content ||
      echo "warning: could not refresh the Firefox user content stylesheet" >&2
  fi
}

hypr_json() {
  local command=$1 output signature
  if output=$(hyprctl -j "$command" 2>/dev/null); then
    printf '%s' "$output"
    return
  fi

  signature=$(hyprctl instances -j 2>/dev/null | jq -r 'first(.[] | select(.pid > 0) | .instance) // empty')
  [[ -n $signature ]] || return 1
  HYPRLAND_INSTANCE_SIGNATURE=$signature hyprctl -j "$command"
}

hypr_call() {
  if hyprctl "$@" >/dev/null 2>&1; then
    return
  fi

  local signature
  signature=$(hyprctl instances -j 2>/dev/null | jq -r 'first(.[] | select(.pid > 0) | .instance) // empty')
  [[ -n $signature ]] || return 1
  HYPRLAND_INSTANCE_SIGNATURE=$signature hyprctl "$@" >/dev/null
}

state() {
  local clients monitors
  clients=$(hypr_json clients)
  monitors=$(hypr_json monitors)

  jq -cn \
    --arg class "$WINDOW_CLASS" \
    --arg workspace "$SPECIAL_WORKSPACE" \
    --argjson clients "$clients" \
    --argjson monitors "$monitors" \
    '(first($clients[] | select(
        ((.class // "") == $class)
        or ((.initialClass // "") == $class)
        or ((.class // "") | contains("music.apple.com__"))
        or ((.initialClass // "") | contains("music.apple.com__"))
      )) // null) as $client |
    {
      client: $client,
      monitors: $monitors,
      open: ($client != null and ($client.workspace.name // "") != $workspace),
      openScreen: (if $client != null and ($client.workspace.name // "") != $workspace
        then (first($monitors[] | select(.id == $client.monitor) | .name) // "")
        else ""
      end)
    }'
}

browser_executable() {
  command -v chromium
}

# Starts bridge.mjs (the widget's page bridge) as a user unit unless it is
# already running. Missing node degrades to MPRIS-only widget state; the
# browser launch itself must never fail because of the bridge.
ensure_bridge() {
  local unit="$BRIDGE_UNIT"
  command -v node >/dev/null || {
    echo "warning: node is required for the widget bridge; playlist and browse stay empty" >&2
    return 0
  }
  if systemctl --user is-active --quiet "$unit" 2>/dev/null; then
    return 0
  fi
  mkdir -p "$BRIDGE_DIR"
  systemd-run --user --quiet --collect --unit="$unit" \
    --property=StandardOutput=null --property=StandardError=journal \
    node "$ROOT/bridge.mjs" --port "$BIDI_PORT" --data "$DATA_DIR" --runtime "$RUNTIME_DIR" ||
    echo "warning: could not start the widget bridge" >&2
}

# Prints the Apple Music window's pid, or nothing when no such window is open.
apple_music_window_pid() {
  state | jq -r '.client.pid // empty' 2>/dev/null || true
}

# Heals a dead bridge on the next command instead of letting every command time
# out, which is what the panel showed as "the page bridge did not answer". The
# unit state is authoritative: a snapshot can still look fresh in the seconds
# after the process dies. A browser that was never launched is left alone,
# because a bridge with no port to talk to would only wait for a window that is
# not coming.
ensure_bridge_when_needed() {
  systemctl --user is-active --quiet "$BRIDGE_UNIT" 2>/dev/null && return 0
  [[ -n $(apple_music_window_pid) ]] || return 0
  ensure_bridge
}

# bridge '<json>' enqueues one bridge command and prints its reply JSON.
# Commands are consumed by bridge.mjs through $BRIDGE_COMMAND_DIR and answered
# in $BRIDGE_REPLY_DIR; this wrapper owns the envelope id so callers never
# collide. That id travels in its own `cmdId` field: `.id` inside the payload
# is a library/catalog item id (song, album, playlist) and overwriting it made
# every row click ask MusicKit to play an item that does not exist.
bridge_send() {
  local payload=${1:-} id attempt reply body
  # 400 attempts at 20 ms keeps a cold bridge (process start, session, page
  # discovery) inside the budget while a dead one fails in seconds instead of
  # hanging the panel for a quarter of a minute.
  local attempts=${OMARCHY_APPLE_MUSIC_BRIDGE_ATTEMPTS:-400}
  [[ $attempts =~ ^[1-9][0-9]*$ ]] || attempts=400
  if [[ -z $payload ]] || ! jq -e '.op | type == "string"' >/dev/null 2>&1 <<<"$payload"; then
    echo "usage: $0 bridge '{\"op\": ...}'" >&2
    return 2
  fi
  ensure_bridge_when_needed
  id="$(date +%s%N)"
  mkdir -p "$BRIDGE_COMMAND_DIR" "$BRIDGE_REPLY_DIR"
  jq -c --arg id "$id" '.cmdId = $id' <<<"$payload" >"$BRIDGE_COMMAND_DIR/cmd-$id.json" || return 1
  chmod 0600 "$BRIDGE_COMMAND_DIR/cmd-$id.json"

  for (( attempt = 0; attempt < attempts; attempt++ )); do
    reply="$BRIDGE_REPLY_DIR/reply-$id.json"
    if [[ -s $reply ]]; then
      body="$(cat "$reply")"
      rm -f -- "$reply" "$BRIDGE_COMMAND_DIR/cmd-$id.json"
      printf '%s\n' "$body"
      jq -e '.ok == true' >/dev/null 2>&1 <<<"$body" && return 0
      return 1
    fi
    sleep 0.02
  done
  rm -f -- "$BRIDGE_COMMAND_DIR/cmd-$id.json"
  printf '{"ok":false,"error":"bridge timeout"}\n'
  return 1
}

load_extension_paths() {
  local file line value paths=""
  for file in "/etc/chromium/chromium-flags.conf" "${XDG_CONFIG_HOME:-$HOME/.config}/chromium-flags.conf"; do
    [[ -f $file ]] || continue
    while IFS= read -r line; do
      if [[ $line =~ ^[[:space:]]*--load-extension=(.+)$ ]]; then
        value=${BASH_REMATCH[1]}
        value=${value#\"}
        value=${value%\"}
        value=${value#\'}
        value=${value%\'}
        paths+="${paths:+,}$value"
      fi
    done <"$file"
  done
  printf '%s%s%s\n' "$paths" "${paths:+,}" "$EXTENSION_DIR"
}

launch() {
  # Firefox is opt-in via the browser-mode marker. A missing Firefox
  # executable falls back to the default Chromium behavior; a Firefox launch
  # that fails (for example when the AppleMusic profile name is already owned
  # by the user) aborts so the browser is never silently switched.
  if use_firefox; then
    launch_firefox
    return
  fi

  local executable extension_paths unit
  executable=$(browser_executable)
  extension_paths=$(load_extension_paths)
  unit="omarchy-apple-music-$(date +%s%N)"

  prepare_extension
  configure_profile
  ensure_bridge

  systemd-run --user --quiet --collect --unit="$unit" \
    --property=StandardOutput=null --property=StandardError=null \
    uwsm-app -- "$executable" \
      --user-data-dir="$PROFILE_DIR" \
      --load-extension="$extension_paths" \
      --class="$WINDOW_CLASS" \
      --app="$APPLE_MUSIC_URL" \
      --remote-debugging-port="$BIDI_PORT" \
      --no-first-run
}

show_window() {
  local address=$1 screen=$2 x=$3 y=$4 width=$5 height=$6

  [[ $address =~ ^0x[0-9a-fA-F]+$ ]] || return 2
  [[ $screen =~ ^[[:alnum:]_.:-]+$ ]] || return 2
  [[ $x =~ ^-?[0-9]+$ && $y =~ ^-?[0-9]+$ ]] || return 2
  [[ $width =~ ^[0-9]+$ && $height =~ ^[0-9]+$ ]] || return 2

  local current workspace cursor_json cursor_x cursor_y
  cursor_json=$(hypr_json cursorpos 2>/dev/null || true)
  cursor_x=$(jq -r '(.x // empty) | floor' <<<"$cursor_json" 2>/dev/null || true)
  cursor_y=$(jq -r '(.y // empty) | floor' <<<"$cursor_json" 2>/dev/null || true)
  if [[ ! $cursor_x =~ ^-?[0-9]+$ || ! $cursor_y =~ ^-?[0-9]+$ ]]; then
    cursor_x=""
    cursor_y=""
  fi

  current=$(hypr_json monitors | jq -r --arg workspace "$SPECIAL_WORKSPACE" \
    'first(.[] | select((.specialWorkspace.name // "") == $workspace) | .name) // empty')
  workspace=$(hypr_json monitors | jq -r --arg screen "$screen" \
    'first(.[] | select(.name == $screen) | .activeWorkspace.name) // empty')
  [[ -n $workspace && $workspace != *$'\n'* && $workspace != *'"'* && $workspace != *'\\'* ]] || return 2

  # Static float rules only apply when a window is created. Reassert the
  # state here so a persistent browser client also recovers after a rule race
  # or Hyprland config reload.
  # Hyprland's Lua toggle parser calls the idempotent action "enable".
  # Unknown values fall back to "toggle", so do not use the documented
  # "set" spelling here on Hyprland 0.56.
  hypr_call dispatch "hl.dsp.window.float({ window = \"address:$address\", action = \"enable\" })"
  hypr_call dispatch "hl.dsp.window.move({ window = \"address:$address\", workspace = \"$workspace\", follow = false })"

  if [[ -n $current ]]; then
    hypr_call dispatch "hl.dsp.focus({ monitor = \"$current\" })"
    hypr_call dispatch "hl.dsp.workspace.toggle_special(\"$SPECIAL_NAME\")"
  fi

  hypr_call dispatch "hl.dsp.focus({ monitor = \"$screen\" })"
  hypr_call dispatch "hl.dsp.window.resize({ window = \"address:$address\", x = $width, y = $height, relative = false })"
  hypr_call dispatch "hl.dsp.window.move({ window = \"address:$address\", x = $x, y = $y, relative = false })"
  hypr_call dispatch "hl.dsp.focus({ window = \"address:$address\" })"

  if [[ -n $cursor_x ]]; then
    hypr_call dispatch "hl.dsp.cursor.move({ x = $cursor_x, y = $cursor_y })"
  fi
}

hide_window() {
  local address=${1:-}
  if [[ -z $address ]]; then
    address=$(state | jq -r '.client.address // empty')
  fi
  [[ $address =~ ^0x[0-9a-fA-F]+$ ]] || return
  hypr_call dispatch "hl.dsp.window.move({ window = \"address:$address\", workspace = \"$SPECIAL_WORKSPACE\", follow = false })"
}

focus_window() {
  local address=$1 cursor_json cursor_x cursor_y
  [[ $address =~ ^0x[0-9a-fA-F]+$ ]] || return 2

  cursor_json=$(hypr_json cursorpos 2>/dev/null || true)
  cursor_x=$(jq -r '(.x // empty) | floor' <<<"$cursor_json" 2>/dev/null || true)
  cursor_y=$(jq -r '(.y // empty) | floor' <<<"$cursor_json" 2>/dev/null || true)
  if [[ ! $cursor_x =~ ^-?[0-9]+$ || ! $cursor_y =~ ^-?[0-9]+$ ]]; then
    cursor_x=""
    cursor_y=""
  fi

  hypr_call dispatch "hl.dsp.focus({ window = \"address:$address\" })"
  if [[ -n $cursor_x ]]; then
    hypr_call dispatch "hl.dsp.cursor.move({ x = $cursor_x, y = $cursor_y })"
  fi
}

wait_for_theme() {
  local attempt observed=0
  for (( attempt = 0; attempt < 300; attempt++ )); do
    if pgrep -u "$UID" -f '[o]marchy-theme-set([[:space:]]|$)' >/dev/null; then
      observed=1
    elif (( observed )); then
      sleep 1
      return
    elif (( attempt >= 15 )); then
      return
    fi
    sleep 0.1
  done
  sleep 1
}

install_rules() {
  local lua_path=$1 force=${2:-false} code
  [[ -f $lua_path ]]
  code="dofile('$(printf '%s' "$lua_path" | sed "s/'/\\\\'/g")'); omarchy_apple_music.install($force)"
  hypr_call eval "$code"
}

run_spectrum() {
  local browser_pid=$1
  [[ $browser_pid =~ ^[0-9]+$ ]] || return 2
  prepare_extension
  if use_firefox; then
    # The bundled MV3 extension is Chromium-only, so nothing consumes the
    # spectrum JSON under Firefox. Publish the inactive frame instead of
    # running the analyser for an output nobody reads.
    printf '{"schemaVersion":1,"active":false,"revision":0,"bands":[]}\n' >"$EXTENSION_DIR/spectrum.json"
    return 0
  fi
  exec "$ROOT/spectrum.sh" "$browser_pid" "$EXTENSION_DIR/spectrum.json"
}

case ${1:-} in
state) state ;;
launch) launch ;;
show)
  (( $# == 7 )) || { echo "usage: $0 show <address> <screen> <x> <y> <width> <height>" >&2; exit 2; }
  show_window "$2" "$3" "$4" "$5" "$6" "$7"
  ;;
hide) hide_window "${2:-}" ;;
focus)
  (( $# == 2 )) || { echo "usage: $0 focus <address>" >&2; exit 2; }
  focus_window "$2"
  ;;
wait-theme) wait_for_theme ;;
theme)
  shift
  publish_theme "$@"
  ;;
rules)
  (( $# >= 2 )) || { echo "usage: $0 rules <lua-path> [true|false]" >&2; exit 2; }
  install_rules "$2" "${3:-false}"
  ;;
spectrum)
  (( $# == 2 )) || { echo "usage: $0 spectrum <browser-pid>" >&2; exit 2; }
  run_spectrum "$2"
  ;;
bridge)
  (( $# == 2 )) || { echo "usage: $0 bridge '<json>'" >&2; exit 2; }
  bridge_send "$2"
  ;;
bridge-state)
  if [[ -s $BRIDGE_STATE_FILE ]]; then
    cat "$BRIDGE_STATE_FILE"
  else
    printf '{"ready":false}\n'
  fi
  ;;
*)
  echo "usage: $0 <state|launch|show|hide|focus|wait-theme|theme|rules|spectrum|bridge|bridge-state>" >&2
  exit 2
  ;;
esac
