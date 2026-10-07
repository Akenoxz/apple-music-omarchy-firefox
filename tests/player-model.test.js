const test = require("node:test")
const assert = require("node:assert")
const player = require("../extension/player-model.js")

test("queue is the default view and full is preserved", () => {
  assert.equal(player.normalizeView(undefined), "queue")
  assert.equal(player.normalizeView("queue"), "queue")
  assert.equal(player.normalizeView("unexpected"), "queue")
  assert.equal(player.normalizeView("full"), "full")
})

test("MusicKit items are reduced to safe compact-player metadata", () => {
  const item = player.serializeItem({
    id: "track-1",
    attributes: {
      name: "Euclid",
      artistName: "Sleep Token",
      albumName: "Take Me Back To Eden",
      durationInMillis: 305000,
      artwork: { url: "https://example.test/{w}x{h}.{f}" }
    }
  }, 4)

  assert.deepEqual(item, {
    index: 4,
    id: "track-1",
    title: "Euclid",
    artist: "Sleep Token",
    album: "Take Me Back To Eden",
    artwork: "https://example.test/512x512.webp",
    duration: 305
  })
  assert.equal(Object.hasOwn(item, "musicUserToken"), false)

  // The live web player reports playbackDuration in milliseconds (a 6:10
  // track arrives as 369629) while older builds report seconds.
  assert.equal(player.serializeItem({ playbackDuration: 369629 }, 0).duration, 369.629)
  assert.equal(player.serializeItem({ playbackDuration: 120 }, 0).duration, 120)
})

test("player level durations are normalized to seconds", () => {
  const state = player.serializePlayer({
    playbackState: 2,
    currentPlaybackTime: 6,
    currentPlaybackDuration: 369629,
    nowPlayingItem: { id: "a", title: "Get Lucky", playbackDuration: 369629 }
  })

  assert.equal(state.duration, 369.629)
  assert.equal(state.time, 6, "position is already seconds")
  assert.equal(state.nowPlaying.duration, 369.629)
})

test("player state maps MusicKit enums and queue position", () => {
  const state = player.serializePlayer({
    playbackState: 2,
    currentPlaybackTime: 32.6,
    currentPlaybackDuration: 180,
    shuffleMode: 1,
    repeatMode: 2,
    nowPlayingItem: { id: "a", title: "Current", artistName: "Artist" },
    queue: {
      position: 0,
      items: [
        { id: "a", title: "Current", artistName: "Artist" },
        { id: "b", title: "Next", artistName: "Artist" }
      ]
    }
  })

  assert.equal(state.ready, true)
  assert.equal(state.playing, true)
  assert.equal(state.shuffle, true)
  assert.equal(state.repeat, "all")
  assert.equal(state.position, 0)
  assert.equal(state.nowPlaying.title, "Current")
  assert.deepEqual(state.queue.map(item => item.title), ["Current", "Next"])
})

test("empty and loading states stay well formed", () => {
  assert.deepEqual(player.serializePlayer(null), {
    ready: false,
    playing: false,
    loading: false,
    time: 0,
    duration: 0,
    shuffle: false,
    repeat: "none",
    position: -1,
    nowPlaying: null,
    queue: []
  })

  assert.equal(player.serializePlayer({ playbackState: 8 }).loading, true)
  assert.equal(player.formatTime(65.9), "1:05")
  assert.equal(player.formatTime(-10), "0:00")
})
