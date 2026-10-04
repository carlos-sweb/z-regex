// Corpora of the cross-engine benchmark (docs/BENCHMARKS.md).
//
//   node bench/compare/gen_corpus.mjs OUT_DIR
//
// Synthetic inputs: 1 MiB each, from a fixed-seed generator (the same bytes
// on every run and every machine). The realistic corpus (a public-domain
// book) comes from fetch_book.sh. Adversarial inputs are built by each
// harness from `cases.json` (they are a few dozen bytes).
import fs from 'node:fs';
import path from 'node:path';

const SIZE = 1 << 20;
const out = process.argv[2];
if (!out) {
  console.error('usage: gen_corpus.mjs OUT_DIR');
  process.exit(2);
}
fs.mkdirSync(out, { recursive: true });

// xorshift32: deterministic across Node versions.
function rng(seed) {
  let x = seed >>> 0 || 1;
  return () => {
    x ^= x << 13; x >>>= 0;
    x ^= x >>> 17;
    x ^= x << 5; x >>>= 0;
    return x;
  };
}

function build(name, seed, step) {
  const r = rng(seed);
  const pick = (n) => r() % n;
  const parts = [];
  let len = 0;
  const put = (s) => {
    parts.push(s);
    len += Buffer.byteLength(s);
  };
  const letters = 'abcdefghijklmnopqrstuvwxyz';
  const word = () => {
    let w = '';
    for (let i = 0, n = 2 + pick(8); i < n; i++) w += letters[pick(26)];
    return w;
  };
  const digits = (n) => {
    let d = '';
    for (let i = 0; i < n; i++) d += String(pick(10));
    return d;
  };
  while (len < SIZE) step({ put, pick, word, digits });
  // Trim to SIZE bytes on a character boundary.
  let buf = Buffer.from(parts.join(''));
  let end = Math.min(buf.length, SIZE);
  while (end > 0 && (buf[end] & 0xc0) === 0x80) end--;
  fs.writeFileSync(path.join(out, name + '.txt'), buf.subarray(0, end));
}

const greek = ['λόγος', 'αλφα', 'Ωμέγα', 'κόσμε', 'Ἀθῆναι'];
const cyr = ['привет', 'Москва', 'слово'];
const cjk = ['漢字', '日本語', '中文'];

build('prose', 1, ({ put, pick, word }) => put(word() + (pick(10) === 0 ? '. ' : ' ')));
build('prose_hello', 2, ({ put, pick, word }) => put((pick(1500) === 0 ? 'hello' : word()) + ' '));
build('phones_sparse', 3, ({ put, pick, word, digits }) => put((pick(30) === 0 ? digits(3) + '-' + digits(4) : word()) + ' '));
build('digits_dense', 4, ({ put, pick, digits }) => put(digits(1 + pick(6)) + (pick(2) ? '-' : ' ')));
build('emails', 5, ({ put, pick, word }) => put((pick(20) === 0 ? `${word()}.${word()}@${word()}.com` : word()) + ' '));
build('ab_runs', 6, ({ put, pick }) => {
  let s = '';
  for (let i = 0, n = 1 + pick(12); i < n; i++) s += pick(2) ? 'a' : 'b';
  put(s + (pick(2) ? 'c ' : ' '));
});
build('unicode_mixed', 7, ({ put, pick, word }) => {
  if (pick(2) === 0) {
    const l = [greek, cyr, cjk][pick(3)];
    put(l[pick(l.length)] + ' ');
  } else put((pick(8) === 0 ? word().toUpperCase() : word()) + ' ');
});
build('html', 8, ({ put, pick, word }) => {
  const t = ['p', 'b', 'div', 'span', 'em'][pick(5)];
  put(`<${t}>${word()} ${word()}</${t}>\n`);
});
build('prices', 9, ({ put, pick, word, digits }) => put((pick(15) === 0 ? '$' + digits(1 + pick(4)) : word()) + ' '));
// Lines of 4-16 characters, some with upper and lower case and >= 8 long
// (the password-policy lookahead case).
build('passwords', 10, ({ put, pick }) => {
  const set = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  const upper = pick(3) !== 0;
  let s = '';
  for (let i = 0, n = 4 + pick(13); i < n; i++) s += set[pick(upper ? set.length : 26)];
  put(s + '\n');
});
// Words and RGI emoji of the six kinds (basic, keycap, modifier, flag,
// tag, ZWJ): the properties of strings case (F5c).
const emoji = ['\u231A', '\u{1F600}', '\u{1F170}\uFE0F', '1\uFE0F\u20E3', '#\uFE0F\u20E3', '\u{1F44D}\u{1F3FD}',
  '\u{1F1EA}\u{1F1F8}', '\u{1F1EF}\u{1F1F5}', '\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}',
  '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}', '\u{1F469}\u200D\u{1F4BB}', '\u2764\uFE0F\u200D\u{1F525}'];
build('emoji', 11, ({ put, pick, word }) => put((pick(4) === 0 ? emoji[pick(emoji.length)] : word()) + ' '));
console.log(`corpus written to ${out}`);
