// Behavior tests for bridge.mjs against a fake WebDriver BiDi server.
// The fake server speaks real WebSocket framing (hand rolled, zero deps) and
// emulates the three things the bridge relies on: session lifecycle, target
// discovery, and script.evaluate returning JSON strings from the page.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, writeFile, readFile, rm, readdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import http from "node:http";
import crypto from "node:crypto";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const BRIDGE = join(ROOT, "bridge.mjs");

const CANNED_STATE = {
  ready: true,
  playbackState: 2,
  playing: true,
  title: "Test Track",
  artist: "Test Artist",
  album: "Test Album",
  artwork: "https://example.test/art.jpg",
  duration: 200,
  position: 10,
  volume: 0.5,
  shuffle: false,
  repeat: "off",
  queueIndex: 0,
  queueLength: 3,
};

const CANNED_PLAYLISTS = [
  { id: "p.1", type: "library-playlists", name: "Chill", artist: null, artwork: null, description: "" },
  { id: "p.2", type: "library-playlists", name: "Focus", artist: null, artwork: "https://example.test/f.jpg", description: "d" },
];

const CANNED_TRACKS = [
  { id: "s.1", type: "library-songs", name: "Track One", artist: "A", artwork: null, description: "" },
  { id: "s.2", type: "library-songs", name: "Track Two", artist: "B", artwork: null, description: "" },
];

const CANNED_ARTIST = {
  id: "ar.1",
  name: "Artist One",
  artwork: "https://example.test/artist.jpg",
  songs: [{ id: "s.9", type: "songs", name: "Hit", artist: "Artist One", artwork: null }],
  albums: [{ id: "a.9", type: "albums", name: "Album", artist: "Artist One", artwork: null }],
};

// --- minimal WebSocket server (RFC 6455 text frames) -------------------------

function encodeText(str) {
  const payload = Buffer.from(str, "utf8");
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.from([0x81, len]);
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  return Buffer.concat([header, payload]);
}

class FrameParser {
  constructor() {
    this.buf = Buffer.alloc(0);
  }

  push(chunk) {
    this.buf = Buffer.concat([this.buf, chunk]);
    const out = [];
    for (;;) {
      const b = this.buf;
      if (b.length < 2) break;
      const opcode = b[0] & 0x0f;
      const masked = (b[1] & 0x80) !== 0;
      let len = b[1] & 0x7f;
      let offset = 2;
      if (len === 126) {
        if (b.length < 4) break;
        len = b.readUInt16BE(2);
        offset = 4;
      } else if (len === 127) {
        if (b.length < 10) break;
        len = Number(b.readBigUInt64BE(2));
        offset = 10;
      }
      const maskLen = masked ? 4 : 0;
      if (b.length < offset + maskLen + len) break;
      let payload = Buffer.from(b.subarray(offset + maskLen, offset + maskLen + len));
      if (masked) {
        const mask = b.subarray(offset, offset + 4);
        for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
      }
      out.push({ opcode, payload: payload.toString("utf8") });
      this.buf = b.subarray(offset + maskLen + len);
    }
    return out;
  }
}

// Fake BiDi server: records every request, serves canned page data.
function startFakeBidi({ occupied = false, port = 0, pageState = CANNED_STATE } = {}) {
  const state = {
    occupied,
    endedSessions: [],
    paths: [],
    evaluations: [],
    methods: [],
  };

  const server = http.createServer();
  server.on("upgrade", (req, socket) => {
    const key = req.headers["sec-websocket-key"];
    const accept = crypto
      .createHash("sha1")
      .update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
      .digest("base64");
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
    );
    state.paths.push(req.url);
    const parser = new FrameParser();
    const reply = (obj) => {
      try {
        socket.write(encodeText(JSON.stringify(obj)));
      } catch {
        /* socket gone */
      }
    };
    socket.on("data", (chunk) => {
      for (const frame of parser.push(chunk)) {
        if (frame.opcode !== 1) continue;
        let message;
        try {
          message = JSON.parse(frame.payload);
        } catch {
          continue;
        }
        const { id, method, params } = message;
        state.methods.push({ method, path: req.url });
        const ok = (result) => reply({ type: "success", id, result });
        const fail = (error, msg) => reply({ type: "error", id, error, message: msg });

        switch (method) {
          case "session.status":
            ok(state.occupied ? { ready: false, message: "Session already started" } : { ready: true });
            break;
          case "session.new":
            if (state.occupied) {
              fail("session not created", "Maximum number of active sessions");
            } else {
              state.occupied = true;
              ok({ sessionId: "fake-session-1", capabilities: {} });
            }
            break;
          case "session.end":
            state.endedSessions.push(req.url);
            state.occupied = false;
            ok({});
            break;
          case "browsingContext.getTree":
            ok({
              contexts: [{ context: "ctx-1", url: "https://music.apple.com/fi/home", children: [] }],
            });
            break;
          case "script.evaluate": {
            const expression = params.expression || "";
            state.evaluations.push(expression);
            let value;
            if (expression.includes("nowPlayingItem")) {
              value = JSON.stringify(pageState);
            } else if (expression.includes("/view/top-songs") || expression.includes("/artists/")) {
              value = JSON.stringify({ ok: true, data: CANNED_ARTIST });
            } else if (expression.includes("recently-added") && expression.includes("charts")) {
              // The one-shot browse load asks for all three groups at once.
              value = JSON.stringify({
                ok: true,
                data: { playlists: CANNED_PLAYLISTS, recent: CANNED_PLAYLISTS, charts: [] },
              });
            } else if (expression.includes("/tracks") || expression.includes("?include=tracks")) {
              // Playlist and album track lists are a separate list; keep this
              // ahead of the playlists branch, whose URL the tracks request
              // also contains.
              value = JSON.stringify({ ok: true, data: CANNED_TRACKS });
            } else if (expression.includes("/v1/me/library/playlists")) {
              value = JSON.stringify({ ok: true, data: CANNED_PLAYLISTS });
            } else if (expression.includes("/search?")) {
              value = JSON.stringify({
                ok: true,
                data: {
                  songs: [{ id: "s.1", type: "songs", name: "Song", artist: "A", artwork: null }],
                  artists: [{ id: "ar.1", type: "artists", name: "Artist One", artwork: null }],
                  albums: [],
                  playlists: [],
                },
              });
            } else {
              value = JSON.stringify({ ok: true });
            }
            ok({ type: "success", result: { type: "string", value } });
            break;
          }
          default:
            fail("unknown command", `unsupported method ${method}`);
        }
      }
    });
    socket.on("error", () => {});
  });

  return new Promise((resolve) => {
    server.listen(port, "127.0.0.1", () => {
      resolve({ server, state, port: server.address().port });
    });
  });
}

// --- helpers -----------------------------------------------------------------

async function waitFor(fn, timeoutMs = 8000, intervalMs = 50) {
  const start = Date.now();
  for (;;) {
    try {
      const value = await fn();
      if (value) return value;
    } catch {
      /* not yet */
    }
    if (Date.now() - start > timeoutMs) throw new Error("waitFor timed out");
    await new Promise((r) => setTimeout(r, intervalMs));
  }
}

async function readJsonIf(file) {
  if (!existsSync(file)) return null;
  try {
    return JSON.parse(await readFile(file, "utf8"));
  } catch {
    return null;
  }
}

function launchBridge({ port, dataDir, runtimeDir, env }) {
  return spawn(
    process.execPath,
    [BRIDGE, "--port", String(port), "--data", dataDir, "--runtime", runtimeDir, "--interval", "50"],
    { stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, ...env } }
  );
}

function waitForExit(child, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("child did not exit")), timeoutMs);
    child.once("exit", (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal });
    });
  });
}

async function makeDirs() {
  const base = await mkdtemp(join(tmpdir(), "am-bridge-"));
  const dataDir = join(base, "data");
  const runtimeDir = join(base, "runtime");
  await mkdir(join(dataDir, "bridge-commands"), { recursive: true });
  await mkdir(join(runtimeDir, "bridge", "replies"), { recursive: true });
  return { base, dataDir, runtimeDir };
}

// --- tests -------------------------------------------------------------------

test("bridge polls page state and answers commands with replies", async () => {
  const fake = await startFakeBidi();
  const { base, dataDir, runtimeDir } = await makeDirs();
  const child = launchBridge({ port: fake.port, dataDir, runtimeDir });
  try {
    const stateFile = join(runtimeDir, "bridge", "state.json");
    const state = await waitFor(async () => {
      const parsed = await readJsonIf(stateFile);
      return parsed && parsed.ready ? parsed : null;
    });
    assert.equal(state.title, "Test Track");
    assert.equal(state.artist, "Test Artist");
    assert.equal(state.playing, true);
    assert.equal(state.duration, 200);
    assert.ok(Number.isInteger(state.revision), "state carries a revision");

    // toggle
    await writeFile(
      join(dataDir, "bridge-commands", "cmd-c1.json"),
      JSON.stringify({ id: "c1", op: "toggle" })
    );
    const reply1 = await waitFor(() => readJsonIf(join(runtimeDir, "bridge", "replies", "reply-c1.json")));
    assert.equal(reply1.ok, true);
    assert.ok(
      fake.state.evaluations.some((e) => e.includes("playbackState") && e.includes("play()")),
      "toggle evaluated playback state in the page"
    );

    // playlists
    await writeFile(
      join(dataDir, "bridge-commands", "cmd-c2.json"),
      JSON.stringify({ id: "c2", op: "playlists", limit: 50 })
    );
    const reply2 = await waitFor(() => readJsonIf(join(runtimeDir, "bridge", "replies", "reply-c2.json")));
    assert.equal(reply2.ok, true);
    assert.deepEqual(reply2.data, CANNED_PLAYLISTS);
    assert.ok(fake.state.evaluations.some((e) => e.includes("/v1/me/library/playlists")));

    // seek with argument substitution
    await writeFile(
      join(dataDir, "bridge-commands", "cmd-c3.json"),
      JSON.stringify({ id: "c3", op: "seek", position: 42 })
    );
    const reply3 = await waitFor(() => readJsonIf(join(runtimeDir, "bridge", "replies", "reply-c3.json")));
    assert.equal(reply3.ok, true);
    assert.ok(fake.state.evaluations.some((e) => e.includes("seekToTime(42)")), "position substituted");

    // unknown op
    await writeFile(
      join(dataDir, "bridge-commands", "cmd-c4.json"),
      JSON.stringify({ id: "c4", op: "explode" })
    );
    const reply4 = await waitFor(() => readJsonIf(join(runtimeDir, "bridge", "replies", "reply-c4.json")));
    assert.equal(reply4.ok, false);
    assert.match(reply4.error, /unknown op/);

    // graceful shutdown ends the session and clears the saved id
    assert.ok(existsSync(join(runtimeDir, "bridge", "session-id")), "session id saved while running");
    child.kill("SIGTERM");
    const { code } = await waitForExit(child);
    assert.equal(code, 0, "bridge exits cleanly on SIGTERM");
    assert.ok(
      fake.state.endedSessions.some((p) => p.includes("session")),
      "session.end was sent"
    );
    assert.ok(!existsSync(join(runtimeDir, "bridge", "session-id")), "session id removed on shutdown");
  } finally {
    try {
      child.kill("SIGKILL");
    } catch {
      /* already gone */
    }
    fake.server.close();
    await rm(base, { recursive: true, force: true });
  }
});

test("bridge ends its own zombie session before creating a new one", async () => {
  const fake = await startFakeBidi({ occupied: true });
  const { base, dataDir, runtimeDir } = await makeDirs();
  // Simulate a previous bridge that died without ending its session.
  await writeFile(join(runtimeDir, "bridge", "session-id"), "zombie-1");
  const child = launchBridge({ port: fake.port, dataDir, runtimeDir });
  try {
    const state = await waitFor(async () => {
      const parsed = await readJsonIf(join(runtimeDir, "bridge", "state.json"));
      return parsed && parsed.ready ? parsed : null;
    });
    assert.equal(state.title, "Test Track");
    assert.ok(
      fake.state.paths.includes("/session/zombie-1"),
      "bridge reconnected to its saved session path"
    );
    assert.ok(
      fake.state.endedSessions.some((p) => p.includes("/session/zombie-1")),
      "bridge ended the zombie session"
    );
  } finally {
    try {
      child.kill("SIGTERM");
    } catch {
      /* already gone */
    }
    await waitForExit(child).catch(() => {});
    fake.server.close();
    await rm(base, { recursive: true, force: true });
  }
});

test("bridge waits for the browser's BiDi port instead of exiting at startup", async () => {
  const { base, dataDir, runtimeDir } = await makeDirs();
  // Reserve a free port, then start the bridge while nothing listens — the
  // same ordering as control.sh, which starts the bridge before the browser.
  const reservation = http.createServer();
  await new Promise((resolve) => reservation.listen(0, "127.0.0.1", resolve));
  const port = reservation.address().port;
  await new Promise((resolve) => reservation.close(resolve));

  const child = launchBridge({ port, dataDir, runtimeDir });
  let fake = null;
  try {
    await new Promise((r) => setTimeout(r, 250));
    fake = await startFakeBidi({ port });
    const state = await waitFor(async () => {
      const parsed = await readJsonIf(join(runtimeDir, "bridge", "state.json"));
      return parsed && parsed.ready ? parsed : null;
    });
    assert.equal(state.title, "Test Track");
    assert.equal(child.exitCode, null, "bridge survived the wait and is still running");
  } finally {
    try {
      child.kill("SIGTERM");
    } catch {
      /* already gone */
    }
    await waitForExit(child).catch(() => {});
    if (fake) fake.server.close();
    await rm(base, { recursive: true, force: true });
  }
});

test("bridge gives up when no BiDi port appears within its budget", async () => {
  const { base, dataDir, runtimeDir } = await makeDirs();
  // Nothing listens on this port, and the connect budget is a fraction of the
  // default: a bridge with nowhere to go must exit instead of waiting for a
  // browser that is not coming.
  const reservation = http.createServer();
  await new Promise((resolve) => reservation.listen(0, "127.0.0.1", resolve));
  const port = reservation.address().port;
  await new Promise((resolve) => reservation.close(resolve));

  const child = launchBridge({
    port,
    dataDir,
    runtimeDir,
    env: { OMARCHY_APPLE_MUSIC_BRIDGE_CONNECT_MS: "300" },
  });
  try {
    const { code } = await waitForExit(child, 8000);
    assert.equal(code, 1, "a bridge with no port to reach exits non-zero");
  } finally {
    try {
      child.kill("SIGKILL");
    } catch {
      /* already gone */
    }
    await rm(base, { recursive: true, force: true });
  }
});

test("bridge normalizes a millisecond page duration to seconds", async () => {
  // The live Firefox MusicKit reports playbackDuration in milliseconds (a
  // 6:10 track as 369629) while currentPlaybackTime is seconds. The panel
  // rendered the raw value as a five-thousand-minute track.
  const fake = await startFakeBidi({
    pageState: { ...CANNED_STATE, duration: 369629, position: 6 },
  });
  const { base, dataDir, runtimeDir } = await makeDirs();
  const child = launchBridge({ port: fake.port, dataDir, runtimeDir });
  try {
    const state = await waitFor(async () => {
      const parsed = await readJsonIf(join(runtimeDir, "bridge", "state.json"));
      return parsed && parsed.ready ? parsed : null;
    });
    assert.ok(Math.abs(state.duration - 369.629) < 1e-9, `duration is seconds, got ${state.duration}`);
    assert.equal(state.position, 6, "position is already seconds and stays untouched");
    assert.equal(state.durationInMillis, undefined, "the raw millisecond field is dropped");
  } finally {
    try {
      child.kill("SIGTERM");
    } catch {
      /* already gone */
    }
    await waitForExit(child).catch(() => {});
    fake.server.close();
    await rm(base, { recursive: true, force: true });
  }
});

test("bridge keys the reply on cmdId so a payload id survives", async () => {
  const fake = await startFakeBidi();
  const { base, dataDir, runtimeDir } = await makeDirs();
  const child = launchBridge({ port: fake.port, dataDir, runtimeDir });
  try {
    await waitFor(async () => {
      const parsed = await readJsonIf(join(runtimeDir, "bridge", "state.json"));
      return parsed && parsed.ready ? parsed : null;
    });
    // control.sh puts the envelope id in cmdId and leaves `id` alone; here
    // that is the song a row click asked to play. Clobbering it made every
    // click ask MusicKit for a nonexistent item.
    await writeFile(
      join(dataDir, "bridge-commands", "cmd-e1.json"),
      JSON.stringify({ cmdId: "e1", op: "playSong", id: "617154366" })
    );
    const reply = await waitFor(() =>
      readJsonIf(join(runtimeDir, "bridge", "replies", "reply-e1.json"))
    );
    assert.equal(reply.ok, true, "the reply is named after the envelope id");
    assert.ok(
      fake.state.evaluations.some((e) => e.includes('"617154366"')),
      "the payload id reached the page expression"
    );
    // Starting a queue must play through the singleton: setQueue's resolved
    // value is not the player in every MusicKit build, which left the queue
    // set but nothing playing.
    assert.ok(
      fake.state.evaluations.some(
        (e) => e.includes("setQueue") && e.includes("i.play()")
      ),
      "a queue builder plays through the MusicKit singleton"
    );
  } finally {
    try {
      child.kill("SIGTERM");
    } catch {
      /* already gone */
    }
    await waitForExit(child).catch(() => {});
    fake.server.close();
    await rm(base, { recursive: true, force: true });
  }
});

test("bridge fills the playlists and browse tabs in one round trip", async () => {
  const fake = await startFakeBidi();
  const { base, dataDir, runtimeDir } = await makeDirs();
  const child = launchBridge({ port: fake.port, dataDir, runtimeDir });
  try {
    await waitFor(async () => {
      const parsed = await readJsonIf(join(runtimeDir, "bridge", "state.json"));
      return parsed && parsed.ready ? parsed : null;
    });
    await writeFile(
      join(dataDir, "bridge-commands", "cmd-b1.json"),
      JSON.stringify({ cmdId: "b1", op: "browse", playlists: 50, recent: 12, charts: 12 })
    );
    const reply = await waitFor(() =>
      readJsonIf(join(runtimeDir, "bridge", "replies", "reply-b1.json"))
    );
    assert.equal(reply.ok, true);
    assert.deepEqual(reply.data.playlists, CANNED_PLAYLISTS);
    assert.deepEqual(reply.data.recent, CANNED_PLAYLISTS);
    assert.deepEqual(reply.data.charts, []);
    const browse = fake.state.evaluations.find((e) => e.includes("recently-added"));
    assert.ok(browse && browse.includes("charts") && browse.includes("Promise.all"),
      "the three catalog requests share one evaluation");
  } finally {
    try {
      child.kill("SIGTERM");
    } catch {
      /* already gone */
    }
    await waitForExit(child).catch(() => {});
    fake.server.close();
    await rm(base, { recursive: true, force: true });
  }
});

test("bridge lists a playlist's tracks so the panel can pick a song", async () => {
  const fake = await startFakeBidi();
  const { base, dataDir, runtimeDir } = await makeDirs();
  const child = launchBridge({ port: fake.port, dataDir, runtimeDir });
  try {
    await waitFor(async () => {
      const parsed = await readJsonIf(join(runtimeDir, "bridge", "state.json"));
      return parsed && parsed.ready ? parsed : null;
    });
    await writeFile(
      join(dataDir, "bridge-commands", "cmd-t1.json"),
      JSON.stringify({ cmdId: "t1", op: "playlistTracks", id: "p.1", limit: 100 })
    );
    const reply = await waitFor(() =>
      readJsonIf(join(runtimeDir, "bridge", "replies", "reply-t1.json"))
    );
    assert.equal(reply.ok, true);
    assert.deepEqual(reply.data, CANNED_TRACKS);
    assert.ok(
      fake.state.evaluations.some(
        (e) =>
          e.includes("/v1/me/library/playlists/") &&
          e.includes("/tracks?limit=") &&
          e.includes('"p.1"')
      ),
      "the library playlist tracks endpoint is queried"
    );
  } finally {
    try {
      child.kill("SIGTERM");
    } catch {
      /* already gone */
    }
    await waitForExit(child).catch(() => {});
    fake.server.close();
    await rm(base, { recursive: true, force: true });
  }
});

test("bridge lists an album's tracks so the panel can open the release", async () => {
  const fake = await startFakeBidi();
  const { base, dataDir, runtimeDir } = await makeDirs();
  const child = launchBridge({ port: fake.port, dataDir, runtimeDir });
  try {
    await waitFor(async () => {
      const parsed = await readJsonIf(join(runtimeDir, "bridge", "state.json"));
      return parsed && parsed.ready ? parsed : null;
    });
    await writeFile(
      join(dataDir, "bridge-commands", "cmd-al1.json"),
      JSON.stringify({ cmdId: "al1", op: "albumDetail", id: "a.1", limit: 100 })
    );
    const reply = await waitFor(() =>
      readJsonIf(join(runtimeDir, "bridge", "replies", "reply-al1.json"))
    );
    assert.equal(reply.ok, true);
    assert.deepEqual(reply.data, CANNED_TRACKS);
    const expression = fake.state.evaluations.find((e) => e.includes("/albums/"));
    assert.ok(expression, "the album is queried in the page");
    assert.ok(expression.includes('"a.1"'), "the album id is passed through");
    assert.ok(
      expression.includes("/v1/me/library/albums/") &&
        expression.includes("?include=tracks") &&
        !expression.includes("limit="),
      "a library album is asked for its tracks, without a limit the relationship refuses"
    );
    assert.ok(
      expression.includes("/v1/catalog/") &&
        expression.includes("/albums/") &&
        expression.includes("?include=tracks"),
      "a catalog album answers with the release's tracks relationship"
    );
    assert.ok(
      expression.includes("/songs/") && expression.includes("?include=albums"),
      "a library album's single track resolves the catalog release it belongs to"
    );
  } finally {
    try {
      child.kill("SIGTERM");
    } catch {
      /* already gone */
    }
    await waitForExit(child).catch(() => {});
    fake.server.close();
    await rm(base, { recursive: true, force: true });
  }
});

test("bridge plays a song through the list it was picked from", async () => {
  const fake = await startFakeBidi();
  const { base, dataDir, runtimeDir } = await makeDirs();
  const child = launchBridge({ port: fake.port, dataDir, runtimeDir });
  try {
    await waitFor(async () => {
      const parsed = await readJsonIf(join(runtimeDir, "bridge", "state.json"));
      return parsed && parsed.ready ? parsed : null;
    });
    await writeFile(
      join(dataDir, "bridge-commands", "cmd-q1.json"),
      JSON.stringify({ cmdId: "q1", op: "playSong", id: "s.2", ids: ["s.1", "s.2"] })
    );
    const reply = await waitFor(() =>
      readJsonIf(join(runtimeDir, "bridge", "replies", "reply-q1.json"))
    );
    assert.equal(reply.ok, true);
    const expression = fake.state.evaluations.find(
      (e) => e.includes("setQueue") && e.includes('"s.2"')
    );
    assert.ok(expression, "playSong built a queue in the page");
    assert.ok(
      expression.includes("songs:") && expression.includes('["s.1","s.2"]'),
      "the whole list is queued, not just the chosen song"
    );
    assert.ok(expression.includes("i.play()"), "the queue plays through the singleton");
  } finally {
    try {
      child.kill("SIGTERM");
    } catch {
      /* already gone */
    }
    await waitForExit(child).catch(() => {});
    fake.server.close();
    await rm(base, { recursive: true, force: true });
  }
});

test("bridge starts a playlist at the song that was chosen", async () => {
  const fake = await startFakeBidi();
  const { base, dataDir, runtimeDir } = await makeDirs();
  const child = launchBridge({ port: fake.port, dataDir, runtimeDir });
  try {
    await waitFor(async () => {
      const parsed = await readJsonIf(join(runtimeDir, "bridge", "state.json"));
      return parsed && parsed.ready ? parsed : null;
    });
    await writeFile(
      join(dataDir, "bridge-commands", "cmd-q2.json"),
      JSON.stringify({ cmdId: "q2", op: "playSong", id: "s.2", playlist: "p.1" })
    );
    const reply = await waitFor(() =>
      readJsonIf(join(runtimeDir, "bridge", "replies", "reply-q2.json"))
    );
    assert.equal(reply.ok, true);
    const expression = fake.state.evaluations.find(
      (e) => e.includes("setQueue") && e.includes('"p.1"')
    );
    assert.ok(expression, "the playlist became the queue");
    assert.ok(
      expression.includes('startWith: "s.2"'),
      "playback starts at the chosen song"
    );
  } finally {
    try {
      child.kill("SIGTERM");
    } catch {
      /* already gone */
    }
    await waitForExit(child).catch(() => {});
    fake.server.close();
    await rm(base, { recursive: true, force: true });
  }
});

test("bridge returns an artist's profile with top songs and albums", async () => {
  const fake = await startFakeBidi();
  const { base, dataDir, runtimeDir } = await makeDirs();
  const child = launchBridge({ port: fake.port, dataDir, runtimeDir });
  try {
    await waitFor(async () => {
      const parsed = await readJsonIf(join(runtimeDir, "bridge", "state.json"));
      return parsed && parsed.ready ? parsed : null;
    });
    await writeFile(
      join(dataDir, "bridge-commands", "cmd-ar1.json"),
      JSON.stringify({ cmdId: "ar1", op: "artistDetail", id: "ar.1", limit: 20 })
    );
    const reply = await waitFor(() =>
      readJsonIf(join(runtimeDir, "bridge", "replies", "reply-ar1.json"))
    );
    assert.equal(reply.ok, true);
    assert.equal(reply.data.name, "Artist One");
    assert.equal(reply.data.songs.length, 1);
    assert.equal(reply.data.albums.length, 1);
    assert.ok(
      fake.state.evaluations.some(
        (e) =>
          e.includes("/artists/") &&
          e.includes('"ar.1"') &&
          e.includes("/view/top-songs") &&
          // Full albums only are the primary source; the plain list is the
          // fallback, so both URLs must stay in the expression.
          e.includes("/view/full-albums") &&
          e.includes("/albums?limit=")
      ),
      "the artist profile asks for info, top songs and full albums"
    );
  } finally {
    try {
      child.kill("SIGTERM");
    } catch {
      /* already gone */
    }
    await waitForExit(child).catch(() => {});
    fake.server.close();
    await rm(base, { recursive: true, force: true });
  }
});

test("bridge consumes command files in order and removes them", async () => {
  const fake = await startFakeBidi();
  const { base, dataDir, runtimeDir } = await makeDirs();
  const child = launchBridge({ port: fake.port, dataDir, runtimeDir });
  try {
    await waitFor(async () => {
      const parsed = await readJsonIf(join(runtimeDir, "bridge", "state.json"));
      return parsed && parsed.ready ? parsed : null;
    });
    await writeFile(
      join(dataDir, "bridge-commands", "cmd-x1.json"),
      JSON.stringify({ id: "x1", op: "next" })
    );
    await waitFor(() => readJsonIf(join(runtimeDir, "bridge", "replies", "reply-x1.json")));
    const remaining = await readdir(join(dataDir, "bridge-commands"));
    assert.deepEqual(remaining, [], "command files are consumed");
  } finally {
    try {
      child.kill("SIGTERM");
    } catch {
      /* already gone */
    }
    await waitForExit(child).catch(() => {});
    fake.server.close();
    await rm(base, { recursive: true, force: true });
  }
});
