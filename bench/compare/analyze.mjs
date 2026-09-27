// Aggregates the rounds of the cross-engine benchmark into bench/results.json
// and prints the Markdown tables of docs/BENCHMARKS.md (one per tier and
// metric; median of the rounds, with min–max).
//
//   node bench/compare/analyze.mjs
import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
process.chdir(root);
const X = 'zig-out/xbench';
const { cases } = JSON.parse(fs.readFileSync('bench/compare/cases.json', 'utf8'));
const rounds = fs.readdirSync(`${X}/rounds`).filter((f) => f.endsWith('.json')).map((f) => JSON.parse(fs.readFileSync(`${X}/rounds/${f}`, 'utf8')));

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
      for (const m of ['findall_mbps', 'execat_mbps', 'short_ns', 'compile_us', 'bytes', 'mbps', 'ms']) put(engine, c.id, m, c[m]);
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

const stat = (v) => {
  if (!v || !v.length) return null;
  const s = [...v].sort((a, b) => a - b);
  return { median: s[Math.floor(s.length / 2)], min: s[0], max: s[s.length - 1], n: s.length };
};
const summary = {};
for (const [e, ids] of Object.entries(data)) for (const [id, ms] of Object.entries(ids)) for (const [m, v] of Object.entries(ms)) ((summary[e] ??= {})[id] ??= {})[m] = stat(v);
const advSummary = Object.values(adv).map((a) => ({ engine: a.engine, id: a.id, n: a.n, ms: stat(a.ms), outcomes: [...a.outcomes], route: a.route }));
let scaling = null;
try { scaling = JSON.parse(fs.readFileSync(`${X}/zigregex-scaling.json`, 'utf8')); } catch {}

// Match counts must agree across engines (same semantics on these inputs).
const mismatches = [];
for (const c of cases.filter((x) => !x.adversarial)) {
  const counts = Object.fromEntries(Object.keys(data).map((e) => [e, notes[`${e}/${c.id}/matches`]]).filter(([, v]) => v !== undefined));
  if (new Set(Object.values(counts)).size > 1) mismatches.push({ id: c.id, counts });
}

fs.writeFileSync('bench/results.json', JSON.stringify({ generated: new Date().toISOString(), rounds: rounds.length, machine, summary, adversarial: advSummary, zigregex_scaling: scaling, notes, match_count_mismatches: mismatches }, null, 1) + '\n');

// ---------------------------------------------------------------- tables
const fmt = (s, digits) => (s ? `${s.median.toFixed(digits)} (${s.min.toFixed(digits)}–${s.max.toFixed(digits)})` : '—');
const cell = (e, id, m, d) => {
  const n = notes[`${e}/${id}`];
  if (n) return 'unsupported';
  return fmt(summary[e]?.[id]?.[m], d);
};
const tiers = { T0: ['zregex', 'v8', 'v8_cold', 'rust', 'zigregex'], T1: ['zregex', 'v8', 'v8_cold', 'rust'], T2: ['zregex', 'v8', 'v8_cold', 'pcre2_jit', 'pcre2_interp'] };
const label = { zregex: 'z-regex', v8: 'V8 (warm)', v8_cold: 'V8 (cold)', rust: 'Rust regex', zigregex: 'zig-regex', pcre2_jit: 'PCRE2 (JIT)', pcre2_interp: 'PCRE2 (interp.)' };
const metrics = [
  ['findall_mbps', 'findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)', 1],
  ['execat_mbps', 'execAt MB/s (engine loop, no per-match allocation where the API allows)', 1],
  ['short_ns', 'ns per exec on a short input (< 64 B)', 0],
  ['compile_us', 'µs per compile', 2],
  ['bytes', 'bytes per compiled pattern', 0],
];
let md = `Rounds: ${rounds.length} interleaved; each cell: median (min–max) over the rounds.\n`;
for (const [tier, engines] of Object.entries(tiers)) {
  const tc = cases.filter((c) => c.tier === tier);
  for (const [m, title, d] of metrics) {
    const cols = engines.filter((e) => tc.some((c) => summary[e]?.[c.id]?.[m === 'findall_mbps' && e === 'v8_cold' ? 'mbps' : m] || notes[`${e}/${c.id}`]));
    if (!cols.length) continue;
    md += `\n#### ${tier}: ${title}\n\n| Case | ${cols.map((e) => label[e]).join(' | ')} |\n|---|${cols.map(() => '---').join('|')}|\n`;
    for (const c of tc) {
      const row = cols.map((e) => (c.engines.includes(e.replace(/_cold|_jit|_interp/, '')) || (e === 'zregex' && c.engines.includes('zregex')) ? cell(e, c.id, m === 'findall_mbps' && e === 'v8_cold' ? 'mbps' : m, d) : 'n/a'));
      const route = notes[`zregex/${c.id}/route`];
      md += `| ${c.name}${route ? ` <sub>(z-regex: ${route})</sub>` : ''} | ${row.join(' | ')} |\n`;
    }
  }
}
md += `\n#### Adversarial: ms until the engine answers or gives up (median over rounds; outcome)\n\n| Case | n | ${['zregex', 'v8', 'pcre2_jit', 'pcre2_interp'].map((e) => label[e]).join(' | ')} |\n|---|---|---|---|---|---|\n`;
for (const c of cases.filter((x) => x.adversarial)) for (const n of c.adversarial) {
  const row = ['zregex', 'v8', 'pcre2_jit', 'pcre2_interp'].map((e) => {
    const a = advSummary.find((x) => x.engine === e && x.id === c.id && x.n === n);
    return a ? `${a.ms.median.toFixed(3)} (${a.outcomes.join(', ')})` : '—';
  });
  md += `| ${c.name} | ${n} | ${row.join(' | ')} |\n`;
}
if (mismatches.length) md += `\n**Match-count mismatches:** ${JSON.stringify(mismatches)}\n`;
else md += `\nMatch counts: identical across every engine that runs a case.\n`;
fs.writeFileSync(`${X}/tables.md`, md);
console.log(md);
