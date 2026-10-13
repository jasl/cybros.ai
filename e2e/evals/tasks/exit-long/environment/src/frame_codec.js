"use strict";

// frame_codec.js — a length-prefixed frame codec for byte streams.
//
// One frame on the wire:
//
//   FLAG  escape( varint(kind) ++ varint(length) ++ payload ++ crc16_be )  FLAG
//
//   FLAG      0x7e, never appears inside a frame body (it is escaped).
//   kind      an unsigned varint, 0..127 — the frame's type as the
//             application defines it; the codec only carries it.
//   length    an unsigned varint, the payload's byte count, 0..65535.
//   payload   `length` raw bytes.
//   crc16     CRC-16/CCITT-FALSE over kind ++ length ++ payload, big-endian.
//
// Escaping (after the body is assembled, before it goes on the wire): each
// of the four reserved bytes — FLAG 0x7e, ESC 0x7d, XON 0x11, XOFF 0x13 —
// is replaced by ESC followed by the byte XOR 0x20. The two flow-control
// bytes are reserved so a frame can cross a serial link that swallows them.
//
// A stream is any number of frames; a frame's closing FLAG may serve as
// the next frame's opening FLAG, and runs of FLAGs between frames are idle
// and ignored. Bytes before the first FLAG are line noise and dropped.
//
// Decoding never throws on a bad frame: a segment (the bytes between two
// FLAGs) that cannot be read is reported as damaged — with a reason and
// how many raw bytes were skipped — and decoding resynchronises on the
// next FLAG. Reasons, in the order they are checked:
//
//   "escape"   an ESC not followed by a reserved byte, or ESC at the end
//   "length"   fewer than four bytes, an unreadable varint, or the body's
//              size disagreeing with `length`, or an overlong segment
//   "kind"     kind above 127
//   "crc"      the checksum does not match
//
// Encoding does throw: a kind outside 0..127 or a payload over MAX_PAYLOAD
// is a programming error, not a wire condition.

const FLAG = 0x7e;
const ESC = 0x7d;
const XON = 0x11;
const XOFF = 0x13;
const ESC_XOR = 0x20;

const MAX_KIND = 127;
const MAX_PAYLOAD = 65535;
const MAX_VARINT_BYTES = 5;
const MAX_VARINT_VALUE = 0xffffffff;
// The worst case for one escaped segment: every byte reserved (doubled)
// in a header of two five-byte varints, a full payload and a two-byte crc.
const MAX_SEGMENT_BYTES = 2 * (MAX_VARINT_BYTES * 2 + MAX_PAYLOAD + 2);

const CRC_POLY = 0x1021;
const CRC_INIT = 0xffff;

const RESERVED = new Set([FLAG, ESC, XON, XOFF]);

class VarintError extends Error {}
class EscapeError extends Error {}

// ---------------------------------------------------------------- bytes --

// Accepts a Uint8Array, an array of byte values, or a string (UTF-8).
function toBytes(input) {
  if (input instanceof Uint8Array) return input;
  if (Array.isArray(input)) return Uint8Array.from(input);
  if (typeof input === "string") return new TextEncoder().encode(input);
  throw new TypeError(`cannot read bytes from ${typeof input}`);
}

function concat(...parts) {
  let total = 0;
  for (const part of parts) total += part.length;
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function toHex(bytes) {
  let out = "";
  for (const byte of toBytes(bytes)) out += byte.toString(16).padStart(2, "0");
  return out;
}

function fromHex(text) {
  const clean = text.replace(/\s+/g, "");
  if (clean.length % 2 !== 0) throw new RangeError("odd number of hex digits");
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) {
    const pair = clean.slice(2 * i, 2 * i + 2);
    const value = Number.parseInt(pair, 16);
    if (Number.isNaN(value)) throw new RangeError(`not a hex pair: ${pair}`);
    out[i] = value;
  }
  return out;
}

// --------------------------------------------------------------- varint --

// Unsigned LEB128: seven bits per byte, least significant group first, the
// high bit set on every byte but the last. Values are kept below 2^32 so
// the arithmetic never touches JavaScript's signed 32-bit bitwise ops.
function encodeVarint(value) {
  if (!Number.isInteger(value) || value < 0 || value > MAX_VARINT_VALUE) {
    throw new VarintError(`varint out of range: ${value}`);
  }
  const out = [];
  let rest = value;
  do {
    let byte = rest % 128;
    rest = Math.floor(rest / 128);
    if (rest > 0) byte += 0x80;
    out.push(byte);
  } while (rest > 0);
  return Uint8Array.from(out);
}

// Reads one varint at `offset`; answers { value, next } where `next` is
// the offset of the first byte after it.
function decodeVarint(bytes, offset = 0) {
  const input = toBytes(bytes);
  let value = 0;
  let scale = 1;
  let count = 0;
  for (let i = offset; i < input.length; i++) {
    const byte = input[i];
    count += 1;
    if (count > MAX_VARINT_BYTES) throw new VarintError("varint longer than five bytes");
    value += (byte & 0x7f) * scale;
    if ((byte & 0x80) === 0) {
      if (value > MAX_VARINT_VALUE) throw new VarintError("varint exceeds 32 bits");
      return { value, next: i + 1 };
    }
    scale *= 128;
  }
  throw new VarintError("truncated varint");
}

// ---------------------------------------------------------------- crc16 --

const CRC_TABLE = (() => {
  const table = new Uint16Array(256);
  for (let n = 0; n < 256; n++) {
    let crc = n << 8;
    for (let bit = 0; bit < 8; bit++) {
      crc = (crc & 0x8000) !== 0 ? ((crc << 1) ^ CRC_POLY) & 0xffff : (crc << 1) & 0xffff;
    }
    table[n] = crc;
  }
  return table;
})();

// CRC-16/CCITT-FALSE: polynomial 0x1021, initial 0xffff, no reflection,
// no final xor. crc16("123456789") is 0x29b1.
function crc16(bytes) {
  let crc = CRC_INIT;
  for (const byte of toBytes(bytes)) {
    crc = ((crc << 8) & 0xffff) ^ CRC_TABLE[((crc >> 8) ^ byte) & 0xff];
  }
  return crc;
}

// -------------------------------------------------------------- escaping --

function escape(bytes) {
  const out = [];
  for (const byte of toBytes(bytes)) {
    if (RESERVED.has(byte)) {
      out.push(ESC, byte ^ ESC_XOR);
    } else {
      out.push(byte);
    }
  }
  return Uint8Array.from(out);
}

// The inverse of `escape`. A bare FLAG cannot occur inside a segment (the
// reader split on it), but a caller handing in arbitrary bytes gets the
// same refusal a bad escape does.
function unescape(bytes) {
  const input = toBytes(bytes);
  const out = [];
  for (let i = 0; i < input.length; i++) {
    const byte = input[i];
    if (byte === FLAG) throw new EscapeError("bare flag inside a frame body");
    if (byte !== ESC) {
      out.push(byte);
      continue;
    }
    if (i + 1 >= input.length) throw new EscapeError("escape at the end of the body");
    const raw = input[i + 1] ^ ESC_XOR;
    if (!RESERVED.has(raw)) {
      throw new EscapeError(`invalid escape sequence 7d ${input[i + 1].toString(16).padStart(2, "0")}`);
    }
    out.push(raw);
    i += 1;
  }
  return Uint8Array.from(out);
}

// --------------------------------------------------------------- frames --

function encodeFrame(kind, payload) {
  if (!Number.isInteger(kind) || kind < 0 || kind > MAX_KIND) {
    throw new RangeError(`kind must be 0..${MAX_KIND}: ${kind}`);
  }
  const body = toBytes(payload);
  if (body.length > MAX_PAYLOAD) {
    throw new RangeError(`payload of ${body.length} bytes exceeds ${MAX_PAYLOAD}`);
  }
  const content = concat(encodeVarint(kind), encodeVarint(body.length), body);
  const crc = crc16(content);
  const framed = concat(content, Uint8Array.of(crc >> 8, crc & 0xff));
  return concat(Uint8Array.of(FLAG), escape(framed), Uint8Array.of(FLAG));
}

function damaged(reason, skipped) {
  return { ok: false, reason, skipped };
}

// One segment — the raw wire bytes between two FLAGs — to a result.
function parseSegment(raw) {
  let body;
  try {
    body = unescape(raw);
  } catch (error) {
    if (error instanceof EscapeError) return damaged("escape", raw.length);
    throw error;
  }
  // kind, length, and two crc bytes: the smallest frame has an empty payload.
  if (body.length < 4) return damaged("length", raw.length);
  let kind;
  let length;
  let offset;
  try {
    ({ value: kind, next: offset } = decodeVarint(body, 0));
    ({ value: length, next: offset } = decodeVarint(body, offset));
  } catch (error) {
    if (error instanceof VarintError) return damaged("length", raw.length);
    throw error;
  }
  if (kind > MAX_KIND) return damaged("kind", raw.length);
  if (body.length !== offset + length + 2) return damaged("length", raw.length);
  const content = body.subarray(0, offset + length);
  const expected = (body[offset + length] << 8) | body[offset + length + 1];
  if (crc16(content) !== expected) return damaged("crc", raw.length);
  return { ok: true, kind, payload: body.slice(offset, offset + length) };
}

// Incremental decoding: feed bytes as they arrive, get back the results of
// every frame that COMPLETED in that feed. A frame split across feeds is
// held until its closing FLAG; `pending` says how many bytes are held.
class FrameReader {
  constructor() {
    this.reset();
  }

  reset() {
    this.buffer = [];
    this.inFrame = false;
  }

  get pending() {
    return this.inFrame ? this.buffer.length : 0;
  }

  feed(input) {
    const results = [];
    for (const byte of toBytes(input)) {
      if (byte === FLAG) {
        if (this.inFrame && this.buffer.length > 0) {
          results.push(parseSegment(Uint8Array.from(this.buffer)));
        }
        // The closing flag opens the next frame; idle flags are ignored.
        this.buffer = [];
        this.inFrame = true;
      } else if (this.inFrame) {
        this.buffer.push(byte);
        if (this.buffer.length > MAX_SEGMENT_BYTES) {
          // A sender that never closes its frame would grow the buffer
          // without bound: give up on the segment and wait for a FLAG.
          results.push(damaged("length", this.buffer.length));
          this.buffer = [];
          this.inFrame = false;
        }
      }
      // Bytes before the first FLAG are noise and dropped.
    }
    return results;
  }
}

// Decode a whole buffer at once: every complete frame, in order, damaged
// segments included; a trailing partial frame (no closing FLAG) is dropped.
function decodeFrames(bytes) {
  return new FrameReader().feed(bytes);
}

module.exports = {
  FLAG,
  ESC,
  XON,
  XOFF,
  MAX_KIND,
  MAX_PAYLOAD,
  MAX_SEGMENT_BYTES,
  VarintError,
  EscapeError,
  toBytes,
  toHex,
  fromHex,
  encodeVarint,
  decodeVarint,
  crc16,
  escape,
  unescape,
  encodeFrame,
  decodeFrames,
  FrameReader,
};
