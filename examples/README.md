# zregex Examples

This directory contains practical examples demonstrating how to use the zregex library.

## Available Examples

### 1. basic_usage.zig
Demonstrates fundamental operations:
- Compiling regex patterns
- Testing if patterns match
- Finding matches in text
- Using metacharacters (`.`, `*`, `+`, `?`)
- Using anchors (`^`, `$`)
- One-shot convenience functions

**Run:**
```bash
zig build-exe basic_usage.zig --dep zregex --mod zregex:../src/main.zig
./basic_usage
```

### 2. capture_groups.zig
Shows how to work with capture groups:
- Simple capture groups `(...)`
- Multiple captures
- Nested captures
- Extracting structured data
- Optional captures

**Run:**
```bash
zig build-exe capture_groups.zig --dep zregex --mod zregex:../src/main.zig
./capture_groups
```

### 3. find_all.zig
Demonstrates finding all matches:
- Finding multiple occurrences
- Counting matches
- Using alternation to find different patterns
- Handling cases with no matches
- Using the `findAll()` convenience function

**Run:**
```bash
zig build-exe find_all.zig --dep zregex --mod zregex:../src/main.zig
./find_all
```

### 4. validation.zig
Real-world validation examples:
- Validating exact formats
- Checking string length with quantifiers
- Validating against multiple options (alternation)
- Validating optional parts
- Prefix/suffix validation
- Batch validation

**Run:**
```bash
zig build-exe validation.zig --dep zregex --mod zregex:../src/main.zig
./validation
```

## Quick Reference

### Basic Pattern Compilation

```zig
const std = @import("std");
const zregex = @import("zregex");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// Compile once, use many times
var re = try zregex.Regex.compile(allocator, "pattern");
defer re.deinit();
```

### Testing if Pattern Matches

```zig
const matches = try re.test_("text to test");
if (matches) {
    // Pattern matched!
}
```

### Finding First Match

```zig
if (try re.find("search this text")) |match| {
    defer match.deinit();

    const matched_text = match.group("search this text");
    const start_pos = match.start;
    const end_pos = match.end;
}
```

### Finding All Matches

```zig
var matches = try re.findAll("text with multiple matches");
defer {
    for (matches.items) |match| {
        match.deinit();
    }
    matches.deinit(allocator);
}

for (matches.items) |match| {
    // Process each match
}
```

### Working with Capture Groups

```zig
var re = try zregex.Regex.compile(allocator, "(capture) (this)");
defer re.deinit();

if (try re.find("capture this")) |match| {
    defer match.deinit();

    const group1 = match.getCapture(1, "capture this"); // "capture"
    const group2 = match.getCapture(2, "capture this"); // "this"
}
```

### One-Shot Operations (Convenience Functions)

```zig
// Test without storing compiled regex
if (try zregex.test_(allocator, "pattern", "text")) {
    // Matched!
}

// Find without storing compiled regex
if (try zregex.find(allocator, "pattern", "text")) |match| {
    defer match.deinit();
    // Process match
}

// Find all without storing compiled regex
var matches = try zregex.findAll(allocator, "pattern", "text");
defer {
    for (matches.items) |match| match.deinit();
    matches.deinit(allocator);
}
```

## Supported Features (Phase 3)

Currently implemented in the engine:

- ✅ **Literals**: `abc`, `hello`
- ✅ **Metacharacters**: `.` (any character)
- ✅ **Quantifiers**: `*` (0 or more), `+` (1 or more), `?` (0 or 1), `{n,m}` (range)
- ✅ **Alternation**: `a|b|c`
- ✅ **Groups**: `(...)` for capturing
- ✅ **Anchors**: `^` (start), `$` (end)
- ✅ **Escapes**: `\.`, `\*`, `\+`, etc.

## Coming Soon (Phase 4+)

Features planned for future phases:

- 🚧 **Character Classes**: `[a-z]`, `[0-9]`, `[^abc]`
- 🚧 **Shorthand Classes**: `\d` (digits), `\w` (word chars), `\s` (whitespace)
- 🚧 **Word Boundaries**: `\b`, `\B`
- 🚧 **Unicode Support**: Full UTF-8 and Unicode properties
- 🚧 **Lookahead/Lookbehind**: `(?=...)`, `(?!...)`, `(?<=...)`, `(?<!...)`
- 🚧 **Named Captures**: `(?<name>...)`
- 🚧 **Backreferences**: `\1`, `\2`
- 🚧 **Lazy Quantifiers**: `*?`, `+?`, `??`

## Notes

- All examples use `GeneralPurposeAllocator` for demonstration
- Remember to call `deinit()` on regex objects and match results
- Match results contain borrowed slices from the input, so keep input alive
- For production use, consider using an arena allocator for match operations

## Getting Help

- Check the main README.md in the project root
- See the API documentation in docs/
- Browse the test files in tests/integration_tests.zig for more examples

## Contributing

Found a bug or want to add an example? See CONTRIBUTING.md in the project root.
