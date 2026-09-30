//! F5a(3): every corpus pattern the dispatcher now routes from T1 to T0's
//! VM, against the backtracker (forced): all slots, every index, sticky and
//! not, WTF-8 and UTF-16. Input files: `flags<TAB>pattern-hex[<TAB>...]`.
//! UTF-16 discrepancies go to stdout as TSV for V8 arbitration.
const std = @import("std");
const zr = @import("zregex");
const gpa = std.heap.smp_allocator;

const subjects = [_][]const u8{
    "",                           "a",                     "ab",                  "aAb",                "abc abc",                  "Zk\u{212A}s\u{17F}",
    "\u{E9}\u{C9}\u{DF}",         "0123 45",               "\u{1F600}x\u{1F600}", "a\nb\r\nc\u{2028}d", "_\xff\xc3",                "ss\u{3C3}\u{3A3}\u{3C2}",
    "\u{C0}\u{E0}\u{D6}\u{F6}",   "--]",                   "aaaaab",              "abab ab",            "\u{E9}\u{A9}x\u{1F600}y",  "\xED\xA0\x80a\xED\xB0\x80",
    "\xED\xA0\xBD\xED\xB8\x80",   "\x80\xC3a\xE2\x82",     "\xC3\xA9\xE9\xA9",    "a\u{1D306}b\u{E9}",  "\u{3B1}\u{3B2}\u{391}x 9", "ab\nab xyz09",
    "\u{4E00}\u{3042}\u{30A2}-_", "A\u{1F600}b\u{1F601}C", "\u{FEFF}\u{A0} \t",
};

fn has(fl: []const u8, c: u8) bool {
    return std.mem.indexOfScalar(u8, fl, c) != null;
}

const Res = struct { err: ?anyerror = null, found: bool = false, slots: [64]?usize = undefined };

fn run(re: *zr.Regex, subj: zr.Subject, i: usize, scratch: *zr.Scratch) Res {
    var r: Res = .{};
    var out: zr.MatchSlots = .{ .slots = r.slots[0..re.slotCount()] };
    if (re.execAt(subj, i, scratch, &out, .{})) |f| r.found = f else |e| r.err = e;
    return r;
}

fn same(a: *const Res, b: *const Res, n: usize) bool {
    if (a.err != null or b.err != null) return a.err == b.err;
    return a.found == b.found and (!a.found or std.mem.eql(?usize, a.slots[0..n], b.slots[0..n]));
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    var s1: zr.Scratch = .init(gpa);
    var s2: zr.Scratch = .init(gpa);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var st: struct { files: usize = 0, patterns: usize = 0, t1: usize = 0, routed: usize = 0, runs: usize = 0, bt_err: usize = 0, diffs8: usize = 0, diffs16: usize = 0, diff_patterns: usize = 0 } = .{};
    while (args.next()) |path| {
        st.files += 1;
        const data = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(256 << 20));
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var cols = std.mem.splitScalar(u8, line, '\t');
            const fl = cols.next().?;
            const hex = cols.next() orelse continue;
            const key = try std.fmt.allocPrint(gpa, "{s}\t{s}", .{ fl, hex });
            if ((try seen.getOrPut(gpa, key)).found_existing) continue;
            st.patterns += 1;
            if (has(fl, 'p')) continue;
            const pat = try gpa.alloc(u8, hex.len / 2);
            _ = std.fmt.hexToBytes(pat, hex) catch continue;
            const flags = zr.internal.analysis.Flags.parse(fl) catch continue;
            const a = try zr.internal.analyze(gpa, pat, flags);
            if (a.min_tier != .unicode) continue;
            st.t1 += 1;
            const o: zr.CompileOptions = .{ .case_insensitive = flags.i, .multiline = flags.m, .dot_all = flags.s, .unicode = flags.u, .v = flags.v };
            var vm_re = zr.Regex.compileWithOptions(gpa, pat, o) catch continue;
            defer vm_re.deinit();
            if (vm_re.t0 == null) continue;
            st.routed += 1;
            var ob = o;
            ob.force_tier = .expert;
            var bt_re = try zr.Regex.compileWithOptions(gpa, pat, ob);
            defer bt_re.deinit();
            const n = vm_re.slotCount();
            if (n > 64) continue;
            var differs = false;
            for (subjects) |s| {
                const s16 = try zr.internal.subject.utf16FromWtf8(gpa, s);
                defer gpa.free(s16);
                for ([_]zr.Subject{ .{ .wtf8 = s }, .{ .utf16 = s16 } }) |subj| {
                    for ([_]bool{ false, true }) |sticky| {
                        vm_re.sticky = sticky;
                        bt_re.sticky = sticky;
                        for (0..subj.len() + 2) |i| {
                            st.runs += 1;
                            const b = run(&bt_re, subj, i, &s2);
                            if (b.err) |e| if (e == error.StepLimitExceeded or e == error.BacktrackStackExhausted) {
                                st.bt_err += 1;
                                continue;
                            };
                            const v = run(&vm_re, subj, i, &s1);
                            if (same(&v, &b, n)) continue;
                            differs = true;
                            switch (subj) {
                                .wtf8 => st.diffs8 += 1,
                                .utf16 => |u| {
                                    st.diffs16 += 1;
                                    try w.print("{s}\t{s}\t", .{ fl, hex });
                                    for (u, 0..) |cu, k| try w.print("{s}{x}", .{ if (k == 0) "" else ",", cu });
                                    try w.print("\t{d}\t{d}\t", .{ i, @intFromBool(sticky) });
                                    for ([_]*const Res{ &v, &b }, 0..) |r, k| {
                                        if (k == 1) try w.writeByte('\t');
                                        if (r.err) |e| {
                                            try w.print("{s}", .{@errorName(e)});
                                        } else if (!r.found) {
                                            try w.writeAll("null");
                                        } else for (r.slots[0..n], 0..) |sl, j| {
                                            if (j > 0) try w.writeByte(',');
                                            if (sl) |x| try w.print("{d}", .{x}) else try w.writeAll("-1");
                                        }
                                    }
                                    try w.writeByte('\n');
                                },
                            }
                        }
                    }
                }
            }
            if (differs) st.diff_patterns += 1;
        }
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, out.written());
    var e: std.Io.Writer.Allocating = .init(gpa);
    try e.writer.print("files {d} patterns {d} T1 {d} routed-to-VM {d} runs {d} bt-step-limit {d} diffs wtf8 {d} utf16 {d} diff-patterns {d}\n", .{ st.files, st.patterns, st.t1, st.routed, st.runs, st.bt_err, st.diffs8, st.diffs16, st.diff_patterns });
    try std.Io.File.stderr().writeStreamingAll(init.io, e.written());
}
