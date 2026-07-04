# Project Structure

This document describes the organization of the zregexp codebase.

## Directory Overview

```
zregexp/
├── src/              # Source code
│   ├── core/         # Core types and utilities
│   ├── compiler/     # Regex parser and code generator
│   ├── executor/     # Bytecode interpreter
│   ├── bytecode/     # Opcode definitions and format
│   ├── unicode/      # Unicode support
│   └── utils/        # Shared utilities
├── tests/            # Test suite
│   ├── unit/         # Unit tests
│   ├── integration/  # Integration tests
│   └── benchmarks/   # Performance benchmarks
├── docs/             # Documentation
├── examples/         # Usage examples
├── build.zig         # Build configuration
├── README.md         # Project overview
├── LICENSE           # MIT license
└── CONTRIBUTING.md   # Contribution guidelines
```

## Source Code Organization (`src/`)

### Core Module (`src/core/`)

**Purpose**: Foundation types used throughout the project.

**Files**:
- `types.zig` - Common types (RegexFlags, Match, CaptureGroup)
- `errors.zig` - Error definitions (CompileError, ExecError)
- `allocator.zig` - Allocator utilities
- `config.zig` - Compile-time configuration
- `core_tests.zig` - Module test entry point

**Key Types**:
```zig
// Regex compilation flags
pub const RegexFlags = packed struct {
    global: bool,
    ignore_case: bool,
    multiline: bool,
    dotall: bool,
    unicode: bool,
    sticky: bool,
    indices: bool,
    unicode_sets: bool,
};

// Match result
pub const Match = struct {
    start: usize,
    end: usize,
    captures: []?CaptureGroup,
};
```

**Dependencies**: None (foundation layer)

### Compiler Module (`src/compiler/`)

**Purpose**: Parse regex patterns and generate bytecode.

**Files**:
- `parser.zig` - Recursive descent parser
- `ast.zig` - Abstract syntax tree definitions
- `codegen.zig` - Bytecode code generator
- `optimizer.zig` - Bytecode optimization passes
- `validator.zig` - Semantic validation
- `compiler_tests.zig` - Module test entry point

**Key Components**:
```zig
// Parser converts pattern string to AST
pub const Parser = struct {
    pub fn parse(pattern: []const u8) !*AST;
};

// CodeGen converts AST to bytecode
pub const CodeGen = struct {
    pub fn generate(ast: *AST) ![]u8;
};
```

**Dependencies**: `core`, `bytecode`, `unicode`

**Processing Pipeline**:
```
Pattern String → Parser → AST → Validator → CodeGen → Bytecode
                                                 ↓
                                            Optimizer
```

### Executor Module (`src/executor/`)

**Purpose**: Execute compiled bytecode to find matches.

**Files**:
- `vm.zig` - Virtual machine core
- `backtrack.zig` - Backtracking engine
- `stack.zig` - Execution stack management
- `captures.zig` - Capture group handling
- `matcher.zig` - High-level matching interface
- `executor_tests.zig` - Module test entry point

**Key Components**:
```zig
// Virtual machine executes bytecode
pub const VM = struct {
    pub fn exec(bytecode: []const u8, input: []const u8) !?Match;
};

// Backtracking state management
pub const BacktrackEngine = struct {
    pub fn push(state: BacktrackState) !void;
    pub fn pop() ?BacktrackState;
};
```

**Dependencies**: `core`, `bytecode`, `unicode`

**Execution Model**:
```
Bytecode + Input → VM → Backtracking → Match Result
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

**Key Components**:
```zig
// All 38 opcodes
pub const Opcode = enum(u8) {
    char = 0x01,
    char32 = 0x02,
    // ... 36 more
};

// Bytecode header format
pub const Header = struct {
    flags: u16,
    capture_count: u8,
    stack_size: u8,
    bytecode_len: u32,
};
```

**Dependencies**: `core`

**Binary Format**:
```
[Header: 8 bytes]
[Opcodes: variable length]
[Named Groups: optional]
```

### Unicode Module (`src/unicode/`)

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

### Unit Tests (`tests/unit/`)

**Purpose**: Test individual modules in isolation.

**Organization**: Tests are co-located with source:
- `src/core/core_tests.zig` - Re-exports all core tests
- `src/compiler/compiler_tests.zig` - Re-exports all compiler tests
- etc.

Each `.zig` file has its own tests:
```zig
// src/core/types.zig
test "RegexFlags: default values" {
    const flags = RegexFlags{};
    try std.testing.expect(!flags.global);
}
```

### Integration Tests (`tests/integration/`)

**Purpose**: Test full end-to-end scenarios.

**Files**:
- `main.zig` - Test runner
- `basic.zig` - Basic pattern matching
- `captures.zig` - Capture group tests
- `unicode.zig` - Unicode tests
- `performance.zig` - Performance regression tests
- `test262/` - ECMAScript test262 suite

**Example**:
```zig
test "integration: email regex" {
    const pattern = "[a-z0-9]+@[a-z0-9]+\\.[a-z]+";
    const regex = try Regex.compile(allocator, pattern, .{});
    defer regex.deinit();

    const result = try regex.exec("test@example.com", allocator);
    try std.testing.expect(result != null);
}
```

### Benchmarks (`tests/benchmarks/`)

**Purpose**: Track performance over time.

**Files**:
- `main.zig` - Benchmark runner
- `compilation.zig` - Compilation speed benchmarks
- `execution.zig` - Execution speed benchmarks
- `memory.zig` - Memory usage benchmarks
- `comparison.zig` - Comparison with other engines

**Output**: JSON results for tracking over time

## Documentation (`docs/`)

**Files**:
- `ARCHITECTURE.md` - System design and architecture
- `ROADMAP.md` - Development timeline and milestones
- `PROJECT_STRUCTURE.md` - This file
- `API.md` - Public API documentation
- `BYTECODE.md` - Bytecode format specification
- `UNICODE.md` - Unicode support details
- `PERFORMANCE.md` - Performance characteristics

## Examples (`examples/`)

**Purpose**: Usage examples for users.

**Files**:
- `basic.zig` - Simple pattern matching
- `captures.zig` - Working with capture groups
- `unicode.zig` - Unicode features
- `advanced.zig` - Advanced features (lookahead, etc.)
- `cinterop.zig` - Using from C code

**Each example is runnable** (no dedicated build step exists yet; compile manually):
```bash
cd examples
zig build-exe basic_usage.zig --dep zregexp --mod zregexp:../src/main.zig
./basic_usage
```

## Main Entry Point (`src/main.zig`)

The main entry point exports the public API:

```zig
// src/main.zig
pub const Regex = @import("compiler/parser.zig").Regex;
pub const Match = @import("core/types.zig").Match;
pub const RegexFlags = @import("core/types.zig").RegexFlags;
pub const CompileError = @import("core/errors.zig").CompileError;
// ... other public exports

// For testing
test {
    _ = @import("core/core_tests.zig");
    _ = @import("compiler/compiler_tests.zig");
    _ = @import("executor/executor_tests.zig");
    _ = @import("unicode/unicode_tests.zig");
    _ = @import("bytecode/bytecode_tests.zig");
    _ = @import("utils/utils_tests.zig");
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

## Module Dependencies

```
         ┌─────────┐
         │  core   │  (no dependencies)
         └────┬────┘
              │
    ┌─────────┼─────────┬─────────┐
    │         │         │         │
┌───▼───┐ ┌──▼──┐  ┌───▼───┐ ┌───▼───┐
│ utils │ │ b.c.│  │unicode│ │executor│
└───┬───┘ └──┬──┘  └───┬───┘ └───┬───┘
    │        │         │         │
    └────┬───┴─────────┴─────┬───┘
         │                   │
      ┌──▼────┐          ┌───▼───┐
      │ comp. │          │ exec. │
      └───┬───┘          └───┬───┘
          │                  │
          └────────┬─────────┘
                   │
              ┌────▼────┐
              │  main   │  (public API)
              └─────────┘

Legend:
  b.c.  = bytecode
  comp. = compiler
  exec. = executor
```

## File Naming Conventions

- `snake_case.zig` - Source files
- `PascalCase` - Types and structs
- `camelCase` - Functions
- `SCREAMING_SNAKE_CASE` - Constants
- `*_tests.zig` - Test aggregation files
- `*_generated.zig` - Auto-generated files

## Line Count Targets

Rough size estimates for each module:

```
src/core/          ~300 lines
src/bytecode/      ~400 lines
src/utils/         ~500 lines
src/unicode/       ~1500 lines (+ 249KB tables)
src/compiler/      ~2500 lines
src/executor/      ~2000 lines
src/main.zig       ~100 lines
Total:             ~7300 lines + tables

tests/             ~3000 lines
examples/          ~500 lines
docs/              ~5000 lines
```

**Compare to libregexp**: 3,261 lines (single file)
**Our approach**: ~7,300 lines (modular, with more documentation)

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

**Last Updated**: 2025-11-26
**Document Version**: 1.0
