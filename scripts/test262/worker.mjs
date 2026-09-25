// Child process: runs one test262 test per IPC message, each in a fresh vm
// context whose RegExp.prototype.exec is backed by zregex (host-exec.js).
// The parent owns timeouts and crash attribution (run.mjs).

import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { loadZRegex, ZRegexCompileError } from './zregex.mjs';
import { extractRegexLiteral } from './meta.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const TEST262 = process.env.ZREGEX_TEST262_DIR;
const LIB = process.env.ZREGEX_LIB;
const VM_TIMEOUT_MS = Number(process.env.ZREGEX_TEST_TIMEOUT_MS || 20000);

const z = loadZRegex(LIB);

// Harness files are parsed once per child and only *run* in each context.
const scriptCache = new Map();
function harnessScript(name) {
  let s = scriptCache.get(name);
  if (!s) {
    const file = path.join(TEST262, 'harness', name);
    if (!fs.existsSync(file)) {
      const err = new Error(`missing harness include ${name}`);
      err.harnessError = true;
      throw err;
    }
    s = new vm.Script(fs.readFileSync(file, 'utf8'), { filename: `harness/${name}` });
    scriptCache.set(name, s);
  }
  return s;
}
const hookScript = new vm.Script(fs.readFileSync(path.join(here, 'host-exec.js'), 'utf8'), {
  filename: 'host-exec.js',
});

function bridge(source, flags, S, lastIndex, sticky) {
  return z.exec(source, flags, S, lastIndex, sticky);
}

/** A fresh realm with the zregex exec hook and a minimal $262. */
function createRealm() {
  const context = vm.createContext({});
  context.__zregexBridge = bridge;
  hookScript.runInContext(context);
  const $262 = {
    global: vm.runInContext('globalThis', context),
    evalScript: (src) => new vm.Script(src).runInContext(context),
    createRealm: () => createRealm().$262,
  };
  vm.runInContext('globalThis', context).$262 = $262;
  vm.runInContext('globalThis', context).print = () => {};
  return { context, $262 };
}

function errorName(e) {
  try {
    return e && e.constructor && e.constructor.name ? e.constructor.name : String(e);
  } catch {
    return 'unknown';
  }
}

function runTest(task) {
  const { rel, mode, meta } = task;
  const before = z.stats.execCalls;
  const compileErrorsBefore = z.stats.compileErrors;
  const file = path.join(TEST262, 'test', rel);
  const source = fs.readFileSync(file, 'utf8');
  const result = (status, detail) => ({
    status,
    detail,
    execCalls: z.stats.execCalls - before,
  });

  // Early (parse-phase) errors: V8 would reject the whole script, so test
  // zregex directly on the extracted literal instead of running anything.
  if (meta.negative && meta.negative.phase === 'parse') {
    const lit = extractRegexLiteral(source);
    if (!lit) return result('unextracted', 'no single regex literal after $DONOTEVALUATE()');
    const r = z.rejects(lit.body, lit.flags);
    return r.rejected
      ? { ...result('pass', `rejected: ${r.reason}`), extracted: true }
      : { ...result('fail', 'zregex accepted a pattern the spec rejects'), extracted: true };
  }

  const { context } = createRealm();
  try {
    if (!meta.flags.includes('raw')) {
      harnessScript('assert.js').runInContext(context);
      harnessScript('sta.js').runInContext(context);
      for (const inc of meta.includes) harnessScript(inc).runInContext(context);
    }
  } catch (e) {
    if (e && e.harnessError) return result('harness_error', e.message);
    return result('harness_error', `harness threw: ${errorName(e)}: ${e && e.message}`);
  }

  let script;
  try {
    const body = mode === 'strict' ? `"use strict";\n${source}` : source;
    script = new vm.Script(body, { filename: rel });
  } catch (e) {
    // V8 itself can't parse this test (e.g. syntax newer than Node's V8).
    return result('skipped_host', `V8 could not parse the test: ${errorName(e)}: ${e.message}`);
  }

  try {
    script.runInContext(context, { timeout: VM_TIMEOUT_MS });
  } catch (e) {
    const name = errorName(e);
    if (e instanceof ZRegexCompileError || z.stats.compileErrors > compileErrorsBefore) {
      return result('zregex_compile_error', e instanceof ZRegexCompileError ? e.message : `${name}: ${e && e.message}`);
    }
    if (meta.negative && meta.negative.phase === 'runtime') {
      return name === meta.negative.type
        ? result('pass')
        : result('fail', `expected ${meta.negative.type}, got ${name}: ${e && e.message}`);
    }
    if (e && e.code === 'ERR_SCRIPT_EXECUTION_TIMEOUT') return result('timeout', 'vm timeout');
    return result('fail', `${name}: ${e && e.message}`);
  }
  if (meta.negative) return result('fail', `expected ${meta.negative.type} to be thrown`);
  return result('pass');
}

let seq = 0;
process.on('message', (task) => {
  const t0 = performance.now();
  let res;
  try {
    res = runTest(task);
  } catch (e) {
    res = { status: 'harness_error', detail: `runner threw: ${e && e.stack}`, execCalls: 0 };
  }
  res.ms = Math.round((performance.now() - t0) * 10) / 10;
  res.rss = process.memoryUsage().rss;
  res.seq = ++seq;
  process.send({ id: task.id, ...res });
});

process.on('disconnect', () => process.exit(0));
