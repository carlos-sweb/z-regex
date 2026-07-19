# zregex - Modern Regular Expression Engine for Zig

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-402%2F402-brightgreen)](#)
[![Zig](https://img.shields.io/badge/zig-0.16.0-orange)](https://ziglang.org/)

[🇪🇸 Versión en Español](README.es.md)

A powerful, feature-rich regular expression engine written in Zig with JavaScript-like syntax and ReDoS protection.

## ✨ Features

- **🚀 High Performance**: Bytecode-based virtual machine with optimized execution
- **🛡️ ReDoS Protection**: Built-in recursion depth and step limits to prevent catastrophic backtracking
- **📝 JavaScript-Compatible Syntax**: 168/168 (100%) pass rate on a heuristically-extracted test262 conformance sample (`zig build test-conformance`) — a real but biased/small measurement, not a full conformance percentage; see [Known Limitations](docs/KNOWN_LIMITATIONS.md) for the verified feature-by-feature breakdown, and the [ECMAScript Compatibility Plan](docs/ECMASCRIPT_COMPATIBILITY_PLAN.md) for the path to 100%
- **🔧 Zero Dependencies**: Pure Zig implementation
- **✅ Well Tested**: 402 comprehensive tests ensuring reliability

## 🎯 Supported Features

### Assertions (100% JS Compatible)
- ✅ `(?=...)` Positive lookahead
- ✅ `(?!...)` Negative lookahead
- ✅ `(?<=...)` Positive lookbehind
- ✅ `(?<!...)` Negative lookbehind

### Groups (100% JS Compatible)
- ✅ `(...)` Capturing groups
- ✅ `(?:...)` Non-capturing groups
- ✅ `\1` to `\9` Backreferences
- ✅ `(?<name>...)` Named capturing groups
- ✅ `\k<name>` Named backreferences

### Quantifiers (100% JS Compatible + Extensions)
- ✅ `*`, `+`, `?` Basic quantifiers
- ✅ `*?`, `+?`, `??` Lazy quantifiers
- ✅ `{n}`, `{n,}`, `{n,m}` Counted quantifiers
- ✅ `{n}?`, `{n,}?`, `{n,m}?` Lazy counted quantifiers
- ✅ `*+`, `++`, `?+` Possessive quantifiers (extension)

### Character Classes
- ✅ `[abc]`, `[^abc]` Character sets
- ✅ `[a-z]`, `[A-Z0-9]` Character ranges
- ✅ `[*&$.^+?(){}|]` Regex metacharacters as literals inside a class
- ✅ `[a-c\d]` Shorthand classes (`\d`/`\w`/`\s`/`\D`/`\W`/`\S`) as class members
- ✅ `[^]` Negated empty class ("match anything", including newline)
- ✅ `.` Any character (except newline)
- ✅ `\d`, `\D` Digits / non-digits
- ✅ `\w`, `\W` Word characters / non-word
- ✅ `\s`, `\S` Whitespace / non-whitespace
- ✅ `\p{L}`, `\p{Lu}`, `\p{Letter}`, `\P{L}`, ... Unicode General_Category property escapes
- ✅ `\p{White_Space}`, `\p{Alphabetic}`, `\p{Math}`, `\p{Dash}`, `\p{Hex_Digit}`, `\p{ID_Start}`, `\p{Emoji}`, `\p{ASCII}`, `\p{Any}`, `\p{Bidi_Mirrored}`, `\p{Assigned}`, and 39 more (50 total, see [Known Limitations](docs/KNOWN_LIMITATIONS.md)) Unicode binary property escapes
- ✅ `\p{Script=Greek}`, `\p{sc=Han}`, `\p{Script=Latin}`, `\p{Script=Grek}` (short alias), ... (all 174 Unicode scripts + short aliases) Unicode Script property escapes
- ✅ `\p{Script_Extensions=Latin}`, `\p{scx=Grek}`, ... Unicode Script_Extensions property escapes (broader per-codepoint membership than plain Script, e.g. combining accents)
- ✅ `[\p{L}\d]`, `[\P{Alphabetic}a-z]`, `[^\p{L}\d]` `\p{...}`/`\P{...}` as a character-class member (General_Category, binary property, Script, or Script_Extensions; up to 4 per class)
- ✅ `[A--B]`, `[A&&B]` (with `CompileOptions.v`) Character-class set operations — difference and intersection, one per class (`[\p{L}--[aeiou]]`, `[[a-z]&&[^x]]`)

### Anchors
- ✅ `^` Start of string
- ✅ `$` End of string
- ✅ `\b` Word boundary
- ✅ `\B` Non-word boundary

## 📦 Installation

### Using as a Zig Library

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zregex = .{
        .url = "https://github.com/yourusername/zregex/archive/refs/tags/v1.0.0.tar.gz",
        .hash = "...",
    },
},
```

In your `build.zig`:

```zig
const zregex = b.dependency("zregex", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zregex", zregex.module("zregex"));
```

> **Note on C/C++**: zregex is a Zig-first library and doesn't ship a supported C/C++
> API (no headers, no wrapper library, no build artifacts for external linking). It does
> export a plain C ABI (`src/c_api.zig`, built as a shared library via `zig build shared`)
> that the project's own tooling drives via FFI — see
> [`ECMASCRIPT_COMPATIBILITY_PLAN.md`](docs/ECMASCRIPT_COMPATIBILITY_PLAN.md) Phase 8. If
> you want to call zregex from C or C++, you're welcome to write your own bindings
> against those exported symbols; none are provided or maintained here.

## 🚀 Quick Start

### Zig Example

```zig
const std = @import("std");
const regex = @import("zregex");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Compile a regex pattern
    var re = try regex.Regex.compile(allocator, "hello (world)");
    defer re.deinit();

    // Find a match
    const text = "hello world";
    const result = try re.find(text);
    if (result) |match| {
        defer match.deinit();

        std.debug.print("Match: {s}\n", .{match.group(text)});
        std.debug.print("Group 1: {s}\n", .{match.getCapture(1, text).?});
    }
}
```

## 📚 API Documentation

### Zig API

#### `Regex.compile(allocator, pattern) !Regex`
Compiles a regex pattern.

**Parameters:**
- `allocator`: Memory allocator
- `pattern`: Regex pattern string

**Returns:** Compiled `Regex` object

**Example:**
```zig
var re = try Regex.compile(allocator, "\\d{3}-\\d{3}-\\d{4}");
defer re.deinit();
```

#### `regex.find(input) !?MatchResult`
Finds the first match in the input string.

**Parameters:**
- `input`: String to search

**Returns:** `MatchResult` if found, `null` otherwise

#### `regex.findAll(input) !std.ArrayListUnmanaged(MatchResult)`
Finds all matches in the input string.

#### `MatchResult` methods
- `match.group(input) []const u8` — the full matched substring
- `match.getCapture(index, input) ?[]const u8` — capture group by number (1-based)
- `match.getNamedCapture(name, input) ?[]const u8` — capture group by name, for
  `(?<name>...)` groups; returns `null` for unknown names or patterns with no named groups

#### `regex.test_(input) !bool`
Tests whether the pattern matches the **entire** input string (anchored full match, not substring search — use `find`/`findAll` for substring matching).

#### `regex.replace(allocator, input, replacement) ![]u8`
Replaces the first match with `replacement` (like JS `String.prototype.replace` with a non-global regex). Returns a newly allocated string (a copy of `input` if there's no match). `replacement` supports JS's substitution syntax: `$$` (literal `$`), `$&` (whole match), `` $` ``/`$'` (text before/after the match), `$1`-`$99` (numbered capture groups), and `$<name>` (named capture groups). A group that exists in the pattern but didn't participate substitutes as an empty string; a `$N`/`$<name>` with no corresponding group is left as literal text (matching JS exactly).

#### `regex.replaceAll(allocator, input, replacement) ![]u8`
Replaces every match with `replacement` (like JS `String.prototype.replaceAll`). Same substitution syntax as `replace`.

## 🔧 Building from Source

### Prerequisites
- Zig 0.16.0 or later

### Build Steps

```bash
# Clone the repository
git clone https://github.com/yourusername/zregex.git
cd zregex

# Run tests
zig build test

# Build (installs the shared library used internally by the conformance harness --
# see the C/C++ note above; not a supported public build artifact)
zig build

# Build for specific targets
zig build -Dtarget=x86_64-linux
zig build -Dtarget=x86_64-windows
zig build -Dtarget=x86_64-macos
zig build -Dtarget=aarch64-linux
```

## ⚡ Performance

zregex uses a bytecode-based virtual machine for efficient pattern matching:

- **Fast Compilation**: Patterns are compiled to optimized bytecode
- **Efficient Execution**: Direct bytecode interpretation with minimal overhead
- **ReDoS Protection**: Configurable limits prevent catastrophic backtracking
- **Memory Efficient**: Careful memory management with arena allocators

### Benchmarks

```
Pattern: \d{3}-\d{3}-\d{4}
Input: "Call me at 555-123-4567"
Time: ~150ns per match

Pattern: (?<=\$)\d+
Input: "Price: $100, $200, $300"
Time: ~200ns per match
```

## 🛡️ Security

### ReDoS Protection

zregex includes built-in protection against Regular Expression Denial of Service (ReDoS) attacks:

- **Recursion Depth Limit**: Default 1000 (configurable)
- **Step Limit**: Default 1,000,000 (configurable)
- **Automatic Detection**: Patterns that exceed limits fail gracefully

### Configuration

```zig
const options = regex.CompileOptions{
    .max_recursion_depth = 500,
    .max_steps = 100_000,
    .case_insensitive = true,
};

var re = try regex.Regex.compileWithOptions(allocator, pattern, options);
```

## 📖 Pattern Examples

### Email Validation
```zig
const email_pattern = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}";
```

### URL Matching
```zig
const url_pattern = "(?:https?://)?(?:www\\.)?[a-zA-Z0-9.-]+\\.[a-z]{2,}(?:/\\S*)?";
```

### Phone Number
```zig
const phone_pattern = "\\+?\\d{1,3}?[-.\\s]?\\(?\\d{1,4}\\)?[-.\\s]?\\d{1,4}[-.\\s]?\\d{1,9}";
```

### HTML Tags
```zig
const html_tag_pattern = "<(\\w+)[^>]*>.*?</\\1>";
```

### Extract Prices
```zig
const price_pattern = "(?<=\\$)\\d+(?:\\.\\d{2})?";
```

### Password Validation
```zig
// At least 8 chars, 1 uppercase, 1 lowercase, 1 digit
const password_pattern = "^(?=.*[a-z])(?=.*[A-Z])(?=.*\\d).{8,}$";
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### Development Setup

```bash
# Clone and build
git clone https://github.com/yourusername/zregex.git
cd zregex
zig build test

# Run specific tests
zig test src/regex.zig
```

### Code Style
- Follow Zig standard library conventions
- Add tests for new features
- Update documentation
- Run `zig fmt` before committing

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Inspired by JavaScript RegExp and PCRE
- Built with [Zig](https://ziglang.org/)
- Thanks to all contributors

## 📬 Contact

- GitHub Issues: [Report bugs or request features](https://github.com/yourusername/zregex/issues)
- Discussions: [Ask questions and share ideas](https://github.com/yourusername/zregex/discussions)

## 🗺️ Roadmap

### Completed ✅
- [x] Basic character matching
- [x] Character classes and ranges
- [x] Quantifiers (greedy, lazy, possessive)
- [x] Capturing and non-capturing groups
- [x] Backreferences
- [x] Lookahead assertions
- [x] Lookbehind assertions
- [x] Anchors and word boundaries
- [x] ReDoS protection
- [x] Named capture groups `(?<name>...)` and `\k<name>` backreferences, including duplicate names across mutually exclusive alternation branches (e.g. `(?<x>a)|(?<x>b)`)
- [x] `replace()`/`replaceAll()` in the pure Zig API, including `$1`/`$&`/`` $` ``/`$'`/`$<name>` substitution
- [x] Unicode property escapes `\p{...}`/`\P{...}` (General_Category, e.g. `\p{L}`, `\p{Lu}`, `\p{Letter}`; 50 binary properties, e.g. `\p{Alphabetic}`; all 174 Unicode scripts + short aliases via `\p{Script=...}`/`\p{sc=...}`, e.g. `\p{Script=Grek}`; Script_Extensions via `\p{Script_Extensions=...}`/`\p{scx=...}`; and as a character-class member, e.g. `[\p{L}\d]`)
- [x] `case_insensitive` folding of a literal non-ASCII character's simple case pair (standalone or as a single character-class member, e.g. `café`/`CAFÉ`, `[é]`/`É`)
- [x] `v` flag (`CompileOptions.v`): character-class set operations `[A--B]`/`[A&&B]`, one per class, e.g. `[\p{L}--[aeiou]]`, `[[a-z]&&[^x]]`

### In Progress 🚧
- [ ] `u` flag (`CompileOptions.unicode`): rejects an unrecognized escape as a compile error; malformed `\x`/`\u`/`\c`/`\k`/`\p` and bad backreferences still not strict
- [ ] `v` flag: chained/nested set operations, `\q{...}` multi-string literals, `v`-only reserved punctuators, full `u` strictness
- [ ] Full UTF-8/UTF-16 support

### Future 🔮
- [ ] Conditional patterns `(?(condition)yes|no)`
- [ ] Recursive patterns
- [ ] JIT compilation
- [ ] WASM target support
- [ ] Performance optimizations

## 📊 Project Stats

- **Lines of Code**: ~11,000
- **Test Count**: 402 comprehensive tests
- **Test Pass Rate**: 100%
- **JavaScript Compatibility**: 168/168 (100%) on a test262-derived conformance sample (see [Known Limitations](docs/KNOWN_LIMITATIONS.md) for what this measurement does and doesn't cover)
- **Supported Platforms**: Linux, macOS, Windows, *BSD
- **Dependencies**: Zero (pure Zig)
- **Language**: Zig 0.16.0+

## 🏆 Features Comparison

| Feature | zregex | JavaScript | PCRE2 | RE2 |
|---------|---------|------------|-------|-----|
| Lookahead | ✅ | ✅ | ✅ | ✅ |
| Lookbehind | ✅ | ✅ | ✅ | ❌ |
| Backreferences | ✅ | ✅ | ✅ | ❌ |
| Non-capturing groups | ✅ | ✅ | ✅ | ✅ |
| Lazy quantifiers | ✅ | ✅ | ✅ | ✅ |
| Possessive quantifiers | ✅ | ❌ | ✅ | ❌ |
| ReDoS protection | ✅ | ❌ | ❌ | ✅ |
| Unicode | 🚧 | ✅ | ✅ | ✅ |

---

**Made with ❤️ using Zig**

**Version**: 0.1.0
**Status**: Active Development
**Zig Version**: 0.16.0+
