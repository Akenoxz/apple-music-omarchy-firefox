#!/usr/bin/env node
// omarchy-apple-music bridge: talks to the dedicated browser window through
// WebDriver BiDi (the protocol Firefox ships on --remote-debugging-port, and
// which Chromium serves on the same port) and turns the signed-in Apple Music
// page into a data/command backend for the Omarchy widget.
//
// Layout:
//   $runtime/bridge/state.json       latest player state (atomic rewrite)
//   $runtime/bridge/replies/<id>.json  result of a completed command
//   $data/bridge-commands/<id>.json    command drop folder (consumed here)
//
// The bridge never throws into the page: every evaluated expression returns a
// JSON string so protocol-level serialization cannot corrupt the payload.
//
// Session lifecycle: Firefox allows a single BiDi session and does not reap it
// when the socket dies (bug 1720707). Graceful shutdown ends the session; a
// restarted bridge first tries to end the session it saved to disk.

import { watch, readdir, readFile, writeFile, rename, mkdir, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import process from "node:process";

const args = process.argv.slice(2);
function arg(name, fallback) {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] !== undefined ? args[i + 1] : fallback;
}

const PORT = Number(arg("port", "62229"));
const DATA_DIR = arg("data", join(process.env.HOME ?? "", ".local/share/omarchy-apple-music"));
const RUNTIME_DIR = arg("runtime", join(process.env.XDG_RUNTIME_DIR ?? DATA_DIR, "omarchy-apple-music"));
const INTERVAL = Number(arg("interval", "750"));
const COMMAND_DIR = join(DATA_DIR, "bridge-commands");
const BRIDGE_DIR = join(RUNTIME_DIR, "bridge");
const REPLY_DIR = join(BRIDGE_DIR, "replies");
const STATE_FILE = join(BRIDGE_DIR, "state.json");
const SESSION_FILE = join(BRIDGE_DIR, "session-id");

const WS_URL = `ws://127.0.0.1:${PORT}/session`;

// ---------------------------------------------------------------------------
// BiDi client
// ---------------------------------------------------------------------------

class BidiClient {
  #ws = null;
  #nextId = 1;
  #pending = new Map();

  connect() {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(WS_URL);
      this.#ws = ws;
      const onError = () => reject(new Error(`cannot connect to ${WS_URL}`));
      ws.onopen = () => {
        ws.onerror = () => {};
        resolve();
      };
      ws.onerror = onError;
      ws.onmessage = (ev) => this.#onMessage(String(ev.data));
      ws.onclose = () => {
        for (const { reject: rej } of this.#pending.values()) {
          rej(new Error("bridge: bi-directional connection closed"));
        }
        this.#pending.clear();
      };
    });
  }

  #onMessage(raw) {
    let message;
    try {
      message = JSON.parse(raw);
    } catch {
      return;
    }
    if (message.id === undefined || !this.#pending.has(message.id)) return;
    const { resolve, reject, timer } = this.#pending.get(message.id);
    this.#pending.delete(message.id);
    clearTimeout(timer);
    if (message.type === "error" || message.error) {
      const error = new Error(message.message || message.error || "bi-di error");
      error.code = message.error;
      reject(error);
    } else {
      resolve(message.result ?? {});
    }
  }

  send(method, params = {}, timeoutMs = 15000) {
    const id = this.#nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error(`bridge: timeout waiting for ${method}`));
      }, timeoutMs);
      this.#pending.set(id, { resolve, reject, timer });
      this.#ws.send(JSON.stringify({ id, method, params }));
    });
  }

  get open() {
    return this.#ws !== null && this.#ws.readyState === WebSocket.OPEN;
  }

  close() {
    try {
      this.#ws?.close();
    } catch {
      /* already gone */
    }
    this.#ws = null;
  }
}

// ---------------------------------------------------------------------------
// Page expressions. Every expression returns a JSON string (never an object)
// so CDP/BiDi serialization cannot mangle the payload.
// ---------------------------------------------------------------------------

const STATE_EXPRESSION = `(() => {
  try {
    const mk = window.MusicKit;
    const i = mk && typeof mk.getInstance === "function" ? mk.getInstance() : null;
    if (!i) return JSON.stringify({ ready: false });
    const item = i.nowPlayingItem;
    const queue = i.queue || {};
    return JSON.stringify({
      ready: true,
      playbackState: i.playbackState,
      playing: i.playbackState === 2,
      id: (item && item.id) || null,
      title: (item && item.title) || null,
      artist: (item && item.artistName) || null,
      album: (item && item.albumName) || null,
      artwork: (item && item.artworkURL) || null,
      duration: (item && item.playbackDuration) || null,
      durationInMillis: (item && item.durationInMillis) || null,
      position: typeof i.currentPlaybackTime === "number" ? i.currentPlaybackTime : null,
      volume: typeof i.volume === "number" ? i.volume : null,
      shuffle: i.shuffleMode === 1,
      repeat: i.repeatMode === 0 ? "off" : i.repeatMode === 1 ? "one" : "all",
      queueIndex: typeof i.indexOfNowPlayingItem === "number" ? i.indexOfNowPlayingItem : null,
      queueLength: Array.isArray(queue.items) ? queue.items.length : null
    });
  } catch (e) {
    return JSON.stringify({ ready: false, error: String((e && e.message) || e) });
  }
})()`;

const COMMAND_EXPRESSIONS = {
  play: `MusicKit.getInstance().play()`,
  pause: `MusicKit.getInstance().pause()`,
  toggle: `(() => { const i = MusicKit.getInstance(); return i.playbackState === 2 ? i.pause() : i.play(); })()`,
  next: `MusicKit.getInstance().skipToNextItem()`,
  previous: `MusicKit.getInstance().skipToPreviousItem()`,
  seek: `MusicKit.getInstance().seekToTime(ARGS.position)`,
  volume: `MusicKit.getInstance().volume = ARGS.volume`,
  shuffle: `MusicKit.getInstance().shuffleMode = ARGS.on ? 1 : 0`,
  repeat: `MusicKit.getInstance().repeatMode = ARGS.mode === "one" ? 1 : ARGS.mode === "all" ? 2 : 0`,
  // Queue builders accept library and catalog identifiers; MusicKit resolves
  // them. Play through the singleton once the queue is in place: setQueue's
  // resolved value is not the player in every MusicKit build, and calling
  // play() on it silently left the queue set but nothing playing.
  playPlaylist: `(async () => { const i = MusicKit.getInstance(); await i.setQueue({ playlist: ARGS.id }); return i.play(); })()`,
  playAlbum: `(async () => { const i = MusicKit.getInstance(); await i.setQueue({ album: ARGS.id }); return i.play(); })()`,
  playSong: `(async () => { const i = MusicKit.getInstance(); await i.setQueue({ song: ARGS.id, startWith: 0 }); return i.play(); })()`,
};

// The modern MusicKit instance only exposes the raw REST client
// (instance.api.get); the old convenience API (MusicKit.api.library/… ) is
// gone. Query parameters must go in the URL string — api.get does not
// serialize its params argument — and the parsed body comes back as
// response.json. A non-2xx body carries an errors[] array; surfacing its
// message keeps panel failures legible. Every list collapses API resources
// to the one row shape the panel model knows: { id, type, name, artist,
// artwork, description }.
const LIST_HELPERS = `
  const api = MusicKit.getInstance().api;
  const fetchJson = async (url) => {
    const r = await api.get(url);
    const b = (r && r.json) || {};
    if (r && r.status >= 400) {
      throw new Error((b.errors && b.errors[0] && (b.errors[0].detail || b.errors[0].title)) || ("request failed (" + r.status + ")"));
    }
    return b;
  };
  const mapRow = (p) => ({
    id: p.id,
    type: p.type,
    name: (p.attributes && p.attributes.name) || "",
    artist: (p.attributes && (p.attributes.artistName || p.attributes.curatorName)) || null,
    artwork: (p.attributes && p.attributes.artwork && p.attributes.artwork.url) || null,
    description: (p.attributes && p.attributes.description && p.attributes.description.standard) || ""
  });`;

const LIST_EXPRESSIONS = {
  playlists: `(async () => {${LIST_HELPERS}
    const b = await fetchJson("/v1/me/library/playlists?limit=" + (ARGS.limit || 100));
    return (b.data || []).map(mapRow);
  })()`,
  recentlyAdded: `(async () => {${LIST_HELPERS}
    const b = await fetchJson("/v1/me/library/recently-added?limit=" + (ARGS.limit || 12));
    return (b.data || []).map(mapRow);
  })()`,
  charts: `(async () => {${LIST_HELPERS}
    const sf = MusicKit.getInstance().storefrontId || "us";
    const b = await fetchJson("/v1/catalog/" + sf + "/charts?types=playlists&limit=" + (ARGS.limit || 12));
    const groups = (b.results && b.results.playlists) || [];
    return groups.flatMap((g) => (g.data || []).map(mapRow));
  })()`,
  search: `(async () => {${LIST_HELPERS}
    const sf = MusicKit.getInstance().storefrontId || "us";
    const term = ARGS.term || "";
    const b = await fetchJson("/v1/catalog/" + sf + "/search?term=" + encodeURIComponent(term) + "&types=songs,albums,playlists&limit=" + (ARGS.limit || 20));
    const res = b.results || {};
    const map = (g) => ((g && g.data) || []).map(mapRow);
    return { songs: map(res.songs), albums: map(res.albums), playlists: map(res.playlists) };
  })()`,
};

function buildExpression(template, args) {
  // ARGS.x is replaced with the literal JSON value, so the evaluated page
  // expression reads like handwritten code (e.g. seekToTime(42)).
  return template.replace(/ARGS\.([a-zA-Z]+)/g, (_, key) => JSON.stringify(args?.[key] ?? null));
}

function wrapSafe(expression, list) {
  // Commands and lists return promises; state is synchronous. All of them are
  // wrapped so a page-side failure becomes a JSON error instead of an
  // exception the protocol reports in its own shape.
  if (list) {
    return `(async () => { try { return JSON.stringify({ ok: true, data: await (${expression}) }); } catch (e) { return JSON.stringify({ ok: false, error: String((e && e.message) || e) }); } })()`;
  }
  return `(async () => { try { await (${expression}); return JSON.stringify({ ok: true }); } catch (e) { return JSON.stringify({ ok: false, error: String((e && e.message) || e) }); } })()`;
}

// ---------------------------------------------------------------------------
// Bridge loop
// ---------------------------------------------------------------------------

async function atomicWrite(file, contents) {
  const tmp = `${file}.tmp-${process.pid}`;
  await writeFile(tmp, contents, { mode: 0o600 });
  await rename(tmp, file);
}

// MusicKit's web player reports playbackDuration in milliseconds while the
// panel and the injected player count in seconds; some builds and library
// items only carry durationInMillis, which is milliseconds by definition.
// currentPlaybackTime is seconds either way, so it is left alone.
function seconds(value, assumeMillis) {
  const raw = Number(value);
  if (!Number.isFinite(raw) || raw <= 0) return null;
  return assumeMillis || raw > 36000 ? raw / 1000 : raw;
}

function normalizeState(state) {
  if (!state || typeof state !== "object" || state.ready !== true) return state;
  const duration = seconds(state.duration) ?? seconds(state.durationInMillis, true);
  if (duration !== null) state.duration = duration;
  delete state.durationInMillis;
  return state;
}

async function evaluate(bidi, context, expression, timeoutMs = 15000) {
  const result = await bidi.send(
    "script.evaluate",
    {
      expression,
      target: { context },
      awaitPromise: true,
      resultOwnership: "none",
    },
    timeoutMs
  );
  const value = result?.result?.value;
  return typeof value === "string" ? value : JSON.stringify({ ok: false, error: "empty evaluation result" });
}

async function findMusicContext(bidi) {
  const tree = await bidi.send("browsingContext.getTree", {}, 8000);
  const contexts = tree?.contexts ?? [];
  const match =
    contexts.find((c) => (c.url || "").includes("music.apple.com")) ??
    contexts.find((c) => (c.url || "").startsWith("https://music.apple.com")) ??
    null;
  return match ? match.context : null;
}

async function startSession(bidi) {
  // The bridge is started before the browser launch (control.sh starts it
  // ahead of the window), so the first connection races the BiDi port
  // opening. Keep retrying for the same budget as the page wait below.
  const deadline = Date.now() + 120000;
  for (;;) {
    try {
      await bidi.connect();
      break;
    } catch (error) {
      if (Date.now() >= deadline) throw error;
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
  }
  try {
    const status = await bidi.send("session.status", {}, 5000);
    if (status.ready === false && /already started|maximum/i.test(status.message || "")) {
      await tryRecoverSession();
    }
  } catch {
    /* some builds answer status with an error when idle; try session.new below */
  }
  const created = await bidi.send("session.new", {
    capabilities: { alwaysMatch: { webSocketUrl: true } },
  });
  if (created.sessionId) {
    await atomicWrite(SESSION_FILE, created.sessionId);
  }
  return created.sessionId;
}

// Firefox keeps a session alive after an unclean disconnect. If the bridge
// saved its session id, reconnect to that session's own path and end it.
async function tryRecoverSession() {
  if (!existsSync(SESSION_FILE)) return false;
  let sessionId = "";
  try {
    sessionId = (await readFile(SESSION_FILE, "utf8")).trim();
  } catch {
    return false;
  }
  if (!sessionId) return false;
  return await new Promise((resolve) => {
    let settled = false;
    const done = (value) => {
      if (!settled) {
        settled = true;
        resolve(value);
      }
    };
    let ws;
    try {
      ws = new WebSocket(`ws://127.0.0.1:${PORT}/session/${sessionId}`);
    } catch {
      resolve(false);
      return;
    }
    ws.onopen = () => {
      ws.send(JSON.stringify({ id: 1, method: "session.end", params: {} }));
    };
    ws.onmessage = () => {
      try {
        ws.close();
      } catch {
        /* ignore */
      }
      done(true);
    };
    ws.onerror = () => done(false);
    setTimeout(() => done(false), 4000);
  });
}

async function handleCommand(bidi, context, file) {
  const fullPath = join(COMMAND_DIR, file);
  let command;
  try {
    command = JSON.parse(await readFile(fullPath, "utf8"));
  } catch {
    await rm(fullPath, { force: true });
    return;
  }
  // The envelope id from control.sh lives in `cmdId`; `.id` is a payload
  // field (the library/catalog item a row click asked to play). Older
  // callers that only set `id` keep working through the fallback.
  const envelopeId = command.cmdId ?? command.id ?? file;
  const reply = { id: envelopeId, ok: false };
  try {
    if (COMMAND_EXPRESSIONS[command.op]) {
      const expression = buildExpression(COMMAND_EXPRESSIONS[command.op], command);
      const raw = await evaluate(bidi, context, wrapSafe(expression, false));
      const parsed = JSON.parse(raw);
      reply.ok = parsed.ok === true;
      if (!parsed.ok) reply.error = parsed.error;
    } else if (LIST_EXPRESSIONS[command.op]) {
      const expression = buildExpression(LIST_EXPRESSIONS[command.op], command);
      const raw = await evaluate(bidi, context, wrapSafe(expression, true), 20000);
      const parsed = JSON.parse(raw);
      reply.ok = parsed.ok === true;
      reply.data = parsed.data ?? null;
      if (!parsed.ok) reply.error = parsed.error;
    } else {
      reply.error = `unknown op: ${command.op}`;
    }
  } catch (e) {
    reply.error = String((e && e.message) || e);
  }
  await atomicWrite(join(REPLY_DIR, `reply-${reply.id}.json`), JSON.stringify(reply));
  await rm(fullPath, { force: true });
}

async function main() {
  await mkdir(COMMAND_DIR, { recursive: true });
  await mkdir(REPLY_DIR, { recursive: true });
  await mkdir(BRIDGE_DIR, { recursive: true });

  const bidi = new BidiClient();
  await startSession(bidi);

  // Wait for the Apple Music page; navigation and cold loads take a while.
  let context = null;
  for (let attempt = 0; attempt < 120 && context === null; attempt++) {
    try {
      context = await findMusicContext(bidi);
    } catch {
      context = null;
    }
    if (context === null) await new Promise((r) => setTimeout(r, 1000));
  }
  if (context === null) {
    console.error("bridge: no music.apple.com page appeared");
    process.exit(1);
  }

  let stopping = false;
  const stop = async (code) => {
    if (stopping) return;
    stopping = true;
    try {
      await bidi.send("session.end", {}, 3000);
    } catch {
      /* session may already be gone */
    }
    bidi.close();
    await rm(SESSION_FILE, { force: true });
    process.exit(code);
  };
  process.on("SIGTERM", () => stop(0));
  process.on("SIGINT", () => stop(0));

  // Commands arrive through the drop folder; polling beats inotify here
  // because the directory survives plugin updates and user inspection.
  let commandsBusy = false;
  setInterval(async () => {
    if (stopping || commandsBusy) return;
    commandsBusy = true;
    try {
      const files = await readdir(COMMAND_DIR);
      for (const file of files.filter((f) => f.endsWith(".json")).sort()) {
        await handleCommand(bidi, context, file);
      }
    } catch {
      /* transient directory races are fine */
    } finally {
      commandsBusy = false;
    }
  }, 150);

  // State poll: a single evaluate per tick keeps the page idle most of the
  // time while the panel still sees near-live position updates.
  let stateBusy = false;
  setInterval(async () => {
    if (stopping || stateBusy) return;
    stateBusy = true;
    try {
      const raw = await evaluate(bidi, context, STATE_EXPRESSION);
      const parsed = normalizeState(JSON.parse(raw));
      parsed.revision = Date.now();
      await atomicWrite(STATE_FILE, JSON.stringify(parsed));
    } catch {
      /* a navigation swaps contexts; rediscover on the next tick */
      try {
        const next = await findMusicContext(bidi);
        if (next) context = next;
      } catch {
        /* keep trying */
      }
    } finally {
      stateBusy = false;
    }
  }, INTERVAL);
}

main().catch((error) => {
  console.error("bridge:", String((error && error.message) || error));
  process.exit(1);
});
