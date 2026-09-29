#!/usr/bin/env node
// Lookbehind differential against V8 (B′'s precheck, E1): zregex and V8 on
// every pattern of a corpus with a lookbehind (tests/corpus/lookbehind.tsv,
// the 5,580 lines of the F2c corpus V8 accepts). Each pattern is classified
// by B′'s predicate on regexpp's AST (`fixed`: every lookbehind of fixed
// length without captures or backreferences inside; `other`: the rest) and
// run on a fixed list of subjects plus one derived from the pattern, at every
// lastIndex, UTF-16 subjects, every slot compared.
//
//   node scripts/test262/lbdiff-v8.mjs --lib PATH [--out FILE] [--check REF.json] [corpus.tsv ...]
//
// `--check REF` compares with a reference run pattern by pattern (class,
// number of differing runs, first difference) and exits 1 on any new or
// changed pattern, like differential-v8's reference. Without it, the run is
// written to --out and summarized.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { RegExpParser, visitRegExpAST } from '@eslint-community/regexpp';
import { loadZRegex } from './zregex.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const args = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : dflt;
};
const LIB = path.resolve(opt('--lib', path.join(repo, 'zig-out/lib/libzregex.so')));
const OUT = path.resolve(opt('--out', path.join(repo, 'zig-out/differential/lbdiff-v8.json')));
const CHECK = opt('--check', null);
const files = [];
for (let i = 0; i < args.length; i++) {
  if (args[i].startsWith('--')) i++;
  else files.push(args[i]);
}
if (files.length === 0) files.push(path.join(repo, 'tests/corpus/lookbehind.tsv'));

const zr = loadZRegex(LIB, { encoding: 'utf16' });
const P = new RegExpParser({ ecmaVersion: 2025 });

function len(n, st) {
  switch (n.type) {
    case 'Character': case 'CharacterSet': case 'CharacterClass': case 'ExpressionCharacterClass': return 1;
    case 'ClassStringDisjunction': return null;
    case 'Assertion':
      if (n.kind === 'lookahead' || n.kind === 'lookbehind') {
        for (const a of n.alternatives) for (const e of a.elements) len(e, st);
        if (n.kind === 'lookbehind' && altLen(n.alternatives, st) === null) st.innerVar = true;
      }
      return 0;
    case 'Backreference': st.caps = true; return null;
    case 'CapturingGroup': st.caps = true; // fallthrough
    case 'Group': return altLen(n.alternatives, st);
    case 'Quantifier': { const x = len(n.element, st); if (x === null || n.min !== n.max || !isFinite(n.max)) return null; return x * n.min; }
    default: return null;
  }
}
function seqLen(a, st) { let s = 0; for (const e of a.elements) { const x = len(e, st); if (x === null) return null; s += x; } return s; }
function altLen(alts, st) { let L = null; for (const a of alts) { const s = seqLen(a, st); if (s === null) return null; if (L === null) L = s; else if (L !== s) return null; } return L ?? 0; }

const SUBJ = ['', 'a', 'ab', 'aAb', 'abc abc', 'ZkKsſ', '\xE9\xC9\xDF', '0123 45', '\u{1F600}x\u{1F600}', 'a\nb\r\nc d', 'ssσΣς', '\xC0\xE0\xD6\xF6', '--]', 'aaaaab', 'abab ab', '\xE9\xA9x\u{1F600}y', '\uD800a\uDC00', '😀', 'a\u{1D306}b\xE9'];

function run(src, flags, subjects) {
  let re; try { re = new RegExp(src, flags + 'gd'); } catch { return null; }
  const d = []; let runs = 0;
  for (const s of subjects) for (let i = 0; i <= s.length; i++) {
    runs++;
    re.lastIndex = i;
    const m = re.exec(s);
    const want = m ? m.indices.flatMap(x => x ? [x[0], x[1]] : [-1, -1]) : null;
    let got;
    try { const r = zr.exec(src, flags, s, i, false); got = r ? r.captures : null; } catch (e) { got = 'ERR ' + String(e.message).slice(-40); }
    if (JSON.stringify(want) !== JSON.stringify(got)) d.push([s, i, want, got]);
  }
  zr.clearCache();
  return { d, runs };
}

const out = [];
const sum = { fixed: { pats: 0, runs: 0, diffPats: 0, unsupported: 0 }, other: { pats: 0, runs: 0, diffPats: 0, unsupported: 0 } };
for (const file of files) for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
  if (!line || line.startsWith('#')) continue;
  const [flags0, hex] = line.split('\t');
  const flags = flags0.replace(/[gy]/g, '');
  const src = Buffer.from(hex, 'hex').toString('utf8');
  if (!/\(\?<[=!]/.test(src)) continue;
  let ast; try { ast = P.parsePattern(src, 0, src.length, { unicode: flags.includes('u'), unicodeSets: flags.includes('v') }); } catch { continue; }
  const lbs = []; visitRegExpAST(ast, { onAssertionEnter(x) { if (x.kind === 'lookbehind') lbs.push(x); } });
  if (!lbs.length) continue;
  try { new RegExp(src, flags); } catch { continue; }
  let fixed = true;
  for (const x of lbs) { const st = {}; if (altLen(x.alternatives, st) === null || st.caps || st.innerVar) fixed = false; }
  const cls = fixed ? 'fixed' : 'other';
  sum[cls].pats++;
  const lit = []; visitRegExpAST(ast, { onCharacterEnter(ch) { if (ch.value <= 0x10FFFF) lit.push(String.fromCodePoint(ch.value)); } });
  const subjects = [...SUBJ, lit.join('')];
  const r = run(src, flags, subjects);
  sum[cls].runs += r.runs;
  if (r.d.some(x => typeof x[3] === 'string' && /UnsupportedFeature/.test(x[3]))) sum[cls].unsupported++;
  if (!r.d.length) continue;
  sum[cls].diffPats++;
  let stripped = src;
  for (const x of [...lbs].sort((a, b) => b.start - a.start)) {
    if (lbs.some(o => o !== x && o.start <= x.start && o.end >= x.end)) continue;
    stripped = stripped.slice(0, x.start) + stripped.slice(x.end);
  }
  const rs = run(stripped, flags, subjects);
  const boundsSame = r.d.every(([, , w, g]) => w && Array.isArray(g) && w[0] === g[0] && w[1] === g[1]);
  out.push({ cls, src, flags: flags0, diffs: r.d.length, outside: !!(rs && rs.d.length), boundsSame, first: r.d[0], strippedFirst: rs && rs.d[0] || null });
}
fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, JSON.stringify({ sum, patterns: out }, null, 1));
console.log(JSON.stringify(sum));

if (CHECK) {
  const ref = JSON.parse(fs.readFileSync(CHECK, 'utf8'));
  const key = (p) => `${p.flags}\t${p.src}`;
  const val = (p) => JSON.stringify([p.cls, p.diffs, p.first]);
  const a = new Map(ref.patterns.map((p) => [key(p), val(p)]));
  const b = new Map(out.map((p) => [key(p), val(p)]));
  const gone = [...a.keys()].filter((k) => !b.has(k));
  const added = [...b.keys()].filter((k) => !a.has(k));
  const changed = [...b.keys()].filter((k) => a.has(k) && a.get(k) !== b.get(k));
  console.log(`lbdiff-v8 against ${path.relative(repo, CHECK)}: gone ${gone.length}, new ${added.length}, changed ${changed.length}`);
  for (const k of [...added, ...changed].slice(0, 20)) console.log(`  NEW/CHANGED /${k.split('\t')[1]}/${k.split('\t')[0]} ${b.get(k)}`.slice(0, 300));
  process.exit(added.length || changed.length ? 1 : 0);
}
