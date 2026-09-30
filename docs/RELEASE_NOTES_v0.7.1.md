# z-regex v0.7.1

**API and results unchanged. T0 throughput only.**

The API is still the one frozen in 0.7.0 (`docs/API.md`). No match, capture, error or index
changes: every differential of the gate is identical to 0.7.0's. What changes is how fast T0 (the
Pike VM tier, `docs/REGEX_TIERS_PLAN.md`) finds matches. Three changes, each with its own
precheck, gate and commit.

## What changed

- **J: `x+` and `x{n,}` without a duplicated body** (`docs/plans/T0-J.md`). A body that always
  consumes compiles as `L: x; split(L, out)` instead of `x; L: split(B, out); B: x; jmp L`.
  The thread seeded at each position lands on the loop and merges with the running one.
  E-mail 1.28× on its own.
- **C: a Shift-And path for fixed ASCII sequences** (`docs/plans/T0-CB.md`,
  `src/tier0/shiftand.zig`). A program that is a straight line of 1 to 64 ASCII
  characters and classes (groups allowed), such as `\d{3}-\d{4}`, is searched with one
  `u64` of state and a 1 KiB table, without the VM. `\d{3}-\d{4}` on dense digits 12.25×
  on its own.
- **B: a skip to the run before a required inner literal** (`docs/plans/T0-CB.md`,
  `prefilter.Inner`). When a match must contain an ASCII character that nothing before it
  in the match can be (the `@` of an e-mail pattern), the VM, while no thread is alive,
  finds that character, backs up over the run before it and starts there. It stays
  linear. B isn't used when the first-character skip is already a single byte, and a run
  shorter than the prefix's minimum is passed over. E-mail 4.89× on its own.

With groups, C and B give the match bounds and the tagged VM fills the groups on the span,
as the other fast paths do. All three work in code-unit mode (without `u`/`v`).

## Measured against 0.7.0

`bench/compare`'s z-regex harness, `execAt` MB/s, the best of 10 interleaved rounds of 0.7.0
and 0.7.1 in the same process series (`-Dcpu=x86_64_v3`):

| Case | 0.7.0 | 0.7.1 | Factor |
|---|---|---|---|
| e-mail `[\w.+-]+@[\w-]+\.[\w.]+` | 49.2 | 308.6 | **6.27×** |
| `\d{3}-\d{4}` (dense) | 45.1 | 569.2 | **12.61×** |
| `(\d{3})-(\d{4})` (dense) | 35.2 | 125.2 | 3.56× |
| `\d{3}-\d{4}` (sparse) | 662.3 | 868.3 | 1.31× |
| `(\d{3})-(\d{4})` (sparse) | 378.2 | 448.8 | 1.19× |
| `(?:(a)\|b)*c` | 15.5 | 19.6 | 1.27× |

The other cases of the harness (T0, T1 and T2) stay between 0.94× and 1.05×.

These are z-regex against itself. The comparison with V8, Rust regex, PCRE2 and zig-regex in
`docs/BENCHMARKS.md` is still 0.7.0's; it will be re-measured for 0.8.0.

## Binary and conformance

- **Shared library** (`scripts/measure_binary.sh`, x86_64_v3, stripped):
  - ReleaseFast 1,130,080 B (+17,712 B against 0.7.0);
  - ReleaseSmall 715,560 B (+11,104 B);
  - 40 exported `zregex_*` symbols.

  Most of the growth is the search loop instantiated once per skip strategy, so that
  patterns without a skip don't test for one at each position.
- **Conformance:** test262 2994/3017 in UTF-16 and in WTF-8, as in 0.7.0.
- **`zregex_version()`:** `"0.7.1"`.

## What comes next

- **0.7.1 → the precheck of T0-A** (2-3 days): a DFA for T0's programs
  (`docs/plans/T0-A.md`). The inventory there finds the forward DFAs small: over the
  three corpora, the 99th percentile of programs without asserts is 52 to 143 states.
- **T0-A's phases** (6-9 weeks, an estimate, to be confirmed by the precheck):
  1. forward and reverse DFA with a fallback to the VM;
  2. assertions;
  3. `u`/`v`;
  4. a generalized inner-literal search.
- **0.8.0:** with the full cross-engine benchmark. The e-mail case is the remaining gap:
  about 2.3× behind Rust regex (308.6 MB/s here against Rust's 705.0 in 0.7.0's run;
  indicative, the two come from different runs).
