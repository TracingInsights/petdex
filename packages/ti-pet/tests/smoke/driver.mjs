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
 *   write a timeline + handoff → ack → disconnect (Electron exits) → the
 *   timeline's moment lands in pet-native-state.json → reconnect with a new
 *   token (the next Electron adopts the pet) → quit → the process exits
 *   and the socket is gone. macOS also launches a quarantined copy.
 *
 * The pet art is synthetic: a PNG atlas of flat coloured cells generated
 * here (magenta first pet, cyan second), never real pet art. Screenshots go
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
const NATIVE_EVENTS = ['drag', 'dragEnd', 'click', 'dblclick', 'hover', 'bubbleClick'];
const MENU_ID_RE = /^[a-z0-9.-]{1,64}$/;
const MARKER_SETTINGS = ['lastResultKey', 'lastRateKey', 'lastFactDay'];

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
      if (raw.event !== 'drag') return { kind: 'event', event: raw.event };
      if (!finiteIn(raw.dx, 10_000) || !finiteIn(raw.dy, 10_000)) return null;
      return { kind: 'event', event: 'drag', dx: raw.dx, dy: raw.dy };
    case 'position':
      if (!finiteIn(raw.x, 1e6) || !finiteIn(raw.y, 1e6)) return null;
      return { kind: 'position', x: Math.round(raw.x), y: Math.round(raw.y) };
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
  return { updatedAt: raw.updatedAt, markers };
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

/**
 * A v1 atlas (8x9 cells of 192x208): every cell a flat block of `color`
 * with a transparent margin and a black bar whose height moves with the
 * frame, so the animation is visible in a screenshot sequence.
 */
function syntheticAtlas([r, g, b]) {
  const width = CELL_W * COLS;
  const height = CELL_H * ROWS;
  const px = Buffer.alloc(width * height * 4);
  const margin = 24;
  for (let row = 0; row < ROWS; row += 1) {
    for (let col = 0; col < COLS; col += 1) {
      const barTop = margin + 20 + col * 16;
      for (let y = margin; y < CELL_H - margin / 2; y += 1) {
        const bar = y >= barTop && y < barTop + 12;
        for (let x = margin; x < CELL_W - margin; x += 1) {
          const i = ((row * CELL_H + y) * width + col * CELL_W + x) * 4;
          px[i] = bar ? 0 : r;
          px[i + 1] = bar ? 0 : g;
          px[i + 2] = bar ? 0 : b;
          px[i + 3] = 255;
        }
      }
    }
  }
  return encodePng(width, height, px);
}

/** userData/pets/<id>/{pet.json, spritesheet.png} like the pet store. */
function writePet(userDataDir, id, color) {
  const dir = join(userDataDir, 'pets', id);
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, 'pet.json'),
    `${JSON.stringify({ id, displayName: `Smoke ${id}`, description: 'Synthetic smoke-test pet (flat colour cells).', spritesheetPath: 'spritesheet.png' }, null, 2)}\n`
  );
  const sheet = join(dir, 'spritesheet.png');
  writeFileSync(sheet, syntheticAtlas(color));
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
        '$g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)',
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

/** Pixel problems of one shot: [] = as expected. */
function shotProblems(img, expect, before) {
  const pets = petPixels(img);
  const problems = [];
  if (expect.first === true && pets.first < MIN_PET_PX) problems.push('first pet not visible');
  if (expect.second === true && pets.second < MIN_PET_PX) problems.push('second pet not visible');
  if (expect.first === false && pets.first >= MIN_PET_PX) problems.push('first pet visible while hidden');
  if (expect.second === false && pets.second >= MIN_PET_PX) problems.push('second pet visible');
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
async function capture(name, expect, { before = null } = {}) {
  const file = join(opts.artifacts, `${String(shots.length + 1).padStart(2, '0')}-${name}.png`);
  let img = null;
  let result = null;
  for (let attempt = 1; attempt <= 5; attempt += 1) {
    await sleep(attempt === 1 ? 1200 : 1000); // poll tick (100 ms) + a few frames + compositor
    img = takeShot(name, file);
    if (!img) break;
    result = shotProblems(img, expect, before ? images.get(before) : null);
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

function renderPayload(sheets, { duo = false, bubble = null, state = 'idle', row = 0, frames = 6, durationMs = 1100, playKey = 'idle' } = {}) {
  return {
    state,
    row,
    frames,
    durationMs,
    once: false,
    still: false,
    playKey,
    bubble,
    size: 'm',
    atlas: { path: sheets.first, rows: 9, scale: 1 },
    second: duo ? { path: sheets.second, rows: 9, scale: 1 } : null
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

// ------------------------------------------------------------------ main

const summary = { platform, arch: process.arch, binary: opts.binary, ok: false, steps: passed, warnings, screenshots: shots };

async function smoke(cleanup) {
  if (!existsSync(opts.binary)) fail(`binary not found: ${opts.binary}`);
  const userDataDir = mkdtempSync(join(tmpdir(), 'ti-pet-smoke-'));
  cleanup.push(() => !opts.keep && rmSync(userDataDir, { recursive: true, force: true }));
  info(`userData ${userDataDir}`);
  const sheets = {
    first: writePet(userDataDir, 'smoke-a', COLORS.first),
    second: writePet(userDataDir, 'smoke-b', COLORS.second)
  };
  const socketPath = nativeSocketPath({ platform, userDataDir, tmpDir: tmpdir() });
  const tokenPath = join(userDataDir, TOKEN_FILE);
  // The pet's app launches (refresh / open) run this stub, which only logs.
  const appStub = join(opts.artifacts, 'app-stub.cjs');
  const appLog = join(opts.artifacts, 'app-launches.log');
  writeFileSync(appStub, "require('fs').appendFileSync(process.argv[2], JSON.stringify(process.argv.slice(3)) + '\\n');\n");
  rmSync(appLog, { force: true });
  writeToken(tokenPath);

  const pet = spawnPet(opts.binary, {
    userDataDir,
    socketPath,
    tokenPath,
    appStub,
    appLog,
    logFile: join(opts.artifacts, 'ti-pet.log')
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

  // --- quit
  again.send({ kind: 'quit' });
  const closedMs = await again.waitFor(() => again.closed, opts.timeoutMs);
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
    warn(`the pet launched the app during the smoke: ${readFileSync(appLog, 'utf8').trim()}`);
  }
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
