#!/usr/bin/env node
// Differential test: zregex against V8 on generated patterns and subjects
// (docs/REGEX_TIERS_PLAN.md, F1c). A manual tool, not a CI gate: run it when a
// change could alter captures (`zig build differential-v8`).
//
//   node scripts/test262/differential.mjs --lib PATH [--seed N] [--count N] [--out FILE]
//
// Patterns come from a fixed-seed generator biased to captures, numbered and
// named backreferences (\1-\20, \k<n>), groups and quantifiers; flags from
// {"", i, m, s, u}. For every pattern V8 accepts, each subject is run through
// both engines (exec from index 0, `d` flag on the V8 side for the indices),
// and the match, every group's [start, end] and the name -> group map are
// compared. Known deviations (D6/D7...) show up too: compare a run against a
// reference run, not against zero.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { fork } from 'node:child_process';
import { loadZRegex, ZRegexCompileError } from './zregex.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');
const args = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : dflt;
};
const LIB = path.resolve(opt('--lib', path.join(repo, 'zig-out/lib/libzregex.so')));
const SEED = Number(opt('--seed', 0xf1c));
const COUNT = Number(opt('--count', 4000));
const OUT = path.resolve(opt('--out', path.join(repo, 'zig-out/differential/results.json')));
// Subject encoding for zregex (F3c, zregex.mjs): wtf8 (default until F3d) or utf16.
const ENCODING = opt('--encoding', null) || process.env.ZREGEX_ENCODING || 'wtf8';

// mulberry32
function prng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rand = prng(SEED);
const pick = (xs) => xs[Math.floor(rand() * xs.length)];
const int = (lo, hi) => lo + Math.floor(rand() * (hi - lo + 1));

const ATOMS = ['a', 'b', '.', '\\d', '\\w', '1', ' ', '[ab]', '[^a]', 'é', '\\u0061', '\\x62'];
const QUANTS = ['', '', '', '*', '+', '?', '{1,2}', '*?', '+?', '??', '{2}'];

function genPattern() {
  let groups = 0;
  const names = [];
  function term(depth) {
    const r = rand();
    if (depth < 3 && r < 0.3) {
      groups++;
      const named = rand() < 0.3;
      let open = '(';
      if (named) {
        const n = `n${names.length}`;
        names.push(n);
        open = `(?<${n}>`;
      }
      return open + seq(depth + 1) + ')' + pick(QUANTS);
    }
    if (depth < 3 && r < 0.4) return '(?:' + seq(depth + 1) + ')' + pick(QUANTS);
    if (r < 0.55) return `\\${int(1, groups + 2 > 20 ? 20 : groups + 2)}`;
    if (r < 0.6 && names.length) return `\\k<${pick(names)}>`;
    return pick(ATOMS) + pick(QUANTS);
  }
  function seq(depth) {
    const n = int(1, 4);
    let s = '';
    for (let i = 0; i < n; i++) s += (i && rand() < 0.15 ? '|' : '') + term(depth);
    return s;
  }
  return seq(0);
}

const SUBJECT_CHARS = ['a', 'b', 'a', 'b', '1', ' ', '_', '\n', 'é', 'A', '😀'];
function genSubject() {
  let s = '';
  const n = int(0, 8);
  for (let i = 0; i < n; i++) s += pick(SUBJECT_CHARS);
  return s;
}

function v8Captures(m) {
  if (!m) return null;
  return m.indices.flatMap((p) => (p ? [p[0], p[1]] : [-1, -1]));
}

// Child: compares one case per IPC message, so a crash inside zregex (the
// recursive matcher can overflow the native stack, D14/D15) is attributed to
// that case and the parent carries on with a fresh child.
function runChild() {
  const z = loadZRegex(LIB, { encoding: ENCODING });
  process.on('message', ({ id, source, flags, subjects }) => {
    const out = [];
    let v8;
    try {
      v8 = new RegExp(source, flags + 'd');
    } catch {
      process.send({ id, v8Rejected: true, out });
      return;
    }
    for (const subject of subjects) {
      const m = v8.exec(subject);
      const expected = v8Captures(m);
      let got;
      try {
        const r = z.exec(source, flags, subject, 0, false);
        got = r ? r.captures : null;
        if (r && m) {
          const zNames = Object.fromEntries(r.names);
          for (const n of Object.keys(m.indices.groups ?? {})) {
            if (!(n in zNames)) got = [...got, `missing group name ${n}`];
          }
        }
      } catch (e) {
        if (e instanceof ZRegexCompileError) {
          out.push({ kind: 'zregex_rejects', reason: e.reason });
          break;
        }
        out.push({ kind: 'zregex_error', subject, reason: String(e.message) });
        continue;
      }
      out.push(JSON.stringify(got) === JSON.stringify(expected) ? { kind: 'same' } : { kind: 'different_result', subject, expected, got });
    }
    process.send({ id, out });
  });
}

if (process.env.ZREGEX_DIFF_CHILD === '1') {
  runChild();
} else {
  const cases = [];
  for (let i = 0; i < COUNT; i++) {
    cases.push({ id: i, source: genPattern(), flags: pick(['', '', 'i', 'm', 's', 'u']), subjects: [genSubject(), genSubject(), genSubject()] });
  }
  const divergences = [];
  const counts = { patterns: COUNT, v8Rejected: 0, zregexRejected: 0, crashed: 0, compared: 0, same: 0, differentResult: 0, zregexError: 0 };
  let next = 0;
  let child = null;
  let inFlight = null;
  const spawn = () => {
    child = fork(fileURLToPath(import.meta.url), args, { env: { ...process.env, ZREGEX_DIFF_CHILD: '1' }, stdio: ['ignore', 'ignore', 'ignore', 'ipc'] });
    child.on('message', (msg) => {
      const c = cases[msg.id];
      inFlight = null;
      if (msg.v8Rejected) counts.v8Rejected++;
      for (const r of msg.out) {
        if (r.kind === 'same') counts.same++, counts.compared++;
        else if (r.kind === 'different_result') counts.differentResult++, counts.compared++;
        else if (r.kind === 'zregex_rejects') counts.zregexRejected++;
        else counts.zregexError++;
        if (r.kind !== 'same') divergences.push({ ...r, source: c.source, flags: c.flags });
      }
      dispatch();
    });
    child.on('exit', (code, signal) => {
      if (inFlight !== null) {
        const c = cases[inFlight];
        counts.crashed++;
        divergences.push({ kind: 'crash', source: c.source, flags: c.flags, subjects: c.subjects, reason: signal ?? `exit ${code}` });
        inFlight = null;
        spawn();
        dispatch();
      }
    });
  };
  const dispatch = () => {
    if (next >= cases.length) {
      child.disconnect();
      finish(counts, divergences);
      return;
    }
    inFlight = next;
    child.send(cases[next++]);
  };
  spawn();
  dispatch();
}

function finish(counts, divergences) {
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, JSON.stringify({ seed: SEED, count: COUNT, node: process.version, counts, divergences }, null, 1));
  console.log(`differential-v8 (seed ${SEED}, ${COUNT} patterns):`, JSON.stringify(counts));
  const byKind = {};
  for (const d of divergences) (byKind[d.kind] ??= []).push(d);
  for (const [kind, list] of Object.entries(byKind)) {
    console.log(`\n${kind} (${list.length}), first 8:`);
    for (const d of list.slice(0, 8)) {
      console.log(`  /${d.source}/${d.flags} ${d.subject !== undefined ? JSON.stringify(d.subject) : ''} ${d.reason ?? `expected ${JSON.stringify(d.expected)} got ${JSON.stringify(d.got)}`}`);
    }
  }
  console.log(`\nfull report: ${path.relative(process.cwd(), OUT)}`);
}
