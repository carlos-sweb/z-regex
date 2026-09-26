# Executor Module

Interprets bytecode and finds pattern matches.

## Purpose

Executes compiled regex bytecode against input strings using recursive backtracking.

## Files

- `matcher.zig` - High-level matching interface (`find`, `findAll`, `matchFull`); used by
  `Regex` in `src/regex.zig`
- `recursive_matcher.zig` - The actual matching engine: a recursive backtracker (chosen
  over an earlier Pike-VM/thread-based design, which had an infinite-loop bug in
  alternation and has been removed)
- `thread.zig` - `Capture` (capture group start/end positions), shared by the matcher
- `executor_tests.zig` - Test aggregation

## Execution Model

```
Bytecode + Input → RecursiveMatcher (backtracking) → Match Result
                              ↓
                          Captures
```

## Dependencies

- `bytecode` - Opcode definitions

## Status

✅ Implemented.
