//! HIR contract (docs/REGEX_TIERS_PLAN.md, F2c): a CharSet node's `set` is
//! what the node matches. T0/T1 will read only `set`, while the backtracker's
//! bytecode follows `encoding_hint`, so the two must agree: for a pattern that
//! lowers to one char_set node, `set.contains(cp)` must equal "the compiled
//! program matches the encoding of cp at position 0 and consumes all of it".

const std = @import("std");
const zregex = @import("zregex");
const testing = std.testing;

const Case = struct { pattern: []const u8, flags: []const u8 };

const atoms = [_][]const u8{
    "\\d",        "\\D",         "\\w",       "\\W",       "\\s",                "\\S",
    ".",          "\\p{L}",      "\\P{L}",    "\\p{Lu}",   "\\P{Script=Greek}",  "\\p{scx=Latin}",
    "\\p{ASCII}", "\\P{Any}",    "[^]",       "[]",        "[a-z]",              "[^a-z]",
    "[ab]",       "[^ab]",       "[a-cX-Z0]", "[\\u{E9}]", "[^\\u{1F600}]",      "[a-z\\u{E9}]",
    "[^\\P{L}]",  "[\\P{L}\\d]", "[\\s\\S]",  "[^\\W\\d]", "[\\u{C0}-\\u{D6}k]",
};
const flag_sets = [_][]const u8{ "", "i", "s", "u", "iu", "is" };
const set_ops = [_][]const u8{ "[\\p{L}--[a-z]]", "[[^a-z]&&\\p{L}]", "[^\\p{Lu}&&[A-F]]", "[[\\u{E9}\\u{C9}]--\\p{Ll}]" };

fn has(flags: []const u8, c: u8) bool {
    return std.mem.indexOfScalar(u8, flags, c) != null;
}

fn check(pattern: []const u8, flags: []const u8) !void {
    const a = testing.allocator;
    const u = has(flags, 'u') or has(flags, 'v');
    var lexer = zregex.Lexer.init(pattern);
    lexer.unicode_mode = u;
    lexer.v_mode = has(flags, 'v');
    var parser = try zregex.Parser.init(a, &lexer);
    defer parser.deinit();
    const ast = try parser.parse();
    defer ast.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const root = try zregex.lower.lower(arena.allocator(), ast, .{ .ignore_case = has(flags, 'i'), .dot_all = has(flags, 's') }, &.{});
    const body = root.modifier_scope.body;
    // `[a]`-style lone members lower to a literal; only char_set nodes here.
    if (body.* != .char_set) return;
    const set = body.char_set.set;

    var re = try zregex.Regex.compileWithOptions(a, pattern, .{ .case_insensitive = has(flags, 'i'), .dot_all = has(flags, 's'), .unicode = u, .v = has(flags, 'v') });
    defer re.deinit();

    var points: std.ArrayListUnmanaged(u32) = .empty;
    defer points.deinit(a);
    var cp: u32 = 0;
    while (cp < 0x300) : (cp += 1) try points.append(a, cp);
    while (cp <= 0x10FFFF) : (cp += 4099) try points.append(a, cp);
    try points.appendSlice(a, &.{ 0x2028, 0x2029, 0x3000, 0x10FFFF, 0xD800, 0xDFFF, 0x1F600, 0x212A });
    for (set.ranges[0..@min(set.ranges.len, 64)]) |r| try points.appendSlice(a, &.{ r.lo -| 1, r.lo, r.hi, @min(r.hi + 1, 0x10FFFF) });

    for (points.items) |p| {
        var enc: [4]u8 = undefined;
        const input: []const u8 = if (p >= 0xD800 and p <= 0xDFFF) blk: {
            // WTF-8 lone surrogate
            enc = .{ 0xED, @intCast(0x80 | ((p >> 6) & 0x3F)), @intCast(0x80 | (p & 0x3F)), 0 };
            break :blk enc[0..3];
        } else enc[0 .. std.unicode.utf8Encode(@intCast(p), &enc) catch unreachable];
        const m = try re.findAt(input, 0);
        const matched = if (m) |x| blk: {
            defer x.deinit();
            break :blk x.start == 0 and x.end == input.len;
        } else false;
        if (matched != set.contains(p)) {
            std.debug.print("\n/{s}/{s} U+{X:0>4}: matcher {}, HIR set {} (hint {s})\n", .{ pattern, flags, p, matched, set.contains(p), @tagName(body.char_set.encoding_hint) });
            return error.TestUnexpectedResult;
        }
    }
    // A lone invalid byte decodes as its value.
    for ([_]u8{ 0x80, 0xC3, 0xFF }) |b| {
        const input = [_]u8{b};
        const m = try re.findAt(&input, 0);
        const matched = if (m) |x| blk: {
            defer x.deinit();
            break :blk x.end == 1;
        } else false;
        if (matched != set.contains(b)) {
            std.debug.print("\n/{s}/{s} byte {X}: matcher {}, HIR set {}\n", .{ pattern, flags, b, matched, set.contains(b) });
            return error.TestUnexpectedResult;
        }
    }
}

test "HIR contract: a char_set node's set is what the backtracker matches" {
    for (atoms) |p| for (flag_sets) |f| try check(p, f);
    for (set_ops) |p| for ([_][]const u8{ "v", "iv" }) |f| try check(p, f);
}
