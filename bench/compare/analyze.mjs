// Aggregates the rounds of the cross-engine benchmark into bench/results.json
// and prints the Markdown tables of docs/BENCHMARKS.md (one per tier and
// metric; the best round, with min–max: since F7-0 the best round is the
// estimator, ~4% p90 between two series of 10 against ~20% for the median).
// With a `zregex_base` engine (run.mjs), a table of z-regex against it; with
// a `zoptia` engine, a table of z-regex against zoptia0regex.
//
//   node bench/compare/analyze.mjs
//
// XBENCH_ROUNDS: the rounds' directory (default zig-out/xbench/rounds);
// XBENCH_RESULTS: the JSON to write (default bench/results.json; the tables
// then go next to it, .md, instead of zig-out/xbench/tables.md).
import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
process.chdir(root);
const X = 'zig-out/xbench';
const { cases } = JSON.parse(fs.readFileSync('bench/compare/cases.json', 'utf8'));
const ROUNDS = process.env.XBENCH_ROUNDS ?? `${X}/rounds`;
const RESULTS = process.env.XBENCH_RESULTS ?? 'bench/results.json';
const TABLES = process.env.XBENCH_RESULTS ? RESULTS.replace(/\.json$/, '') + '.md' : `${X}/tables.md`;
const rounds = fs.readdirSync(ROUNDS).filter((f) => f.endsWith('.json')).map((f) => JSON.parse(fs.readFileSync(`${ROUNDS}/${f}`, 'utf8')));

const sh = (c) => { try { return execSync(c, { encoding: 'utf8' }).trim(); } catch { return null; } };
const machine = {
  cpu: sh("lscpu | sed -n 's/^Model name: *//p'"),
  cores: Number(sh('nproc')),
  threads_per_core: Number(sh("lscpu | sed -n 's/^Thread(s) per core: *//p'")),
  hypervisor: sh("lscpu | sed -n 's/^Hypervisor vendor: *//p'"),
  ram: sh("free -h | awk '/Mem:/{print $2}'"),
  kernel: sh('uname -r'),
  shared_container: true,
  zig: sh('zig version'),
  node: process.version,
  v8: process.versions.v8,
  rustc: sh('rustc --version'),
  rust_regex: '1.13.1',
  pcre2: sh('pcre2-config --version'),
  zig_regex: '0.1.1 (zig-utils/zig-regex, 173b298)',
  zregex: rounds[0]?.engines?.zregex?.version ?? null,
  zoptia0regex: rounds[0]?.engines?.zoptia ? `zoptia/zoptia0regex ${rounds[0].engines.zoptia.version}` : undefined,
  cc: sh('cc --version | head -1'),
};

// engine -> case id -> metric -> [values]
const data = {};
const put = (engine, id, metric, v) => {
  if (v === undefined || v === null || Number.isNaN(v)) return;
  ((data[engine] ??= {})[id] ??= {})[metric] ??= [];
  data[engine][id][metric].push(v);
};
const notes = {};
for (const r of rounds) {
  for (const [name, out] of Object.entries(r.engines)) {
    for (const c of out.cases) {
      const engine = c.engine ?? name;
      if (c.error) { notes[`${engine}/${c.id}`] = c.error; continue; }
      for (const m of ['findall_mbps', 'execat_mbps', 'iter_mbps', 'short_ns', 'compile_us', 'bytes', 'mbps', 'ms']) put(engine, c.id, m, c[m]);
      if (c.route) notes[`${engine}/${c.id}/route`] = c.route;
      if (c.matches !== undefined) notes[`${engine}/${c.id}/matches`] = c.matches;
    }
  }
}
const adv = {};
for (const r of rounds) for (const a of r.adversarial) {
  const k = `${a.engine}|${a.id}|${a.n}`;
  (adv[k] ??= { engine: a.engine, id: a.id, n: a.n, ms: [], outcomes: new Set(), route: a.route });
  adv[k].ms.push(a.ms);
  adv[k].outcomes.add(a.outcome);
}

// Throughput is better high; times and sizes are better low.
const higherIsBetter = new Set(['findall_mbps', 'execat_mbps', 'iter_mbps', 'mbps']);
const stat = (v, m) => {
  if (!v || !v.length) return null;
  const s = [...v].sort((a, b) => a - b);
  return { best: higherIsBetter.has(m) ? s[s.length - 1] : s[0], median: s[Math.floor(s.length / 2)], min: s[0], max: s[s.length - 1], n: s.length };
};
const summary = {};
for (const [e, ids] of Object.entries(data)) for (const [id, ms] of Object.entries(ids)) for (const [m, v] of Object.entries(ms)) ((summary[e] ??= {})[id] ??= {})[m] = stat(v, m);
const advSummary = Object.values(adv).map((a) => ({ engine: a.engine, id: a.id, n: a.n, ms: stat(a.ms, 'ms'), outcomes: [...a.outcomes], route: a.route }));
let scaling = null;
try { scaling = JSON.parse(fs.readFileSync(`${X}/zigregex-scaling.json`, 'utf8')); } catch {}

// Match counts must agree across engines (same semantics on these inputs).
const mismatches = [];
for (const c of cases.filter((x) => !x.adversarial)) {
  const counts = Object.fromEntries(Object.keys(data).map((e) => [e, notes[`${e}/${c.id}/matches`]]).filter(([, v]) => v !== undefined));
  if (new Set(Object.values(counts)).size > 1) mismatches.push({ id: c.id, counts });
}

fs.writeFileSync(RESULTS, JSON.stringify({ generated: new Date().toISOString(), rounds: rounds.length, machine, summary, adversarial: advSummary, zigregex_scaling: scaling, notes, match_count_mismatches: mismatches }, null, 1) + '\n');

// ---------------------------------------------------------------- tables
const fmt = (s, digits) => (s ? `${s.best.toFixed(digits)} (${s.min.toFixed(digits)}–${s.max.toFixed(digits)})` : '—');
const cell = (e, id, m, d) => {
  const n = notes[`${e}/${id}`];
  if (n) return 'unsupported';
  return fmt(summary[e]?.[id]?.[m], d);
};
const tiers = { T0: ['zregex', 'v8', 'v8_cold', 'rust', 'zigregex', 'zoptia'], T1: ['zregex', 'v8', 'v8_cold', 'rust', 'zoptia'], T2: ['zregex', 'v8', 'v8_cold', 'pcre2_jit', 'pcre2_interp'] };
const label = { zregex: 'z-regex', v8: 'V8 (warm)', v8_cold: 'V8 (cold)', rust: 'Rust regex', zigregex: 'zig-regex', zoptia: 'zoptia0regex', pcre2_jit: 'PCRE2 (JIT)', pcre2_interp: 'PCRE2 (interp.)' };
const metrics = [
  ['findall_mbps', 'findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)', 1],
  ['execat_mbps', 'execAt MB/s (engine loop, no per-match allocation where the API allows)', 1],
  ['iter_mbps', 'z-regex iterator MB/s (Regex.iterator: every match, warm Scratch, no allocation)', 1],
  ['short_ns', 'ns per exec on a short input (< 64 B)', 0],
  ['compile_us', 'µs per compile', 2],
  ['bytes', 'bytes per compiled pattern', 0],
];
let md = `Rounds: ${rounds.length} interleaved; each cell: the best round (highest MB/s, lowest ns, µs or ms) and the min–max band over the rounds.\n`;
for (const [tier, engines] of Object.entries(tiers)) {
  const tc = cases.filter((c) => c.tier === tier);
  for (const [m, title, d] of metrics) {
    const cols = engines.filter((e) => (m !== 'iter_mbps' || e === 'zregex') && tc.some((c) => summary[e]?.[c.id]?.[m === 'findall_mbps' && e === 'v8_cold' ? 'mbps' : m] || notes[`${e}/${c.id}`]));
    if (!cols.length) continue;
    md += `\n#### ${tier}: ${title}\n\n| Case | ${cols.map((e) => label[e]).join(' | ')} |\n|---|${cols.map(() => '---').join('|')}|\n`;
    for (const c of tc) {
      const row = cols.map((e) => (c.engines.includes(e.replace(/_cold|_jit|_interp/, '')) || (e === 'zregex' && c.engines.includes('zregex')) ? cell(e, c.id, m === 'findall_mbps' && e === 'v8_cold' ? 'mbps' : m, d) : 'n/a'));
      const route = notes[`zregex/${c.id}/route`];
      md += `| ${c.name.replaceAll('|', '\\|')}${route ? ` <sub>(z-regex: ${route})</sub>` : ''} | ${row.join(' | ')} |\n`;
    }
  }
}
const advCols = ['zregex', 'v8', 'pcre2_jit', 'pcre2_interp', 'zoptia'].filter((e) => advSummary.some((x) => x.engine === e));
md += `\n#### Adversarial: ms until the engine answers or gives up (best round; outcome)\n\n| Case | n | ${advCols.map((e) => label[e]).join(' | ')} |\n|---|---|${advCols.map(() => '---').join('|')}|\n`;
for (const c of cases.filter((x) => x.adversarial)) for (const n of c.adversarial) {
  const row = advCols.map((e) => {
    const a = advSummary.find((x) => x.engine === e && x.id === c.id && x.n === n);
    return a ? `${a.ms.best.toFixed(3)} (${a.outcomes.join(', ')})` : '—';
  });
  md += `| ${c.name.replaceAll('|', '\\|')} | ${n} | ${row.join(' | ')} |\n`;
}
if (summary.zregex_base) {
  const base = rounds[0]?.engines?.zregex_base?.version ?? 'base';
  md += `\n#### z-regex ${machine.zregex} against z-regex ${base}, same rounds (best round; ratio > 1: better now)\n\n| Case | Tier | execAt MB/s now | ${base} | ratio | findAll MB/s now | ${base} | ratio | ns short now | ${base} | ratio |\n|---|---|---|---|---|---|---|---|---|---|---|\n`;
  const r = (a, b, hi) => (a && b ? (hi ? a.best / b.best : b.best / a.best).toFixed(2) : '—');
  const v = (s, d) => (s ? s.best.toFixed(d) : '—');
  for (const c of cases.filter((x) => !x.adversarial && x.engines.includes('zregex'))) {
    const now = summary.zregex?.[c.id] ?? {}, old = summary.zregex_base?.[c.id] ?? {};
    md += `| ${c.name.replaceAll('|', '\\|')} | ${c.tier} | ${v(now.execat_mbps, 1)} | ${v(old.execat_mbps, 1)} | ${r(now.execat_mbps, old.execat_mbps, true)} | ${v(now.findall_mbps, 1)} | ${v(old.findall_mbps, 1)} | ${r(now.findall_mbps, old.findall_mbps, true)} | ${v(now.short_ns, 0)} | ${v(old.short_ns, 0)} | ${r(now.short_ns, old.short_ns, false)} |\n`;
  }
  md += `\n| Adversarial | n | now | ${base} |\n|---|---|---|---|\n`;
  for (const c of cases.filter((x) => x.adversarial)) for (const n of c.adversarial) {
    const f = (e) => { const a = advSummary.find((x) => x.engine === e && x.id === c.id && x.n === n); return a ? `${a.ms.best.toFixed(3)} (${a.outcomes.join(', ')})` : '—'; };
    md += `| ${c.name.replaceAll('|', '\\|')} | ${n} | ${f('zregex')} | ${f('zregex_base')} |\n`;
  }
}
if (summary.zoptia) {
  md += `\n#### z-regex ${machine.zregex} against zoptia0regex ${rounds[0].engines.zoptia.version}, same rounds (best round; ratio > 1: z-regex ahead)\n\n| Case | Tier | execAt MB/s z-regex | zoptia | ratio | findAll MB/s z-regex | zoptia | ratio | ns short z-regex | zoptia | ratio | µs compile z-regex | zoptia | ratio |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n`;
  const r = (a, b, hi) => (a && b ? (hi ? a.best / b.best : b.best / a.best).toFixed(2) : '—');
  const v = (s, d) => (s ? s.best.toFixed(d) : '—');
  for (const c of cases.filter((x) => !x.adversarial && x.engines.includes('zoptia'))) {
    const z = summary.zregex?.[c.id] ?? {}, o = summary.zoptia?.[c.id] ?? {};
    md += `| ${c.name.replaceAll('|', '\\|')} | ${c.tier} | ${v(z.execat_mbps, 1)} | ${v(o.execat_mbps, 1)} | ${r(z.execat_mbps, o.execat_mbps, true)} | ${v(z.findall_mbps, 1)} | ${v(o.findall_mbps, 1)} | ${r(z.findall_mbps, o.findall_mbps, true)} | ${v(z.short_ns, 0)} | ${v(o.short_ns, 0)} | ${r(z.short_ns, o.short_ns, false)} | ${v(z.compile_us, 2)} | ${v(o.compile_us, 2)} | ${r(z.compile_us, o.compile_us, false)} |\n`;
  }
}
if (mismatches.length) md += `\n**Match-count mismatches:** ${JSON.stringify(mismatches)}\n`;
else md += `\nMatch counts: identical across every engine that runs a case.\n`;
fs.writeFileSync(TABLES, md);
console.log(md);
