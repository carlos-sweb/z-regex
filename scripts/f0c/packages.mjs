// F0c (docs/REGEX_TIERS_PLAN.md §5.6): pick the npm packages the regex
// corpus is extracted from. Queries the registry's search API with several
// broad terms, keeps each package's monthly downloads, and writes the top N
// by downloads as `name@version` (scripts/f0c/packages.txt, committed, so
// the corpus can be rebuilt from exactly the same versions).
//
//   node scripts/f0c/packages.mjs [N=500] > scripts/f0c/packages.txt
const N = Number(process.argv[2] ?? 500);
const terms = ['javascript', 'node', 'react', 'util', 'string', 'cli', 'parser', 'http', 'typescript', 'webpack',
  'babel', 'eslint', 'test', 'css', 'date', 'json', 'stream', 'file', 'promise', 'array', 'regex', 'url',
  'template', 'markdown', 'validation', 'color', 'path', 'glob', 'ast', 'polyfill'];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The search API rate-limits (429): pace requests and back off.
async function search(url) {
  for (let attempt = 0; ; attempt++) {
    await sleep(1500);
    const res = await fetch(url);
    if (res.ok) return res.json();
    if (res.status !== 429 || attempt === 6) throw new Error(`${url}: ${res.status}`);
    await sleep(5000 * 2 ** attempt);
  }
}

const pkgs = new Map();
for (const t of terms) {
  for (let from = 0; from < 500; from += 250) {
    const url = `https://registry.npmjs.org/-/v1/search?text=${encodeURIComponent(t)}&popularity=1.0&quality=0.0&maintenance=0.0&size=250&from=${from}`;
    const body = await search(url);
    for (const o of body.objects) {
      const p = o.package;
      const monthly = o.downloads?.monthly ?? 0;
      if (!pkgs.has(p.name) || pkgs.get(p.name).monthly < monthly) pkgs.set(p.name, { version: p.version, monthly });
    }
    if (body.objects.length < 250) break;
  }
}
const top = [...pkgs.entries()].sort((a, b) => b[1].monthly - a[1].monthly).slice(0, N);
console.log(`# F0c package list: top ${N} by monthly downloads among the results of ${terms.length} npm searches, ${new Date().toISOString().slice(0, 10)}.`);
console.log('# name@version<TAB>monthly downloads');
for (const [name, p] of top) console.log(`${name}@${p.version}\t${p.monthly}`);
