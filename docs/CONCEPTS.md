# Core Concepts

This document explains the fundamental concepts behind zregex.

## Regular Expression Engine Architecture

### Compilation vs Execution

**Compilation** (Ahead-of-Time):
- Parse pattern string into AST
- Validate syntax and semantics
- Generate optimized bytecode
- Happens once, result is reusable

**Execution** (Runtime):
- Interpret bytecode
- Match against input string
- Use backtracking to explore alternatives
- Happens many times with same compiled regex

**Benefits of Separation**:
- Compile once, execute many times
- Optimization opportunities
- Clear separation of concerns
- Testability

### Bytecode Intermediate Representation

**Why Bytecode?**
- Platform independent
- Compact representation
- Fast to interpret
- Easy to optimize
- Serializable (save to disk)

**Alternative Approaches**:
- **Direct AST interpretation**: Slower, more memory
- **JIT compilation**: Faster but complex
- **DFA/NFA**: Linear time but limited features

## Pattern Matching Strategies

### Backtracking Engine

**How it works**:
1. Try to match at current position
2. On success, advance and continue
3. On failure, backtrack to last choice point
4. Try alternative path
5. Repeat until match or all paths exhausted

**Advantages**:
- Supports all ECMAScript features
- Backreferences, lookahead, etc.
- Intuitive semantics

**Disadvantages**:
- Exponential worst case: O(2^n)
- Susceptible to ReDoS attacks
- Not guaranteed linear time

**Example**:
```
Pattern: (a|ab)*c
Input:   ababababababababababz

Backtracking explores:
  a, backtrack, ab, backtrack, a, backtrack, ab, ...
  Exponential explosion!
```

### ReDoS Protection

**Strategies**:
1. **Timeout**: Interrupt after N operations
2. **Depth limit**: Maximum backtrack depth
3. **Pattern analysis**: Detect dangerous patterns
4. **Hybrid engines**: Switch to DFA for simple patterns

**zregex approach**:
- Interrupt counter (check every 10k ops)
- User-configurable timeout
- Stack depth limiting
- Future: Pattern analysis warnings

## Unicode Support

### Character Representation

**UTF-8** (native in Zig):
- Variable width: 1-4 bytes
- Backward compatible with ASCII
- Most common encoding

**UTF-16** (JavaScript standard):
- Variable width: 2 or 4 bytes
- Surrogate pairs for >U+FFFF
- Required for ECMAScript compliance

**Code Points**:
- Numeric value: U+0000 to U+10FFFF
- Not the same as bytes
- Zig: `u21` type (21 bits)

### Character Classes

**ASCII Classes**:
- `\d` = [0-9]
- `\w` = [a-zA-Z0-9_]
- `\s` = [ \t\n\r\f\v]

**Unicode Classes** (with /u flag):
- `\d` = All Unicode decimal numbers
- `\w` = ID_Continue property
- `\s` = White_Space property

### Character Ranges

**Representation**:
```
[a-z0-9] → CharRange{ points: [a, z+1, 0, 9+1] }
```

**Operations**:
- Union: [a-z] | [0-9] = [a-z0-9]
- Intersection: [a-z] & [a-f] = [a-f]
- Subtraction: [a-z] - [a-f] = [g-z]
- Inversion: ^[a-z] = everything except [a-z]

**Implementation**:
- Sorted array of intervals
- Binary search for lookup: O(log n)
- Merge overlapping ranges

### Case Folding

**Simple case folding**:
```
'A' → 'a'
'α' → 'Α'
```

**Complex case folding**:
```
'ß' → "ss"  (German eszett)
'ﬁ' → "fi"  (ligature)
```

**ECMAScript rules**:
- Without /u: ASCII only
- With /u: Full Unicode case folding

## Capture Groups

### Numbered Captures

```zig
Pattern: (\d+)-(\d+)
Input:   123-456

Captures:
  0: "123-456"  (full match)
  1: "123"      (first group)
  2: "456"      (second group)
```

**Implementation**:
- Array of (start, end) positions
- Save/restore on backtrack
- Indexed from 1 (0 = full match)

### Named Captures

```zig
Pattern: (?<year>\d{4})-(?<month>\d{2})
Input:   2025-11

Captures:
  0: "2025-11"
  "year": "2025"
  "month": "11"
```

**Implementation**:
- Store names in bytecode
- Map names to indices
- Access by name or number

### Backreferences

```zig
Pattern: (\w+) \1
Input:   hello hello  ✓
Input:   hello world  ✗

Pattern: (?<word>\w+) \k<word>
Input:   test test    ✓
```

**Implementation**:
- Look up captured value
- Match character-by-character
- Handle case-insensitive mode

## Assertions

### Zero-Width Assertions

**Anchors**:
- `^` - Start of line/string
- `$` - End of line/string
- `\b` - Word boundary
- `\B` - Not word boundary

**Lookahead**:
- `(?=...)` - Positive lookahead
- `(?!...)` - Negative lookahead

**Lookbehind**:
- `(?<=...)` - Positive lookbehind
- `(?<!...)` - Negative lookbehind

**Key property**: Don't consume characters

### Word Boundaries

```zig
\b = transition between \w and \W

"hello world" with \bhello\b
  ^           ^
  boundary    boundary
```

**Implementation**:
```zig
fn isWordBoundary(prev: ?u32, curr: ?u32) bool {
    const prev_is_word = if (prev) |p| isWord(p) else false;
    const curr_is_word = if (curr) |c| isWord(c) else false;
    return prev_is_word != curr_is_word;
}
```

## Quantifiers

### Greedy Quantifiers

```
*   = 0 or more (greedy)
+   = 1 or more (greedy)
?   = 0 or 1 (greedy)
{n} = exactly n
{n,}= n or more
{n,m}=between n and m
```

**Greedy**: Match as much as possible

**Example**:
```
Pattern: a+b
Input:   aaaab

Greedy tries:
  aaaa + b ✓ (matches all a's)
```

### Lazy Quantifiers

```
*?  = 0 or more (lazy)
+?  = 1 or more (lazy)
??  = 0 or 1 (lazy)
{n,}?= n or more (lazy)
{n,m}?=between n and m (lazy)
```

**Lazy**: Match as little as possible

**Example**:
```
Pattern: a+?b
Input:   aaaab

Lazy tries:
  a + aaab ✗
  aa + aab ✗
  aaa + ab ✗
  aaaa + b ✓ (backtracks to minimum)
```

### Implementation

**Greedy** (SPLIT_GOTO_FIRST):
```
SPLIT → GOTO body | continue
Try body first, backtrack to continue
```

**Lazy** (SPLIT_NEXT_FIRST):
```
SPLIT → continue | GOTO body
Try continue first, backtrack to body
```

## Optimization Techniques

### Bytecode Optimizations

**Constant Folding**:
```
[a-z] ∩ [e-m] → [e-m]
```

**Dead Code Elimination**:
```
GOTO L1
CHAR 'x'  ← unreachable
L1:
```

**Jump Threading**:
```
GOTO L1      GOTO L2
L1: GOTO L2  (eliminated)
L2: ...      L2: ...
```

**Instruction Merging**:
```
CHAR 'h'     CHAR 'hello'
CHAR 'e'  →  (5x faster)
CHAR 'l'
CHAR 'l'
CHAR 'o'
```

### Execution Optimizations

**Static Stack**:
- Small stack (32 elements) on stack
- Avoids malloc for common cases
- Grows dynamically if needed

**Character Class Caching**:
- Cache recent property lookups
- Avoid binary search overhead

**Fast Paths**:
- Inline common operations
- Branch prediction hints
- SIMD for scanning (future)

## Error Handling

### Compile Errors

**Syntax Errors**:
```
Pattern: "hello("
Error: Unmatched opening parenthesis at position 5
```

**Semantic Errors**:
```
Pattern: "\1(group)"
Error: Backreference \1 before group definition
```

**Resource Errors**:
```
Pattern: (a)(b)(c)...(too many)
Error: Too many capture groups (max 255)
```

### Runtime Errors

**Timeout**:
```
Pattern: (a+)+b
Input:   aaaaaaaaaaaaaaaaaaaaaz
Error: Execution timeout (possible ReDoS)
```

**Stack Overflow**:
```
Pattern: deeply nested structure
Error: Backtrack stack overflow
```

## Performance Characteristics

### Time Complexity

**Best Case**: O(n)
- Simple patterns (literal strings)
- No backtracking required

**Average Case**: O(n * m)
- n = input length
- m = pattern complexity
- Most real-world patterns

**Worst Case**: O(2^n)
- Pathological patterns
- Exponential backtracking
- ReDoS territory

### Space Complexity

**Compilation**:
- O(p) for pattern length p
- AST nodes
- Bytecode buffer

**Execution**:
- O(c) for captures
- O(d) for backtrack depth
- Usually small and bounded

### Optimality

**Not optimal for**:
- Guaranteed linear time (use RE2)
- Low memory (use DFA)

**Optimal for**:
- ECMAScript compliance
- Feature completeness
- Embedding in applications

---

**Document Version**: 1.0
**Last Updated**: 2025-11-26
