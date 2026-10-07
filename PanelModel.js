var REPEAT_MODES = ["off", "one", "all"]

function number(value, fallback) {
  var parsed = Number(value)
  return isFinite(parsed) ? parsed : fallback
}

function clamp01(value) {
  return Math.max(0, Math.min(1, number(value, 0)))
}

// MusicKit reports playbackDuration in milliseconds while the panel counts in
// seconds; bridge.mjs normalizes the state it publishes, and this guard keeps
// an older or hand-written snapshot from rendering a five-thousand-minute
// track.
function durationSeconds(value) {
  var raw = number(value, 0)
  if (raw <= 0) return 0
  return raw > 36000 ? raw / 1000 : raw
}

// bridge-state.json (or its parsed form) becomes one flat, always-complete
// view of the player. Missing fields degrade to empty/false so QML bindings
// never see undefined.
function normalizeState(raw) {
  var source = null
  if (typeof raw === "string") {
    try {
      source = JSON.parse(raw)
    } catch (error) {
      source = null
    }
  } else if (raw && typeof raw === "object") {
    source = raw
  }
  var state = source || {}

  var duration = Math.max(0, durationSeconds(state.duration))
  var position = Math.max(0, number(state.position, 0))
  if (duration > 0) position = Math.min(position, duration)

  var repeat = String(state.repeat || "off")
  if (REPEAT_MODES.indexOf(repeat) === -1) repeat = "off"

  return {
    ready: state.ready === true,
    playing: state.playing === true,
    id: String(state.id == null ? "" : state.id),
    title: String(state.title || ""),
    artist: String(state.artist || ""),
    album: String(state.album || ""),
    artwork: typeof state.artwork === "string" ? state.artwork : "",
    duration: duration,
    position: position,
    volume: clamp01(state.volume == null ? 1 : state.volume),
    shuffle: state.shuffle === true,
    repeat: repeat,
    queueIndex: number(state.queueIndex, -1),
    queueLength: number(state.queueLength, 0)
  }
}

// Fraction of the track played, for the seek bar.
function progress(state) {
  var view = normalizeState(state)
  if (view.duration <= 0) return 0
  return clamp01(view.position / view.duration)
}

function formatTime(seconds) {
  var total = Math.max(0, Math.floor(number(seconds, 0)))
  var minutes = Math.floor(total / 60)
  var rest = total % 60
  return minutes + ":" + (rest < 10 ? "0" : "") + rest
}

// One bridge command file: the op plus its arguments, nothing else.
function commandJson(op, args) {
  var payload = { op: String(op || "") }
  if (args && typeof args === "object") {
    for (var key in args) {
      if (Object.prototype.hasOwnProperty.call(args, key) && args[key] !== undefined) {
        payload[key] = args[key]
      }
    }
  }
  return JSON.stringify(payload)
}

// Map a MusicKit resource type onto the row kinds the panel knows how to play.
function rowKind(type, fallback) {
  var value = String(type || "").toLowerCase()
  if (value.indexOf("song") !== -1) return "song"
  if (value.indexOf("playlist") !== -1) return "playlist"
  if (value.indexOf("album") !== -1) return "album"
  return String(fallback || "song")
}

// Library playlists, catalog charts, and recently-added entries all collapse
// to one row shape: { id, kind, name, subtitle, artwork }.
function normalizeRows(data, fallbackKind) {
  var items = Array.isArray(data) ? data : []
  var rows = []
  for (var i = 0; i < items.length; i++) {
    var item = items[i] || {}
    var id = String(item.id == null ? "" : item.id)
    if (!id) continue
    rows.push({
      id: id,
      kind: rowKind(item.type, fallbackKind),
      name: String(item.name || "Unknown"),
      subtitle: String(item.artist || item.curator || item.description || ""),
      artwork: typeof item.artwork === "string" ? item.artwork : ""
    })
  }
  return rows
}

// Search replies are grouped by type; drop empty groups and label the rest.
function searchSections(data) {
  var groups = data && typeof data === "object" ? data : {}
  var specs = [
    { key: "songs", label: "SONGS", kind: "song" },
    { key: "albums", label: "ALBUMS", kind: "album" },
    { key: "playlists", label: "PLAYLISTS", kind: "playlist" }
  ]
  var sections = []
  for (var i = 0; i < specs.length; i++) {
    var rows = normalizeRows(groups[specs[i].key], specs[i].kind)
    if (rows.length > 0) sections.push({ key: specs[i].key, label: specs[i].label, rows: rows })
  }
  return sections
}

// Which bridge command plays a row, based on its kind.
function playCommandFor(row) {
  var kind = row && row.kind === "album"
    ? "album"
    : row && row.kind === "playlist" ? "playlist" : "song"
  return {
    op: kind === "album" ? "playAlbum" : kind === "playlist" ? "playPlaylist" : "playSong",
    id: String(row && row.id != null ? row.id : "")
  }
}

// MusicKit artwork URLs carry {w}/{h}/{f} placeholders; the panel wants
// concrete square thumbnails.
function artworkUrl(template, size) {
  var value = String(template || "")
  if (!value) return ""
  var pixels = Math.max(16, Math.round(number(size, 64)))
  return value
    .replace(/\{w\}/g, String(pixels))
    .replace(/\{h\}/g, String(pixels))
    .replace(/\{f\}/g, "webp")
}

// A drag fraction on the seek bar becomes a whole-second seek target.
function seekTarget(fraction, duration) {
  var span = Math.max(0, number(duration, 0))
  if (span <= 0) return 0
  return Math.round(clamp01(fraction) * span)
}

if (typeof module !== "undefined") {
  module.exports = {
    REPEAT_MODES: REPEAT_MODES,
    normalizeState: normalizeState,
    progress: progress,
    formatTime: formatTime,
    commandJson: commandJson,
    rowKind: rowKind,
    normalizeRows: normalizeRows,
    searchSections: searchSections,
    playCommandFor: playCommandFor,
    artworkUrl: artworkUrl,
    seekTarget: seekTarget
  }
}
