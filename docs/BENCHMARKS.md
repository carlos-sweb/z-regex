# Benchmarks: z-regex against V8, Rust regex, PCRE2 and zig-regex

**v0.9.0, after F5c (`v` on T0).** What this measures: z-regex 0.9.0 (measured on commit
`b751bef` plus the bench cases of the release commit: the same engine code, before the
version bump) against the engines people would use instead, **tier by tier**
(docs/REGEX_TIERS_PLAN.md): a T0 case is compared only with engines that run it as a regular
expression, a T2 case (backreferences, lookaround) only with backtracking engines that
support it. Tiers are never mixed in one table. z-regex 0.8.0, the version of the previous
publication, runs in the same rounds as a base (see "Against 0.8.0").

## Headline (v0.9.0, execAt)

Reference: V8 warm and Rust regex, the `execAt` tables under "Results", best round. Each
"×" is the ratio of two cells of the same table, never a number across tables, tiers or
hosts. Even: within ±10%. The method is under "Setup", the raw tables under "Results".

**T0 (z-regex: T0's DFA, its fast paths, and the tagged VM for groups)**

| Case | Route | vs V8 | vs Rust regex |
|---|---|---|---|
| literal `hello` | literal | **8.3× ahead** | 1.47× behind |
| `[a-z]+` | class run | **2.0× ahead** | **3.0× ahead** |
| `\d{3}-\d{4}` sparse | Shift-And | 1.47× behind | 2.6× behind |
| `\d{3}-\d{4}` dense | Shift-And | **2.6× ahead** | **6.5× ahead** |
| e-mail | DFA | **8.3× ahead** | even (1.04× behind) |
| `(\d{3})-(\d{4})` sparse | Shift-And, tagged VM | 3.8× behind | 3.7× behind |
| `(\d{3})-(\d{4})` dense | Shift-And, tagged VM | 1.88× behind | **1.23× ahead** |
| `(?:(a)\|b)*c` | DFA, tagged VM | 1.58× behind | 2.5× behind |
| book: `Darcy` | literal | **1.37× ahead** | 1.40× behind |
| book: `[A-Z][a-z]+` | DFA | even (1.06× ahead) | **2.0× ahead** |
| book: `(Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+)` | DFA, tagged VM | **1.52× ahead** | 3.2× behind |

**T1 (`u`/`v`: T0's DFA in code-point mode; since 0.9.0 `v` runs there too; Rust regex has
no `v`)**

| Case | Route | vs V8 | vs Rust regex |
|---|---|---|---|
| `\p{L}+ /u` | DFA | **1.80× ahead** | even (1.07× behind) |
| `\p{Script=Greek}+ /u` | DFA | **1.59× ahead** | 1.40× behind |
| `\p{General_Category=Lu} /u` | DFA | **2.4× ahead** | 1.43× behind |
| book: `\p{L}+ /u` | DFA | **2.9× ahead** | **1.37× ahead** |
| `[\p{L}--[a-z]] /v` | DFA | **1.77× ahead** | n/a |
| `\p{Script=Greek}{3,} /v` | DFA | **1.57× ahead** | n/a |
| `[\p{L}--[a-z]]{4} /v` | DFA | **3.1× ahead** | n/a |
| `\b\p{Lu}{5}\b /v` | DFA | even (1.04× ahead) | n/a |
| `[\p{L}\p{N}_]+\u{1F600} /v` | DFA | **15.7× ahead** | n/a |
| `(\p{Lu})(\p{Ll}+)\.$ /v` | DFA, tagged VM | **3.3× ahead** | n/a |
| `\p{RGI_Emoji}+ /v` (emoji corpus) | VM | 2.6× behind | n/a |

**T2 (the explicit-stack backtracker; Rust regex has no backreferences or lookaround)**

| Case | vs V8 | vs PCRE2 JIT | vs PCRE2 interp. |
|---|---|---|---|
| `<(\w+)>.*?<\/\1>` | 7.4× behind | 7.3× behind | 2.3× behind |
| `(?=.*[a-z])(?=.*[A-Z]).{8,}` | 6.1× behind | 7.7× behind | 1.23× behind |
| `(?<=\$)\d+` | 13× behind | 53× behind | 29× behind |
| book: `\b(\w+) \1\b` | 14× behind | 9.9× behind | 3.1× behind |

**Where z-regex is ahead**
- **`v` on T0** (0.9.0): every `v` case but `\p{RGI_Emoji}+` runs on the DFA and is ahead of
  V8 or even with it (1.04–15.7×); against 0.8.0, where they ran on the backtracker, they are
  2.5–24× faster (see "Against 0.8.0").
- **T0's DFA:** the e-mail 8.3× V8, the book's title pattern 1.52× V8, the book's
  `[A-Z][a-z]+` 2.0× Rust. On T1 every `u` case is ahead of V8 (1.59–2.9×), and the book's
  `\p{L}+` is ahead of Rust (1.37×).
- **Fast paths:** `[a-z]+` (class run) 2.0× V8 and 3.0× Rust; `\d{3}-\d{4}` on dense digits
  (Shift-And) 2.6× V8 and 6.5× Rust; the literal `hello` 8.3× V8.
- **Short inputs** without groups: 16–57 ns on T0, ahead of V8 on every such case (1.3–2.6×)
  and of Rust on most (`[a-z]+` 16 ns against 53, the e-mail 57 against 67). On T1, the `v`
  cases without groups take 36–106 ns against V8's 62–371.
- **Compile time:** 1.4–19 µs on T0 (the e-mail 12.5 µs, the DFA included) against 2.2–147 µs
  for Rust regex; 5–31 µs for the `u` cases of T1 against Rust's 50–247.
- **Adversarial:** `(a+)+b` runs on T0 (the DFA gives the bounds), a few µs at any n. V8 is
  exponential (seconds at n = 25, killed after 5 s at n = 30). PCRE2 answers at once when a
  required character is absent, and on `(a+)+b` over `a^n cb` stops at its match limit
  (~21 ms JIT, ~140 ms interpreter) with an error instead of an answer.

**Even (±10%):** the e-mail against Rust regex, `\p{L}+ /u` against Rust, the book's
`[A-Z][a-z]+` and `\b\p{Lu}{5}\b /v` against V8.

**Where it's behind, and why**
- **`\p{RGI_Emoji}+ /v`:** 2.6× behind V8 on the emoji corpus (0.7 against 1.8 MB/s), 14.5 µs
  against 3.4 µs on a short input, and 10.4 ms to compile (528,637 bytes). The class holds
  3,953 strings: the program is over the DFA's limit (`dfa.max_insts_for_dfa`, 2,000
  instructions), so it runs on the Pike VM, which carries the whole trie of alternatives at
  every position. On the case measured in 2c-b (`^\p{RGI_Emoji}+$` over the 3,953 strings
  concatenated) it is 1.8× behind V8, where the backtracker of 0.8.0 was 5.3× behind.
- **Groups on T0** (`(\d{3})-(\d{4})`, `(?:(a)|b)*c`, the title pattern against Rust):
  1.58–3.8× behind V8, 2.5–3.7× behind Rust. The DFA (or Shift-And) gives the match bounds,
  and the tagged VM then fills the groups over the span: a second pass, on the Pike VM.
- **Literals against Rust:** 1.40–1.47× behind (`hello`, `Darcy`). Rust's `memchr` picks the
  rarest bytes of each needle and the vector width at run time; z-regex searches the first
  and last bytes in pairs of vectors of a width fixed at build time (AVX2 here).
- **Sparse `\d{3}-\d{4}`:** 1.47× behind V8 and 2.6× behind Rust: Shift-And steps every
  byte, where Rust's prefilter skips to the digits.
- **Short inputs with groups:** 3.4–6.5× behind V8 (e.g. `(\d{3})-(\d{4})` 288 ns against
  74, `(\p{Lu})(\p{Ll}+)\.$ /v` 287 against 71): the tagged VM's fixed cost per search.
- **T1 against Rust:** `\p{Script=Greek}+` and `\p{General_Category=Lu}` 1.40–1.43× behind.
  The DFA decodes UTF-8 one character at a time and looks non-ASCII classes up by binary
  search over the cuts; Rust's DFA steps bytes.
- **findAll:** z-regex's facade allocates per match; on dense cases it gives up most of the
  execAt speed (`[a-z]+` 236 → 70 MB/s, the e-mail 806 → 568). `Regex.iterator` doesn't.
- **T2:** 6.1–14× behind V8 and 7.3–53× behind PCRE2 JIT, 1.23–29× behind PCRE2's
  interpreter; unchanged since 0.7.0. The lookbehind case is the worst (13× behind V8, 53×
  behind PCRE2 JIT): the backward body runs at every position with no prefilter on `$`.
- **`(?=(a+)+b)`** (a genuine T2 adversarial): z-regex stops at its step budget after ~23 ms
  with `StepLimitExceeded`: bounded, but not an answer. V8 is exponential; PCRE2 answers at
  once (required-character shortcut).
- **Compile time of `v`:** a `v` pattern now builds T0's program and DFA where 0.8.0 built a
  backtracker program: +6 to +169 µs per small pattern in this run (`\b\p{Lu}{5}\b` 1.0 →
  170 µs, `[\p{L}--[a-z]]{4}` 9.8 → 110 µs), and 10.4 ms for `\p{RGI_Emoji}+`, which 0.8.0
  rejected. An accepted cost: it is paid once per compiled pattern.

## Setup

| | |
|---|---|
| Machine | Intel(R) Xeon(R) Processor @ 2.80GHz, 4 cores (no SMT), KVM guest, 15Gi RAM, Linux 6.18.44-fc-v64 |
| Environment | **shared container**: a case moves by ±20% from one process to the next; read the band, not only the best round |
| z-regex | 0.9.0 (commit `b751bef` plus the bench cases: the same code, before the version bump), and 0.8.0 (tag `v0.8.0`, `edde4e1`) as the base. Zig 0.16.0, ReleaseFast, **`-Dcpu=x86_64_v3`** (AVX2, no AVX-512), the CPU model of `scripts/measure_binary.sh` |
| V8 | 12.4.254.21-node.39 (Node v22.22.2) |
| Rust regex | 1.13.1 (rustc 1.94.1 (e408947bf 2026-03-25)), release, LTO |
| PCRE2 | 10.42, 8-bit library, JIT and interpreter |
| zig-regex | 0.1.1 (zig-utils/zig-regex, 173b298), the last release that builds with Zig 0.16 (v0.2.x needs 0.17-dev); built `native` by `setup_zigregex.sh` |

**The previous publication** (0.8.0) was measured on the same kind of host and the same CPU
model; what changed in z-regex since then is measured here against 0.8.0 in the same rounds:
see "Against 0.8.0". The route of each case (`<sub>(z-regex: …)</sub>`) now says when T0's DFA
runs it: "DFA" (the forward and reverse DFAs give the match), "DFA, tagged VM" (the DFA gives
the bounds and the tagged VM fills the groups over the span); "VM" covers the fast paths
(literal, class run, Shift-And) that run before the DFA.

**Method.** 10 interleaved rounds: each round runs every engine once over all its cases, and
the engines' order rotates from round to round. Within a round, a throughput number is the
median of up to 5 timed passes after one warm-up. Every cell below is **the best round (the
highest MB/s, the lowest ns, µs or ms), with the min–max band** in parentheses: since F7-0
the best round is the estimator (below). Harness, corpora and runner: `bench/compare/`
(`prepare.sh` builds everything, `run.mjs` only runs, `analyze.mjs` writes
`bench/results.json`, the raw aggregated numbers, with the best, median, min and max of each
cell).

**Precision (F7-0).** Two series of 5 interleaved rounds of the same z-regex binary differ
by more than 5% in 35 to 45 of the 66 throughput metrics, whatever was tried:

| Setup (same binary, series A vs B, 5 rounds each) | Metrics with \|A−B\| > 5% | Median \|A−B\| | Max \|A−B\| |
|---|---|---|---|
| Samples of ≥ 100 ms instead of one pass (tried in F7-0, not kept) | 45 / 66 | 7.3% | 33.8% |
| ASLR off (`setarch -R`), one pass per sample | 35 / 66 | 5.7% | 42.8% |
| ASLR off and the input 2 MiB-aligned | 36 / 66 | 5.8% | 35.5% |

With the same address layout in every process the spread doesn't drop, so it isn't layout:
it is the shared VM's timing noise, which moves one case by 20–45% from one process to the
next (each whole run stays within 0.91–1.01 of the median). A bootstrap over the 10 ASLR-off
runs gives how two series of n rounds compare, per estimator of a case:

| Estimator | n = 5 | n = 10 | n = 20 |
|---|---|---|---|
| Median of the rounds: metrics > 5%, p90 \|A−B\| | 52%, 32.0% | 44%, 20.0% | 31%, 14.8% |
| Best round (minimum time = the max MB/s of the band): metrics > 5%, p90 \|A−B\| | 21%, 7.9% | 8%, 4.2% | 2%, 2.1% |

**Regression criterion (since F7b).** A regression is declared when the bench flags it (10
interleaved rounds, minimum time per case, worse than 10%) **and** callgrind, or a probe
that reproduces the case's context, confirms it. Bench flag without confirmation: noise of
this environment, noted and passed. Callgrind flag without the bench: real, fixed. Both
have to agree to block a commit. Why: at the F7b close two runs of the same code flagged
disjoint sets of cases (16 and 7 of 110 metrics), every one executing the same instructions
as the base (callgrind, ±0.73%); and the one real regression of F7b (a compile cost in the
allocator) was invisible to callgrind and caught by the bench.

**In this environment the bench cannot detect changes under ~20% with 10 rounds using the
median; §7.2's 10% gate is applied with this precision.** Comparing the minimum time per case
(the max MB/s of the min–max band, already in `bench/results.json`), the precision with 10
rounds is ~4% (p90): regression checks compare the minimum. Changes finer than that are
measured with callgrind or a dedicated probe, not with this bench.

**Metrics.**
- *findAll MB/s*: every match through each engine's allocating convenience API (z-regex
  `Regex.findAll`, JS `String.prototype.matchAll`, Rust `find_iter`/`captures_iter` collected,
  PCRE2 ovectors copied to the heap, zig-regex `findAll`).
- *execAt MB/s*: the engine's own search loop from an index, with no per-match allocation
  where the API allows (z-regex `execAt` with a warm `Scratch`; Rust `find_at` /
  `captures_read_at` with reused locations; PCRE2 `pcre2_match` with reused match data). V8
  has no allocation-free API: its "execAt" is a `RegExp.prototype.exec` loop.
- *V8 (warm)*: after warm-up, when V8 has compiled the regexp to native code. *V8 (cold)*: a
  fresh Node process per case, `new RegExp` plus the first findAll pass timed together — what
  a script that runs a regexp once pays. V8 compiles lazily and caches compiled regexps by
  source, so it has no compile column: the cold column holds that cost.
- *ns per exec*: one search on a short input (< 64 B). *µs per compile* and *bytes per
  compiled pattern* (z-regex and zig-regex: live allocations of the compiled object; PCRE2:
  `PCRE2_INFO_SIZE` plus the JIT code). Rust regex exposes no size.
- MB/s is always over the corpus's UTF-8 bytes, the same count for every engine.

**Semantics check.** Every engine that runs a case finds the same number of matches on it
(checked by `analyze.mjs` on every run). For T0, Rust regex runs with `regex::bytes` and
`unicode(false)`, so `\d`, `\w` and classes are ASCII as in ECMAScript without `u`.

## Corpora

- **Synthetic**: 1 MiB per input, from a fixed-seed xorshift32 generator
  (`bench/compare/gen_corpus.mjs`; seeds 1–11, one per input: prose, prose with rare
  "hello", sparse phone numbers, dense digits, e-mails, `a`/`b` runs, mixed-script Unicode,
  HTML, prices, password-like lines, and since 0.9.0 words with one RGI emoji in four, drawn
  from 12 of the six kinds: basic, keycap, modifier, flag, tag and ZWJ sequences). Byte-identical on every run and machine.
- **Realistic**: *Pride and Prejudice* (Project Gutenberg #1342, public domain, 724,725 bytes,
  UTF-8 with CRLF), from GITenberg's mirror at commit `81db45c`, sha256
  `48e0522844402a86a3ea98f0947ba85ea54838db3c59022299298ed968a5a163`
  (`bench/compare/fetch_book.sh` checks it).
- **Adversarial**: `a` × n followed by `c` (no match) or by `cb` (still no match, but it
  defeats PCRE2's required-character shortcut, which rejects `a^n c` without trying).
  Each run in its own process, killed after 5 s.

## Results

zig-regex has no findAll MB/s ("—"): its findAll is quadratic, see its growth below; it runs
the other T0 metrics. "n/a": the engine doesn't run that case (a z-regex-only variant, or a
feature it lacks). "unsupported": the engine rejects the pattern.

#### T0: findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)

| Case | z-regex | V8 (warm) | V8 (cold) | Rust regex | zig-regex |
|---|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 15559.6 (3759.2–15559.6) | 1983.5 (1295.0–1983.5) | 1533.2 (1031.9–1533.2) | 24437.3 (9401.2–24437.3) | — |
| [a-z]+ <sub>(z-regex: VM)</sub> | 70.2 (53.8–70.2) | 99.9 (79.9–99.9) | 71.2 (38.0–71.2) | 73.3 (31.0–73.3) | — |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 36.0 (33.6–36.0) | n/a | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 26.0 (22.8–26.0) | n/a | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 694.0 (634.5–694.0) | 1695.4 (1426.5–1695.4) | 506.6 (336.0–506.6) | 2047.7 (1479.8–2047.7) | — |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 297.8 (261.8–297.8) | 219.4 (146.0–219.4) | 124.0 (81.1–124.0) | 90.8 (80.5–90.8) | — |
| email <sub>(z-regex: DFA)</sub> | 568.0 (519.2–568.0) | 96.3 (89.0–96.3) | 84.6 (65.8–84.6) | 811.2 (551.5–811.2) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 333.9 (172.3–333.9) | 1379.0 (933.9–1379.0) | 446.6 (369.4–446.6) | 1087.2 (870.0–1087.2) | — |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 79.4 (69.5–79.4) | 175.0 (111.6–175.0) | 119.3 (96.1–119.3) | 68.7 (64.9–68.7) | — |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 21.9 (20.8–21.9) | 38.4 (32.6–38.4) | 32.8 (17.6–32.8) | 48.4 (46.6–48.4) | — |
| book: Darcy <sub>(z-regex: VM)</sub> | 8710.9 (3224.9–8710.9) | 11170.5 (5115.1–11170.5) | 2986.7 (2223.9–2986.7) | 21399.9 (12628.4–21399.9) | — |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 395.0 (380.4–395.0) | 589.6 (550.5–589.6) | 170.6 (110.0–170.6) | 326.8 (247.8–326.8) | — |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 758.7 (673.4–758.7) | 569.6 (394.3–569.6) | 429.8 (285.9–429.8) | 2163.9 (1022.8–2163.9) | — |

#### T0: execAt MB/s (engine loop, no per-match allocation where the API allows)

| Case | z-regex | V8 (warm) | Rust regex | zig-regex |
|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 17571.0 (9436.0–17571.0) | 2130.9 (1364.5–2130.9) | 25819.8 (20362.0–25819.8) | — |
| [a-z]+ <sub>(z-regex: VM)</sub> | 236.0 (168.5–236.0) | 116.6 (107.5–116.6) | 79.8 (74.8–79.8) | — |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 58.9 (56.0–58.9) | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 37.6 (28.9–37.6) | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 935.5 (777.2–935.5) | 1375.1 (1266.0–1375.1) | 2427.9 (1792.9–2427.9) | — |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 606.9 (350.6–606.9) | 235.9 (143.2–235.9) | 93.3 (67.7–93.3) | — |
| email <sub>(z-regex: DFA)</sub> | 806.1 (714.6–806.1) | 97.6 (59.0–97.6) | 841.0 (560.6–841.0) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 402.1 (205.3–402.1) | 1528.7 (921.6–1528.7) | 1484.2 (744.5–1484.2) | — |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 102.5 (99.7–102.5) | 192.4 (124.1–192.4) | 83.4 (74.4–83.4) | — |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 25.4 (19.6–25.4) | 40.2 (37.6–40.2) | 62.4 (60.4–62.4) | — |
| book: Darcy <sub>(z-regex: VM)</sub> | 16193.0 (6086.8–16193.0) | 11855.5 (6278.3–11855.5) | 22615.5 (13372.4–22615.5) | — |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 670.3 (498.2–670.3) | 633.7 (591.3–633.7) | 331.2 (256.3–331.2) | — |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 891.1 (830.5–891.1) | 586.0 (410.0–586.0) | 2814.9 (1321.7–2814.9) | — |

#### T0: z-regex iterator MB/s (Regex.iterator: every match, warm Scratch, no allocation)

| Case | z-regex |
|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 17280.4 (9412.9–17280.4) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 236.2 (197.3–236.2) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 58.9 (49.8–58.9) |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 37.5 (29.8–37.5) |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 937.2 (878.6–937.2) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 600.1 (352.5–600.1) |
| email <sub>(z-regex: DFA)</sub> | 803.4 (601.9–803.4) |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 403.0 (206.1–403.0) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 102.3 (97.7–102.3) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 25.5 (23.3–25.5) |
| book: Darcy <sub>(z-regex: VM)</sub> | 16060.2 (11540.9–16060.2) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 669.9 (632.4–669.9) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 889.5 (851.0–889.5) |

#### T0: ns per exec on a short input (< 64 B)

| Case | z-regex | V8 (warm) | Rust regex | zig-regex |
|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 20 (20–21) | 44 (44–54) | 18 (18–25) | 319 (319–712) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 16 (16–19) | 41 (41–51) | 53 (53–58) | 503 (503–548) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 81 (81–125) | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 126 (126–137) | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 22 (22–23) | 54 (54–63) | 59 (59–64) | 1041 (1041–1311) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 22 (22–70) | 55 (55–74) | 58 (58–62) | 1034 (1034–1115) |
| email <sub>(z-regex: DFA)</sub> | 57 (57–118) | 105 (105–122) | 67 (67–72) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 288 (288–313) | 74 (74–118) | 98 (98–105) | 2850 (2850–2995) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 289 (289–308) | 84 (84–94) | 97 (97–105) | 2795 (2795–2931) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 373 (373–404) | 57 (57–88) | 102 (102–156) | 2874 (2874–3269) |
| book: Darcy <sub>(z-regex: VM)</sub> | 20 (20–21) | 52 (52–62) | 18 (18–21) | 309 (309–346) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 43 (43–49) | 57 (57–69) | 61 (61–81) | 1449 (1449–1642) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 491 (491–518) | 81 (81–91) | 129 (129–146) | 6974 (6974–7310) |

#### T0: µs per compile

| Case | z-regex | Rust regex | zig-regex |
|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 1.43 (1.43–2.77) | 2.34 (2.34–3.13) | 0.81 (0.81–1.43) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 1.42 (1.42–1.58) | 6.91 (6.91–11.50) | 0.50 (0.50–0.85) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 1.16 (1.16–1.99) | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 0.71 (0.71–0.95) | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 2.13 (2.13–2.22) | 145.82 (145.82–201.84) | 1.22 (1.22–1.92) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 2.12 (2.12–2.21) | 143.39 (143.39–203.95) | 1.14 (1.14–1.95) |
| email <sub>(z-regex: DFA)</sub> | 12.52 (12.52–29.08) | 16.91 (16.91–29.86) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 2.72 (2.72–4.86) | 146.86 (146.86–220.30) | 2.23 (2.23–2.61) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 2.71 (2.71–2.76) | 147.46 (147.46–153.14) | 2.34 (2.34–2.64) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 7.94 (7.94–9.35) | 10.64 (10.64–11.68) | 1.63 (1.63–1.78) |
| book: Darcy <sub>(z-regex: VM)</sub> | 1.44 (1.44–1.73) | 2.15 (2.15–3.37) | 0.85 (0.85–2.10) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 4.26 (4.26–4.83) | 8.24 (8.24–13.16) | 0.79 (0.79–0.87) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 18.97 (18.97–29.50) | 22.77 (22.77–40.49) | 2.99 (2.99–4.42) |

#### T0: bytes per compiled pattern

| Case | z-regex | zig-regex |
|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 185 (185–185) | 2322 (2322–2322) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 135 (135–135) | 1016 (1016–1016) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 135 (135–135) | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 19 (19–19) | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 1349 (1349–1349) | 3817 (3817–3817) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 1349 (1349–1349) | 3817 (3817–3817) |
| email <sub>(z-regex: DFA)</sub> | 2165 (2165–2165) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 1457 (1457–1457) | 5365 (5365–5365) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 1457 (1457–1457) | 5365 (5365–5365) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 1393 (1393–1393) | 3227 (3227–3227) |
| book: Darcy <sub>(z-regex: VM)</sub> | 185 (185–185) | 2322 (2322–2322) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 1176 (1176–1176) | 1751 (1751–1751) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 3284 (3284–3284) | 9370 (9370–9370) |

#### T1: findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)

| Case | z-regex | V8 (warm) | V8 (cold) | Rust regex |
|---|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 51.3 (38.8–51.3) | 44.5 (42.6–44.5) | 36.9 (27.3–36.9) | 83.8 (72.5–83.8) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 160.5 (148.8–160.5) | 119.7 (95.0–119.7) | 80.2 (71.2–80.2) | 273.7 (256.6–273.7) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 97.9 (92.0–97.9) | 63.3 (39.7–63.3) | 49.0 (44.6–49.0) | 200.5 (88.1–200.5) |
| [\p{L}--[a-z]] /v <sub>(z-regex: DFA)</sub> | 27.1 (25.4–27.1) | 33.1 (25.3–33.1) | 28.6 (17.4–28.6) | n/a |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 46.5 (41.2–46.5) | 31.6 (29.9–31.6) | 25.8 (17.4–25.8) | 65.3 (60.9–65.3) |
| \p{Script=Greek}{3,} /v <sub>(z-regex: DFA)</sub> | 158.2 (143.0–158.2) | 122.1 (117.6–122.1) | 80.0 (48.7–80.0) | n/a |
| [\p{L}--[a-z]]{4} /v <sub>(z-regex: DFA)</sub> | 92.3 (85.9–92.3) | 40.3 (37.6–40.3) | 33.0 (19.3–33.0) | n/a |
| \b\p{Lu}{5}\b /v <sub>(z-regex: DFA)</sub> | 198.1 (141.5–198.1) | 196.9 (186.3–196.9) | 172.5 (128.9–172.5) | n/a |
| [\p{L}\p{N}_]+\u{1F600} /v <sub>(z-regex: DFA)</sub> | 193.4 (181.8–193.4) | 12.3 (11.6–12.3) | 12.0 (10.6–12.0) | n/a |
| (\p{Lu})(\p{Ll}+)\.$ /v <sub>(z-regex: DFA, tagged VM)</sub> | 209.5 (201.5–209.5) | 62.9 (42.8–62.9) | 60.7 (57.6–60.7) | n/a |
| \p{RGI_Emoji}+ /v <sub>(z-regex: VM)</sub> | 0.7 (0.6–0.7) | 1.8 (1.7–1.8) | 1.7 (1.5–1.7) | n/a |

#### T1: execAt MB/s (engine loop, no per-match allocation where the API allows)

| Case | z-regex | V8 (warm) | Rust regex |
|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 85.3 (63.9–85.3) | 47.3 (45.0–47.3) | 91.1 (49.4–91.1) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 199.2 (184.1–199.2) | 125.6 (105.7–125.6) | 279.2 (269.8–279.2) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 153.1 (149.0–153.1) | 64.7 (44.2–64.7) | 218.7 (193.7–218.7) |
| [\p{L}--[a-z]] /v <sub>(z-regex: DFA)</sub> | 61.6 (59.2–61.6) | 34.8 (24.1–34.8) | n/a |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 98.1 (73.1–98.1) | 33.4 (32.5–33.4) | 71.8 (58.0–71.8) |
| \p{Script=Greek}{3,} /v <sub>(z-regex: DFA)</sub> | 198.1 (192.2–198.1) | 125.8 (119.1–125.8) | n/a |
| [\p{L}--[a-z]]{4} /v <sub>(z-regex: DFA)</sub> | 126.8 (114.2–126.8) | 41.3 (31.3–41.3) | n/a |
| \b\p{Lu}{5}\b /v <sub>(z-regex: DFA)</sub> | 202.5 (141.4–202.5) | 194.9 (148.7–194.9) | n/a |
| [\p{L}\p{N}_]+\u{1F600} /v <sub>(z-regex: DFA)</sub> | 192.5 (181.1–192.5) | 12.2 (11.3–12.2) | n/a |
| (\p{Lu})(\p{Ll}+)\.$ /v <sub>(z-regex: DFA, tagged VM)</sub> | 210.4 (204.8–210.4) | 62.9 (41.8–62.9) | n/a |
| \p{RGI_Emoji}+ /v <sub>(z-regex: VM)</sub> | 0.7 (0.6–0.7) | 1.8 (1.7–1.8) | n/a |

#### T1: z-regex iterator MB/s (Regex.iterator: every match, warm Scratch, no allocation)

| Case | z-regex |
|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 85.6 (71.8–85.6) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 198.5 (160.8–198.5) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 153.4 (143.9–153.4) |
| [\p{L}--[a-z]] /v <sub>(z-regex: DFA)</sub> | 61.8 (58.6–61.8) |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 99.4 (92.3–99.4) |
| \p{Script=Greek}{3,} /v <sub>(z-regex: DFA)</sub> | 199.7 (177.8–199.7) |
| [\p{L}--[a-z]]{4} /v <sub>(z-regex: DFA)</sub> | 126.5 (105.4–126.5) |
| \b\p{Lu}{5}\b /v <sub>(z-regex: DFA)</sub> | 202.9 (140.3–202.9) |
| [\p{L}\p{N}_]+\u{1F600} /v <sub>(z-regex: DFA)</sub> | 192.6 (131.8–192.6) |
| (\p{Lu})(\p{Ll}+)\.$ /v <sub>(z-regex: DFA, tagged VM)</sub> | 210.2 (207.6–210.2) |
| \p{RGI_Emoji}+ /v <sub>(z-regex: VM)</sub> | 0.7 (0.6–0.7) |

#### T1: ns per exec on a short input (< 64 B)

| Case | z-regex | V8 (warm) | Rust regex |
|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 124 (124–135) | 145 (145–155) | 69 (69–73) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 94 (94–142) | 136 (136–152) | 76 (76–85) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 53 (53–57) | 120 (120–128) | 38 (38–46) |
| [\p{L}--[a-z]] /v <sub>(z-regex: DFA)</sub> | 53 (53–55) | 145 (145–153) | n/a |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 30 (30–34) | 54 (54–60) | 49 (49–72) |
| \p{Script=Greek}{3,} /v <sub>(z-regex: DFA)</sub> | 92 (92–98) | 132 (132–166) | n/a |
| [\p{L}--[a-z]]{4} /v <sub>(z-regex: DFA)</sub> | 106 (106–146) | 219 (219–235) | n/a |
| \b\p{Lu}{5}\b /v <sub>(z-regex: DFA)</sub> | 36 (36–40) | 62 (62–67) | n/a |
| [\p{L}\p{N}_]+\u{1F600} /v <sub>(z-regex: DFA)</sub> | 57 (57–112) | 371 (371–387) | n/a |
| (\p{Lu})(\p{Ll}+)\.$ /v <sub>(z-regex: DFA, tagged VM)</sub> | 287 (287–304) | 71 (71–100) | n/a |
| \p{RGI_Emoji}+ /v <sub>(z-regex: VM)</sub> | 14485 (14485–15466) | 3407 (3407–3575) | n/a |

#### T1: µs per compile

| Case | z-regex | Rust regex |
|---|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 31.30 (31.30–32.08) | 243.49 (243.49–357.76) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 4.93 (4.93–5.51) | 50.45 (50.45–56.58) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 29.73 (29.73–30.13) | 154.34 (154.34–158.33) |
| [\p{L}--[a-z]] /v <sub>(z-regex: DFA)</sub> | 35.27 (35.27–60.51) | n/a |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 31.43 (31.43–32.10) | 246.90 (246.90–347.68) |
| \p{Script=Greek}{3,} /v <sub>(z-regex: DFA)</sub> | 6.93 (6.93–7.38) | n/a |
| [\p{L}--[a-z]]{4} /v <sub>(z-regex: DFA)</sub> | 110.05 (110.05–113.03) | n/a |
| \b\p{Lu}{5}\b /v <sub>(z-regex: DFA)</sub> | 169.97 (169.97–227.09) | n/a |
| [\p{L}\p{N}_]+\u{1F600} /v <sub>(z-regex: DFA)</sub> | 50.19 (50.19–52.56) | n/a |
| (\p{Lu})(\p{Ll}+)\.$ /v <sub>(z-regex: DFA, tagged VM)</sub> | 92.80 (92.80–99.26) | n/a |
| \p{RGI_Emoji}+ /v <sub>(z-regex: VM)</sub> | 10405.60 (10405.60–11552.11) | n/a |

#### T1: bytes per compiled pattern

| Case | z-regex |
|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 22852 (22852–22852) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 2116 (2116–2116) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 21871 (21871–21871) |
| [\p{L}--[a-z]] /v <sub>(z-regex: DFA)</sub> | 28250 (28250–28250) |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 22852 (22852–22852) |
| \p{Script=Greek}{3,} /v <sub>(z-regex: DFA)</sub> | 2223 (2223–2223) |
| [\p{L}--[a-z]]{4} /v <sub>(z-regex: DFA)</sub> | 28409 (28409–28409) |
| \b\p{Lu}{5}\b /v <sub>(z-regex: DFA)</sub> | 24586 (24586–24586) |
| [\p{L}\p{N}_]+\u{1F600} /v <sub>(z-regex: DFA)</sub> | 32248 (32248–32248) |
| (\p{Lu})(\p{Ll}+)\.$ /v <sub>(z-regex: DFA, tagged VM)</sub> | 30608 (30608–30608) |
| \p{RGI_Emoji}+ /v <sub>(z-regex: VM)</sub> | 528637 (528637–528637) |

#### T2: findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)

| Case | z-regex | V8 (warm) | V8 (cold) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 29.9 (20.0–29.9) | 220.8 (194.4–220.8) | 119.2 (95.6–119.2) | 244.1 (215.7–244.1) | 76.4 (60.7–76.4) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 9.8 (8.5–9.8) | 60.1 (40.3–60.1) | 46.7 (26.7–46.7) | 77.1 (42.8–77.1) | 12.5 (10.0–12.5) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 19.8 (18.2–19.8) | 262.0 (232.8–262.0) | 157.9 (75.9–157.9) | 1031.8 (902.8–1031.8) | 568.7 (495.7–568.7) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 11.4 (11.1–11.4) | 157.9 (108.5–157.9) | 152.2 (119.8–152.2) | 114.1 (74.5–114.1) | 35.6 (33.8–35.6) |

#### T2: execAt MB/s (engine loop, no per-match allocation where the API allows)

| Case | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 34.6 (32.6–34.6) | 256.2 (235.2–256.2) | 254.2 (240.0–254.2) | 79.6 (73.9–79.6) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 10.3 (9.7–10.3) | 63.0 (44.5–63.0) | 79.1 (76.1–79.1) | 12.7 (10.7–12.7) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 20.4 (18.7–20.4) | 266.1 (162.5–266.1) | 1076.5 (985.9–1076.5) | 581.3 (541.0–581.3) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 11.5 (11.1–11.5) | 159.0 (109.6–159.0) | 113.9 (80.6–113.9) | 35.7 (33.9–35.7) |

#### T2: z-regex iterator MB/s (Regex.iterator: every match, warm Scratch, no allocation)

| Case | z-regex |
|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 34.7 (19.8–34.7) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 10.3 (9.3–10.3) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 20.4 (17.9–20.4) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 11.5 (9.0–11.5) |

#### T2: ns per exec on a short input (< 64 B)

| Case | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 342 (342–371) | 57 (57–72) | 38 (38–79) | 139 (139–150) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 313 (313–328) | 87 (87–94) | 53 (53–78) | 250 (250–271) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 434 (434–466) | 70 (70–80) | 30 (30–31) | 80 (80–85) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 274 (274–288) | 67 (67–79) | 39 (39–41) | 90 (90–104) |

#### T2: µs per compile

| Case | z-regex | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 2.63 (2.63–3.06) | 6.54 (6.54–6.73) | 0.64 (0.64–2.20) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 3.78 (3.78–4.37) | 5.52 (5.52–8.24) | 0.83 (0.83–1.42) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 1.51 (1.51–2.16) | 3.75 (3.75–3.84) | 0.43 (0.43–0.48) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 1.79 (1.79–1.87) | 6.15 (6.15–12.39) | 0.59 (0.59–0.63) |

#### T2: bytes per compiled pattern

| Case | z-regex | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 92 (92–92) | 1287 (1287–1287) | 168 (168–168) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 1820 (1820–1820) | 963 (963–963) | 231 (231–231) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 714 (714–714) | 687 (687–687) | 156 (156–156) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 59 (59–59) | 1226 (1226–1226) | 160 (160–160) |

#### Adversarial: ms until the engine answers or gives up (best round; outcome)

| Case | n | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|---|
| (a+)+b on a^n c | 20 | 0.002 (no match) | 84.299 (no match) | 0.004 (no match) | 0.005 (no match) |
| (a+)+b on a^n c | 25 | 0.001 (no match) | 2723.121 (no match) | 0.004 (no match) | 0.005 (no match) |
| (a+)+b on a^n c | 30 | 0.001 (no match) | 5002.000 (timeout (> 5 s, killed)) | 0.004 (no match) | 0.005 (no match) |
| (a+)+b on a^n c | 40 | 0.002 (no match) | 5002.000 (timeout (> 5 s, killed)) | 0.004 (no match) | 0.006 (no match) |
| (a+)+b on a^n cb | 20 | 0.002 (no match) | 84.595 (no match) | 8.666 (no match) | 73.050 (no match) |
| (a+)+b on a^n cb | 25 | 0.001 (no match) | 2727.572 (no match) | 20.633 (match limit) | 138.040 (match limit) |
| (a+)+b on a^n cb | 30 | 0.002 (no match) | 5002.000 (timeout (> 5 s, killed)) | 20.556 (match limit) | 139.676 (match limit) |
| (a+)+b on a^n cb | 40 | 0.001 (no match) | 5002.000 (timeout (> 5 s, killed)) | 20.515 (match limit) | 140.156 (match limit) |
| (?=(a+)+b) on a^n c | 20 | 23.351 (StepLimitExceeded) | 85.444 (no match) | 0.004 (no match) | 0.005 (no match) |
| (?=(a+)+b) on a^n c | 25 | 23.125 (StepLimitExceeded) | 2716.183 (no match) | 0.004 (no match) | 0.006 (no match) |
| (?=(a+)+b) on a^n c | 30 | 23.159 (StepLimitExceeded) | 5006.000 (timeout (> 5 s, killed)) | 0.004 (no match) | 0.004 (no match) |
| (?=(a+)+b) on a^n c | 40 | 23.191 (StepLimitExceeded) | 5005.000 (timeout (> 5 s, killed)) | 0.004 (no match) | 0.005 (no match) |

z-regex runs `(a+)+b` on T0's DFA (linear; the tagged VM fills the group over the span).
V8 grows by ~32× every 5 `a`s. PCRE2 answers at once
because the required character `c` is absent (its start-up shortcut, as for `(a+)+b` on
`a^n c`).

### Against 0.8.0

z-regex 0.9.0 and z-regex 0.8.0, the previous publication, in the same 10 rounds (the same
harness), both built with `-Dcpu=x86_64_v3`; 0.8.0 from the tag `v0.8.0` (`edde4e1`). 0.9.0's
harness was built from `b751bef` plus the bench cases, before the version bump, so its JSON
still says 0.8.0. 0.8.0 rejects `\p{RGI_Emoji}` (`UnsupportedFeature`): that case is skipped
for the base (`XBENCH_BASE_SKIP=t1_v_rgi`, "—").

The absolute numbers of this run are higher than those of the 0.8.0 publication on many
cases for both builds (e.g. `\d{3}-\d{4}` sparse: 0.8.0 measured 573 MB/s then and 726 now):
the host, not the code. Only the two columns of the same run are compared.

#### Best round; ratio > 1: better now

| Case | Tier | execAt MB/s now | 0.8.0 | ratio | findAll MB/s now | 0.8.0 | ratio | ns short now | 0.8.0 | ratio |
|---|---|---|---|---|---|---|---|---|---|---|
| literal hello | T0 | 17571.0 | 17272.9 | 1.02 | 15559.6 | 14657.8 | 1.06 | 20 | 21 | 1.02 |
| [a-z]+ | T0 | 236.0 | 236.0 | 1.00 | 70.2 | 71.4 | 0.98 | 16 | 16 | 1.00 |
| [a-z]+ (z-regex: generic VM, no fast path) | T0 | 58.9 | 59.1 | 1.00 | 36.0 | 36.4 | 0.99 | 81 | 81 | 1.00 |
| [a-z]+ (z-regex: backtracker) | T0 | 37.6 | 38.0 | 0.99 | 26.0 | 26.7 | 0.97 | 126 | 124 | 0.99 |
| \d{3}-\d{4} (sparse) | T0 | 935.5 | 726.3 | 1.29 | 694.0 | 576.3 | 1.20 | 22 | 24 | 1.07 |
| \d{3}-\d{4} (dense) | T0 | 606.9 | 544.7 | 1.11 | 297.8 | 288.1 | 1.03 | 22 | 24 | 1.07 |
| email | T0 | 806.1 | 794.1 | 1.02 | 568.0 | 553.8 | 1.03 | 57 | 56 | 0.97 |
| (\d{3})-(\d{4}) (sparse) | T0 | 402.1 | 373.0 | 1.08 | 333.9 | 311.1 | 1.07 | 288 | 275 | 0.96 |
| (\d{3})-(\d{4}) (dense) | T0 | 102.5 | 106.8 | 0.96 | 79.4 | 80.7 | 0.98 | 289 | 275 | 0.95 |
| (?:(a)\|b)*c | T0 | 25.4 | 24.6 | 1.03 | 21.9 | 21.5 | 1.02 | 373 | 393 | 1.05 |
| book: Darcy | T0 | 16193.0 | 16031.5 | 1.01 | 8710.9 | 8953.4 | 0.97 | 20 | 21 | 1.01 |
| book: [A-Z][a-z]+ | T0 | 670.3 | 641.8 | 1.04 | 395.0 | 389.3 | 1.01 | 43 | 45 | 1.03 |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) | T0 | 891.1 | 900.0 | 0.99 | 758.7 | 752.9 | 1.01 | 491 | 484 | 0.99 |
| \p{L}+ /u | T1 | 85.3 | 82.8 | 1.03 | 51.3 | 50.1 | 1.02 | 124 | 130 | 1.04 |
| \p{Script=Greek}+ /u | T1 | 199.2 | 196.2 | 1.02 | 160.5 | 156.9 | 1.02 | 94 | 94 | 1.00 |
| \p{General_Category=Lu} /u | T1 | 153.1 | 154.1 | 0.99 | 97.9 | 100.4 | 0.98 | 53 | 54 | 1.01 |
| [\p{L}--[a-z]] /v | T1 | 61.6 | 24.8 | 2.48 | 27.1 | 16.2 | 1.67 | 53 | 204 | 3.85 |
| book: \p{L}+ /u | T1 | 98.1 | 97.3 | 1.01 | 46.5 | 46.3 | 1.00 | 30 | 31 | 1.00 |
| \p{Script=Greek}{3,} /v | T1 | 198.1 | 33.1 | 5.99 | 158.2 | 31.2 | 5.07 | 92 | 363 | 3.95 |
| [\p{L}--[a-z]]{4} /v | T1 | 126.8 | 29.0 | 4.38 | 92.3 | 26.1 | 3.53 | 106 | 308 | 2.90 |
| \b\p{Lu}{5}\b /v | T1 | 202.5 | 24.9 | 8.14 | 198.1 | 24.7 | 8.01 | 36 | 319 | 8.84 |
| [\p{L}\p{N}_]+\u{1F600} /v | T1 | 192.5 | 7.9 | 24.42 | 193.4 | 7.8 | 24.63 | 57 | 545 | 9.55 |
| (\p{Lu})(\p{Ll}+)\.$ /v | T1 | 210.4 | 14.9 | 14.08 | 209.5 | 14.9 | 14.10 | 287 | 508 | 1.77 |
| \p{RGI_Emoji}+ /v | T1 | 0.7 | — | — | 0.7 | — | — | 14485 | — | — |
| <(\w+)>.*?<\/\1> | T2 | 34.6 | 35.3 | 0.98 | 29.9 | 30.6 | 0.98 | 342 | 327 | 0.96 |
| (?=.*[a-z])(?=.*[A-Z]).{8,} | T2 | 10.3 | 10.3 | 1.00 | 9.8 | 9.9 | 0.99 | 313 | 324 | 1.03 |
| (?<=\$)\d+ | T2 | 20.4 | 20.8 | 0.98 | 19.8 | 20.3 | 0.97 | 434 | 421 | 0.97 |
| book: \b(\w+) \1\b | T2 | 11.5 | 11.4 | 1.01 | 11.4 | 11.4 | 1.00 | 274 | 286 | 1.04 |

| Adversarial | n | now | 0.8.0 |
|---|---|---|---|
| (a+)+b on a^n c | 20 | 0.002 (no match) | 0.001 (no match) |
| (a+)+b on a^n c | 25 | 0.001 (no match) | 0.001 (no match) |
| (a+)+b on a^n c | 30 | 0.001 (no match) | 0.001 (no match) |
| (a+)+b on a^n c | 40 | 0.002 (no match) | 0.002 (no match) |
| (a+)+b on a^n cb | 20 | 0.002 (no match) | 0.001 (no match) |
| (a+)+b on a^n cb | 25 | 0.001 (no match) | 0.001 (no match) |
| (a+)+b on a^n cb | 30 | 0.002 (no match) | 0.001 (no match) |
| (a+)+b on a^n cb | 40 | 0.001 (no match) | 0.001 (no match) |
| (?=(a+)+b) on a^n c | 20 | 23.351 (StepLimitExceeded) | 22.401 (StepLimitExceeded) |
| (?=(a+)+b) on a^n c | 25 | 23.125 (StepLimitExceeded) | 22.586 (StepLimitExceeded) |
| (?=(a+)+b) on a^n c | 30 | 23.159 (StepLimitExceeded) | 22.327 (StepLimitExceeded) |
| (?=(a+)+b) on a^n c | 40 | 23.191 (StepLimitExceeded) | 22.790 (StepLimitExceeded) |

- **`v`, the reason for 0.9.0:** the six `v` patterns on the mixed corpus run on T0's DFA
  (one with the tagged VM for its groups), where 0.8.0 ran them on the backtracker:

  | Pattern | execAt MB/s 0.9.0 | 0.8.0 | Factor | V8 |
  |---|---|---|---|---|
  | `[\p{L}--[a-z]]` | 61.6 | 24.8 | 2.5× | 34.8 |
  | `\p{Script=Greek}{3,}` | 198.1 | 33.1 | 6.0× | 125.8 |
  | `[\p{L}--[a-z]]{4}` | 126.8 | 29.0 | 4.4× | 41.3 |
  | `\b\p{Lu}{5}\b` | 202.5 | 24.9 | 8.1× | 194.9 |
  | `[\p{L}\p{N}_]+\u{1F600}` | 192.5 | 7.9 | 24.4× | 12.2 |
  | `(\p{Lu})(\p{Ll}+)\.$` | 210.4 | 14.9 | 14.1× | 62.9 |

  On short inputs: 53–106 ns against 204–545 (2.9–9.6×), and `(\p{Lu})(\p{Ll}+)\.$` 508 →
  287 ns. In the 2c-b probe (the node bridge, 1 MB, the match at the end) the same kind of
  patterns measured 10.3×, 12.8×, 14.7×, 57× and 32×: the gap depends on how many positions
  the backtracker tries.
- **`\p{RGI_Emoji}`:** new in 0.9.0 (2c-a), on T0's VM since 2c-b. On `^\p{RGI_Emoji}+$`
  over the 3,953 strings concatenated (the 2c-b probe), 79.65 → 27.01 ms (2.9×), from 5.3×
  to 1.8× behind V8.
- **Compile:** what the `v` patterns gain at run time they pay once at compile time: 0.8.0
  compiled them in 0.8–9.8 µs (a backtracker program of 13–6,268 bytes); 0.9.0 builds T0's
  program and DFA in 6.9–170 µs (2.2–32 KB). +6 to +169 µs per pattern in this run.
- **Other changes over 10%:** `\d{3}-\d{4}` sparse 1.29× execAt (935.5 against 726.3 MB/s)
  and dense 1.11× (606.9 against 544.7). No code on their route (Shift-And) changed in 0.9.0,
  so they are not claimed as an improvement: the host or the code layout (not checked with
  callgrind).
- **Within ±10%:** every other T0, `u` and T2 case, short inputs included
  (`(\d{3})-(\d{4})` dense 0.96, short 0.95–0.96), and the adversarial runs.
- **Worse by more than 10%:** none.

### `u`/`v` on the DFA: four patterns of T0-A's phase 3 (0.8.0)

Not in the harness: a separate probe (the `execAt` loop over the whole input, the best of 10
interleaved rounds, MB/s, the same matches) of z-regex alone, before (`fbdac3a`: `u`/`v` on
T0's VM, as in 0.7.1) and after (0.8.0's code), on this machine. The corpora: the book; a
deterministic Greek text of 1 MiB; the `.zig` files of `src/` concatenated (1.1 MB).

| Pattern | Before (VM) | 0.8.0 (DFA) | Factor |
|---|---|---|---|
| `\p{L}+` (book) | 45.2 | 96.8 | 2.14× |
| `\p{Script=Greek}+` (Greek) | 46.4 | 88.7 | 1.91× |
| `[\p{L}\p{N}_]+` (code) | 51.0 | 123.4 | 2.42× |
| `\b\p{L}+\b` (book) | 17.4 | 82.6 | 4.75× |

### zig-regex: findAll growth (characterization, not a performance number)

Measured in the 0.3.0 run (previous host) with `run.mjs --scaling`; zig-regex and its
harness haven't changed, so it wasn't re-run.

zig-regex's `findAll` restarts its VM at every start position, so its cost grows with the
square of the input: a 1 MiB pass would take on the order of an hour, and it has no MB/s in
the tables above. Measured once on prefixes of the same corpora (MB/s at 16 / 32 / 64 KiB):
literal `hello` 0.014 / 0.007 / 0.003; `[a-z]+` 0.046 / 0.022 / 0.011. Each doubling of the input
halves the throughput. zig-regex also rejects `\w` inside a class (`InvalidCharacterClass`),
so the e-mail pattern doesn't compile.

### z-regex: findAll against the iterator

`Regex.iterator` gives every match `findAll` gives, one at a time, over the caller's
`Scratch` and `MatchSlots`: no allocation once the scratch is warm. Its column is in the
tables above ("iterator MB/s"): on every case it is within the band of the execAt loop, and
1.0–3.4× findAll (the most where matches are many: `[a-z]+` 236 against 70 MB/s).

Where findAll's time goes (a separate probe on 0.3.1, on the previous host, µs per call, `smp_allocator` as in the bench):
findAll allocates one `captures` slice per match and grows its list of 72-byte `MatchResult`s.
On Darcy (417 matches) that's 426 allocations and 8 page faults per call; on `[a-z]+` (158,795
matches), 158,804 allocations and ~2,800 page faults. About 43% of findAll's time on Darcy and
63% on `[a-z]+` is outside the search. Most of it is fresh memory (the large list goes back to
the OS on free, so every call faults its pages in again): run over reused memory, findAll on
Darcy drops from ~79 to ~55 µs (execAt: ~44). The rest, ~25–30 ns per match, is building and
freeing the results. Putting every `captures` slice in one block (an arena) measured no faster.
In the `literal hello` row the findAll/execAt gap (1.13× in these tables) is mostly noise:
a pass takes ~60 µs and each timed sample is one pass; timed over ≥ 150 ms per sample the gap
is ~1.05×.

## Notes

- V8 has a JIT; z-regex doesn't. Both are real.
- Rust regex doesn't support backreferences; the T2 cases are not compared against it.
- Absolute numbers vary with LLVM's code layout between builds; the best of 10 rounds is
  within ~4% (p90) between two series (F7-0).
- Match counts are identical across every engine, z-regex 0.8.0 included, on every case
  (0.8.0 doesn't run `\p{RGI_Emoji}+`).
- Everything here is one machine, a shared container: compare engines within a table, not
  numbers across machines.
