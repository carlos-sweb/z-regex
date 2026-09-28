// F0c follow-up: which sub-features put the T1 regexes of the corpus in T1
// (docs/F0C_T1_BREAKDOWN.md). Input: the per-regex dump of `analyze()` over an
// extract.mjs corpus (flags, pattern hex, occurrences, packages, min_tier,
// comma-separated features). `analyze()` doesn't tell a General_Category
// property from a Script one, nor `\q{}`, nor counts over 100, so each T1
// pattern is parsed again with @eslint-community/regexpp (not a dependency
// of the repo: install it anywhere and pass that directory, as with acorn).
//
//   npm install --prefix /tmp/f0cdeps @eslint-community/regexpp@4
//   node scripts/f0c/t1_breakdown.mjs --deps /tmp/f0cdeps dump.tsv
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const args = process.argv.slice(2);
const opt = (name) => { const i = args.indexOf(name); return i >= 0 ? args.splice(i, 2)[1] : null; };
const deps = opt('--deps') ?? '.';
const require = createRequire(path.join(path.resolve(deps), 'node_modules', 'x.js'));
const { RegExpParser, visitRegExpAST } = require('@eslint-community/regexpp');
const parser = new RegExpParser({ ecmaVersion: 2025 });

const T1_FEATURES = ['unicode_mode', 'unicode_sets_mode', 'property_escape', 'class_set_operation', 'ignore_case_unicode', 'large_counted_repeat'];
const CATS = [
  ['u_only', 'u only (no \\p, no non-ASCII i, no v)'],
  ['p_gc', '\\p General_Category'],
  ['p_script', '\\p Script / Script_Extensions'],
  ['p_binary', '\\p binary property'],
  ['i_simple', 'i: non-ASCII literal character'],
  ['i_class', 'i: class, range or property that can hold non-ASCII (folding of sets)'],
  ['i_u_ascii', 'i with u over ASCII text only (Unicode folding: s/ſ, k/K)'],
  ['v', 'v flag (any use)'],
  ['v_setop', 'v: set operation (--, &&) or nested class'],
  ['q_strings', '\\q{} or property of strings'],
  ['counter100', 'counted repeat with min or max > 100'],
  ['large_unroll', "analyze()'s large_counted_repeat (> 1000 unrolled copies)"],
];
// Categories that are each a reason of their own (for "more than one at once").
const REASON_CATS = ['p_gc', 'p_script', 'p_binary', 'i_simple', 'i_class', 'i_u_ascii', 'v', 'q_strings', 'counter100'];
const GC_KEYS = new Set(['General_Category', 'gc']);
const SCRIPT_KEYS = new Set(['Script', 'sc', 'Script_Extensions', 'scx']);

/** Sub-features of one pattern, from its AST. */
function subFeatures(source, flags) {
  const u = flags.includes('u'), v = flags.includes('v'), i = flags.includes('i');
  const ast = parser.parsePattern(source, 0, source.length, { unicode: u, unicodeSets: v });
  const s = new Set();
  let classDepth = 0;
  const nonAsciiSet = (node) => {
    // Can this class-like node hold a non-ASCII member?
    if (node.type === 'CharacterSet') {
      if (node.kind === 'property') return true;
      if (node.kind === 'space') return true; // \s and \S both hold non-ASCII
      if ((node.kind === 'word' || node.kind === 'digit') && node.negate) return true;
      if (node.kind === 'word' && u) return true; // /[\w]/ui folds ſ and K
      return false;
    }
    return false;
  };
  visitRegExpAST(ast, {
    onCharacterClassEnter(n) {
      classDepth++;
      if (classDepth > 1 && v) s.add('v_setop');
      if (i && n.negate) s.add('i_class');
    },
    onCharacterClassLeave() { classDepth--; },
    onExpressionCharacterClassEnter(n) { classDepth++; if (i && n.negate) s.add('i_class'); },
    onExpressionCharacterClassLeave() { classDepth--; },
    onClassIntersectionEnter() { s.add('v_setop'); },
    onClassSubtractionEnter() { s.add('v_setop'); },
    onClassStringDisjunctionEnter() { s.add('q_strings'); },
    onCharacterSetEnter(n) {
      if (n.kind === 'property') {
        if (n.strings) s.add('q_strings');
        else if (GC_KEYS.has(n.key)) s.add('p_gc');
        else if (SCRIPT_KEYS.has(n.key)) s.add('p_script');
        else s.add('p_binary');
      }
      if (i && nonAsciiSet(n)) s.add('i_class');
    },
    onCharacterClassRangeEnter(n) { if (i && n.max.value > 0x7f) s.add('i_class'); },
    onCharacterEnter(n) {
      if (!i || n.value <= 0x7f) return;
      s.add(classDepth > 0 ? 'i_class' : 'i_simple');
    },
    onQuantifierEnter(n) {
      if (n.min > 100 || (Number.isFinite(n.max) && n.max > 100)) s.add('counter100');
    },
  });
  if (v) s.add('v');
  return s;
}

const rows = [];
for (const line of fs.readFileSync(args[0], 'utf8').split('\n')) {
  if (!line) continue;
  const [flags, hex, occ, pkgs, tier, feats] = line.split('\t');
  rows.push({ flags, source: Buffer.from(hex, 'hex').toString('utf8'), occ: Number(occ), pkgs: Number(pkgs), tier, feats: new Set(feats ? feats.split(',') : []) });
}

const W = ['unique', 'occ', 'pkgs'];
const zero = () => ({ unique: 0, occ: 0, pkgs: 0 });
const addTo = (acc, r) => { acc.unique += 1; acc.occ += r.occ; acc.pkgs += r.pkgs; };
const tiers = {};
for (const r of rows) addTo((tiers[r.tier] ??= zero()), r);

const t1 = rows.filter((r) => r.tier === 'unicode');
const T1 = zero();
const cats = Object.fromEntries(CATS.map(([k]) => [k, zero()]));
const reasonsN = { analyze_multi: zero(), sub_multi: zero() };
const combos = new Map();
const failures = [];
for (const r of t1) {
  addTo(T1, r);
  let s;
  try { s = subFeatures(r.source, r.flags); } catch (e) { failures.push({ ...r, error: e.message }); continue; }
  const t1f = T1_FEATURES.filter((f) => r.feats.has(f));
  if (t1f.every((f) => f === 'unicode_mode')) s.add('u_only');
  if (r.feats.has('large_counted_repeat')) s.add('large_unroll');
  // `analyze()` puts every `iu` pattern with a letter in T1 (Unicode simple
  // folding): with ASCII text only, the rest of the categories miss it.
  if (r.feats.has('ignore_case_unicode') && !s.has('i_simple') && !s.has('i_class')) s.add('i_u_ascii');
  for (const k of s) addTo(cats[k], r);
  if (t1f.filter((f) => f !== 'unicode_mode').length > 1) addTo(reasonsN.analyze_multi, r);
  const rc = REASON_CATS.filter((k) => s.has(k));
  if (rc.length > 1) addTo(reasonsN.sub_multi, r);
  const key = s.has('u_only') ? 'u_only' : rc.join('+') || '(none of the categories)';
  addTo(combos.get(key) ?? (combos.set(key, zero()), combos.get(key)), r);
}

// Counted repeats > 100 over the whole corpus (T0 unrolls them).
const counterAll = Object.fromEntries(['regular', 'unicode', 'expert'].map((t) => [t, zero()]));
let counterFail = 0;
for (const r of rows) {
  if (!counterAll[r.tier]) continue;
  let s;
  try { s = subFeatures(r.source, r.flags); } catch { counterFail++; continue; }
  if (s.has('counter100')) addTo(counterAll[r.tier], r);
}

const pct = (a, b) => (b ? (100 * a / b).toFixed(1) : '0.0');
const cell = (c, tot) => W.map((w) => `${c[w]} (${pct(c[w], tot[w])} %)`).join(' | ');
let md = '';
md += `Corpus rows: ${rows.length}. By tier (unique | occurrences | packages):\n\n| Tier | Unique | Occurrences | Packages |\n|---|---|---|---|\n`;
const all = zero();
for (const r of rows) addTo(all, r);
for (const [t, c] of Object.entries(tiers)) md += `| ${t} | ${cell(c, all)} |\n`;
md += `\nT1 sub-features (not exclusive; % of T1):\n\n| Sub-feature | Unique | Occurrences | Packages |\n|---|---|---|---|\n`;
for (const [k, label] of CATS) md += `| ${label} | ${cell(cats[k], T1)} |\n`;
md += `| more than one analyze() reason (besides u) | ${cell(reasonsN.analyze_multi, T1)} |\n`;
md += `| more than one sub-feature above | ${cell(reasonsN.sub_multi, T1)} |\n`;
md += `\nExclusive combinations (% of T1):\n\n| Combination | Unique | Occurrences | Packages |\n|---|---|---|---|\n`;
for (const [k, c] of [...combos.entries()].sort((a, b) => b[1].unique - a[1].unique)) md += `| ${k} | ${cell(c, T1)} |\n`;
md += `\nCounted repeats with min or max > 100, whole corpus (% of all rows):\n\n| Tier | Unique | Occurrences | Packages |\n|---|---|---|---|\n`;
for (const [t, c] of Object.entries(counterAll)) md += `| ${t} | ${cell(c, all)} |\n`;
md += `\nregexpp couldn't parse: ${failures.length} T1 patterns${failures.length ? ` (${failures.slice(0, 5).map((f) => f.error).join('; ')})` : ''}; ${counterFail} over the whole corpus.\n`;
process.stdout.write(md);
