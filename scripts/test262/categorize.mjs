#!/usr/bin/env node
// Groups the engine suite's non-passing entries of a results.json by root
// cause and by the plan phase expected to fix them (docs/REGEX_TIERS_PLAN.md).
// The rules are explicit and ordered: the first match wins; anything
// unmatched is reported as `unclassified`, never guessed.
//
//   node scripts/test262/categorize.mjs [zig-out/test262/results.json]

import fs from 'node:fs';

const file = process.argv[2] || 'zig-out/test262/results.json';
const { results } = JSON.parse(fs.readFileSync(file, 'utf8'));

// [cause, phase, predicate(rel, result)]
const RULES = [
  ['short binary-property aliases (UnknownUnicodeProperty)', 'F5', (k, r) => /UnknownUnicodeProperty/.test(r.detail || '')],
  ['Unicode tables / case folding', 'F5', (k) => /property-escapes\/generated\/|unicode_full_case_folding|u-case-mapping/.test(k)],
  ['lookbehind (D7)', 'F6b', (k) => /lookBehind\/|named-groups\/lookbehind/.test(k)],
  ['captures in quantified lookahead', 'F6a', (k) => /lookahead-quantifier-match-groups/.test(k)],
  // Only D5 (dot/anchors vs \r, U+2028, U+2029) fails in these two; bonus
  // for F1, not counted in its target (docs/REGEX_TIERS_PLAN.md, F1).
  ['line terminators \\r U+2028 U+2029 (D5)', 'F1', (k) => /dotall\/without-dotall-unicode/.test(k)],
  ['non-u code units: dot, lone surrogate halves, indices (D6)', 'F3', (k) => /dotall\/|indices-array-non-unicode-match|coerce-unicode|builtin-infer-unicode/.test(k)],
  ['u: escaped/literal surrogate pairs (D13)', 'F1', (k) => /u-surrogate-pairs|source\/value-u|u-astral-char-class-invert/.test(k)],
  ['\\s is ASCII-only (D4)', 'F1', (k) => /whitespace-class-escape|character-class-escape-non-whitespace/.test(k)],
  ['empty class [] (D3)', 'F1', (k, r) => /EmptyCharClass/.test(r.detail || '')],
  ['backreferences past \\9, >16 groups, deep nesting (D9)', 'F1', (k) => /S15\.10\.2\.11_A1_T[89]|S15\.10\.2\.8_A3_T1[56]/.test(k)],
  ['group names: Unicode identifiers, forward references', 'F1', (k, r) => /InvalidGroupName|UnknownGroupName/.test(r.detail || '') && !/annexB/.test(k)],
  ['Annex B lexical grammar (D2 and friends)', 'F1', (k) => /^annexB\//.test(k)],
  // `\` + LineTerminator inside a *literal* is a JS lexer error; as a
  // pattern (`new RegExp("\\\n")`) it is valid and zregex agrees with V8.
  ['JS lexer: \\ + LineTerminator in a literal (host)', '—', (k) => /literals\/regexp\/S7\.8\.5_A[12]\.5_T[13]/.test(k)],
  ['u grammar / early errors (parse-negative accepted)', 'F1', (k, r) => /\|parse$/.test(k) && r.status === 'fail'],
  ['\\xFF / Latin-1 escape', 'F1', (k) => /S15\.10\.2\.10_A3\.1_T1/.test(k)],
  ['literal lexer tests (not extractable)', '—', (k, r) => r.status === 'unextracted'],
];

const byCause = new Map();
for (const [key, r] of Object.entries(results)) {
  if (key.startsWith('built-ins/RegExp/prototype/exec/')) continue;
  if (r.status === 'pass' || r.status.startsWith('skipped')) continue;
  const rule = RULES.find(([, , pred]) => pred(key, r));
  const cause = rule ? rule[0] : 'unclassified';
  const phase = rule ? rule[1] : '?';
  const k = `${phase}\t${cause}`;
  if (!byCause.has(k)) byCause.set(k, []);
  byCause.get(k).push(key);
}
const byPhase = {};
console.log('| Phase | Root cause | Entries |\n|---|---|---|');
for (const [k, list] of [...byCause].sort()) {
  const [phase, cause] = k.split('\t');
  byPhase[phase] = (byPhase[phase] || 0) + list.length;
  console.log(`| ${phase} | ${cause} | ${list.length} |`);
}
console.log(`\nby phase: ${JSON.stringify(byPhase)}`);
const unclassified = byCause.get('?\tunclassified') || [];
for (const k of unclassified) console.log(`unclassified: ${k} -- ${results[k].detail}`);
