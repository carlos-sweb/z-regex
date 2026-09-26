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
- Subjects cross the FFI in one of two encodings (F3c, `--encoding` or
  `ZREGEX_ENCODING`), through `zregex_exec_wtf8` / `zregex_exec_utf16`:
  - `utf16`: the string's own code units; indices need no mapping.
  - `wtf8`: WTF-8 bytes; UTF-16 indices map to byte offsets, with `b+2`
    for the point between the two halves of a 4-byte character (the
    `subject` module's convention), so any `lastIndex` is expressible.
- **Default and baseline:** until F3d the default is `wtf8` and
  `baseline.json` is measured with it; `utf16` is run by hand with the same
  baseline. From F3d the default is `utf16` (what JS uses inside, so what a
  real host sees), `baseline.json` is regenerated with it, and `wtf8` runs
  as a cross-check against its own `baseline-wtf8.json`: two numbers, and
  any test whose status differs between the encodings is reported case by
  case.
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
node scripts/test262/run.mjs --encoding utf16  # the subject as UTF-16 (F3c)

zig build test262                              # the gate: ReleaseSafe build + --check-baseline
node scripts/test262/run.mjs --update-baseline-improvements scripts/test262/baseline.json  # record improvements only
node scripts/test262/run.mjs --update-baseline scripts/test262/baseline.json   # new test262 revision only
```

## The baseline gate

`baseline.json` holds the engine suite's status per entry (host suite and
skipped tests excluded; crashes included as expected states).
`--check-baseline` fails the run on:

- a **regression**: an entry that passed and no longer does;
- a **new** entry the baseline doesn't know;
- an entry that **disappeared**, unless the pinned test262 revision changed.

An entry that starts passing is reported as an improvement and doesn't fail
the run; record it with `--update-baseline-improvements` in an explicit
commit. That flag runs the check first and refuses to write anything if it
fails, then flips only not-pass -> pass entries, so a regression can never be
absorbed into the baseline. `--update-baseline` rewrites every entry and is
only for a new pinned test262 revision. With
`--filter`/`--sample` the check is scoped to the selected tests.

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
| `skipped_host` | not zregex's to pass; the `reason` field says why (see below) |
| `skipped_feature` | feature zregex doesn't implement yet (`features.json`, with the phase that re-enables it) |

`skipped_host` reasons (grep `results.json` by `reason` to re-enable them on
a newer Node):

| Reason | Meaning |
|---|---|
| `v8_behind_spec` | the test fails with zregex **and** in plain V8 without zregex (control run), so the failure is V8's. `hookedStatus`/`hookedDetail` keep the zregex-side result |
| `host_feature` | a feature Node's V8 lacks (probed at startup), or V8 can't parse the test |
| `host_flags` | a parse-negative literal with invalid flags: validating literal flags is the JS lexer's job, not zregex's |
| `host_runner` | `module`/`async` tests, which the vm-based runner doesn't run |
| `host_bug` | reserved for a reproducible harness/host bug left unfixed |

**Control run.** Every engine entry that doesn't pass with zregex is run a
second time in a plain V8 realm (no hook). This makes rule D-1 automatic,
at the cost of roughly doubling the time of the non-passing entries
(~300 entries x ~30 ms, about +10 s per full run).

`built-ins/RegExp/prototype/exec/` is the **host suite**: it measures
`host-exec.js`, not zregex, and is reported apart from the engine suite.

## Blind spots

- `new RegExp(src)` with a pattern V8 rejects but zregex would accept: V8
  throws first, so the test passes without measuring zregex. Only
  parse-negative tests with an extractable literal measure rejection.
- (Fixed in F3c.) A non-`u` `lastIndex` between the two halves of a
  surrogate pair couldn't be expressed in WTF-8, so a search resumed after
  the pair and a sticky attempt failed. With `b+2` it is a position, and
  `Symbol.replace/coerce-unicode.js` passes in both encodings.
- `RegExp.$1` and the other legacy statics are maintained by V8's own
  matcher, which the hook bypasses; the tests for them are `legacy-regexp`,
  which Node 22's V8 doesn't support anyway (skipped).
- Coverage is the four RegExp directories fetched by `fetch.sh`;
  `built-ins/String/prototype/{match,replace,split,...}` is not included yet.
