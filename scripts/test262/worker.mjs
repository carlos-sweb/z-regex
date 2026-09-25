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
/**
 * A fresh realm with a minimal $262. With `hooked`, RegExp.prototype.exec
 * is backed by zregex; without it the realm is plain V8 (the control run).
 */
function createRealm(hooked = true) {
  const context = vm.createContext({});
  if (hooked) {
    context.__zregexBridge = bridge;
    hookScript.runInContext(context);
  }
  const $262 = {
    global: vm.runInContext('globalThis', context),
    evalScript: (src) => new vm.Script(src).runInContext(context),
    createRealm: () => createRealm(hooked).$262,
  };
  vm.runInContext('globalThis', context).$262 = $262;
  vm.runInContext('globalThis', context).print = () => {};
  return { context, $262 };
}

// Mirrors the RegExp literal flag rules; validating a literal's flags is the
// JS lexer's job (the host), not zregex's.
function validLiteralFlags(flags) {
  if (!/^[dgimsuvy]*$/.test(flags)) return false;
  if (new Set(flags).size !== flags.length) return false;
  return !(flags.includes('u') && flags.includes('v'));
}

function errorName(e) {
  try {
    return e && e.constructor && e.constructor.name ? e.constructor.name : String(e);
  } catch {
    return 'unknown';
  }
}

/**
 * Run the test body in a realm (with or without the zregex hook). Returns
 * { status, detail } where status is pass | fail | timeout | harness_error |
 * compile_error (zregex) | unparsable (V8 can't parse the test).
 */
function runInRealm(task, source, hooked) {
  const { rel, mode, meta } = task;
  const compileErrorsBefore = z.stats.compileErrors;
  const { context } = createRealm(hooked);
  try {
    if (!meta.flags.includes('raw')) {
      harnessScript('assert.js').runInContext(context);
      harnessScript('sta.js').runInContext(context);
      for (const inc of meta.includes) harnessScript(inc).runInContext(context);
    }
  } catch (e) {
    if (e && e.harnessError) return { status: 'harness_error', detail: e.message };
    return { status: 'harness_error', detail: `harness threw: ${errorName(e)}: ${e && e.message}` };
  }

  let script;
  try {
    const body = mode === 'strict' ? `"use strict";\n${source}` : source;
    script = new vm.Script(body, { filename: rel });
  } catch (e) {
    return { status: 'unparsable', detail: `V8 could not parse the test: ${errorName(e)}: ${e.message}` };
  }

  try {
    script.runInContext(context, { timeout: VM_TIMEOUT_MS });
  } catch (e) {
    const name = errorName(e);
    if (e instanceof ZRegexCompileError || z.stats.compileErrors > compileErrorsBefore) {
      return { status: 'compile_error', detail: e instanceof ZRegexCompileError ? e.message : `${name}: ${e && e.message}` };
    }
    if (meta.negative && meta.negative.phase === 'runtime') {
      return name === meta.negative.type
        ? { status: 'pass' }
        : { status: 'fail', detail: `expected ${meta.negative.type}, got ${name}: ${e && e.message}` };
    }
    if (e && e.code === 'ERR_SCRIPT_EXECUTION_TIMEOUT') return { status: 'timeout', detail: 'vm timeout' };
    return { status: 'fail', detail: `${name}: ${e && e.message}` };
  }
  if (meta.negative) return { status: 'fail', detail: `expected ${meta.negative.type} to be thrown` };
  return { status: 'pass' };
}

function runTest(task) {
  const { rel, meta } = task;
  const before = z.stats.execCalls;
  const source = fs.readFileSync(path.join(TEST262, 'test', rel), 'utf8');
  const result = (status, detail, extra = {}) => ({
    status,
    detail,
    execCalls: z.stats.execCalls - before,
    ...extra,
  });

  // Early (parse-phase) errors: V8 would reject the whole script, so test
  // zregex directly on the extracted literal instead of running anything.
  if (meta.negative && meta.negative.phase === 'parse') {
    const lit = extractRegexLiteral(source);
    if (!lit) return result('unextracted', 'no single regex literal after $DONOTEVALUATE()');
    if (!validLiteralFlags(lit.flags)) {
      return result('skipped_host', `invalid literal flags "${lit.flags}": flag validation belongs to the host`, { reason: 'host_flags' });
    }
    const r = z.rejects(lit.body, lit.flags);
    return r.rejected
      ? result('pass', `rejected: ${r.reason}`, { extracted: true })
      : result('fail', 'zregex accepted a pattern the spec rejects', { extracted: true });
  }

  const hooked = runInRealm(task, source, true);
  const execCalls = z.stats.execCalls - before;
  if (hooked.status === 'unparsable') {
    return result('skipped_host', hooked.detail, { reason: 'host_feature' });
  }
  const status = hooked.status === 'compile_error' ? 'zregex_compile_error' : hooked.status;
  if (status === 'pass' || status === 'harness_error') return result(status, hooked.detail);

  // Control run (plan rule D-1): does the test also fail in plain V8,
  // without zregex? Then the failure is V8's, not zregex's.
  const control = runInRealm(task, source, false);
  if (control.status !== 'pass') {
    return {
      status: 'skipped_host',
      reason: 'v8_behind_spec',
      detail: `fails in V8 without zregex too: ${control.detail}`,
      hookedStatus: status,
      hookedDetail: hooked.detail,
      execCalls,
    };
  }
  return { status, detail: hooked.detail, execCalls, controlStatus: 'pass' };
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
  if (typeof globalThis.gc === 'function') globalThis.gc();
  res.rss = process.memoryUsage().rss;
  res.seq = ++seq;
  res.pid = process.pid;
  process.send({ id: task.id, ...res });
});

process.on('disconnect', () => process.exit(0));
