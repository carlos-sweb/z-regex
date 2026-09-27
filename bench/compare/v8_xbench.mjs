// V8 (Node) harness of the cross-engine benchmark (docs/BENCHMARKS.md).
//
//   node v8_xbench.mjs CORPUS_DIR                warm: every V8 case, JSON on stdout
//   node v8_xbench.mjs CORPUS_DIR --cold ID      one case, first pass in this process
//   node v8_xbench.mjs CORPUS_DIR --adv ID N     one adversarial run ('a' x N + adv_suffix)
//
// warm: one warm-up pass, then the median of up to 5 timed passes (5 s
// budget), after V8 has tiered the regexp up to native code. cold: a fresh
// process, `new RegExp` + one findAll pass, timed together: what a script
// that runs a regexp once pays (parse, bytecode or native compile, tier-up).
// V8 compiles lazily and caches compiled regexps by (source, flags) inside
// an isolate, so it has no separate compile column: the cold column holds it.
// V8 has no allocation-free matching API: "execAt" is a loop of
// RegExp.prototype.exec (one match array per match). MB/s is over the
// corpus's UTF-8 bytes, the same count for every engine.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const { cases } = JSON.parse(fs.readFileSync(path.join(here, 'cases.json'), 'utf8'));
const [corpusDir, mode, id, nArg] = process.argv.slice(2);
const now = () => process.hrtime.bigint();
const MB = 1024 * 1024;

function load(c) {
  const buf = fs.readFileSync(path.join(corpusDir, c.corpus + '.txt'));
  return { text: buf.toString('utf8'), bytes: buf.length };
}

function findAll(re, text) {
  let n = 0;
  for (const m of text.matchAll(re)) n += m.length > 0 ? 1 : 0;
  return n;
}

function execLoop(re, text, unicode) {
  re.lastIndex = 0;
  let n = 0;
  for (;;) {
    const m = re.exec(text);
    if (m === null) break;
    n++;
    if (m[0].length === 0) {
      const i = re.lastIndex;
      const cp = unicode ? text.codePointAt(i) : 0;
      re.lastIndex = i + (unicode && cp > 0xffff ? 2 : 1);
    }
  }
  return n;
}

function timed(fn, bytes) {
  let matches = fn(); // warm-up (and tier-up)
  const times = [];
  let spent = 0n;
  for (let i = 0; i < 5; i++) {
    const t0 = now();
    matches = fn();
    const dt = now() - t0;
    times.push(Number(dt));
    spent += dt;
    if (spent > 5_000_000_000n) break;
  }
  times.sort((a, b) => a - b);
  const med = times[Math.floor(times.length / 2)];
  return { mbps: bytes / MB / (med / 1e9), matches };
}

function shortNs(re, s) {
  const iters = 200000;
  for (let i = 0; i < 10000; i++) {
    re.lastIndex = 0;
    re.exec(s);
  }
  const samples = [];
  for (let k = 0; k < 11; k++) {
    const t0 = now();
    for (let i = 0; i < iters; i++) {
      re.lastIndex = 0;
      re.exec(s);
    }
    samples.push(Number(now() - t0) / iters);
  }
  samples.sort((a, b) => a - b);
  return samples[5];
}

const isV8 = (c) => c.engines.includes('v8');
if (mode === '--cold') {
  const c = cases.find((x) => x.id === id);
  const { text, bytes } = load(c);
  const t0 = now();
  const re = new RegExp(c.pattern, c.flags + 'g');
  const matches = findAll(re, text);
  const dt = Number(now() - t0);
  console.log(JSON.stringify({ engine: 'v8_cold', id, mbps: bytes / MB / (dt / 1e9), ms: dt / 1e6, matches }));
} else if (mode === '--adv') {
  const c = cases.find((x) => x.id === id);
  const input = 'a'.repeat(Number(nArg)) + (c.adv_suffix ?? 'c');
  const re = new RegExp(c.pattern, c.flags);
  const t0 = now();
  const m = re.exec(input);
  console.log(JSON.stringify({ engine: 'v8', id, n: Number(nArg), ms: Number(now() - t0) / 1e6, outcome: m ? 'match' : 'no match' }));
} else {
  const out = [];
  for (const c of cases) {
    if (!isV8(c) || c.adversarial) continue;
    const { text, bytes } = load(c);
    const unicode = /[uv]/.test(c.flags);
    const fa = timed(() => findAll(new RegExp(c.pattern, c.flags + 'g'), text), bytes);
    const reg = new RegExp(c.pattern, c.flags + 'g');
    const ex = timed(() => execLoop(reg, text, unicode), bytes);
    // Short input: a match anywhere, not only at 0, so search (g), not sticky.
    const rs = new RegExp(c.pattern, c.flags + 'g');
    out.push({ id: c.id, findall_mbps: fa.mbps, execat_mbps: ex.mbps, matches: fa.matches, exec_matches: ex.matches, short_ns: shortNs(rs, c.short) });
  }
  console.log(JSON.stringify({ engine: 'v8', node: process.version, v8: process.versions.v8, cases: out }));
}
