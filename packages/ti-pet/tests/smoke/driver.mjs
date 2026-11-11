#!/usr/bin/env node
/**
 * ti-pet smoke driver: plays the TracingInsights desktop app's side of the
 * native pet protocol against a real `ti-pet` binary, on Linux, Windows and
 * macOS (.github/workflows/ti-pet-smoke.yml runs it on each).
 *
 *   node packages/ti-pet/tests/smoke/driver.mjs --binary <ti-pet> \
 *     [--artifacts <dir>] [--timeout-ms 15000] [--strict-pixels] [--keep]
 *
 * Self-contained (Node >= 20, no dependencies, nothing imported from the
 * private tif1ai repo): the protocol bits below are copied from tif1ai's
 * desktop/src/pets/native-protocol.mjs and native-pet.mjs — socket / pipe
 * naming, the token file, JSON lines, message shapes and validation. Keep
 * them in step when the protocol changes (NATIVE_PROTOCOL_VERSION).
 *
 * What it does, in the order Electron would:
 *   spawn with Electron's argv (GDK_BACKEND=x11 on Linux) → hello / ready
 *   (pid must be the spawned process: the desktop's Windows pipe check needs
 *   it) → menu → show → render solo → render duo → bubble → hide → show →
 *   round 3 live: the caps, a v2 look-around row (its v1 partner falls back
 *   to idle), the partner's own animation (secondAnim), sleep (still frame +
 *   "z z"), the answer badge, a dash and a roam walk (`position` with
 *   walk: true), bubble buttons and the click panel (Linux: real clicks
 *   through xdotool must come back as bubbleAction / panelAction; the panel
 *   closes itself after 20 s → panelAction close) →
 *   write a timeline + handoff → ack → disconnect (Electron exits) → the
 *   timeline's moment lands in pet-native-state.json → reconnect with a new
 *   token (the next Electron adopts the pet) → a v2 timeline + handoff →
 *   disconnect → its greeting moment is recorded (Linux: the offline mute
 *   button lands in `mutes`, a click opens the static panel and its button
 *   starts the app with --pets-open) → reconnect → quit → the process exits
 *   and the socket is gone. macOS also launches a quarantined copy.
 *
 * The pet art is synthetic: a PNG atlas of flat coloured cells generated
 * here (magenta first pet, cyan second), never real pet art. Each cell
 * carries a black notch whose x encodes its row, so a screenshot tells
 * which row a sprite plays. Screenshots go
 * to the artifacts dir after each visible step; a missing screenshot tool
 * only warns. With --strict-pixels a screenshot without the pet's colour
 * (or with it while hidden) fails the run; without it that is a warning.
 * A bubble that is missing, not above the pets or more than 40 pt off the
 * pets' centre always fails (it is found as what turned near-white since
 * the shot before it). Each shot is retried a few times before it is judged.
 * Any protocol error, a timeout or a bad exit fails the run (exit code 1).
 */
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import {
  chmodSync,
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  rmSync,
  writeFileSync
} from 'node:fs';
import { createConnection } from 'node:net';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { deflateSync, inflateSync } from 'node:zlib';

// ------------------------------------------------- protocol (native-protocol.mjs)

const NATIVE_PROTOCOL_VERSION = 1;
const TIMELINE_VERSION = 1;
/** Round 3: written only to a pet whose ready.caps has 'timeline-v2'. */
const TIMELINE_VERSION_V2 = 2;
/** ready.caps a round-3 pet must list (protocol.zig `caps`). */
const ROUND3_CAPS = ['motion', 'sleep', 'bubble-actions', 'panel', 'badge', 'second-anim', 'v2-rows', 'timeline-v2'];
const NATIVE_STATE_VERSION = 1;
const MAX_LINE_BYTES = 64 * 1024;
const SOCKET_FILE = 'pet.sock';
const TOKEN_FILE = 'pet-token';
const TIMELINE_FILE = 'pet-timeline.json';
const NATIVE_STATE_FILE = 'pet-native-state.json';
const MAX_UNIX_SOCKET_PATH = 100;
/** native-pet.mjs: Electron gives up on an ack after this long. */
const HANDOFF_ACK_MS = 1000;
const TO_NATIVE_KINDS = ['hello', 'show', 'hide', 'render', 'menu', 'handoff', 'quit'];
const FROM_NATIVE_KINDS = ['ready', 'event', 'position', 'menuAction', 'ack', 'error'];
const NATIVE_EVENTS = ['drag', 'dragEnd', 'click', 'dblclick', 'hover', 'bubbleClick', 'bubbleAction', 'panelAction'];
const MENU_ID_RE = /^[a-z0-9.-]{1,64}$/;
const ACTION_ID_RE = /^[a-z0-9-]{1,32}$/;
const MARKER_SETTINGS = ['lastResultKey', 'lastRateKey', 'lastFactDay', 'lastGreetingKey'];
const BUBBLE_KIND_RE = /^[a-z-]{1,24}$/;

function nativeSocketPath({ platform, userDataDir, tmpDir }) {
  const hash = createHash('sha256').update(userDataDir).digest('hex').slice(0, 16);
  if (platform === 'win32') return `\\\\.\\pipe\\tracinginsights-pet-${hash}`;
  const inside = join(userDataDir, SOCKET_FILE);
  return Buffer.byteLength(inside) <= MAX_UNIX_SOCKET_PATH
    ? inside
    : join(tmpDir, `tracinginsights-pet-${hash}.sock`);
}

function encodeLine(message) {
  if (!TO_NATIVE_KINDS.includes(message?.kind)) {
    throw new Error(`Unknown native message kind: ${message?.kind}`);
  }
  const line = `${JSON.stringify(message)}\n`;
  if (Buffer.byteLength(line) > MAX_LINE_BYTES) throw new Error('Native message too large.');
  return line;
}

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const finiteIn = (v, max) => typeof v === 'number' && Number.isFinite(v) && Math.abs(v) <= max;
const shortText = (v) => typeof v === 'string' && v.length > 0 && v.length <= 200;

/** native → Electron message, normalised, or null (validateFromNative). */
function validateFromNative(raw) {
  if (!isObject(raw) || !FROM_NATIVE_KINDS.includes(raw.kind)) return null;
  switch (raw.kind) {
    case 'ready':
      if (!Number.isSafeInteger(raw.protocol)) return null;
      return {
        kind: 'ready',
        protocol: raw.protocol,
        version: shortText(raw.version) ? raw.version : '',
        caps: Array.isArray(raw.caps) ? raw.caps.filter(shortText).slice(0, 32) : [],
        pid: Number.isSafeInteger(raw.pid) && raw.pid > 0 ? raw.pid : null
      };
    case 'event':
      if (!NATIVE_EVENTS.includes(raw.event)) return null;
      if (raw.event === 'bubbleAction' || raw.event === 'panelAction') {
        return typeof raw.id === 'string' && ACTION_ID_RE.test(raw.id) ? { kind: 'event', event: raw.event, id: raw.id } : null;
      }
      if (raw.event !== 'drag') return { kind: 'event', event: raw.event };
      if (!finiteIn(raw.dx, 10_000) || !finiteIn(raw.dy, 10_000)) return null;
      return { kind: 'event', event: 'drag', dx: raw.dx, dy: raw.dy };
    case 'position':
      if (!finiteIn(raw.x, 1e6) || !finiteIn(raw.y, 1e6)) return null;
      return { kind: 'position', x: Math.round(raw.x), y: Math.round(raw.y), walk: raw.walk === true };
    case 'menuAction':
      if (typeof raw.id !== 'string' || !MENU_ID_RE.test(raw.id)) return null;
      return { kind: 'menuAction', id: raw.id };
    case 'ack':
      return raw.of === 'handoff' ? { kind: 'ack', of: 'handoff' } : null;
    case 'error':
      return {
        kind: 'error',
        code: shortText(raw.code) ? raw.code : 'unknown',
        message: shortText(raw.message) ? raw.message : ''
      };
    default:
      return null;
  }
}

/** native-state.mjs parseNativeState, reduced to what the smoke checks. */
function parseNativeState(raw) {
  if (!isObject(raw) || raw.v !== NATIVE_STATE_VERSION) return null;
  const markers = [];
  if (Array.isArray(raw.shownMoments)) {
    for (const m of raw.shownMoments.slice(-32)) {
      if (m && MARKER_SETTINGS.includes(m.name) && typeof m.value === 'string') {
        markers.push({ name: m.name, value: m.value });
      }
    }
  }
  const mutes = Array.isArray(raw.mutes) ? raw.mutes.filter((k) => typeof k === 'string' && BUBBLE_KIND_RE.test(k)) : [];
  return { updatedAt: raw.updatedAt, markers, mutes };
}

// ------------------------------------------------------------------ args

function parseArgs(argv) {
  const out = { binary: null, artifacts: null, timeoutMs: 15_000, strictPixels: false, keep: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--binary') out.binary = argv[++i];
    else if (arg === '--artifacts') out.artifacts = argv[++i];
    else if (arg === '--timeout-ms') out.timeoutMs = Number(argv[++i]);
    else if (arg === '--strict-pixels') out.strictPixels = true;
    else if (arg === '--keep') out.keep = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!out.binary) throw new Error('--binary <path to ti-pet> is required');
  if (!Number.isFinite(out.timeoutMs) || out.timeoutMs <= 0) throw new Error('bad --timeout-ms');
  out.binary = resolve(out.binary);
  out.artifacts = resolve(out.artifacts ?? join(tmpdir(), 'ti-pet-smoke-artifacts'));
  return out;
}

const opts = parseArgs(process.argv.slice(2));
const platform = process.platform;
mkdirSync(opts.artifacts, { recursive: true });
const logPath = join(opts.artifacts, 'driver.log');
writeFileSync(logPath, '');
const started = Date.now();

function log(level, text) {
  const line = `[${((Date.now() - started) / 1000).toFixed(2).padStart(6)}s] ${level.padEnd(4)} ${text}`;
  console.log(line);
  writeFileSync(logPath, `${line}\n`, { flag: 'a' });
}
const info = (t) => log('info', t);
const warnings = [];
const warn = (t) => {
  warnings.push(t);
  log('WARN', t);
};
/** Steps passed, for summary.json. */
const passed = [];
const pass = (t) => {
  passed.push(t);
  log('ok', t);
};

class SmokeError extends Error {}
const fail = (t) => {
  throw new SmokeError(t);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ------------------------------------------------------- synthetic atlas

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();
function crc32(buf) {
  let c = 0xffffffff;
  for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function pngChunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}
/** RGBA8 pixels → PNG bytes (filter 0 on every row). */
function encodePng(width, height, rgba) {
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y += 1) {
    rgba.copy(raw, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', deflateSync(raw)),
    pngChunk('IEND', Buffer.alloc(0))
  ]);
}

const CELL_W = 192;
const CELL_H = 208;
const COLS = 8;
const ROWS = 9;
const COLORS = { first: [255, 0, 255], second: [0, 255, 255] };
const MARGIN = 24;
/** Row notch: a black NOTCH_W x 10 block at x MARGIN + NOTCH_X0 + row * NOTCH_STEP. */
const NOTCH_X0 = 6;
const NOTCH_STEP = 12;
const NOTCH_W = 9;
const NOTCH_Y0 = 180;
const NOTCH_Y1 = 190;

/**
 * An atlas (8 x `rows` cells of 192x208; 9 = v1, 11 = v2): every cell a
 * flat block of `color` with a transparent margin, a black bar whose
 * height moves with the frame (the animation is visible in a screenshot
 * sequence) and a black notch whose x is the row.
 */
function syntheticAtlas([r, g, b], rows = ROWS) {
  const width = CELL_W * COLS;
  const height = CELL_H * rows;
  const px = Buffer.alloc(width * height * 4);
  for (let row = 0; row < rows; row += 1) {
    const notchX = MARGIN + NOTCH_X0 + row * NOTCH_STEP;
    for (let col = 0; col < COLS; col += 1) {
      const barTop = MARGIN + 20 + col * 16;
      for (let y = MARGIN; y < CELL_H - MARGIN / 2; y += 1) {
        const bar = y >= barTop && y < barTop + 12;
        for (let x = MARGIN; x < CELL_W - MARGIN; x += 1) {
          const notch = y >= NOTCH_Y0 && y < NOTCH_Y1 && x >= notchX && x < notchX + NOTCH_W;
          const i = ((row * CELL_H + y) * width + col * CELL_W + x) * 4;
          px[i] = bar || notch ? 0 : r;
          px[i + 1] = bar || notch ? 0 : g;
          px[i + 2] = bar || notch ? 0 : b;
          px[i + 3] = 255;
        }
      }
    }
  }
  return encodePng(width, height, px);
}

/** userData/pets/<id>/{pet.json, spritesheet.png} like the pet store. */
function writePet(userDataDir, id, color, rows = ROWS) {
  const dir = join(userDataDir, 'pets', id);
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, 'pet.json'),
    `${JSON.stringify({ id, displayName: `Smoke ${id}`, description: 'Synthetic smoke-test pet (flat colour cells).', spritesheetPath: 'spritesheet.png' }, null, 2)}\n`
  );
  const sheet = join(dir, 'spritesheet.png');
  writeFileSync(sheet, syntheticAtlas(color, rows));
  return sheet;
}

// ------------------------------------------------- screenshots + pixels

/** PNG (8-bit RGB/RGBA, not interlaced) → { width, height, channels, data } or null. */
function decodePng(buf) {
  if (buf.length < 8 || buf.readUInt32BE(0) !== 0x89504e47) return null;
  let off = 8;
  let width = 0;
  let height = 0;
  let depth = 0;
  let type = 0;
  let interlace = 0;
  const idat = [];
  while (off + 8 <= buf.length) {
    const len = buf.readUInt32BE(off);
    const kind = buf.toString('ascii', off + 4, off + 8);
    const data = buf.subarray(off + 8, off + 8 + len);
    if (kind === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      depth = data[8];
      type = data[9];
      interlace = data[12];
    } else if (kind === 'IDAT') idat.push(data);
    else if (kind === 'IEND') break;
    off += 12 + len;
  }
  if (depth !== 8 || interlace !== 0 || (type !== 2 && type !== 6)) return null;
  const channels = type === 6 ? 4 : 3;
  const raw = inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const out = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y += 1) {
    const filter = raw[y * (stride + 1)];
    const src = y * (stride + 1) + 1;
    for (let x = 0; x < stride; x += 1) {
      const a = x >= channels ? out[y * stride + x - channels] : 0;
      const b = y > 0 ? out[(y - 1) * stride + x] : 0;
      const c = x >= channels && y > 0 ? out[(y - 1) * stride + x - channels] : 0;
      let v = raw[src + x];
      if (filter === 1) v += a;
      else if (filter === 2) v += b;
      else if (filter === 3) v += (a + b) >> 1;
      else if (filter === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a);
        const pb = Math.abs(p - b);
        const pc = Math.abs(p - c);
        v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      }
      out[y * stride + x] = v & 0xff;
    }
  }
  return { width, height, channels, data: out };
}

/** A pet-colour pixel: 1 = first pet (magenta), 2 = second (cyan), else 0. */
function petColour(r, g, b) {
  if (r > 190 && g < 80 && b > 190) return 1;
  if (r < 80 && g > 190 && b > 190) return 2;
  return 0;
}

const nearWhite = (data, i) => data[i] >= 225 && data[i + 1] >= 225 && data[i + 2] >= 225;

/**
 * Pet-colour pixel counts, and the box of the densest pet-coloured block —
 * desktop icons (a Dock, a browser logo) can carry a few such pixels too.
 */
function petPixels(img) {
  const { data, channels, width, height } = img;
  let first = 0;
  let second = 0;
  const mask = new Uint8Array(width * height);
  const rows = new Array(height).fill(0);
  for (let i = 0, p = 0; i + 2 < data.length; i += channels, p += 1) {
    const kind = petColour(data[i], data[i + 1], data[i + 2]);
    if (!kind) continue;
    if (kind === 1) first += 1;
    else second += 1;
    mask[p] = 1;
    rows[Math.floor(p / width)] += 1;
  }
  return { first, second, box: denseBox(mask, rows, width, { rowMin: 20, rowGap: 16, colMin: 5, colGap: 120 }) };
}

/** Box of the densest block of a pixel mask (rows first, then columns inside them). */
function denseBox(mask, rows, width, { rowMin, rowGap, colMin, colGap }) {
  const rowRun = densestRun(rows, rowMin, rowGap);
  if (!rowRun) return null;
  const cols = new Array(width).fill(0);
  for (let y = rowRun.from; y <= rowRun.to; y += 1) {
    for (let x = 0; x < width; x += 1) cols[x] += mask[y * width + x];
  }
  const colRun = densestRun(cols, colMin, colGap);
  if (!colRun) return null;
  return { minX: colRun.from, maxX: colRun.to, minY: rowRun.from, maxY: rowRun.to, px: colRun.total };
}

/** The densest run of indices whose count is >= min, allowing gaps <= maxGap. */
function densestRun(counts, min, maxGap) {
  let best = null;
  let cur = null;
  let gap = 0;
  for (let i = 0; i < counts.length; i += 1) {
    if (counts[i] >= min) {
      if (!cur) cur = { from: i, to: i, total: 0 };
      cur.to = i;
      cur.total += counts[i];
      gap = 0;
    } else if (cur && ++gap > maxGap) {
      if (!best || cur.total > best.total) best = cur;
      cur = null;
    }
  }
  if (cur && (!best || cur.total > best.total)) best = cur;
  return best;
}

/**
 * The bubble's box: near-white pixels in `img` that were not near-white in
 * `before` (the same scene without the bubble). A light-theme bubble is a
 * white panel; a dark one has near-white text — either way the box centre
 * is the bubble's centre. Null when nothing bubble-sized appeared.
 */
function bubbleBox(img, before) {
  const { data, channels, width, height } = img;
  const same = before && before.width === width && before.height === height;
  const fresh = new Uint8Array(width * height);
  const rows = new Array(height).fill(0);
  for (let p = 0, i = 0; p < width * height; p += 1, i += channels) {
    if (!nearWhite(data, i)) continue;
    if (same && nearWhite(before.data, p * before.channels)) continue;
    fresh[p] = 1;
    rows[Math.floor(p / width)] += 1;
  }
  const box = denseBox(fresh, rows, width, { rowMin: 2, rowGap: 6, colMin: 1, colGap: 12 });
  return box && box.px >= 150 ? box : null;
}

/** Box of one pet's colour (1 = first / magenta, 2 = second / cyan), or null. */
function colourBox(img, kind) {
  const { data, channels, width, height } = img;
  const mask = new Uint8Array(width * height);
  const rows = new Array(height).fill(0);
  for (let i = 0, p = 0; i + 2 < data.length; i += channels, p += 1) {
    if (petColour(data[i], data[i + 1], data[i + 2]) !== kind) continue;
    mask[p] = 1;
    rows[Math.floor(p / width)] += 1;
  }
  return denseBox(mask, rows, width, { rowMin: 20, rowGap: 16, colMin: 5, colGap: 120 });
}

const black = (data, i) => data[i] < 60 && data[i + 1] < 60 && data[i + 2] < 60;

/**
 * The notch of a pet's sprite (syntheticAtlas): its x run on the notch's
 * middle line, with the sprite box and scale, or null.
 */
function notchRun(img, kind) {
  const box = colourBox(img, kind);
  if (!box) return null;
  const s = (box.maxX - box.minX + 1) / (CELL_W - 2 * MARGIN);
  const y = Math.round(box.minY + ((NOTCH_Y0 + NOTCH_Y1) / 2 - MARGIN) * s);
  if (y < 0 || y >= img.height) return null;
  let start = null;
  for (let x = box.minX; x <= box.maxX + 1; x += 1) {
    const dark = x <= box.maxX && black(img.data, (y * img.width + x) * img.channels);
    if (dark && start === null) start = x;
    if (!dark && start !== null) {
      const w = x - start;
      if (w >= NOTCH_W * s * 0.5 && w <= NOTCH_W * s * 2) return { box, s, y, from: start, to: x - 1 };
      start = null;
    }
  }
  return null;
}

/**
 * The atlas row a pet's sprite shows, read off its notch (syntheticAtlas),
 * or null when no notch is found.
 */
function rowOf(img, kind) {
  const run = notchRun(img, kind);
  if (!run) return null;
  const mid = (run.from + run.to) / 2;
  const xo = (mid - run.box.minX) / run.s + MARGIN;
  return Math.round((xo - (MARGIN + NOTCH_X0 + NOTCH_W / 2)) / NOTCH_STEP);
}

/**
 * The brightest channel inside the notch (1 px in from its edges), or null.
 * The notch is pure black art: it must read ~black. On Windows a pure-black
 * pixel used to be keyed away (the Native SDK colour-keys transparent
 * windows on RGB 0,0,0) and showed what is behind the pet instead — the
 * CI console's (12,12,12) and its text. ti-pet lifts it to (0,0,1).
 */
function notchMax(img, kind) {
  const run = notchRun(img, kind);
  if (!run) return null;
  const half = Math.max(1, Math.floor(((NOTCH_Y1 - NOTCH_Y0) * run.s) / 2) - 1);
  let max = 0;
  for (let y = run.y - half; y <= run.y + half; y += 1) {
    for (let x = run.from + 1; x <= run.to - 1; x += 1) {
      const i = (y * img.width + x) * img.channels;
      max = Math.max(max, img.data[i], img.data[i + 1], img.data[i + 2]);
    }
  }
  return max;
}
/** A notch brighter than this is not the pet's black (see notchMax). */
const NOTCH_MAX_CHANNEL = 4;

/**
 * The pets' area of a shot: their dense box plus a margin (the badge and the
 * "z z" sit on the sprites), else the whole shot. Full-screen captures also
 * hold the desktop — a red tray / Dock badge or a blue wallpaper must not
 * count as the pet's marks.
 */
function petsArea(img, box) {
  if (!box) return { x0: 0, y0: 0, x1: img.width - 1, y1: img.height - 1 };
  const pad = Math.round((box.maxX - box.minX + 1) * 0.1);
  return {
    x0: Math.max(0, box.minX - pad),
    y0: Math.max(0, box.minY - pad),
    x1: Math.min(img.width - 1, box.maxX + pad),
    y1: Math.min(img.height - 1, box.maxY + pad)
  };
}

/** Pixels inside `area` for which `test(r, g, b)` holds. */
function countIn(img, area, test) {
  const { data, channels, width } = img;
  let n = 0;
  for (let y = area.y0; y <= area.y1; y += 1) {
    for (let x = area.x0; x <= area.x1; x += 1) {
      const i = (y * width + x) * channels;
      if (test(data[i], data[i + 1], data[i + 2])) n += 1;
    }
  }
  return n;
}

/** Red badge-dot pixels (main.zig withMarks: rgb 239, 68, 68). */
function badgePixels(img, area) {
  return countIn(img, area, (r, g, b) => r > 200 && g < 110 && b < 110);
}

/** Blue-grey "z z" pixels (main.zig withMarks, dark or light), cyan excluded. */
function zzPixels(img, area) {
  return countIn(img, area, (r, g, b) => {
    if (g > 190 && r < 80) return false;
    return r >= 60 && g >= 60 && b - r >= 20 && b - g >= 10 && b <= 245;
  });
}

/** Both shots show the same pixels inside `box` (a still frame). */
function sameInBox(a, b, box) {
  if (!a || !b || !box || a.width !== b.width || a.height !== b.height) return false;
  for (let y = box.minY; y <= box.maxY; y += 1) {
    for (let x = box.minX; x <= box.maxX; x += 1) {
      const i = (y * a.width + x) * a.channels;
      const j = (y * b.width + x) * b.channels;
      if (a.data[i] !== b.data[j] || a.data[i + 1] !== b.data[j + 1] || a.data[i + 2] !== b.data[j + 2]) return false;
    }
  }
  return true;
}

function haveTool(cmd, args = ['-version']) {
  try {
    return spawnSync(cmd, args, { stdio: 'ignore', timeout: 10_000 }).error == null;
  } catch {
    return false;
  }
}

/** Full-desktop PNG at `file`; false (with a warning) when no tool works. */
function screenshot(file) {
  try {
    if (platform === 'darwin') {
      execFileSync('screencapture', ['-x', '-t', 'png', file], { timeout: 20_000 });
    } else if (platform === 'win32') {
      const ps = [
        'Add-Type -AssemblyName System.Windows.Forms, System.Drawing',
        '$b = [System.Windows.Forms.SystemInformation]::VirtualScreen',
        '$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height',
        '$g = [System.Drawing.Graphics]::FromImage($bmp)',
        // CAPTUREBLT: include layered windows (the pet's are) explicitly
        // rather than rely on the DWM read-back; plain copy if refused.
        '$op = [System.Enum]::ToObject([System.Drawing.CopyPixelOperation], ([int][System.Drawing.CopyPixelOperation]::SourceCopy) -bor ([int][System.Drawing.CopyPixelOperation]::CaptureBlt))',
        'try { $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size, $op) } catch { $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size) }',
        `$bmp.Save('${file.replace(/'/g, "''")}', [System.Drawing.Imaging.ImageFormat]::Png)`
      ].join('; ');
      execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', ps], {
        timeout: 30_000,
        windowsHide: true
      });
    } else if (haveTool('import')) {
      // PNG24: 8-bit RGB. Left to itself ImageMagick writes a palette or
      // 1-bit greyscale PNG for a scene with few colours.
      execFileSync('import', ['-window', 'root', '-depth', '8', `PNG24:${file}`], { timeout: 20_000 });
    } else if (haveTool('ffmpeg')) {
      const geo = execFileSync('xwininfo', ['-root'], { encoding: 'utf8', timeout: 10_000 });
      const w = /Width:\s*(\d+)/.exec(geo)?.[1];
      const h = /Height:\s*(\d+)/.exec(geo)?.[1];
      execFileSync(
        'ffmpeg',
        ['-loglevel', 'error', '-y', '-f', 'x11grab', '-video_size', `${w}x${h}`, '-i', process.env.DISPLAY ?? ':0', '-frames:v', '1', file],
        { timeout: 20_000 }
      );
    } else {
      warn('no screenshot tool (ImageMagick import or ffmpeg + xwininfo); skipped');
      return false;
    }
  } catch (error) {
    warn(`screenshot failed: ${error.message.split('\n')[0]}`);
    return false;
  }
  return existsSync(file);
}

function readShot(name, file) {
  try {
    const buf = readFileSync(file);
    const img = decodePng(buf);
    if (img) return img;
    const what = buf.length >= 29 ? `depth ${buf[24]}, colour type ${buf[25]}, interlace ${buf[28]}` : 'truncated';
    warn(`${name}: screenshot PNG not decodable here (${what}); pixel checks skipped`);
  } catch (error) {
    warn(`${name}: reading the screenshot failed: ${error.message}`);
  }
  return null;
}

/**
 * Rootless XWayland (a GNOME / KDE Wayland session): the X root window
 * reads black, but each X window's contents can be read. Paint the pet's
 * visible windows (pet + bubble) at their screen positions onto a black
 * root-sized image and write it over `file`. False when that fails.
 */
function compositeWindows(file) {
  if (!petPid || !haveTool('xdotool', ['version']) || !haveTool('ffmpeg')) return false;
  try {
    const root = execFileSync('xwininfo', ['-root'], { encoding: 'utf8', timeout: 10_000 });
    const width = Number(/Width:\s*(\d+)/.exec(root)[1]);
    const height = Number(/Height:\s*(\d+)/.exec(root)[1]);
    const canvas = Buffer.alloc(width * height * 4);
    for (let i = 3; i < canvas.length; i += 4) canvas[i] = 255;
    let ids = [];
    try {
      ids = execFileSync('xdotool', ['search', '--onlyvisible', '--pid', String(petPid)], { encoding: 'utf8', timeout: 10_000 })
        .split('\n')
        .filter((id) => /^\d+$/.test(id));
    } catch {
      // no visible window (hidden pet): a black screen is the right answer
    }
    for (const id of ids) {
      const geo = execFileSync('xwininfo', ['-id', id], { encoding: 'utf8', timeout: 10_000 });
      const left = Number(/Absolute upper-left X:\s*(-?\d+)/.exec(geo)[1]);
      const top = Number(/Absolute upper-left Y:\s*(-?\d+)/.exec(geo)[1]);
      const part = `${file}.win${id}.png`;
      execFileSync(
        'ffmpeg',
        ['-loglevel', 'error', '-y', '-f', 'x11grab', '-window_id', id, '-i', process.env.DISPLAY ?? ':0', '-frames:v', '1', part],
        { timeout: 20_000 }
      );
      const img = decodePng(readFileSync(part));
      rmSync(part, { force: true });
      if (!img) continue;
      for (let y = 0; y < img.height; y += 1) {
        for (let x = 0; x < img.width; x += 1) {
          const sx = left + x;
          const sy = top + y;
          if (sx < 0 || sy < 0 || sx >= width || sy >= height) continue;
          const i = (y * img.width + x) * img.channels;
          const o = (sy * width + sx) * 4;
          canvas[o] = img.data[i];
          canvas[o + 1] = img.data[i + 1];
          canvas[o + 2] = img.data[i + 2];
        }
      }
    }
    writeFileSync(file, encodePng(width, height, canvas));
    return true;
  } catch (error) {
    warn(`window composite failed: ${error.message.split('\n')[0]}`);
    return false;
  }
}

/** One screenshot, decoded; null when unavailable (already warned). */
function takeShot(name, file) {
  if (!screenshot(file)) return null;
  if (platform === 'linux' && process.env.WAYLAND_DISPLAY && !compositeWindows(file)) return null;
  return readShot(name, file);
}

const MIN_PET_PX = 2000;
/** Width of the coloured part of the synthetic sprites at size m, in points. */
const SPRITE_W = Math.round(CELL_W * 0.75);
const SPRITE_INSET = Math.round(24 * 0.75);
const groupSpan = (duo) =>
  duo ? 2 * SPRITE_W + Math.round(SPRITE_W * 0.05) - 2 * SPRITE_INSET : SPRITE_W - 2 * SPRITE_INSET;
/** Bubble centre may sit this far (points) from the pets' centre. */
const BUBBLE_CENTRE_TOLERANCE = 40;

/**
 * Pixel problems of one shot: [] = as expected. `ref` = an earlier shot of
 * the same scene without the marks: the badge / "z z" counts are taken
 * relative to it, so a desktop behind or between the pets (Windows console
 * text, a blue wallpaper) cancels out.
 */
function shotProblems(img, expect, before, ref = null) {
  const pets = petPixels(img);
  const problems = [];
  if (expect.first === true && pets.first < MIN_PET_PX) problems.push('first pet not visible');
  if (expect.second === true && pets.second < MIN_PET_PX) problems.push('second pet not visible');
  if (expect.first === false && pets.first >= MIN_PET_PX) problems.push('first pet visible while hidden');
  if (expect.second === false && pets.second >= MIN_PET_PX) problems.push('second pet visible');
  // Round 3: rows (v2 look-around, the partner's fallback / own row, the walk).
  for (const [who, kind] of [['first', 1], ['second', 2]]) {
    const want = expect.rows?.[who];
    if (want === undefined || problems.length > 0) continue;
    const got = rowOf(img, kind);
    const ok = Array.isArray(want) ? want.includes(got) : got === want;
    if (!ok) problems.push(`${who} pet shows row ${got}, want ${JSON.stringify(want)}`);
    const max = notchMax(img, kind);
    if (ok && max !== null && max > NOTCH_MAX_CHANNEL) {
      problems.push(`${who} pet's black notch shows what is behind it (brightest channel ${max}): black art keyed away`);
    }
  }
  const area = petsArea(img, pets.box);
  const sameSize = ref && ref.width === img.width && ref.height === img.height;
  const red = badgePixels(img, area) - (sameSize ? badgePixels(ref, area) : 0);
  const zz = zzPixels(img, area) - (sameSize ? zzPixels(ref, area) : 0);
  if (expect.badge === true && red < 30) problems.push(`no badge dot (${red} red px)`);
  if (expect.badge === false && red >= 10) problems.push(`badge dot while none is set (${red} red px)`);
  if (expect.zz === true && zz < 12) problems.push(`no "z z" mark (${zz} px)`);
  if (expect.zz === false && zz >= 12) problems.push(`"z z" mark while awake (${zz} px)`);
  const result = { pets, bubble: null, problems, bubbleProblems: [] };
  if (!expect.bubble || problems.length > 0 || !pets.box) return result;
  const bubble = bubbleBox(img, before);
  result.bubble = bubble;
  if (!bubble) {
    result.bubbleProblems.push('no bubble found');
    return result;
  }
  // Screenshot pixels per point (2 on a Retina display).
  const scale = (pets.box.maxX - pets.box.minX + 1) / groupSpan(expect.second === true);
  const petCx = (pets.box.minX + pets.box.maxX) / 2;
  const bubbleCx = (bubble.minX + bubble.maxX) / 2;
  const dx = bubbleCx - petCx;
  result.bubbleDx = Math.round(dx / scale);
  if (Math.abs(dx) > BUBBLE_CENTRE_TOLERANCE * scale) {
    result.bubbleProblems.push(`bubble centre ${Math.round(dx / scale)} pt from the pets' centre (x ${Math.round(bubbleCx)} vs ${Math.round(petCx)} px)`);
  }
  if (bubble.maxY >= pets.box.minY) {
    result.bubbleProblems.push(`bubble not above the pets (bubble bottom y ${bubble.maxY}, pets top y ${pets.box.minY} px)`);
  }
  return result;
}

/**
 * Screenshot + expectations ('first' / 'second' visible or not; `bubble`:
 * a bubble centred above the pets, found against the `before` shot).
 * Retries a few times before judging: a window can take a moment to map,
 * paint its first frame or move. Pet visibility fails only with
 * --strict-pixels; a misplaced or missing bubble always fails. Without a
 * usable screenshot both are skipped with a warning.
 */
let petPid = null;
const shots = [];
const images = new Map();
async function capture(name, expect, { before = null, ref = null } = {}) {
  const file = join(opts.artifacts, `${String(shots.length + 1).padStart(2, '0')}-${name}.png`);
  let img = null;
  let result = null;
  for (let attempt = 1; attempt <= 5; attempt += 1) {
    await sleep(attempt === 1 ? 1200 : 1000); // poll tick (100 ms) + a few frames + compositor
    img = takeShot(name, file);
    if (!img) break;
    result = shotProblems(img, expect, before ? images.get(before) : null, ref ? (images.get(ref) ?? null) : null);
    if (result.problems.length === 0 && result.bubbleProblems.length === 0) break;
    info(`${name}: attempt ${attempt}: ${[...result.problems, ...result.bubbleProblems].join(', ')}; retrying`);
  }
  const counts = result ? { first: result.pets.first, second: result.pets.second } : null;
  shots.push({ name, file, counts, bubble: result?.bubble ?? null, bubbleDx: result?.bubbleDx ?? null });
  if (!img || !result) return;
  images.set(name, img);
  info(`${name}: screenshot ${file} — first-pet px ${counts.first}, second-pet px ${counts.second}`);
  if (result.bubble) info(`${name}: bubble box ${JSON.stringify(result.bubble)}, centre offset ${result.bubbleDx} pt`);
  if (result.bubbleProblems.length > 0) fail(`${name}: ${result.bubbleProblems.join(', ')} (screenshot ${file})`);
  if (expect.bubble && result.problems.length === 0) pass(`${name}: bubble centred above the pets (${result.bubbleDx} pt off centre)`);
  if (result.problems.length === 0) return pass(`${name}: pixels as expected`);
  const text = `${name}: ${result.problems.join(', ')} (screenshot ${file})`;
  if (opts.strictPixels) fail(text);
  warn(text);
}

/** A second shot of `name`'s scene: the pets must not have changed (still frame). */
async function stillCheck(name) {
  const first = images.get(name);
  if (!first) return;
  await sleep(900);
  const again = takeShot(name, join(opts.artifacts, `${String(shots.length).padStart(2, '0')}-${name}-again.png`));
  if (!again) return;
  if (sameInBox(first, again, petPixels(first).box)) return pass(`${name}: the frame stays still`);
  const text = `${name}: the pets changed between two shots of a still frame`;
  if (opts.strictPixels) fail(text);
  warn(text);
}

/**
 * A few more shots of `name`'s scene: an animating pet must change (its
 * frame bar moves). All the same = frozen frames: reduce motion forced on
 * by the pet, its frame timer never fires, or the frames never reach the
 * screen. ti-pet.log tells which: "appearance", "frames:" (ticks and frame
 * events) and, on Windows, the SDK host's "sdk:" lines (the present path
 * each window took; frame events, presents, layered updates, child paints).
 */
async function animatesCheck(name) {
  const first = images.get(name);
  if (!first) return;
  const box = petPixels(first).box;
  const sdkLines = () => (platform === 'win32' ? petLogTail(/ sdk: /, 3) : []);
  for (let attempt = 1; attempt <= 4; attempt += 1) {
    await sleep(350);
    const again = takeShot(name, join(opts.artifacts, `${String(shots.length).padStart(2, '0')}-${name}-anim${attempt}.png`));
    if (!again) return;
    if (!sameInBox(first, again, box)) {
      for (const line of sdkLines()) info(`ti-pet.log: ${line}`);
      return pass(`${name}: the pets animate`);
    }
  }
  const lines = [...petLogTail(/appearance|frames:/, 2), ...sdkLines()];
  const text = `${name}: the pets never changed in 5 shots: frozen frames (${lines.join(' | ') || 'no ti-pet.log lines'})`;
  if (opts.strictPixels) fail(text);
  warn(text);
}

// --------------------------------------------------------- ti-pet.log

/** ti-pet's stderr (spawnPet; TI_PET_DEBUG=1 adds motion / walk / frames lines). */
let petLogFile = null;
function petLogLines() {
  try {
    return readFileSync(petLogFile, 'utf8').split('\n').filter(Boolean);
  } catch {
    return [];
  }
}
/** The last `n` ti-pet.log lines matching `re`. */
const petLogTail = (re, n = 3) => petLogLines().filter((l) => re.test(l)).slice(-n);

// ------------------------------------------------------- pointer (Linux)

/** Linux with xdotool: real pointer input into the pet's X11 windows. */
const canClick = () => platform === 'linux' && petPid !== null && haveTool('xdotool', ['version']);
const xdo = (args) => execFileSync('xdotool', args, { encoding: 'utf8', timeout: 10_000 });

function xGeom(id) {
  const geo = execFileSync('xwininfo', ['-id', id], { encoding: 'utf8', timeout: 10_000 });
  const num = (re) => Number(re.exec(geo)?.[1] ?? NaN);
  return { x: num(/Absolute upper-left X:\s*(-?\d+)/), y: num(/Absolute upper-left Y:\s*(-?\d+)/), w: num(/Width:\s*(\d+)/), h: num(/Height:\s*(\d+)/) };
}

/** The pet's visible windows: the pet (the largest) and its bubble / panel. */
function petXWindows() {
  let ids = [];
  try {
    ids = xdo(['search', '--onlyvisible', '--pid', String(petPid)]).split('\n').filter((id) => /^\d+$/.test(id));
  } catch {
    // none visible
  }
  const wins = ids.map((id) => ({ id, ...xGeom(id) })).filter((w) => w.w > 2 && w.h > 2);
  wins.sort((a, b) => b.w * b.h - a.w * a.h);
  return { main: wins[0] ?? null, float: wins[1] ?? null };
}

/**
 * No `--sync`: it waits for a pointer motion event, and a move to where the
 * pointer already is sends none, so it hangs until the timeout (Xvfb).
 */
function pointerTo(x, y) {
  xdo(['mousemove', String(Math.round(x)), String(Math.round(y))]);
}

/**
 * Move the pointer to the screen corner, off the pets: xdotool on Linux,
 * PowerShell on Windows (no input tool there, but the cursor can be set).
 * A pet that walked under a resting pointer keeps a hover that blocks
 * roaming and keeps the panel open (both by design). macOS: no tool.
 */
function parkPointer() {
  if (canClick()) return pointerTo(2, 2);
  if (platform !== 'win32') return;
  const ps =
    'Add-Type -AssemblyName System.Windows.Forms; ' +
    '[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(2, 2)';
  try {
    execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', ps], { timeout: 20_000, stdio: 'ignore' });
  } catch (error) {
    warn(`moving the pointer away failed: ${error.message.split('\n')[0]}`);
  }
}

async function clickAt(x, y) {
  pointerTo(x, y);
  await sleep(150);
  xdo(['click', '1']);
}

/**
 * Click along a horizontal band of `win` (`yFromBottom` above its bottom
 * edge) until `done()`; resolves the point that did it, or null. Buttons
 * sit on the card's last row; a click beside them lands on the card.
 */
async function clickScan(win, { yFromBottom, fromRight = false, step = 12 }, done, waitMs = 500) {
  const y = win.y + win.h - yFromBottom;
  const xs = [];
  for (let x = win.x + 14; x <= win.x + win.w - 14; x += step) xs.push(x);
  if (fromRight) xs.reverse();
  for (const x of xs) {
    await clickAt(x, y);
    const t0 = Date.now();
    while (Date.now() - t0 < waitMs) {
      if (done()) return { x, y };
      await sleep(50);
    }
  }
  return null;
}

// ------------------------------------------------------------ connection

/** One Electron connection: hello → ready, then lines both ways. */
function connect(socketPath, token, timeoutMs) {
  return new Promise((resolvePromise, reject) => {
    const conn = createConnection(socketPath);
    const received = [];
    const waiters = new Set();
    let buffer = '';
    let ready = null;
    let closed = false;
    let protocolError = null;
    const timer = setTimeout(() => {
      conn.destroy();
      reject(new SmokeError('no ready within the timeout'));
    }, timeoutMs);
    const notify = () => {
      for (const w of waiters) w();
    };
    conn.on('error', (error) => {
      clearTimeout(timer);
      if (!ready) reject(error);
    });
    conn.on('connect', () => {
      conn.write(encodeLine({ kind: 'hello', token, protocol: NATIVE_PROTOCOL_VERSION, appVersion: 'smoke' }));
    });
    conn.on('data', (chunk) => {
      buffer += chunk.toString('utf8');
      let index;
      while ((index = buffer.indexOf('\n')) !== -1) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 1);
        if (!line.trim()) continue;
        let message = null;
        try {
          message = validateFromNative(JSON.parse(line));
        } catch {
          // handled below
        }
        if (!message || Buffer.byteLength(line) > MAX_LINE_BYTES) {
          protocolError = `invalid line from the pet: ${line.slice(0, 200)}`;
          notify();
          continue;
        }
        info(`← ${line}`);
        if (!ready) {
          if (message.kind !== 'ready') {
            protocolError = `first line was ${message.kind}, not ready`;
            continue;
          }
          ready = message;
          clearTimeout(timer);
          resolvePromise(api);
          continue;
        }
        message.at = Date.now();
        received.push(message);
        notify();
      }
    });
    conn.on('close', () => {
      closed = true;
      clearTimeout(timer);
      if (!ready) reject(new SmokeError('connection closed before ready (wrong token?)'));
      notify();
    });
    const api = {
      get ready() {
        return ready;
      },
      get closed() {
        return closed;
      },
      received,
      send(message) {
        info(`→ ${JSON.stringify(message).slice(0, 300)}`);
        conn.write(encodeLine(message));
      },
      /** Fail on any `error` line or invalid line so far. */
      check(step) {
        if (protocolError) fail(`${step}: ${protocolError}`);
        const error = received.find((m) => m.kind === 'error');
        if (error) fail(`${step}: pet sent error ${error.code}: ${error.message}`);
      },
      /** Wait until `pred()` or the timeout; resolves the elapsed ms or null. */
      waitFor(pred, ms) {
        const t0 = Date.now();
        return new Promise((done) => {
          const check = () => {
            if (pred()) {
              cleanup();
              done(Date.now() - t0);
            }
          };
          const t = setTimeout(() => {
            cleanup();
            done(null);
          }, ms);
          const cleanup = () => {
            clearTimeout(t);
            waiters.delete(check);
          };
          waiters.add(check);
          check();
        });
      },
      end() {
        conn.end();
      }
    };
  });
}

async function connectUntil(socketPath, tokenPath, deadline, checkSocket) {
  let lastError = null;
  while (Date.now() < deadline) {
    if (checkSocket()) {
      try {
        const token = readFileSync(tokenPath, 'utf8').trim();
        return await connect(socketPath, token, Math.max(500, deadline - Date.now()));
      } catch (error) {
        lastError = error;
      }
    }
    await sleep(100);
  }
  fail(`could not connect to ${socketPath}: ${lastError?.message ?? 'socket never appeared'}`);
}

// ------------------------------------------------------------------ pet

function writeToken(tokenPath) {
  const token = randomBytes(32).toString('hex');
  writeFileSync(tokenPath, `${token}\n`, { mode: 0o600 });
  if (platform !== 'win32') chmodSync(tokenPath, 0o600);
  return token;
}

/** A Unix socket Electron would trust: ours, mode without group/other bits. */
function socketIsSafe(socketPath) {
  if (platform === 'win32') return true;
  try {
    const st = lstatSync(socketPath);
    return st.isSocket() && st.uid === process.getuid() && (st.mode & 0o077) === 0;
  } catch {
    return false;
  }
}

/** Does the named pipe / socket still accept connections? */
function endpointAlive(socketPath) {
  return new Promise((done) => {
    const c = createConnection(socketPath);
    const t = setTimeout(() => {
      c.destroy();
      done(true);
    }, 1500);
    c.on('connect', () => {
      clearTimeout(t);
      c.destroy();
      done(true);
    });
    c.on('error', () => {
      clearTimeout(t);
      done(false);
    });
  });
}

/** Spawn ti-pet with Electron's argv (native-pet.mjs nativeArgs / spawnNative). */
function spawnPet(binary, { userDataDir, socketPath, tokenPath, appStub, appLog, logFile }) {
  const args = [
    '--socket',
    socketPath,
    '--token-file',
    tokenPath,
    '--user-data',
    userDataDir,
    '--app',
    process.execPath,
    '--app-arg',
    appStub,
    '--app-arg',
    appLog
  ];
  const env = { ...process.env };
  if (platform === 'linux') env.GDK_BACKEND = 'x11';
  // Walking, motion gates and frame ticks in ti-pet.log (main.zig dlog).
  env.TI_PET_DEBUG = '1';
  const fd = openSync(logFile, 'a');
  const child = spawn(binary, args, { detached: true, stdio: ['ignore', fd, fd], env, windowsHide: true });
  const exit = new Promise((done) => {
    child.on('exit', (code, signal) => done({ code, signal }));
    child.on('error', (error) => done({ code: null, signal: null, error }));
  });
  return { child, exit, args };
}

function exitedWithin(exit, ms) {
  return Promise.race([exit, sleep(ms).then(() => null)]);
}

const menu = {
  tray: [
    { id: 'tray.open-tracinginsights', label: 'Open TracingInsights', offline: { do: 'open', path: '/' } },
    { id: 'tray.choose-pet', label: 'Choose pet…', offline: { do: 'open', path: '/settings/pets' } },
    { id: 'tray.hide-pet', label: 'Hide pet', offline: { do: 'toggle-pet' } },
    {
      id: 'tray.quiet',
      label: 'Quiet',
      submenu: [
        { id: 'tray.quiet.for-1-hour', label: 'For 1 hour', offline: { do: 'quiet', kind: '1h' } },
        { id: 'tray.quiet.off', label: 'Off', type: 'radio', checked: true, offline: { do: 'quiet', kind: 'off' } }
      ]
    },
    { id: 'tray.launch-at-login', label: 'Launch at login', type: 'checkbox', checked: false, offline: { do: 'launch-at-login' } },
    { id: 'tray.sep-1', label: '', type: 'separator' },
    { id: 'tray.quit', label: 'Quit', offline: { do: 'quit' } }
  ],
  pet: [
    { id: 'pet.open-tracinginsights', label: 'Open TracingInsights', offline: { do: 'open', path: '/' } },
    { id: 'pet.size', label: 'Size', submenu: [{ id: 'pet.size.small', label: 'Small', type: 'radio', checked: false, offline: { do: 'size', size: 's' } }] }
  ]
};

function renderPayload(sheets, { duo = false, bubble = null, state = 'idle', row = 0, frames = 6, durationMs = 1100, playKey = 'idle', still = false, first = null, extra = {} } = {}) {
  return {
    state,
    row,
    frames,
    durationMs,
    once: false,
    still,
    playKey,
    bubble,
    size: 'm',
    atlas: first ?? { path: sheets.first, rows: 9, scale: 1 },
    second: duo ? { path: sheets.second, rows: 9, scale: 1 } : null,
    // round 3 (motion, sleeping, bubbleActions, panel, badge, secondAnim)
    ...extra
  };
}

/** A small valid v1 timeline (timeline.mjs shape): a moment now, then idle. */
function timelineDoc(sheets, nowMs, today) {
  const iso = (ms) => new Date(ms).toISOString();
  const visible = (at, extra) => ({
    at: iso(at),
    visible: true,
    state: 'idle',
    row: 0,
    frames: 6,
    durationMs: 1100,
    once: false,
    still: false,
    playKey: 'idle',
    bubble: null,
    bubbleTarget: null,
    duo: true,
    moment: null,
    ...extra
  });
  return {
    v: TIMELINE_VERSION,
    generatedAt: iso(nowMs - 1000),
    until: iso(nowMs + 7 * 86_400_000),
    // Far enough that the pet never starts the app during the smoke.
    refreshAt: iso(nowMs + 6 * 86_400_000),
    pets: {
      first: { id: 'smoke-a', path: sheets.first, rows: 9, scale: 1 },
      second: { id: 'smoke-b', path: sheets.second, rows: 9, scale: 1 }
    },
    size: 'm',
    quietUntil: null,
    sessionReactions: 'calm',
    entries: [
      visible(nowMs - 1000, {
        bubble: `On this day · ${today}`,
        bubbleTarget: `/stats/on-this-day/${today}`,
        moment: { name: 'lastFactDay', value: today }
      }),
      visible(nowMs + 120_000, { state: 'waiting', row: 6, frames: 6, durationMs: 1010, playKey: 'waiting' }),
      { at: iso(nowMs + 600_000), visible: false }
    ],
    sessions: [
      {
        key: 'smoke-race',
        kind: 'race',
        label: 'Race',
        gp: 'Smoke GP',
        start: iso(nowMs + 3 * 86_400_000),
        end: iso(nowMs + 3 * 86_400_000 + 2 * 3_600_000)
      }
    ],
    duo: { text: 'Smoke A vs Smoke B', target: '/stats/compare' },
    calendarTarget: '/',
    countdown: { format: 'v1' }
  };
}

/**
 * A v2 timeline (round 3): an 11-row first sheet, a greeting moment whose
 * bubble has OK / mute buttons and whose partner waves late, and a static
 * click panel whose buttons open the app.
 */
function timelineDocV2(sheets, nowMs, today, greetingKey) {
  const doc = timelineDoc(sheets, nowMs, today);
  doc.v = TIMELINE_VERSION_V2;
  doc.pets.first = { id: 'smoke-c', path: sheets.firstV2, rows: 11, scale: 1 };
  doc.entries[0] = {
    ...doc.entries[0],
    bubble: 'Race weekend · Smoke GP',
    bubbleTarget: '/',
    moment: { name: 'lastGreetingKey', value: greetingKey },
    motion: null,
    sleeping: false,
    bubbleActions: [
      { id: 'ok', label: 'OK' },
      { id: 'mute', label: 'No greetings' }
    ],
    bubbleKind: 'greeting',
    secondAnim: { state: 'waving', row: 3, frames: 4, durationMs: 700, once: true, still: false, playKey: 'greeting:second', delayMs: 700 }
  };
  doc.panel = {
    lines: ['Smoke A P1 · Smoke GP'],
    countdown: true,
    actions: [
      { id: 'stats', label: 'On this day', target: '/stats/on-this-day' },
      { id: 'pets', label: 'Pets', target: '/settings/pets' }
    ]
  };
  return doc;
}

function readState(statePath) {
  try {
    return parseNativeState(JSON.parse(readFileSync(statePath, 'utf8')));
  } catch {
    return null;
  }
}

async function waitForState(statePath, pred, ms) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    const st = readState(statePath);
    if (st && pred(st)) return st;
    await sleep(200);
  }
  return null;
}

// ------------------------------------------------------------------ main

const summary = { platform, arch: process.arch, binary: opts.binary, ok: false, steps: passed, warnings, screenshots: shots };

async function smoke(cleanup) {
  if (!existsSync(opts.binary)) fail(`binary not found: ${opts.binary}`);
  const userDataDir = mkdtempSync(join(tmpdir(), 'ti-pet-smoke-'));
  cleanup.push(() => !opts.keep && rmSync(userDataDir, { recursive: true, force: true }));
  info(`userData ${userDataDir}`);
  const sheets = {
    first: writePet(userDataDir, 'smoke-a', COLORS.first),
    second: writePet(userDataDir, 'smoke-b', COLORS.second),
    // v2 (8x11) sheet, same colour as the first pet
    firstV2: writePet(userDataDir, 'smoke-c', COLORS.first, 11)
  };
  const socketPath = nativeSocketPath({ platform, userDataDir, tmpDir: tmpdir() });
  const tokenPath = join(userDataDir, TOKEN_FILE);
  // The pet's app launches (refresh / open) run this stub, which only logs.
  const appStub = join(opts.artifacts, 'app-stub.cjs');
  const appLog = join(opts.artifacts, 'app-launches.log');
  writeFileSync(appStub, "require('fs').appendFileSync(process.argv[2], JSON.stringify(process.argv.slice(3)) + '\\n');\n");
  rmSync(appLog, { force: true });
  writeToken(tokenPath);

  petLogFile = join(opts.artifacts, 'ti-pet.log');
  rmSync(petLogFile, { force: true });
  const pet = spawnPet(opts.binary, {
    userDataDir,
    socketPath,
    tokenPath,
    appStub,
    appLog,
    logFile: petLogFile
  });
  cleanup.push(() => {
    if (pet.child.exitCode === null && pet.child.signalCode === null) {
      info(`killing ti-pet pid ${pet.child.pid}`);
      try {
        pet.child.kill('SIGKILL');
      } catch {
        // already gone
      }
    }
    if (platform !== 'win32') rmSync(socketPath, { force: true });
  });
  petPid = pet.child.pid;
  info(`spawned ti-pet pid ${pet.child.pid}: ${pet.args.join(' ')}`);
  // Off the pet before it shows: a hover would hold its walk back 30 s.
  if (canClick()) pointerTo(2, 2);
  let early = null;
  void pet.exit.then((r) => {
    early = r;
  });

  // --- hello / ready
  const deadline = Date.now() + opts.timeoutMs;
  const conn = await connectUntil(socketPath, tokenPath, deadline, () => {
    if (early) fail(`ti-pet exited before ready: ${JSON.stringify(early)}`);
    return socketIsSafe(socketPath);
  });
  const ready = conn.ready;
  if (ready.protocol !== NATIVE_PROTOCOL_VERSION) fail(`ready.protocol ${ready.protocol}`);
  if (!ready.version) fail('ready.version missing');
  if (ready.pid !== pet.child.pid) {
    fail(`ready.pid ${ready.pid} is not the spawned pid ${pet.child.pid} (the desktop refuses such a pipe on Windows)`);
  }
  pass(`hello → ready (version ${ready.version}, caps ${ready.caps.join(',')}, pid ${ready.pid})`);
  // What the pet reads from the OS (reduce motion stills it while undriven).
  const appearanceDeadline = Date.now() + 3000;
  while (Date.now() < appearanceDeadline && petLogTail(/appearance/).length === 0) await sleep(100);
  info(`ti-pet.log: ${petLogTail(/appearance/, 1)[0] ?? 'no appearance line yet'}`);
  // Windows: the present path the pet window took (ti-pet-sdk-windows-present.patch).
  if (platform === 'win32') info(`ti-pet.log: ${petLogTail(/ sdk: window /, 1)[0] ?? 'no sdk: window line yet'}`);
  if (platform === 'darwin') {
    const reduce = spawnSync('defaults', ['read', 'com.apple.universalaccess', 'reduceMotion'], { encoding: 'utf8', timeout: 10_000 });
    info(`macOS reduceMotion setting: ${(reduce.stdout || reduce.stderr || '').trim() || 'unreadable'}`);
  }
  if (platform !== 'win32') pass('socket is ours with mode 0600');

  // --- menu, show, renders
  conn.send({ kind: 'menu', ...menu });
  await sleep(400);
  conn.check('menu');
  pass('menu accepted');

  conn.send({ kind: 'show', size: 'm', duo: false, position: { x: 320, y: 260 } });
  await sleep(300);
  conn.check('show');
  pass('show accepted');

  conn.send({ kind: 'render', payload: renderPayload(sheets) });
  await capture('render-solo', { first: true, second: false });
  conn.check('render solo');
  pass('render solo accepted');

  conn.send({ kind: 'render', payload: renderPayload(sheets, { duo: true, state: 'waving', row: 3, frames: 4, durationMs: 700, playKey: 'wave' }) });
  await capture('render-duo', { first: true, second: true });
  await animatesCheck('render-duo');
  conn.check('render duo');
  pass('render duo accepted');

  conn.send({ kind: 'render', payload: renderPayload(sheets, { duo: true, bubble: 'Smoke test · bubble from Electron' }) });
  await capture('bubble', { first: true, second: true, bubble: true }, { before: 'render-duo' });
  conn.check('bubble');
  pass('render with bubble accepted');

  conn.send({ kind: 'hide' });
  await capture('hidden', { first: false, second: false });
  conn.check('hide');
  pass('hide accepted');

  conn.send({ kind: 'show', size: 'm', duo: true, position: null });
  conn.send({ kind: 'render', payload: renderPayload(sheets, { duo: true }) });
  await capture('shown-again', { first: true, second: true });
  conn.check('show again');
  pass('show after hide accepted');

  await roundThreeLive(conn, ready, sheets);

  // --- handoff
  const nowMs = Date.now();
  const today = new Date(nowMs).toISOString().slice(0, 10);
  const timelinePath = join(userDataDir, TIMELINE_FILE);
  writeFileSync(timelinePath, `${JSON.stringify(timelineDoc(sheets, nowMs, today), null, 2)}\n`);
  conn.send({ kind: 'handoff', timelinePath });
  const ackMs = await conn.waitFor(
    () => conn.received.some((m) => m.kind === 'ack' || m.kind === 'error'),
    Math.max(3000, HANDOFF_ACK_MS)
  );
  conn.check('handoff');
  if (ackMs === null) fail('no ack for handoff within 3 s');
  if (ackMs > HANDOFF_ACK_MS) warn(`handoff ack took ${ackMs} ms (Electron waits ${HANDOFF_ACK_MS} ms)`);
  pass(`handoff → ack in ${ackMs} ms`);

  // Electron exits after the ack: the pet plays the timeline on its own.
  conn.end();
  await conn.waitFor(() => conn.closed, 3000);
  const statePath = join(userDataDir, NATIVE_STATE_FILE);
  let stateDoc = null;
  const stateDeadline = Date.now() + 8000;
  while (Date.now() < stateDeadline) {
    if (existsSync(statePath)) {
      try {
        stateDoc = JSON.parse(readFileSync(statePath, 'utf8'));
        break;
      } catch {
        // mid-write is impossible (atomic rename), but retry anyway
      }
    }
    await sleep(200);
  }
  if (!stateDoc) fail(`${NATIVE_STATE_FILE} did not appear after the timeline's moment`);
  const parsed = parseNativeState(stateDoc);
  if (!parsed) fail(`${NATIVE_STATE_FILE} rejected: ${JSON.stringify(stateDoc)}`);
  if (!parsed.markers.some((m) => m.name === 'lastFactDay' && m.value === today)) {
    fail(`${NATIVE_STATE_FILE} lacks the shown moment: ${JSON.stringify(stateDoc)}`);
  }
  if (platform !== 'win32' && (lstatSync(statePath).mode & 0o077) !== 0) {
    fail(`${NATIVE_STATE_FILE} is readable by group/other`);
  }
  pass(`timeline moment recorded in ${NATIVE_STATE_FILE}`);
  await capture('timeline', { first: true, second: true, bubble: true }, { before: 'shown-again' });
  if (early) fail(`ti-pet exited after the handoff: ${JSON.stringify(early)}`);
  pass('pet keeps running after Electron left');

  // --- the next Electron adopts the pet (fresh token, re-read on hello)
  writeToken(tokenPath);
  const again = await connectUntil(socketPath, tokenPath, Date.now() + opts.timeoutMs, () => socketIsSafe(socketPath));
  if (again.ready.pid !== ready.pid) fail(`adopted pet reports pid ${again.ready.pid}, was ${ready.pid}`);
  pass('reconnect with a rotated token → ready (adopt)');
  again.send({ kind: 'menu', ...menu });
  await sleep(300);
  again.check('menu after adopt');

  // --- round 3 offline: a v2 timeline, then the next Electron adopts again
  await roundThreeOffline(again, { sheets, timelinePath, statePath, today, appLog });
  writeToken(tokenPath);
  const last = await connectUntil(socketPath, tokenPath, Date.now() + opts.timeoutMs, () => socketIsSafe(socketPath));
  if (last.ready.pid !== ready.pid) fail(`adopted pet reports pid ${last.ready.pid}, was ${ready.pid}`);
  pass('reconnect after the v2 timeline → ready (adopt)');

  // --- quit
  last.send({ kind: 'quit' });
  const closedMs = await last.waitFor(() => last.closed, opts.timeoutMs);
  if (closedMs === null) fail('connection still open after quit');
  const exit = await exitedWithin(pet.exit, opts.timeoutMs);
  if (!exit) fail(`ti-pet still running ${opts.timeoutMs} ms after quit`);
  if (exit.error) fail(`ti-pet process error: ${exit.error.message}`);
  // main.zig quitPet ends the process with SIGTERM on Linux / macOS (and
  // exit(0) on Windows), after removing the socket.
  const byDesign = platform !== 'win32' && exit.signal === 'SIGTERM';
  if (exit.code !== 0 && !byDesign) fail(`ti-pet exit ${JSON.stringify(exit)} after quit (want code 0)`);
  pass(`quit → ${byDesign ? 'self-SIGTERM (quitPet)' : 'exit code 0'} (connection closed in ${closedMs} ms)`);
  if (platform === 'win32') {
    if (await endpointAlive(socketPath)) fail('named pipe still accepts connections after exit');
    pass('named pipe gone');
  } else {
    if (existsSync(socketPath)) fail(`socket ${socketPath} left behind`);
    pass('socket removed');
  }

  if (existsSync(appLog)) {
    // Offline clicks (bubble text, panel buttons) start the app on purpose.
    const other = readFileSync(appLog, 'utf8').trim().split('\n').filter((l) => l && !l.includes('--pets-open='));
    if (other.length > 0) warn(`the pet launched the app during the smoke: ${other.join(' | ')}`);
  }
}

/** Round 3 while Electron drives: what the payload carries is drawn, button presses come back. */
async function roundThreeLive(conn, ready, sheets) {
  const missing = ROUND3_CAPS.filter((c) => !ready.caps.includes(c));
  if (missing.length > 0) fail(`ready.caps lacks round-3 capabilities: ${missing.join(', ')}`);
  pass(`ready.caps lists round 3 (${ROUND3_CAPS.join(', ')})`);
  // Keep the pointer off the pet: a hover stops walking.
  parkPointer();

  // A v2 look-around row on the 11-row sheet; the 9-row partner plays idle.
  const v2 = { path: sheets.firstV2, rows: 11, scale: 1 };
  conn.send({ kind: 'render', payload: renderPayload(sheets, { duo: true, first: v2, state: 'look-a', row: 9, frames: 8, durationMs: 1120, playKey: 'look-a:1' }) });
  await capture('look-a', { first: true, second: true, rows: { first: 9, second: 0 } });
  conn.check('look-a');
  pass('v2 look-around row accepted');

  // The partner's own reaction (secondAnim), started late.
  const wave = { state: 'waving', row: 3, frames: 4, durationMs: 700, once: false, still: false, playKey: 'duo-wave', delayMs: 300 };
  conn.send({ kind: 'render', payload: renderPayload(sheets, { duo: true, extra: { secondAnim: wave } }) });
  await capture('second-anim', { first: true, second: true, rows: { first: 0, second: 3 } });
  conn.check('secondAnim');
  pass('secondAnim accepted');

  // Asleep: a still frame and the "z z" mark.
  conn.send({ kind: 'render', payload: renderPayload(sheets, { duo: true, still: true, extra: { sleeping: true } }) });
  await capture('sleeping', { first: true, second: true, zz: true, badge: false }, { ref: 'second-anim' });
  await stillCheck('sleeping');
  conn.check('sleeping');
  pass('sleeping accepted');

  // The answer-ready badge (the pet is awake again: no "z z").
  conn.send({ kind: 'render', payload: renderPayload(sheets, { duo: true, extra: { badge: { kind: 'answer', label: 'Answer ready' } } }) });
  await capture('badge', { first: true, second: true, badge: true, zz: false }, { ref: 'second-anim' });
  conn.check('badge');
  pass('badge accepted');

  // A dash: out to an edge and back to where it started, at once.
  const start = canClick() ? petXWindows().main : null;
  conn.send({ kind: 'render', payload: renderPayload(sheets, { duo: true, playKey: 'calendar:smoke:live', extra: { motion: 'dash' } }) });
  if (start) {
    let far = 0;
    let back = false;
    const t0 = Date.now();
    while (Date.now() - t0 < 12_000) {
      await sleep(120);
      const w = petXWindows().main;
      if (!w) continue;
      far = Math.max(far, Math.abs(w.x - start.x));
      if (far > 60 && Math.abs(w.x - start.x) <= 2) {
        back = true;
        break;
      }
    }
    if (far <= 60) fail(`dash: the pet did not run (moved ${far} px)`);
    if (!back) fail('dash: the pet did not come back to where it started');
    pass(`dash: ran ${far} px and came back in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
    // Back where it started: nothing to save (a walk saves only when it moved).
    await sleep(300);
    if (conn.received.some((m) => m.kind === 'position' && m.walk)) fail('dash: saved a position though it came back');
  } else {
    await sleep(9000);
  }
  // Every platform: the pet's walker log (TI_PET_DEBUG) shows the run.
  const dashLines = petLogTail(/walk: .*mode=dash|motion: wanted dash/, 20);
  const ran = dashLines.some((l) => /walk: idle -> walk mode=dash/.test(l));
  const done = dashLines.some((l) => /walk: walk -> done mode=dash/.test(l));
  if (!ran || !done) {
    fail(`dash: the pet's walker never ${ran ? 'finished' : 'started'} the run (${petLogTail(/motion:|walk:|appearance/, 4).join(' | ') || 'no ti-pet.log lines'})`);
  }
  pass('dash: ti-pet.log shows the run start and end');
  conn.check('dash');

  // A roam walk: a pause (10–40 s), a walk, then `position` with walk: true.
  const sinceRoam = conn.received.length;
  conn.send({ kind: 'render', payload: renderPayload(sheets, { duo: true, extra: { motion: 'roam' } }) });
  const before = canClick() ? petXWindows().main : null;
  let walkingRow = null;
  const walked = () => conn.received.slice(sinceRoam).find((m) => m.kind === 'position' && m.walk);
  const t1 = Date.now();
  // A hover keeps the pet from roaming for 30 s; then a 10–40 s pause and the walk.
  const lastHover = Math.max(0, ...conn.received.filter((m) => m.event === 'hover').map((m) => m.at));
  const roamDeadline = Math.max(t1, lastHover + 30_000) + 50_000;
  while (!walked() && Date.now() < roamDeadline) {
    await sleep(250);
    if (!before || walkingRow !== null) continue;
    const w = petXWindows().main;
    if (w && Math.abs(w.x - before.x) > 8) {
      const img = takeShot('walking', join(opts.artifacts, 'walking.png'));
      walkingRow = img ? rowOf(img, 1) : -1;
    }
  }
  const walk = walked();
  if (!walk) {
    fail(
      `roam: no walk ended within ${Math.round((roamDeadline - t1) / 1000)} s (no position with walk: true; ti-pet.log: ${petLogTail(/motion:|walk:|appearance/, 5).join(' | ') || 'nothing'})`
    );
  }
  pass(`roam: walked, then position walk: true (x ${walk.x}) after ${((Date.now() - t1) / 1000).toFixed(1)} s`);
  if (walkingRow !== null && walkingRow !== -1) {
    if (walkingRow === 1 || walkingRow === 2) pass(`roam: running row ${walkingRow} while walking`);
    else if (opts.strictPixels) fail(`roam: row ${walkingRow} while walking (want 1 or 2)`);
    else warn(`roam: row ${walkingRow} while walking (want 1 or 2)`);
  }
  conn.send({ kind: 'render', payload: renderPayload(sheets, { duo: true }) });
  conn.check('roam');

  // Buttons under the bubble: a real click comes back as bubbleAction.
  const actions = [
    { id: 'ok', label: 'OK' },
    { id: 'quiet-1h', label: 'Quiet 1 h' },
    { id: 'mute', label: 'No daily facts' }
  ];
  conn.send({ kind: 'render', payload: renderPayload(sheets, { duo: true, bubble: 'Smoke test · bubble buttons', extra: { bubbleActions: actions } }) });
  await capture('bubble-actions', { first: true, second: true, bubble: true }, { before: 'second-anim' });
  conn.check('bubble-actions');
  pass('bubble with buttons accepted');
  if (canClick()) {
    const { float } = petXWindows();
    if (!float) fail('bubble-actions: no bubble window to click');
    const action = () => conn.received.find((m) => m.kind === 'event' && m.event === 'bubbleAction');
    if (!(await clickScan(float, { yFromBottom: 24 }, () => Boolean(action())))) {
      fail('bubble-actions: no click on the button row came back as bubbleAction');
    }
    pass(`bubble button click → event bubbleAction ${action().id}`);
    pointerTo(2, 2);
  } else {
    warn('bubble buttons: no xdotool on this runner, clicks not checked');
  }

  // The click panel: a button click comes back as panelAction; the pet
  // closes the panel itself after 20 s without the pointer (panelAction
  // with id 'close', contract.mjs PANEL_CLOSE_ID).
  const panel = {
    lines: ['Race in 2 h · Smoke GP', 'Smoke A P1 · Smoke GP'],
    actions: [
      { id: 'ask', label: 'Ask F1' },
      { id: 'stats', label: 'On this day' },
      { id: 'pets', label: 'Pets' }
    ]
  };
  conn.send({ kind: 'render', payload: renderPayload(sheets, { duo: true, extra: { panel } }) });
  await capture('panel', { first: true, second: true, bubble: true }, { before: 'second-anim' });
  conn.check('panel');
  pass('panel accepted');
  if (canClick()) {
    const { float } = petXWindows();
    if (!float) fail('panel: no panel window to click');
    const action = () => conn.received.find((m) => m.kind === 'event' && m.event === 'panelAction' && m.id !== 'close');
    if (!(await clickScan(float, { yFromBottom: 26 }, () => Boolean(action())))) {
      fail('panel: no click on the button row came back as panelAction');
    }
    pass(`panel button click → event panelAction ${action().id}`);
  }
  // The 20 s close counts from the pointer leaving: park it off the pets
  // (on Windows the pet may have walked under the runner's resting cursor).
  parkPointer();
  const closed = (m) => m.kind === 'event' && m.event === 'panelAction' && m.id === 'close';
  const closeMs = await conn.waitFor(() => conn.received.some(closed), 24_000);
  if (closeMs === null) fail('panel: no panelAction close within 24 s of the pointer leaving');
  pass(`panel closed itself → event panelAction close (${(closeMs / 1000).toFixed(1)} s later)`);
  // Electron answers with a render without the panel.
  conn.send({ kind: 'render', payload: renderPayload(sheets, { duo: true }) });
  conn.check('panel closed');
}

/** Round 3 with Electron gone: a v2 timeline plays; offline buttons work. */
async function roundThreeOffline(conn, { sheets, timelinePath, statePath, today, appLog }) {
  const greetingKey = `${today}:evening`;
  writeFileSync(timelinePath, `${JSON.stringify(timelineDocV2(sheets, Date.now(), today, greetingKey), null, 2)}\n`);
  conn.send({ kind: 'handoff', timelinePath });
  const ackMs = await conn.waitFor(() => conn.received.some((m) => m.kind === 'ack' || m.kind === 'error'), 3000);
  conn.check('handoff v2');
  if (ackMs === null) fail('no ack for the v2 timeline within 3 s');
  pass(`v2 timeline handoff → ack in ${ackMs} ms`);
  conn.end();
  await conn.waitFor(() => conn.closed, 3000);
  if (canClick()) pointerTo(2, 2);

  const st = await waitForState(statePath, (s) => s.markers.some((m) => m.name === 'lastGreetingKey' && m.value === greetingKey), 8000);
  if (!st) fail(`the v2 greeting moment never reached ${NATIVE_STATE_FILE}`);
  pass('v2 greeting moment recorded in pet-native-state.json');
  await capture('timeline-v2', { first: true, second: true, bubble: true, rows: { first: 0, second: 3 } }, { before: 'shown-again' });

  if (!canClick()) {
    warn('offline buttons: no xdotool on this runner, clicks not checked');
    return;
  }
  // The mute button (the rightmost) records the bubble's kind for Electron.
  const { float } = petXWindows();
  if (!float) fail('timeline-v2: no bubble window to click');
  const muted = () => readState(statePath)?.mutes.includes('greeting');
  if (!(await clickScan(float, { yFromBottom: 24, fromRight: true }, muted))) {
    fail('offline mute: pet-native-state.json never got mutes: ["greeting"]');
  }
  pass('offline mute button → mutes: ["greeting"] in pet-native-state.json');
  pointerTo(2, 2);
  await sleep(600);

  // A click on the pet opens the timeline's panel; its button starts the app.
  const { main } = petXWindows();
  if (!main) fail('offline: the pet window is gone');
  await clickAt(main.x + main.w * 0.75, main.y + main.h * 0.55);
  await sleep(1500);
  const panelWin = petXWindows().float;
  if (!panelWin) fail('offline click: no panel opened');
  pass(`offline click opened the panel (${panelWin.w}x${panelWin.h})`);
  const opened = () => existsSync(appLog) && readFileSync(appLog, 'utf8').includes('--pets-open=/stats/on-this-day');
  if (!(await clickScan(panelWin, { yFromBottom: 26 }, opened, 900))) {
    fail('offline panel: no button click started the app with --pets-open=/stats/on-this-day');
  }
  pass('offline panel button → app started with --pets-open=/stats/on-this-day');
  pointerTo(2, 2);
}

/** macOS: does a copy carrying com.apple.quarantine still launch? (report only) */
async function quarantineCheck(cleanup) {
  if (platform !== 'darwin') return;
  const dir = mkdtempSync(join(tmpdir(), 'ti-pet-q-'));
  cleanup.push(() => rmSync(dir, { recursive: true, force: true }));
  const copy = join(dir, 'ti-pet-quarantined');
  copyFileSync(opts.binary, copy);
  chmodSync(copy, 0o755);
  const flag = `0081;${Math.floor(Date.now() / 1000).toString(16)};Safari;`;
  try {
    execFileSync('xattr', ['-w', 'com.apple.quarantine', flag, copy]);
  } catch (error) {
    summary.quarantine = { launched: null, note: `xattr failed: ${error.message}` };
    warn(summary.quarantine.note);
    return;
  }
  const userDataDir = join(dir, 'ud');
  mkdirSync(userDataDir);
  const socketPath = nativeSocketPath({ platform, userDataDir, tmpDir: tmpdir() });
  const tokenPath = join(userDataDir, TOKEN_FILE);
  writeToken(tokenPath);
  const pet = spawnPet(copy, {
    userDataDir,
    socketPath,
    tokenPath,
    appStub: join(opts.artifacts, 'app-stub.cjs'),
    appLog: join(opts.artifacts, 'app-launches-quarantine.log'),
    logFile: join(opts.artifacts, 'ti-pet-quarantine.log')
  });
  cleanup.push(() => {
    if (pet.child.exitCode === null && pet.child.signalCode === null) pet.child.kill('SIGKILL');
    rmSync(socketPath, { force: true });
  });
  let launched = false;
  let note = '';
  try {
    let gone = null;
    void pet.exit.then((r) => {
      gone = r;
    });
    const conn = await connectUntil(socketPath, tokenPath, Date.now() + opts.timeoutMs, () => {
      if (gone) fail(`exited: ${JSON.stringify(gone)}`);
      return socketIsSafe(socketPath);
    });
    launched = true;
    conn.send({ kind: 'quit' });
    await exitedWithin(pet.exit, opts.timeoutMs);
  } catch (error) {
    note = error.message;
  }
  const xattr = spawnSync('xattr', ['-p', 'com.apple.quarantine', copy], { encoding: 'utf8' });
  summary.quarantine = { launched, note, xattrAfter: xattr.stdout.trim() || null };
  info(`quarantined copy launched: ${launched}${note ? ` (${note})` : ''}`);
}

const cleanup = [];
let exitCode = 0;
try {
  info(`ti-pet smoke on ${platform}-${process.arch}, node ${process.version}, binary ${opts.binary}`);
  await smoke(cleanup);
  await quarantineCheck(cleanup);
  summary.ok = true;
  info(`PASS (${passed.length} checks, ${warnings.length} warnings)`);
} catch (error) {
  exitCode = 1;
  summary.error = error.message;
  log('FAIL', error instanceof SmokeError ? error.message : error.stack);
} finally {
  for (const fn of cleanup.reverse()) {
    try {
      fn();
    } catch (error) {
      log('WARN', `cleanup: ${error.message}`);
    }
  }
  writeFileSync(join(opts.artifacts, 'summary.json'), `${JSON.stringify(summary, null, 2)}\n`);
}
process.exit(exitCode);
