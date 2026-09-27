// F4b(2): the iteration corpus. Groups inside iterated bodies, nullable and
// not, under greedy, lazy and counted quantifiers: the per-iteration reset
// of captures (plan §6.5 D4) and the empty-iteration rule (D3), which the
// random corpora barely exercise (with them alone, a VM that ignores
// `clear` was invisible to the differential).
//
// A plain enumeration, no randomness: the same 16,384 patterns every run.
//
//   node scripts/iter_corpus/gen.mjs --patterns out.txt
//       every pattern, one per line as `flags<TAB>hex(pattern)` (the
//       corpus format of the scratch differential).
//   node scripts/iter_corpus/gen.mjs --v8 tests/corpus/iter_v8.tsv
//       one pattern in 8 (2,048) with V8's result on each of `subjects`
//       from index 0 (`d` flag): `pattern<TAB>slots<TAB>slots...`, slots
//       as a comma list with -1 for an unset group, `null` for no match.
//       This file is committed; `tests/t0_tests.zig` checks the tagged VM
//       against it. Regenerate only to change the corpus, and say which
//       Node produced it (the header line).
import fs from 'node:fs';

export const bodies = ['(?:(A)|B)', '(?:(A)(B)?)', '((A)|B)', '(?:A|(B))', '(?:(A)|(B))', '(?:(A)B?|B)', '(A|(B))', '(?:(A)?B)'];
export const atoms = ['a', 'b', 'ab', '\\d', '[ab]', 'x', 'a*', ''];
export const quants = ['*', '+', '{2}', '{1,3}', '{2,}', '*?', '+?', '?'];
export const suffixes = ['', 'c', '$', 'b'];
// ASCII only: WTF-8 and UTF-16 indices are the same.
export const subjects = ['', 'a', 'ab', 'abab', 'aab c', 'ba1b', 'xabx', '1a2b3c'];

export function patterns() {
  const seen = new Set();
  const out = [];
  for (const body of bodies)
    for (const A of atoms)
      for (const B of atoms)
        for (const q of quants)
          for (const s of suffixes) {
            const p = body.replace('A', A).replace('B', B) + q + s;
            if (!seen.has(p)) {
              seen.add(p);
              out.push(p);
            }
          }
  return out;
}

const [, , mode, path] = process.argv;
if (mode === '--patterns') {
  fs.writeFileSync(path, patterns().map((p) => '\t' + Buffer.from(p).toString('hex')).join('\n') + '\n');
} else if (mode === '--v8') {
  const lines = [`# ${process.version}; subjects: ${JSON.stringify(subjects)}`];
  patterns().forEach((p, k) => {
    if (k % 8 !== 0) return;
    const re = new RegExp(p, 'd');
    const cols = subjects.map((s) => {
      const m = re.exec(s);
      return m ? m.indices.flatMap((x) => (x ? x : [-1, -1])).join(',') : 'null';
    });
    lines.push([p, ...cols].join('\t'));
  });
  fs.writeFileSync(path, lines.join('\n') + '\n');
} else {
  console.error('usage: gen.mjs --patterns out.txt | --v8 out.tsv');
  process.exit(2);
}
