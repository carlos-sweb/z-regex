# test262 harness for zregex

Runs the RegExp parts of [test262](https://github.com/tc39/test262) against
zregex, as the semantic verdict of `docs/REGEX_TIERS_PLAN.md` (phase F0b).
This is tooling only: the library itself has no Node dependency.

## How it works

- Every test runs in a fresh `vm` context whose `RegExp.prototype.exec` is
  replaced by `host-exec.js`, an implementation of `RegExpBuiltinExec` whose
  matching goes to zregex through `koffi` (`zregex.mjs`). Every RegExp
  method that matches (`test`, `@@match`, `@@matchAll`, `@@replace`,
  `@@search`, `@@split`) reaches the matcher through `RegExpExec`, so V8
  supplies the language and the algorithms around matching, zregex the
  matching.
- Strings cross the FFI as WTF-8. Offsets are mapped back to UTF-16 indices.
- Parse-phase negative tests (`negative: phase: parse`) never run: the
  regex literal is extracted and zregex must reject it.
- A pool of child processes runs one test per IPC message, so a crash
  (e.g. a segfault inside zregex) is attributed to the test that caused it.

## Usage

```bash
bash scripts/test262/fetch.sh                  # pinned revision -> .test262/
npm ci --prefix scripts/test262                # installs koffi
zig build -Doptimize=ReleaseSafe               # safety checks on: bugs surface as crashes
node scripts/test262/run.mjs                   # full run -> zig-out/test262/results.json
node scripts/test262/run.mjs --sample 100      # stratified, reproducible sample
node scripts/test262/run.mjs --filter lookBehind
```

| Variable | Default | Meaning |
|---|---|---|
| `ZREGEX_LIB` | `zig-out/lib/libzregex.so` | library under test |
| `ZREGEX_TEST262_DIR` | `.test262` | test262 checkout |
| `ZREGEX_TEST_TIMEOUT_MS` | `20000` | per-test timeout, enforced by the parent |
| `ZREGEX_TEST_RECYCLE` | `1000` | tests per worker before it is replaced |
| `ZREGEX_TEST_WORKERS` | `min(os.availableParallelism(), 8)` | worker processes |
| `ZREGEX_NATIVE_STACK_MB` | `8` | native stack for FFI calls; koffi's own default is 1 MiB, on which zregex's recursive matcher overflows |

The pinned test262 revision is in `TEST262_SHA`.

## Statuses

| Status | Meaning |
|---|---|
| `pass` | test passed |
| `fail` | assertion failed, wrong exception, or zregex hit a resource limit |
| `zregex_compile_error` | zregex rejected a pattern V8 accepted |
| `crash` | the worker died while running the test |
| `timeout` | the parent's timeout expired |
| `unextracted` | parse-negative test whose literal couldn't be extracted |
| `harness_error` | runner problem (missing include, unsupported metadata) |
| `skipped_host` | Node's V8 can't run the test (feature probed at startup, `module`/`async` flags, or V8 can't parse it) |
| `skipped_feature` | feature zregex doesn't implement yet (`features.json`, with the phase that re-enables it) |

`built-ins/RegExp/prototype/exec/` is the **host suite**: it measures
`host-exec.js`, not zregex, and is reported apart from the engine suite.

## Blind spots

- `new RegExp(src)` with a pattern V8 rejects but zregex would accept: V8
  throws first, so the test passes without measuring zregex. Only
  parse-negative tests with an extractable literal measure rejection.
- A non-`u` `lastIndex` between the two halves of a surrogate pair can't be
  expressed in WTF-8 (D6): a search resumes after the pair and a sticky
  attempt fails, so a match never starts before `lastIndex`. Tests that
  need to match a lone half of a pair fail on this.
- `RegExp.$1` and the other legacy statics are maintained by V8's own
  matcher, which the hook bypasses; the tests for them are `legacy-regexp`,
  which Node 22's V8 doesn't support anyway (skipped).
- Coverage is the four RegExp directories fetched by `fetch.sh`;
  `built-ins/String/prototype/{match,replace,split,...}` is not included yet.
