# z-regex v0.8.0

**API and results unchanged. T0-A: the DFA on T0.**

The API is still the one frozen in 0.7.0 (`docs/API.md`). No match, capture, error or index
changes: every differential of the gate is identical to 0.7.1's. What changes is how T0 (the
Pike VM tier, `docs/REGEX_TIERS_PLAN.md`) searches. A program now gets a forward and a reverse
DFA, built at compile time, within a cap. Above the cap, the program runs on the Pike VM as
before.

## What changed

T0-A (`docs/plans/T0-A.md`; precheck, measurements and each phase in
`docs/plans/T0-A-precheck.md`):

- **The DFA** (`src/tier0/dfa.zig`).
  - The forward DFA is the VM with its threads merged into states. It finds the end of the
    leftmost-first match.
  - The reverse DFA, from that end, finds the start.
  - The alphabet is equivalence classes of the decoded value: a 128-entry table for ASCII,
    and a binary search over the range cuts for the rest.
  - Both DFAs are built at compile time into the `Program`, so they are immutable and shared
    like the rest of it.
  - The cap is 1,024 states (forward and reverse) and 32,768 cells.
  - The fast paths of 0.7.1 (literal, class run, Shift-And) still run before the DFA. The skips
    (`first`, B's inner literal) run inside it, while nothing is alive.
  - With groups, the DFA gives the match bounds and the tagged VM fills the groups over the
    span.
- **Phase 1: without asserts.** Programs without `^`, `$`, `\b` or `\B`. Coverage of T0's
  code-unit programs: f2c 67%, f2c-2 70%, npm 20%.
- **Phase 2: with asserts.**
  - The state also holds the context of the character on one side (the text's edge, a line
    terminator, a word character or another). The closure is resolved one character later,
    with the asserts evaluated from the two contexts.
  - Anchored programs (`^` without `m`) run the forward DFA at index 0.
  - npm, where most programs have asserts, goes from 20% to **87%**.
- **Phase 3: `u`/`v`.**
  - A `u`/`v` program gets its DFA in code-point mode. The tables are built over the values
    `decodeAt(.code_point)` gives: a surrogate pair is one astral value, and a lone surrogate
    its own.
  - `\b` with `i` takes the extended word characters, as the VM does.
  - Coverage of `u`/`v` programs: from 0% to **4,349 of 4,354 (99.9%)**. The other five are
    above the cap.
- **Three fixes found on the way, each measured:**
  - **The closure per context in the constructor.** With asserts, the constructor walked the
    closure once per class instead of once per context. npm's compile p99 drops ~33%, and its
    maximum by more than half. The tables are identical.
  - **UTF-8 decoded backwards in the reverse DFA.** `\p{Script=Greek}+` on Greek text had
    fallen to 0.68× of the VM. It goes back to 1.06×.
  - **UTF-8 decoded forwards in the DFA.** `\p{Script=Greek}+` reaches **1.91×** the VM.

  In phase 3 the class signatures also sweep each set's sorted ranges instead of searching per
  cut: `\p{…}` gives thousands of cuts.

## Measured

**Against 0.7.0**, the previous publication: `bench/compare`, the same 10 interleaved rounds,
`-Dcpu=x86_64_v3`, `execAt` MB/s, best round (`docs/BENCHMARKS.md`, "Against 0.7.0"):

| Case | 0.7.0 | 0.8.0 | Factor |
|---|---|---|---|
| e-mail `[\w.+-]+@[\w-]+\.[\w.]+` | 36.4 | 758.7 | 20.8× |
| `\d{3}-\d{4}` (dense) | 34.1 | 409.5 | 12.0× |
| `(\d{3})-(\d{4})` (dense) | 25.0 | 74.5 | 2.98× |
| book: `[A-Z][a-z]+` | 324.6 | 599.3 | 1.85× |
| `\p{Script=Greek}+ /u` | 56.1 | 169.8 | 3.03× |
| book: `\p{L}+ /u` | 38.7 | 90.2 | 2.33× |

No case is worse by more than 10%.

**T0-A alone**, from the measurements of each phase (separate runs on this kind of host):
- The e-mail goes from 288.9 to 683.5 MB/s against 0.7.1 (**2.37×**).
- Four `u`/`v` patterns against the VM they ran on before:

  | Pattern | Factor |
  |---|---|
  | `\p{L}+` | 2.14× |
  | `\p{Script=Greek}+` | **1.91×** |
  | `[\p{L}\p{N}_]+` | **2.42×** |
  | `\b\p{L}+\b` | 4.75× |

**Against the other engines** (`docs/BENCHMARKS.md`):
- The e-mail runs at 1.06× Rust regex (even) and 9.5× V8. It was 19× behind Rust in 0.7.0.
- Every `u` case is ahead of V8 (1.8–3.4×). `\p{L}+` is ahead of Rust regex.
- Groups (the tagged VM's second pass), sparse `\d{3}-\d{4}` and T2 are where z-regex is still
  behind.

**Compile time:** the DFA is built when the pattern is compiled.
- Over the three pattern corpora (`docs/plans/T0-A-precheck.md` §11-13, one host), the median
  `compile()` goes from 2.4 to ~5.5 µs on f2c and from 2.7 to ~6.8 µs on f2c-2.
- npm grows the most, because 87% of its programs now build a DFA with contexts: median 3.0 →
  ~12.3 µs, p99 42 → ~665 µs.
- On the benchmark's cases, compile stays at 1.4–25 µs on T0 and 6–42 µs on T1, below Rust
  regex's.

## Binary and conformance

- **Shared library** (`scripts/measure_binary.sh`, x86_64_v3, stripped):
  - ReleaseFast 1,214,560 B (+84,480 B against 0.7.1);
  - ReleaseSmall 754,152 B (+38,592 B);
  - 40 exported `zregex_*` symbols.
- **Conformance:** test262 2994/3017 in UTF-16 and in WTF-8, as in 0.7.1.
- **`zregex_version()`:** `"0.8.0"`.

## Known debt

- **Deferred construction of the DFA** (lazy build, or cheaper interning of states). Building
  the whole DFA at compile time is what makes npm's compile cost; it affects both code-unit and
  code-point mode.
- **`[a-z]+` on a short input** (the class-run fast path): 0.89–0.94× of 0.7.1 in four runs.
  Callgrind gives +1.05% instructions, about 3 per call: the DFA's dispatch check.
- **Phase 4 of T0-A, a generalized inner-literal search (ReverseInner):** not done. The DFA
  and B's skip cover the cases measured.
- **ES2025:** RegExp modifiers stay pending until further notice.

## What comes next

- **0.8.0 → 1–3 months of production use** (z-interpreter and other consumers), with the same
  API.
- **Then v1.0.0.**
