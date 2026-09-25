// test262 metadata helpers shared by the parent (run.mjs) and the workers.

/**
 * Parse the YAML frontmatter fields the harness needs. test262 uses a small
 * YAML subset; in the RegExp directories every list is inline (`[a, b]`),
 * which is all this supports -- a block list would come back empty, and
 * `readMeta` flags that as unsupported rather than guessing.
 */
export function readMeta(source) {
  const start = source.indexOf('/*---');
  const end = source.indexOf('---*/', start);
  const meta = { flags: [], includes: [], features: [], negative: null, unsupported: null };
  if (start < 0 || end < 0) return meta;
  const lines = source.slice(start + 5, end).split('\n');
  const list = (v) => {
    const m = /^\[(.*)\]\s*$/.exec(v.trim());
    return m ? m[1].split(',').map((s) => s.trim()).filter(Boolean) : null;
  };
  for (let i = 0; i < lines.length; i++) {
    const m = /^(flags|includes|features|negative):\s*(.*)$/.exec(lines[i]);
    if (!m) continue;
    const [, key, value] = m;
    if (key === 'negative') {
      const neg = {};
      for (let j = i + 1; j < lines.length && /^\s+\S/.test(lines[j]); j++) {
        const kv = /^\s+(phase|type):\s*(\S+)/.exec(lines[j]);
        if (kv) neg[kv[1]] = kv[2];
      }
      meta.negative = neg;
    } else {
      const items = list(value);
      if (items === null) meta.unsupported = `non-inline YAML list for ${key}`;
      else meta[key] = items;
    }
  }
  return meta;
}

/**
 * For parse-phase negative tests: the single regex literal that follows
 * `$DONOTEVALUATE();`, e.g. `/(?-s:a)/;` -> { body: '(?-s:a)', flags: '' }.
 * Uses the JS RegularExpressionLiteral lexical grammar (escapes and
 * `[...]` classes can hold an unescaped `/`). Returns null when the rest of
 * the file isn't exactly one literal statement (plus comments).
 */
export function extractRegexLiteral(source) {
  const marker = source.indexOf('$DONOTEVALUATE();');
  if (marker < 0) return null;
  const rest = source.slice(marker + '$DONOTEVALUATE();'.length);
  let i = 0;
  const skipSpaceAndComments = () => {
    for (;;) {
      while (i < rest.length && /\s/.test(rest[i])) i++;
      if (rest.startsWith('//', i)) {
        const nl = rest.indexOf('\n', i);
        i = nl < 0 ? rest.length : nl;
      } else if (rest.startsWith('/*', i)) {
        const close = rest.indexOf('*/', i + 2);
        if (close < 0) return false;
        i = close + 2;
      } else {
        return true;
      }
    }
  };
  if (!skipSpaceAndComments() || rest[i] !== '/') return null;
  i++;
  let body = '';
  let inClass = false;
  for (;;) {
    if (i >= rest.length) return null;
    const c = rest[i];
    if (c === '\n' || c === '\r' || c === ' ' || c === ' ') return null;
    if (c === '\\') {
      if (i + 1 >= rest.length) return null;
      body += c + rest[i + 1];
      i += 2;
      continue;
    }
    if (c === '[') inClass = true;
    else if (c === ']') inClass = false;
    else if (c === '/' && !inClass) break;
    body += c;
    i++;
  }
  i++; // closing '/'
  let flags = '';
  while (i < rest.length && /[A-Za-z0-9_$]/.test(rest[i])) flags += rest[i++];
  if (!skipSpaceAndComments()) return null;
  if (rest[i] === ';') i++;
  if (!skipSpaceAndComments() || i !== rest.length) return null;
  return { body, flags };
}

/**
 * test262 features Node's V8 doesn't support: a test using one fails in
 * V8 before zregex is involved, so it is `skipped_host`. Probed at startup
 * instead of assumed.
 */
export function probeHostFeatures() {
  const probes = {
    'regexp-duplicate-named-groups': () => new RegExp('(?<a>x)|(?<a>y)'),
    'regexp-modifiers': () => new RegExp('(?i:a)'),
    'regexp-v-flag': () => new RegExp('[a--b]', 'v'),
    // Annex B legacy RegExp features proposal: RegExp.prototype.compile
    // must reject subclass instances. Without it, V8 also keeps its own
    // RegExp.$1 & co., which the zregex exec hook never updates.
    'legacy-regexp': () => {
      class Sub extends RegExp {}
      try {
        RegExp.prototype.compile.call(new Sub('a'));
      } catch (e) {
        if (e instanceof TypeError) return;
      }
      throw new Error('missing');
    },
    'RegExp.escape': () => {
      if (typeof RegExp.escape !== 'function') throw new Error('missing');
    },
  };
  const unsupported = new Set();
  for (const [feature, probe] of Object.entries(probes)) {
    try {
      probe();
    } catch {
      unsupported.add(feature);
    }
  }
  return unsupported;
}
