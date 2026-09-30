# z-regex

An ECMA-262 regular expression engine in Zig, independent of the JavaScript engine that uses it.

[![Zig 0.16+](https://img.shields.io/badge/zig-0.16%2B-orange)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![test262](https://img.shields.io/badge/test262-2994%2F3017%20run%2C%20821%20skipped-blue)](#compatibility)
[![T0](https://img.shields.io/badge/T0-complete-green)](docs/REGEX_TIERS_PLAN.md)

## What it is

- A regex engine that follows ECMA-262's syntax and semantics, Annex B included, with the
  gaps listed under [Limitations](#limitations).
- It does **not** implement the `RegExp` object. It gives a host the primitives to build one:
  `Regex.execAt` (one search from an index, into caller-owned `MatchSlots`),
  `Regex.advanceIndex` (the `lastIndex` step for empty matches), a reusable `Scratch`, and
  subjects in WTF-8 or UTF-16 (`Subject`). `lastIndex`, flags objects, `exec` arrays and
  `Symbol.replace` stay in the host.
- Engine-agnostic: no dependency on a JS engine's values, objects or garbage collector.
- A convenience facade for plain Zig use: `find`, `findAll`, `test_`, `replace`,
  `replaceAll`, and `Regex.iterator` (every match without allocating).
- A C ABI (`src/c_api.zig`, `zig build shared`): 40 `zregex_*` symbols, stable for FFI
  consumers such as the test262 harness ([docs/API.md](docs/API.md)). It is not a
  documented public C API: there is no C header, and callers declare the functions they use
  from `src/c_api.zig`.

## Status

- **T0 (regular patterns): complete.** A Pike VM without captures and a tagged VM with
  captures, both linear in the input.
- **T1 (Unicode: `u`/`v`, `\p{…}`, full case folding): in development (F5).** Since F5a, `u`
  and `\p{…}` run on T0's linear VM (code-point mode); since F5b, so does case folding
  under `i` (with and without `u`). `v` (F5c) still runs on the backtracker.
- **T2 (backreferences, lookaround): on the explicit-stack backtracker**, with a step budget.
  Lookbehind: fixed length without captures (F6b step 1), and outside `u`/`v` any other
  without a lookaround inside, captures and backreferences included (F6b(1)-(3)); the rest
  is `error.UnsupportedFeature`.
- **test262: 2994 of the 3017 entries that run (99.2%); 821 are skipped**, most of them
  features zregex doesn't implement (`v`, RegExp modifiers): see Compatibility.
- **Divergences from V8** in the differential: 0 different results; 2 patterns hit the step
  limit (T2).

## What runs where

| Feature | Tier | Status |
|---|---|---|
| Literals, quantifiers, classes, anchors | T0 | OK |
| Capturing groups (numbered and named) | T0 | OK |
| `.` and the `s` flag | T0 | OK |
| `^` `$` `\b` `\B` | T0 | OK |
| Alternation, prefilters, fast paths | T0 | OK |
| `u`, `\p{…}` | T1 | OK (T0's linear VM, F5a) |
| Unicode case folding under `i` (with and without `u`) | T1 | OK (T0's linear VM, F5b) |
| `v`, `\q{…}` | T1 | F5c (runs on the backtracker) |
| Case folding under `v` (`iv`) | T1 | Literals and classes as `iu` (F7c-0); properties, negated foldable classes and set operations on open operands: `error.UnsupportedFeature` |
| Backreferences | T2 | OK (backtracker) |
| Lookahead | T2 | OK (backtracker) |
| Lookbehind: fixed length without captures (any mode), or variable length, captures and backreferences inside (no `u`/`v`) | T2 | OK (backtracker; backward atoms since v0.6.0, F6b) |
| Lookbehind with a lookaround inside a backward body, or matched backward under `u`/`v` | T2 | `error.UnsupportedFeature` (lookaround inside: 1.x) |

"OK" means it works and passes the tests. It does **not** mean optimized. Which executor runs a
pattern is decided at compile time from the pattern (`zregex.internal.analyze`); the results are the
same whichever runs it.

## Quick start

With Zig 0.16. Add the dependency (this writes the hash into `build.zig.zon`):

```sh
zig fetch --save https://github.com/carlos-sweb/z-regex/archive/refs/tags/v0.7.1.tar.gz
```

In `build.zig`:

```zig
const zregex = b.dependency("zregex", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zregex", zregex.module("zregex"));
```

The facade: find a match and its groups.

```zig
const std = @import("std");
const zregex = @import("zregex");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const re = try zregex.Regex.compile(allocator, "(\\d{3})-(\\d{4})");
    defer re.deinit();

    const text = "Call 555-1234 or 555-9876";
    if (try re.find(text)) |match| {
        defer match.deinit();
        std.debug.print("match: {s}\n", .{match.group(text)}); // 555-1234
        std.debug.print("group 1: {s}\n", .{match.getCapture(1, text).?}); // 555
    }
}
```

What a host (a JS engine's `RegExp`) uses: `execAt` into caller-owned slots, a reused
`Scratch`, `advanceIndex` for empty matches, and WTF-8 or UTF-16 subjects.

```zig
const std = @import("std");
const zregex = @import("zregex");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const re = try zregex.Regex.compile(allocator, "(\\d{3})-(\\d{4})");
    defer re.deinit();

    // One Scratch per thread, reused across calls: 0 allocations once warm.
    var scratch = zregex.Scratch.init(allocator);
    defer scratch.deinit();

    // slots[2g], slots[2g + 1]: start and end of group g (group 0 = match).
    var buf: [6]?usize = undefined;
    var out: zregex.MatchSlots = .{ .slots = buf[0..re.slotCount()] };

    // Every match, as a host's `lastIndex` loop would do it.
    const subject: zregex.Subject = .{ .wtf8 = "Call 555-1234 or 555-9876" };
    var index: usize = 0;
    while (try re.execAt(subject, index, &scratch, &out, .{})) {
        const start = buf[0].?;
        const end = buf[1].?;
        std.debug.print("[{d}, {d}) group 2 at [{d}, {d})\n", .{ start, end, buf[4].?, buf[5].? });
        index = if (end == start) re.advanceIndex(subject, end) else end;
    }

    // The same regex on a UTF-16 subject (a JS string's code units):
    // indices are UTF-16 code units.
    const units = std.unicode.utf8ToUtf16LeStringLiteral("tel 555-1234");
    if (try re.execAt(.{ .utf16 = units }, 0, &scratch, &out, .{})) {
        std.debug.print("utf16: [{d}, {d})\n", .{ buf[0].?, buf[1].? });
    }
}
```

Every match without allocating, as `findAll` finds them: `Regex.iterator` runs the same
`execAt` loop over your `Scratch` and `MatchSlots`.

```zig
const std = @import("std");
const zregex = @import("zregex");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const re = try zregex.Regex.compile(allocator, "(\\d{3})-(\\d{4})");
    defer re.deinit();
    var scratch = zregex.Scratch.init(allocator);
    defer scratch.deinit();
    var buf: [6]?usize = undefined;
    var out: zregex.MatchSlots = .{ .slots = buf[0..re.slotCount()] };

    // Every match, as findAll finds them, without allocating: `m.slots`
    // is `out`, overwritten by the next call.
    const text = "Call 555-1234 or 555-9876";
    var it = re.iterator(.{ .wtf8 = text }, &scratch, &out, .{});
    while (try it.next()) |m| {
        std.debug.print("{s} (group 1: {s})\n", .{ text[m.start..m.end], text[m.slots[2].?..m.slots[3].?] });
    }
}
```

Flags are compile options; resource limits (for patterns on the backtracker) are per
execution:

```zig
const re = try zregex.Regex.compileWithOptions(allocator, "^hello$", .{
    .case_insensitive = true,
    .multiline = true,
});
defer re.deinit();
const limits: zregex.ExecLimits = .{ .max_steps = 100_000, .max_backtrack_stack_bytes = 1 << 20 };
const found = try re.execAt(.{ .wtf8 = "say\nHELLO" }, 0, &scratch, &out, limits);
```

These examples are compiled and run against the library (`zig build`, Zig 0.16).

## API stability

The root of the `zregex` module and the C API are the stable API; the contract is
[docs/API.md](docs/API.md): the 19 stable declarations, the errors and their C codes, what
is a breaking change and how a symbol is deprecated.

- **Not covered:** `zregex.internal` (the engine's pieces, for this repository's tests,
  tools and bench) and the diagnostic fields of `CompileOptions` (`force_tier`,
  `tier_diagnostic`, `t0_prefilters`, `t2_look_linear`). They can change in any release.
- **The error rule (the freeze):** valid syntax that zregex doesn't implement is
  `error.UnsupportedFeature` (C: `ZREGEXP_ERROR_UNSUPPORTED`, 9), never a wrong result. A
  later release only removes such cases; it never adds an error to `RegexError` or
  `ExecError`.

## Performance

T0 runs in O(n·m), without ReDoS. See [docs/BENCHMARKS.md](docs/BENCHMARKS.md) for numbers
against V8, Rust regex, PCRE2 and zig-regex.

## Compatibility

- **test262: 2994 of the 3017 entries that run (99.2%)**, the same status with UTF-16 and
  WTF-8 subjects. Baseline: `scripts/test262/baseline.json`. The 23 that run and don't pass:
  4 lookbehind entries that are `UnsupportedFeature` (2 with a lookaround inside a backward
  lookbehind, `nested-lookaround`, a 1.x decision; 2 under `u`, `named-groups/lookbehind`),
  4 host (JS lexer) and 15 not extractable.
- **821 test262 entries are skipped** and are not in 2994/3017:

  | Skipped | Entries | Why |
  |---|---|---|
  | `v` flag | 312 | Partial in zregex (F5c); the harness skips the feature |
  | RegExp modifiers (ES2025) | 377 | Not implemented, pending until further notice; the harness's Node (22) lacks them too |
  | Duplicate named groups | 24 | Implemented; the harness's Node lacks them. With Node 24 every `named-groups` entry passes except the variable-length lookbehind one |
  | `RegExp.escape` | 40 | A host function; its tests don't exercise zregex |
  | Legacy RegExp (Annex B statics) | 52 | Host |
  | Fail in V8 itself / host flag validation | 16 | Host |
- **`differential-v8`** against `tests/differential/reference/diff-F7a.json`: 0 new, 0 gone,
  0 changed. It has no different result; 2 T2 patterns hit the step limit.
- **Internal differential** (every capture slot, V8 as the arbiter where the executors
  disagree): 0 crashes and 0 two-pass mismatches in 12.76 M runs over the real corpora and
  14.16 M over the iteration corpus (`tests/corpus/`).
- 0 divergences from V8 on T0.

## Architecture

- **Three tiers:** T0 (linear VMs), T1 (Unicode, F5), T2 (backtracker). A pattern's tier comes
  from `zregex.internal.analyze`.
- **One parser, one HIR, several executors:** every executor runs the same HIR, so a pattern
  means the same thing wherever it runs.
- **Layers as build modules:** the table in `build.zig` says which module may import which
  (`tier0` never sees Unicode data or the backtracker); `zig build check-layers` enforces it.
- How it works: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Design and phases:
  [docs/REGEX_TIERS_PLAN.md](docs/REGEX_TIERS_PLAN.md).

## Building and testing

```sh
zig build                  # shared library with the C ABI (zig-out/lib)
zig build test             # unit and integration tests (also -Doptimize=ReleaseSafe)
zig build check-layers     # module layering: lint, forced analysis, canaries
zig build bench            # performance baseline (ReleaseFast)
```

test262 needs Node and the harness's dependencies:

```sh
bash scripts/test262/fetch.sh
npm ci --prefix scripts/test262
zig build test262          # UTF-16 subjects; test262-wtf8 for WTF-8
```

The cross-engine benchmark: `bench/compare/prepare.sh`, then `node bench/compare/run.mjs 10`
(see [bench/README.md](bench/README.md)).

## Limitations

- **T1 is incomplete (F5):** Unicode case folding, `v` and `\q{…}` run on the backtracker,
  not on a linear executor (`u` and `\p{…}` alone run on the VM since F5a). Case folding of
  non-ASCII ranges is partial.
- **T2 uses the current backtracker**, bounded by a step budget: a pathological pattern stops
  with `error.StepLimitExceeded` instead of an answer.
- **Lookbehind (F6b, v0.6.0):** of fixed length without captures or
  backreferences inside (29 of the 34 lookbehind patterns in the npm corpus), or outside
  `u`/`v` any other without a lookaround inside (captures saved and backreferences compared
  right to left); any other is `error.UnsupportedFeature` (C API
  `ZREGEXP_ERROR_UNSUPPORTED`). A lookaround inside a backward lookbehind is a 1.x decision.
  The old 100-character window (D7) is gone.
- **Valid syntax that isn't implemented is `error.UnsupportedFeature`** (C API
  `ZREGEXP_ERROR_UNSUPPORTED`), never a wrong result: a lookbehind matched backward (variable
  length, captures or backreferences inside) under `u`/`v` or with a lookaround inside,
  and under `v` `\q{…}`, chained operations, a bare character as a set operand, a
  union with a nested class, properties of strings. The table: [docs/LIMITATIONS.md](docs/LIMITATIONS.md).
- **RegExp modifiers (ES2025)**, `(?i:…)`, `(?-m:…)`: not implemented, pending until further
  notice; `(?i:a)` is `error.UnsupportedFeature`.
- Patterns with a raw, non-UTF-8 byte (WTF-8 only) stay on the backtracker, as does a tagged
  program over the slot bound.

The full list: [docs/LIMITATIONS.md](docs/LIMITATIONS.md); how each phase got here, with its
measurements: [docs/HISTORY.md](docs/HISTORY.md). How the engine works:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Roadmap

- **T0: done** (F4a, F4b; v0.3.0; v0.3.1 adds the SIMD literal search; v0.3.2 adds `Regex.iterator`).
- **v0.4.0:** F5a, F6a and F5b (T1 without `v` on the VM, explicit-stack backtracker,
  full case folding under `i`; test262 2978/3017).
- **v0.5.0:** F7a, F7b, B′ and C API error names (RepeatMatcher steps 4 and 2.b, compile
  cost, fixed-length lookbehind on the explicit-stack backtracker; test262 2968/3017;
  [release notes](docs/RELEASE_NOTES_v0.5.0.md)).
- **v0.5.1 (E0):** honest errors: valid syntax that isn't implemented is
  `UnsupportedFeature`; `v` applies `u`'s early errors
  ([release notes](docs/RELEASE_NOTES_v0.5.1.md)).
- **v0.6.0 (E1, F6b):** lookbehind matched backward outside `u`/`v`: variable length,
  captures and backreferences inside; test262 2994/3017
  ([release notes](docs/RELEASE_NOTES_v0.6.0.md)).
- **v0.7.0 (F7c): the API freeze.** The stable API and its contract
  ([docs/API.md](docs/API.md)), `zregex.internal`, honest errors for `v` with `i` and for
  invalid `v` set operations, C error codes, documentation and benchmarks re-measured
  ([release notes](docs/RELEASE_NOTES_v0.7.0.md)).
- **v0.7.1: T0 throughput (J+C+B).** `x+` without a duplicated body, a Shift-And path for
  fixed ASCII sequences and a skip to the run before a required inner literal; API and
  results unchanged ([release notes](docs/RELEASE_NOTES_v0.7.1.md)).
- **To 1.0** ([docs/plans/ROADMAP_1.0.md](docs/plans/ROADMAP_1.0.md)): E0 (v0.5.1) → E1, full
  F6b (v0.6.0) → F7c: API freeze and documentation (v0.7.0, done) → T0 throughput
  (v0.7.1, done) → a DFA for T0 ([docs/plans/T0-A.md](docs/plans/T0-A.md)) and the full
  benchmark (v0.8.0) → 1–3 months of production use → v1.0.0 with the same API. RegExp modifiers: pending until further notice.
- **F5, T1 (Unicode):** F5a done (`u` and `\p{…}` on the VM, every UCD property name);
  F5b done (full case folding under `i`); F5c (full `v`) pending.
- **F6a, T2 without lookbehind: done** (explicit-stack backtracker, capture trail,
  LookLinear; F6a(1)–(3)).
- **F6b, lookbehind: closed in v0.6.0.** B′ (fixed length without captures, forward) and
  matching backward outside `u`/`v` (variable length, captures, backreferences). Not
  covered, `UnsupportedFeature`: a lookaround inside a backward lookbehind (1.x) and any
  backward lookbehind under `u`/`v`.

No dates. Phases and exit criteria: [docs/REGEX_TIERS_PLAN.md](docs/REGEX_TIERS_PLAN.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Behavior changes are judged against test262 and V8
(`zig build differential-v8`).

## License

MIT, see [LICENSE](LICENSE).
