const test = require("node:test")
const assert = require("node:assert")
const M = require("../PanelModel.js")

test("missing or malformed state degrades to a complete empty view", () => {
  const view = M.normalizeState(undefined)
  assert.deepEqual(view, {
    ready: false,
    playing: false,
    id: "",
    title: "",
    artist: "",
    album: "",
    artwork: "",
    duration: 0,
    position: 0,
    volume: 1,
    shuffle: false,
    repeat: "off",
    queueIndex: -1,
    queueLength: 0,
    revision: 0
  })
  assert.deepEqual(M.normalizeState("not json"), view)
  assert.deepEqual(M.normalizeState({ ready: true, repeat: "banana" }), {
    ...view,
    ready: true,
    repeat: "off"
  })
})

test("bridge state JSON becomes the panel view", () => {
  const raw = JSON.stringify({
    ready: true,
    playing: true,
    id: "track-1",
    title: "Helena Beat",
    artist: "Foster the People",
    album: "Torches",
    artwork: "https://example.test/{w}x{h}bb.webp",
    duration: 282.5,
    position: 41.2,
    volume: 0.62,
    shuffle: true,
    repeat: "one",
    queueIndex: 2,
    queueLength: 11
  })
  const view = M.normalizeState(raw)
  assert.equal(view.ready, true)
  assert.equal(view.playing, true)
  assert.equal(view.id, "track-1")
  assert.equal(view.title, "Helena Beat")
  assert.equal(view.artwork, "https://example.test/{w}x{h}bb.webp")
  assert.equal(view.repeat, "one")
  assert.ok(Math.abs(M.progress(view) - 41.2 / 282.5) < 1e-9)
})

test("millisecond durations from an older bridge still render as track lengths", () => {
  // The panel previously showed a five-thousand-minute total because the
  // page reports milliseconds while the view counts seconds.
  const view = M.normalizeState({ ready: true, duration: 369629, position: 6 })
  assert.ok(Math.abs(view.duration - 369.629) < 1e-9)
  assert.equal(M.formatTime(view.duration), "6:09")
  assert.equal(M.formatTime(200), "3:20")
})

test("position is clamped to the duration and volume to the unit range", () => {
  const view = M.normalizeState({ ready: true, duration: 100, position: 250, volume: 3 })
  assert.equal(view.position, 100)
  assert.equal(view.volume, 1)
  assert.equal(M.normalizeState({ volume: -2 }).volume, 0)
  assert.equal(M.progress({ duration: 0, position: 4 }), 0)
})

test("time formats as m:ss without wrapping past an hour", () => {
  assert.equal(M.formatTime(0), "0:00")
  assert.equal(M.formatTime(41.2), "0:41")
  assert.equal(M.formatTime(282), "4:42")
  assert.equal(M.formatTime(3600), "60:00")
  assert.equal(M.formatTime(-5), "0:00")
  assert.equal(M.formatTime("garbage"), "0:00")
})

test("command payloads carry the op and its arguments only", () => {
  assert.equal(M.commandJson("toggle"), '{"op":"toggle"}')
  assert.equal(
    M.commandJson("seek", { position: 42 }),
    '{"op":"seek","position":42}'
  )
  assert.equal(
    M.commandJson("playPlaylist", { id: "p.123", extra: undefined }),
    '{"op":"playPlaylist","id":"p.123"}'
  )
})

test("list rows collapse playlists, charts, and recents into one shape", () => {
  const rows = M.normalizeRows([
    { id: "p.1", name: "Focus", artwork: "https://a/{w}x{h}.webp", description: "Deep cuts" },
    { id: "a.2", type: "albums", name: "Torches", artist: "Foster the People" },
    { id: "s.3", type: "songs", name: "Houdini", artist: "Dua Lipa" },
    { name: "no id drops out" },
    null
  ], "playlist")
  assert.equal(rows.length, 3)
  assert.deepEqual(rows[0], {
    id: "p.1",
    kind: "playlist",
    name: "Focus",
    subtitle: "Deep cuts",
    artwork: "https://a/{w}x{h}.webp"
  })
  assert.equal(rows[1].kind, "album")
  assert.equal(rows[1].subtitle, "Foster the People")
  assert.equal(rows[2].kind, "song")
})

test("one browse reply fills the playlists and browse tabs", () => {
  const lists = M.browseLists({
    playlists: [{ id: "p.1", type: "library-playlists", name: "Chill" }],
    recent: [{ id: "a.1", type: "albums", name: "Album", artist: "A" }],
    charts: [{ id: "pl.1", type: "playlists", name: "Chart" }]
  })
  assert.deepEqual(lists.playlists.map((row) => [row.id, row.kind]), [["p.1", "playlist"]])
  assert.deepEqual(lists.recent.map((row) => [row.id, row.kind]), [["a.1", "album"]])
  assert.deepEqual(lists.charts.map((row) => [row.id, row.kind]), [["pl.1", "playlist"]])
  assert.deepEqual(M.browseLists(undefined), { playlists: [], recent: [], charts: [] })
})

test("search groups become labelled sections with empty groups dropped", () => {
  const sections = M.searchSections({
    songs: [{ id: "s.1", name: "Houdini", artist: "Dua Lipa" }],
    albums: [],
    playlists: [{ id: "p.9", name: "Pop", curator: "Apple Music" }]
  })
  assert.deepEqual(sections.map(s => [s.key, s.label, s.rows.length]), [
    ["songs", "SONGS", 1],
    ["playlists", "PLAYLISTS", 1]
  ])
  assert.deepEqual(M.searchSections(null), [])
})

test("search results lead with artists, then songs", () => {
  const sections = M.searchSections({
    songs: [{ id: "s.1", name: "Song", artist: "A" }],
    artists: [{ id: "ar.1", type: "artists", name: "Artist One" }],
    albums: [],
    playlists: []
  })
  assert.deepEqual(sections.map((s) => [s.key, s.label, s.rows[0].kind]), [
    ["artists", "ARTISTS", "artist"],
    ["songs", "SONGS", "song"]
  ])
})

test("an artist row is labelled as an artist", () => {
  const [row] = M.normalizeRows([{ id: "ar.1", type: "artists", name: "Artist One" }], "song")
  assert.equal(row.kind, "artist")
  assert.equal(row.subtitle, "Artist")
})

test("an artist reply becomes the profile view's sections", () => {
  const view = M.artistDetail({
    id: "ar.1",
    name: "Artist One",
    artwork: "https://a/{w}x{h}.webp",
    songs: [{ id: "s.1", type: "songs", name: "Hit", artist: "Artist One" }],
    albums: [{ id: "a.1", type: "albums", name: "Album", artist: "Artist One" }]
  })
  assert.equal(view.id, "ar.1")
  assert.equal(view.name, "Artist One")
  assert.equal(view.songs[0].kind, "song")
  assert.equal(view.albums[0].kind, "album")
  assert.equal(view.albums[0].subtitle, "Artist One")
  assert.deepEqual(M.artistDetail(null), { id: "", name: "", artwork: "", songs: [], albums: [] })
})

test("rows map to the bridge command that plays them", () => {
  assert.deepEqual(M.playCommandFor({ kind: "song", id: "s.1" }), { op: "playSong", id: "s.1" })
  assert.deepEqual(M.playCommandFor({ kind: "album", id: "a.1" }), { op: "playAlbum", id: "a.1" })
  assert.deepEqual(M.playCommandFor({ kind: "playlist", id: "p.1" }), { op: "playPlaylist", id: "p.1" })
  assert.deepEqual(M.playCommandFor(null), { op: "playSong", id: "" })
})

test("a song picked from a list carries its queue so playback continues", () => {
  // A song started from the search results queues the other results too, so
  // the next one follows when it ends instead of stopping after one track.
  assert.deepEqual(
    M.playCommandFor({ kind: "song", id: "s.2" }, { ids: ["s.1", "s.2", "s.3"] }),
    { op: "playSong", id: "s.2", ids: ["s.1", "s.2", "s.3"] }
  )
  // A song picked inside a playlist replays the playlist from that track.
  assert.deepEqual(
    M.playCommandFor({ kind: "song", id: "s.9" }, { playlist: "p.1" }),
    { op: "playSong", id: "s.9", playlist: "p.1" }
  )
  // A lone song stays a single-song command; no queue fields leak in.
  assert.deepEqual(
    M.playCommandFor({ kind: "song", id: "s.1" }, { ids: ["s.1"] }),
    { op: "playSong", id: "s.1" }
  )
})

test("a song queue lists the song ids in order and keeps the chosen row", () => {
  const rows = [
    { kind: "song", id: "s.1" },
    { kind: "album", id: "a.1" },
    { kind: "song", id: "s.2" },
    { kind: "song", id: "s.2" }
  ]
  assert.deepEqual(M.songQueue(rows, rows[0]), ["s.1", "s.2"])
  // A row that is not in the list is still appended so it can play.
  assert.deepEqual(M.songQueue([{ kind: "song", id: "s.1" }], { kind: "song", id: "s.9" }), ["s.1", "s.9"])
  assert.deepEqual(M.songQueue(null, { kind: "song", id: "s.1" }), ["s.1"])
})

test("artwork templates become concrete square thumbnails", () => {
  assert.equal(
    M.artworkUrl("https://img.test/{w}x{h}bb.{f}.jpg", 64),
    "https://img.test/64x64bb.webp.jpg"
  )
  assert.equal(M.artworkUrl("", 64), "")
  assert.equal(M.artworkUrl(null, 64), "")
  // No placeholders is a pass-through.
  assert.equal(M.artworkUrl("https://img.test/a.webp", 64), "https://img.test/a.webp")
})

test("seek targets round a drag fraction to whole seconds", () => {
  assert.equal(M.seekTarget(0.5, 200), 100)
  assert.equal(M.seekTarget(0.333, 9), 3)
  assert.equal(M.seekTarget(2, 100), 100)
  assert.equal(M.seekTarget(0.5, 0), 0)
})
