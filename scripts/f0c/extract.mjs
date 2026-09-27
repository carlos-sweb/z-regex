// F0c: extract the regexes of a set of npm packages (or of a directory) into
// a corpus for `zig build f0c`. Needs acorn and acorn-walk, not a
// dependency of the repo: install them anywhere and pass that directory.
//
//   npm install --prefix /tmp/f0cdeps acorn@8 acorn-walk@8
//   node scripts/f0c/extract.mjs --deps /tmp/f0cdeps --packages scripts/f0c/packages.txt > npm.tsv
//   node scripts/f0c/extract.mjs --deps /tmp/f0cdeps --dir path/to/test262/test > test262.tsv
//
// What counts as a regex: a regex literal `/p/f`, and `RegExp(...)` or
// `new RegExp(...)` whose pattern (and flags, if given) are string literals
// or templates without substitutions. Files: .js, .mjs and .cjs up to 10 MB
// that acorn parses (as a module, or else as a script); TypeScript, JSX and
// files acorn rejects are skipped and counted.
//
// Output (TSV): flags, pattern as hex (UTF-8), occurrences, packages (or
// files, with --dir) it appears in.
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { createRequire } from 'node:module';

const args = process.argv.slice(2);
const opt = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
const require = createRequire(path.join(path.resolve(opt('--deps') ?? '.'), 'node_modules', 'x.js'));
const acorn = require('acorn');
const walk = require('acorn-walk');

const corpus = new Map(); // key flags\tpattern -> { n, units: Set }
const stats = { units: 0, files: 0, parsed: 0, skipped: 0, tooBig: 0, failedUnits: 0 };

function add(pattern, flags, unit) {
  const key = `${flags}\t${pattern}`;
  let e = corpus.get(key);
  if (!e) corpus.set(key, (e = { n: 0, units: new Set() }));
  e.n += 1;
  e.units.add(unit);
}

function stringOf(node) {
  if (!node) return null;
  if (node.type === 'Literal' && typeof node.value === 'string') return node.value;
  if (node.type === 'TemplateLiteral' && node.expressions.length === 0) return node.quasis[0].value.cooked;
  return null;
}

function scan(source, unit) {
  stats.files += 1;
  let ast = null;
  for (const sourceType of ['module', 'script']) {
    try {
      ast = acorn.parse(source, { ecmaVersion: 'latest', sourceType, allowHashBang: true, allowReturnOutsideFunction: true, allowImportExportEverywhere: true, allowAwaitOutsideFunction: true });
      break;
    } catch { /* try the other source type */ }
  }
  if (!ast) { stats.skipped += 1; return; }
  stats.parsed += 1;
  const regexpCall = (node) => {
    if (node.callee.type !== 'Identifier' || node.callee.name !== 'RegExp') return;
    const p = stringOf(node.arguments[0]);
    if (p === null) return;
    const f = node.arguments.length > 1 ? stringOf(node.arguments[1]) : '';
    if (f === null) return;
    add(p, f, unit);
  };
  walk.full(ast, (node) => {
    if (node.type === 'Literal' && node.regex) add(node.regex.pattern, node.regex.flags, unit);
    else if (node.type === 'NewExpression' || node.type === 'CallExpression') regexpCall(node);
  });
}

const wanted = (name) => /\.(m|c)?js$/.test(name) && !name.endsWith('.d.ts');

// Minimal tar reader: regular files only; pax/GNU long names don't matter
// here (only the extension of the entry is looked at).
function* tarFiles(buf) {
  let off = 0;
  while (off + 512 <= buf.length) {
    const header = buf.subarray(off, off + 512);
    if (header.every((b) => b === 0)) break;
    const name = header.subarray(0, 100).toString('utf8').replace(/\0.*$/s, '');
    const prefix = header.subarray(345, 500).toString('utf8').replace(/\0.*$/s, '');
    const size = parseInt(header.subarray(124, 136).toString('utf8').replace(/\0.*$/s, '').trim() || '0', 8);
    const type = String.fromCharCode(header[156]);
    const start = off + 512;
    if (type === '0' || type === '\0') yield { name: prefix ? `${prefix}/${name}` : name, data: buf.subarray(start, start + size) };
    off = start + Math.ceil(size / 512) * 512;
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function get(url) {
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(url);
    if (res.ok) return Buffer.from(await res.arrayBuffer());
    if (res.status !== 429 || attempt === 6) throw new Error(`${url}: ${res.status}`);
    await sleep(5000 * 2 ** attempt);
  }
}

async function doPackage(spec) {
  const at = spec.lastIndexOf('@');
  const name = spec.slice(0, at), version = spec.slice(at + 1);
  const meta = JSON.parse((await get(`https://registry.npmjs.org/${name.replace('/', '%2F')}/${version}`)).toString('utf8'));
  const tgz = await get(meta.dist.tarball);
  const tar = zlib.gunzipSync(tgz);
  for (const f of tarFiles(tar)) {
    if (!wanted(f.name)) continue;
    if (f.data.length > 10 << 20) { stats.tooBig += 1; continue; }
    scan(f.data.toString('utf8'), spec);
  }
}

function* walkDir(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) yield* walkDir(p);
    else if (wanted(e.name)) yield p;
  }
}

if (opt('--dir')) {
  for (const file of walkDir(opt('--dir'))) {
    stats.units += 1;
    const data = fs.readFileSync(file);
    if (data.length > 10 << 20) { stats.tooBig += 1; continue; }
    scan(data.toString('utf8'), file);
  }
} else {
  const specs = fs.readFileSync(opt('--packages'), 'utf8').split('\n').filter((l) => l && !l.startsWith('#')).map((l) => l.split('\t')[0]);
  const queue = [...specs];
  const workers = Array.from({ length: 4 }, async () => {
    while (queue.length) {
      const spec = queue.shift();
      stats.units += 1;
      try { await doPackage(spec); } catch (e) { stats.failedUnits += 1; process.stderr.write(`failed ${spec}: ${e.message}\n`); }
    }
  });
  await Promise.all(workers);
}

const rows = [...corpus.entries()].sort((a, b) => b[1].n - a[1].n);
for (const [key, e] of rows) {
  const tab = key.indexOf('\t');
  const flags = key.slice(0, tab), pattern = key.slice(tab + 1);
  process.stdout.write(`${flags}\t${Buffer.from(pattern, 'utf8').toString('hex')}\t${e.n}\t${e.units.size}\n`);
}
process.stderr.write(`units ${stats.units} (failed ${stats.failedUnits}), files ${stats.files}, parsed ${stats.parsed}, unparsed ${stats.skipped}, over 10 MB ${stats.tooBig}; ${rows.length} unique regexes, ${rows.reduce((s, r) => s + r[1].n, 0)} occurrences\n`);
