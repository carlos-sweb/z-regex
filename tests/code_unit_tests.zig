//! F3d (D6, D12): without `u` or `v` a character is one UTF-16 code unit,
//! as in ECMA-262; with them, one code point. Checked on WTF-8 and UTF-16
//! subjects (docs/REGEX_TIERS_PLAN.md, F3).

const std = @import("std");
const zregex = @import("zregex");
const testing = std.testing;
const dual = @import("dual_encoding.zig");

const u_opts: zregex.CompileOptions = .{ .unicode = true };
const v_opts: zregex.CompileOptions = .{ .v = true };

/// `slots[0..2]` of a search from 0, as WTF-8 byte offsets, in both
/// encodings (they must agree); null when nothing matches.
fn search(pattern: []const u8, opts: zregex.CompileOptions, s: []const u8) !?[2]usize {
    var re = try zregex.Regex.compileWithOptions(testing.allocator, pattern, opts);
    defer re.deinit();
    try dual.expectSameInBoth(testing.allocator, re, s);
    const f = try dual.execWtf8(testing.allocator, re, s, 0) orelse return null;
    defer f.deinit(testing.allocator);
    return .{ f.slots[0].?, f.slots[1].? };
}

fn hasUnit(pattern: []const u8, opts: zregex.CompileOptions, unit: u32) !bool {
    const c = try zregex.compile(testing.allocator, pattern, opts);
    defer c.deinit();
    var pc: usize = 0;
    while (pc < c.bytecode.len) {
        const inst = try zregex.tier2.format.decodeInstruction(c.bytecode, pc);
        if (inst.opcode == .CHAR32 and inst.operands[0] == unit) return true;
        pc += inst.size;
    }
    for (c.charsets) |cs| if (cs.contains(unit) and !cs.contains(0x1F600)) return true;
    return false;
}

test "D6: without u an astral character is two code units" {
    const emoji = "\u{1F600}"; // D83D DE00
    try testing.expect(try search("^.$", .{}, emoji) == null);
    try testing.expectEqual([2]usize{ 0, 4 }, (try search("^..$", .{}, emoji)).?);
    try testing.expectEqual([2]usize{ 0, 4 }, (try search("^.$", u_opts, emoji)).?);
    // A lone half of the pattern matches half of the subject's pair; in
    // WTF-8 the point between the halves is b+2.
    try testing.expectEqual([2]usize{ 0, 2 }, (try search("\\ud83d", .{}, emoji)).?);
    try testing.expectEqual([2]usize{ 2, 4 }, (try search("\\ude00", .{}, emoji)).?);
    try testing.expect(try search("\\ude00", u_opts, emoji) == null);
    // The literal pattern character is its two halves, and matches the pair.
    try testing.expectEqual([2]usize{ 1, 5 }, (try search("\u{1F600}", .{}, "x\u{1F600}")).?);
    try testing.expectEqual([2]usize{ 0, 2 }, (try search("[\u{1F600}]", .{}, emoji)).?);
    try testing.expectEqual([2]usize{ 0, 4 }, (try search("[\u{1F600}]", u_opts, emoji)).?);
    // Quantifiers and classes count units.
    try testing.expectEqual([2]usize{ 0, 4 }, (try search("^[^a]{2}$", .{}, emoji)).?);
    try testing.expect(try search("^[^a]{2}$", u_opts, emoji) == null);
    // A range between astral characters is between units: out of order.
    try testing.expectError(error.InvalidCharRange, zregex.Regex.compile(testing.allocator, "[\u{1F600}-\u{1F64F}]"));
}

test "D6: a capture can hold half of a pair" {
    var re = try zregex.Regex.compile(testing.allocator, "(.)");
    defer re.deinit();
    const s = "\u{1F600}";
    try dual.expectSameInBoth(testing.allocator, re, s);
    const f = (try dual.execWtf8(testing.allocator, re, s, 0)).?;
    defer f.deinit(testing.allocator);
    try testing.expectEqualSlices(?usize, &.{ 0, 2, 0, 2 }, f.slots);
}

test "D12: without u the search and advanceIndex step one code unit" {
    const a = testing.allocator;
    const s = "\u{1F600}x";
    var empty = try zregex.Regex.compile(a, "");
    defer empty.deinit();
    var all = try empty.findAll(s);
    defer {
        for (all.items) |m| m.deinit();
        all.deinit(a);
    }
    // Empty matches at 0, at b+2 and at 4 (findAll never reports one at the
    // end of the input).
    try testing.expectEqual(@as(usize, 3), all.items.len);
    try testing.expectEqual(@as(usize, 2), all.items[1].start);
    try testing.expectEqual(@as(usize, 2), empty.advanceIndex(.{ .wtf8 = s }, 0));
    try testing.expectEqual(@as(usize, 1), empty.advanceIndex(.{ .utf16 = &.{ 0xD83D, 0xDE00, 'x' } }, 0));

    var empty_u = try zregex.Regex.compileWithOptions(a, "", u_opts);
    defer empty_u.deinit();
    var all_u = try empty_u.findAll(s);
    defer {
        for (all_u.items) |m| m.deinit();
        all_u.deinit(a);
    }
    try testing.expectEqual(@as(usize, 2), all_u.items.len);
    try testing.expectEqual(@as(usize, 4), empty_u.advanceIndex(.{ .wtf8 = s }, 0));

    // A search from 0 for a trail half finds it at b+2 (UTF-16 index 1).
    try testing.expectEqual([2]usize{ 2, 4 }, (try search("\\ude00|x", .{}, s)).?);
}

test "code_units: the parser's lookahead doesn't split an astral character under v" {
    // After `[` (and after a nested `]`) the parser fetches the next token
    // with `unicode_mode` off; `code_units` must stay off under `v`. The
    // partial `v` grammar (full `v` is F5) only takes a nested class as an
    // operand of `--`/`&&`, so `[[a]😀]` and `[[😀]a]` are
    // InvalidClassSetOperand, as before F3d; these are the forms it takes.
    for ([_][]const u8{ "[\u{1F600}]", "[[\u{1F600}]--[a]]" }) |p| {
        try testing.expectEqual([2]usize{ 0, 4 }, (try search(p, v_opts, "\u{1F600}")).?);
        try testing.expect(!try hasUnit(p, v_opts, 0xD83D));
    }
    // {a} minus {😀}: the 😀 operand is one code point, so nothing of it is
    // a lone half.
    try testing.expect(try search("[[a]--[\u{1F600}]]", v_opts, "\u{1F600}") == null);
    try testing.expectEqual([2]usize{ 0, 1 }, (try search("[[a]--[\u{1F600}]]", v_opts, "a")).?);
    try testing.expect(!try hasUnit("[[\u{1F600}]&&[\u{1F600}a]]", v_opts, 0xD83D));
    try testing.expectEqual([2]usize{ 0, 4 }, (try search("[\u{1F600}]", u_opts, "\u{1F600}")).?);
    for ([_][]const u8{ "[[a]\u{1F600}]", "[[\u{1F600}]a]" }) |p| {
        try testing.expectError(error.InvalidClassSetOperand, zregex.Regex.compileWithOptions(testing.allocator, p, v_opts));
    }
    // Without `u`, `[[a]😀]` is the class `[[a]` then 😀 then `]`, and 😀
    // is split into its halves.
    try testing.expect(try hasUnit("[[a]\u{1F600}]", .{}, 0xD83D));
    try testing.expect(try hasUnit("[[a]\u{1F600}]", .{}, 0xDE00));
    try testing.expectEqual([2]usize{ 0, 6 }, (try search("[[a]\u{1F600}]", .{}, "a\u{1F600}]")).?);
}

test "code_units: \\u{...} above U+FFFF without u is its two halves" {
    try testing.expectEqual([2]usize{ 0, 4 }, (try search("^\\u{1F600}$", .{}, "\u{1F600}")).?);
    try testing.expect(try hasUnit("\\u{1F600}", .{}, 0xD83D));
    try testing.expectEqual([2]usize{ 0, 4 }, (try search("^\\u{1F600}$", u_opts, "\u{1F600}")).?);
}
