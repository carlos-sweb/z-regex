# Architecture Overview

> **Accuracy note**: this document was originally written before implementation began, as
> a design plan. The Module Breakdown (Core, Parser/Codegen, Bytecode, Executor, Unicode,
> Utils) and Error Hierarchy sections below have been corrected against the current
> source tree (2026-07-04). Sections further down (memory/ownership details, testing
> strategy, future enhancements) have not all been individually re-verified and may still
> describe original design intent rather than exact current code — treat type/field names
> there as illustrative, and check `src/` directly when precision matters. See
> [PROJECT_STRUCTURE.md](PROJECT_STRUCTURE.md) for the verified directory layout and
> [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) for verified current behavior.

## Philosophy

zregexp follows these core principles:

1. **Separation of Concerns**: Each subsystem is independent and testable
2. **Explicit over Implicit**: No hidden allocations, clear ownership
3. **Safety First**: Leverage Zig's compile-time guarantees
4. **Performance Aware**: Optimize hot paths without sacrificing clarity
5. **Modular Design**: Unlike libregexp's single file, organize by domain

## System Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        USER API                             │
│  (compile, exec, match, captures, replace, split)           │
└─────────────────────────────────────────────────────────────┘
                            │
        ┌───────────────────┴───────────────────┐
        │                                       │
        ▼                                       ▼
┌──────────────────┐                  ┌──────────────────┐
│    COMPILER      │                  │    EXECUTOR      │
│                  │                  │                  │
│  - Parser        │                  │  - VM            │
│  - Validator     │    Bytecode      │  - Backtracking  │
│  - Code Gen      │  ═══════════>    │  - Stack Mgmt    │
│  - Optimizer     │                  │  - Captures      │
└──────────────────┘                  └──────────────────┘
        │                                       │
        │                                       │
        ▼                                       ▼
┌──────────────────┐                  ┌──────────────────┐
│    BYTECODE      │                  │     UNICODE      │
│                  │                  │                  │
│  - Opcodes       │                  │  - CharRange     │
│  - Format        │                  │  - Properties    │
│  - Header        │                  │  - Case Folding  │
└──────────────────┘                  └──────────────────┘
        │                                       │
        │                                       │
        └───────────────────┬───────────────────┘
                            │
                            ▼
                  ┌──────────────────┐
                  │      CORE        │
                  │                  │
                  │  - Types         │
                  │  - Errors        │
                  │  - Allocators    │
                  └──────────────────┘
```

## Module Breakdown

### 1. Core (`src/core/`)

**Purpose**: Compile-time configuration flags.

**Components**:
- `config.zig`: Two compile-time booleans (`enable_execution_trace`,
  `panic_on_internal_error`), consumed by `src/utils/debug.zig`.

That's the entire module today. `CompileOptions` (case-insensitivity, multiline, dot_all)
lives in `src/codegen/compiler.zig` instead, and error sets are defined per-module
(`ParseError` in `src/parser/parser.zig`, `CodegenError` in `src/codegen/generator.zig`,
combined into `RegexError` in `src/regex.zig`) rather than centralized here.

**Key Decisions**:
- All allocations explicit via Allocator parameter
- Errors as first-class citizens (no error codes)

### 2. Parser + Codegen (`src/parser/`, `src/codegen/`)

**Purpose**: Parse the regex pattern and generate bytecode. (Originally planned as one
`src/compiler/` module — see `PROJECT_STRUCTURE.md` for why it's split this way instead.)

**Components**:
- `parser/lexer.zig`: Tokenizer
- `parser/ast.zig`: Abstract syntax tree nodes
- `parser/parser.zig`: Recursive descent parser (tokens → AST)
- `codegen/generator.zig`: AST → bytecode
- `codegen/optimizer.zig`: Bytecode optimization passes
- `codegen/compiler.zig`: Top-level `compile()`/`compileSimple()` and `CompileOptions`

**Pipeline**:
```
Pattern String → Lexer → Parser → AST → Generator → Bytecode
                                             ↓
                                        Optimizer
```

**Key Algorithms**:
- **Recursive Descent Parsing**: Clean, maintainable, maps to spec
- **Single-Pass Code Generation**: No intermediate IR needed

**Parsing Strategy** (`parseAlternation` → `parseSequence` → `parseTerm` → `parseAtom`,
matching the grammar documented at the top of `parser.zig`):
```
parseAlternation()
  ├─ parseSequence()
  │   └─ parseTerm()
  │       ├─ parseAtom()
  │       └─ (quantifier, if present)
  └─ '|' parseSequence()
```

### 3. Bytecode (`src/bytecode/`)

**Purpose**: Define bytecode format and opcodes.

**Components**:
- `opcodes.zig`: Opcode enum and metadata
- `format.zig`: Bytecode layout and header
- `writer.zig`: Bytecode writing utilities
- `reader.zig`: Bytecode reading utilities

**Bytecode Format**: No fixed header — bytecode produced by `BytecodeWriter.finalize()` is
just a flat sequence of `[opcode][operands...]` instructions, terminated by a `MATCH`
opcode. There's no capture count, stack size, or length prefix stored alongside it (the
caller already knows the pattern's group count from parsing).

**Opcode Categories** (see `src/bytecode/opcodes.zig` for the authoritative, current list
of all 40 opcodes and their exact byte values): character matching (`CHAR`, `CHAR32`,
`CHAR2`, `CHAR_RANGE[_INV]`, `CHAR_CLASS[_INV]`, `CHAR_CLASS_RANGES[_INV]`,
`UNICODE_PROPERTY[_INV]` for `\p{...}`/`\P{...}`), control flow (`GOTO`, the `SPLIT*`
family), captures (`SAVE_START`/`SAVE_END`/`CLEAR_CAPTURE`), anchors (`LINE_START`/`LINE_END`,
`STRING_START`/`STRING_END`, word boundaries), lookaround
(`[NEGATIVE_]LOOKAHEAD[_END]`/`[NEGATIVE_]LOOKBEHIND[_END]`), and backreferences
(`BACK_REF[_I]`).

### 4. Executor (`src/executor/`)

**Purpose**: Interpret bytecode and find matches.

**Components**:
- `recursive_matcher.zig`: The matching engine — a recursive backtracker (an earlier
  Pike-VM/thread-based design, `vm.zig`, had an infinite-loop bug in alternation and has
  been removed)
- `thread.zig`: `Capture` (capture group start/end positions)
- `matcher.zig`: High-level matching interface (`find`, `findAll`, `matchFull`)

**Execution Model**: `RecursiveMatcher.matchFrom(pc, pos)` recursively tries to match the
bytecode starting at `pc` against the input starting at `pos`, returning as soon as it
finds a match or exhausts the alternatives at that point. There is no explicit backtrack
stack — Zig's native call stack *is* the backtrack stack, and capture group start/end
positions are restored implicitly by each recursive call returning its own `MatchResult`
(see `src/executor/recursive_matcher.zig`). An earlier design used an explicit
Pike-VM-style thread queue (`vm.zig`) instead of recursion; it had an infinite-loop bug in
alternation and was replaced.

**ReDoS Protection**: `RecursiveMatcher` counts recursive calls (`step_count`) and tracks
`recursion_depth`, returning `error.StepLimitExceeded` / `error.RecursionLimitExceeded`
once `ExecOptions.max_steps` / `max_recursion_depth` are hit (defaults: 1,000,000 steps,
1,000 depth) — this is what actually protects against catastrophic backtracking, not a
separate timeout mechanism.

### 5. Unicode (`src/unicode/`) — ⚠️ design only, not implemented

**Status**: `src/unicode/` currently contains only a README describing this design; none
of the files below exist yet. See [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) and
[ECMASCRIPT_COMPATIBILITY_PLAN.md](ECMASCRIPT_COMPATIBILITY_PLAN.md) (Phases 1/3/4) for the
current status and build plan. The design below is the intended target, not current state.

**Purpose**: Unicode support and character operations.

**Components**:
- `charrange.zig`: Efficient character range representation
- `properties.zig`: Unicode properties lookup
- `casefold.zig`: Case folding tables and logic
- `normalize.zig`: Unicode normalization
- `tables.zig`: Generated Unicode data tables

**CharRange Design**:
```zig
pub const CharRange = struct {
    // Sorted array of [start, end+1, start, end+1, ...]
    points: std.ArrayList(u32),

    pub fn addInterval(self: *CharRange, start: u32, end: u32) !void;
    pub fn union(self: *CharRange, other: CharRange) !void;
    pub fn intersect(self: *CharRange, other: CharRange) !void;
    pub fn subtract(self: *CharRange, other: CharRange) !void;
    pub fn invert(self: *CharRange) !void;
    pub fn contains(self: CharRange, ch: u32) bool;
};
```

**Unicode Property Support**:
- General Categories (Lu, Ll, Nd, etc.)
- Scripts (Latin, Greek, Cyrillic, etc.)
- Binary Properties (Alphabetic, Emoji, etc.)
- Derived Properties (ID_Start, ID_Continue)

**Data Generation**:
- Compile-time generation from UCD (Unicode Character Database)
- Compressed tables using ranges
- ~249KB of data (similar to libregexp)

**Case Folding**:
```
Simple:   'A' → 'a'
Full:     'ß' → "ss"
Turkic:   'I' → 'ı' (dotless)
```

### 6. Utils (`src/utils/`)

**Purpose**: Shared utilities.

**Components**:
- `dynbuf.zig`: Dynamic buffer (like C DynBuf)
- `bitset.zig`: Bit set operations
- `pool.zig`: Object pooling for performance
- `debug.zig`: Debug utilities and dumpers

**DynBuf** (ArrayList wrapper):
```zig
pub fn DynBuf(comptime T: type) type {
    return struct {
        list: std.ArrayList(T),

        pub fn init(allocator: Allocator) DynBuf(T);
        pub fn deinit(self: *DynBuf(T)) void;
        pub fn append(self: *DynBuf(T), item: T) !void;
        pub fn appendSlice(self: *DynBuf(T), items: []const T) !void;
    };
}
```

## Data Flow

### Compilation Flow

```
User Input
    ↓
"(\d+)-(\d+)"
    ↓
┌─────────────────┐
│     Parser      │  Tokenize and parse
└─────────────────┘
    ↓
AST:
  Sequence
    ├─ Capture(1)
    │   └─ Repeat(1+)
    │       └─ CharClass(\d)
    ├─ Char('-')
    └─ Capture(2)
        └─ Repeat(1+)
            └─ CharClass(\d)
    ↓
┌─────────────────┐
│   Validator     │  Check semantics
└─────────────────┘
    ↓
┌─────────────────┐
│    CodeGen      │  Emit bytecode
└─────────────────┘
    ↓
Bytecode:
  [SAVE_START, 1]
  [PUSH_I32, 1]
  [RANGE, [\d]]
  [LOOP, ...]
  [SAVE_END, 1]
  [CHAR, '-']
  [SAVE_START, 2]
  ...
    ↓
┌─────────────────┐
│   Optimizer     │  Optimize
└─────────────────┘
    ↓
Optimized Bytecode
    ↓
CompiledRegex
```

### Execution Flow

```
Input: "123-456"
    ↓
┌─────────────────┐
│       VM        │
└─────────────────┘
    ↓
PC=0, CP=0  [SAVE_START, 1]  → captures[0] = 0
PC=2, CP=0  [PUSH_I32, 1]    → push(1)
PC=8, CP=0  [RANGE, \d]      → match '1', CP=1
PC=8, CP=1  [LOOP]           → counter--, goto RANGE
PC=8, CP=1  [RANGE, \d]      → match '2', CP=2
PC=8, CP=2  [LOOP]           → counter--, goto RANGE
PC=8, CP=2  [RANGE, \d]      → match '3', CP=3
PC=8, CP=3  [LOOP]           → counter--, goto RANGE
PC=8, CP=3  [RANGE, \d]      → no match '-'
PC=..       [try next path]
    ↓
    ... continue matching ...
    ↓
PC=X, CP=7  [MATCH]          → SUCCESS!
    ↓
Match {
    start: 0,
    end: 7,
    captures: [
        (0, 3),  // "123"
        (4, 7),  // "456"
    ]
}
```

## Memory Management

### Allocation Strategy

1. **Compile Time**:
   - AST nodes: Allocate during parsing
   - Bytecode: Single allocation, grown as needed
   - Temporary buffers: Arena allocator

2. **Run Time**:
   - Compiled regex: Single allocation (immutable)
   - Execution stack: Reusable, grows if needed
   - Captures: Pre-allocated array (known size)
   - Match results: Allocated on success

### Ownership Model

```zig
// User owns compiled regex
const regex = try Regex.compile(allocator, pattern, .{});
defer regex.deinit();  // User must free

// Regex owns bytecode
regex.bytecode  // Freed by regex.deinit()

// Match owns captures
const match = try regex.exec(input, allocator);
defer if (match) |m| m.deinit();  // User must free
```

### Pool Optimization (Future)

```zig
// Reuse VMs across multiple executions
var pool = try VMPool.init(allocator, 4);
defer pool.deinit();

const vm = try pool.acquire();
defer pool.release(vm);

const match = try vm.exec(regex, input);
```

## Error Handling

### Error Hierarchy

Error sets are defined per-module and combined in `src/regex.zig`, rather than through a
central `CompileError`/`ExecError` split:

```zig
// src/parser/parser.zig
pub const ParseError = error{
    UnexpectedToken, UnexpectedEOF, UnmatchedParen, UnmatchedBracket,
    InvalidCharRange, EmptyCharClass, InvalidQuantifier, EmptyGroup,
    EmptyAlternation, OutOfMemory, InvalidEscape, InvalidRepeat, UnterminatedRepeat,
};

// src/codegen/generator.zig
pub const CodegenError = error{
    UnsupportedNode, InvalidPattern, TooManyGroups, OutOfMemory,
    BufferTooSmall, UnknownOpcode,
};

// src/regex.zig — the combined, public error set
pub const RegexError = ParseError || CodegenError || Allocator.Error || error{
    UnexpectedEndOfBytecode, UnknownOpcode, UnresolvedLabels,
    BufferTooSmall, RecursionLimitExceeded, StepLimitExceeded,
};
```

### Error Context

```zig
pub const CompileErrorContext = struct {
    position: usize,
    message: []const u8,
    pattern: []const u8,
};

// Usage
catch |err| {
    if (err == error.SyntaxError) {
        const ctx = compiler.errorContext();
        std.debug.print("Error at position {}: {s}\n",
            .{ctx.position, ctx.message});
        std.debug.print("  {s}\n", .{ctx.pattern});
        std.debug.print("  {s}^\n", .{" " ** ctx.position});
    }
}
```

## Testing Strategy

### Unit Tests

Each module has comprehensive unit tests:

```zig
// src/unicode/charrange.zig
test "CharRange: add interval" {
    var cr = CharRange.init(std.testing.allocator);
    defer cr.deinit();

    try cr.addInterval('a', 'z');
    try std.testing.expect(cr.contains('m'));
    try std.testing.expect(!cr.contains('A'));
}
```

### Integration Tests

End-to-end scenarios:

```zig
// tests/integration/basic.zig
test "simple pattern matching" {
    const regex = try Regex.compile(allocator, "hello", .{});
    defer regex.deinit();

    const match = try regex.exec("hello world", allocator);
    try std.testing.expect(match != null);
    try std.testing.expectEqual(@as(usize, 0), match.?.start);
    try std.testing.expectEqual(@as(usize, 5), match.?.end);
}
```

### Property-Based Tests

Fuzzing and property testing:

```zig
test "any compiled regex is valid bytecode" {
    var prng = std.rand.DefaultPrng.init(12345);
    const random = prng.random();

    for (0..1000) |_| {
        const pattern = generateRandomPattern(random);
        const result = Regex.compile(allocator, pattern, .{});

        if (result) |regex| {
            defer regex.deinit();
            // Validate bytecode structure
            try validateBytecode(regex.bytecode);
        } else |_| {
            // Compile errors are ok
        }
    }
}
```

### Benchmark Tests

Performance tracking:

```zig
// tests/benchmarks/matching.zig
test "benchmark: email regex" {
    const pattern = "[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}";
    const regex = try Regex.compile(allocator, pattern, .{});
    defer regex.deinit();

    var timer = try std.time.Timer.start();

    for (0..10000) |_| {
        _ = try regex.exec("test@example.com", allocator);
    }

    const elapsed = timer.read();
    std.debug.print("Email regex: {} ns/op\n", .{elapsed / 10000});
}
```

## Performance Considerations

### Hot Paths

1. **Character matching**: Most common operation
   - Inline comparison
   - Branch prediction friendly

2. **Backtrack stack**: Frequent push/pop
   - Static stack for common cases
   - Cache-friendly layout

3. **Unicode lookup**: Can be expensive
   - Binary search on ranges
   - Cache frequently used results

### Cold Paths

1. **Compilation**: Happens once
   - Clarity over micro-optimizations
   - Focus on error messages

2. **Unicode normalization**: Rare
   - Correct over fast
   - Can be lazy

### Memory Layout

`RecursiveMatcher` (`src/executor/recursive_matcher.zig`) holds the bytecode slice, the
input slice, a fixed-size `[MAX_CAPTURE_GROUPS]CaptureGroup` array, and small counters
(`recursion_depth`, `step_count`) — no separate heap-allocated stack, since Zig's call
stack fills that role.

## Future Enhancements

For the JS/ECMAScript compatibility gaps (named groups, Unicode property escapes, atomic
groups, etc.) and the phased plan to close them, see
[ECMASCRIPT_COMPATIBILITY_PLAN.md](ECMASCRIPT_COMPATIBILITY_PLAN.md). Possessive
quantifiers, listed as a future item in an earlier version of this document, are already
implemented (`*+`, `++`, `?+`).

Performance-oriented ideas not yet scheduled in that plan: JIT compilation, SIMD character
scanning, a lazy DFA for simple patterns.

---

**Last Updated**: 2026-07-04
**Status**: Living document — corrected against the current source tree for the Executor,
Unicode, Core, and Parser/Codegen sections above; verify against `src/` directly for
anything not covered by that pass.
