#!/usr/bin/env node
// `v` with `i` differential (F7c-0): every (flags, pattern) with both `i`
// and `v` from the corpora and test262's literals, zregex against V8 on a
// fixed subject list plus the case variants of the pattern's literals,
// every lastIndex, UTF-16, all slots.
//
//   node scripts/test262/ivdiff.mjs --lib PATH [--out FILE] [--check REF.json] [tsv:FILE | t262:DIR ...]
//
// `--check REF` compares each pattern's outcome (same / different /
// unsupported) with a reference run and exits 1 on any change or on any
// pattern that compiles and differs from V8 (F7c-0: none may).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadZRegex } from './zregex.mjs';
import { RegExpParser, visitRegExpAST } from '@eslint-community/regexpp';
const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const argv = process.argv.slice(2);
const opt = (name, dflt) => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : dflt; };
const lib = path.resolve(opt('--lib', path.join(repo, 'zig-out/lib/libzregex.so')));
const out = path.resolve(opt('--out', path.join(repo, 'zig-out/differential/ivdiff.json')));
const CHECK = opt('--check', null);
const sources = [];
for (let i = 0; i < argv.length; i++) { if (argv[i].startsWith('--')) i++; else sources.push(argv[i]); }
if (sources.length === 0) sources.push(`tsv:${path.join(repo, 'tests/corpus/f2c-2.txt')}`, `tsv:${path.join(repo, 'tests/corpus/f2c.txt')}`, `tsv:${path.join(repo, 'tests/corpus/npm.tsv')}`, `t262:${path.join(repo, '.test262/test')}`);
const zr = loadZRegex(lib, { encoding: 'utf16' });
const P = new RegExpParser({ ecmaVersion: 2025 });
const pats = new Map(); // key -> {flags, src, origin}
function add(flags, src, origin) {
  flags = flags.replace(/[gyd]/g, '');
  if (!flags.includes('i') || !flags.includes('v')) return;
  const k = flags + '\t' + src; if (!pats.has(k)) pats.set(k, { flags, src, origin });
}
for (const s of sources) {
  const cut = s.indexOf(':'); const kind = s.slice(0, cut), file = s.slice(cut + 1);
  if (kind === 'tsv') for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    if (!line || line.startsWith('#')) continue; const [f, hex] = line.split('\t'); add(f, Buffer.from(hex, 'hex').toString('utf8'), path.basename(file));
  } else if (kind === 't262') {
    const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else if (p.endsWith('.js')) {
      const src = fs.readFileSync(p, 'utf8');
      for (const m of src.matchAll(/\/((?:\\.|\[(?:\\.|[^\]\n])*\]|[^\/\n\\\[])+)\/([dgimsuvy]+)/g)) if (m[2].includes('v') && m[2].includes('i')) add(m[2], m[1], 'test262');
    } } };
    walk(file);
  }
}
const SUBJ = ['', 'a', 'A', 'aB', 'k', 'K', 'K', 's', 'S', 'ſ', '\xDF', 'ẞ', 'ss', '\xE0\xC0\xF6\xD6', 'σΣς', 'ǅǄǆ', 'İiıI', 'ⱥȺ', 'abc ABC 123 _', '\u{1F600}x', '\u{10400}\u{10428}', 'q Q'];
const res = { patterns: 0, v8Rejected: 0, compiled: 0, same: 0, different: 0, unsupported: 0, otherError: 0, runs: 0 };
const bySource = {}; const diffs = [], unsup = [], other = [], outcomes = [];
for (const { flags, src, origin } of pats.values()) {
  let re; try { re = new RegExp(src, flags + 'gd'); } catch { res.v8Rejected++; continue; }
  res.patterns++; bySource[origin] ??= { patterns: 0, same: 0, different: 0, unsupported: 0, otherError: 0 }; const b = bySource[origin]; b.patterns++;
  let compileErr = null; try { zr.exec(src, flags, '', 0, false); } catch (e) { compileErr = String(e.message); }
  if (compileErr) { const k = /UnsupportedFeature/.test(compileErr) ? 'unsupported' : 'otherError'; res[k]++; b[k]++; (k === 'unsupported' ? unsup : other).push([flags, src, compileErr.slice(-60)]); zr.clearCache(); continue; }
  res.compiled++;
  const lits = []; try { visitRegExpAST(P.parsePattern(src, 0, src.length, { unicodeSets: true }), { onCharacterEnter(c) { lits.push(String.fromCodePoint(c.value)); } }); } catch {}
  const l = lits.join(''); const subjects = [...SUBJ, l, l.toUpperCase(), l.toLowerCase()];
  let first = null, n = 0;
  for (const s of subjects) for (let i = 0; i <= s.length; i++) {
    n++; re.lastIndex = i; const m = re.exec(s); const want = m ? m.indices.flatMap(x => x ? [x[0], x[1]] : [-1, -1]) : null;
    let got; try { const r = zr.exec(src, flags, s, i, false); got = r ? r.captures : null; } catch (e) { got = 'ERR ' + String(e.message).slice(-40); }
    if (!first && JSON.stringify(want) !== JSON.stringify(got)) first = [s, i, want, got];
  }
  res.runs += n; zr.clearCache();
  outcomes.push([flags, src, first ? "different" : "same"]); if (first) { res.different++; b.different++; diffs.push({ flags, src, origin, first }); } else { res.same++; b.same++; }
}
fs.mkdirSync(path.dirname(out), { recursive: true });
const status = {};
for (const [f, s, o] of outcomes) status[f + '\t' + s] = o;
for (const [f, s] of unsup) status[f + '\t' + s] = 'unsupported';
for (const [f, s] of other) status[f + '\t' + s] = 'error';
fs.writeFileSync(out, JSON.stringify({ res, bySource, status, diffs }, null, 1));
console.log(JSON.stringify(res)); console.log(JSON.stringify(bySource));

if (CHECK) {
  const ref = JSON.parse(fs.readFileSync(CHECK, 'utf8')).status;
  const keys = new Set([...Object.keys(ref), ...Object.keys(status)]);
  const changed = [...keys].filter((k) => ref[k] !== status[k]);
  console.log(`ivdiff against ${path.relative(repo, CHECK)}: changed ${changed.length}, different ${res.different}`);
  for (const k of changed.slice(0, 20)) console.log(`  CHANGED /${k.split('\t')[1]}/${k.split('\t')[0]} ${ref[k]} -> ${status[k]}`);
  process.exit(changed.length || res.different ? 1 : 0);
}
