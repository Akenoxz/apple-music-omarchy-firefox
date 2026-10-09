var REPEAT_MODES = ["off", "one", "all"]

// How many rows one wheel notch (or one arrow key) moves the song list. The
// list is the only thing that scrolls — the player chrome stays put — and at a
// row a notch a hundred-song playlist takes a hundred flicks to cross. This is
// fixed rather than a setting: one speed that feels right beats a knob.
var SCROLL_ROWS = 2

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
    queueLength: number(state.queueLength, 0),
    revision: number(state.revision, 0)
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
  if (value.indexOf("artist") !== -1) return "artist"
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
    var kind = rowKind(item.type, fallbackKind)
    rows.push({
      id: id,
      kind: kind,
      name: String(item.name || "Unknown"),
      // An artist resource carries no artist/curator of its own, so it gets a
      // plain "Artist" label — the same way Apple Music tags artist results.
      subtitle: String(item.artist || item.curator || item.description || (kind === "artist" ? "Artist" : "")),
      artwork: typeof item.artwork === "string" ? item.artwork : "",
      single: item.single === true
    })
  }
  return rows
}

// The Albums sections mean albums, not singles. Apple flags most singles with
// isSingle, but not all of them — "One - Single" and "Two - Single" come back
// with the flag false — so the release title Apple gives every single is the
// reliable second signal.
function isSingleRelease(row) {
  if (!row || row.kind !== "album") return false
  if (row.single === true) return true
  return / - single$/i.test(String(row.name || ""))
}

function albumsOnly(rows) {
  return (Array.isArray(rows) ? rows : []).filter(function(row) { return !isSingleRelease(row) })
}

// An artist reply becomes the panel's artist view: the artist's identity plus
// their top songs and albums, each collapsed to the row shape the list renders.
function artistDetail(data) {
  var source = data && typeof data === "object" ? data : {}
  return {
    id: String(source.id == null ? "" : source.id),
    name: String(source.name || ""),
    artwork: typeof source.artwork === "string" ? source.artwork : "",
    songs: normalizeRows(source.songs, "song"),
    albums: albumsOnly(normalizeRows(source.albums, "album"))
  }
}

// The one-shot browse reply carries the library playlists, recently added
// albums, and catalog charts the Playlists and Browse tabs render.
function browseLists(data) {
  var groups = data && typeof data === "object" ? data : {}
  return {
    playlists: normalizeRows(groups.playlists, "playlist"),
    recent: normalizeRows(groups.recent, "album"),
    charts: normalizeRows(groups.charts, "playlist")
  }
}

// Search replies are grouped by type; drop empty groups and label the rest.
function searchSections(data) {
  var groups = data && typeof data === "object" ? data : {}
  // Artists lead, the way Apple Music's search does: looking for a performer
  // puts their profile at the top of the results instead of burying it under a
  // screenful of tracks.
  var specs = [
    { key: "artists", label: "ARTISTS", kind: "artist" },
    { key: "songs", label: "SONGS", kind: "song" },
    { key: "albums", label: "ALBUMS", kind: "album" },
    { key: "playlists", label: "PLAYLISTS", kind: "playlist" }
  ]
  var sections = []
  for (var i = 0; i < specs.length; i++) {
    var rows = normalizeRows(groups[specs[i].key], specs[i].kind)
    // The ALBUMS section shows albums only; the singles Apple mixes into a
    // search reply stay out of it.
    if (specs[i].key === "albums") rows = albumsOnly(rows)
    if (rows.length > 0) sections.push({ key: specs[i].key, label: specs[i].label, rows: rows })
  }
  return sections
}

// The song ids of a list, in order, so playing one of them can hand the page
// the whole list and keep going when the track ends instead of stopping after
// it. The chosen row is kept even if the list did not contain it.
function songQueue(rows, row) {
  var items = Array.isArray(rows) ? rows : []
  var ids = []
  for (var i = 0; i < items.length; i++) {
    var item = items[i]
    if (item && item.kind === "song" && item.id != null && item.id !== "") {
      var id = String(item.id)
      if (ids.indexOf(id) === -1) ids.push(id)
    }
  }
  var chosen = row && row.id != null ? String(row.id) : ""
  if (chosen !== "" && ids.indexOf(chosen) === -1) ids.push(chosen)
  return ids
}

// A row click either plays a song or opens the container it names. An album
// and an artist open their own view: clicking one is browsing, not a decision
// to start the first track, and the album's page is where its songs are.
function rowAction(row) {
  var kind = row && row.kind ? String(row.kind) : ""
  if (kind === "playlist") return "openPlaylist"
  if (kind === "artist") return "openArtist"
  if (kind === "album") return "openAlbum"
  return "play"
}

// One wheel event, in the pixels the song list should move. A wheel reports
// 120 angle units per notch and a touchpad reports pixel deltas; both get the
// same multiplier so the two devices feel like the same speed.
function wheelScroll(pixelDeltaY, angleDeltaY, rowHeight) {
  var precise = number(pixelDeltaY, 0)
  if (precise !== 0) return precise * SCROLL_ROWS
  var row = Math.max(1, number(rowHeight, 44))
  return (number(angleDeltaY, 0) / 120) * row * SCROLL_ROWS
}

// Which bridge command plays a row, based on its kind. `queue` describes the
// list the row was picked from: `{ ids }` for the search results it came from,
// or `{ playlist }` for a playlist the panel drilled into. Both are optional;
// a row played on its own falls back to a single-song queue.
function playCommandFor(row, queue) {
  var kind = row && row.kind === "album"
    ? "album"
    : row && row.kind === "playlist" ? "playlist" : "song"
  var id = String(row && row.id != null ? row.id : "")
  var command = {
    op: kind === "album" ? "playAlbum" : kind === "playlist" ? "playPlaylist" : "playSong",
    id: id
  }
  if (kind === "song" && queue && typeof queue === "object") {
    if (Array.isArray(queue.ids) && queue.ids.length > 1) command.ids = queue.ids
    if (queue.playlist) command.playlist = String(queue.playlist)
  }
  return command
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
    SCROLL_ROWS: SCROLL_ROWS,
    normalizeState: normalizeState,
    progress: progress,
    formatTime: formatTime,
    commandJson: commandJson,
    rowKind: rowKind,
    normalizeRows: normalizeRows,
    artistDetail: artistDetail,
    isSingleRelease: isSingleRelease,
    browseLists: browseLists,
    searchSections: searchSections,
    songQueue: songQueue,
    rowAction: rowAction,
    wheelScroll: wheelScroll,
    playCommandFor: playCommandFor,
    artworkUrl: artworkUrl,
    seekTarget: seekTarget
  }
}
