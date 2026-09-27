# Benchmarks: z-regex against V8, Rust regex, PCRE2 and zig-regex

What this measures: z-regex 0.3.0 (T0 closed: F4a and F4b) against the engines people
would use instead, **tier by tier** (docs/REGEX_TIERS_PLAN.md): a T0 case is compared only
with engines that run it as a regular expression, a T2 case (backreferences, lookaround) only
with backtracking engines that support it. Tiers are never mixed in one table.

## Setup

| | |
|---|---|
| Machine | Intel(R) Xeon(R) Processor @ 2.10GHz, 4 cores (no SMT), KVM guest, 15Gi RAM, Linux 6.18.44-fc-v37 |
| Environment | **shared container**: expect ±15% variance between runs; read the min–max band, not only the median |
| z-regex | 0.3.0, Zig 0.16.0, ReleaseFast |
| V8 | 12.4.254.21-node.39 (Node v22.22.2) |
| Rust regex | 1.13.1 (rustc 1.94.1 (e408947bf 2026-03-25)), release, LTO |
| PCRE2 | 10.42, 8-bit library, JIT and interpreter |
| zig-regex | 0.1.1 (zig-utils/zig-regex, 173b298) — the last release that builds with Zig 0.16 (v0.2.x needs 0.17-dev) |

**Method.** 10 interleaved rounds: each round runs every engine once over all its cases, and
the engines' order rotates from round to round. Within a round, a throughput number is the
median of up to 5 timed passes after one warm-up. Every cell below is the **median over the
rounds, with the min–max band** in parentheses. Harness, corpora and runner:
`bench/compare/` (`prepare.sh` builds everything, `run.mjs` only runs, `analyze.mjs` writes
`bench/results.json`, the raw aggregated numbers).

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
feature it lacks).

Rounds: 10 interleaved; each cell: median (min–max) over the rounds.

† z-regex literal cells re-measured after the SIMD literal search (`prefilter.findLiteral`):
10 interleaved rounds of z-regex alone, new code against the previous one, same machine and
harness; the other engines' cells are from the original run and `bench/results.json` still
holds the original z-regex numbers. Before: execAt 926.3 (`hello`) and 886.5 (`Darcy`) MB/s.
Measured on Xeon with SSE2 + AVX2 + AVX-512BW; other CPUs will see less.

#### T0: findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)

| Case | z-regex | V8 (warm) | V8 (cold) | Rust regex | zig-regex |
|---|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 12777.7 (10426.2–13342.6) † | 1689.8 (1584.7–1760.6) | 1439.8 (1308.0–1549.9) | 20505.7 (13435.3–20918.3) | — |
| [a-z]+ <sub>(z-regex: VM)</sub> | 76.4 (67.2–82.9) | 103.6 (63.0–108.8) | 70.1 (57.7–73.5) | 71.8 (64.2–74.0) | — |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 35.3 (26.5–36.5) | n/a | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 27.4 (24.9–28.5) | n/a | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 504.6 (474.2–520.7) | 1649.7 (1016.8–1744.4) | 510.7 (337.8–536.4) | 2114.7 (1345.6–2150.5) | — |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 38.2 (23.6–39.3) | 215.3 (206.9–219.7) | 121.8 (116.3–126.4) | 84.4 (60.7–86.0) | — |
| email <sub>(z-regex: VM)</sub> | 43.8 (31.0–45.9) | 87.4 (85.8–89.5) | 75.0 (67.4–77.4) | 759.1 (620.5–772.7) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 305.8 (179.9–319.1) | 1447.1 (1358.9–1522.9) | 412.6 (282.7–455.5) | 1121.1 (1025.4–1141.8) | — |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 29.9 (18.2–32.4) | 172.8 (124.1–178.4) | 112.8 (79.0–117.6) | 67.2 (60.1–69.2) | — |
| (?:(a)\|b)*c <sub>(z-regex: tagged VM)</sub> | 14.2 (12.3–14.6) | 36.6 (34.0–37.3) | 30.3 (22.4–31.5) | 48.3 (38.4–50.3) | — |
| book: Darcy <sub>(z-regex: VM)</sub> | 9068.7 (6785.8–9879.5) † | 13344.8 (11562.6–14372.6) | 2700.9 (2275.3–3228.4) | 17748.2 (15611.5–18063.2) | — |
| book: [A-Z][a-z]+ <sub>(z-regex: VM)</sub> | 283.2 (192.7–289.7) | 611.6 (561.1–638.9) | 172.8 (150.5–189.9) | 284.1 (259.2–288.7) | — |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: tagged VM)</sub> | 606.6 (535.8–639.1) | 524.3 (498.0–536.9) | 394.7 (330.3–407.8) | 2111.0 (1273.6–2226.6) | — |

#### T0: execAt MB/s (engine loop, no per-match allocation where the API allows)

| Case | z-regex | V8 (warm) | Rust regex | zig-regex |
|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 16925.1 (15043.9–17551.6) † | 1791.8 (1501.9–1831.4) | 20999.1 (14847.4–21438.5) | — |
| [a-z]+ <sub>(z-regex: VM)</sub> | 214.8 (154.0–222.5) | 116.7 (73.3–118.1) | 75.0 (71.9–76.4) | — |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 53.1 (50.9–53.9) | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 40.3 (37.5–41.4) | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 644.7 (605.0–655.0) | 1342.9 (869.8–1369.3) | 2319.2 (1404.8–2446.4) | — |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 42.5 (31.0–44.0) | 222.8 (193.1–229.4) | 85.0 (61.1–88.1) | — |
| email <sub>(z-regex: VM)</sub> | 45.5 (36.3–46.7) | 87.8 (82.3–89.6) | 778.0 (639.8–785.6) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 358.9 (205.9–369.4) | 1629.6 (1558.0–1662.2) | 1493.7 (1326.7–1522.8) | — |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 33.6 (29.9–34.4) | 198.5 (142.0–203.9) | 76.5 (52.7–79.0) | — |
| (?:(a)\|b)*c <sub>(z-regex: tagged VM)</sub> | 15.5 (14.8–15.9) | 37.2 (34.1–38.1) | 58.4 (56.0–60.1) | — |
| book: Darcy <sub>(z-regex: VM)</sub> | 15925.0 (14503.5–16229.5) † | 15514.4 (13534.5–15943.5) | 19231.8 (18352.9–19347.0) | — |
| book: [A-Z][a-z]+ <sub>(z-regex: VM)</sub> | 400.7 (377.7–407.0) | 622.9 (380.5–647.4) | 290.1 (264.2–294.0) | — |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: tagged VM)</sub> | 681.5 (511.0–730.7) | 532.0 (382.0–541.8) | 2662.5 (1712.1–2750.9) | — |

#### T0: ns per exec on a short input (< 64 B)

| Case | z-regex | V8 (warm) | Rust regex | zig-regex |
|---|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 18 (18–19) † | 48 (46–60) | 19 (18–25) | 317 (305–353) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 15 (14–26) | 43 (41–49) | 52 (50–53) | 501 (484–606) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 85 (83–99) | n/a | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 107 (102–121) | n/a | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 194 (190–204) | 53 (51–58) | 50 (49–68) | 1071 (1030–1259) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 201 (190–234) | 53 (52–57) | 52 (48–53) | 1050 (1028–1213) |
| email <sub>(z-regex: VM)</sub> | 401 (393–431) | 98 (96–104) | 59 (56–61) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 425 (410–516) | 68 (66–76) | 102 (98–123) | 2986 (2884–3059) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 410 (398–445) | 66 (63–72) | 101 (98–160) | 3015 (2889–3450) |
| (?:(a)\|b)*c <sub>(z-regex: tagged VM)</sub> | 463 (444–508) | 47 (44–78) | 95 (91–101) | 3174 (3053–3384) |
| book: Darcy <sub>(z-regex: VM)</sub> | 18 (18–20) † | 44 (41–44) | 18 (17–19) | 311 (304–348) |
| book: [A-Z][a-z]+ <sub>(z-regex: VM)</sub> | 135 (131–227) | 47 (45–70) | 62 (59–68) | 1478 (1434–1503) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: tagged VM)</sub> | 633 (607–656) | 62 (60–65) | 119 (114–128) | 7338 (7234–7427) |

#### T0: µs per compile

| Case | z-regex | Rust regex | zig-regex |
|---|---|---|---|
| literal hello <sub>(z-regex: VM)</sub> | 1.45 (1.42–2.13) | 2.37 (2.32–3.86) | 0.98 (0.95–1.31) |
| [a-z]+ <sub>(z-regex: VM)</sub> | 1.15 (1.14–1.92) | 7.51 (7.21–9.49) | 0.51 (0.50–0.62) |
| [a-z]+ (z-regex: generic VM, no fast path) <sub>(z-regex: VM)</sub> | 1.14 (1.11–1.70) | n/a | n/a |
| [a-z]+ (z-regex: backtracker) <sub>(z-regex: backtracker)</sub> | 0.78 (0.75–1.05) | n/a | n/a |
| \d{3}-\d{4} (sparse) <sub>(z-regex: VM)</sub> | 2.39 (2.20–3.39) | 167.57 (156.31–261.13) | 1.28 (1.23–1.50) |
| \d{3}-\d{4} (dense) <sub>(z-regex: VM)</sub> | 2.28 (2.21–3.22) | 156.54 (150.45–162.16) | 1.32 (1.21–1.81) |
| email <sub>(z-regex: VM)</sub> | 6.36 (6.22–10.48) | 18.56 (18.17–27.85) | unsupported |
| (\d{3})-(\d{4}) (sparse) <sub>(z-regex: tagged VM)</sub> | 3.19 (2.85–7.53) | 163.77 (158.28–206.29) | 1.62 (1.57–1.68) |
| (\d{3})-(\d{4}) (dense) <sub>(z-regex: tagged VM)</sub> | 2.96 (2.85–3.07) | 160.00 (157.44–214.20) | 2.04 (1.61–2.32) |
| (?:(a)\|b)*c <sub>(z-regex: tagged VM)</sub> | 3.19 (3.01–4.71) | 11.40 (11.10–19.06) | 1.10 (1.06–1.18) |
| book: Darcy <sub>(z-regex: VM)</sub> | 1.44 (1.41–1.47) | 2.29 (2.15–2.46) | 0.98 (0.96–1.30) |
| book: [A-Z][a-z]+ <sub>(z-regex: VM)</sub> | 2.12 (1.96–2.22) | 9.16 (8.57–19.18) | 0.87 (0.84–1.13) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: tagged VM)</sub> | 6.07 (5.92–7.05) | 25.36 (24.29–35.39) | 3.13 (3.09–3.17) |

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
| (?:(a)\|b)*c <sub>(z-regex: tagged VM)</sub> | 354 (354–354) | 3227 (3227–3227) |
| book: Darcy <sub>(z-regex: VM)</sub> | 185 (185–185) | 2322 (2322–2322) |
| book: [A-Z][a-z]+ <sub>(z-regex: VM)</sub> | 260 (260–260) | 1751 (1751–1751) |
| book: (Mr\|Mrs\|Miss)\.? ([A-Z][a-z]+) <sub>(z-regex: tagged VM)</sub> | 880 (880–880) | 9370 (9370–9370) |

#### T1: findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)

| Case | z-regex | V8 (warm) | V8 (cold) | Rust regex |
|---|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: backtracker)</sub> | 23.6 (22.2–24.7) | 47.5 (44.5–49.1) | 38.0 (25.3–39.0) | 80.4 (55.9–83.8) |
| \p{Script=Greek}+ /u <sub>(z-regex: backtracker)</sub> | 30.0 (21.1–30.4) | 110.9 (101.2–112.7) | 76.0 (66.0–79.1) | 249.8 (213.7–254.8) |
| \p{General_Category=Lu} /u <sub>(z-regex: backtracker)</sub> | 23.9 (19.5–24.6) | 61.8 (42.0–63.9) | 47.2 (41.2–50.0) | 191.2 (180.3–194.2) |
| [\p{L}--[a-z]] /v <sub>(z-regex: backtracker)</sub> | 16.7 (16.1–16.9) | 33.7 (30.8–34.9) | 28.1 (19.2–30.4) | n/a |
| book: \p{L}+ /u <sub>(z-regex: backtracker)</sub> | 18.5 (14.4–19.2) | 33.0 (25.4–34.3) | 26.8 (18.4–27.7) | 65.8 (61.4–66.5) |

#### T1: execAt MB/s (engine loop, no per-match allocation where the API allows)

| Case | z-regex | V8 (warm) | Rust regex |
|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: backtracker)</sub> | 30.1 (20.9–31.2) | 48.8 (34.6–50.3) | 85.1 (62.9–87.4) |
| \p{Script=Greek}+ /u <sub>(z-regex: backtracker)</sub> | 32.2 (28.7–32.4) | 100.7 (97.6–114.8) | 252.6 (228.1–256.3) |
| \p{General_Category=Lu} /u <sub>(z-regex: backtracker)</sub> | 26.5 (17.4–27.3) | 61.8 (50.2–63.9) | 204.1 (200.9–205.3) |
| [\p{L}--[a-z]] /v <sub>(z-regex: backtracker)</sub> | 25.6 (24.4–26.7) | 36.6 (27.3–38.4) | n/a |
| book: \p{L}+ /u <sub>(z-regex: backtracker)</sub> | 24.7 (22.7–25.2) | 34.2 (21.6–35.5) | 67.7 (64.2–69.2) |

#### T1: ns per exec on a short input (< 64 B)

| Case | z-regex | V8 (warm) | Rust regex |
|---|---|---|---|
| \p{L}+ /u <sub>(z-regex: backtracker)</sub> | 273 (265–282) | 142 (136–145) | 70 (66–77) |
| \p{Script=Greek}+ /u <sub>(z-regex: backtracker)</sub> | 353 (344–397) | 149 (143–158) | 71 (68–76) |
| \p{General_Category=Lu} /u <sub>(z-regex: backtracker)</sub> | 195 (191–203) | 119 (114–125) | 37 (36–39) |
| [\p{L}--[a-z]] /v <sub>(z-regex: backtracker)</sub> | 196 (191–212) | 134 (128–149) | n/a |
| book: \p{L}+ /u <sub>(z-regex: backtracker)</sub> | 144 (140–151) | 46 (41–57) | 49 (47–49) |

#### T1: µs per compile

| Case | z-regex | Rust regex |
|---|---|---|
| \p{L}+ /u <sub>(z-regex: backtracker)</sub> | 0.67 (0.66–0.91) | 300.14 (272.86–416.33) |
| \p{Script=Greek}+ /u <sub>(z-regex: backtracker)</sub> | 0.74 (0.72–1.01) | 58.98 (58.33–62.89) |
| \p{General_Category=Lu} /u <sub>(z-regex: backtracker)</sub> | 0.49 (0.48–0.67) | 175.58 (170.31–180.75) |
| [\p{L}--[a-z]] /v <sub>(z-regex: backtracker)</sub> | 5.10 (5.03–6.94) | n/a |
| book: \p{L}+ /u <sub>(z-regex: backtracker)</sub> | 0.68 (0.67–0.98) | 281.90 (277.38–330.23) |

#### T1: bytes per compiled pattern

| Case | z-regex |
|---|---|
| \p{L}+ /u <sub>(z-regex: backtracker)</sub> | 12 (12–12) |
| \p{Script=Greek}+ /u <sub>(z-regex: backtracker)</sub> | 12 (12–12) |
| \p{General_Category=Lu} /u <sub>(z-regex: backtracker)</sub> | 3 (3–3) |
| [\p{L}--[a-z]] /v <sub>(z-regex: backtracker)</sub> | 5486 (5486–5486) |
| book: \p{L}+ /u <sub>(z-regex: backtracker)</sub> | 12 (12–12) |

#### T2: findAll MB/s (allocating wrapper; V8 cold: new RegExp + first pass)

| Case | z-regex | V8 (warm) | V8 (cold) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 29.7 (20.2–30.9) | 240.3 (151.9–262.4) | 117.1 (85.6–124.7) | 261.8 (236.9–270.0) | 66.4 (47.2–69.0) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 3.8 (3.5–3.9) | 54.4 (51.9–55.8) | 43.0 (38.1–44.9) | 69.2 (56.2–70.8) | 10.7 (9.2–11.0) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 0.8 (0.8–0.8) | 226.5 (219.7–230.6) | 140.8 (128.9–145.9) | 990.3 (526.8–1045.7) | 521.5 (504.1–535.1) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 11.4 (8.4–11.9) | 133.4 (97.7–135.1) | 128.4 (116.4–131.3) | 111.4 (94.8–114.3) | 32.0 (30.4–32.8) |

#### T2: execAt MB/s (engine loop, no per-match allocation where the API allows)

| Case | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 33.8 (23.4–35.4) | 262.1 (157.1–276.4) | 276.3 (247.2–285.5) | 69.6 (65.7–70.3) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 3.8 (3.6–3.9) | 54.8 (49.8–56.3) | 70.3 (66.3–72.4) | 10.9 (9.6–11.2) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 0.8 (0.7–0.8) | 233.2 (219.6–236.4) | 1073.6 (964.2–1095.5) | 529.1 (333.8–545.1) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 11.4 (10.3–11.9) | 134.1 (98.2–136.2) | 112.3 (107.2–115.3) | 31.9 (28.2–32.7) |

#### T2: ns per exec on a short input (< 64 B)

| Case | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 396 (387–468) | 45 (41–92) | 36 (34–40) | 154 (149–159) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 874 (845–894) | 88 (86–91) | 58 (57–63) | 283 (273–308) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 650 (612–687) | 68 (62–84) | 27 (27–34) | 85 (84–108) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 292 (284–309) | 55 (53–61) | 38 (38–41) | 100 (99–159) |

#### T2: µs per compile

| Case | z-regex | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 3.56 (3.52–4.28) | 6.76 (6.66–9.43) | 0.60 (0.59–0.62) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 2.79 (2.76–4.08) | 5.53 (5.48–10.26) | 0.78 (0.75–1.27) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 1.18 (1.15–1.66) | 3.67 (3.65–3.78) | 0.42 (0.41–0.68) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 2.55 (2.50–3.27) | 6.34 (6.22–6.94) | 0.53 (0.52–0.95) |

#### T2: bytes per compiled pattern

| Case | z-regex | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|
| <(\w+)>.*?<\/\1> <sub>(z-regex: backtracker)</sub> | 92 (92–92) | 1287 (1287–1287) | 168 (168–168) |
| (?=.*[a-z])(?=.*[A-Z]).{8,} <sub>(z-regex: backtracker)</sub> | 84 (84–84) | 963 (963–963) | 231 (231–231) |
| (?<=\$)\d+ <sub>(z-regex: backtracker)</sub> | 30 (30–30) | 687 (687–687) | 156 (156–156) |
| book: \b(\w+) \1\b <sub>(z-regex: backtracker)</sub> | 59 (59–59) | 1226 (1226–1226) | 160 (160–160) |

#### Adversarial: ms until the engine answers or gives up (median over rounds; outcome)

| Case | n | z-regex | V8 (warm) | PCRE2 (JIT) | PCRE2 (interp.) |
|---|---|---|---|---|---|
| (a+)+b on a^n c | 20 | 0.004 (no match) | 96.189 (no match) | 0.006 (no match) | 0.005 (no match) |
| (a+)+b on a^n c | 25 | 0.004 (no match) | 3095.259 (no match) | 0.006 (no match) | 0.005 (no match) |
| (a+)+b on a^n c | 30 | 0.004 (no match) | 5003.000 (timeout (> 5 s, killed)) | 0.006 (no match) | 0.004 (no match) |
| (a+)+b on a^n c | 40 | 0.004 (no match) | 5003.000 (timeout (> 5 s, killed)) | 0.006 (no match) | 0.004 (no match) |
| (a+)+b on a^n cb | 20 | 0.004 (no match) | 97.746 (no match) | 9.499 (no match) | 79.074 (no match) |
| (a+)+b on a^n cb | 25 | 0.004 (no match) | 3123.573 (no match) | 22.549 (match limit) | 143.709 (match limit) |
| (a+)+b on a^n cb | 30 | 0.004 (no match) | 5005.000 (timeout (> 5 s, killed)) | 23.070 (match limit) | 145.506 (match limit) |
| (a+)+b on a^n cb | 40 | 0.004 (no match) | 5003.000 (timeout (> 5 s, killed)) | 22.922 (match limit) | 154.482 (match limit) |
| (?=(a+)+b) on a^n c | 20 | 28.183 (StepLimitExceeded) | 98.936 (no match) | 0.006 (no match) | 0.004 (no match) |
| (?=(a+)+b) on a^n c | 25 | 27.661 (StepLimitExceeded) | 3094.175 (no match) | 0.005 (no match) | 0.005 (no match) |
| (?=(a+)+b) on a^n c | 30 | 28.160 (StepLimitExceeded) | 5008.000 (timeout (> 5 s, killed)) | 0.005 (no match) | 0.004 (no match) |
| (?=(a+)+b) on a^n c | 40 | 27.991 (StepLimitExceeded) | 5007.000 (timeout (> 5 s, killed)) | 0.006 (no match) | 0.005 (no match) |

Match counts: identical across every engine that runs a case.

### zig-regex: findAll growth (characterization, not a performance number)

zig-regex's `findAll` restarts its VM at every start position, so its cost grows with the
square of the input: a 1 MiB pass would take on the order of an hour, and it has no MB/s in
the tables above. Measured once on prefixes of the same corpora (MB/s at 16 / 32 / 64 KiB):
literal `hello` 0.014 / 0.007 / 0.003; `[a-z]+` 0.046 / 0.022 / 0.011. Each doubling of the input
halves the throughput. zig-regex also rejects `\w` inside a class (`InvalidCharacterClass`),
so the e-mail pattern doesn't compile.

### z-regex: findAll against the iterator

`Regex.iterator` (0.3.1+) gives every match `findAll` gives, one at a time, over the caller's
`Scratch` and `MatchSlots`: no allocation once the scratch is warm. Measured on its own run
(z-regex alone, 10 runs of `zregex_xbench`, same machine; median (min–max), MB/s):

| Case | matches | findAll | execAt loop | iterator |
|---|---|---|---|---|
| literal hello | 87 | 13425.4 (12363.1–14161.9) | 16511.8 (12163.2–17493.2) | 16853.4 (15149.9–17340.3) |
| book: Darcy | 417 | 8480.3 (6701.4–9561.1) | 15620.1 (10443.2–16042.7) | 15689.5 (15205.2–16092.0) |
| [a-z]+ | 158,795 | 75.1 (68.5–82.0) | 213.2 (164.0–217.3) | 214.8 (163.0–219.5) |
| book: [A-Z][a-z]+ | 11,031 | 280.5 (178.3–288.8) | 384.8 (233.2–390.4) | 388.7 (233.6–396.2) |
| \d{3}-\d{4} (dense) | 30,810 | 39.3 (24.3–41.0) | 42.5 (41.4–43.8) | 43.2 (25.8–44.7) |
| [\p{L}--[a-z]] /v | 309,431 | 16.7 (14.3–17.0) | 25.7 (22.6–26.2) | 25.5 (24.4–26.3) |

On all 22 cases the iterator is within 0.98–1.03× of the execAt loop; against findAll it's
1.00–2.86× (the most where matches are many or the search is fast).

Where findAll's time goes (a separate probe, µs per call, `smp_allocator` as in the bench):
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

Reference: V8 warm, `execAt` column, unless said otherwise. Factors are ratios of medians.

**Where z-regex is ahead**
- `[a-z]+` (class-run fast path): 1.84× V8, 2.86× Rust regex (execAt).
- `(Mr|Mrs|Miss)\.? ([A-Z][a-z]+)` on the book (tagged VM): 1.28× V8 (execAt), 1.16× V8
  (findAll).
- `[A-Z][a-z]+` on the book: 1.38× Rust regex (execAt); in findAll, 1.64× V8 cold (and 1.54×
  V8 cold for the title pattern).
- Literal `hello` (SIMD pair search, †): 9.4× V8 in execAt, 7.6× V8 in findAll.
- Short inputs where a fast path applies: literal 18 ns (V8 48, 2.7×; Rust 19), `[a-z]+`
  15 ns (V8 43, 2.87×; Rust 52, 3.45×).
- Memory per compiled pattern: 185–880 bytes on T0, against 1–9 KB for zig-regex and
  0.7–1.3 KB for PCRE2 with JIT.
- Compile time against Rust regex: 1.6–70× less on T0 and 80–450× less on T1 (Rust builds
  its automata and Unicode classes eagerly).
- Adversarial `(a+)+b`: z-regex routes it to T0 (linear): ~4 µs at any n. V8 is exponential
  (~3.1 s at n = 25, killed after 5 s from n = 30). PCRE2 either rejects `a^n c` at once
  (required-character shortcut) or, on `a^n cb`, stops at its match limit (~23 ms JIT,
  ~145 ms interpreter) with an error instead of an answer.

**Where it's even (within ±10%)**
- `[a-z]+` findAll against Rust regex (1.06×) and against V8 cold (1.09×).
- `[A-Z][a-z]+` findAll against Rust regex (1.00×).
- `\d{3}-\d{4}` sparse findAll against V8 cold (0.99×).
- Literal `Darcy` execAt against V8 (1.03×, †).

**Where it's behind, and why**
- **Literals** (†): 1.24× (`hello`) and 1.21× (`Darcy`) behind Rust in execAt; in findAll,
  1.6× / 2.0× behind Rust and 1.47× behind V8 on `Darcy` (the allocating wrapper's cost per
  call). z-regex searches the first and last bytes of the literal in pairs of vectors whose
  width is fixed at compile time (scalar search when the target has no vectors), without
  Rust's per-case selection: Rust's `memchr` picks the two rarest bytes of each needle,
  chooses AVX2 or SSE2 at run time, and falls back to Two-Way. Measured on Xeon with SSE2 +
  AVX2 + AVX-512BW; other CPUs will see less.
- **`\d{3}-\d{4}`**: 2.1× (sparse) and 5.2× (dense) behind V8. V8 compiles the regexp to
  machine code (JIT); z-regex interprets a Pike VM that steps every live thread per input
  position, with no DFA. Rust regex's lazy DFA is 3.6× / 2× ahead.
- **E-mail**: 1.9× behind V8, 17× behind Rust regex (lazy DFA plus its literal prefilter on
  `@`).
- **Captures**: `(\d{3})-(\d{4})` 4.5× (sparse) and 5.9× (dense) behind V8,
  `(?:(a)|b)*c` 2.4×. The tagged VM runs D5's two passes (the capture-less VM finds the
  bounds, then the tagged VM with slot rows and a dynamic closure re-runs the match).
- **Short inputs with classes or groups**: 2.9–10× behind V8 (e.g. `\d{3}-\d{4}` 194 ns
  against 53). The Pike VM has a fixed cost per search (thread lists, closure), and groups
  pay two passes.
- **findAll in general**: z-regex's facade allocates one `captures` slice per match and a
  growing list of `MatchResult`s, and pays fresh pages for it on every call; it weighs on dense
  cases (`[a-z]+`: 214 MB/s execAt, 76 findAll). `Regex.iterator` gives the same matches at the
  execAt loop's speed (see "findAll against the iterator" above).
- **T1** (`u`/`v`): 1.4–3.1× behind V8 and 2.7–7.7× behind Rust regex. z-regex has no T1
  executor yet (F5): these patterns run on the backtracker.
- **T2** (the backtracker, unchanged since before T0): 7.8× (`<(\w+)>.*?<\/\1>`), 14×
  (the double lookahead) and 11.8× (the book's `\b(\w+) \1\b`) behind V8, and **~290× on
  the lookbehind `(?<=\$)\d+`**: the current lookbehind (D7) tries up to 100 lengths at every
  position; F6b replaces it.
- **`(?=(a+)+b)`** (a genuine T2 adversarial): z-regex stops at its step budget after ~28 ms
  with `StepLimitExceeded` — bounded, but not an answer. V8 is exponential; PCRE2 answers at
  once (required-character shortcut).

## Notes

- V8 has a JIT; z-regex doesn't. Both are real.
- Rust regex doesn't support backreferences; the T2 cases are not compared against it.
- Absolute numbers vary with LLVM's code layout between builds. Median of 10 runs.
- z-regex T0 has 0 divergences from V8 in test262 and in the differential. The 477
  divergences of `diff-F4b.json` are T2 (470) and T1 (7).
- Everything here is one machine, a shared container: compare engines within a table, not
  numbers across machines.
