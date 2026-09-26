//! F3c: running a match on the UTF-16 form of a WTF-8 subject, with the
//! result mapped back to byte offsets, so a test written against WTF-8
//! checks both encodings (docs/REGEX_TIERS_PLAN.md, F3: "the same tests in
//! both encodings").

const std = @import("std");
const zregex = @import("zregex");
const subject = zregex.subject;

/// Whether `s` is well-formed WTF-8 (no ill-formed byte), so its UTF-16
/// form means the same string. Ill-formed bytes only exist in WTF-8.
pub fn wellFormed(s: []const u8) bool {
    const sub: zregex.Subject = .{ .wtf8 = s };
    var pos: usize = 0;
    while (sub.decodeAt(.code_unit, pos)) |d| : (pos = d.pos) if (d.invalid) return false;
    return true;
}

/// A match as byte offsets: `slots` as `Regex.execAt` fills them.
pub const Found = struct {
    slots: []?usize,

    pub fn deinit(self: Found, gpa: std.mem.Allocator) void {
        gpa.free(self.slots);
    }
};

/// `execAt` on `s8`'s UTF-16 form from UTF-16 index `index16`, with the
/// slots mapped back to WTF-8 byte offsets.
pub fn execUtf16(gpa: std.mem.Allocator, re: zregex.Regex, s8: []const u8, index16: usize) !?Found {
    const s16 = try subject.utf16FromWtf8(gpa, s8);
    defer gpa.free(s16);
    var scratch = zregex.Scratch.init(gpa);
    defer scratch.deinit();
    const slots = try gpa.alloc(?usize, re.slotCount());
    errdefer gpa.free(slots);
    var out: zregex.MatchSlots = .{ .slots = slots };
    if (!try re.execAt(.{ .utf16 = s16 }, index16, &scratch, &out, .{})) {
        gpa.free(slots);
        return null;
    }
    for (slots) |*v| {
        if (v.*) |u| v.* = try subject.utf16ToWtf8Index(s8, u);
    }
    return .{ .slots = slots };
}

/// `execAt` on the WTF-8 subject itself.
pub fn execWtf8(gpa: std.mem.Allocator, re: zregex.Regex, s8: []const u8, index8: usize) !?Found {
    var scratch = zregex.Scratch.init(gpa);
    defer scratch.deinit();
    const slots = try gpa.alloc(?usize, re.slotCount());
    errdefer gpa.free(slots);
    var out: zregex.MatchSlots = .{ .slots = slots };
    if (!try re.execAt(.{ .wtf8 = s8 }, index8, &scratch, &out, .{})) {
        gpa.free(slots);
        return null;
    }
    return .{ .slots = slots };
}

/// Both encodings from every position of `s8` (as UTF-16 indices): the
/// same outcome, with the same slots once mapped. Errors (a step limit)
/// must agree too.
pub fn expectSameInBoth(gpa: std.mem.Allocator, re: zregex.Regex, s8: []const u8) !void {
    if (!wellFormed(s8)) return;
    const n16 = try subject.wtf8ToUtf16Index(s8, s8.len);
    var i: usize = 0;
    while (i <= n16) : (i += 1) {
        const idx8 = try subject.utf16ToWtf8Index(s8, i);
        const a = execWtf8(gpa, re, s8, idx8) catch |e| {
            try std.testing.expectError(e, execUtf16(gpa, re, s8, i));
            continue;
        };
        defer if (a) |f| f.deinit(gpa);
        const b = try execUtf16(gpa, re, s8, i);
        defer if (b) |f| f.deinit(gpa);
        if ((a == null) != (b == null) or (a != null and !std.mem.eql(?usize, a.?.slots, b.?.slots))) {
            std.debug.print("\nWTF-8 and UTF-16 differ: /{s}/ on {x} from UTF-16 index {d}: {any} vs {any}\n", .{ re.getPattern(), s8, i, if (a) |f| f.slots else null, if (b) |f| f.slots else null });
            return error.TestUnexpectedResult;
        }
    }
}
