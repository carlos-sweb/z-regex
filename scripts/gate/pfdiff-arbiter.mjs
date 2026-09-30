// F4b(2): V8 decides each discrepancy of `pfdiff --slots` (slotdiff.tsv).
// Per line: flags, pattern and subject as UTF-16 units, index, sticky,
// the VM's slots (two passes) and the backtracker's (or StepLimitExceeded).
// Slots: comma list, -1 unset; "null" no match.
// Usage: node arbiter.mjs slotdiff.tsv [detail.tsv]
//        node arbiter.mjs --extract diff-F3d.json cases.tsv
//   (differential-v8's divergences as `pfdiff --v8` input: flags, pattern
//   as UTF-8 hex, subject as UTF-16 units, V8's slots or null, kind)
import fs from 'node:fs';
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';

const units = (s) => (s === '' ? '' : String.fromCharCode(...s.split(',').map(Number)));
const v8Slots = (re, subj, i) => {
  re.lastIndex = i;
  const m = re.exec(subj);
  if (!m) return 'null';
  return m.indices.flatMap((p) => (p ? p : [-1, -1])).join(',');
};

// A line's V8 result, in a worker: a catastrophic pattern can't be
// interrupted, so the main thread kills the worker after 2 s.
if (!isMainThread) {
  const lines = workerData.lines;
  for (let k = workerData.from; k < lines.length; k++) {
    const [fl, pat, subj, idx, sticky] = lines[k].split('\t');
    const flags = [...fl].filter((c) => 'ims'.includes(c)).join('') + (sticky === '1' ? 'y' : 'g') + 'd';
    let v8;
    try {
      v8 = v8Slots(new RegExp(units(pat), flags), units(subj), Number(idx));
    } catch (e) {
      v8 = 'V8Error';
    }
    parentPort.postMessage({ k, v8 });
  }
}

if (isMainThread && process.argv[2] === '--extract') {
  const d = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
  const out = d.divergences.map((x) => {
    const subj = [...Array(x.subject.length)].map((_, k) => x.subject.charCodeAt(k)).join(',');
    const exp = Array.isArray(x.expected) ? x.expected.join(',') : 'null';
    return [x.flags, Buffer.from(x.source, 'utf8').toString('hex'), subj, exp, x.kind].join('\t');
  });
  fs.writeFileSync(process.argv[4], out.join('\n') + '\n');
  console.log(`extracted ${out.length}`);
} else if (isMainThread) {
  const [, , input, detailPath] = process.argv;
  const lines = fs.readFileSync(input, 'utf8').split('\n').filter((l) => l);
  const v8 = new Array(lines.length);
  let next = 0;
  while (next < lines.length) {
    await new Promise((resolve) => {
      const w = new Worker(new URL(import.meta.url), { workerData: { lines, from: next } });
      let timer;
      const arm = () => {
        clearTimeout(timer);
        timer = setTimeout(() => {
          v8[next] = 'V8Timeout';
          next++;
          w.terminate().then(resolve);
        }, 2000);
      };
      arm();
      w.on('message', ({ k, v8: r }) => {
        v8[k] = r;
        next = k + 1;
        arm();
        if (next >= lines.length) {
          clearTimeout(timer);
          w.terminate().then(resolve);
        }
      });
      w.on('error', (e) => {
        clearTimeout(timer);
        console.error('worker error', e);
        v8[next] = 'V8Error';
        next++;
        resolve();
      });
    });
  }
  const counts = { lines: 0, vm_right: 0, bt_right: 0, neither: 0, both: 0, v8_error: 0, v8_timeout: 0, steplimit_vm_right: 0, steplimit_vm_wrong: 0 };
  const byPattern = new Map();
  const detail = [];
  lines.forEach((line, k) => {
    const [fl, pat, subj, idx, sticky, vm, bt] = line.split('\t');
    counts.lines++;
    const r = v8[k];
    const key = `/${units(pat)}/${fl}`;
    const p = byPattern.get(key) ?? { vm_right: 0, bt_right: 0, neither: 0, steplimit: 0, timeout: 0, example: null };
    byPattern.set(key, p);
    if (r === 'V8Error') return void counts.v8_error++;
    if (r === 'V8Timeout') {
      counts.v8_timeout++;
      p.timeout++;
      return;
    }
    let verdict;
    if (bt === 'StepLimitExceeded') {
      verdict = r === vm ? 'steplimit_vm_right' : 'steplimit_vm_wrong';
      p.steplimit++;
    } else if (r === vm && r === bt) verdict = 'both';
    else if (r === vm) verdict = 'vm_right';
    else if (r === bt) verdict = 'bt_right';
    else verdict = 'neither';
    counts[verdict]++;
    if (verdict in p) p[verdict]++;
    if (verdict !== 'steplimit_vm_right' && !p.example) p.example = { subj: JSON.stringify(units(subj)), idx, sticky, vm, bt, v8: r, verdict };
    if (verdict === 'bt_right' || verdict === 'neither' || verdict === 'steplimit_vm_wrong') detail.push([verdict, key, JSON.stringify(units(subj)), idx, sticky, vm, bt, r].join('\t'));
  });
  // V8, the VM and the backtracker all different: each such pattern is
  // looked at one by one (F4b(2): only /[a-f0-9\w\s]\u{1F600}(?<n0>\B)*/, D17).
  const neither = [...byPattern].filter(([, p]) => p.neither > 0);
  counts.neither_patterns = neither.length;
  console.log(JSON.stringify(counts));
  console.log(`patterns: ${byPattern.size}`);
  for (const [k, p] of neither) console.log(`NEITHER ${p.neither} runs ${k} e.g. ${JSON.stringify(p.example)}`);
  for (const [k, p] of byPattern) console.log(`${p.bt_right + p.neither > 0 ? 'BLOCK' : 'ok   '} vm_right ${p.vm_right} bt_right ${p.bt_right} neither ${p.neither} steplimit ${p.steplimit} timeout ${p.timeout} ${k.slice(0, 100)} e.g. ${JSON.stringify(p.example)}`);
  if (detailPath) fs.writeFileSync(detailPath, detail.join('\n') + '\n');
}
