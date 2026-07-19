# zregex Development Roadmap

## Vision Statement

Create a production-ready ECMAScript regex engine in Zig that matches libregexp's quality (9/10) while providing modern safety guarantees, better maintainability, and competitive performance.

## Timeline Overview

```
Week 0-1:   Phase 0 - Project Setup
Week 2-3:   Phase 1 - Core Infrastructure
Week 4-6:   Phase 2 - Basic Compiler
Week 7-9:   Phase 3 - Basic Executor
Week 10-11: Phase 4 - Unicode Foundation
Week 12-14: Phase 5 - Advanced Compiler Features
Week 15-17: Phase 6 - Advanced Executor Features
Week 18-19: Phase 7 - Unicode Completion
Week 20-22: Phase 8 - Testing & Validation
Week 23-24: Phase 9 - Optimization & Polish
Week 25-26: Phase 10 - Release Preparation

Total: ~6 months (26 weeks) to 1.0.0
```

---

## Phase 0: Project Setup (Week 0-1)

**Goal**: Establish project foundation and tooling.

### Week 0: Repository & Documentation

**Tasks**:
- [x] Create repository structure
- [x] Write README.md
- [x] Write ARCHITECTURE.md
- [x] Write ROADMAP.md (this document)
- [ ] Create LICENSE (MIT)
- [ ] Create CONTRIBUTING.md
- [ ] Create .gitignore
- [ ] Create build.zig skeleton
- [ ] Set up CI/CD (GitHub Actions)

**Deliverables**:
- Public GitHub repository
- Complete documentation foundation
- Basic build system

### Week 1: Development Environment

**Tasks**:
- [ ] Set up development containers (Docker/devcontainer)
- [ ] Configure editor/IDE setup guides
- [ ] Create development scripts (format, lint, test)
- [ ] Set up code coverage tracking
- [ ] Create issue templates
- [ ] Create PR templates
- [ ] Design project logo/badges

**Deliverables**:
- Reproducible dev environment
- Contributor workflow established
- Project branding

---

## Phase 1: Core Infrastructure (Week 2-3)

**Goal**: Build foundational types and utilities.

### Week 2: Core Types & Errors

**Module**: `src/core/`

**Tasks**:
1. **types.zig**:
   - Define RegexFlags (packed struct)
   - Define Match and CaptureGroup types
   - Define CompiledRegex struct
   - Define buffer type enums

2. **errors.zig**:
   - Define CompileError set
   - Define ExecError set
   - Define error context structs
   - Implement error formatting helpers

3. **allocator.zig**:
   - Create allocator wrappers
   - Add allocation tracking (debug builds)
   - Implement arena allocator helpers

4. **config.zig**:
   - Define compile-time feature flags
   - Define size limits (captures, stack, etc.)
   - Create configuration validation

**Tests**:
- Unit tests for all types
- Error handling scenarios
- Allocator tracking validation

**Deliverables**:
- Complete `src/core/` module
- 100% test coverage
- Documentation for all public APIs

### Week 3: Utilities

**Module**: `src/utils/`

**Tasks**:
1. **dynbuf.zig**:
   - Generic DynBuf(T) implementation
   - Append, insert, remove operations
   - Efficient growth strategy

2. **bitset.zig**:
   - Bit set for fast character lookups
   - Set operations (union, intersect, etc.)

3. **pool.zig**:
   - Generic object pool
   - Thread-safe version (future)

4. **debug.zig**:
   - Bytecode dumper
   - AST printer
   - Debug logging helpers

**Tests**:
- DynBuf growth and edge cases
- BitSet operations correctness
- Pool acquire/release patterns

**Deliverables**:
- Complete `src/utils/` module
- Performance benchmarks for DynBuf
- Documentation

---

## Phase 2: Basic Compiler (Week 4-6)

**Goal**: Parse simple regex patterns and generate bytecode.

### Week 4: Bytecode Foundation

**Module**: `src/bytecode/`

**Tasks**:
1. **opcodes.zig**:
   - Define all 38 opcodes (enum)
   - Implement size() method
   - Create opcode metadata tables
   - Document each opcode

2. **format.zig**:
   - Define bytecode header structure
   - Implement header read/write
   - Define bytecode validation rules

3. **writer.zig**:
   - Implement BytecodeWriter
   - Add emit methods for each opcode
   - Add label/jump resolution

4. **reader.zig**:
   - Implement BytecodeReader
   - Add read methods for each opcode
   - Add validation during read

**Tests**:
- Write/read round-trip tests
- Header validation tests
- Invalid bytecode rejection

**Deliverables**:
- Complete bytecode subsystem
- Bytecode format specification document
- Validation test suite

### Week 5: Basic Parser

**Module**: `src/compiler/`

**Tasks**:
1. **parser.zig** (Phase 1):
   - Implement basic structure
   - Parse literal characters
   - Parse `.` (dot)
   - Parse `^` and `$` anchors
   - Parse `|` (alternation)
   - Parse `(...)` (groups)
   - Parse `*`, `+`, `?` (quantifiers)

2. **ast.zig**:
   - Define AST node types
   - Implement node creation/destruction
   - Add AST printing for debugging

**Patterns Supported**:
- `abc` - Literals
- `a.c` - Dot
- `^abc$` - Anchors
- `a|b` - Alternation
- `(abc)` - Groups
- `a*`, `a+`, `a?` - Basic quantifiers

**Tests**:
- Parse valid simple patterns
- Reject invalid syntax
- AST structure validation

**Deliverables**:
- Working parser for simple patterns
- AST representation
- Parser error messages

### Week 6: Basic Code Generation

**Module**: `src/compiler/`

**Tasks**:
1. **codegen.zig** (Phase 1):
   - Implement CodeGenerator
   - Generate opcodes for literals
   - Generate opcodes for alternation
   - Generate opcodes for groups
   - Generate opcodes for quantifiers
   - Implement jump resolution

2. **validator.zig** (Phase 1):
   - Basic syntax validation
   - Check balanced parentheses
   - Validate quantifier targets

**Patterns Compiled**:
- All patterns from Week 5
- Bytecode optimization (basic)

**Tests**:
- Compile and verify bytecode
- Test jump targets are correct
- Validate generated bytecode

**Deliverables**:
- End-to-end compilation for simple patterns
- Bytecode dumper for debugging
- Compilation test suite

---

## Phase 3: Basic Executor (Week 7-9)

**Goal**: Execute compiled bytecode and find matches.

### Week 7: VM Core

**Module**: `src/executor/`

**Tasks**:
1. **vm.zig**:
   - Implement VM structure
   - Implement fetch-decode-execute loop
   - Handle character matching opcodes
   - Handle anchor opcodes
   - Handle match opcode

2. **stack.zig**:
   - Implement execution stack
   - Stack growth/shrink logic
   - Stack element types

**Opcodes Implemented**:
- CHAR, CHAR_I
- DOT, ANY
- LINE_START, LINE_END
- MATCH

**Tests**:
- Execute simple patterns
- Verify match positions
- Stack operations

**Deliverables**:
- Working VM for simple patterns
- VM execution tests
- Performance baseline

### Week 8: Backtracking Engine

**Module**: `src/executor/`

**Tasks**:
1. **backtrack.zig**:
   - Implement backtrack stack
   - Handle SPLIT opcodes
   - Implement backtrack on failure
   - Add depth limiting

2. **vm.zig** (continued):
   - Handle GOTO opcode
   - Handle SPLIT_GOTO_FIRST
   - Handle SPLIT_NEXT_FIRST
   - Integrate backtracking

**Patterns Executed**:
- Alternation: `a|b|c`
- Optional: `a?b`
- Repetition: `a*b`, `a+b`

**Tests**:
- Backtracking correctness
- Performance tests (ReDoS patterns)
- Stack overflow protection

**Deliverables**:
- Full backtracking support
- ReDoS protection mechanisms
- Backtracking test suite

### Week 9: Captures & Match Results

**Module**: `src/executor/`

**Tasks**:
1. **captures.zig**:
   - Implement capture array
   - Handle SAVE_START/SAVE_END opcodes
   - Restore captures on backtrack

2. **matcher.zig**:
   - Implement high-level Match API
   - Extract capture groups
   - Build Match result objects

3. **vm.zig** (integration):
   - Integrate capture handling
   - Return Match on success

**API Completed**:
```zig
const match = try regex.exec(input, allocator);
if (match) |m| {
    const full = m.group(0);      // Full match
    const cap1 = m.group(1);      // First capture
}
```

**Tests**:
- Capture group extraction
- Nested captures
- Backtracking capture restoration

**Deliverables**:
- Complete basic matching API
- Capture group support
- Integration tests

---

## Phase 4: Unicode Foundation (Week 10-11)

**Goal**: Add Unicode support infrastructure.

### Week 10: CharRange

**Module**: `src/unicode/`

**Tasks**:
1. **charrange.zig**:
   - Implement CharRange structure
   - Add interval operations
   - Implement union/intersect/subtract
   - Implement invert operation
   - Add contains() lookup (binary search)

2. **Integration**:
   - Use CharRange in character classes
   - Update parser to build CharRange
   - Update executor to check CharRange

**Tests**:
- Range operations correctness
- Binary search performance
- Edge cases (empty, full, overlapping)

**Deliverables**:
- Complete CharRange implementation
- Character class support in parser
- Range matching in executor

### Week 11: Basic Unicode

**Module**: `src/unicode/`

**Tasks**:
1. **tables.zig**:
   - Define basic ASCII tables
   - Implement \d, \w, \s classes
   - Implement \D, \W, \S (inverted)

2. **casefold.zig**:
   - Implement ASCII case folding
   - Support /i flag for ASCII

3. **Parser integration**:
   - Parse `[a-z]`, `[^0-9]`
   - Parse `\d`, `\w`, `\s`
   - Generate RANGE opcodes

**Patterns Supported**:
- Character classes: `[a-z]`, `[0-9]`
- Negated classes: `[^a-z]`
- Shorthand classes: `\d`, `\w`, `\s`
- Case-insensitive: `/abc/i`

**Tests**:
- Character class matching
- Case-insensitive matching
- Unicode vs ASCII mode

**Deliverables**:
- ASCII-complete regex engine
- Character class support
- Case-insensitive mode

---

## Phase 5: Advanced Compiler Features (Week 12-14)

**Goal**: Complete compiler with all ECMAScript features.

### Week 12: Advanced Quantifiers & Assertions

**Module**: `src/compiler/`

**Tasks**:
1. **parser.zig** (Phase 2):
   - Parse `{n}`, `{n,}`, `{n,m}` quantifiers
   - Parse lazy quantifiers: `*?`, `+?`, `??`, `{n,m}?`
   - Parse `\b`, `\B` (word boundaries)
   - Parse lookahead: `(?=...)`, `(?!...)`
   - Parse lookbehind: `(?<=...)`, `(?<!...)`

2. **codegen.zig** (Phase 2):
   - Generate LOOP/PUSH_I32 for counted quantifiers
   - Generate greedy vs lazy split order
   - Generate WORD_BOUNDARY opcodes
   - Generate LOOKAHEAD opcodes

**Tests**:
- All quantifier variants
- Word boundary edge cases
- Lookahead/lookbehind correctness

**Deliverables**:
- Complete quantifier support
- Assertion support
- Lookaround support

### Week 13: Named Groups & Backreferences

**Module**: `src/compiler/`

**Tasks**:
1. **parser.zig** (Phase 3):
   - Parse `(?:...)` (non-capturing)
   - Parse `(?<name>...)` (named groups)
   - Parse `\1`, `\2` (numeric backreferences)
   - Parse `\k<name>` (named backreferences)
   - Track capture group names

2. **codegen.zig** (Phase 3):
   - Generate non-capturing groups
   - Store group names in bytecode
   - Generate BACK_REFERENCE opcodes
   - Validate backreference indices

**Tests**:
- Named group extraction
- Backreference matching
- Invalid backreference errors

**Deliverables**:
- Named capture groups
- Backreference support
- Group name metadata

### Week 14: Inline Modifiers & Optimization

**Module**: `src/compiler/`

**Tasks**:
1. **parser.zig** (Phase 4):
   - Parse `(?i:...)` (inline ignore-case)
   - Parse `(?m:...)` (inline multiline)
   - Parse `(?s:...)` (inline dotall)
   - Parse `(?-i:...)` (remove modifiers)

2. **optimizer.zig**:
   - Merge consecutive character matches
   - Constant fold character classes
   - Dead code elimination
   - Jump threading

3. **validator.zig** (Phase 2):
   - Validate backreferences exist
   - Check for invalid constructs
   - Warn about performance issues

**Tests**:
- Inline modifier scoping
- Optimization correctness
- Validation catches errors

**Deliverables**:
- Complete ECMAScript parser
- Bytecode optimizer
- Compiler warnings system

---

## Phase 6: Advanced Executor Features (Week 15-17)

**Goal**: Complete executor with all opcode support.

### Week 15: Advanced Opcodes

**Module**: `src/executor/`

**Tasks**:
1. **vm.zig** (advanced opcodes):
   - Implement LOOP/PUSH_I32 (counted quantifiers)
   - Implement WORD_BOUNDARY opcodes
   - Implement LOOKAHEAD opcodes
   - Implement BACK_REFERENCE opcodes
   - Implement PREV (backward movement)

2. **backtrack.zig** (enhancements):
   - Lookahead state management
   - Lookbehind execution
   - Backreference caching

**Tests**:
- All advanced opcodes
- Edge cases for each
- Performance benchmarks

**Deliverables**:
- Complete opcode implementation
- All ECMAScript features working
- Comprehensive test suite

### Week 16: Performance & Safety

**Module**: `src/executor/`

**Tasks**:
1. **Timeout mechanism**:
   - Implement interrupt counter
   - Add timeout parameter to exec()
   - Return Timeout error cleanly

2. **Stack management**:
   - Implement static stack (32 elements)
   - Dynamic growth when needed
   - Stack overflow protection

3. **Memory optimization**:
   - Reuse VM across executions
   - Pool allocator for hot paths
   - Reduce allocations

**Tests**:
- Timeout on ReDoS patterns
- Stack overflow protection
- Memory leak detection

**Deliverables**:
- Production-ready executor
- ReDoS protection
- Performance optimizations

### Week 17: Match API Completion

**Module**: `src/executor/`

**Tasks**:
1. **Extended Match API**:
   - Implement `matchAll()` (find all matches)
   - Implement `replace()` (with substitutions)
   - Implement `split()` (split on pattern)
   - Support named capture access: `m.group("name")`

2. **Iterator API**:
   - Implement MatchIterator
   - Lazy evaluation of matches
   - Memory-efficient streaming

**API Examples**:
```zig
// Find all matches
var iter = try regex.matchAll(input, allocator);
while (try iter.next()) |match| {
    // process match
}

// Replace
const result = try regex.replace(input, "replacement", allocator);

// Split
const parts = try regex.split(input, allocator);
```

**Tests**:
- All API methods
- Edge cases (no matches, empty, etc.)
- Memory safety

**Deliverables**:
- Complete public API
- Comprehensive documentation
- API examples

---

## Phase 7: Unicode Completion (Week 18-19)

**Goal**: Full Unicode support.

### Week 18: Unicode Properties

**Module**: `src/unicode/`

**Tasks**:
1. **properties.zig**:
   - Implement General Categories (Lu, Ll, Nd, etc.)
   - Implement Scripts (Latin, Greek, etc.)
   - Implement Binary Properties (Alphabetic, Emoji)
   - Generate from UCD (Unicode Character Database)

2. **Parser integration**:
   - Parse `\p{Letter}`, `\p{Script=Greek}`
   - Parse `\P{...}` (negated properties)
   - Validate property names

3. **tables.zig** (generation):
   - Create comptime generator from UCD
   - Compress ranges efficiently
   - Generate ~249KB of tables

**Tests**:
- All property categories
- Unicode version consistency
- Property negation

**Deliverables**:
- Complete Unicode properties
- UCD data generator
- Property lookup performance

### Week 19: Case Folding & Normalization

**Module**: `src/unicode/`

**Tasks**:
1. **casefold.zig** (full):
   - Implement full Unicode case folding
   - Handle special cases (ß → ss, etc.)
   - Support /u flag semantics

2. **normalize.zig**:
   - Implement NFC normalization
   - Implement NFD normalization
   - Implement NFKC/NFKD (if needed)

3. **Executor integration**:
   - UTF-8 character iteration
   - UTF-16 support (with surrogates)
   - Case-insensitive Unicode matching

**Tests**:
- Unicode case folding correctness
- Normalization forms
- Multi-byte character handling

**Deliverables**:
- Full Unicode support
- /u flag compliance
- /v flag (Unicode Sets) foundation

---

## Phase 8: Testing & Validation (Week 20-22)

**Goal**: Ensure correctness and ECMAScript compliance.

### Week 20: Test Suite Development

**Tasks**:
1. **Unit test completion**:
   - Ensure 100% coverage of all modules
   - Add edge case tests
   - Add fuzz test targets

2. **Integration tests**:
   - Real-world regex patterns
   - Complex nested structures
   - Performance stress tests

3. **Test organization**:
   - Organize by feature category
   - Document test intent
   - Create test data generators

**Deliverables**:
- Comprehensive test suite
- Test coverage report
- Fuzzing infrastructure

### Week 21: Test262 Integration

**Tasks**:
1. **Test262 runner**:
   - Implement Test262 harness
   - Parse .js test files
   - Run regex tests
   - Generate compliance report

2. **Fix failures**:
   - Identify failing tests
   - Fix bugs in implementation
   - Document any spec deviations

3. **Regression tests**:
   - Add tests for all bugs found
   - Create regression test suite

**Goal**: 95%+ Test262 regex pass rate

**Deliverables**:
- Test262 integration
- Compliance report
- Bug fixes

### Week 22: Fuzzing & Property Testing

**Tasks**:
1. **Fuzzing setup**:
   - Integrate with AFL/libFuzzer
   - Create fuzzing targets
   - Set up continuous fuzzing

2. **Property-based tests**:
   - Generate random valid patterns
   - Verify invariants hold
   - Compare with reference implementation

3. **Differential testing**:
   - Compare with JavaScript engines (Node, Deno)
   - Compare with PCRE2
   - Document differences

**Deliverables**:
- Fuzzing infrastructure
- Property test suite
- Differential testing results

---

## Phase 9: Optimization & Polish (Week 23-24)

**Goal**: Performance optimization and API refinement.

### Week 23: Performance Optimization

**Tasks**:
1. **Profiling**:
   - Profile compilation
   - Profile execution
   - Identify hot spots

2. **Optimizations**:
   - Inline hot paths
   - Reduce allocations
   - Optimize CharRange lookup
   - Cache Unicode property checks

3. **Benchmarking**:
   - Create comprehensive benchmark suite
   - Compare with competitors
   - Track performance over time

**Targets**:
- Compilation: < 1ms for typical patterns
- Execution: Within 2x of RE2 for linear patterns
- Memory: Minimal overhead

**Deliverables**:
- Performance optimizations
- Benchmark suite
- Performance report

### Week 24: API Polish & Documentation

**Tasks**:
1. **API review**:
   - Review all public APIs
   - Ensure consistency
   - Add convenience methods

2. **Documentation**:
   - Complete API documentation
   - Write user guide
   - Create tutorial
   - Add more examples

3. **Error messages**:
   - Improve error messages
   - Add helpful suggestions
   - Better error formatting

**Deliverables**:
- Polished API
- Complete documentation
- User guide

---

## Phase 10: Release Preparation (Week 25-26)

**Goal**: Prepare for 1.0.0 release.

### Week 25: Release Engineering

**Tasks**:
1. **Version 1.0.0-rc1**:
   - Freeze features
   - Complete all docs
   - Final test pass

2. **Release artifacts**:
   - Build for all targets
   - Create release notes
   - Generate changelog

3. **Package repository**:
   - Publish to package manager (if applicable)
   - Set up version tags
   - Create release branch

**Deliverables**:
- Release candidate
- Release documentation
- Distribution packages

### Week 26: Launch & Maintenance

**Tasks**:
1. **Public release**:
   - Announce 1.0.0
   - Write blog post
   - Social media promotion

2. **Maintenance plan**:
   - Set up issue triage
   - Define support policy
   - Plan future roadmap

3. **Community**:
   - Encourage contributions
   - Respond to early issues
   - Build community

**Deliverables**:
- 1.0.0 release
- Launch announcement
- Maintenance plan

---

## Success Criteria

### Functional Requirements

- ✅ Complete ECMAScript regex compliance
- ✅ Full Unicode support (Scripts, Properties, Case Folding)
- ✅ All flags: /g, /i, /m, /s, /u, /y, /d, /v
- ✅ Named captures and backreferences
- ✅ Lookahead and lookbehind

### Quality Requirements

- ✅ 95%+ Test262 pass rate
- ✅ 100% code coverage (unit tests)
- ✅ Zero memory leaks (valgrind clean)
- ✅ No undefined behavior
- ✅ Comprehensive documentation

### Performance Requirements

- ✅ Compilation: < 1ms for typical patterns
- ✅ Execution: Competitive with established engines
- ✅ Memory: Minimal allocations
- ✅ Binary size: < 200KB

### Safety Requirements

- ✅ ReDoS protection (timeout, depth limits)
- ✅ Stack overflow protection
- ✅ Memory safety (no crashes)
- ✅ Clear error messages

---

## Post-1.0 Roadmap

### Version 1.1 (Performance)
- JIT compilation (x86_64)
- SIMD character scanning
- Lazy DFA for simple patterns
- Compiled character classes

### Version 1.2 (Features)
- Possessive quantifiers: `*+`, `++`
- Atomic groups: `(?>...)`
- Conditional expressions: `(?(1)yes|no)`

### Version 2.0 (Advanced)
- Multiple regex engine backends (NFA/DFA/hybrid)
- Full JIT (all platforms)
- Regex composition and reuse
- Advanced debugging tools

---

## Risk Assessment

### High Priority Risks

1. **Test262 Compliance**
   - Risk: May uncover spec edge cases
   - Mitigation: Early Test262 integration, iterative fixes

2. **Performance vs libregexp**
   - Risk: Zig version may be slower initially
   - Mitigation: Profile early, optimize incrementally

3. **Unicode Table Size**
   - Risk: 249KB may be too large for some use cases
   - Mitigation: Make tables optional/lazy-load

### Medium Priority Risks

1. **Zig 0.15 Stability**
   - Risk: Language may change during development
   - Mitigation: Pin version, track upstream

2. **ReDoS Protection**
   - Risk: Hard to get right without formal verification
   - Mitigation: Extensive fuzzing, literature review

### Low Priority Risks

1. **Community Adoption**
   - Risk: Limited Zig ecosystem
   - Mitigation: Excellent docs, C ABI support

---

## Resource Requirements

### Development Team
- 1-2 developers (full-time equivalent)
- Skills: Zig, parsers, VMs, Unicode

### Infrastructure
- GitHub repository (free)
- CI/CD (GitHub Actions, free)
- Test262 suite (public)
- Fuzzing infrastructure (OSS-Fuzz if accepted)

### Time
- ~6 months to 1.0.0
- ~1-2 hours/day for maintenance post-1.0

---

## Conclusion

This roadmap provides a clear, achievable path to building a world-class regex engine in Zig. By following libregexp's proven design while leveraging Zig's modern features, we can create something that matches the original's quality while providing better safety and maintainability.

**Estimated Effort**: 520-780 hours (13-26 weeks × 20-30 hours/week)
**Success Probability**: High (proven design, clear path)
**Value**: High (fills gap in Zig ecosystem)

---

**Document Version**: 1.0
**Last Updated**: 2025-11-26
**Next Review**: Start of each phase
