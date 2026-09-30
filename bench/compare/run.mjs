// Runner of the cross-engine benchmark (docs/BENCHMARKS.md). Runs, never
// builds (prepare.sh first).
//
//   node bench/compare/run.mjs ROUNDS            interleaved rounds -> zig-out/xbench/rounds/
//   node bench/compare/run.mjs --scaling         zig-regex findAll on 16/32/64 KiB prefixes
//
// A round runs every engine once over its cases (z-regex, V8 warm, V8 cold
// one process per case, Rust regex, PCRE2 per case, zig-regex without its
// findAll pass), then the adversarial runs, each in its own process with a
// 5 s timeout. The engines' order rotates from round to round.
//
// A base version of z-regex (another build of zregex_xbench, e.g. the last
// published one) runs in the same rounds when
// zig-out/xbench/bin/zregex_base_xbench exists: engine `zregex_base`, the
// same cases and adversarial runs, so two versions compare on one machine.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
process.chdir(root);
const X = 'zig-out/xbench';
const corpus = `${X}/corpus`;
const { cases } = JSON.parse(fs.readFileSync('bench/compare/cases.json', 'utf8'));
const TIMEOUT_MS = 5000;

function run(cmd, args, timeout = 600000) {
  const t0 = Date.now();
  const r = spawnSync(cmd, args, { encoding: 'utf8', timeout, maxBuffer: 64 << 20 });
  const ms = Date.now() - t0;
  if (r.error && r.error.code === 'ETIMEDOUT') return { timeout: true, ms };
  if (r.status !== 0) throw new Error(`${cmd} ${args.join(' ')} failed: ${r.stderr}`);
  return JSON.parse(r.stdout);
}

const engines = {
  zregex: () => run('zig-out/bin/zregex_xbench', [corpus]),
  v8: () => run('node', ['bench/compare/v8_xbench.mjs', corpus]),
  v8_cold: () => ({
    engine: 'v8_cold',
    cases: cases.filter((c) => c.engines.includes('v8') && !c.adversarial).map((c) => run('node', ['bench/compare/v8_xbench.mjs', corpus, '--cold', c.id])),
  }),
  rust: () => run('bench/compare/rust/target/release/rust_xbench', [corpus, 'bench/compare/cases.json']),
  pcre2: () => ({
    engine: 'pcre2',
    cases: cases.filter((c) => c.engines.includes('pcre2') && !c.adversarial).flatMap((c) => run(`${X}/bin/pcre2_xbench`, ['case', c.id, c.pattern, `${corpus}/${c.corpus}.txt`, c.short])),
  }),
  zigregex: () => run(`${X}/zigregex/zigregex_xbench`, [corpus, 'bench/compare/cases.json', '--no-findall']),
};
const BASE = `${X}/bin/zregex_base_xbench`;
const relabel = (out) => ({ ...out, engine: 'zregex_base', cases: out.cases.map((c) => ({ ...c, engine: 'zregex_base' })) });
if (fs.existsSync(BASE)) engines.zregex_base = () => relabel(run(BASE, [corpus]));

function adversarial() {
  const out = [];
  for (const c of cases.filter((x) => x.adversarial)) {
    for (const n of c.adversarial) {
      const one = (engine, cmd, args) => {
        const r = run(cmd, args, TIMEOUT_MS);
        out.push(r.timeout ? { engine, id: c.id, n, ms: r.ms, outcome: `timeout (> ${TIMEOUT_MS / 1000} s, killed)` } : { ...r, engine });
      };
      one('zregex', 'zig-out/bin/zregex_xbench', [corpus, '--adv', c.id, String(n)]);
      if (fs.existsSync(BASE)) one('zregex_base', BASE, [corpus, '--adv', c.id, String(n)]);
      one('v8', 'node', ['bench/compare/v8_xbench.mjs', corpus, '--adv', c.id, String(n)]);
      one('pcre2_jit', `${X}/bin/pcre2_xbench`, ['adv', c.id, c.pattern, String(n), 'jit', c.adv_suffix ?? 'c']);
      one('pcre2_interp', `${X}/bin/pcre2_xbench`, ['adv', c.id, c.pattern, String(n), 'interp', c.adv_suffix ?? 'c']);
    }
  }
  return out;
}

if (process.argv[2] === '--scaling') {
  const res = [];
  for (const k of [16, 32, 64]) {
    const d = `${X}/corpus-${k}`;
    fs.mkdirSync(d, { recursive: true });
    for (const f of fs.readdirSync(corpus)) fs.writeFileSync(path.join(d, f), fs.readFileSync(path.join(corpus, f)).subarray(0, k * 1024));
    for (const id of ['t0_literal', 't0_az']) {
      const r = run(`${X}/zigregex/zigregex_xbench`, [d, 'bench/compare/cases.json', id], 300000);
      res.push({ kib: k, id, ...(r.timeout ? { timeout: true } : r.cases[0]) });
      console.error(`scaling ${id} ${k} KiB done`);
    }
  }
  fs.writeFileSync(`${X}/zigregex-scaling.json`, JSON.stringify(res, null, 1));
  console.log(JSON.stringify(res));
} else {
  const rounds = Number(process.argv[2] || 10);
  fs.mkdirSync(`${X}/rounds`, { recursive: true });
  const names = Object.keys(engines);
  for (let r = 1; r <= rounds; r++) {
    const order = names.slice(r % names.length).concat(names.slice(0, r % names.length));
    const result = { round: r, order, engines: {} };
    for (const e of order) {
      result.engines[e] = engines[e]();
      console.error(`round ${r}: ${e} done ${new Date().toISOString().slice(11, 19)}`);
    }
    result.adversarial = adversarial();
    fs.writeFileSync(`${X}/rounds/round_${r}.json`, JSON.stringify(result));
    console.error(`round ${r} written`);
  }
}
