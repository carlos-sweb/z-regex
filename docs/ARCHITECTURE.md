# Architecture

How zregex turns a pattern into a match, as of 0.8.0. This is the reference; the directory
tree with one line per file is in [PROJECT_STRUCTURE.md](PROJECT_STRUCTURE.md), what the
engine supports in [LIMITATIONS.md](LIMITATIONS.md), and the reasoning behind the tiers
in [REGEX_TIERS_PLAN.md](REGEX_TIERS_PLAN.md).

## Overview

```
pattern ──► frontend ──────────────────► HIR ──┬─► tier0: Thompson program ──► fast paths (literal, class run, Shift-And)
            lexer → parser (AST) → lower       │                               ──► DFA (forward + reverse), within a cap
                                               │                               ──► Pike VM (plain or tagged)
                                               └─► tier2: code generator ──► bytecode ──► explicit-stack backtracker
                                                                                               │
                                                                    LookLinear: a lookahead ◄──┘
                                                                    without captures on T0's VM
```

- **One front end.** The lexer and parser build an AST; the lowering turns it into the
  HIR (`src/ir/hir.zig`), plain data in one arena, with every character class already a
  `CharSet` (sorted code point ranges) and case folding already applied to sets. The AST
  is freed when compilation ends.
- **Two executors, chosen per pattern at compile time** (`src/compile.zig`, `route`):
  - **T0**, for patterns without backreferences or lookarounds, linear in the subject. A
    Thompson program, searched by the first that applies: a fast path (a literal, a class
    run, Shift-And for a fixed sequence), the DFA built at compile time (forward and
    reverse, within a cap), or a Pike VM in O(subject × program). The Pike VM has two
    forms: a plain VM for patterns without capture groups and a tagged VM with capture
    slots (two passes, D5); with groups, the fast paths and the DFA give the match bounds
    and the tagged VM fills the groups over the span.
  - **T2**, a backtracker over bytecode, for everything else. It keeps its pending
    alternatives on a heap stack, never on the native stack.
- **The backtracker's program is always built**; T0's only when the pattern routes there.
  Every execution of a pattern with a T0 program stays on T0 (fast path, DFA or VM).
- **T1** (Unicode data, large counted repeats) has no executor of its own: its patterns run
  on T0 in code-point mode when T0 takes them (`u`, `\p{…}`, Unicode case folding; the DFA
  too, in code-point mode),
  on the backtracker otherwise. `src/tier1/` is an empty layer kept for that tier.

## Modules and layers

Each directory under `src/` is a module; `build.zig`'s `layers` table says which modules
each one may import, and `zig build check-layers` checks the sources against it
(`tools/check_layers.zig`). Dependencies only go downwards:

| Module | Imports | What it holds |
|---|---|---|
| `ir` | — | The HIR (`hir.zig`), `CharSet` (`charset.zig`), word-character sets |
| `unicode` | — | UCD 17.0.0 tables (generated), property lookup, case folding (Canonicalize) |
| `utils` | — | Bit sets, dynamic buffers, pools, the shared step `Budget`, debug helpers |
| `subject` | — | `Subject`: WTF-8 bytes or UTF-16 code units, positions and decoding in both directions |
| `frontend` | `ir`, `unicode` | Lexer, parser (AST), lowering to the HIR and set folding |
| `tier0` | `ir`, `utils`, `subject` | Thompson program, prefilters and fast paths (`prefilter.zig`, Shift-And in `shiftand.zig`), the DFA (`dfa.zig`), Pike VM (plain and tagged) |
| `tier1` | `ir`, `unicode`, `utils`, `subject`, `tier0` | Empty (see above) |
| `tier2` | `ir`, `unicode`, `utils`, `subject`, `tier0` | Bytecode format, code generator, backtracker |
| `zregex` (`src/main.zig`) | all of the above | The public API: `regex.zig`, `compile.zig`, `analysis/`. `c_api.zig` is a separate root built on `zregex` |

T0 can't see `unicode` or the front end: it reads the HIR only, and of a `CharSet` only its
ranges. `tier2` imports `tier0` for LookLinear (below).

## Compilation

`Regex.compileWithOptions` → `compile.compileTiers`:

1. **Flags.** `u` and `v` together are `error.IncompatibleFlags`.
2. **Front end** (`frontend.lower.Frontend`):
   - **Lexer** (`frontend/parser/lexer.zig`): tokens, in normal or class mode (the parser
     switches it). Strict mode under `u`/`v`, Annex B otherwise. Without `u`/`v` it works
     in code units: an escape above U+FFFF gives two surrogate halves.
   - **Parser** (`frontend/parser/parser.zig`): recursive descent into an AST, nesting
     bounded by 256 levels (`NestingTooDeep`). Syntax errors are named errors of
     `RegexError`; valid syntax that isn't implemented is `UnsupportedFeature`.
   - **Lowering** (`frontend/lower/lower.zig`, `fold.zig`): AST → HIR. Classes, ranges,
     shorthands, properties and `v` set operations become `CharSet`s; under `i` a set is
     widened to the union of its members' case-folding classes.
3. **Lookbehind check** (`hir.lookbehindsSupported`): a lookbehind the backtracker can't run
   is `UnsupportedFeature`.
4. **Route** (`route`): `analysis/classify.zig` gives the pattern's minimum tier from the
   HIR alone (never from the input). T0 patterns, and T1 ones the VM takes, get a T0
   program when `tier0.check` (plain) or `checkTagged` (tagged) accepts the HIR; the rest
   run on the backtracker. `CompileOptions.force_tier` overrides the route (tests and
   bench only).
5. **Code generation** (`tier2/codegen/generator.zig`): HIR → bytecode, always. A program
   is at most 16 MiB (`PatternTooLarge`). Under the backtracker, a lookahead without
   captures also gets a T0 program (a `LinearSite`) for LookLinear.
6. **T0 program** (`tier0/compile.zig`), when routed: a Thompson NFA whose split order is
   ECMA-262's backtracking priority, plus:
   - **prefilters and fast paths** (`prefilter.zig`), in code-unit mode: anchored, literal,
     class run, Shift-And for a straight line of 1 to 64 ASCII characters and classes
     (`shiftand.zig`), and the skips `first` (first character) and `inner` (the run
     before a required inner literal);
   - **the DFA** (`dfa.zig`, T0-A), built here, at compile time (not lazily), for every
     program it can take: a forward DFA that finds the end of the leftmost-first match and
     a reverse DFA that finds its start, over equivalence classes of the decoded value (a
     128-entry table for ASCII, a binary search over the range cuts for the rest). With
     `^`, `$`, `\b` or `\B` the states also hold the context of one side (`Ctx` tables).
     A `u`/`v` program gets it in code-point mode. The cap is 1,024 states (forward and
     reverse together) and 32,768 cells; a program above it gets no DFA. In code-unit mode
     a program the literal, class-run or Shift-And path serves whole gets none either.

The result is a `Regex`: the backtracker's `CompileResult` (bytecode, `CharSet` table,
named groups), the optional T0 `Program`, the pattern slice, `sticky` and the facade's
`ExecLimits`.

## Execution

`Regex.execAt(subject, index, scratch, out, limits)` is the primitive; `iterator` loops over
it, and the facade (`find`, `findAll`, `test_`, `replace`, …) runs on the same dispatcher
with a WTF-8 subject and byte offsets.

- **Positions.** Indices are in the subject's units. Under `u`/`v` an index inside a
  surrogate pair starts at the pair (`Subject.charStart`).
- **T0** (`tier0/pikevm.zig`, `exec`), in this order:
  1. a fast path (literal, class run, Shift-And), code-unit mode only;
  2. the DFA, when the program has one built for the execution's mode
     (`tier0/dfa.zig`): the forward DFA finds the end (with the `first` or `inner` skip
     while nothing is alive), the reverse DFA from there the start; sticky runs the
     forward one only;
  3. otherwise the Pike VM: threads ordered by priority, the leftmost-first match
     ECMA-262's backtracking would find, in O(subject × program).

  With groups, the tagged VM (`pikevm_tagged.zig`) fills the captures over the bounds
  the first step gave (or finds the end in a first pass and the captures in a second,
  D5). T0 ignores `ExecLimits`: it can't blow up.
- **The backtracker** (`tier2/executor/backtrack.zig`, `core.zig`): runs the bytecode with
  a heap stack of choicepoints (`Scratch.choices`), a capture trail undone to each
  choicepoint's height, zero-progress loop guards and a fast path for simple stars. One
  step per instruction; `ExecLimits.max_steps` (1,000,000 by default) bounds the steps
  **per start position**, and `max_backtrack_stack_bytes` (64 MiB) bounds its stacks.
- **Lookbehind.** A fixed-length body runs forward from `L` characters back
  (`LOOKBEHIND_FIXED`). Any other body is emitted in reverse and each atom in its backward
  form (the opcode with the high bit set: `CHAR_B`, `BACK_REF_B`, …), which tests the
  character before the position and moves left (architecture B, F6b).
- **LookLinear** (F6a): the backtracker hands a lookahead without captures to T0's VM
  (`tier0.existsAnchoredMatch`), with a 2-bit memo per position
  (`ExecLimits.max_memo_bytes`) and the same step `Budget`.
- **`Scratch`** holds every buffer (VM thread lists, choicepoints, trail, guards, memo).
  The caller owns it; once warm, an execution allocates nothing.

## Bytecode (T2 only)

`tier2/bytecode/`: `opcodes.zig` (the opcodes and their operand layout), `writer.zig`
(emission, labels), `reader.zig` and `format.zig` (decoding). Families: character tests
(`CHAR`, `CHAR32`, `CHAR_ANY`, ranges, 256-bit classes, `CHAR_SET`, the `UNICODE_*`
property and script tests, `BYTE` for raw bytes), control flow (`SPLIT` and its greedy,
lazy and possessive forms, `GOTO`, `MATCH`, `REPEAT_MARK`/`REPEAT_CHECK`,
`PUSH_POS`/`CHECK_POS`), captures (`SAVE_START`, `SAVE_END`, their named forms,
`CLEAR_CAPTURE`), backreferences (`BACK_REF`, `BACK_REF_I`), assertions (`LINE_*`,
`STRING_*`, word boundaries), lookarounds (`LOOKAHEAD`, `LOOKBEHIND`, `LOOKBEHIND_FIXED`,
their negatives and ends) and the backward forms of the character tests and
backreferences (`*_B`). `0x02` and `0x16` are reserved (the retired `CHAR2` and `LOOP`, F7c-2).
The encoding doesn't depend on the subject's encoding (F3b); `tests/snapshots/bytecode.txt`
pins the output of the code generator.

## Memory

- **Compilation** frees the AST, the HIR (one arena) and the parser before it returns.
  The `Regex` owns its bytecode, `CharSet` table and T0 program, freed by `deinit`. It
  keeps the caller's pattern slice without copying it: `getPattern` needs that slice to
  outlive the `Regex`.
- **Execution** allocates only in `Scratch`, which grows to the largest execution it has
  served. The facade (`find`, `findAll`, …) makes a `Scratch` per call; `execAt` and
  `iterator` use the caller's.
- No global state, except the diagnostic counter `two_pass_fallbacks` (always 0 unless
  the tagged VM breaks its contract in a build without runtime safety).

## Errors

- **Compile:** `RegexError` (35 errors). Syntax errors have their own names; valid syntax
  that isn't implemented is `UnsupportedFeature`; limits are `NestingTooDeep`,
  `TooManyCaptures`, `PatternTooLarge`.
- **Execution:** `ExecError` (8): `StepLimitExceeded`, `BacktrackStackExhausted`,
  `OutOfMemory`, `InvalidIndex`, `SlotsTooSmall`, and three a compiled program never
  produces.
- The C API maps each one to a `ZRegexError` code. Both lists and the mapping are the
  contract of [API.md](API.md).

## Testing

| What | Where | Run |
|---|---|---|
| Unit tests of each layer | next to the code (`src/**`) | `zig build test-unit` |
| Integration, regression, syntax, captures, subjects, T0, pipeline | `tests/*.zig` | `zig build test-integration` (twice: once as routed, once with every pattern forced onto the backtracker) |
| Bytecode snapshot | `tests/bytecode_snapshot.zig`, `tests/snapshots/bytecode.txt` | part of `zig build test` |
| Layering | `tools/check_layers.zig`, `tests/layers/` | `zig build check-layers` |
| Parser fuzzing | `tests/fuzz_*.zig` | `zig build test-fuzz-stress` |
| test262 | `scripts/test262/` (Node + koffi over the C API) | `zig build test262`, `test262-wtf8` |
| Against V8 | `scripts/test262/differential.mjs`, `lbdiff-v8.mjs`, `ivdiff.mjs` | `zig build differential-v8`, `lbdiff-v8`, `ivdiff` |
| Internal differentials | `tools/{pfdiff,t1diff,lldiff,lbdiff,dfadiff}.zig` over `tests/corpus/` | `zig build pfdiff`, `t1diff`, `lldiff`, `lbdiff`, `dfadiff` |
| All of it | `scripts/gate.sh` | the gate every phase closes with |

The internal differentials compare two executors that must agree: T0's prefilters and VMs
against the backtracker (`pfdiff`, `t1diff`), T0 as routed (fast paths and DFA, both
modes) against the plain VM (`dfadiff`), LookLinear against the backtracker's own
lookahead (`lldiff`), and each lookbehind against a forward oracle (`lbdiff`).
