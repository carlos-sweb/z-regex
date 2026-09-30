# Benchmarks: z-regex against V8, Rust regex, PCRE2 and zig-regex

What this measures: z-regex 0.7.0 (the end of F7c; measured on commit `e242987`, whose
code is 0.7.0's) against the engines people would use instead, **tier by tier**
(docs/REGEX_TIERS_PLAN.md): a T0 case is compared only with engines that run it as a regular
expression, a T2 case (backreferences, lookaround) only with backtracking engines that
support it. Tiers are never mixed in one table. z-regex 0.3.2, the version of the previous
publication, runs in the same rounds as a base (see "Against 0.3.2").

## Setup

| | |
|---|---|
| Machine | Intel(R) Xeon(R) Processor @ 2.80GHz, 4 cores (no SMT), KVM guest, 15Gi RAM, Linux 6.18.44-fc-v50 |
| Environment | **shared container**: a case moves by ±20% from one process to the next; read the band, not only the best round |
| z-regex | 0.7.0 (commit `e242987`: the same code, before the version bump), and 0.3.2 as the base. Zig 0.16.0, ReleaseFast, **`-Dcpu=x86_64_v3`** (AVX2, no AVX-512), the CPU model of `scripts/measure_binary.sh` |
| V8 | 12.4.254.21-node.39 (Node v22.22.2) |
| Rust regex | 1.13.1 (rustc 1.94.1 (e408947bf 2026-03-25)), release, LTO |
| PCRE2 | 10.42, 8-bit library, JIT and interpreter |
| zig-regex | 0.1.1 (zig-utils/zig-regex, 173b298), the last release that builds with Zig 0.16 (v0.2.x needs 0.17-dev); built `native` by `setup_zigregex.sh` |

**Not comparable with the previous publication's numbers.** Those (0.3.0, literals on
0.3.1) were measured on another host (a Xeon at 2.10 GHz) with a `native` build (AVX-512).
What changed in z-regex since then is measured here against 0.3.2 in the same rounds, same
machine and same CPU model: see "Against 0.3.2".

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
  (`bench/compare/gen_corpus.mjs`; seeds 1–10, one per input: prose, prose with rare
  "hello", sparse phone numbers, dense digits, e-mails, `a`/`b` runs, mixed-script Unicode,
  HTML, prices, password-like lines). Byte-identical on every run and machine.
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
| literal hello <sub>(z-regex: VM)</sub> | 12479.3 (7152.2–12479.3) | 1793.9 (1369.8–1793.9) | 1505.2 (1002.8–1505.2) | 19530.5 (12528.8–19530.5) | — |
| [a-z]+ <sub>(z-regex: VM)</sub> | 53.1 (42.1–53.1) | 73.5 (50.5–73.5) | 51.4 (44.9–51.4) | 55.6 (31.2–55.6) | — |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 25.7 (22.7–25.7) | n/a | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 20.2 (15.5–20.2) | n/a | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 373.8 (221.5–373.8) | 1177.7 (867.6–1177.7) | 371.1 (267.1–371.1) | 1728.0 (1027.5–1728.0) | — |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 29.2 (25.7–29.2) | 165.7 (146.2–165.7) | 96.1 (60.8–96.1) | 81.6 (72.1–81.6) | — |
| email <sub>(z-regex: VM)</sub> | 34.9 (19.7–34.9) | 79.3 (70.0–79.3) | 66.6 (40.7–66.6) | 687.7 (450.9–687.7) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 210.2 (195.3–210.2) | 955.3 (534.1–955.3) | 357.7 (205.6–357.7) | 833.8 (569.4–833.8) | — |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 22.0 (19.1–22.0) | 126.1 (89.8–126.1) | 91.9 (69.9–91.9) | 60.0 (55.1–60.0) | — |
| (?:(a)\|b)*c <sub>(z-regex: tagged VM)</sub> | 12.0 (10.1–12.0) | 29.1 (23.8–29.1) | 24.8 (19.4–24.8) | 39.0 (35.5–39.0) | — |
| book: Darcy <sub>(z-regex: VM)</sub> | 6964.1 (4306.9–6964.1) | 8379.8 (4805.2–8379.8) | 2534.8 (1508.8–2534.8) | 17967.9 (16669.9–17967.9) | — |
| book: [A-Z][a-z]+ <sub>(z-regex: VM)</sub> | 222.8 (164.4–222.8) | 478.1 (258.5–478.1) | 139.4 (111.6–139.4) | 292.3 (273.0–292.3) | — |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: tagged VM)</sub> | 459.8 (275.4–459.8) | 455.7 (327.6–455.7) | 348.0 (178.1–348.0) | 1641.4 (1480.7–1641.4) | — |

#### T0: execAt MB/s (engine loop, no per-match allocation where the API allows)

| Case | z-regex | V8 (warm) | Rust regex | zig-regex |
|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 13668.9 (11496.0–13668.9) | 1809.3 (1421.3–1809.3) | 19916.7 (12089.3–19916.7) | — |
| [a-z]+ <sub>(z-regex: VM)</sub> | 195.3 (100.0–195.3) | 77.9 (65.4–77.9) | 59.0 (35.4–59.0) | — |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 40.2 (22.8–40.2) | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 29.5 (28.1–29.5) | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 473.4 (411.1–473.4) | 909.5 (847.9–909.5) | 1819.2 (1110.2–1819.2) | — |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 34.0 (26.5–34.0) | 172.8 (155.4–172.8) | 84.3 (56.1–84.3) | — |
| email <sub>(z-regex: VM)</sub> | 36.2 (25.3–36.2) | 79.4 (48.0–79.4) | 705.0 (544.5–705.0) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 244.3 (211.7–244.3) | 1002.5 (341.0–1002.5) | 1155.5 (972.4–1155.5) | — |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 24.8 (19.1–24.8) | 143.7 (98.5–143.7) | 71.5 (49.8–71.5) | — |
| (?:(a)\|b)*c <sub>(z-regex: tagged VM)</sub> | 13.6 (12.5–13.6) | 29.5 (28.0–29.5) | 51.3 (38.1–51.3) | — |
| book: Darcy <sub>(z-regex: VM)</sub> | 13284.0 (8603.8–13284.0) | 8759.7 (4906.5–8759.7) | 19276.8 (17366.1–19276.8) | — |
| book: [A-Z][a-z]+ <sub>(z-regex: VM)</sub> | 322.4 (255.5–322.4) | 506.5 (283.1–506.5) | 301.0 (287.0–301.0) | — |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: tagged VM)</sub> | 527.7 (314.4–527.7) | 460.8 (353.1–460.8) | 2116.5 (1725.2–2116.5) | — |

#### T0: z-regex iterator MB/s (Regex.iterator: every match, warm Scratch, no allocation)

| Case | z-regex |
|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 13682.9 (12573.1–13682.9) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 192.3 (100.7–192.3) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 40.2 (32.5–40.2) |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 29.6 (24.9–29.6) |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 473.7 (422.4–473.7) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 33.6 (29.4–33.6) |
| email <sub>(z-regex: VM)</sub> | 36.0 (30.4–36.0) |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 244.5 (201.2–244.5) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 24.4 (21.5–24.4) |
| (?:(a)\|b)*c <sub>(z-regex: tagged VM)</sub> | 13.3 (12.1–13.3) |
| book: Darcy <sub>(z-regex: VM)</sub> | 13197.7 (8405.2–13197.7) |
| book: [A-Z][a-z]+ <sub>(z-regex: VM)</sub> | 321.6 (203.7–321.6) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: tagged VM)</sub> | 525.2 (316.0–525.2) |

#### T0: ns per exec on a short input (< 64 B)

| Case | z-regex | V8 (warm) | Rust regex | zig-regex |
|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 28 (28–30) | 67 (67–107) | 22 (22–38) | 417 (417–597) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 19 (19–35) | 65 (65–83) | 83 (83–101) | 602 (602–672) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 121 (121–156) | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 162 (162–303) | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 284 (284–338) | 86 (86–95) | 76 (76–81) | 1501 (1501–1874) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 284 (284–322) | 84 (84–100) | 75 (75–125) | 1453 (1453–1829) |
| email <sub>(z-regex: VM)</sub> | 482 (482–547) | 137 (137–154) | 86 (86–93) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 618 (618–671) | 114 (114–151) | 137 (137–147) | 3526 (3526–3715) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 621 (621–652) | 116 (116–153) | 137 (137–143) | 3470 (3470–4044) |
| (?:(a)\|b)*c <sub>(z-regex: tagged VM)</sub> | 566 (566–618) | 77 (77–97) | 141 (141–145) | 3401 (3401–4046) |
| book: Darcy <sub>(z-regex: VM)</sub> | 28 (28–29) | 71 (71–82) | 21 (21–22) | 405 (405–470) |
| book: [A-Z][a-z]+ <sub>(z-regex: VM)</sub> | 182 (182–259) | 80 (80–103) | 86 (86–89) | 1788 (1788–1958) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: tagged VM)</sub> | 856 (856–952) | 110 (110–124) | 173 (173–179) | 8653 (8653–9528) |

#### T0: µs per compile

| Case | z-regex | Rust regex | zig-regex |
|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 1.53 (1.53–1.58) | 2.66 (2.66–5.13) | 0.96 (0.96–1.86) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 1.28 (1.28–1.65) | 8.37 (8.37–15.06) | 0.63 (0.63–0.93) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 1.25 (1.25–2.08) | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 0.83 (0.83–1.01) | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 2.12 (2.12–3.59) | 194.45 (194.45–328.74) | 1.26 (1.26–2.86) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 2.09 (2.09–2.47) | 191.81 (191.81–199.77) | 1.30 (1.30–2.28) |
| email <sub>(z-regex: VM)</sub> | 4.42 (4.42–5.54) | 21.41 (21.41–24.95) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 2.77 (2.77–2.80) | 197.84 (197.84–244.50) | 1.65 (1.65–1.98) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 2.76 (2.76–2.97) | 197.25 (197.25–225.96) | 1.67 (1.67–3.90) |
| (?:(a)\|b)*c <sub>(z-regex: tagged VM)</sub> | 2.95 (2.95–3.02) | 13.07 (13.07–16.95) | 1.16 (1.16–2.08) |
| book: Darcy <sub>(z-regex: VM)</sub> | 1.52 (1.52–2.43) | 2.60 (2.60–2.95) | 0.97 (0.97–1.78) |
| book: [A-Z][a-z]+ <sub>(z-regex: VM)</sub> | 1.84 (1.84–1.87) | 10.13 (10.13–11.17) | 0.86 (0.86–1.47) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: tagged VM)</sub> | 6.04 (6.04–9.90) | 29.50 (29.50–31.34) | 3.32 (3.32–3.95) |

#### T0: bytes per compiled pattern

| Case | z-regex | zig-regex |
|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 185 (185–185) | 2322 (2322–2322) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 187 (187–187) | 1016 (1016–1016) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 187 (187–187) | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 19 (19–19) | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 325 (325–325) | 3817 (3817–3817) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 325 (325–325) | 3817 (3817–3817) |
| email <sub>(z-regex: VM)</sub> | 745 (745–745) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 433 (433–433) | 5365 (5365–5365) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 433 (433–433) | 5365 (5365–5365) |
| (?:(a)\|b)*c <sub>(z-regex: tagged VM)</sub> | 357 (357–357) | 3227 (3227–3227) |
| book: Darcy <sub>(z-regex: VM)</sub> | 185 (185–185) | 2322 (2322–2322) |
| book: [A-Z][a-z]+ <sub>(z-regex: VM)</sub> | 260 (260–260) | 1751 (1751–1751) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: tagged VM)</sub> | 880 (880–880) | 9370 (9370–9370) |

#### T1: findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)

| Case | z-regex | V8 (warm) | V8 (cold) | Rust regex |
|---|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: VM)</sub> | 27.0 (24.3–27.0) | 36.9 (35.2–36.9) | 30.7 (18.8–30.7) | 63.1 (55.0–63.1) |
| \p{Script=Greek}+ /u <sub>(z-regex: VM)</sub> | 48.7 (39.1–48.7) | 96.0 (81.4–96.0) | 65.6 (54.6–65.6) | 220.9 (205.4–220.9) |
| \p{General_Category=Lu} /u <sub>(z-regex: VM)</sub> | 36.8 (30.6–36.8) | 51.4 (46.8–51.4) | 40.0 (24.9–40.0) | 172.1 (163.8–172.1) |
| [\p{L}--[a-z]] /v <sub>(z-regex: backtracker)</sub> | 12.4 (9.1–12.4) | 25.9 (23.1–25.9) | 21.9 (12.3–21.9) | n/a |
| book: \p{L}+ /u <sub>(z-regex: VM)</sub> | 23.2 (18.3–23.2) | 25.5 (22.5–25.5) | 20.5 (12.9–20.5) | 50.6 (30.9–50.6) |

#### T1: execAt MB/s (engine loop, no per-match allocation where the API allows)

| Case | z-regex | V8 (warm) | Rust regex |
|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: VM)</sub> | 40.3 (31.5–40.3) | 38.0 (34.4–38.0) | 67.6 (62.7–67.6) |
| \p{Script=Greek}+ /u <sub>(z-regex: VM)</sub> | 55.6 (48.8–55.6) | 94.2 (82.3–94.2) | 228.9 (216.1–228.9) |
| \p{General_Category=Lu} /u <sub>(z-regex: VM)</sub> | 47.7 (25.9–47.7) | 53.2 (43.9–53.2) | 186.8 (175.2–186.8) |
| [\p{L}--[a-z]] /v <sub>(z-regex: backtracker)</sub> | 20.1 (18.6–20.1) | 27.1 (22.6–27.1) | n/a |
| book: \p{L}+ /u <sub>(z-regex: VM)</sub> | 38.8 (34.5–38.8) | 26.2 (22.5–26.2) | 53.1 (49.9–53.1) |

#### T1: z-regex iterator MB/s (Regex.iterator: every match, warm Scratch, no allocation)

| Case | z-regex |
|---|---|
| \p{L}+ /u <sub>(z-regex: VM)</sub> | 40.3 (36.1–40.3) |
| \p{Script=Greek}+ /u <sub>(z-regex: VM)</sub> | 55.7 (35.6–55.7) |
| \p{General_Category=Lu} /u <sub>(z-regex: VM)</sub> | 47.9 (40.4–47.9) |
| [\p{L}--[a-z]] /v <sub>(z-regex: backtracker)</sub> | 20.1 (16.9–20.1) |
| book: \p{L}+ /u <sub>(z-regex: VM)</sub> | 38.7 (22.8–38.7) |

#### T1: ns per exec on a short input (< 64 B)

| Case | z-regex | V8 (warm) | Rust regex |
|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: VM)</sub> | 255 (255–281) | 176 (176–188) | 112 (112–123) |
| \p{Script=Greek}+ /u <sub>(z-regex: VM)</sub> | 273 (273–291) | 176 (176–195) | 114 (114–120) |
| \p{General_Category=Lu} /u <sub>(z-regex: VM)</sub> | 141 (141–175) | 155 (155–168) | 54 (54–63) |
| [\p{L}--[a-z]] /v <sub>(z-regex: backtracker)</sub> | 276 (276–328) | 188 (188–221) | n/a |
| book: \p{L}+ /u <sub>(z-regex: VM)</sub> | 95 (95–106) | 73 (73–81) | 74 (74–84) |

#### T1: µs per compile

| Case | z-regex | Rust regex |
|---|---|---|
| \p{L}+ /u <sub>(z-regex: VM)</sub> | 7.02 (7.02–10.53) | 321.39 (321.39–347.46) |
| \p{Script=Greek}+ /u <sub>(z-regex: VM)</sub> | 1.22 (1.22–1.75) | 55.63 (55.63–60.30) |
| \p{General_Category=Lu} /u <sub>(z-regex: VM)</sub> | 0.99 (0.99–1.94) | 191.42 (191.42–209.48) |
| [\p{L}--[a-z]] /v <sub>(z-regex: backtracker)</sub> | 5.26 (5.26–5.34) | n/a |
| book: \p{L}+ /u <sub>(z-regex: VM)</sub> | 1.24 (1.24–1.83) | 323.04 (323.04–483.11) |

#### T1: bytes per compiled pattern

| Case | z-regex |
|---|---|
| \p{L}+ /u <sub>(z-regex: VM)</sub> | 5644 (5644–5644) |
| \p{Script=Greek}+ /u <sub>(z-regex: VM)</sub> | 460 (460–460) |
| \p{General_Category=Lu} /u <sub>(z-regex: VM)</sub> | 5323 (5323–5323) |
| [\p{L}--[a-z]] /v <sub>(z-regex: backtracker)</sub> | 5486 (5486–5486) |
| book: \p{L}+ /u <sub>(z-regex: VM)</sub> | 5644 (5644–5644) |

#### T2: findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)

| Case | z-regex | V8 (warm) | V8 (cold) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 24.5 (22.8–24.5) | 166.6 (140.2–166.6) | 88.6 (45.5–88.6) | 192.6 (120.6–192.6) | 63.0 (37.3–63.0) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 7.2 (6.4–7.2) | 41.2 (35.6–41.2) | 32.9 (23.3–32.9) | 56.5 (42.0–56.5) | 9.0 (7.5–9.0) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 14.3 (11.8–14.3) | 195.8 (90.8–195.8) | 116.3 (104.4–116.3) | 833.8 (452.9–833.8) | 427.8 (224.8–427.8) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 8.8 (7.7–8.8) | 123.2 (93.7–123.2) | 117.3 (86.1–117.3) | 87.5 (54.6–87.5) | 21.5 (17.7–21.5) |

#### T2: execAt MB/s (engine loop, no per-match allocation where the API allows)

| Case | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 28.5 (22.4–28.5) | 176.6 (147.4–176.6) | 207.9 (121.6–207.9) | 65.4 (54.1–65.4) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 7.5 (6.5–7.5) | 42.0 (32.7–42.0) | 57.6 (39.6–57.6) | 9.1 (7.2–9.1) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 15.1 (9.8–15.1) | 200.5 (92.5–200.5) | 872.8 (478.4–872.8) | 440.3 (245.3–440.3) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 8.9 (7.7–8.9) | 123.6 (93.9–123.6) | 88.7 (54.6–88.7) | 21.6 (18.7–21.6) |

#### T2: z-regex iterator MB/s (Regex.iterator: every match, warm Scratch, no allocation)

| Case | z-regex |
|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 28.3 (26.7–28.3) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 7.5 (6.6–7.5) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 15.1 (12.3–15.1) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 8.9 (7.9–8.9) |

#### T2: ns per exec on a short input (< 64 B)

| Case | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 426 (426–469) | 80 (80–89) | 58 (58–92) | 189 (189–215) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 402 (402–504) | 129 (129–146) | 76 (76–109) | 351 (351–411) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 564 (564–614) | 96 (96–143) | 44 (44–78) | 109 (109–214) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 335 (335–360) | 95 (95–108) | 57 (57–76) | 127 (127–133) |

#### T2: µs per compile

| Case | z-regex | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 2.89 (2.89–2.93) | 7.78 (7.78–19.99) | 0.79 (0.79–1.47) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 4.10 (4.10–4.66) | 6.53 (6.53–12.91) | 1.01 (1.01–1.43) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 1.66 (1.66–2.02) | 4.34 (4.34–8.78) | 0.52 (0.52–0.98) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 1.98 (1.98–2.94) | 7.28 (7.28–14.93) | 0.67 (0.67–1.25) |

#### T2: bytes per compiled pattern

| Case | z-regex | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 92 (92–92) | 1287 (1287–1287) | 168 (168–168) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 1788 (1788–1788) | 963 (963–963) | 231 (231–231) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 698 (698–698) | 687 (687–687) | 156 (156–156) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 59 (59–59) | 1226 (1226–1226) | 160 (160–160) |

#### Adversarial: ms until the engine answers or gives up (best round; outcome)

| Case | n | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|---|
| (a+)+b on a^n c | 20 | 0.003 (no match) | 107.816 (no match) | 0.006 (no match) | 0.006 (no match) |
| (a+)+b on a^n c | 25 | 0.003 (no match) | 3642.182 (no match) | 0.005 (no match) | 0.006 (no match) |
| (a+)+b on a^n c | 30 | 0.004 (no match) | 5004.000 (timeout (> 5 s, killed)) | 0.006 (no match) | 0.006 (no match) |
| (a+)+b on a^n c | 40 | 0.004 (no match) | 5003.000 (timeout (> 5 s, killed)) | 0.005 (no match) | 0.006 (no match) |
| (a+)+b on a^n cb | 20 | 0.003 (no match) | 110.650 (no match) | 12.296 (no match) | 101.084 (no match) |
| (a+)+b on a^n cb | 25 | 0.003 (no match) | 3614.159 (no match) | 29.482 (match limit) | 193.418 (match limit) |
| (a+)+b on a^n cb | 30 | 0.004 (no match) | 5003.000 (timeout (> 5 s, killed)) | 28.984 (match limit) | 189.699 (match limit) |
| (a+)+b on a^n cb | 40 | 0.004 (no match) | 5003.000 (timeout (> 5 s, killed)) | 29.111 (match limit) | 191.562 (match limit) |
| (?=(a+)+b) on a^n c | 20 | 31.530 (StepLimitExceeded) | 109.244 (no match) | 0.005 (no match) | 0.006 (no match) |
| (?=(a+)+b) on a^n c | 25 | 32.366 (StepLimitExceeded) | 3590.587 (no match) | 0.006 (no match) | 0.007 (no match) |
| (?=(a+)+b) on a^n c | 30 | 31.592 (StepLimitExceeded) | 5007.000 (timeout (> 5 s, killed)) | 0.006 (no match) | 0.006 (no match) |
| (?=(a+)+b) on a^n c | 40 | 31.672 (StepLimitExceeded) | 5006.000 (timeout (> 5 s, killed)) | 0.006 (no match) | 0.006 (no match) |

Match counts: identical across every engine that runs a case.

**`(a|aa)*c` on `a^n b`** (a separate run: 10 processes per engine and n, best; not in
`cases.json`, so the published case set stays the one of 0.3.0):

| n | z-regex | z-regex 0.3.2 | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|---|
| 20 | 0.003 (no match) | 0.003 (no match) | 2.774 (no match) | 0.006 (no match) | 0.007 (no match) |
| 25 | 0.003 (no match) | 0.003 (no match) | 30.718 (no match) | 0.007 (no match) | 0.006 (no match) |
| 30 | 0.003 (no match) | 0.004 (no match) | 338.865 (no match) | 0.006 (no match) | 0.006 (no match) |
| 40 | 0.003 (no match) | 0.004 (no match) | > 6000 (killed) | 0.006 (no match) | 0.006 (no match) |

z-regex runs it on T0's VM (linear). V8 grows by ~11× every 5 `a`s. PCRE2 answers at once
because the required character `c` is absent (its start-up shortcut, as for `(a+)+b` on
`a^n c`).

### Against 0.3.2

z-regex 0.7.0 and z-regex 0.3.2 in the same 10 rounds (the same harness: `bench/compare/` is
unchanged since 0.3.2), both built with `-Dcpu=x86_64_v3`.

#### Best round; ratio > 1: better now

| Case | Tier | execAt MB/s now | 0.3.2 | ratio | findAll MB/s now | 0.3.2 | ratio | ns short now | 0.3.2 | ratio |
|---|---|---|---|---|---|---|---|---|---|---|
| literal hello | T0 | 13668.9 | 13546.5 | 1.01 | 12479.3 | 12163.2 | 1.03 | 28 | 26 | 0.92 |
| [a-z]+ | T0 | 195.3 | 196.6 | 0.99 | 53.1 | 55.0 | 0.97 | 19 | 19 | 1.01 |
| [a-z]+ (z-regex: generic VM, no fast path) | T0 | 40.2 | 39.5 | 1.02 | 25.7 | 25.2 | 1.02 | 121 | 121 | 1.00 |
| [a-z]+ (z-regex: backtracker) | T0 | 29.5 | 31.4 | 0.94 | 20.2 | 20.6 | 0.98 | 162 | 145 | 0.90 |
| \d{3}-\d{4} (sparse) | T0 | 473.4 | 412.6 | 1.15 | 373.8 | 334.1 | 1.12 | 284 | 336 | 1.18 |
| \d{3}-\d{4} (dense) | T0 | 34.0 | 29.6 | 1.15 | 29.2 | 27.2 | 1.07 | 284 | 323 | 1.14 |
| email | T0 | 36.2 | 33.2 | 1.09 | 34.9 | 32.1 | 1.09 | 482 | 539 | 1.12 |
| (\d{3})-(\d{4}) (sparse) | T0 | 244.3 | 239.6 | 1.02 | 210.2 | 204.0 | 1.03 | 618 | 692 | 1.12 |
| (\d{3})-(\d{4}) (dense) | T0 | 24.8 | 23.4 | 1.06 | 22.0 | 21.3 | 1.03 | 621 | 681 | 1.10 |
| (?:(a)\|b)*c | T0 | 13.6 | 12.6 | 1.07 | 12.0 | 11.9 | 1.01 | 566 | 630 | 1.11 |
| book: Darcy | T0 | 13284.0 | 13348.6 | 1.00 | 6964.1 | 6714.2 | 1.04 | 28 | 26 | 0.93 |
| book: [A-Z][a-z]+ | T0 | 322.4 | 320.6 | 1.01 | 222.8 | 223.1 | 1.00 | 182 | 193 | 1.06 |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) | T0 | 527.7 | 507.4 | 1.04 | 459.8 | 446.6 | 1.03 | 856 | 872 | 1.02 |
| \p{L}+ /u | T1 | 40.3 | 24.7 | 1.63 | 27.0 | 18.8 | 1.44 | 255 | 332 | 1.30 |
| \p{Script=Greek}+ /u | T1 | 55.6 | 26.0 | 2.14 | 48.7 | 24.4 | 2.00 | 273 | 420 | 1.54 |
| \p{General_Category=Lu} /u | T1 | 47.7 | 21.8 | 2.19 | 36.8 | 19.1 | 1.93 | 141 | 274 | 1.94 |
| [\p{L}--[a-z]] /v | T1 | 20.1 | 21.7 | 0.92 | 12.4 | 13.2 | 0.94 | 276 | 272 | 0.99 |
| book: \p{L}+ /u | T1 | 38.8 | 19.4 | 2.00 | 23.2 | 14.4 | 1.61 | 95 | 197 | 2.07 |
| <(\w+)>.*?<\/\1> | T2 | 28.5 | 30.4 | 0.94 | 24.5 | 26.4 | 0.93 | 426 | 434 | 1.02 |
| (?=.*[a-z])(?=.*[A-Z]).{8,} | T2 | 7.5 | 3.2 | 2.37 | 7.2 | 3.1 | 2.30 | 402 | 1080 | 2.68 |
| (?<=\$)\d+ | T2 | 15.1 | 0.6 | 24.34 | 14.3 | 0.6 | 23.14 | 564 | 846 | 1.50 |
| book: \b(\w+) \1\b | T2 | 8.9 | 9.0 | 0.99 | 8.8 | 9.1 | 0.97 | 335 | 340 | 1.02 |

| Adversarial | n | now | 0.3.2 |
|---|---|---|---|
| (a+)+b on a^n c | 20 | 0.003 (no match) | 0.004 (no match) |
| (a+)+b on a^n c | 25 | 0.003 (no match) | 0.004 (no match) |
| (a+)+b on a^n c | 30 | 0.004 (no match) | 0.004 (no match) |
| (a+)+b on a^n c | 40 | 0.004 (no match) | 0.004 (no match) |
| (a+)+b on a^n cb | 20 | 0.003 (no match) | 0.003 (no match) |
| (a+)+b on a^n cb | 25 | 0.003 (no match) | 0.003 (no match) |
| (a+)+b on a^n cb | 30 | 0.004 (no match) | 0.003 (no match) |
| (a+)+b on a^n cb | 40 | 0.004 (no match) | 0.004 (no match) |
| (?=(a+)+b) on a^n c | 20 | 31.530 (StepLimitExceeded) | 33.451 (StepLimitExceeded) |
| (?=(a+)+b) on a^n c | 25 | 32.366 (StepLimitExceeded) | 33.359 (StepLimitExceeded) |
| (?=(a+)+b) on a^n c | 30 | 31.592 (StepLimitExceeded) | 32.908 (StepLimitExceeded) |
| (?=(a+)+b) on a^n c | 40 | 31.672 (StepLimitExceeded) | 32.988 (StepLimitExceeded) |

- **Better:** T1 (F5a: `u` and `\p{…}` moved from the backtracker to T0's VM) 1.4–2.2×; the
  lookbehind `(?<=\$)\d+` ~24× (F6b: matched backward instead of trying up to 100 lengths
  at every position); the double lookahead 2.4× (F6a: LookLinear); `\d{3}-\d{4}` 1.15×.
- **Within ±10%:** every other case, T0 included.
- **Worse by more than 10%:** one cell, a z-regex-only variant: `[a-z]+` forced onto the
  backtracker, ns per short exec, 162 against 145 (+12%). Its execAt is 0.94×. Under F7b's
  criterion a bench flag needs callgrind to confirm it; not investigated here.
- `[\p{L}--[a-z]] /v` (0.92×) still runs on the backtracker: `v` isn't routed to the VM.

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
1.0–3.6× findAll (the most where matches are many: `[a-z]+` 192 against 53 MB/s).

Where findAll's time goes (a separate probe on 0.3.1, on the previous host, µs per call, `smp_allocator` as in the bench):
findAll allocates one `captures` slice per match and grows its list of 72-byte `MatchResult`s.
On Darcy (417 matches) that's 426 allocations and 8 page faults per call; on `[a-z]+` (158,795
matches), 158,804 allocations and ~2,800 page faults. About 43% of findAll's time on Darcy and
63% on `[a-z]+` is outside the search. Most of it is fresh memory (the large list goes back to
the OS on free, so every call faults its pages in again): run over reused memory, findAll on
Darcy drops from ~79 to ~55 µs (execAt: ~44). The rest, ~25–30 ns per match, is building and
freeing the results. Putting every `captures` slice in one block (an arena) measured no faster.
In the `literal hello` row the findAll/execAt gap (1.2–1.3× in these tables) is mostly noise:
a pass takes ~60 µs and each timed sample is one pass; timed over ≥ 150 ms per sample the gap
is ~1.05×.

## Analysis

Reference: V8 warm and Rust regex, `execAt` column, best round; "×" is a ratio of best
rounds. Even: within ±10%.

**T0 (z-regex: T0's VMs and their fast paths)**

| Case | vs V8 | vs Rust regex |
|---|---|---|
| literal `hello` | **7.6× ahead** | 1.45× behind |
| `[a-z]+` | **2.5× ahead** | **3.3× ahead** |
| `\d{3}-\d{4}` sparse | 1.9× behind | 3.8× behind |
| `\d{3}-\d{4}` dense | 5.1× behind | 2.5× behind |
| e-mail | 2.2× behind | 19× behind |
| `(\d{3})-(\d{4})` sparse | 4.1× behind | 4.7× behind |
| `(\d{3})-(\d{4})` dense | 5.8× behind | 2.9× behind |
| `(?:(a)\|b)*c` | 2.2× behind | 3.8× behind |
| book: `Darcy` | **1.5× ahead** | 1.45× behind |
| book: `[A-Z][a-z]+` | 1.6× behind | even (1.07×) |
| book: `(Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+)` | **1.15× ahead** | 4.0× behind |

**T1 (`u`/`v`: T0's VM in code-point mode; `v` on the backtracker)**

| Case | vs V8 | vs Rust regex |
|---|---|---|
| `\p{L}+ /u` | even (1.06×) | 1.7× behind |
| `\p{Script=Greek}+ /u` | 1.7× behind | 4.1× behind |
| `\p{General_Category=Lu} /u` | even (0.90×) | 3.9× behind |
| `[\p{L}--[a-z]] /v` | 1.35× behind | n/a |
| book: `\p{L}+ /u` | **1.5× ahead** | 1.4× behind |

**T2 (the explicit-stack backtracker; Rust regex has no backreferences or lookaround)**

| Case | vs V8 | vs PCRE2 JIT | vs PCRE2 interp. |
|---|---|---|---|
| `<(\w+)>.*?<\/\1>` | 6.2× behind | 7.3× behind | 2.3× behind |
| `(?=.*[a-z])(?=.*[A-Z]).{8,}` | 5.6× behind | 7.7× behind | 1.2× behind |
| `(?<=\$)\d+` | 13× behind | 58× behind | 29× behind |
| book: `\b(\w+) \1\b` | 14× behind | 10× behind | 2.4× behind |

**Where z-regex is ahead**
- Fast paths: `[a-z]+` (class run) 2.5× V8 and 3.3× Rust; the literal `hello` 7.6× V8; short
  inputs where a fast path applies: literal 28 ns (V8 67), `[a-z]+` 19 ns (V8 65, Rust 83).
- The book's title pattern (tagged VM) 1.15× V8; `\p{L}+` on the book 1.5× V8.
- Compile time: 1.7–92× less than Rust regex on T0 and 46–260× less on T1 (Rust builds its
  automata and Unicode classes eagerly).
- Memory per compiled pattern: 185–880 bytes on T0, against 1–9 KB for zig-regex.
- Adversarial: `(a+)+b` and `(a|aa)*c` run on T0's VM, a few µs at any n. V8 is exponential
  (seconds at n = 25–30, killed after 5–6 s). PCRE2 answers at once when a required
  character is absent, and on `(a+)+b` over `a^n cb` stops at its match limit (~29 ms JIT,
  ~190 ms interpreter) with an error instead of an answer.

**Even (±10%):** `\p{L}+` and `\p{General_Category=Lu}` against V8; `[A-Z][a-z]+` on the
book against Rust; `[a-z]+` findAll against Rust (0.95×).

**The e-mail case.** Email validation is z-regex's worst T0 case against Rust regex: 19× slower (2.2× slower than V8). The Pike VM pays per-position overhead that a JIT or a lazy DFA avoids. No fix is planned for 0.7.0; a lazy DFA over T0's Thompson program is the candidate for 1.x. Against V8 the worst T0 case is `(\d{3})-(\d{4})` on dense
digits, 5.8× behind (the tagged VM's two passes on top of the same per-position cost); the
worst case of the whole benchmark is T2's lookbehind `(?<=\$)\d+`, 13× behind V8 and 58×
behind PCRE2 JIT.

**Where it's behind, and why**
- **Classes and groups on T0** (`\d{3}-\d{4}`, e-mail, captures): 1.9–5.8× behind V8. V8
  compiles the regexp to machine code; z-regex interprets a Pike VM that steps every live
  thread at every input position, with no DFA. Rust regex's lazy DFA (and on the e-mail its
  literal prefilter on `@`) is 2.5–19× ahead. Groups pay the tagged VM's two passes.
  Email validation is z-regex's worst T0 case against Rust regex: 19× slower (2.2× slower than V8). The Pike VM pays per-position overhead that a JIT or a lazy DFA avoids. No fix is planned for 0.7.0; a lazy DFA over T0's Thompson program is the candidate for 1.x.
- **Literals against Rust:** 1.45× behind (`hello`, `Darcy`). Rust's `memchr` picks the
  rarest bytes of each needle and the vector width at run time; z-regex searches the first
  and last bytes in pairs of vectors of a width fixed at build time (AVX2 here).
- **Short inputs with classes or groups:** 2.3–7.8× behind V8 (e.g. `\d{3}-\d{4}` 284 ns against
  84). The Pike VM has a fixed cost per search (thread lists, closure).
- **findAll:** z-regex's facade allocates per match; on dense cases it gives up most of the
  execAt speed (`[a-z]+` 195 → 53 MB/s). `Regex.iterator` doesn't.
- **T1:** 1.7–4.1× behind Rust regex, whose DFA handles Unicode classes; `\p{Script=Greek}+`
  1.7× behind V8. `v` (`[\p{L}--[a-z]]`) still runs on the backtracker.
- **T2:** 5.6–14× behind V8 and 7–58× behind PCRE2 JIT, 1.2–29× behind PCRE2's interpreter.
  The lookbehind case improved ~24× since 0.3.2 and is still the worst (13× behind V8): the
  backward body runs at every position with no prefilter on `$`.
- **`(?=(a+)+b)`** (a genuine T2 adversarial): z-regex stops at its step budget after ~32 ms
  with `StepLimitExceeded`: bounded, but not an answer. V8 is exponential; PCRE2 answers at
  once (required-character shortcut).

## Notes

- V8 has a JIT; z-regex doesn't. Both are real.
- Rust regex doesn't support backreferences; the T2 cases are not compared against it.
- Absolute numbers vary with LLVM's code layout between builds; the best of 10 rounds is
  within ~4% (p90) between two series (F7-0).
- Match counts are identical across every engine, z-regex 0.3.2 included, on every case.
- Everything here is one machine, a shared container: compare engines within a table, not
  numbers across machines.
