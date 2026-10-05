# Benchmarks: z-regex against V8, Rust regex, PCRE2, zig-regex and zoptia0regex

**v0.9.0, after F5c (`v` on T0).** What this measures: z-regex 0.9.0 (measured on commit
`c724d26`; the engine code is 0.9.0's) against the engines people would use instead, **tier
by tier** (docs/REGEX_TIERS_PLAN.md): a T0 case is compared only with engines that run it as a
regular expression, a T2 case (backreferences, lookaround) only with backtracking engines
that support it. Tiers are never mixed in one table. z-regex 0.8.0, the version of the
previous publication, runs in the same rounds as a base (see "Against 0.8.0").

This run (after 0.9.0's release, to add zoptia0regex to every table) replaces the one of the
release: the figures of `docs/RELEASE_NOTES_v0.9.0.md` are the release run's and can differ
from these by this host's noise.

## Headline (v0.9.0, execAt)

Reference: V8 warm, Rust regex and zoptia0regex, the `execAt` tables under "Results", best
round. Each "×" is the ratio of two cells of the same table, never a number across tables,
tiers or hosts. Even: within ±10%. The method is under "Setup", the raw tables under
"Results".

**T0 (z-regex: T0's DFA, its fast paths, and the tagged VM for groups)**

| Case | Route | vs V8 | vs Rust regex | vs zoptia0regex |
|---|---|---|---|---|
| literal `hello` | literal | **7.7× ahead** | 1.45× behind | **10.1× ahead** |
| `[a-z]+` | class run | **2.5× ahead** | **3.3× ahead** | **11.0× ahead** |
| `\d{3}-\d{4}` sparse | Shift-And | even (1.01× behind) | 1.97× behind | **2.8× ahead** |
| `\d{3}-\d{4}` dense | Shift-And | **3.2× ahead** | **6.4× ahead** | **29× ahead** |
| e-mail | DFA | **9.3× ahead** | even (1.04× ahead) | **30× ahead** |
| `(\d{3})-(\d{4})` sparse | Shift-And, tagged VM | 3.1× behind | 3.4× behind | **1.21× ahead** |
| `(\d{3})-(\d{4})` dense | Shift-And, tagged VM | 1.83× behind | **1.11× ahead** | **5.3× ahead** |
| `(?:(a)\|b)*c` | DFA, tagged VM | 1.34× behind | 2.3× behind | **1.85× ahead** |
| book: `Darcy` | literal | **1.52× ahead** | 1.43× behind | **2.4× ahead** |
| book: `[A-Z][a-z]+` | DFA | **1.21× ahead** | **2.0× ahead** | **15× ahead** |
| book: `(Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+)` | DFA, tagged VM | **1.61× ahead** | 2.9× behind | even (1.09× ahead) |

**T1 (`u`/`v`: T0's DFA in code-point mode; since 0.9.0 `v` runs there too; Rust regex has
no `v`; zoptia0regex runs each `v` pattern written in RE2 syntax, see "Against zoptia0regex")**

| Case | Route | vs V8 | vs Rust regex | vs zoptia0regex |
|---|---|---|---|---|
| `\p{L}+ /u` | DFA | **2.0× ahead** | **1.17× ahead** | **3.2× ahead** |
| `\p{Script=Greek}+ /u` | DFA | **1.81× ahead** | 1.41× behind | **4.0× ahead** |
| `\p{General_Category=Lu} /u` | DFA | **2.4× ahead** | 1.43× behind | **3.7× ahead** |
| book: `\p{L}+ /u` | DFA | **3.4× ahead** | **1.67× ahead** | **4.6× ahead** |
| `[\p{L}--[a-z]] /v` | DFA | **1.94× ahead** | n/a | **3.0× ahead** |
| `\p{Script=Greek}{3,} /v` | DFA | **1.61× ahead** | n/a | **4.4× ahead** |
| `[\p{L}--[a-z]]{4} /v` | DFA | **3.1× ahead** | n/a | **4.2× ahead** |
| `\b\p{Lu}{5}\b /v` | DFA | even (1.04× behind) | n/a | **3.1× ahead** |
| `[\p{L}\p{N}_]+\u{1F600} /v` | DFA | **17.8× ahead** | n/a | **5.8× ahead** |
| `(\p{Lu})(\p{Ll}+)\.$ /v` | DFA, tagged VM | **3.2× ahead** | n/a | **5.9× ahead** |
| `\p{RGI_Emoji}+ /v` (emoji corpus) | VM | 2.3× behind | n/a | n/a |

**T2 (the explicit-stack backtracker; Rust regex and zoptia0regex have no backreferences or
lookaround)**

| Case | vs V8 | vs PCRE2 JIT | vs PCRE2 interp. |
|---|---|---|---|
| `<(\w+)>.*?<\/\1>` | 6.3× behind | 7.7× behind | 2.5× behind |
| `(?=.*[a-z])(?=.*[A-Z]).{8,}` | 5.5× behind | 7.7× behind | 1.18× behind |
| `(?<=\$)\d+` | 14× behind | 59× behind | 30× behind |
| book: `\b(\w+) \1\b` | 14× behind | 9.9× behind | 2.3× behind |

**Where z-regex is ahead**
- **`v` on T0** (0.9.0): every `v` case but `\p{RGI_Emoji}+` runs on the DFA and is ahead of
  V8 or even with it (1.04–17.8×). Against 0.8.0, where these cases ran on the backtracker,
  they are 3.0–27× faster (see "Against 0.8.0").
- **T0's DFA:**
  - the e-mail 9.3× V8, the book's title pattern 1.61× V8, the book's `[A-Z][a-z]+` 2.0× Rust;
  - on T1 every `u` case is ahead of V8 (1.81–3.4×);
  - `\p{L}+` is ahead of Rust (1.17× on the mixed corpus, 1.67× on the book).
- **Fast paths:** `[a-z]+` (class run) 2.5× V8 and 3.3× Rust; `\d{3}-\d{4}` on dense digits
  (Shift-And) 3.2× V8 and 6.4× Rust; the literal `hello` 7.7× V8.
- **Against zoptia0regex:** ahead on every case with execAt. The gap is widest where the DFA
  or a fast path runs (10–30×) and zoptia runs its Pike VM; on T1 it is 3.0–5.9×.
- **Short inputs** without groups:
  - 20–72 ns on T0, ahead of V8 on every such case (1.5–3.6×);
  - ahead of Rust on most (`[a-z]+` 20 ns against 82, the e-mail 72 against 85);
  - on T1, the `v` cases without groups take 51–129 ns against V8's 90–478.
- **Compile time:**
  - 1.7–25 µs on T0 (the e-mail 12.7 µs, the DFA included) against 2.6–197 µs for Rust
    regex;
  - 6–42 µs for the `u` cases of T1 against Rust's 56–327.
- **Adversarial:** `(a+)+b` runs on T0 (the DFA gives the bounds), a few µs at any n.
  - V8 is exponential (seconds at n = 25, killed after 5 s at n = 30).
  - PCRE2 answers at once when a required character is absent. On `(a+)+b` over `a^n cb` it
    stops at its match limit (~29 ms JIT, ~190 ms interpreter) with an error instead of an
    answer.
  - zoptia0regex is linear too (4–6 µs).

**Even (±10%):**
- the e-mail against Rust regex;
- `\d{3}-\d{4}` sparse and `\b\p{Lu}{5}\b /v` against V8;
- the book's title pattern against zoptia0regex.

**Where it's behind, and why**
- **`\p{RGI_Emoji}+ /v`:**
  - Figures: 2.3× behind V8 on the emoji corpus (0.6 against 1.3 MB/s); 15.9 µs against
    5.1 µs on a short input; 14.6 ms to compile, 528,637 bytes.
  - Why: the class holds 3,953 strings, so the program is over the DFA's limit
    (`dfa.max_insts_for_dfa`, 2,000 instructions). It runs on the Pike VM, which carries the
    whole trie of alternatives at every position.
  - The release's own measurement (`^\p{RGI_Emoji}+$` over the 3,953 strings concatenated)
    put it 1.8× behind V8, where the backtracker of 0.8.0 was 5.3× behind.
- **Groups on T0** (`(\d{3})-(\d{4})`, `(?:(a)|b)*c`, the title pattern against Rust):
  - 1.34–3.1× behind V8 and 2.3–3.4× behind Rust;
  - why: the DFA (or Shift-And) gives the match bounds, and the tagged VM then fills the
    groups over the span. That is a second pass, on the Pike VM.
- **Literals against Rust:** 1.43–1.45× behind (`hello`, `Darcy`). Rust's `memchr` picks the
  rarest bytes of each needle and the vector width at run time; z-regex searches the first
  and last bytes in pairs of vectors of a width fixed at build time (AVX2 here).
- **Sparse `\d{3}-\d{4}` against Rust:** 1.97× behind. Shift-And steps every byte, where
  Rust's prefilter skips to the digits.
- **Short inputs with groups:**
  - 3.1–5.9× behind V8 (e.g. `(\d{3})-(\d{4})` 374 ns against 117);
  - 1.56–3.2× behind zoptia0regex (374 ns against 140);
  - why: the tagged VM's fixed cost per search.
  - zoptia0regex is also ahead on the short literals (19 ns against 25–26).
- **T1 against Rust:** `\p{Script=Greek}+` and `\p{General_Category=Lu}` are 1.41–1.43×
  behind. The DFA decodes UTF-8 one character at a time and looks non-ASCII classes up by
  binary search over the cuts; Rust's DFA steps bytes.
- **findAll:**
  - z-regex's facade allocates per match; on dense cases it gives up most of the execAt
    speed (`[a-z]+` 192 → 51 MB/s, the e-mail 738 → 533). `Regex.iterator` doesn't.
  - zoptia0regex's findAll is ahead of z-regex's on `(\d{3})-(\d{4})` sparse (0.93) and the
    title pattern (0.71): it collects only the bounds.
- **T2:** unchanged since 0.7.0.
  - Figures: 5.5–14× behind V8, 7.7–59× behind PCRE2 JIT and 1.18–30× behind PCRE2's
    interpreter.
  - The lookbehind case is the worst (14× behind V8, 59× behind PCRE2 JIT): the backward
    body runs at every position, with no prefilter on `$`.
- **`(?=(a+)+b)`** (a genuine T2 adversarial): z-regex stops at its step budget after ~33 ms
  with `StepLimitExceeded`: bounded, but not an answer. V8 is exponential; PCRE2 answers at
  once (required-character shortcut).
- **Compile time:**
  - **Against zoptia0regex:** zoptia0regex compiles faster on every case, 1.6–42×
    (`\b\p{Lu}{5}\b /v`: 269 µs against 6.5).
  - **The cost of `v`:** a `v` pattern now builds T0's program and its DFA, where 0.8.0 built
    a backtracker program. That adds tens to hundreds of µs per small pattern (see
    "Against 0.8.0") and 14.6 ms for `\p{RGI_Emoji}+`, which 0.8.0 rejected.
  - It is paid once per compiled pattern: an accepted cost.

## Setup

| | |
|---|---|
| Machine | Intel(R) Xeon(R) Processor @ 2.80GHz, 4 cores (no SMT), KVM guest, 15Gi RAM, Linux 6.18.44-fc-v64 |
| Environment | **shared container**: a case moves by ±20% from one process to the next; read the band, not only the best round |
| z-regex | 0.9.0 (commit `c724d26`: 0.9.0's engine code plus the zoptia0regex harness), and 0.8.0 (tag `v0.8.0`, `edde4e1`) as the base. Zig 0.16.0, ReleaseFast, **`-Dcpu=x86_64_v3`** (AVX2, no AVX-512), the CPU model of `scripts/measure_binary.sh` |
| V8 | 12.4.254.21-node.39 (Node v22.22.2) |
| Rust regex | 1.13.1 (rustc 1.94.1 (e408947bf 2026-03-25)), release, LTO |
| PCRE2 | 10.42, 8-bit library, JIT and interpreter |
| zig-regex | 0.1.1 (zig-utils/zig-regex, 173b298), the last release that builds with Zig 0.16 (v0.2.x needs 0.17-dev); built `native` by `setup_zigregex.sh` |
| zoptia0regex | zoptia/zoptia0regex at `8e8f225` (no tags), a port of Go's `regexp`; ReleaseFast, `-mcpu=x86_64_v3`, built by `setup_zoptia.sh`; its patterns and metrics under "Against zoptia0regex" |

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
feature it lacks). "unsupported": the engine rejects the pattern. zoptia0regex's execAt column
is its `matchesScratch` iterator, and it runs six patterns in RE2 syntax (see "Against
zoptia0regex").

#### T0: findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)

| Case | z-regex | V8 (warm) | V8 (cold) | Rust regex | zig-regex | zoptia0regex |
|---|---|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 11948.4 (8451.0–11948.4) | 1750.0 (1177.8–1750.0) | 1505.5 (773.3–1505.5) | 19042.2 (9857.4–19042.2) | — | 1350.2 (907.7–1350.2) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 51.1 (30.8–51.1) | 74.3 (33.5–74.3) | 49.6 (28.5–49.6) | 55.0 (28.9–55.0) | — | 16.4 (9.7–16.4) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 25.8 (12.8–25.8) | n/a | n/a | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 19.4 (9.7–19.4) | n/a | n/a | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 654.3 (289.5–654.3) | 1163.8 (612.9–1163.8) | 378.8 (178.3–378.8) | 1705.0 (1020.1–1705.0) | — | 311.8 (146.2–311.8) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 244.4 (188.9–244.4) | 161.6 (99.8–161.6) | 95.1 (49.3–95.1) | 81.7 (52.8–81.7) | — | 18.5 (10.6–18.5) |
| email <sub>(z-regex: DFA)</sub> | 532.8 (376.3–532.8) | 79.0 (42.9–79.0) | 66.2 (33.6–66.2) | 687.7 (349.6–687.7) | unsupported | 23.9 (13.2–23.9) |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 282.0 (132.9–282.0) | 948.0 (364.5–948.0) | 319.9 (159.2–319.9) | 823.4 (358.4–823.4) | — | 304.4 (133.6–304.4) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 57.6 (29.2–57.6) | 126.5 (53.0–126.5) | 91.9 (44.4–91.9) | 59.5 (28.2–59.5) | — | 17.7 (9.7–17.7) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 17.8 (10.1–17.8) | 29.0 (16.6–29.0) | 24.8 (15.4–24.8) | 38.1 (23.5–38.1) | — | 13.0 (7.1–13.0) |
| book: Darcy <sub>(z-regex: VM)</sub> | 6497.9 (3624.2–6497.9) | 8144.7 (4551.6–8144.7) | 2387.8 (770.5–2387.8) | 17530.4 (9816.9–17530.4) | — | 5379.4 (1912.3–5379.4) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 348.2 (254.9–348.2) | 475.1 (216.6–475.1) | 132.0 (69.5–132.0) | 281.9 (203.3–281.9) | — | 39.0 (14.9–39.0) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 548.7 (325.3–548.7) | 446.0 (284.6–446.0) | 338.6 (225.0–338.6) | 1643.6 (778.6–1643.6) | — | 771.6 (351.3–771.6) |

#### T0: execAt MB/s (engine loop, no per-match allocation where the API allows)

| Case | z-regex | V8 (warm) | Rust regex | zig-regex | zoptia0regex |
|---|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 13619.5 (9209.1–13619.5) | 1775.3 (1312.2–1775.3) | 19685.8 (9489.5–19685.8) | — | 1345.3 (964.1–1345.3) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 191.8 (119.0–191.8) | 75.8 (41.5–75.8) | 59.0 (31.8–59.0) | — | 17.5 (11.7–17.5) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 43.3 (18.5–43.3) | n/a | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 27.9 (13.7–27.9) | n/a | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 896.0 (834.9–896.0) | 902.9 (378.8–902.9) | 1762.5 (1069.3–1762.5) | — | 325.1 (150.6–325.1) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 538.1 (309.0–538.1) | 167.9 (104.2–167.9) | 84.2 (56.5–84.2) | — | 18.5 (10.7–18.5) |
| email <sub>(z-regex: DFA)</sub> | 737.9 (517.7–737.9) | 79.6 (43.2–79.6) | 711.5 (365.0–711.5) | unsupported | 24.8 (14.6–24.8) |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 334.5 (189.7–334.5) | 1022.9 (420.4–1022.9) | 1149.1 (472.4–1149.1) | — | 275.4 (116.4–275.4) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 79.1 (41.1–79.1) | 144.8 (62.5–144.8) | 71.5 (33.3–71.5) | — | 14.8 (8.4–14.8) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 22.1 (11.0–22.1) | 29.6 (16.9–29.6) | 50.7 (30.3–50.7) | — | 12.0 (7.0–12.0) |
| book: Darcy <sub>(z-regex: VM)</sub> | 13457.8 (7558.2–13457.8) | 8867.2 (4838.3–8867.2) | 19216.8 (11071.4–19216.8) | — | 5697.6 (2163.9–5697.6) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 596.7 (390.2–596.7) | 493.0 (252.3–493.0) | 302.6 (215.5–302.6) | — | 39.7 (15.6–39.7) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 735.5 (381.4–735.5) | 457.8 (314.2–457.8) | 2115.2 (1036.8–2115.2) | — | 677.8 (320.8–677.8) |

#### T0: z-regex iterator MB/s (Regex.iterator: every match, warm Scratch, no allocation)

| Case | z-regex |
|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 13630.8 (9807.2–13630.8) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 184.2 (113.9–184.2) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 43.3 (21.6–43.3) |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 29.3 (13.6–29.3) |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 892.6 (781.5–892.6) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 528.6 (343.3–528.6) |
| email <sub>(z-regex: DFA)</sub> | 743.9 (524.7–743.9) |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 332.5 (189.5–332.5) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 79.2 (43.0–79.2) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 22.0 (12.7–22.0) |
| book: Darcy <sub>(z-regex: VM)</sub> | 13398.8 (7876.0–13398.8) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 595.6 (381.4–595.6) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 733.7 (342.0–733.7) |

#### T0: ns per exec on a short input (< 64 B)

| Case | z-regex | V8 (warm) | Rust regex | zig-regex | zoptia0regex |
|---|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 26 (26–36) | 68 (68–169) | 22 (22–39) | 420 (420–622) | 19 (19–32) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 20 (20–48) | 71 (71–149) | 82 (82–147) | 621 (621–1353) | 127 (127–254) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 111 (111–201) | n/a | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 162 (162–358) | n/a | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 27 (27–28) | 85 (85–174) | 76 (76–125) | 1501 (1501–3077) | 127 (127–228) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 27 (27–59) | 86 (86–181) | 75 (75–163) | 1475 (1475–3016) | 128 (128–215) |
| email <sub>(z-regex: DFA)</sub> | 72 (72–129) | 141 (141–280) | 85 (85–126) | unsupported | 335 (335–724) |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 374 (374–673) | 117 (117–240) | 136 (136–319) | 3646 (3646–5470) | 140 (140–228) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 363 (363–590) | 116 (116–234) | 137 (137–281) | 3685 (3685–6131) | 142 (142–281) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 477 (477–811) | 81 (81–162) | 148 (148–300) | 3411 (3411–5640) | 200 (200–498) |
| book: Darcy <sub>(z-regex: VM)</sub> | 25 (25–45) | 75 (75–145) | 21 (21–38) | 406 (406–873) | 19 (19–47) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 56 (56–101) | 84 (84–152) | 88 (88–157) | 1798 (1798–3952) | 253 (253–636) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 618 (618–1008) | 111 (111–221) | 175 (175–327) | 8763 (8763–13041) | 194 (194–465) |

#### T0: µs per compile

| Case | z-regex | Rust regex | zig-regex | zoptia0regex |
|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 1.71 (1.71–2.67) | 2.83 (2.83–5.64) | 0.96 (0.96–1.61) | 1.01 (1.01–1.75) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 1.66 (1.66–2.55) | 8.52 (8.52–17.82) | 0.63 (0.63–1.12) | 0.72 (0.72–1.30) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 1.39 (1.39–2.98) | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 0.84 (0.84–1.27) | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 2.63 (2.63–4.61) | 192.96 (192.96–314.60) | 1.29 (1.29–2.78) | 1.53 (1.53–3.14) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 2.61 (2.61–4.15) | 192.29 (192.29–354.02) | 1.26 (1.26–3.41) | 1.54 (1.54–2.77) |
| email <sub>(z-regex: DFA)</sub> | 12.72 (12.72–22.10) | 21.37 (21.37–43.46) | unsupported | 2.21 (2.21–3.64) |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 3.24 (3.24–5.96) | 196.90 (196.90–408.86) | 1.63 (1.63–3.23) | 2.00 (2.00–3.36) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 3.26 (3.26–6.96) | 197.23 (197.23–478.23) | 1.64 (1.64–2.68) | 2.01 (2.01–3.37) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 7.43 (7.43–13.50) | 13.40 (13.40–26.28) | 1.15 (1.15–2.25) | 1.65 (1.65–2.98) |
| book: Darcy <sub>(z-regex: VM)</sub> | 1.72 (1.72–2.76) | 2.58 (2.58–5.23) | 1.00 (1.00–1.75) | 1.01 (1.01–2.09) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 4.96 (4.96–5.16) | 10.70 (10.70–19.12) | 0.88 (0.88–1.48) | 0.96 (0.96–2.04) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 24.88 (24.88–49.97) | 29.37 (29.37–54.68) | 3.30 (3.30–4.54) | 3.99 (3.99–7.33) |

#### T0: bytes per compiled pattern

| Case | z-regex | zig-regex | zoptia0regex |
|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 185 (185–185) | 2322 (2322–2322) | 3532 (3532–3532) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 135 (135–135) | 1016 (1016–1016) | 872 (872–872) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 135 (135–135) | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 19 (19–19) | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 1349 (1349–1349) | 3817 (3817–3817) | 3008 (3008–3008) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 1349 (1349–1349) | 3817 (3817–3817) | 3008 (3008–3008) |
| email <sub>(z-regex: DFA)</sub> | 2165 (2165–2165) | unsupported | 2854 (2854–2854) |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 1457 (1457–1457) | 5365 (5365–5365) | 6030 (6030–6030) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 1457 (1457–1457) | 5365 (5365–5365) | 6030 (6030–6030) |
| (?:(a)\|b)*c <sub>(z-regex: DFA, tagged VM)</sub> | 1393 (1393–1393) | 3227 (3227–3227) | 3050 (3050–3050) |
| book: Darcy <sub>(z-regex: VM)</sub> | 185 (185–185) | 2322 (2322–2322) | 3532 (3532–3532) |
| book: [A-Z][a-z]+ <sub>(z-regex: DFA)</sub> | 1176 (1176–1176) | 1751 (1751–1751) | 1298 (1298–1298) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: DFA, tagged VM)</sub> | 3284 (3284–3284) | 9370 (9370–9370) | 6866 (6866–6866) |

#### T1: findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)

| Case | z-regex | V8 (warm) | V8 (cold) | Rust regex | zoptia0regex |
|---|---|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 40.8 (22.9–40.8) | 36.4 (31.2–36.4) | 28.7 (12.8–28.7) | 62.3 (31.3–62.3) | 22.8 (13.2–22.8) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 123.8 (59.3–123.8) | 98.8 (47.2–98.8) | 62.8 (33.1–62.8) | 215.7 (105.0–215.7) | 39.1 (25.1–39.1) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 77.0 (35.1–77.0) | 51.9 (30.2–51.9) | 39.7 (24.0–39.7) | 173.3 (77.4–173.3) | 34.4 (23.0–34.4) |
| [\p{L}--[a-z]] /v <sub>(z-regex: DFA)</sub> | 22.2 (12.1–22.2) | 25.7 (14.5–25.7) | 20.4 (12.8–20.4) | n/a | 16.2 (9.7–16.2) |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 36.2 (20.5–36.2) | 25.5 (12.0–25.5) | 19.3 (11.7–19.3) | 50.7 (25.1–50.7) | 16.9 (9.0–16.9) |
| \p{Script=Greek}{3,} /v <sub>(z-regex: DFA)</sub> | 124.2 (52.8–124.2) | 102.6 (41.6–102.6) | 65.6 (32.5–65.6) | n/a | 37.5 (19.0–37.5) |
| [\p{L}--[a-z]]{4} /v <sub>(z-regex: DFA)</sub> | 73.4 (34.6–73.4) | 33.3 (16.5–33.3) | 26.5 (18.3–26.5) | n/a | 24.7 (13.7–24.7) |
| \b\p{Lu}{5}\b /v <sub>(z-regex: DFA)</sub> | 165.0 (98.7–165.0) | 172.6 (80.5–172.6) | 151.1 (105.5–151.1) | n/a | 53.6 (27.0–53.6) |
| [\p{L}\p{N}_]+\u{1F600} /v <sub>(z-regex: DFA)</sub> | 165.7 (110.3–165.7) | 9.4 (5.3–9.4) | 9.2 (4.8–9.2) | n/a | 28.8 (17.2–28.8) |
| (\p{Lu})(\p{Ll}+)\.$ /v <sub>(z-regex: DFA, tagged VM)</sub> | 174.0 (106.4–174.0) | 54.0 (31.7–54.0) | 50.8 (25.0–50.8) | n/a | 33.9 (30.3–33.9) |
| \p{RGI_Emoji}+ /v <sub>(z-regex: VM)</sub> | 0.6 (0.3–0.6) | 1.2 (0.9–1.2) | 1.2 (0.9–1.2) | n/a | n/a |

#### T1: execAt MB/s (engine loop, no per-match allocation where the API allows)

| Case | z-regex | V8 (warm) | Rust regex | zoptia0regex |
|---|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 77.3 (39.8–77.3) | 37.8 (24.6–37.8) | 66.3 (38.6–66.3) | 24.2 (13.3–24.2) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 161.3 (78.2–161.3) | 89.1 (44.7–89.1) | 226.6 (103.9–226.6) | 40.7 (21.4–40.7) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 131.1 (54.7–131.1) | 53.6 (25.2–53.6) | 187.0 (80.9–187.0) | 35.8 (25.1–35.8) |
| [\p{L}--[a-z]] /v <sub>(z-regex: DFA)</sub> | 53.0 (29.0–53.0) | 27.4 (13.8–27.4) | n/a | 17.8 (9.7–17.8) |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 89.2 (46.8–89.2) | 26.2 (14.9–26.2) | 53.3 (29.8–53.3) | 19.4 (10.6–19.4) |
| \p{Script=Greek}{3,} /v <sub>(z-regex: DFA)</sub> | 166.3 (68.6–166.3) | 103.6 (43.3–103.6) | n/a | 37.5 (18.2–37.5) |
| [\p{L}--[a-z]]{4} /v <sub>(z-regex: DFA)</sub> | 106.3 (62.8–106.3) | 34.9 (18.2–34.9) | n/a | 25.6 (12.5–25.6) |
| \b\p{Lu}{5}\b /v <sub>(z-regex: DFA)</sub> | 167.1 (74.9–167.1) | 173.8 (91.3–173.8) | n/a | 54.3 (41.3–54.3) |
| [\p{L}\p{N}_]+\u{1F600} /v <sub>(z-regex: DFA)</sub> | 166.6 (113.5–166.6) | 9.4 (6.4–9.4) | n/a | 28.6 (15.7–28.6) |
| (\p{Lu})(\p{Ll}+)\.$ /v <sub>(z-regex: DFA, tagged VM)</sub> | 173.3 (108.1–173.3) | 54.5 (32.7–54.5) | n/a | 29.2 (13.4–29.2) |
| \p{RGI_Emoji}+ /v <sub>(z-regex: VM)</sub> | 0.6 (0.5–0.6) | 1.3 (0.9–1.3) | n/a | n/a |

#### T1: z-regex iterator MB/s (Regex.iterator: every match, warm Scratch, no allocation)

| Case | z-regex |
|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 76.9 (39.7–76.9) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 157.9 (79.6–157.9) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 131.4 (54.6–131.4) |
| [\p{L}--[a-z]] /v <sub>(z-regex: DFA)</sub> | 51.9 (24.3–51.9) |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 89.8 (54.6–89.8) |
| \p{Script=Greek}{3,} /v <sub>(z-regex: DFA)</sub> | 165.9 (68.6–165.9) |
| [\p{L}--[a-z]]{4} /v <sub>(z-regex: DFA)</sub> | 107.2 (52.7–107.2) |
| \b\p{Lu}{5}\b /v <sub>(z-regex: DFA)</sub> | 167.7 (75.4–167.7) |
| [\p{L}\p{N}_]+\u{1F600} /v <sub>(z-regex: DFA)</sub> | 167.7 (111.4–167.7) |
| (\p{Lu})(\p{Ll}+)\.$ /v <sub>(z-regex: DFA, tagged VM)</sub> | 170.0 (107.4–170.0) |
| \p{RGI_Emoji}+ /v <sub>(z-regex: VM)</sub> | 0.6 (0.4–0.6) |

#### T1: ns per exec on a short input (< 64 B)

| Case | z-regex | V8 (warm) | Rust regex | zoptia0regex |
|---|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 140 (140–305) | 177 (177–362) | 112 (112–223) | 223 (223–394) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 114 (114–279) | 179 (179–346) | 114 (114–308) | 241 (241–446) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 66 (66–149) | 155 (155–272) | 54 (54–152) | 135 (135–192) |
| [\p{L}--[a-z]] /v <sub>(z-regex: DFA)</sub> | 65 (65–142) | 187 (187–439) | n/a | 140 (140–280) |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 38 (38–73) | 74 (74–128) | 74 (74–150) | 115 (115–203) |
| \p{Script=Greek}{3,} /v <sub>(z-regex: DFA)</sub> | 110 (110–285) | 168 (168–325) | n/a | 254 (254–639) |
| [\p{L}--[a-z]]{4} /v <sub>(z-regex: DFA)</sub> | 129 (129–282) | 278 (278–500) | n/a | 212 (212–460) |
| \b\p{Lu}{5}\b /v <sub>(z-regex: DFA)</sub> | 51 (51–135) | 90 (90–177) | n/a | 235 (235–384) |
| [\p{L}\p{N}_]+\u{1F600} /v <sub>(z-regex: DFA)</sub> | 68 (68–135) | 478 (478–813) | n/a | 250 (250–421) |
| (\p{Lu})(\p{Ll}+)\.$ /v <sub>(z-regex: DFA, tagged VM)</sub> | 346 (346–640) | 99 (99–199) | n/a | 222 (222–389) |
| \p{RGI_Emoji}+ /v <sub>(z-regex: VM)</sub> | 15933 (15933–21114) | 5060 (5060–6498) | n/a | n/a |

#### T1: µs per compile

| Case | z-regex | Rust regex | zoptia0regex |
|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 42.14 (42.14–83.92) | 322.94 (322.94–608.30) | 8.63 (8.63–19.12) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 6.42 (6.42–13.35) | 56.09 (56.09–93.75) | 1.25 (1.25–3.03) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 40.69 (40.69–106.86) | 193.02 (193.02–462.88) | 12.79 (12.79–19.20) |
| [\p{L}--[a-z]] /v <sub>(z-regex: DFA)</sub> | 46.63 (46.63–121.09) | n/a | 25.16 (25.16–54.28) |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 42.09 (42.09–97.52) | 327.08 (327.08–556.45) | 8.65 (8.65–18.84) |
| \p{Script=Greek}{3,} /v <sub>(z-regex: DFA)</sub> | 8.40 (8.40–17.15) | n/a | 1.54 (1.54–2.47) |
| [\p{L}--[a-z]]{4} /v <sub>(z-regex: DFA)</sub> | 152.02 (152.02–362.79) | n/a | 18.38 (18.38–42.70) |
| \b\p{Lu}{5}\b /v <sub>(z-regex: DFA)</sub> | 268.96 (268.96–558.98) | n/a | 6.47 (6.47–12.54) |
| [\p{L}\p{N}_]+\u{1F600} /v <sub>(z-regex: DFA)</sub> | 71.52 (71.52–173.83) | n/a | 22.30 (22.30–38.16) |
| (\p{Lu})(\p{Ll}+)\.$ /v <sub>(z-regex: DFA, tagged VM)</sub> | 132.30 (132.30–255.87) | n/a | 19.27 (19.27–41.82) |
| \p{RGI_Emoji}+ /v <sub>(z-regex: VM)</sub> | 14636.90 (14636.90–21260.01) | n/a | n/a |

#### T1: bytes per compiled pattern

| Case | z-regex | zoptia0regex |
|---|---|---|
| \p{L}+ /u <sub>(z-regex: DFA)</sub> | 22852 (22852–22852) | 15808 (15808–15808) |
| \p{Script=Greek}+ /u <sub>(z-regex: DFA)</sub> | 2116 (2116–2116) | 1472 (1472–1472) |
| \p{General_Category=Lu} /u <sub>(z-regex: DFA)</sub> | 21871 (21871–21871) | 15808 (15808–15808) |
| [\p{L}--[a-z]] /v <sub>(z-regex: DFA)</sub> | 28250 (28250–28250) | 15318 (15318–15318) |
| book: \p{L}+ /u <sub>(z-regex: DFA)</sub> | 22852 (22852–22852) | 15808 (15808–15808) |
| \p{Script=Greek}{3,} /v <sub>(z-regex: DFA)</sub> | 2223 (2223–2223) | 5036 (5036–5036) |
| [\p{L}--[a-z]]{4} /v <sub>(z-regex: DFA)</sub> | 28409 (28409–28409) | 15366 (15366–15366) |
| \b\p{Lu}{5}\b /v <sub>(z-regex: DFA)</sub> | 24586 (24586–24586) | 15746 (15746–15746) |
| [\p{L}\p{N}_]+\u{1F600} /v <sub>(z-regex: DFA)</sub> | 32248 (32248–32248) | 15540 (15540–15540) |
| (\p{Lu})(\p{Ll}+)\.$ /v <sub>(z-regex: DFA, tagged VM)</sub> | 30608 (30608–30608) | 42220 (42220–42220) |
| \p{RGI_Emoji}+ /v <sub>(z-regex: VM)</sub> | 528637 (528637–528637) | n/a |

#### T2: findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)

| Case | z-regex | V8 (warm) | V8 (cold) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 22.4 (9.4–22.4) | 149.9 (91.0–149.9) | 87.6 (50.3–87.6) | 190.2 (96.5–190.2) | 62.2 (38.0–62.2) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 7.2 (3.9–7.2) | 40.0 (24.1–40.0) | 32.6 (16.5–32.6) | 56.9 (36.4–56.9) | 8.9 (3.7–8.9) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 14.3 (7.4–14.3) | 193.2 (80.7–193.2) | 117.2 (55.3–117.2) | 823.0 (367.3–823.0) | 421.9 (188.3–421.9) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 8.9 (4.3–8.9) | 121.7 (83.5–121.7) | 115.2 (58.6–115.2) | 86.2 (49.1–86.2) | 21.3 (10.7–21.3) |

#### T2: execAt MB/s (engine loop, no per-match allocation where the API allows)

| Case | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 26.3 (10.3–26.3) | 164.6 (103.7–164.6) | 202.8 (120.8–202.8) | 64.9 (42.6–64.9) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 7.5 (3.6–7.5) | 41.3 (19.6–41.3) | 57.7 (40.9–57.7) | 8.9 (5.3–8.9) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 14.5 (6.5–14.5) | 199.1 (81.6–199.1) | 856.3 (380.8–856.3) | 430.5 (194.9–430.5) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 9.0 (4.4–9.0) | 122.8 (84.4–122.8) | 88.2 (46.2–88.2) | 20.4 (11.5–20.4) |

#### T2: z-regex iterator MB/s (Regex.iterator: every match, warm Scratch, no allocation)

| Case | z-regex |
|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 26.0 (12.1–26.0) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 7.4 (3.4–7.4) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 14.3 (6.3–14.3) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 9.0 (4.3–9.0) |

#### T2: ns per exec on a short input (< 64 B)

| Case | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 453 (453–1036) | 82 (82–144) | 57 (57–110) | 191 (191–333) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 442 (442–784) | 130 (130–306) | 75 (75–125) | 349 (349–582) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 573 (573–1176) | 95 (95–105) | 46 (46–91) | 111 (111–245) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 335 (335–739) | 93 (93–176) | 59 (59–135) | 127 (127–246) |

#### T2: µs per compile

| Case | z-regex | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 2.97 (2.97–6.58) | 7.85 (7.85–18.90) | 0.79 (0.79–1.69) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 4.47 (4.47–7.42) | 6.59 (6.59–18.20) | 1.01 (1.01–2.00) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 1.83 (1.83–2.89) | 4.36 (4.36–11.64) | 0.53 (0.53–1.23) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 2.03 (2.03–4.61) | 7.29 (7.29–18.34) | 0.67 (0.67–1.53) |

#### T2: bytes per compiled pattern

| Case | z-regex | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 92 (92–92) | 1287 (1287–1287) | 168 (168–168) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 1820 (1820–1820) | 963 (963–963) | 231 (231–231) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 714 (714–714) | 687 (687–687) | 156 (156–156) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 59 (59–59) | 1226 (1226–1226) | 160 (160–160) |

#### Adversarial: ms until the engine answers or gives up (best round; outcome)

| Case | n | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) | zoptia0regex |
|---|---|---|---|---|---|---|
| (a+)+b on a^n c | 20 | 0.002 (no match) | 109.335 (no match) | 0.006 (no match) | 0.007 (no match) | 0.004 (no match) |
| (a+)+b on a^n c | 25 | 0.002 (no match) | 3934.541 (no match) | 0.006 (no match) | 0.006 (no match) | 0.004 (no match) |
| (a+)+b on a^n c | 30 | 0.002 (no match) | 5003.000 (timeout (> 5 s, killed)) | 0.006 (no match) | 0.008 (no match) | 0.005 (no match) |
| (a+)+b on a^n c | 40 | 0.002 (no match) | 5003.000 (timeout (> 5 s, killed)) | 0.007 (no match) | 0.007 (no match) | 0.006 (no match) |
| (a+)+b on a^n cb | 20 | 0.002 (no match) | 110.729 (no match) | 12.247 (no match) | 106.313 (no match) | 0.004 (no match) |
| (a+)+b on a^n cb | 25 | 0.002 (no match) | 3949.938 (no match, timeout (> 5 s, killed)) | 29.104 (match limit) | 188.791 (match limit) | 0.005 (no match) |
| (a+)+b on a^n cb | 30 | 0.002 (no match) | 5003.000 (timeout (> 5 s, killed)) | 29.370 (match limit) | 189.707 (match limit) | 0.005 (no match) |
| (a+)+b on a^n cb | 40 | 0.002 (no match) | 5003.000 (timeout (> 5 s, killed)) | 29.333 (match limit) | 192.569 (match limit) | 0.005 (no match) |
| (?=(a+)+b) on a^n c | 20 | 33.280 (StepLimitExceeded) | 109.076 (no match) | 0.005 (no match) | 0.006 (no match) | — |
| (?=(a+)+b) on a^n c | 25 | 33.046 (StepLimitExceeded) | 3860.017 (no match) | 0.006 (no match) | 0.007 (no match) | — |
| (?=(a+)+b) on a^n c | 30 | 32.982 (StepLimitExceeded) | 5007.000 (timeout (> 5 s, killed)) | 0.006 (no match) | 0.007 (no match) | — |
| (?=(a+)+b) on a^n c | 40 | 33.640 (StepLimitExceeded) | 5008.000 (timeout (> 5 s, killed)) | 0.006 (no match) | 0.006 (no match) | — |

z-regex runs `(a+)+b` on T0's DFA (linear; the tagged VM fills the group over the span).
V8 grows by ~36× every 5 `a`s. zoptia0regex is linear (4–6 µs). PCRE2 answers at once
because the required character `c` is absent (its start-up shortcut, as for `(a+)+b` on
`a^n c`).

### Against 0.8.0

z-regex 0.9.0 and z-regex 0.8.0, the previous publication, ran in the same 10 rounds of the
same harness, both built with `-Dcpu=x86_64_v3`. 0.8.0 is built from the tag `v0.8.0`
(`edde4e1`). 0.8.0 rejects `\p{RGI_Emoji}` (`UnsupportedFeature`), so that case is skipped
for the base (`XBENCH_BASE_SKIP=t1_v_rgi`, "—").

#### Best round; ratio > 1: better now

| Case | Tier | execAt MB/s now | 0.8.0 | ratio | findAll MB/s now | 0.8.0 | ratio | ns short now | 0.8.0 | ratio |
|---|---|---|---|---|---|---|---|---|---|---|
| literal hello | T0 | 13619.5 | 13588.1 | 1.00 | 11948.4 | 11910.9 | 1.00 | 26 | 26 | 1.01 |
| [a-z]+ | T0 | 191.8 | 191.8 | 1.00 | 51.1 | 51.5 | 0.99 | 20 | 20 | 1.00 |
| [a-z]+ (z-regex: generic VM, no fast path) | T0 | 43.3 | 45.1 | 0.96 | 25.8 | 26.9 | 0.96 | 111 | 102 | 0.91 |
| [a-z]+ (z-regex: backtracker) | T0 | 27.9 | 28.4 | 0.98 | 19.4 | 19.5 | 1.00 | 162 | 170 | 1.05 |
| \d{3}-\d{4} (sparse) | T0 | 896.0 | 695.8 | 1.29 | 654.3 | 499.4 | 1.31 | 27 | 29 | 1.09 |
| \d{3}-\d{4} (dense) | T0 | 538.1 | 465.7 | 1.16 | 244.4 | 223.8 | 1.09 | 27 | 30 | 1.09 |
| email | T0 | 737.9 | 711.7 | 1.04 | 532.8 | 476.8 | 1.12 | 72 | 76 | 1.06 |
| (\d{3})-(\d{4}) (sparse) | T0 | 334.5 | 301.1 | 1.11 | 282.0 | 238.9 | 1.18 | 374 | 379 | 1.01 |
| (\d{3})-(\d{4}) (dense) | T0 | 79.1 | 79.1 | 1.00 | 57.6 | 58.3 | 0.99 | 363 | 365 | 1.01 |
| (?:(a)\|b)*c | T0 | 22.1 | 21.4 | 1.03 | 17.8 | 17.9 | 0.99 | 477 | 486 | 1.02 |
| book: Darcy | T0 | 13457.8 | 13322.9 | 1.01 | 6497.9 | 6916.4 | 0.94 | 25 | 25 | 1.00 |
| book: [A-Z][a-z]+ | T0 | 596.7 | 545.2 | 1.09 | 348.2 | 317.9 | 1.10 | 56 | 64 | 1.13 |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) | T0 | 735.5 | 724.4 | 1.02 | 548.7 | 614.8 | 0.89 | 618 | 613 | 0.99 |
| \p{L}+ /u | T1 | 77.3 | 71.4 | 1.08 | 40.8 | 40.5 | 1.01 | 140 | 147 | 1.04 |
| \p{Script=Greek}+ /u | T1 | 161.3 | 156.6 | 1.03 | 123.8 | 119.3 | 1.04 | 114 | 123 | 1.08 |
| \p{General_Category=Lu} /u | T1 | 131.1 | 129.7 | 1.01 | 77.0 | 76.9 | 1.00 | 66 | 68 | 1.03 |
| [\p{L}--[a-z]] /v | T1 | 53.0 | 17.9 | 2.96 | 22.2 | 12.0 | 1.85 | 65 | 286 | 4.39 |
| book: \p{L}+ /u | T1 | 89.2 | 79.0 | 1.13 | 36.2 | 34.5 | 1.05 | 38 | 44 | 1.16 |
| \p{Script=Greek}{3,} /v | T1 | 166.3 | 26.0 | 6.39 | 124.2 | 24.5 | 5.07 | 110 | 479 | 4.35 |
| [\p{L}--[a-z]]{4} /v | T1 | 106.3 | 22.8 | 4.66 | 73.4 | 19.9 | 3.69 | 129 | 410 | 3.18 |
| \b\p{Lu}{5}\b /v | T1 | 167.1 | 20.9 | 7.98 | 165.0 | 20.7 | 7.98 | 51 | 417 | 8.26 |
| [\p{L}\p{N}_]+\u{1F600} /v | T1 | 166.6 | 6.1 | 27.13 | 165.7 | 5.5 | 30.09 | 68 | 772 | 11.34 |
| (\p{Lu})(\p{Ll}+)\.$ /v | T1 | 173.3 | 10.8 | 16.02 | 174.0 | 11.5 | 15.17 | 346 | 699 | 2.02 |
| \p{RGI_Emoji}+ /v | T1 | 0.6 | — | — | 0.6 | — | — | 15933 | — | — |
| <(\w+)>.*?<\/\1> | T2 | 26.3 | 27.8 | 0.94 | 22.4 | 22.8 | 0.98 | 453 | 429 | 0.95 |
| (?=.*[a-z])(?=.*[A-Z]).{8,} | T2 | 7.5 | 7.4 | 1.01 | 7.2 | 7.0 | 1.03 | 442 | 427 | 0.97 |
| (?<=\$)\d+ | T2 | 14.5 | 15.5 | 0.94 | 14.3 | 15.2 | 0.94 | 573 | 546 | 0.95 |
| book: \b(\w+) \1\b | T2 | 9.0 | 8.5 | 1.05 | 8.9 | 8.5 | 1.04 | 335 | 338 | 1.01 |

| Adversarial | n | now | 0.8.0 |
|---|---|---|---|
| (a+)+b on a^n c | 20 | 0.002 (no match) | 0.002 (no match) |
| (a+)+b on a^n c | 25 | 0.002 (no match) | 0.002 (no match) |
| (a+)+b on a^n c | 30 | 0.002 (no match) | 0.002 (no match) |
| (a+)+b on a^n c | 40 | 0.002 (no match) | 0.002 (no match) |
| (a+)+b on a^n cb | 20 | 0.002 (no match) | 0.002 (no match) |
| (a+)+b on a^n cb | 25 | 0.002 (no match) | 0.002 (no match) |
| (a+)+b on a^n cb | 30 | 0.002 (no match) | 0.002 (no match) |
| (a+)+b on a^n cb | 40 | 0.002 (no match) | 0.002 (no match) |
| (?=(a+)+b) on a^n c | 20 | 33.280 (StepLimitExceeded) | 32.856 (StepLimitExceeded) |
| (?=(a+)+b) on a^n c | 25 | 33.046 (StepLimitExceeded) | 33.680 (StepLimitExceeded) |
| (?=(a+)+b) on a^n c | 30 | 32.982 (StepLimitExceeded) | 34.333 (StepLimitExceeded) |
| (?=(a+)+b) on a^n c | 40 | 33.640 (StepLimitExceeded) | 34.378 (StepLimitExceeded) |

- **`v`, the reason for 0.9.0:** the six `v` patterns on the mixed corpus run on T0's DFA
  (one with the tagged VM for its groups), where 0.8.0 ran them on the backtracker:

  | Pattern | execAt MB/s 0.9.0 | 0.8.0 | Factor |
  |---|---|---|---|
  | `[\p{L}--[a-z]]` | 53.0 | 17.9 | 3.0× |
  | `\p{Script=Greek}{3,}` | 166.3 | 26.0 | 6.4× |
  | `[\p{L}--[a-z]]{4}` | 106.3 | 22.8 | 4.7× |
  | `\b\p{Lu}{5}\b` | 167.1 | 20.9 | 8.0× |
  | `[\p{L}\p{N}_]+\u{1F600}` | 166.6 | 6.1 | 27× |
  | `(\p{Lu})(\p{Ll}+)\.$` | 173.3 | 10.8 | 16× |

  - Short inputs: 51–129 ns against 286–772 (3.2–11×), and `(\p{Lu})(\p{Ll}+)\.$` goes from
    699 to 346 ns.
  - The release's own probe (the node bridge, 1 MB, the match at the end) measured 10× to 57×
    on the same kind of pattern.
- **`\p{RGI_Emoji}`:** new in 0.9.0. On `^\p{RGI_Emoji}+$` over the 3,953 strings
  concatenated (the release probe), 79.65 → 27.01 ms (2.9×), from 5.3× to 1.8× behind V8.
- **Compile:** 0.8.0 compiled the six `v` cases in 1–13 µs, as a backtracker program. 0.9.0
  builds T0's program and DFA in 8–269 µs, +7 to +268 µs per pattern in this run (the release
  run measured +6 to +169).
- **Other changes over 10%:**
  - Better: `\d{3}-\d{4}` sparse 1.29× execAt and dense 1.16×, `(\d{3})-(\d{4})` sparse
    1.11×, the book's `\p{L}+` 1.13× and short `[A-Z][a-z]+` 1.13×.
  - Worse: the title pattern's findAll 0.89×.

  None of these routes changed in 0.9.0, and every other metric of the same cases is within
  ±10%. By the regression criterion (the bench flags it and callgrind or a probe confirms
  it), a bench flag alone is this host's noise. They are not claimed as changes.
- **Within ±10%:** every other T0, `u` and T2 case, short inputs included, and the
  adversarial runs.

### Against zoptia0regex

[zoptia0regex](https://github.com/zoptia/zoptia0regex) is a port of Go's `regexp` to Zig 0.16:
RE2 syntax, leftmost-first, linear time (one-pass, Pike VM and bitstate engines, a SIMD
first-byte prefilter). It has no backreferences, lookaround or properties of strings, so it
doesn't run T2, `\p{RGI_Emoji}` or `(?=(a+)+b)`. It runs in the same rounds as every other
engine.

**Metrics.** zoptia0regex has no search from an index, so its "execAt" column is its
`matchesScratch` iterator: every match with its groups, a warm `Scratch`, no allocation.
That is what z-regex's `execAt` loop does. Its findAll is `findAllIndex` (allocating, bounds
only), and its short input is one `findIndexScratch`.

**Patterns.** Six cases are given to zoptia in RE2 syntax (`zoptia_pattern` in `cases.json`),
the same language:
- `\p{Greek}` for `\p{Script=Greek}`;
- `\p{Lu}` for `\p{General_Category=Lu}`;
- `[^\P{L}a-z]` for `[\p{L}--[a-z]]`;
- `\x{1F600}` for `\u{1F600}`.

The match counts are identical on all 21 cases.

#### Best round; ratio > 1: z-regex ahead

| Case | Tier | execAt MB/s z-regex | zoptia | ratio | findAll MB/s z-regex | zoptia | ratio | ns short z-regex | zoptia | ratio | µs compile z-regex | zoptia | ratio |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| literal hello | T0 | 13619.5 | 1345.3 | 10.12 | 11948.4 | 1350.2 | 8.85 | 26 | 19 | 0.73 | 1.71 | 1.01 | 0.59 |
| [a-z]+ | T0 | 191.8 | 17.5 | 10.96 | 51.1 | 16.4 | 3.13 | 20 | 127 | 6.42 | 1.66 | 0.72 | 0.44 |
| \d{3}-\d{4} (sparse) | T0 | 896.0 | 325.1 | 2.76 | 654.3 | 311.8 | 2.10 | 27 | 127 | 4.73 | 2.63 | 1.53 | 0.58 |
| \d{3}-\d{4} (dense) | T0 | 538.1 | 18.5 | 29.05 | 244.4 | 18.5 | 13.18 | 27 | 128 | 4.75 | 2.61 | 1.54 | 0.59 |
| email | T0 | 737.9 | 24.8 | 29.72 | 532.8 | 23.9 | 22.29 | 72 | 335 | 4.68 | 12.72 | 2.21 | 0.17 |
| (\d{3})-(\d{4}) (sparse) | T0 | 334.5 | 275.4 | 1.21 | 282.0 | 304.4 | 0.93 | 374 | 140 | 0.37 | 3.24 | 2.00 | 0.62 |
| (\d{3})-(\d{4}) (dense) | T0 | 79.1 | 14.8 | 5.33 | 57.6 | 17.7 | 3.25 | 363 | 142 | 0.39 | 3.26 | 2.01 | 0.62 |
| (?:(a)\|b)*c | T0 | 22.1 | 12.0 | 1.85 | 17.8 | 13.0 | 1.37 | 477 | 200 | 0.42 | 7.43 | 1.65 | 0.22 |
| book: Darcy | T0 | 13457.8 | 5697.6 | 2.36 | 6497.9 | 5379.4 | 1.21 | 25 | 19 | 0.73 | 1.72 | 1.01 | 0.59 |
| book: [A-Z][a-z]+ | T0 | 596.7 | 39.7 | 15.02 | 348.2 | 39.0 | 8.93 | 56 | 253 | 4.47 | 4.96 | 0.96 | 0.19 |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) | T0 | 735.5 | 677.8 | 1.09 | 548.7 | 771.6 | 0.71 | 618 | 194 | 0.31 | 24.88 | 3.99 | 0.16 |
| \p{L}+ /u | T1 | 77.3 | 24.2 | 3.19 | 40.8 | 22.8 | 1.79 | 140 | 223 | 1.59 | 42.14 | 8.63 | 0.20 |
| \p{Script=Greek}+ /u | T1 | 161.3 | 40.7 | 3.96 | 123.8 | 39.1 | 3.17 | 114 | 241 | 2.12 | 6.42 | 1.25 | 0.19 |
| \p{General_Category=Lu} /u | T1 | 131.1 | 35.8 | 3.66 | 77.0 | 34.4 | 2.24 | 66 | 135 | 2.06 | 40.69 | 12.79 | 0.31 |
| [\p{L}--[a-z]] /v | T1 | 53.0 | 17.8 | 2.98 | 22.2 | 16.2 | 1.37 | 65 | 140 | 2.15 | 46.63 | 25.16 | 0.54 |
| book: \p{L}+ /u | T1 | 89.2 | 19.4 | 4.59 | 36.2 | 16.9 | 2.14 | 38 | 115 | 3.05 | 42.09 | 8.65 | 0.21 |
| \p{Script=Greek}{3,} /v | T1 | 166.3 | 37.5 | 4.43 | 124.2 | 37.5 | 3.31 | 110 | 254 | 2.31 | 8.40 | 1.54 | 0.18 |
| [\p{L}--[a-z]]{4} /v | T1 | 106.3 | 25.6 | 4.15 | 73.4 | 24.7 | 2.97 | 129 | 212 | 1.64 | 152.02 | 18.38 | 0.12 |
| \b\p{Lu}{5}\b /v | T1 | 167.1 | 54.3 | 3.08 | 165.0 | 53.6 | 3.08 | 51 | 235 | 4.66 | 268.96 | 6.47 | 0.02 |
| [\p{L}\p{N}_]+\u{1F600} /v | T1 | 166.6 | 28.6 | 5.83 | 165.7 | 28.8 | 5.76 | 68 | 250 | 3.67 | 71.52 | 22.30 | 0.31 |
| (\p{Lu})(\p{Ll}+)\.$ /v | T1 | 173.3 | 29.2 | 5.93 | 174.0 | 33.9 | 5.13 | 346 | 222 | 0.64 | 132.30 | 19.27 | 0.15 |

- **Throughput:**
  - z-regex is ahead on every case with execAt: 10–30× where it runs the DFA or a fast path
    (the e-mail 30×, `\d{3}-\d{4}` dense 29×, the book's `[A-Z][a-z]+` 15×, `[a-z]+` and the
    literal `hello` 10–11×) and zoptia runs its Pike VM, and 3.0–5.9× on T1.
  - It is even on the book's title pattern (1.09) and 1.21× ahead on `(\d{3})-(\d{4})`
    sparse.
  - On those two, zoptia's findAll is ahead (0.71 and 0.93): it collects only the bounds.
- **Short inputs:**
  - zoptia is ahead with groups, 1.56–3.2× (`(\d{3})-(\d{4})` 140 ns against 374, the title
    pattern 194 against 618): the tagged VM's fixed cost per search, as against V8;
  - it is also ahead on the literals (19 ns against 25–26);
  - z-regex is ahead on the other 14 cases, 1.6–6.4×.
- **Compile time:** zoptia is faster on every case, 1.6–42×. The widest gap is
  `\b\p{Lu}{5}\b /v`, 269 µs against 6.5: z-regex builds its DFA at compile time.
- **Bytes per compiled pattern** (the tables above):
  - T0: zoptia uses 872–6,866 B where z-regex uses 135–3,284.
  - T1: zoptia uses ~15.8 KB for most cases where z-regex uses 22–32 KB.
  - Exceptions: `\p{Script=Greek}{3,}` (5,036 B against 2,223) and `(\p{Lu})(\p{Ll}+)\.$`
    (42,220 against 30,608).
- **Adversarial:** `(a+)+b` is linear on both: 2 µs for z-regex, 4–6 µs for zoptia, at any n.

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
- Match counts are identical across every engine, z-regex 0.8.0 and zoptia0regex included, on every case
  (0.8.0 doesn't run `\p{RGI_Emoji}+`).
- Everything here is one machine, a shared container: compare engines within a table, not
  numbers across machines.
