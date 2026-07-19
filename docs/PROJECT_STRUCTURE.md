# Project Structure

This document describes the organization of the zregex codebase.

> **Accuracy note**: this document was originally written before implementation began.
> The directory tree, module purpose/file lists, dependency diagram, build commands, and
> line counts below have been corrected against the current source tree (2026-07-04). A
> few small illustrative code snippets further down (e.g. in the Utils Module section)
> may still show simplified/original-design APIs rather than the exact current function
> signatures — check `src/` directly when precision matters.

## Directory Overview

```
zregex/
├── src/              # Source code
│   ├── core/         # Compile-time config flags (tiny)
│   ├── parser/        # Lexer, AST, recursive-descent parser
│   ├── codegen/       # AST -> bytecode generator, optimizer, compile() entry point
│   ├── executor/     # Recursive backtracking matcher
│   ├── bytecode/     # Opcode definitions and format
│   ├── unicode/      # Unicode support (design only, not implemented)
│   ├── utils/        # Shared utilities
│   ├── regex.zig     # High-level Regex API
│   ├── c_api.zig     # Exported C ABI -- internal FFI substrate for the conformance
│   │                 # harness (docs/ECMASCRIPT_COMPATIBILITY_PLAN.md Phase 8), not a
│   │                 # supported public C/C++ API (no headers/wrapper are shipped)
│   └── main.zig      # Public module entry point
├── tests/            # Integration tests
├── docs/             # Documentation
├── examples/         # Usage examples
├── build.zig         # Build configuration
├── README.md         # Project overview (English, primary)
├── README.es.md      # Project overview (Spanish translation)
├── LICENSE           # MIT license
└── CONTRIBUTING.md   # Contribution guidelines
```

## Source Code Organization (`src/`)

### Core Module (`src/core/`)

**Purpose**: Compile-time configuration flags. This is the entire module today — it's
much smaller than originally planned; there's no `types.zig`/`errors.zig`/`allocator.zig`.
`CompileOptions` (the equivalent of a "flags" type) lives in `src/codegen/compiler.zig`
instead, and error sets are defined per-module and combined into `RegexError` in
`src/regex.zig`.

**Files**:
- `config.zig` - Two compile-time booleans (`enable_execution_trace`,
  `panic_on_internal_error`), consumed by `src/utils/debug.zig`

**Dependencies**: None (foundation layer)

### Parser Module (`src/parser/`)

**Purpose**: Parse regex pattern strings into an AST.

**Files**:
- `lexer.zig` - Tokenizes the pattern string
- `ast.zig` - Abstract syntax tree node definitions
- `parser.zig` - Recursive descent parser (tokens → AST)
- `parser_tests.zig` - Module test entry point

**Dependencies**: none

### Codegen Module (`src/codegen/`)

**Purpose**: Generate bytecode from the AST, and drive the overall compile pipeline.

**Files**:
- `compiler.zig` - Top-level `compile()`/`compileSimple()` entry points and
  `CompileOptions` (`case_insensitive`, `multiline`, `dot_all`)
- `generator.zig` - AST → bytecode code generator
- `optimizer.zig` - Bytecode optimization passes
- `codegen_tests.zig` - Module test entry point

**Dependencies**: `parser`, `bytecode`

**Processing Pipeline**:
```
Pattern String → Lexer → Parser → AST → Generator → Bytecode
                                             ↓
                                        Optimizer
```

### Executor Module (`src/executor/`)

**Purpose**: Execute compiled bytecode to find matches.

**Files**:
- `recursive_matcher.zig` - The matching engine: a recursive backtracker. Zig's native
  call stack acts as the backtrack stack (no explicit stack data structure). An earlier
  Pike-VM/thread-based design (`vm.zig`) had an infinite-loop bug in alternation and has
  been removed.
- `thread.zig` - `Capture` (capture group start/end positions)
- `matcher.zig` - High-level matching interface (`find`, `findAll`, `matchFull`)
- `executor_tests.zig` - Module test entry point

**Dependencies**: `bytecode`

**Execution Model**:
```
Bytecode + Input → RecursiveMatcher (backtracking) → Match Result
                              ↓
                          Captures
```

### Bytecode Module (`src/bytecode/`)

**Purpose**: Define bytecode format and opcodes.

**Files**:
- `opcodes.zig` - Opcode enumeration and metadata
- `format.zig` - Bytecode layout specification
- `writer.zig` - Bytecode emission utilities
- `reader.zig` - Bytecode reading utilities
- `bytecode_tests.zig` - Module test entry point

**Key Components**: 34 opcodes (`CHAR`, `CHAR32`, `CHAR_RANGE[_INV]`, `CHAR_CLASS[_INV]`,
`GOTO`, `SPLIT*`, `SAVE_START`/`SAVE_END`, `LINE_START`/`LINE_END`,
`STRING_START`/`STRING_END`, `BACK_REF[_I]`, lookaround opcodes, ...) — see
`src/bytecode/opcodes.zig` for the authoritative, current list and exact byte values.

**Dependencies**: none

**Binary Format**: No fixed header. `BytecodeWriter.finalize()` produces a flat
`[opcode][operands...]` sequence terminated by `MATCH`.

### Unicode Module (`src/unicode/`) — ⚠️ design only, not implemented

**Status**: `src/unicode/` currently contains only a README describing this design; none
of the files below exist yet. See [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) and
[ECMASCRIPT_COMPATIBILITY_PLAN.md](ECMASCRIPT_COMPATIBILITY_PLAN.md) for current status.

**Purpose**: Unicode character operations and properties.

**Files**:
- `charrange.zig` - Efficient character range representation
- `properties.zig` - Unicode property lookup
- `casefold.zig` - Case folding tables and operations
- `normalize.zig` - Unicode normalization
- `tables.zig` - Generated Unicode data
- `tables_generated.zig` - Auto-generated (gitignored)
- `unicode_tests.zig` - Module test entry point

**Key Components**:
```zig
// Represents a set of character ranges
pub const CharRange = struct {
    points: []u32,  // [start, end+1, start, end+1, ...]
    pub fn contains(self: CharRange, ch: u32) bool;
    pub fn union(self: *CharRange, other: CharRange) !void;
};

// Unicode property lookup
pub fn hasProperty(ch: u32, property: Property) bool;
```

**Dependencies**: `core`

**Data Size**: ~249KB of Unicode tables

### Utils Module (`src/utils/`)

**Purpose**: Shared utility functions and data structures.

**Files**:
- `dynbuf.zig` - Dynamic buffer (generic wrapper over ArrayList)
- `bitset.zig` - Bit set for fast character lookups
- `pool.zig` - Object pooling for performance
- `debug.zig` - Debug utilities (dumpers, printers)
- `utils_tests.zig` - Module test entry point

**Key Components**:
```zig
// Generic dynamic buffer
pub fn DynBuf(comptime T: type) type {
    return struct {
        list: std.ArrayList(T),
        pub fn append(self: *@This(), item: T) !void;
    };
}

// Bit set for character ranges
pub const BitSet = struct {
    bits: []u64,
    pub fn set(self: *BitSet, index: usize) void;
    pub fn isSet(self: BitSet, index: usize) bool;
};
```

**Dependencies**: `core`

## Tests Organization (`tests/`)

### Unit Tests

**Purpose**: Test individual modules in isolation.

**Organization**: Tests are co-located with source as inline `test { ... }` blocks, and
each module has a `*_tests.zig` file that re-exports them (e.g. `src/parser/parser_tests.zig`,
`src/codegen/codegen_tests.zig`, `src/executor/executor_tests.zig`,
`src/bytecode/bytecode_tests.zig`, `src/utils/utils_tests.zig`); `src/main.zig`'s top-level
`test { }` block pulls all of them in via `std.testing.refAllDecls`.

### Integration Tests (`tests/`)

**Purpose**: Test full end-to-end scenarios through the public `zregex` module (as
opposed to the inline unit tests, which test internal modules directly).

**Files**:
- `integration_tests.zig` - The full integration suite (23 tests), run via
  `zig build test-integration`

## Documentation (`docs/`)

**Files** (non-exhaustive; see the directory for the full, current list):
- `ARCHITECTURE.md` - System design and architecture
- `ROADMAP.md` - Long-term development plan (aspirational; not all phases/dates reflect
  what actually shipped)
- `PROJECT_STRUCTURE.md` - This file
- `KNOWN_LIMITATIONS.md` - Verified, current list of what works and what doesn't
- `ECMASCRIPT_COMPATIBILITY_PLAN.md` - Phased plan toward full JS RegExp compatibility
- `CONCEPTS.md` - General regex engine background

## Examples (`examples/`)

**Purpose**: Usage examples for users.

**Files**:
- `basic_usage.zig` - Simple pattern matching, metacharacters, quantifiers, anchors
- `capture_groups.zig` - Working with capture groups (simple, multiple, nested, optional)
- `find_all.zig` - Finding all matches in a string
- `validation.zig` - Input validation use cases

**Build and run**:
```bash
zig build examples          # builds all examples into zig-out/bin/
./zig-out/bin/basic_usage
```

## Main Entry Point (`src/main.zig`)

The main entry point exports the public API. The high-level `Regex` type comes from
`regex.zig`, not from the parser or codegen modules directly:

```zig
// src/main.zig (abridged)
pub const Regex = @import("regex.zig").Regex;
pub const MatchResult = @import("executor/matcher.zig").MatchResult;
pub const CompileOptions = @import("codegen/compiler.zig").CompileOptions;
// ... plus lower-level building blocks (Lexer, Parser, CodeGenerator, ...)
// for anyone assembling their own pipeline instead of using Regex directly.

// Aggregates every module's tests so `zig build test` reaches all of them
test {
    std.testing.refAllDecls(@This());
    _ = @import("utils/utils_tests.zig");
    _ = @import("bytecode/bytecode_tests.zig");
    _ = @import("parser/parser_tests.zig");
    _ = @import("codegen/codegen_tests.zig");
    _ = @import("executor/executor_tests.zig");
    _ = @import("regex.zig");
}
```

## Build System (`build.zig`)

Defines build targets:
- `zig build` - Build the static and shared libraries and install headers
- `zig build test` - Run all tests (unit + integration)
- `zig build test-unit` - Run unit tests only
- `zig build test-integration` - Run integration tests only
- `zig build lib` - Build all libraries and install headers
- `zig build static` - Build the static library only
- `zig build shared` - Build the shared library only
- `zig build examples` - Build all examples into `zig-out/bin/`

## Module Dependencies

```
┌──────┐   ┌────────┐
│ core │   │ utils  │  (core has no deps; utils depends on core for config.zig)
└──────┘   └───┬────┘
               │
         ┌─────▼─────┐
         │ bytecode  │  (no deps)
         └─────┬─────┘
               │
      ┌────────┴────────┐
      │                 │
┌─────▼─────┐     ┌─────▼──────┐
│  parser   │     │  executor  │  (depends on bytecode only)
│(no deps)  │     └─────┬──────┘
└─────┬─────┘           │
      │                 │
┌─────▼─────┐           │
│  codegen  │           │
│ (parser + │           │
│ bytecode) │           │
└─────┬─────┘           │
      │                 │
      └────────┬────────┘
               │
          ┌────▼────┐
          │ regex.zig│  (public high-level API)
          └────┬────┘
               │
          ┌────▼────┐
          │ main.zig │  (public module entry point)
          └─────────┘
```

Note: `unicode/` isn't in this diagram — it has no implementation yet (see
[KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)), so nothing depends on it today.

## File Naming Conventions

- `snake_case.zig` - Source files
- `PascalCase` - Types and structs
- `camelCase` - Functions
- `SCREAMING_SNAKE_CASE` - Constants
- `*_tests.zig` - Test aggregation files
- `*_generated.zig` - Auto-generated files

## Line Count Targets

Actual line counts (2026-07-04, including inline tests):

```
src/parser/        ~2000 lines (lexer, ast, parser)
src/utils/         ~1950 lines
src/bytecode/      ~1470 lines
src/executor/      ~1430 lines (recursive_matcher, thread, matcher)
src/codegen/       ~1180 lines (compiler, generator, optimizer)
src/regex.zig      ~1400 lines (high-level API + tests)
src/c_api.zig      ~500 lines
src/main.zig       ~120 lines
src/unicode/       0 lines (design only — see status note above)
src/core/          ~4 lines

tests/             ~290 lines
examples/          ~680 lines
```

**Compare to libregexp**: 3,261 lines (single file)

## Code Organization Principles

1. **Separation of Concerns**: Each module has a single responsibility
2. **Minimal Dependencies**: Core has no deps, others depend on core
3. **Testability**: Each module independently testable
4. **Documentation**: Each module has README explaining purpose
5. **No Circular Deps**: Strict dependency hierarchy

## Adding New Modules

If adding a new module:

1. Create directory under `src/`
2. Add module exports to `src/main.zig`
3. Add test target to `build.zig`
4. Create `<module>_tests.zig` aggregator
5. Add to this document
6. Update dependency diagram

---

**Last Updated**: 2026-07-04
