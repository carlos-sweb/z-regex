//! F4a(4): every corpus pattern the dispatcher routes to the VM, run with
//! prefilters (default) vs the backtracker (forced) and vs the plain VM.
//! F4b(2), `--slots out.tsv files...`: every tagged-eligible T0 pattern,
//! D5's two passes vs one tagged pass vs the backtracker, all slots; the
//! UTF-16 discrepancies with the backtracker go to out.tsv for arbiter.mjs.
//! `--v8 cases.tsv`: V8's expected results (from differential-v8's JSON,
//! via arbiter.mjs) against the two passes.
const std = @import("std");
const new = @import("zregex");
const gpa = std.heap.smp_allocator;

const subjects = [_][]const u8{
    "",                         "a",                    "ab",              "aAb",           "abc abc",          "Zk\u{212A}s\u{17F}",
    "\u{E9}\u{C9}\u{DF}",       "0123 45",              "\u{1F600}x\u{1F600}", "a\nb\r\nc\u{2028}d", "_\xff\xc3",  "ss\u{3C3}\u{3A3}\u{3C2}",
    "\u{C0}\u{E0}\u{D6}\u{F6}", "--]",                  "aaaaab",          "abab ab",       "\u{E9}\u{A9}x\u{1F600}y", "\xED\xA0\x80a\xED\xB0\x80",
    "\xED\xA0\xBD\xED\xB8\x80", "\x80\xC3a\xE2\x82",    "\xC3\xA9\xE9\xA9", "a\u{1D306}b\u{E9}",
};

fn has(fl: []const u8, c: u8) bool {
    return std.mem.indexOfScalar(u8, fl, c) != null;
}

const Out = struct { err: ?anyerror = null, found: bool = false, s: usize = 0, e: usize = 0 };
fn eq(a: Out, b: Out) bool {
    const same_err = if (a.err) |x| (if (b.err) |y| x == y else false) else b.err == null;
    return same_err and a.found == b.found and a.s == b.s and a.e == b.e;
}

var scratch: new.Scratch = undefined;
var stats: struct { runs: usize = 0, found: usize = 0, steplimit: usize = 0, bt_diffs: usize = 0, plain_diffs: usize = 0 } = .{};
var kinds = [_]usize{0} ** 4;

fn run(re: *new.Regex, subj: new.Subject, i: usize) Out {
    var buf: [256]?usize = undefined;
    var out: new.MatchSlots = .{ .slots = buf[0..re.slotCount()] };
    var o: Out = .{};
    if (re.execAt(subj, i, &scratch, &out, .{})) |f| {
        o.found = f;
        if (f) {
            o.s = buf[0].?;
            o.e = buf[1].?;
        }
    } else |err| o.err = err;
    return o;
}

fn compare(re: *new.Regex, bt: *new.Regex, plain: *new.Regex, subj: new.Subject, pat: []const u8, fl: []const u8) void {
    for ([_]bool{ false, true }) |sticky| {
        re.sticky = sticky;
        bt.sticky = sticky;
        plain.sticky = sticky;
        for (0..subj.len() + 2) |i| {
            const a = run(re, subj, i);
            const b = run(bt, subj, i);
            const c = run(plain, subj, i);
            stats.runs += 1;
            if (a.found) stats.found += 1;
            if (!eq(a, c)) {
                stats.plain_diffs += 1;
                if (stats.plain_diffs <= 20) std.debug.print("PREFILTER DIFF /{s}/{s} {s} sticky={} i={d}: pf={any} plain={any}\n", .{ pat, fl, @tagName(subj), sticky, i, a, c });
            }
            if (b.err != null and b.err.? == error.StepLimitExceeded) {
                stats.steplimit += 1;
                continue;
            }
            if (!eq(a, b)) {
                stats.bt_diffs += 1;
                if (stats.bt_diffs <= 20) std.debug.print("BT DIFF /{s}/{s} {s} sticky={} i={d}: vm={any} bt={any}\n", .{ pat, fl, @tagName(subj), sticky, i, a, b });
            }
        }
    }
}

const Slots = struct {
    err: ?anyerror = null,
    found: bool = false,
    n: usize = 0,
    v: [64]?usize = undefined,

    fn same(a: *const Slots, b: *const Slots) bool {
        const same_err = if (a.err) |x| (if (b.err) |y| x == y else false) else b.err == null;
        if (!same_err or a.found != b.found) return false;
        if (!a.found) return true;
        return std.mem.eql(?usize, a.v[0..a.n], b.v[0..b.n]);
    }
};

var sstats: struct { patterns: usize = 0, runs: usize = 0, found: usize = 0, steplimit: usize = 0, mismatch: usize = 0, one_pass: usize = 0, bt8: usize = 0, bt16: usize = 0, pats_diff: usize = 0 } = .{};

/// Long subjects (the pattern-derived ones of long patterns): every offset
/// within 8 of either end, and one in ceil(len / 64) in between.
fn skipOffset(len: usize, i: usize) bool {
    if (len <= 64 or i < 8 or i + 10 > len + 2) return false;
    return i % ((len + 63) / 64) != 0;
}

fn tagRun(comptime Unit: type, tp: *const new.tier0.Program, in: []const Unit, i: usize, sticky: bool, two: bool, vs: *new.tier0.VmScratch) Slots {
    var o: Slots = .{ .n = tp.nslots };
    const r = if (two) new.tier0.execCaptures(tp, Unit, in, .code_unit, i, sticky, vs, &o.v) else new.tier0.execTagged(tp, Unit, in, .code_unit, i, sticky, null, vs, &o.v);
    if (r) |f| o.found = f else |e| o.err = e;
    return o;
}

fn btRun(bt: *new.Regex, subj: new.Subject, i: usize, n: usize) Slots {
    var o: Slots = .{ .n = n };
    var out: new.MatchSlots = .{ .slots = o.v[0..n] };
    if (bt.execAt(subj, i, &scratch, &out, .{ .max_steps = 200_000 })) |f| o.found = f else |e| o.err = e;
    return o;
}

fn writeSlots(w: *std.Io.Writer, o: *const Slots) !void {
    if (o.err) |e| return w.print("{s}", .{@errorName(e)});
    if (!o.found) return w.writeAll("null");
    for (o.v[0..o.n], 0..) |x, k| {
        if (k > 0) try w.writeByte(',');
        if (x) |y| try w.print("{d}", .{y}) else try w.writeAll("-1");
    }
}

fn writeUnits(w: *std.Io.Writer, units: []const u16) !void {
    for (units, 0..) |u, k| {
        if (k > 0) try w.writeByte(',');
        try w.print("{d}", .{u});
    }
}

fn slotsMain(io: std.Io, args: anytype, out_path: []const u8) !void {
    var vs = new.tier0.VmScratch.init(gpa);
    var out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer out_file.close(io);
    var wbuf: [1 << 16]u8 = undefined;
    var fw = out_file.writer(io, &wbuf);
    const w = &fw.interface;
    var buf: [65536]u8 = undefined;
    const t_start = std.Io.Timestamp.now(io, .awake).nanoseconds;
    while (args.next()) |path| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var cols = std.mem.splitScalar(u8, line, '\t');
            const fl = cols.next().?;
            const hex = cols.next().?;
            if (hex.len / 2 > buf.len) continue;
            const pat = try std.fmt.hexToBytes(&buf, hex);
            if (has(fl, 'p')) continue;
            const f = new.analysis.Flags.parse(fl) catch continue;
            const an = try new.analyze(gpa, pat, f);
            if (an.min_tier != .regular) continue;
            const fe = try new.lower.Frontend.init(gpa, pat, .{ .unicode = f.u, .v = f.v }, .{ .ignore_case = f.i, .multiline = f.m, .dot_all = f.s });
            defer fe.deinit();
            if (new.tier0.compile_mod.checkTagged(fe.root) != null) continue;
            const tp = try new.tier0.compileWith(gpa, fe.root, .{ .tagged = true });
            defer tp.deinit(gpa);
            if (tp.nslots > 64) continue;
            sstats.patterns += 1;
            var bt = try new.Regex.compileWithOptions(gpa, pat, .{ .case_insensitive = f.i, .multiline = f.m, .dot_all = f.s, .force_tier = .expert });
            defer bt.deinit();
            const pat16 = try new.subject.utf16FromWtf8(gpa, pat);
            defer gpa.free(pat16);
            var extra: [3][]const u8 = .{ pat, "", "" };
            const doubled = try std.mem.concat(gpa, u8, &.{ "x", pat, pat, "y" });
            defer gpa.free(doubled);
            extra[1] = doubled;
            extra[2] = if (pat.len > 1) pat[1..] else "";
            const t_pat = std.Io.Timestamp.now(io, .awake).nanoseconds;
            const before = sstats.bt8 + sstats.bt16 + sstats.mismatch + sstats.one_pass;
            for (subjects ++ [_][]const u8{ "", "", "" }, 0..) |s0, k| {
                const s = if (k < subjects.len) s0 else extra[k - subjects.len];
                const s16 = try new.subject.utf16FromWtf8(gpa, s);
                defer gpa.free(s16);
                for ([_]bool{ false, true }) |sticky| {
                    bt.sticky = sticky;
                    for (0..s.len + 2) |i| {
                        if (skipOffset(s.len, i)) continue;
                        const a = tagRun(u8, &tp, s, i, sticky, true, &vs);
                        const c = tagRun(u8, &tp, s, i, sticky, false, &vs);
                        const b = btRun(&bt, .{ .wtf8 = s }, i, tp.nslots);
                        sstats.runs += 1;
                        if (a.found) sstats.found += 1;
                        if (a.err != null and a.err.? == error.TwoPassMismatch) {
                            sstats.mismatch += 1;
                            if (sstats.mismatch <= 10) std.debug.print("MISMATCH /{s}/{s} wtf8 i={d} sticky={}\n", .{ pat, fl, i, sticky });
                        }
                        if (!a.same(&c)) {
                            sstats.one_pass += 1;
                            if (sstats.one_pass <= 10) std.debug.print("ONEPASS /{s}/{s} wtf8 i={d} sticky={}: two={any} one={any}\n", .{ pat, fl, i, sticky, a.v[0..a.n], c.v[0..c.n] });
                        }
                        if (b.err != null and b.err.? == error.StepLimitExceeded) {
                            sstats.steplimit += 1;
                        } else if (!a.same(&b)) sstats.bt8 += 1;
                    }
                    for (0..s16.len + 2) |i| {
                        if (skipOffset(s16.len, i)) continue;
                        const a = tagRun(u16, &tp, s16, i, sticky, true, &vs);
                        const c = tagRun(u16, &tp, s16, i, sticky, false, &vs);
                        const b = btRun(&bt, .{ .utf16 = s16 }, i, tp.nslots);
                        sstats.runs += 1;
                        if (a.found) sstats.found += 1;
                        if (a.err != null and a.err.? == error.TwoPassMismatch) sstats.mismatch += 1;
                        if (!a.same(&c)) sstats.one_pass += 1;
                        const limited = b.err != null and b.err.? == error.StepLimitExceeded;
                        if (limited) sstats.steplimit += 1;
                        if (limited or !a.same(&b)) {
                            if (!limited) sstats.bt16 += 1;
                            try w.print("{s}\t", .{fl});
                            try writeUnits(w, pat16);
                            try w.writeByte('\t');
                            try writeUnits(w, s16);
                            try w.print("\t{d}\t{d}\t", .{ i, @intFromBool(sticky) });
                            try writeSlots(w, &a);
                            try w.writeByte('\t');
                            try writeSlots(w, &b);
                            try w.writeByte('\n');
                        }
                    }
                }
            }
            if (sstats.bt8 + sstats.bt16 + sstats.mismatch + sstats.one_pass != before) sstats.pats_diff += 1;
            const dt = std.Io.Timestamp.now(io, .awake).nanoseconds - t_pat;
            if (dt > 200_000_000) std.debug.print("SLOW {d} ms nslots {d} insts {d} /{s}/{s}\n", .{ @divTrunc(dt, 1_000_000), tp.nslots, tp.insts.len, pat[0..@min(pat.len, 120)], fl });
            if (sstats.patterns % 1000 == 0) std.debug.print("progress {d} patterns, {d} runs, {d} s\n", .{ sstats.patterns, sstats.runs, @divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds - t_start, 1_000_000_000) });
        }
    }
    try w.flush();
    std.debug.print("tagged-eligible T0 {d}; runs {d}, matched {d}, bt StepLimit {d}; TwoPassMismatch {d}, two passes vs one {d}; vs backtracker: WTF-8 {d}, UTF-16 {d} (to arbiter), patterns with any difference {d}\n", .{ sstats.patterns, sstats.runs, sstats.found, sstats.steplimit, sstats.mismatch, sstats.one_pass, sstats.bt8, sstats.bt16, sstats.pats_diff });
}

/// `--v8 cases.tsv`: the T0 tagged-eligible divergences of a
/// differential-v8 JSON, the two passes from 0 on the UTF-16 subject
/// against V8's expected slots.
fn v8Main(io: std.Io, path: []const u8) !void {
    var vs = new.tier0.VmScratch.init(gpa);
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20));
    var buf: [65536]u8 = undefined;
    var total: usize = 0;
    var t0: usize = 0;
    var same: usize = 0;
    var any_t0: usize = 0;
    var unclassified: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        total += 1;
        var cols = std.mem.splitScalar(u8, line, '\t');
        const fl = cols.next().?;
        const pat = try std.fmt.hexToBytes(&buf, cols.next().?);
        const subj_col = cols.next().?;
        const exp_col = cols.next().?;
        const kind = cols.next().?;
        const f = new.analysis.Flags.parse(fl) catch continue;
        const an = new.analyze(gpa, pat, f) catch continue;
        std.debug.print("TIER {s} {s}\n", .{ if (an.min_tier) |t| @tagName(t) else "none", kind });
        if (an.min_tier != .regular) {
            if (an.min_tier == null) unclassified += 1;
            continue;
        }
        any_t0 += 1;
        const fe = new.lower.Frontend.init(gpa, pat, .{ .unicode = f.u, .v = f.v }, .{ .ignore_case = f.i, .multiline = f.m, .dot_all = f.s }) catch continue;
        defer fe.deinit();
        if (new.tier0.compile_mod.checkTagged(fe.root)) |w| {
            std.debug.print("NOTTAGGED {s} /{s}/{s}\n", .{ @tagName(w), pat, fl });
            continue;
        }
        const tp = try new.tier0.compileWith(gpa, fe.root, .{ .tagged = true });
        defer tp.deinit(gpa);
        t0 += 1;
        var s16: std.ArrayListUnmanaged(u16) = .empty;
        defer s16.deinit(gpa);
        if (subj_col.len > 0) {
            var it = std.mem.splitScalar(u8, subj_col, ',');
            while (it.next()) |u| try s16.append(gpa, try std.fmt.parseInt(u16, u, 10));
        }
        const a = tagRun(u16, &tp, s16.items, 0, false, true, &vs);
        var got: std.Io.Writer.Allocating = .init(gpa);
        defer got.deinit();
        try writeSlots(&got.writer, &a);
        const ok = std.mem.eql(u8, got.written(), exp_col);
        if (ok) same += 1;
        const why = new.tier0.check(fe.root);
        std.debug.print("{s} {s} f4a={s} /{s}/{s} vm={s} v8={s}\n", .{ if (ok) "SAME" else "DIFF", kind, if (why) |w| @tagName(w) else "eligible", pat, fl, got.written(), exp_col });
    }
    std.debug.print("divergences {d}; T0 {d} (unclassified {d}); T0 tagged-eligible {d}; two passes = V8: {d}\n", .{ total, any_t0, unclassified, t0, same });
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    scratch = .init(gpa);
    scratch = .init(gpa);
    var routed: usize = 0;
    var routed_tagged: usize = 0;
    var buf: [8192]u8 = undefined;
    var first_path: ?[]const u8 = args.next();
    if (first_path) |a| if (std.mem.eql(u8, a, "--slots")) return slotsMain(init.io, &args, args.next().?);
    if (first_path) |a| if (std.mem.eql(u8, a, "--v8")) return v8Main(init.io, args.next().?);
    while (if (first_path) |p0| blk: {
        first_path = null;
        break :blk p0;
    } else args.next()) |path| {
        const data = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(64 << 20));
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const tab = std.mem.indexOfScalar(u8, line, '\t').?;
            const fl = line[0..tab];
            const pat = try std.fmt.hexToBytes(&buf, line[tab + 1 ..]);
            const o: new.CompileOptions = .{ .case_insensitive = has(fl, 'i'), .multiline = has(fl, 'm'), .dot_all = has(fl, 's'), .unicode = has(fl, 'u'), .v = has(fl, 'v'), .possessive = has(fl, 'p') };
            var re = new.Regex.compileWithOptions(gpa, pat, o) catch continue;
            defer re.deinit();
            const t0 = re.t0 orelse continue;
            if (re.slotCount() > 256) continue;
            routed += 1;
            {
                // Tagged when tier0.check rejects it (what route() does).
                const fe = try new.lower.Frontend.init(gpa, pat, .{ .unicode = o.unicode, .v = o.v, .possessive = o.possessive }, .{ .ignore_case = o.case_insensitive, .multiline = o.multiline, .dot_all = o.dot_all });
                defer fe.deinit();
                if (new.tier0.check(fe.root) != null) routed_tagged += 1;
            }
            kinds[@intFromEnum(std.meta.activeTag(t0.prefilter.kind))] += 1;
            var ob = o;
            ob.force_tier = .expert;
            var bt = try new.Regex.compileWithOptions(gpa, pat, ob);
            defer bt.deinit();
            var op = o;
            op.t0_prefilters = false;
            var plain = try new.Regex.compileWithOptions(gpa, pat, op);
            defer plain.deinit();
            var extra: [3][]const u8 = .{ pat, "", "" };
            const doubled = try std.mem.concat(gpa, u8, &.{ "x", pat, pat, "y" });
            defer gpa.free(doubled);
            extra[1] = doubled;
            extra[2] = if (pat.len > 1) pat[1..] else "";
            for (subjects ++ [_][]const u8{ "", "", "" }, 0..) |s0, k| {
                const s = if (k < subjects.len) s0 else extra[k - subjects.len];
                const s16 = try new.subject.utf16FromWtf8(gpa, s);
                defer gpa.free(s16);
                compare(&re, &bt, &plain, .{ .wtf8 = s }, pat, fl);
                compare(&re, &bt, &plain, .{ .utf16 = s16 }, pat, fl);
            }
        }
    }
    std.debug.print("tagged programs {d}; routed {d} (none {d}, literal {d}, class_run {d}, first {d}); runs {d}, matched {d}, bt StepLimit {d}; DISCREPANCIES (bounds) vs backtracker {d}, vs plain VM {d}\n", .{ routed_tagged, routed, kinds[0], kinds[1], kinds[2], kinds[3], stats.runs, stats.found, stats.steplimit, stats.bt_diffs, stats.plain_diffs });
}
