# Contributing to zregexp

Thank you for your interest in contributing to zregexp! This document provides guidelines and information for contributors.

## Code of Conduct

We are committed to providing a welcoming and inclusive environment. Be respectful, constructive, and professional in all interactions.

## Getting Started

### Prerequisites

- **Zig 0.16.0** or later ([download](https://ziglang.org/download/))
- **Git** for version control
- A code editor with Zig support (VSCode + ZLS recommended)

### Setup Development Environment

```bash
# Clone the repository
git clone https://github.com/yourusername/zregexp.git
cd zregexp

# Verify Zig installation
zig version  # Should be 0.16.0 or later

# Run tests to ensure everything works
zig build test

# Check code formatting
zig fmt --check src/
```

### Development Tools

**Recommended VSCode Extensions**:
- Zig Language (by zigtools)
- Zig Language Server (ZLS)
- Error Lens

**Recommended Editor Settings**:
```json
{
  "zig.path": "zig",
  "zig.zls.enabled": true,
  "editor.formatOnSave": true,
  "[zig]": {
    "editor.defaultFormatter": "ziglang.vscode-zig"
  }
}
```

## How to Contribute

### Reporting Bugs

Before creating a bug report:
1. Check existing issues to avoid duplicates
2. Test with the latest version
3. Verify it's not a usage error

**Good Bug Report Includes**:
- Clear, descriptive title
- Minimal reproduction case
- Expected vs actual behavior
- Zig version and OS
- Relevant code snippets or test cases

**Example**:
```markdown
## Bug: Case-insensitive matching fails for Unicode

**Environment**:
- Zig version: 0.16.0
- OS: Ubuntu 22.04

**Reproduction**:
```zig
const regex = try Regex.compile(allocator, "café", .{ .ignore_case = true });
const match = try regex.exec("CAFÉ", allocator); // Returns null, should match
```

**Expected**: Match should succeed
**Actual**: No match found
```

### Suggesting Features

Feature requests are welcome! Please:
1. Check if it's already planned in [ROADMAP.md](docs/ROADMAP.md)
2. Explain the use case
3. Consider ECMAScript compatibility
4. Propose API if applicable

**Example**:
```markdown
## Feature Request: Possessive Quantifiers

**Motivation**:
Possessive quantifiers (*+, ++, ?+) can prevent backtracking and
improve performance for certain patterns.

**Proposed API**:
Pattern: `a++b` (possessive one-or-more)

**ECMAScript Status**:
Not in ECMAScript spec, but in PCRE/Java

**Alternative**:
Could be added in 2.0 as extension
```

### Submitting Pull Requests

#### Before You Start

1. **Discuss large changes**: Open an issue first for major features
2. **Check roadmap**: Ensure feature aligns with project goals
3. **One feature per PR**: Keep PRs focused and reviewable

#### PR Workflow

1. **Fork and create branch**:
   ```bash
   git checkout -b feature/my-feature
   # or
   git checkout -b fix/issue-123
   ```

2. **Make changes**:
   - Write clear, idiomatic Zig code
   - Follow project style (see Style Guide below)
   - Add tests for new functionality
   - Update documentation if needed

3. **Test thoroughly**:
   ```bash
   # Run all tests (unit + integration)
   zig build test

   # Check formatting
   zig fmt --check src/

   # Run specific module tests
   zig build test -- --filter "my test name"
   ```

4. **Commit with clear messages**:
   ```bash
   git commit -m "feat(compiler): add support for possessive quantifiers"
   ```

   **Commit Message Format**:
   ```
   <type>(<scope>): <subject>

   <body>

   <footer>
   ```

   **Types**: feat, fix, docs, style, refactor, perf, test, chore
   **Scopes**: compiler, executor, unicode, bytecode, core, utils

5. **Push and create PR**:
   ```bash
   git push origin feature/my-feature
   ```

   Then open PR on GitHub with:
   - Clear description of changes
   - Link to related issues
   - Screenshots/examples if applicable
   - Checklist of completed items

#### PR Checklist

- [ ] Code follows project style
- [ ] All tests pass (`zig build test`)
- [ ] New tests added for new functionality
- [ ] Documentation updated (if applicable)
- [ ] No merge conflicts with main
- [ ] Commit messages are clear
- [ ] PR description is complete

## Style Guide

### Code Style

**Follow Zig's standard style**:
- Use `zig fmt` for formatting (no exceptions)
- 4-space indentation (enforced by `zig fmt`)
- No trailing whitespace

**Naming Conventions**:
```zig
// Types: PascalCase
pub const RegexFlags = struct { ... };
pub const CompileError = error{ ... };

// Functions: camelCase
pub fn compile(allocator: Allocator, ...) !*CompiledRegex { ... }
fn parseAlternative(self: *Parser) !void { ... }

// Constants: snake_case or SCREAMING_SNAKE_CASE
const default_stack_size = 32;
const MAX_CAPTURES = 255;

// Variables: snake_case
var capture_count: u8 = 0;
const match_result = try regex.exec(input);
```

**File Organization**:
```zig
// 1. Imports
const std = @import("std");
const Allocator = std.mem.Allocator;

// 2. Public types
pub const MyType = struct { ... };

// 3. Public constants
pub const MY_CONSTANT = 42;

// 4. Public functions
pub fn myFunction() void { ... }

// 5. Private types
const PrivateType = struct { ... };

// 6. Private functions
fn helperFunction() void { ... }

// 7. Tests
test "MyType: basic functionality" {
    // ...
}
```

**Comments**:
```zig
// Use comments to explain WHY, not WHAT
// Good:
// Merge ranges to reduce lookup time during execution
fn optimizeRanges(ranges: []Range) void { ... }

// Bad:
// This function optimizes ranges
fn optimizeRanges(ranges: []Range) void { ... }

/// Use doc comments for public APIs
/// Compiles a regex pattern into bytecode.
/// Returns a CompiledRegex that must be freed with deinit().
pub fn compile(allocator: Allocator, pattern: []const u8) !*CompiledRegex { ... }
```

**Error Handling**:
```zig
// Prefer explicit error handling
pub fn parse() !void {
    const token = try self.nextToken();
    if (token.type != .lparen) {
        return error.ExpectedLeftParen;
    }
    // ...
}

// Use errdefer for cleanup
pub fn allocateThing(allocator: Allocator) !*Thing {
    const thing = try allocator.create(Thing);
    errdefer allocator.destroy(thing);

    thing.data = try allocator.alloc(u8, 100);
    return thing;
}
```

**Memory Management**:
```zig
// Always take allocator as parameter (no global allocators)
pub fn doWork(allocator: Allocator) !Result { ... }

// Document ownership
/// Caller owns the returned memory and must free it
pub fn allocateBuffer(allocator: Allocator) ![]u8 { ... }

/// Takes ownership of the provided buffer
pub fn consumeBuffer(buffer: []u8) void { ... }
```

### Testing Style

```zig
test "Module: specific functionality" {
    const allocator = std.testing.allocator;

    // Setup
    var thing = try Thing.init(allocator);
    defer thing.deinit();

    // Execute
    const result = try thing.doSomething();

    // Assert
    try std.testing.expectEqual(expected, result);
}

// Use descriptive test names
test "CharRange: union of overlapping ranges merges correctly" { ... }
test "Parser: unmatched closing paren returns error" { ... }
test "VM: backtracking restores captures correctly" { ... }
```

### Documentation Style

```zig
/// Brief one-line description.
///
/// Longer description with more details if needed.
/// Can span multiple lines.
///
/// Example:
/// ```zig
/// const regex = try Regex.compile(allocator, "\\d+", .{});
/// defer regex.deinit();
/// ```
///
/// Params:
///   - allocator: Memory allocator for regex internals
///   - pattern: Regex pattern string
///   - flags: Compilation flags
///
/// Returns: Compiled regex or error
///
/// Errors:
///   - error.SyntaxError: Invalid regex syntax
///   - error.OutOfMemory: Allocation failed
pub fn compile(
    allocator: Allocator,
    pattern: []const u8,
    flags: RegexFlags,
) CompileError!*CompiledRegex {
    // ...
}
```

## Module-Specific Guidelines

### Core Module (`src/core/`)

- Define shared types and errors
- No dependencies on other modules
- Keep it minimal and stable

### Compiler Module (`src/compiler/`)

- Parser must be spec-compliant (ECMAScript)
- Add references to spec sections in comments
- Optimize code generation, not parsing speed

### Executor Module (`src/executor/`)

- Optimize for speed (hot path)
- Inline small functions
- Profile before optimizing

### Unicode Module (`src/unicode/`)

- Always reference Unicode version (e.g., Unicode 15.0)
- Regenerate tables from UCD, don't hand-edit
- Document table generation process

### Bytecode Module (`src/bytecode/`)

- Keep opcode set stable
- Document binary format precisely
- Version bytecode format if changed

## Testing Guidelines

### Unit Tests

- Test each function independently
- Cover edge cases (empty, null, max values)
- Use descriptive test names
- One assertion per test (when possible)

### Integration Tests

- Test real-world scenarios
- Use actual regex patterns from the wild
- Test combinations of features

### Performance Tests

- Establish baseline
- Track performance over time
- Compare with competitors
- Document test patterns used

### Test Coverage

- Aim for 100% line coverage
- Don't test for coverage's sake
- Focus on meaningful tests

## Review Process

### What Reviewers Look For

1. **Correctness**: Does it work? Are there bugs?
2. **Tests**: Are there adequate tests?
3. **Style**: Does it follow project style?
4. **Performance**: Any performance regressions?
5. **Documentation**: Is it well-documented?
6. **Design**: Does it fit the architecture?

### Addressing Review Comments

- Be receptive to feedback
- Ask for clarification if needed
- Make requested changes or discuss alternatives
- Push updates to the same branch (PR updates automatically)

### Approval and Merge

- PRs need at least 1 approval
- All CI checks must pass
- Maintainer will merge (squash commits)

## Release Process (Maintainers)

1. Update version in `build.zig`
2. Update CHANGELOG.md
3. Create release tag: `git tag v1.0.0`
4. Push tag: `git push origin v1.0.0`
5. GitHub Actions builds release artifacts
6. Create GitHub release with notes

## Getting Help

- **Questions**: Open a discussion on GitHub
- **Chat**: (TBD - Discord/Matrix/IRC)
- **Email**: (TBD)

## Recognition

Contributors will be:
- Listed in CONTRIBUTORS.md
- Mentioned in release notes
- Credited in git history

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

---

**Thank you for contributing to zregexp!**

We appreciate your time and effort in making this project better.
