//! T0-A: every corpus pattern that gets a T0 program, run as routed (the
//! fast paths and the DFA, code unit and code point) and on the plain VM
//! (`t0_prefilters = false`: no prefilter, no DFA), at every index of each
//! subject, with and without sticky, in WTF-8 and UTF-16: all slots, or the
//! same error. The subjects: tests/corpus/dfadiff-subject.txt (ASCII, Latin,
//! Greek, CJK, emoji) and the odd ones below (lone surrogates, a pair encoded
//! apart, ill-formed bytes, LS/PS, the extended word characters).
//!
//!   zig build dfadiff -- tests/corpus/dfadiff-subject.txt files...
const std = @import("std");
const zregex = @import("zregex");
const gpa = std.heap.smp_allocator;

fn has(fl: []const u8, c: u8) bool {
    return std.mem.indexOfScalar(u8, fl, c) != null;
}

const max_slots = 256;

const Out = struct {
    err: ?anyerror = null,
    found: bool = false,
    v: [max_slots]?usize = undefined,

    fn same(a: *const Out, b: *const Out, n: usize) bool {
        const same_err = if (a.err) |x| (if (b.err) |y| x == y else false) else b.err == null;
        if (!same_err or a.found != b.found) return false;
        if (!a.found) return true;
        return std.mem.eql(?usize, a.v[0..n], b.v[0..n]);
    }
};

var scratch: zregex.Scratch = undefined;
var stats: struct { patterns: usize = 0, dfa_unit: usize = 0, dfa_point: usize = 0, runs: usize = 0, found: usize = 0, diffs: usize = 0, pats_diff: usize = 0 } = .{};

fn run(re: *zregex.Regex, subj: zregex.Subject, i: usize, o: *Out) void {
    var out: zregex.MatchSlots = .{ .slots = o.v[0..re.slotCount()] };
    o.err = null;
    o.found = false;
    if (re.execAt(subj, i, &scratch, &out, .{})) |f| o.found = f else |e| o.err = e;
}

fn compare(re: *zregex.Regex, vm: *zregex.Regex, subj: zregex.Subject, pat: []const u8, fl: []const u8) bool {
    var ok = true;
    var a: Out = .{};
    var b: Out = .{};
    for ([_]bool{ false, true }) |sticky| {
        re.sticky = sticky;
        vm.sticky = sticky;
        for (0..subj.len() + 2) |i| {
            run(re, subj, i, &a);
            run(vm, subj, i, &b);
            stats.runs += 1;
            if (a.found) stats.found += 1;
            if (!a.same(&b, re.slotCount())) {
                ok = false;
                stats.diffs += 1;
                if (stats.diffs <= 20) std.debug.print("DFA DIFF /{s}/{s} {s} sticky={} i={d}: routed={any} {any} vm={any} {any}\n", .{ pat, fl, @tagName(subj), sticky, i, a.err, a.v[0..2], b.err, b.v[0..2] });
            }
        }
    }
    return ok;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    scratch = .init(gpa);
    const subj8 = try std.Io.Dir.cwd().readFileAlloc(io, args.next() orelse return error.MissingSubject, gpa, .limited(1 << 20));
    const subj16 = try std.unicode.utf8ToUtf16LeAlloc(gpa, subj8);
    const odd8 = "ab \u{17F}x \u{212A}k caf\u{E9} \u{1F600}z\u{2028}y\u{2029}\r\n_9 \u{391}\u{3B1}! " ++
        "a\xED\xA0\x80b\xED\xB0\x80c\xED\xA0\x80\xED\xB0\x80d\x80e\xC3f\xE2\x82g\xFF\xF0\x9F\x98h \xC3\xA9";
    const odd16 = [_]u16{ 'a', 0xD800, 'b', 0xDC00, 'c', 0xDC00, 0xD800, 'd', 0xD83D, 0xDE00, 0x17F, ' ', 0x212A, 'k', 0x2028, 0xD800 };
    const subjects = [_]zregex.Subject{ .{ .wtf8 = subj8 }, .{ .utf16 = subj16 }, .{ .wtf8 = odd8 }, .{ .utf16 = &odd16 } };
    var buf: [8192]u8 = undefined;
    while (args.next()) |path| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const fl = line[0..tab];
            // npm.tsv has more columns after the pattern's hex.
            const rest = line[tab + 1 ..];
            const hex = rest[0 .. std.mem.indexOfScalar(u8, rest, '\t') orelse rest.len];
            const pat = std.fmt.hexToBytes(&buf, hex) catch continue;
            const o: zregex.CompileOptions = .{ .case_insensitive = has(fl, 'i'), .multiline = has(fl, 'm'), .dot_all = has(fl, 's'), .unicode = has(fl, 'u'), .v = has(fl, 'v'), .possessive = has(fl, 'p') };
            var re = zregex.Regex.compileWithOptions(gpa, pat, o) catch continue;
            defer re.deinit();
            const t0 = re.t0 orelse continue;
            if (re.slotCount() > max_slots) continue;
            stats.patterns += 1;
            if (t0.dfa) |d| {
                if (d.mode == .code_point) stats.dfa_point += 1 else stats.dfa_unit += 1;
            }
            var op = o;
            op.t0_prefilters = false;
            var vm = try zregex.Regex.compileWithOptions(gpa, pat, op);
            defer vm.deinit();
            var ok = true;
            for (subjects) |subj| ok = compare(&re, &vm, subj, pat, fl) and ok;
            if (!ok) stats.pats_diff += 1;
        }
    }
    std.debug.print("T0 programs {d} (DFA: code unit {d}, code point {d}); runs {d}, matched {d}; patterns with any difference {d}; DIFFERENCES {d}\n", .{ stats.patterns, stats.dfa_unit, stats.dfa_point, stats.runs, stats.found, stats.pats_diff, stats.diffs });
}
