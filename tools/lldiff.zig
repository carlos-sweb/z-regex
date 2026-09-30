//! F6a(3): LookLinear on vs off on the backtracker (force_tier = .expert),
//! every pattern with a lookahead (and no lookbehind) of the corpora, every
//! subject and index, both encodings, all slots. Input: TSV flags \t hex
//! [\t ...]. Reports differences (must be 0) and how many sites delegate.
//! B′ (F6b step 1): with `--lookbehind` first, the patterns with a
//! lookbehind instead (fixed length since B′; the rest fail to compile).
const std = @import("std");
const z = @import("zregex");
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

const Res = struct { err: ?anyerror, found: bool };

fn run(re: *const z.Regex, s: z.Subject, i: usize, scratch: *z.Scratch, slots: []?usize) Res {
    @memset(slots, null);
    var out: z.MatchSlots = .{ .slots = slots };
    const f = re.execAt(s, i, scratch, &out, .{}) catch |e| return .{ .err = e, .found = false };
    return .{ .err = null, .found = f };
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    var lookbehind = false;
    var first = args.next();
    if (first != null and std.mem.eql(u8, first.?, "--lookbehind")) {
        lookbehind = true;
        first = args.next();
    }
    var s_on = z.Scratch.init(gpa);
    var s_off = z.Scratch.init(gpa);
    var patterns: usize = 0;
    var with_sites: usize = 0;
    var sites: usize = 0;
    var runs: usize = 0;
    var diffs: usize = 0;
    var errs: usize = 0;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var buf: [65536]u8 = undefined;
    var next_path = first;
    while (next_path) |path| : (next_path = args.next()) {
        const data = try std.Io.Dir.cwd().readFileAlloc(init.io, path, gpa, .limited(64 << 20));
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var cols = std.mem.splitScalar(u8, line, '\t');
            const fl = cols.next().?;
            const hex = cols.next().?;
            const key = try std.fmt.allocPrint(gpa, "{s}\t{s}", .{ fl, hex });
            if ((try seen.getOrPut(gpa, key)).found_existing) continue;
            if (hex.len / 2 > buf.len) continue;
            const pat = try std.fmt.hexToBytes(&buf, hex);
            const lb_text = std.mem.indexOf(u8, pat, "(?<=") != null or std.mem.indexOf(u8, pat, "(?<!") != null;
            if (lookbehind) {
                if (!lb_text) continue;
            } else if (std.mem.indexOf(u8, pat, "(?=") == null and std.mem.indexOf(u8, pat, "(?!") == null) continue;
            const o: z.CompileOptions = .{ .case_insensitive = has(fl, 'i'), .multiline = has(fl, 'm'), .dot_all = has(fl, 's'), .unicode = has(fl, 'u'), .v = has(fl, 'v'), .possessive = has(fl, 'p'), .force_tier = .expert };
            var on = z.Regex.compileWithOptions(gpa, pat, o) catch continue;
            defer on.deinit();
            if (hasLookbehind(on.compiled.bytecode) != lookbehind) continue;
            var oo = o;
            oo.t2_look_linear = false;
            var off = try z.Regex.compileWithOptions(gpa, pat, oo);
            defer off.deinit();
            patterns += 1;
            if (on.compiled.linear.len > 0) with_sites += 1;
            sites += on.compiled.linear.len;
            if (on.compiled.linear.len == 0) continue;
            const n = on.slotCount();
            const a = try gpa.alloc(?usize, n);
            defer gpa.free(a);
            const b = try gpa.alloc(?usize, n);
            defer gpa.free(b);
            var reported = false;
            for (subjects) |subj| {
                const s16 = try z.internal.subject.utf16FromWtf8(gpa, subj);
                defer gpa.free(s16);
                for ([_]z.Subject{ .{ .wtf8 = subj }, .{ .utf16 = s16 } }) |s| {
                    var i: usize = 0;
                    while (i <= s.len()) : (i += 1) {
                        if (!s.isPosition(i)) continue;
                        const ra = run(&on, s, i, &s_on, a);
                        const rb = run(&off, s, i, &s_off, b);
                        runs += 1;
                        if (ra.err != null or rb.err != null) errs += 1;
                        const same = ra.err == rb.err and ra.found == rb.found and (!ra.found or std.mem.eql(?usize, a, b));
                        if (!same) {
                            diffs += 1;
                            if (!reported) {
                                reported = true;
                                std.debug.print("DIFF /{s}/{s} subj {x} i={d}: on {any} {any} off {any} {any}\n", .{ pat, fl, subj, i, ra, a, rb, b });
                            }
                        }
                    }
                }
            }
        }
    }
    std.debug.print("{s} {d}; with delegated sites {d} ({d} sites); runs {d}; errors (either) {d}; DIFFERENCES {d}; VM evals {d}, memo hits {d}\n", .{ if (lookbehind) "patterns with lookbehind" else "patterns with lookahead (no lookbehind)", patterns, with_sites, sites, runs, errs, diffs, s_on.bt.look_evals, s_on.bt.look_memo_hits });
}

fn hasLookbehind(code: []const u8) bool {
    var pc: usize = 0;
    while (pc < code.len) {
        const inst = z.internal.tier2.format.decodeInstruction(code, pc) catch return false;
        if (inst.opcode == .LOOKBEHIND_FIXED or inst.opcode == .NEGATIVE_LOOKBEHIND_FIXED) return true;
        pc += inst.size;
    }
    return false;
}
