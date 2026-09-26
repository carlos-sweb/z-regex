#!/usr/bin/env node
// test262 harness for zregex (docs/REGEX_TIERS_PLAN.md, phase F0b).
//
//   node scripts/test262/run.mjs [--sample N] [--filter SUBSTR] [--out FILE] [--lib PATH]
//                                [--encoding wtf8|utf16]
//                                [--check-baseline FILE | --update-baseline FILE |
//                                 --update-baseline-improvements FILE]
//
// --check-baseline compares the engine suite against a committed baseline
// and exits non-zero on a regression (pass -> anything else), on a test the
// baseline doesn't know, or on a baseline test that disappeared while the
// pinned test262 revision is unchanged. A test that starts passing is
// reported as an improvement and doesn't fail the run.
// --update-baseline writes the engine suite's current statuses (skips
// excluded, crashes included) as the new baseline. Only for a new pinned
// test262 revision: it would silently accept a regression.
// --update-baseline-improvements runs the --check-baseline check first and,
// only if it passes, records the improvements (not pass -> pass) in FILE;
// every other entry stays as it was. A regression, a new entry or a
// disappeared one fails the run without writing anything. This is the
// update used while a phase is in progress (docs/REGEX_TIERS_PLAN.md, F1).
//
// --encoding picks the subject encoding zregex runs on (F3c, zregex.mjs):
// wtf8 (default until F3d) or utf16.
//
// Environment:
//   ZREGEX_LIB               path to libzregex.so (default zig-out/lib/libzregex.so)
//   ZREGEX_ENCODING          default for --encoding
//   ZREGEX_TEST262_DIR       test262 checkout (default .test262, see fetch.sh)
//   ZREGEX_TEST_TIMEOUT_MS   per-test timeout enforced by the parent (default 20000)
//   ZREGEX_TEST_RECYCLE      tests per worker before it is replaced (default 1000)
//   ZREGEX_TEST_WORKERS      worker count (default min(os.availableParallelism(), 8))
//   ZREGEX_TEST_GC           1 = run workers with --expose-gc and force a GC before
//                            each RSS sample (to tell a leak from GC lag)

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fork } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { readMeta, probeHostFeatures } from './meta.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '../..');

const args = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : dflt;
};
const SAMPLE = opt('--sample', null) === null ? null : Number(opt('--sample'));
const FILTER = opt('--filter', null);
const OUT = path.resolve(opt('--out', path.join(repo, 'zig-out/test262/results.json')));
const CHECK = opt('--check-baseline', null);
const UPDATE = opt('--update-baseline', null);
const IMPROVE = opt('--update-baseline-improvements', null);
if ([CHECK, UPDATE, IMPROVE].filter(Boolean).length > 1) {
  console.error('--check-baseline, --update-baseline and --update-baseline-improvements are mutually exclusive');
  process.exit(2);
}
if ((UPDATE || IMPROVE) && (FILTER || SAMPLE !== null)) {
  console.error('updating the baseline needs a full run (no --filter/--sample)');
  process.exit(2);
}

const TEST262 = path.resolve(process.env.ZREGEX_TEST262_DIR || path.join(repo, '.test262'));
const LIB = path.resolve(opt('--lib', null) || process.env.ZREGEX_LIB || path.join(repo, 'zig-out/lib/libzregex.so'));
const ENCODING = opt('--encoding', null) || process.env.ZREGEX_ENCODING || 'wtf8';
const TIMEOUT_MS = Number(process.env.ZREGEX_TEST_TIMEOUT_MS || 20000);
const RECYCLE = Number(process.env.ZREGEX_TEST_RECYCLE || 1000);
const WORKERS = Number(process.env.ZREGEX_TEST_WORKERS || Math.min(os.availableParallelism(), 8));
const FORCE_GC = process.env.ZREGEX_TEST_GC === '1';

const ROOTS = [
  'built-ins/RegExp',
  'language/literals/regexp',
  'annexB/built-ins/RegExp',
  'annexB/language/literals/regexp',
];
// Tests of RegExp.prototype.exec itself measure host-exec.js (the JS
// RegExpBuiltinExec), not zregex: reported separately, outside the engine
// baseline (plan D-1).
const HOST_SUITE_PREFIX = 'built-ins/RegExp/prototype/exec/';
// Groups whose tests build huge subjects (every code point of a property,
// or loops over the whole code space). They dominate run time, so they get
// their own table.
const HEAVY_GROUPS = ['built-ins/RegExp/property-escapes/generated', 'built-ins/RegExp/CharacterClassEscapes'];
const isHeavy = (g) => HEAVY_GROUPS.some((h) => g === h || g.startsWith(`${h}/`));

const pinnedSha = fs.readFileSync(path.join(here, 'TEST262_SHA'), 'utf8').trim();
const zregexFeatureGaps = JSON.parse(fs.readFileSync(path.join(here, 'features.json'), 'utf8'));
const hostUnsupported = probeHostFeatures();

function walk(dir, out) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) walk(p, out);
    else if (ent.name.endsWith('.js') && !ent.name.includes('_FIXTURE')) out.push(p);
  }
  return out;
}

function groupOf(rel) {
  return path.dirname(rel).split('/').slice(0, 4).join('/');
}

// Deterministic PRNG so a sample is reproducible.
function mulberry32(seed) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** `n` files spread round-robin across directory groups. */
function stratifiedSample(files, n) {
  const rand = mulberry32(262);
  const groups = new Map();
  for (const f of files) {
    const g = groupOf(f);
    if (!groups.has(g)) groups.set(g, []);
    groups.get(g).push(f);
  }
  for (const list of groups.values()) {
    for (let i = list.length - 1; i > 0; i--) {
      const j = Math.floor(rand() * (i + 1));
      [list[i], list[j]] = [list[j], list[i]];
    }
  }
  const order = [...groups.keys()].sort();
  const picked = [];
  for (let round = 0; picked.length < n; round++) {
    let any = false;
    for (const g of order) {
      const list = groups.get(g);
      if (round < list.length && picked.length < n) {
        picked.push(list[round]);
        any = true;
      }
    }
    if (!any) break;
  }
  return picked;
}

// ---------------------------------------------------------------- discover
let files = [];
for (const root of ROOTS) {
  const dir = path.join(TEST262, 'test', root);
  if (fs.existsSync(dir)) walk(dir, files);
}
files = files.map((f) => path.relative(path.join(TEST262, 'test'), f)).sort();
if (files.length === 0) {
  console.error(`no tests under ${TEST262}/test -- run scripts/test262/fetch.sh first`);
  process.exit(2);
}
if (FILTER) files = files.filter((f) => f.includes(FILTER));
if (SAMPLE !== null) files = stratifiedSample(files, SAMPLE);

const results = {};
const tasks = [];
for (const rel of files) {
  const meta = readMeta(fs.readFileSync(path.join(TEST262, 'test', rel), 'utf8'));
  const modes = meta.flags.includes('onlyStrict')
    ? ['strict']
    : meta.flags.includes('noStrict') || meta.flags.includes('raw')
      ? ['sloppy']
      : meta.negative && meta.negative.phase === 'parse'
        ? ['parse'] // checked on the extracted literal; mode-independent
        : ['strict', 'sloppy'];
  for (const mode of modes) {
    const key = `${rel}|${mode}`;
    const skip = (status, detail, reason) => (results[key] = { status, reason, detail, execCalls: 0 });
    const hostGap = meta.features.find((f) => hostUnsupported.has(f));
    const zregexGap = meta.features.find((f) => f in zregexFeatureGaps);
    if (meta.unsupported) skip('harness_error', meta.unsupported);
    else if (meta.flags.includes('module') || meta.flags.includes('async')) {
      skip('skipped_host', `flags: ${meta.flags.join(', ')} not supported by the vm-based runner`, 'host_runner');
    } else if (meta.negative && meta.negative.phase === 'resolution') {
      skip('skipped_host', 'module resolution phase', 'host_runner');
    } else if (hostGap) skip('skipped_host', `Node ${process.version} lacks ${hostGap}`, 'host_feature');
    else if (zregexGap) skip('skipped_feature', `${zregexGap}: not in zregex yet (${zregexFeatureGaps[zregexGap]})`, 'zregex_feature');
    else tasks.push({ id: tasks.length, key, rel, mode, meta });
  }
}

// -------------------------------------------------------------------- pool
const started = Date.now();
const rssByWorker = [];
let next = 0;
let done = 0;

function spawnWorker(slot) {
  const child = fork(path.join(here, 'worker.mjs'), [], {
    env: { ...process.env, ZREGEX_TEST262_DIR: TEST262, ZREGEX_LIB: LIB, ZREGEX_ENCODING: ENCODING },
    execArgv: FORCE_GC ? ['--expose-gc'] : [],
    stdio: ['ignore', 'ignore', 'pipe', 'ipc'],
  });
  const w = { slot, child, task: null, timer: null, ran: 0, stderr: '', rss: [] };
  rssByWorker.push(w.rss);
  child.stderr.on('data', (d) => (w.stderr = (w.stderr + d).slice(-4000)));
  child.on('message', (msg) => {
    clearTimeout(w.timer);
    const task = w.task;
    w.task = null;
    w.ran++;
    w.rss.push(msg.rss);
    const { id, ...res } = msg;
    results[task.key] = res;
    done++;
    if (w.ran >= RECYCLE) {
      w.retired = true;
      child.kill();
      startSlot(slot);
    } else {
      feed(w);
    }
  });
  child.on('exit', (code, signal) => {
    clearTimeout(w.timer);
    if (w.retired) return;
    if (w.task) {
      const reason = w.timedOut
        ? `parent timeout after ${TIMEOUT_MS} ms`
        : `worker died (code ${code}, signal ${signal}): ${w.stderr.trim().split('\n').slice(-3).join(' | ')}`;
      results[w.task.key] = { status: w.timedOut ? 'timeout' : 'crash', detail: reason, execCalls: null };
      w.task = null;
      done++;
    }
    if (next < tasks.length) startSlot(slot);
    else maybeFinish();
  });
  return w;
}

const workers = [];
function startSlot(slot) {
  const w = spawnWorker(slot);
  workers[slot] = w;
  feed(w);
}

function feed(w) {
  if (next >= tasks.length) {
    w.retired = true;
    w.child.disconnect();
    maybeFinish();
    return;
  }
  const task = tasks[next++];
  w.task = task;
  w.timedOut = false;
  w.timer = setTimeout(() => {
    w.timedOut = true;
    w.child.kill('SIGKILL');
  }, TIMEOUT_MS);
  w.child.send({ id: task.id, rel: task.rel, mode: task.mode, meta: task.meta });
}

let finished = false;
function maybeFinish() {
  if (finished || done < tasks.length) return;
  finished = true;
  report();
}

if (tasks.length === 0) report();
else for (let i = 0; i < Math.min(WORKERS, tasks.length); i++) startSlot(i);

// ------------------------------------------------------------------ report
function report() {
  const durationMs = Date.now() - started;
  const out = {
    meta: {
      test262Sha: pinnedSha,
      node: process.version,
      lib: path.relative(repo, LIB),
      encoding: ENCODING,
      workers: WORKERS,
      timeoutMs: TIMEOUT_MS,
      recycle: RECYCLE,
      forceGc: FORCE_GC,
      sample: SAMPLE,
      filter: FILTER,
      hostUnsupportedFeatures: [...hostUnsupported],
      zregexFeatureGaps,
      files: files.length,
      entries: Object.keys(results).length,
      durationMs,
      date: new Date().toISOString(),
      rssByWorker: rssByWorker.filter((r) => r.length).map((r) => ({ first: r[0], last: r[r.length - 1], max: Math.max(...r), tests: r.length })),
    },
    results: Object.fromEntries(Object.entries(results).sort(([a], [b]) => (a < b ? -1 : 1))),
  };
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, JSON.stringify(out, null, 1));
  printSummary(out);
  if (UPDATE) writeBaseline(out, UPDATE);
  if (CHECK) process.exitCode = checkBaseline(out, CHECK);
  if (IMPROVE) process.exitCode = recordImprovements(out, IMPROVE);
}

const BASELINE_SKIPS = new Set(['skipped_host', 'skipped_feature']);
function engineEntries(out) {
  const entries = {};
  for (const [key, r] of Object.entries(out.results)) {
    if (key.startsWith(HOST_SUITE_PREFIX) || BASELINE_SKIPS.has(r.status)) continue;
    entries[key] = r.status;
  }
  return entries;
}

function serializeBaseline(baseline) {
  return `${JSON.stringify(baseline, null, 0).replace(/,"/g, ',\n"')}\n`;
}

/** --update-baseline-improvements: check first, then flip only not-pass -> pass. */
function recordImprovements(out, file) {
  if (checkBaseline(out, file) !== 0) {
    console.log('\nbaseline NOT updated: the check failed (fix the regressions/new/disappeared entries first)');
    return 1;
  }
  const baseline = JSON.parse(fs.readFileSync(file, 'utf8'));
  const current = engineEntries(out);
  let flipped = 0;
  for (const [key, was] of Object.entries(baseline.entries)) {
    if (was !== 'pass' && current[key] === 'pass') {
      baseline.entries[key] = 'pass';
      flipped++;
    }
  }
  baseline.generated = out.meta.date;
  fs.writeFileSync(file, serializeBaseline(baseline));
  const pass = Object.values(baseline.entries).filter((s) => s === 'pass').length;
  console.log(`\nbaseline: recorded ${flipped} improvements; ${pass}/${Object.keys(baseline.entries).length} pass -> ${path.relative(process.cwd(), file)}`);
  return 0;
}

function writeBaseline(out, file) {
  const baseline = {
    test262Sha: out.meta.test262Sha,
    node: out.meta.node,
    generated: out.meta.date,
    note: 'Engine suite only (host suite and skipped tests excluded). Update with --update-baseline.',
    entries: engineEntries(out),
  };
  fs.writeFileSync(file, serializeBaseline(baseline));
  const bytes = fs.statSync(file).size;
  console.log(`\nbaseline: ${Object.keys(baseline.entries).length} entries, ${(bytes / 1024).toFixed(0)} KiB -> ${path.relative(process.cwd(), file)}`);
}

function checkBaseline(out, file) {
  const baseline = JSON.parse(fs.readFileSync(file, 'utf8'));
  const current = engineEntries(out);
  const shaChanged = baseline.test262Sha !== out.meta.test262Sha;
  const scoped = FILTER !== null || SAMPLE !== null;
  const inScope = new Set(files.flatMap((f) => [`${f}|strict`, `${f}|sloppy`, `${f}|parse`]));
  const regressions = [];
  const improvements = [];
  const added = [];
  const disappeared = [];
  for (const [key, was] of Object.entries(baseline.entries)) {
    if (scoped && !inScope.has(key)) continue;
    const now = current[key];
    if (now === undefined) disappeared.push(`${key} (was ${was}, now ${out.results[key]?.status ?? 'absent'})`);
    else if (was === 'pass' && now !== 'pass') regressions.push(`${key}: pass -> ${now}: ${out.results[key].detail ?? ''}`);
    else if (was !== 'pass' && now === 'pass') improvements.push(`${key}: ${was} -> pass`);
  }
  for (const key of Object.keys(current)) {
    if (!(key in baseline.entries)) added.push(`${key} (${current[key]})`);
  }
  const list = (title, items) => {
    if (items.length === 0) return;
    console.log(`\n${title} (${items.length}):`);
    for (const i of items.slice(0, 50)) console.log(`  ${i}`);
    if (items.length > 50) console.log(`  ... ${items.length - 50} more`);
  };
  console.log(`\nbaseline check against ${path.relative(process.cwd(), file)}${scoped ? ' (scoped to the selected tests)' : ''}`);
  list('REGRESSIONS: pass -> not pass', regressions);
  list('NEW tests not in the baseline', added);
  list(shaChanged ? 'Disappeared (test262 revision changed)' : 'DISAPPEARED from the baseline', disappeared);
  list('Improvements: now passing (run --update-baseline-improvements to record)', improvements);
  const failed = regressions.length > 0 || added.length > 0 || (disappeared.length > 0 && !shaChanged);
  console.log(`\nbaseline check: ${failed ? 'FAILED' : 'ok'} (${regressions.length} regressions, ${added.length} new, ${disappeared.length} disappeared, ${improvements.length} improvements)`);
  return failed ? 1 : 0;
}

function printSummary(out) {
  const SKIPS = new Set(['skipped_host', 'skipped_feature']);
  const rows = new Map();
  const totals = { host: {}, engine: {} };
  for (const [key, r] of Object.entries(out.results)) {
    const rel = key.slice(0, key.lastIndexOf('|'));
    const suite = rel.startsWith(HOST_SUITE_PREFIX) ? 'host' : 'engine';
    const g = `${suite === 'host' ? '[host] ' : ''}${groupOf(rel)}`;
    if (!rows.has(g)) rows.set(g, { entries: 0, ran: 0, pass: 0, exercised: 0, exercisedPass: 0, ms: 0, statuses: {} });
    const row = rows.get(g);
    row.entries++;
    row.ms += r.ms || 0;
    row.statuses[r.status] = (row.statuses[r.status] || 0) + 1;
    totals[suite][r.status] = (totals[suite][r.status] || 0) + 1;
    if (SKIPS.has(r.status)) continue;
    row.ran++;
    if (r.status === 'pass') row.pass++;
    const exercised = r.execCalls > 0 || r.extracted || r.status === 'zregex_compile_error';
    if (exercised) {
      row.exercised++;
      if (r.status === 'pass') row.exercisedPass++;
    }
  }
  const pct = (a, b) => (b === 0 ? '—' : `${((100 * a) / b).toFixed(1)}%`);
  const table = (title, entries) => {
    if (entries.length === 0) return;
    console.log(`\n${title}\n`);
    console.log('| Directory | Entries | Ran | Pass (of ran) | zregex exercised | Pass (of exercised) | Time (s) | Statuses |');
    console.log('|---|---|---|---|---|---|---|---|');
    for (const [g, r] of entries) {
      const st = Object.entries(r.statuses).map(([s, n]) => `${s} ${n}`).join(', ');
      console.log(`| ${g} | ${r.entries} | ${r.ran} | ${r.pass} (${pct(r.pass, r.ran)}) | ${r.exercised} | ${r.exercisedPass} (${pct(r.exercisedPass, r.exercised)}) | ${(r.ms / 1000).toFixed(1)} | ${st} |`);
    }
  };
  const sorted = [...rows].sort(([a], [b]) => (a < b ? -1 : 1));
  console.log(`\ntest262 ${out.meta.test262Sha.slice(0, 12)} · ${out.meta.files} files · ${out.meta.entries} entries · ${(out.meta.durationMs / 1000).toFixed(1)} s wall`);
  console.log('Time (s) is the sum of per-test worker time (CPU-ish), not wall time.');
  table('Engine and host suites', sorted.filter(([g]) => !isHeavy(g.replace('[host] ', ''))));
  table('Heavy groups (huge subjects; dominate run time)', sorted.filter(([g]) => isHeavy(g)));
  console.log(`\nengine suite: ${JSON.stringify(totals.engine)}`);
  console.log(`host suite:   ${JSON.stringify(totals.host)}`);
  console.log(`results: ${path.relative(process.cwd(), OUT)}`);
}
