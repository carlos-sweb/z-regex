# Utils Module

Shared utilities and helper data structures.

## Purpose

Provides common utilities used across multiple modules.

## Components

- **DynBuf**: Generic dynamic buffer (ArrayList wrapper)
- **BitSet**: Bit set for fast character lookups
- **Pool**: Object pooling for performance
- **Debug**: Debug utilities (dumpers, formatters)

## Files

- `dynbuf.zig` - Dynamic buffer
- `bitset.zig` - Bit set implementation
- `bittable.zig` - Fixed-size bit table (used for character class opcodes)
- `pool.zig` - Object pool
- `debug.zig` - Debug utilities
- `utils_tests.zig` - Test aggregation

## Usage

```zig
const utils = @import("utils");

// Dynamic buffer
var buf = utils.DynBuf(u8).init(allocator);
defer buf.deinit();
try buf.append('a');

// Bit set
var bitset = utils.BitSet.init(allocator, 256);
defer bitset.deinit();
bitset.set('a');
const has_a = bitset.isSet('a');
```

## Status

✅ Implemented.
