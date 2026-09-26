// FFI bridge from Node to libzregex (src/c_api.zig) via koffi.
//
// This is the "host" side of docs/REGEX_TIERS_PLAN.md §6.4: it owns
// everything ECMAScript-specific that zregex deliberately doesn't (lastIndex,
// the result array is built by host-exec.js). Since F3c it hands zregex the
// subject in one of two encodings (`encoding`, ZREGEX_ENCODING):
//   utf16  the string's own code units, indices as they are;
//   wtf8   WTF-8 bytes, indices mapped to byte offsets (with b+2 between
//          the two halves of a 4-byte character, see src/subject/root.zig).

import koffi from 'koffi';

const NO_CAPTURE_THRESHOLD = Number.MAX_SAFE_INTEGER;

export class ZRegexCompileError extends Error {
  constructor(source, flags, reason) {
    super(`zregex could not compile /${source}/${flags}: ${reason}`);
    this.name = 'ZRegexCompileError';
    this.reason = reason;
  }
}

export class ZRegexExecError extends Error {
  constructor(reason) {
    super(`zregex failed while matching: ${reason}`);
    this.name = 'ZRegexExecError';
    this.reason = reason;
  }
}

export class ZRegexOffsetError extends Error {
  constructor(byteOffset) {
    super(`zregex returned byte offset ${byteOffset}, which is not a code point boundary`);
    this.name = 'ZRegexOffsetError';
  }
}

/**
 * WTF-8 encode a JS string (lone surrogates are encoded as 3-byte
 * sequences; TextEncoder would replace them with U+FFFD). Also returns the
 * UTF-16 index <-> byte offset maps:
 *   unitToByte[i]  byte offset of UTF-16 index i (0..length). The second
 *                  unit of a surrogate pair maps to b+2, the position
 *                  between the halves of the pair's 4-byte sequence at b.
 *   byteToUnit[b]  UTF-16 index for a byte offset that is a position, -1
 *                  anywhere else inside a sequence.
 */
export function encodeWtf8(str) {
  const len = str.length;
  const bytes = new Uint8Array(len * 3);
  const unitToByte = new Uint32Array(len + 1);
  let b = 0;
  for (let i = 0; i < len; i++) {
    unitToByte[i] = b;
    let cp = str.charCodeAt(i);
    if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < len) {
      const lo = str.charCodeAt(i + 1);
      if (lo >= 0xdc00 && lo <= 0xdfff) {
        cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
        unitToByte[i + 1] = b + 2;
        i++;
      }
    }
    if (cp < 0x80) {
      bytes[b++] = cp;
    } else if (cp < 0x800) {
      bytes[b++] = 0xc0 | (cp >> 6);
      bytes[b++] = 0x80 | (cp & 0x3f);
    } else if (cp < 0x10000) {
      bytes[b++] = 0xe0 | (cp >> 12);
      bytes[b++] = 0x80 | ((cp >> 6) & 0x3f);
      bytes[b++] = 0x80 | (cp & 0x3f);
    } else {
      bytes[b++] = 0xf0 | (cp >> 18);
      bytes[b++] = 0x80 | ((cp >> 12) & 0x3f);
      bytes[b++] = 0x80 | ((cp >> 6) & 0x3f);
      bytes[b++] = 0x80 | (cp & 0x3f);
    }
  }
  unitToByte[len] = b;
  const byteToUnit = new Int32Array(b + 1).fill(-1);
  for (let i = len; i >= 0; i--) byteToUnit[unitToByte[i]] = i;
  return { bytes: bytes.subarray(0, b), unitToByte, byteToUnit };
}

/**
 * Native stack for FFI calls, in MiB. koffi runs synchronous calls on its
 * own stack (1 MiB by default), much smaller than the 8 MiB main-thread
 * stack a typical Linux host (and `zig test`) gives zregex; with 1 MiB the
 * recursive matcher overflows on patterns that pass elsewhere. Matching the
 * usual host stack keeps the harness measuring zregex, not koffi.
 */
const NATIVE_STACK_MIB = Number(process.env.ZREGEX_NATIVE_STACK_MB || 8);

/** The UTF-16 code units of a JS string. */
function encodeUtf16(str) {
  const units = new Uint16Array(str.length);
  for (let i = 0; i < str.length; i++) units[i] = str.charCodeAt(i);
  return units;
}

const NO_CAPTURE = 0xffffffffffffffffn;

export function loadZRegex(libPath, { encoding = process.env.ZREGEX_ENCODING || 'utf16' } = {}) {
  if (encoding !== 'wtf8' && encoding !== 'utf16') throw new Error(`unknown encoding ${encoding} (wtf8 or utf16)`);
  koffi.config({ ...koffi.config(), sync_stack_size: NATIVE_STACK_MIB * 1024 * 1024 });
  const lib = koffi.load(libPath);
  const Options = koffi.struct('ZRegexOptions', {
    case_insensitive: 'bool',
    multiline: 'bool',
    dot_all: 'bool',
    sticky: 'bool',
    unicode: 'bool',
    v: 'bool',
    max_recursion_depth: 'uint32_t',
    max_steps: 'uint64_t',
    reserved: koffi.array('uint32_t', 4),
  });
  const fn = {
    compile: lib.func('void* zregex_compile_n(const uint8_t* p, size_t len, const ZRegexOptions* opts)'),
    free: lib.func('void zregex_free(void* re)'),
    execWtf8: lib.func('int zregex_exec_wtf8(void* re, const uint8_t* s, size_t len, size_t index, bool sticky, _Inout_ uint64_t* slots, size_t n)'),
    execUtf16: lib.func('int zregex_exec_utf16(void* re, const uint16_t* s, size_t len, size_t index, bool sticky, _Inout_ uint64_t* slots, size_t n)'),
    groupCount: lib.func('size_t zregex_group_count(void* re)'),
    namedCount: lib.func('size_t zregex_named_group_count(void* re)'),
    namedName: lib.func('void* zregex_named_group_name(void* re, size_t i)'),
    namedIndex: lib.func('size_t zregex_named_group_index(void* re, size_t i)'),
    stringFree: lib.func('void zregex_string_free(void* s)'),
    lastError: lib.func('int zregex_last_error()'),
    lastErrorName: lib.func('const char* zregex_last_error_name()'),
  };

  const cache = new Map(); // `${flags}/${source}` -> compiled entry (per process)
  let lastSubject = null;
  let lastEncoded = null;
  const stats = { execCalls: 0, compileErrors: 0 };

  function compile(source, flags) {
    const key = `${flags}/${source}`;
    const hit = cache.get(key);
    if (hit) return hit;
    const { bytes } = encodeWtf8(source);
    const opts = {
      case_insensitive: flags.includes('i'),
      multiline: flags.includes('m'),
      dot_all: flags.includes('s'),
      sticky: false, // stickiness is handled by the host (matchAt vs search)
      unicode: flags.includes('u'),
      v: flags.includes('v'),
      max_recursion_depth: 0,
      max_steps: 0,
      reserved: [0, 0, 0, 0],
    };
    const handle = fn.compile(bytes, bytes.length, opts);
    if (!handle) {
      stats.compileErrors++;
      throw new ZRegexCompileError(source, flags, fn.lastErrorName() || `code ${fn.lastError()}`);
    }
    const names = [];
    const n = Number(fn.namedCount(handle));
    for (let i = 0; i < n; i++) {
      const ptr = fn.namedName(handle, i);
      names.push([koffi.decode(ptr, 'char', -1), Number(fn.namedIndex(handle, i))]);
      fn.stringFree(ptr);
    }
    const entry = { handle, groupCount: Number(fn.groupCount(handle)), names };
    cache.set(key, entry);
    return entry;
  }

  function encodeSubject(str) {
    if (str !== lastSubject) {
      lastSubject = str;
      lastEncoded = encoding === 'wtf8' ? encodeWtf8(str) : { units: encodeUtf16(str) };
    }
    return lastEncoded;
  }

  function toUnit(enc, offset) {
    if (encoding === 'utf16') return offset;
    const u = offset < enc.byteToUnit.length ? enc.byteToUnit[offset] : -1;
    if (u < 0) throw new ZRegexOffsetError(offset);
    return u;
  }

  /**
   * One match attempt for RegExpBuiltinExec. `lastIndex` is a UTF-16 index
   * (0 <= lastIndex <= S.length). Returns null, or
   *   { captures: [start0, end0, start1, end1, ...] (UTF-16, -1 = unmatched),
   *     names: [[name, groupIndex], ...] }.
   */
  function exec(source, flags, subject, lastIndex, sticky) {
    stats.execCalls++;
    const re = compile(source, flags);
    const enc = encodeSubject(subject);
    const slots = new BigUint64Array(2 * (re.groupCount + 1));
    const rc = encoding === 'wtf8'
      ? fn.execWtf8(re.handle, enc.bytes, enc.bytes.length, enc.unitToByte[lastIndex], sticky, slots, slots.length)
      : fn.execUtf16(re.handle, enc.units, enc.units.length, lastIndex, sticky, slots, slots.length);
    if (rc < 0) throw new ZRegexExecError(fn.lastErrorName() || `code ${fn.lastError()}`);
    if (rc === 0) return null;
    const captures = [];
    for (const v of slots) captures.push(v === NO_CAPTURE ? -1 : toUnit(enc, Number(v)));
    return { captures, names: re.names };
  }

  function clearCache() {
    for (const entry of cache.values()) fn.free(entry.handle);
    cache.clear();
    lastSubject = null;
    lastEncoded = null;
  }

  /** Whether zregex rejects `source` under `flags` (for parse-negative tests). */
  function rejects(source, flags) {
    const { bytes } = encodeWtf8(source);
    const opts = {
      case_insensitive: flags.includes('i'), multiline: flags.includes('m'),
      dot_all: flags.includes('s'), sticky: false,
      unicode: flags.includes('u'), v: flags.includes('v'),
      max_recursion_depth: 0, max_steps: 0, reserved: [0, 0, 0, 0],
    };
    const handle = fn.compile(bytes, bytes.length, opts);
    if (!handle) return { rejected: true, reason: fn.lastErrorName() };
    fn.free(handle);
    return { rejected: false };
  }

  return { exec, rejects, clearCache, stats, Options };
}
