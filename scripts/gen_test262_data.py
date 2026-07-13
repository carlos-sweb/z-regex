#!/usr/bin/env python3
"""Turn the extracted test262 JSON cases into a Zig source data file."""
import json
import sys


def zig_escape(s):
    out = []
    for ch in s:
        cp = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif cp < 0x20 or cp == 0x7F:
            out.append("\\x%02x" % cp)
        else:
            out.append(ch)
    return "".join(out)


def zig_str(s):
    return '"' + zig_escape(s) + '"'


def zig_opt_str(s):
    if s is None:
        return "null"
    return zig_str(s)


def main():
    with open(sys.argv[1]) as f:
        cases = json.load(f)

    print("//! Auto-generated from test262 (tc39/test262, RegExp subtree) by")
    print("//! scripts/extract_test262.py. Do not hand-edit -- regenerate instead.")
    print("//! See docs/ECMASCRIPT_COMPATIBILITY_PLAN.md Phase 6 for how/why.")
    print()
    print("pub const Kind = enum { test_, exec_array, exec_null };")
    print()
    print("pub const Case = struct {")
    print("    kind: Kind,")
    print("    pattern: []const u8,")
    print("    flags: []const u8,")
    print("    input: []const u8,")
    print("    expected_bool: bool = false,")
    print("    expected_captures: []const ?[]const u8 = &.{},")
    print("    file: []const u8,")
    print("};")
    print()
    print(f"pub const cases = [_]Case{{")
    for c in cases:
        kind = c["kind"]
        if kind == "test":
            print("    .{ .kind = .test_, .pattern = %s, .flags = %s, .input = %s, .expected_bool = %s, .file = %s },"
                  % (zig_str(c["pattern"]), zig_str(c["flags"]), zig_str(c["input"]),
                     "true" if c["expected"] else "false", zig_str(c["file"])))
        elif kind == "exec_array":
            items = ", ".join(zig_opt_str(x) for x in c["expected"])
            print("    .{ .kind = .exec_array, .pattern = %s, .flags = %s, .input = %s, .expected_captures = &[_]?[]const u8{ %s }, .file = %s },"
                  % (zig_str(c["pattern"]), zig_str(c["flags"]), zig_str(c["input"]), items, zig_str(c["file"])))
        elif kind == "exec_null":
            print("    .{ .kind = .exec_null, .pattern = %s, .flags = %s, .input = %s, .file = %s },"
                  % (zig_str(c["pattern"]), zig_str(c["flags"]), zig_str(c["input"]), zig_str(c["file"])))
    print("};")


if __name__ == "__main__":
    main()
