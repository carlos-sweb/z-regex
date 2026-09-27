//! The Subject: the input a regex runs over (docs/REGEX_TIERS_PLAN.md, F3).
//!
//! A Subject is WTF-8 bytes or UTF-16 code units, and every index is in
//! the Subject's own units (bytes or u16s). What one "character" is
//! depends on the mode: without `u` it is one UTF-16 code unit, with `u`
//! (or `v`) one code point, where a valid surrogate pair combines and a
//! lone surrogate is a code point of its own.
//!
//! **Positions in WTF-8.** Every sequence boundary is a position. Without
//! `u`, an astral character is two code units, and the point between them
//! has no byte offset. By convention it is `b+2`, where `b` is the start of
//! the character's 4-byte sequence: `b+1` and `b+3` are never positions, so
//! this is unambiguous. `b+2` exists only inside a 4-byte sequence, and in
//! WTF-8 a 4-byte sequence is always an astral character (a lead+trail
//! pair). No other interior offset is a position:
//!
//! - a lone lead followed by another lead (two 3-byte sequences): `b`,
//!   `b+3` and `b+6`, with no `b+2`;
//! - a lone lead followed by a BMP character: `b`, `b+3` and the next
//!   boundary;
//! - a lead and a trail encoded separately (not valid WTF-8): two lone
//!   surrogates at `b` and `b+3`, which never combine, not even with `u`;
//! - an invalid byte: one unit whose value is the byte, so `b` and `b+1`.
//!
//! Decoding at `b+2` gives the trail half in both modes. That is what the
//! spec does with `u` when `lastIndex` points into a pair. Decoding before
//! `b+2` gives the lead half.
//!
//! In UTF-16 every index from 0 to the length is a position.

const std = @import("std");

pub const Mode = enum {
    /// Without `u`: one UTF-16 code unit per character.
    code_unit,
    /// With `u` or `v`: one code point per character.
    code_point,
};

/// One decoded character: its value, and the position on its other side
/// (the next position for `decodeAt`, the previous one for `decodeBefore`).
/// `invalid` marks an ill-formed WTF-8 byte, decoded as its value: a
/// literal U+00E9 must not match a lone byte 0xE9, while a class or `.`
/// takes it as its value (the HIR contract).
pub const Decoded = struct { value: u32, pos: usize, invalid: bool = false };

pub const IndexError = error{InvalidIndex};

pub const Subject = union(enum) {
    wtf8: []const u8,
    utf16: []const u16,

    /// Length in the Subject's units.
    pub fn len(self: Subject) usize {
        return switch (self) {
            inline else => |s| s.len,
        };
    }

    /// Whether `i` is a position of this Subject (see the file comment).
    pub fn isPosition(self: Subject, i: usize) bool {
        return switch (self) {
            .utf16 => |s| i <= s.len,
            .wtf8 => |s| wtf8IsPosition(s, i),
        };
    }

    /// The character starting at position `i`, or null at the end.
    pub fn decodeAt(self: Subject, mode: Mode, i: usize) ?Decoded {
        return switch (self) {
            .utf16 => |s| utf16DecodeAt(s, mode, i),
            .wtf8 => |s| wtf8DecodeAt(s, mode, i),
        };
    }

    /// The character ending at position `i`, or null at the start.
    pub fn decodeBefore(self: Subject, mode: Mode, i: usize) ?Decoded {
        return switch (self) {
            .utf16 => |s| utf16DecodeBefore(s, mode, i),
            .wtf8 => |s| wtf8DecodeBefore(s, mode, i),
        };
    }

    /// AdvanceStringIndex: the position after the character at `i`. At or
    /// past the end, `i + 1`, as in the spec.
    pub fn advanceIndex(self: Subject, mode: Mode, i: usize) usize {
        if (i >= self.len()) return i + 1;
        return self.decodeAt(mode, i).?.pos;
    }
};

// ---------------------------------------------------------------- UTF-16

fn isLead(u: u32) bool {
    return u >= 0xD800 and u <= 0xDBFF;
}

fn isTrail(u: u32) bool {
    return u >= 0xDC00 and u <= 0xDFFF;
}

fn combine(lead: u32, trail: u32) u32 {
    return 0x10000 + ((lead - 0xD800) << 10) + (trail - 0xDC00);
}

fn utf16DecodeAt(s: []const u16, mode: Mode, i: usize) ?Decoded {
    if (i >= s.len) return null;
    const u: u32 = s[i];
    if (mode == .code_point and isLead(u) and i + 1 < s.len and isTrail(s[i + 1]))
        return .{ .value = combine(u, s[i + 1]), .pos = i + 2 };
    return .{ .value = u, .pos = i + 1 };
}

fn utf16DecodeBefore(s: []const u16, mode: Mode, i: usize) ?Decoded {
    if (i == 0 or i > s.len) return null;
    const u: u32 = s[i - 1];
    if (mode == .code_point and isTrail(u) and i >= 2 and isLead(s[i - 2]))
        return .{ .value = combine(s[i - 2], u), .pos = i - 2 };
    return .{ .value = u, .pos = i - 1 };
}

// ----------------------------------------------------------------- WTF-8

const Seq = struct { cp: u21, len: u3 };

/// The valid sequence starting at byte `i`: UTF-8, or a 3-byte surrogate
/// (WTF-8). Null for an invalid, truncated or overlong sequence, or a
/// continuation byte.
fn seqAt(s: []const u8, i: usize) ?Seq {
    if (i >= s.len) return null;
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return null;
    if (i + n > s.len) return null;
    const bytes = s[i..][0..n];
    if (std.unicode.utf8Decode(bytes)) |cp| return .{ .cp = cp, .len = n } else |_| {}
    if (n == 3 and bytes[0] == 0xED and bytes[1] >= 0xA0 and bytes[1] <= 0xBF and bytes[2] & 0xC0 == 0x80) {
        const cp: u21 = (@as(u21, bytes[0] & 0x0F) << 12) | (@as(u21, bytes[1] & 0x3F) << 6) | (bytes[2] & 0x3F);
        return .{ .cp = cp, .len = 3 };
    }
    return null;
}

/// The astral character whose 4-byte sequence has `i` as its `b+2`.
fn midOf(s: []const u8, i: usize) ?u21 {
    if (i < 2 or i >= s.len or s[i] & 0xC0 != 0x80) return null;
    const seq = seqAt(s, i - 2) orelse return null;
    return if (seq.len == 4) seq.cp else null;
}

fn leadOf(cp: u32) u32 {
    return 0xD800 + ((cp - 0x10000) >> 10);
}

fn trailOf(cp: u32) u32 {
    return 0xDC00 + ((cp - 0x10000) & 0x3FF);
}

fn wtf8IsPosition(s: []const u8, i: usize) bool {
    if (i > s.len) return false;
    if (i == s.len) return true;
    // Only a continuation byte can be inside a sequence.
    if (s[i] & 0xC0 != 0x80) return true;
    // The byte at `i` is inside the sequence that starts at `i - k`, if any.
    var k: usize = 1;
    while (k <= 3 and k <= i) : (k += 1) {
        if (seqAt(s, i - k)) |seq| {
            if (seq.len > k) return k == 2 and seq.len == 4;
        }
    }
    return true;
}

fn wtf8DecodeAt(s: []const u8, mode: Mode, i: usize) ?Decoded {
    if (i >= s.len) return null;
    if (s[i] < 0x80) return .{ .value = s[i], .pos = i + 1 };
    if (midOf(s, i)) |cp| return .{ .value = trailOf(cp), .pos = i + 2 };
    const seq = seqAt(s, i) orelse return .{ .value = s[i], .pos = i + 1, .invalid = true };
    if (seq.len == 4 and mode == .code_unit) return .{ .value = leadOf(seq.cp), .pos = i + 2 };
    return .{ .value = seq.cp, .pos = i + seq.len };
}

fn wtf8DecodeBefore(s: []const u8, mode: Mode, i: usize) ?Decoded {
    if (i == 0 or i > s.len) return null;
    if (midOf(s, i)) |cp| return .{ .value = leadOf(cp), .pos = i - 2 };
    if (s[i - 1] < 0x80) return .{ .value = s[i - 1], .pos = i - 1 };
    // A valid sequence that ends exactly at `i`: its lead is the first
    // non-continuation byte going back, so there is at most one.
    var k: usize = 1;
    while (k <= 4 and k <= i) : (k += 1) {
        if (seqAt(s, i - k)) |seq| {
            if (seq.len != k) break;
            if (seq.len == 4 and mode == .code_unit) return .{ .value = trailOf(seq.cp), .pos = i - 2 };
            return .{ .value = seq.cp, .pos = i - k };
        }
        if (s[i - k] & 0xC0 != 0x80) break;
    }
    return .{ .value = s[i - 1], .pos = i - 1, .invalid = true };
}

// --------------------------------------------------------- Index mapping

/// The UTF-16 index of WTF-8 position `i`: the number of UTF-16 code units
/// before it. An invalid byte counts as one unit. O(i).
pub fn wtf8ToUtf16Index(s: []const u8, i: usize) IndexError!usize {
    if (!wtf8IsPosition(s, i)) return error.InvalidIndex;
    var pos: usize = 0;
    var units: usize = 0;
    while (pos < i) : (units += 1) pos = wtf8DecodeAt(s, .code_unit, pos).?.pos;
    return units;
}

/// The WTF-8 position of UTF-16 index `u` (see `wtf8ToUtf16Index`). O(u).
pub fn utf16ToWtf8Index(s: []const u8, u: usize) IndexError!usize {
    var pos: usize = 0;
    var units: usize = 0;
    while (units < u) : (units += 1) {
        pos = (wtf8DecodeAt(s, .code_unit, pos) orelse return error.InvalidIndex).pos;
    }
    return pos;
}

/// The UTF-16 code units of a WTF-8 string, one per unit of
/// `wtf8ToUtf16Index` (an invalid byte becomes a unit with its value).
pub fn utf16FromWtf8(gpa: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u16 {
    var out: std.ArrayListUnmanaged(u16) = .empty;
    errdefer out.deinit(gpa);
    var pos: usize = 0;
    while (wtf8DecodeAt(s, .code_unit, pos)) |d| : (pos = d.pos) try out.append(gpa, @intCast(d.value));
    return out.toOwnedSlice(gpa);
}

/// The WTF-8 bytes of UTF-16 code units: a pair becomes one 4-byte
/// sequence, a lone surrogate a 3-byte one.
pub fn wtf8FromUtf16(gpa: std.mem.Allocator, s: []const u16) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var pos: usize = 0;
    while (utf16DecodeAt(s, .code_point, pos)) |d| : (pos = d.pos) {
        var buf: [4]u8 = undefined;
        const n = std.unicode.wtf8Encode(@intCast(d.value), &buf) catch unreachable;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

// ----------------------------------------------------------------- Tests

const testing = std.testing;

/// Compares value and position; `invalid` has its own test.
fn expectDecoded(expected: ?Decoded, actual: ?Decoded) !void {
    try testing.expectEqual(expected == null, actual == null);
    if (expected) |e| {
        try testing.expectEqual(e.value, actual.?.value);
        try testing.expectEqual(e.pos, actual.?.pos);
    }
}

test "every code point decodes the same in WTF-8 and UTF-16, in both modes" {
    var cp: u32 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        var w: [4]u8 = undefined;
        const wn = std.unicode.wtf8Encode(@intCast(cp), &w) catch unreachable;
        var u: [2]u16 = undefined;
        const un: usize = if (cp >= 0x10000) 2 else 1;
        if (un == 2) {
            u = .{ @intCast(leadOf(cp)), @intCast(trailOf(cp)) };
        } else u[0] = @intCast(cp);
        const sw: Subject = .{ .wtf8 = w[0..wn] };
        const su: Subject = .{ .utf16 = u[0..un] };

        // code_point: one character over the whole encoding.
        try expectDecoded(.{ .value = cp, .pos = wn }, sw.decodeAt(.code_point, 0));
        try expectDecoded(.{ .value = cp, .pos = un }, su.decodeAt(.code_point, 0));
        try expectDecoded(.{ .value = cp, .pos = 0 }, sw.decodeBefore(.code_point, wn));
        try expectDecoded(.{ .value = cp, .pos = 0 }, su.decodeBefore(.code_point, un));

        if (un == 2) {
            // code_unit: two halves, split at b+2 in WTF-8.
            try expectDecoded(.{ .value = leadOf(cp), .pos = 2 }, sw.decodeAt(.code_unit, 0));
            try expectDecoded(.{ .value = trailOf(cp), .pos = 4 }, sw.decodeAt(.code_unit, 2));
            try expectDecoded(.{ .value = trailOf(cp), .pos = 2 }, sw.decodeBefore(.code_unit, 4));
            try expectDecoded(.{ .value = leadOf(cp), .pos = 0 }, sw.decodeBefore(.code_unit, 2));
            // At b+2 the trail half decodes alone in both modes.
            try expectDecoded(.{ .value = trailOf(cp), .pos = 4 }, sw.decodeAt(.code_point, 2));
            try expectDecoded(.{ .value = trailOf(cp), .pos = 2 }, su.decodeAt(.code_point, 1));
            try expectDecoded(.{ .value = leadOf(cp), .pos = 0 }, sw.decodeBefore(.code_point, 2));
            try expectDecoded(.{ .value = leadOf(cp), .pos = 0 }, su.decodeBefore(.code_point, 1));
            try testing.expect(sw.isPosition(2) and !sw.isPosition(1) and !sw.isPosition(3));
        } else {
            try expectDecoded(.{ .value = cp, .pos = wn }, sw.decodeAt(.code_unit, 0));
            try expectDecoded(.{ .value = cp, .pos = 0 }, sw.decodeBefore(.code_unit, wn));
            var k: usize = 1;
            while (k < wn) : (k += 1) try testing.expect(!sw.isPosition(k));
        }
        try testing.expect(sw.isPosition(0) and sw.isPosition(wn) and !sw.isPosition(wn + 1));
    }
}

test "WTF-8 positions around lone surrogates and invalid bytes" {
    const Row = struct { bytes: []const u8, positions: []const usize, units: []const u32 };
    const rows = [_]Row{
        // A lone lead followed by another lead: two units, no b+2.
        .{ .bytes = "\xED\xA0\x80\xED\xA0\x81", .positions = &.{ 0, 3, 6 }, .units = &.{ 0xD800, 0xD801 } },
        // A lone lead followed by a BMP character.
        .{ .bytes = "\xED\xA0\x80\xC3\xA9", .positions = &.{ 0, 3, 5 }, .units = &.{ 0xD800, 0xE9 } },
        // A lead and a trail encoded separately: two lone surrogates.
        .{ .bytes = "\xED\xA0\xBD\xED\xB8\x80", .positions = &.{ 0, 3, 6 }, .units = &.{ 0xD83D, 0xDE00 } },
        // A lone trail.
        .{ .bytes = "a\xED\xB8\x80", .positions = &.{ 0, 1, 4 }, .units = &.{ 'a', 0xDE00 } },
        // Invalid bytes: one unit each, with the byte's value.
        .{ .bytes = "\x80a\xFF", .positions = &.{ 0, 1, 2, 3 }, .units = &.{ 0x80, 'a', 0xFF } },
        // A truncated sequence: each byte is a unit.
        .{ .bytes = "\xE2\x82", .positions = &.{ 0, 1, 2 }, .units = &.{ 0xE2, 0x82 } },
        // An astral character after a lone lead: b+2 only inside it.
        .{ .bytes = "\xED\xA0\x80\xF0\x9F\x98\x80", .positions = &.{ 0, 3, 5, 7 }, .units = &.{ 0xD800, 0xD83D, 0xDE00 } },
    };
    for (rows) |row| {
        const s: Subject = .{ .wtf8 = row.bytes };
        var i: usize = 0;
        while (i <= row.bytes.len + 1) : (i += 1) {
            const expected = std.mem.indexOfScalar(usize, row.positions, i) != null;
            try testing.expectEqual(expected, s.isPosition(i));
        }
        // Forward and backward in code_unit mode visit the same positions
        // and units, and the UTF-16 index of each is its rank.
        for (row.units, 0..) |unit, n| {
            try expectDecoded(.{ .value = unit, .pos = row.positions[n + 1] }, s.decodeAt(.code_unit, row.positions[n]));
            try expectDecoded(.{ .value = unit, .pos = row.positions[n] }, s.decodeBefore(.code_unit, row.positions[n + 1]));
        }
        for (row.positions, 0..) |p, n| {
            try testing.expectEqual(n, try wtf8ToUtf16Index(row.bytes, p));
            try testing.expectEqual(p, try utf16ToWtf8Index(row.bytes, n));
        }
        try testing.expectError(error.InvalidIndex, utf16ToWtf8Index(row.bytes, row.units.len + 1));
    }
    // Separately encoded halves never combine, not even with `u`.
    const split: Subject = .{ .wtf8 = "\xED\xA0\xBD\xED\xB8\x80" };
    try expectDecoded(.{ .value = 0xD83D, .pos = 3 }, split.decodeAt(.code_point, 0));
    try testing.expectError(error.InvalidIndex, wtf8ToUtf16Index("\xF0\x9F\x98\x80", 1));
    try testing.expectError(error.InvalidIndex, wtf8ToUtf16Index("\xC3\xA9", 1));
}

test "only ill-formed WTF-8 bytes are marked invalid" {
    const s: Subject = .{ .wtf8 = "a\xC3\xA9\x80\xED\xA0\x80\xF0\x9F\x98\x80\xE2\x82" };
    const expected = [_]bool{ false, false, true, false, false, false, true, true };
    var pos: usize = 0;
    for (expected) |inv| {
        const d = s.decodeAt(.code_unit, pos).?;
        try testing.expectEqual(inv, d.invalid);
        pos = d.pos;
    }
    try testing.expectEqual(s.len(), pos);
    var back = s.len();
    var n = expected.len;
    while (n > 0) : (n -= 1) {
        const d = s.decodeBefore(.code_unit, back).?;
        try testing.expectEqual(expected[n - 1], d.invalid);
        back = d.pos;
    }
    try testing.expectEqual(@as(usize, 0), back);
    try testing.expect(!(Subject{ .utf16 = &.{0xD800} }).decodeAt(.code_unit, 0).?.invalid);
}

test "UTF-16 pairs combine only with u; every index is a position" {
    const units = [_]u16{ 'a', 0xD83D, 0xDE00, 0xD800, 'b', 0xDC00 };
    const s: Subject = .{ .utf16 = &units };
    try expectDecoded(.{ .value = 0x1F600, .pos = 3 }, s.decodeAt(.code_point, 1));
    try expectDecoded(.{ .value = 0xD83D, .pos = 2 }, s.decodeAt(.code_unit, 1));
    try expectDecoded(.{ .value = 0xD800, .pos = 4 }, s.decodeAt(.code_point, 3));
    try expectDecoded(.{ .value = 0x1F600, .pos = 1 }, s.decodeBefore(.code_point, 3));
    try expectDecoded(.{ .value = 0xDC00, .pos = 5 }, s.decodeBefore(.code_point, 6));
    try testing.expect(s.decodeAt(.code_point, 6) == null and s.decodeBefore(.code_unit, 0) == null);
    var i: usize = 0;
    while (i <= units.len) : (i += 1) try testing.expect(s.isPosition(i));
    try testing.expect(!s.isPosition(units.len + 1));
}

test "advanceIndex steps one unit without u and one code point with u" {
    const w: Subject = .{ .wtf8 = "a\xF0\x9F\x98\x80" };
    try testing.expectEqual(@as(usize, 3), w.advanceIndex(.code_unit, 1));
    try testing.expectEqual(@as(usize, 5), w.advanceIndex(.code_point, 1));
    try testing.expectEqual(@as(usize, 5), w.advanceIndex(.code_point, 3));
    try testing.expectEqual(@as(usize, 6), w.advanceIndex(.code_point, 5));
    const u: Subject = .{ .utf16 = &.{ 'a', 0xD83D, 0xDE00 } };
    try testing.expectEqual(@as(usize, 2), u.advanceIndex(.code_unit, 1));
    try testing.expectEqual(@as(usize, 3), u.advanceIndex(.code_point, 1));
    try testing.expectEqual(@as(usize, 3), u.advanceIndex(.code_point, 2));
}

test "WTF-8 and UTF-16 agree on random well-formed strings" {
    var prng = std.Random.DefaultPrng.init(0xF3A);
    const r = prng.random();
    const pool = [_]u16{ 'a', 'Z', '\n', 0xE9, 0x20AC, 0x2028, 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0xD83D, 0xDE00, 0xFFFF };
    var round: usize = 0;
    while (round < 2000) : (round += 1) {
        var units: [12]u16 = undefined;
        const n = r.uintLessThan(usize, units.len + 1);
        for (units[0..n]) |*u| u.* = pool[r.uintLessThan(usize, pool.len)];
        const bytes = try wtf8FromUtf16(testing.allocator, units[0..n]);
        defer testing.allocator.free(bytes);
        const back = try utf16FromWtf8(testing.allocator, bytes);
        defer testing.allocator.free(back);
        try testing.expectEqualSlices(u16, units[0..n], back);

        const sw: Subject = .{ .wtf8 = bytes };
        const su: Subject = .{ .utf16 = units[0..n] };
        for ([_]Mode{ .code_unit, .code_point }) |mode| {
            // Walk forward from every UTF-16 index: the same values, and
            // positions that map to each other.
            var ui: usize = 0;
            while (ui <= n) : (ui += 1) {
                const wi = try utf16ToWtf8Index(bytes, ui);
                try testing.expect(sw.isPosition(wi));
                try testing.expectEqual(ui, try wtf8ToUtf16Index(bytes, wi));
                const du = su.decodeAt(mode, ui);
                const dw = sw.decodeAt(mode, wi);
                try testing.expectEqual(du == null, dw == null);
                if (du) |d| {
                    try testing.expectEqual(d.value, dw.?.value);
                    try testing.expectEqual(d.pos, try wtf8ToUtf16Index(bytes, dw.?.pos));
                }
                const bu = su.decodeBefore(mode, ui);
                const bw = sw.decodeBefore(mode, wi);
                try testing.expectEqual(bu == null, bw == null);
                if (bu) |d| {
                    try testing.expectEqual(d.value, bw.?.value);
                    try testing.expectEqual(d.pos, try wtf8ToUtf16Index(bytes, bw.?.pos));
                }
                try testing.expectEqual(su.advanceIndex(mode, ui), if (ui >= n) n + 1 else try wtf8ToUtf16Index(bytes, sw.advanceIndex(mode, wi)));
            }
        }
    }
}
