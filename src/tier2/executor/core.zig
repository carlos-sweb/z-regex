//! The explicit-stack backtracker's core (F6b step 1, B′): its state
//! (subject, capture slots, loop guards, star positions, on `Scratch`'s
//! buffers) and the checks of single atoms (characters, sets, properties,
//! backreferences, line terminators, word boundaries) that `backtrack.zig`
//! runs. Until B′ this was `recursive_matcher.zig`, whose control flow
//! (a native stack frame per instruction, D14/D15) and 100-character
//! lookbehind window (D7) are gone: `backtrack.zig` runs every pattern.

const std = @import("std");
const Allocator = std.mem.Allocator;
const opcodes = @import("../bytecode/opcodes.zig");
const format = @import("../bytecode/format.zig");
const properties = @import("unicode").properties;
const casefold = @import("unicode").casefold;
const word = @import("ir").word;
const CharSet = @import("ir").charset.CharSet;
const subject_mod = @import("subject");
const Subject = subject_mod.Subject;
const Decoded = subject_mod.Decoded;
const Mode = subject_mod.Mode;

const Opcode = opcodes.Opcode;
const Choice = @import("backtrack.zig").Choice;
const TrailEntry = @import("backtrack.zig").TrailEntry;
const LookMemo = @import("backtrack.zig").LookMemo;
const tier0 = @import("tier0");
const Instruction = format.Instruction;

/// Capture slots kept inline in the core (no allocation); patterns with
/// more groups use `Scratch.captures`, sized to the pattern (D9: no cap).
const INLINE_CAPTURES = 16;

/// Default `ExecLimits.max_steps` (ReDoS protection), per start position.
pub const DEFAULT_MAX_STEPS: usize = 1_000_000;

/// Capture group boundaries
pub const CaptureGroup = struct {
    start: ?usize = null,
    end: ?usize = null,

    pub fn isValid(self: CaptureGroup) bool {
        return self.start != null and self.end != null;
    }
};

/// A loop back-edge being re-entered: the loop head's pc and the position
/// it was (re)entered at. An iteration that comes back to the same one
/// made no progress and is refused (`backtrack.zig`'s `enterBackEdge`).
pub const LoopState = struct {
    pc: usize,
    pos: usize,
};

/// The explicit-stack backtracker's mirror of its loop guards past
/// `backtrack.zig`'s `guard_set_min` (F7a(3), F7b(5)): an open-addressing
/// set with linear probing. Removals always undo insertions in reverse
/// order (the guards are a stack, truncated to a choicepoint's height), so
/// a removal only empties the slot: when a key was inserted, every slot
/// its probe crossed held an older key, present as long as it is, so no
/// present key's probe crosses an emptied slot. `rebuild` reinserts the
/// stack in order, which keeps that true. Smaller in code than
/// `std.AutoHashMapUnmanaged` (no tombstones, no metadata).
pub const GuardSet = struct {
    /// Power-of-two length, or empty; `free_pc` marks a free slot. With
    /// `count == 0` every slot is free, so reusing the table after its keys
    /// are gone costs nothing (a retained table can be large).
    slots: []LoopState = &.{},
    count: usize = 0,

    const free_pc = std.math.maxInt(usize);

    pub fn deinit(self: *GuardSet, gpa: Allocator) void {
        gpa.free(self.slots);
        self.* = .{};
    }

    pub fn clearRetainingCapacity(self: *GuardSet) void {
        if (self.count == 0) return;
        @memset(self.slots, .{ .pc = free_pc, .pos = 0 });
        self.count = 0;
    }

    /// The slot holding `e`, or the free slot where it would go.
    fn find(self: *const GuardSet, e: LoopState) usize {
        const mask = self.slots.len - 1;
        var i: usize = @truncate(std.hash.int(@as(u64, e.pc) *% 0x9E3779B97F4A7C15 ^ @as(u64, e.pos)));
        while (true) : (i +%= 1) {
            const s = self.slots[i & mask];
            if (s.pc == free_pc or (s.pc == e.pc and s.pos == e.pos)) return i & mask;
        }
    }

    pub fn contains(self: *const GuardSet, e: LoopState) bool {
        return self.count > 0 and self.slots[self.find(e)].pc != free_pc;
    }

    /// The set holds exactly `guards`, inserted oldest first.
    pub fn rebuild(self: *GuardSet, gpa: Allocator, guards: []const LoopState) Allocator.Error!void {
        const len = std.math.ceilPowerOfTwoAssert(usize, @max(256, guards.len * 4));
        if (self.slots.len < len) {
            const fresh = try gpa.alloc(LoopState, len);
            gpa.free(self.slots);
            self.slots = fresh;
            @memset(self.slots, .{ .pc = free_pc, .pos = 0 });
        } else self.clearRetainingCapacity();
        self.count = 0;
        for (guards) |g| self.put(g);
    }

    /// Insert `e`, absent and newer than every key present; `guards` is the
    /// whole guard stack, `e` on top (growing rebuilds from it).
    pub fn insert(self: *GuardSet, gpa: Allocator, e: LoopState, guards: []const LoopState) Allocator.Error!void {
        if ((self.count + 1) * 2 > self.slots.len) return self.rebuild(gpa, guards);
        self.put(e);
    }

    fn put(self: *GuardSet, e: LoopState) void {
        self.slots[self.find(e)] = e;
        self.count += 1;
    }

    /// Remove every key; `guards` holds them all. Clears the table when it
    /// is at most 16 times their count, else removes them one by one, so
    /// the cost stays proportional to the keys (the table keeps its
    /// largest size between executions).
    pub fn removeAll(self: *GuardSet, guards: []const LoopState) void {
        if (self.count * 16 >= self.slots.len) return self.clearRetainingCapacity();
        var i = guards.len;
        while (i > 0) {
            i -= 1;
            self.removeNewest(guards[i]);
        }
    }

    /// Remove `e`, the newest key present.
    pub fn removeNewest(self: *GuardSet, e: LoopState) void {
        self.slots[self.find(e)].pc = free_pc;
        self.count -= 1;
    }
};

/// Everything a match allocates, kept between executions so a warm
/// `Scratch` runs without allocating (F3c; docs/REGEX_TIERS_PLAN.md §4.2).
/// Not thread-safe and not reentrant: one per thread, and a second one for
/// a match run from inside another's callback. In safe builds, using one
/// twice at once panics.
pub const Scratch = struct {
    gpa: Allocator,
    /// Capture slots for patterns with more groups than the core keeps
    /// inline.
    captures: []CaptureGroup = &.{},
    loop_guard: std.ArrayListUnmanaged(LoopState) = .empty,
    /// The mirror of the loop guards once they pass `backtrack.zig`'s
    /// `guard_set_min` (F7a(3); `GuardSet`, F7b(5)).
    guard_set: GuardSet = .{},
    /// Positions of the greedy star fast path (a stack: nested stars push
    /// above the outer one's).
    positions: std.ArrayListUnmanaged(usize) = .empty,
    /// The backtracker's choicepoints (F6a, `backtrack.zig`).
    choices: std.ArrayListUnmanaged(Choice) = .empty,
    /// Its capture trail.
    trail: std.ArrayListUnmanaged(TrailEntry) = .empty,
    /// LookLinear (F6a): T0's VM for the lookarounds it answers, their memo
    /// (one per program, valid for one execution: `look_gen`), and how many
    /// times the VM ran or the memo answered (tests and the bench).
    look_vm: tier0.VmScratch,
    look_memo: std.ArrayListUnmanaged(LookMemo) = .empty,
    look_gen: u32 = 0,
    look_evals: u64 = 0,
    look_memo_hits: u64 = 0,
    in_use: bool = false,

    pub fn init(gpa: Allocator) Scratch {
        return .{ .gpa = gpa, .look_vm = .init(gpa) };
    }

    pub fn deinit(self: *Scratch) void {
        self.gpa.free(self.captures);
        self.loop_guard.deinit(self.gpa);
        self.guard_set.deinit(self.gpa);
        self.positions.deinit(self.gpa);
        self.choices.deinit(self.gpa);
        self.trail.deinit(self.gpa);
        self.look_vm.deinit();
        for (self.look_memo.items) |*m| m.bits.deinit(self.gpa);
        self.look_memo.deinit(self.gpa);
        self.* = undefined;
    }

    /// Marks the scratch in use for one execution; panics in safe builds if
    /// it already is.
    pub fn acquire(self: *Scratch) void {
        if (std.debug.runtime_safety) {
            if (self.in_use) @panic("zregex.Scratch used by two executions at once");
            self.in_use = true;
        }
    }

    pub fn release(self: *Scratch) void {
        self.in_use = false;
    }
};

/// Capture slots a bytecode program needs: its highest group index + 1
/// (slot 0 is never written; group 0 is the match itself).
pub fn captureSlotsIn(bytecode: []const u8) usize {
    var slots: usize = 1;
    var pc: usize = 0;
    while (pc < bytecode.len) {
        const inst = format.decodeInstruction(bytecode, pc) catch break;
        switch (inst.opcode) {
            .SAVE_START, .SAVE_END, .SAVE_START_NAMED, .SAVE_END_NAMED, .CLEAR_CAPTURE, .BACK_REF, .BACK_REF_I => {
                slots = @max(slots, @as(usize, inst.operands[0]) + 1);
            },
            else => {},
        }
        pc += inst.size;
    }
    return slots;
}

/// The core over a subject of `Unit`s: `u8` for WTF-8, `u16` for UTF-16
/// (F3c). Positions are in units. `Unit` is comptime so each instance
/// keeps its ASCII path monomorphic (the F3b lesson: decoding every
/// character through the generic `Subject` path cost 17-53 %).
pub fn CoreFor(comptime Unit: type) type {
    comptime std.debug.assert(Unit == u8 or Unit == u16);
    return struct {
        allocator: Allocator,
        bytecode: []const u8,
        /// The program's CharSet table (`CompileResult.charsets`), which
        /// CHAR_SET/CHAR_SET_INV index into. Empty for bytecode built without
        /// one; a CHAR_SET then fails with `error.InvalidCharSet`.
        charsets: []const CharSet = &.{},
        input: []const Unit,
        /// Capture slots in use: the pattern's group count + 1 (slot 0
        /// unused), then the REPEAT_MARK marks (F7a(4)).
        capture_slots: usize,
        inline_captures: [INLINE_CAPTURES]CaptureGroup,
        /// `Scratch.captures` when `capture_slots` exceeds the inline ones.
        heap_captures: []CaptureGroup,
        /// The backtracker's loop guards (`enterBackEdge`), a stack.
        loop_guard: std.ArrayListUnmanaged(LoopState),
        /// Positions of the greedy star fast path (see `Scratch.positions`).
        positions: std.ArrayListUnmanaged(usize),
        /// What one character is (F3d): a code unit for a pattern without
        /// `u`/`v`, a code point with it (`CompileResult.mode`). Only
        /// surrogates and astral characters decode differently, so the
        /// inline ASCII path doesn't depend on it.
        mode: Mode = .code_point,
        /// `i` with `u`/`v` (`CompileResult.word_fold`): `\b`/`\B` count
        /// the extended WordCharacters (F5b).
        word_fold: bool = false,

        const Self = @This();

        /// Error set of the atom checks.
        pub const MatchError = error{ OutOfMemory, UnknownOpcode, UnexpectedEndOfBytecode, StepLimitExceeded, InvalidCharSet };

        /// A core on `scratch`'s buffers: nothing is allocated unless a
        /// buffer has to grow. Hand them back with `releaseScratch`. Built
        /// in place: its inline captures make it a few hundred bytes, and
        /// the backtracker builds one per execution.
        pub fn initScratchInto(self: *Self, bytecode: []const u8, input: []const Unit, capture_slots: usize, scratch: *Scratch) Allocator.Error!void {
            self.* = .{
                .allocator = scratch.gpa,
                .bytecode = bytecode,
                .input = input,
                .capture_slots = capture_slots,
                .inline_captures = [_]CaptureGroup{.{}} ** INLINE_CAPTURES,
                .heap_captures = &.{},
                .loop_guard = scratch.loop_guard,
                .positions = scratch.positions,
            };
            scratch.loop_guard = .empty;
            scratch.positions = .empty;
            self.loop_guard.clearRetainingCapacity();
            self.positions.clearRetainingCapacity();
            if (capture_slots > INLINE_CAPTURES) {
                if (scratch.captures.len < capture_slots) {
                    scratch.gpa.free(scratch.captures);
                    scratch.captures = &.{};
                    scratch.captures = try scratch.gpa.alloc(CaptureGroup, capture_slots);
                }
                self.heap_captures = scratch.captures[0..capture_slots];
                @memset(self.heap_captures, .{});
            }
        }

        /// Ready the core for another start position: captures unset (the
        /// lists are already empty between runs).
        pub fn reset(self: *Self) void {
            @memset(self.caps(), .{});
            std.debug.assert(self.loop_guard.items.len == 0 and self.positions.items.len == 0);
        }

        /// Give the buffers back to `scratch`, keeping their capacity.
        pub fn releaseScratch(self: *Self, scratch: *Scratch) void {
            scratch.loop_guard = self.loop_guard;
            scratch.positions = self.positions;
            self.loop_guard = .empty;
            self.positions = .empty;
            self.heap_captures = &.{};
        }

        /// The live capture slots (inline or heap, see `capture_slots`).
        pub fn caps(self: *Self) []CaptureGroup {
            if (self.capture_slots <= INLINE_CAPTURES) return self.inline_captures[0..self.capture_slots];
            return self.heap_captures;
        }

        /// The captures of the last successful run.
        pub fn captureSlice(self: *Self) []const CaptureGroup {
            return self.caps();
        }

        /// The subject: WTF-8 bytes or UTF-16 units, as `Unit` says.
        pub fn subject(self: *const Self) Subject {
            return subjectOf(self.input);
        }

        fn subjectOf(input: []const Unit) Subject {
            return if (Unit == u8) .{ .wtf8 = input } else .{ .utf16 = input };
        }

        /// Whether `u` is a whole character by itself, decoded inline: ASCII,
        /// and in UTF-16 any unit that isn't a surrogate (never next to a pair
        /// or a WTF-8 `b+2`).
        inline fn isSingle(u: Unit) bool {
            return if (Unit == u8) u < 0x80 else (u < 0xD800 or u > 0xDFFF);
        }

        /// The character at `pos`, one code point (F3b keeps the pre-F3
        /// semantics for every pattern; F3d decodes code units without `u`).
        /// Null at the end of input.
        /// ASCII is decoded here, inline: an ASCII byte is always a whole
        /// character, and never next to a `b+2` position.
        pub inline fn decodeAt(self: *const Self, pos: usize) ?Decoded {
            if (pos < self.input.len and isSingle(self.input[pos])) return .{ .value = self.input[pos], .pos = pos + 1 };
            return self.subject().decodeAt(self.mode, pos);
        }

        pub inline fn decodeBefore(self: *const Self, pos: usize) ?Decoded {
            if (pos > 0 and pos <= self.input.len and isSingle(self.input[pos - 1])) return .{ .value = self.input[pos - 1], .pos = pos - 1 };
            return self.subject().decodeBefore(self.mode, pos);
        }

        /// Where the next search start after `pos` is: one whole character
        /// later (one byte for ill-formed input), so a search never starts in
        /// the middle of a character (D12, start positions).
        pub fn nextSearchStart(input: []const Unit, pos: usize) usize {
            return subjectOf(input).advanceIndex(.code_point, pos);
        }

        /// ECMA-262 LineTerminator: LF, CR, LS (U+2028) or PS (U+2029). What `.`
        /// without /s excludes and what `^`/`$` with /m look for (D5).
        pub fn isLineTerminator(c: u32) bool {
            return c == '\n' or c == '\r' or c == 0x2028 or c == 0x2029;
        }

        pub fn isLineTerminatorAt(self: *const Self, pos: usize) bool {
            const d = self.decodeAt(pos) orelse return false;
            return isLineTerminator(d.value);
        }

        /// Whether a LineTerminator ends right before `pos`.
        pub fn lineTerminatorEndsAt(self: *const Self, pos: usize) bool {
            const d = self.decodeBefore(pos) orelse return false;
            return isLineTerminator(d.value);
        }

        /// Whether the decoded character `d` matches a single-character
        /// instruction (CHAR32, dot, CHAR_RANGE/CHAR_CLASS and their `_INV`).
        pub inline fn charMatches(self: *const Self, inst: Instruction, pc: usize, d: Decoded) MatchError!bool {
            const c = d.value;
            return switch (inst.opcode) {
                .CHAR32 => !d.invalid and c == inst.operands[0],
                .CHAR => !isLineTerminator(c),
                .CHAR_ANY => true,
                .CHAR_RANGE => c >= inst.operands[0] and c <= inst.operands[1],
                .CHAR_RANGE_INV => c < inst.operands[0] or c > inst.operands[1],
                .CHAR_CLASS, .CHAR_CLASS_INV => blk: {
                    if (pc + 33 > self.bytecode.len) return error.UnexpectedEndOfBytecode;
                    const in_class = inBitTable(self.bytecode[pc + 1 ..][0..32], c);
                    break :blk if (inst.opcode == .CHAR_CLASS) in_class else !in_class;
                },
                else => unreachable,
            };
        }

        /// Whether `c` is in a CHAR_CLASS(_INV) bit table (bits 0-255; the
        /// generator only sets ASCII bits).
        fn inBitTable(table: *const [32]u8, c: u32) bool {
            if (c > 0xFF) return false;
            return (table[c / 8] & (@as(u8, 1) << @as(u3, @intCast(c % 8)))) != 0;
        }

        /// Shared matching logic for CHAR_SET(_INV), used by both the backtracker
        /// and its star-loop fast path
        /// (matchSingleInstruction): decode the code point at `pos` and look it
        /// up in `charsets[idx]`. Decoded code points are always in
        /// [0, 0x10FFFF] (a lone invalid byte decodes as its value), so a set
        /// complemented at compile time agrees with a runtime negation.
        pub fn checkCharSet(self: *Self, inst: Instruction, pos: usize) MatchError!struct { matched: bool, end_pos: usize } {
            const idx = inst.operands[0];
            if (idx >= self.charsets.len) return error.InvalidCharSet;
            const decoded = self.decodeAt(pos) orelse return .{ .matched = false, .end_pos = pos };
            const in_set = self.charsets[idx].contains(decoded.value);
            const matched = if (inst.opcode == .CHAR_SET_INV) !in_set else in_set;
            return .{ .matched = matched, .end_pos = if (matched) decoded.pos else pos };
        }

        /// Shared matching logic for UNICODE_PROPERTY(_INV), used by both the
        /// backtracker and its star-loop fast path
        /// (matchSingleInstruction). Decodes the code point at `pos` and checks
        /// it against the instruction's General_Category operand.
        pub fn checkUnicodeProperty(self: *Self, pc: usize, pos: usize, inverted: bool) MatchError!struct { matched: bool, end_pos: usize } {
            if (pos >= self.input.len) return .{ .matched = false, .end_pos = pos };
            if (pc + 2 > self.bytecode.len) return error.UnexpectedEndOfBytecode;

            const category: properties.UnicodeProperty = @enumFromInt(self.bytecode[pc + 1]);
            const decoded = self.decodeAt(pos) orelse return .{ .matched = false, .end_pos = pos };
            const in_category = properties.isInCategory(decoded.value, category);

            const matched = if (inverted) !in_category else in_category;
            return .{ .matched = matched, .end_pos = if (matched) decoded.pos else pos };
        }

        /// Shared matching logic for UNICODE_SCRIPT(_INV), used by both the backtracker
        /// and its star-loop fast path (matchSingleInstruction).
        /// Decodes the code point at `pos` and checks it against the
        /// instruction's script-index operand.
        pub fn checkUnicodeScript(self: *Self, pc: usize, pos: usize, inverted: bool) MatchError!struct { matched: bool, end_pos: usize } {
            if (pos >= self.input.len) return .{ .matched = false, .end_pos = pos };
            if (pc + 2 > self.bytecode.len) return error.UnexpectedEndOfBytecode;

            const script_index = self.bytecode[pc + 1];
            const decoded = self.decodeAt(pos) orelse return .{ .matched = false, .end_pos = pos };
            const in_script = properties.isInScript(decoded.value, script_index);

            const matched = if (inverted) !in_script else in_script;
            return .{ .matched = matched, .end_pos = if (matched) decoded.pos else pos };
        }

        /// Shared matching logic for UNICODE_SCRIPT_EXTENSIONS(_INV), used by
        /// both the backtracker and its star-loop fast path
        /// (matchSingleInstruction). Same shape as `checkUnicodeScript`, but
        /// checks `properties.isInScriptExtensions` instead of `isInScript`.
        pub fn checkUnicodeScriptExtensions(self: *Self, pc: usize, pos: usize, inverted: bool) MatchError!struct { matched: bool, end_pos: usize } {
            if (pos >= self.input.len) return .{ .matched = false, .end_pos = pos };
            if (pc + 2 > self.bytecode.len) return error.UnexpectedEndOfBytecode;

            const script_index = self.bytecode[pc + 1];
            const decoded = self.decodeAt(pos) orelse return .{ .matched = false, .end_pos = pos };
            const in_script = properties.isInScriptExtensions(decoded.value, script_index);

            const matched = if (inverted) !in_script else in_script;
            return .{ .matched = matched, .end_pos = if (matched) decoded.pos else pos };
        }

        /// Detect if SPLIT is part of star quantifier pattern
        /// Pattern: SPLIT pc_consume, pc_skip OR SPLIT pc_skip, pc_consume
        /// where pc_consume points to: CHAR; GOTO back_to_split
        pub fn isStarQuantifier(self: *Self, split_pc: usize, pc1: usize, pc2: usize) MatchError!bool {
            // Try pc1 as the consume path
            if (try self.isStarConsumePath(split_pc, pc1)) return true;

            // Try pc2 as the consume path
            if (try self.isStarConsumePath(split_pc, pc2)) return true;

            return false;
        }

        /// Every opcode that can be the quantified atom of `e?`/`e*`/`e+` and
        /// consumes (or, for BACK_REF, potentially doesn't consume -- see
        /// checkBackRef) input on success. Used by isStarConsumePath so it can't
        /// silently drift out of sync with the set of opcodes the codegen
        /// actually quantifies: a quantifiable opcode missing from this list
        /// previously caused `\1+`-style patterns to fall through to plain
        /// recursive alternation with no zero-width-progress guard, crashing on
        /// a stack overflow instead of matching correctly or hitting the depth
        /// limit (found via test262-derived conformance testing).
        fn isQuantifiableAtomOpcode(opcode: Opcode) bool {
            return switch (opcode) {
                .CHAR, .CHAR_ANY, .CHAR32, .BYTE, .CHAR2, .CHAR_RANGE, .CHAR_RANGE_INV, .CHAR_CLASS, .CHAR_CLASS_INV, .CHAR_SET, .CHAR_SET_INV, .UNICODE_PROPERTY, .UNICODE_PROPERTY_INV, .UNICODE_SCRIPT, .UNICODE_SCRIPT_INV, .UNICODE_SCRIPT_EXTENSIONS, .UNICODE_SCRIPT_EXTENSIONS_INV, .BACK_REF, .BACK_REF_I => true,
                else => false,
            };
        }

        /// Check if a given PC is the consume path of a star quantifier
        pub fn isStarConsumePath(self: *Self, split_pc: usize, consume_pc: usize) MatchError!bool {
            // Check if consume_pc points to a character-consuming instruction
            if (consume_pc >= self.bytecode.len) return false;

            const inst1 = try format.decodeInstruction(self.bytecode, consume_pc);
            const consumes_char = isQuantifiableAtomOpcode(inst1.opcode);
            if (!consumes_char) return false;

            const next_pc = consume_pc + inst1.size;

            // Plus-shape loop (`generatePlus`): `consume_pc: X; SPLIT_GREEDY
            // consume_pc, end;` -- X directly precedes the split with no
            // intervening GOTO, and looping happens via the split branching
            // straight back to consume_pc (which is already known to be one of
            // its two targets, since isStarQuantifier calls this with pc1/pc2).
            if (next_pc == split_pc) return true;

            // Star-shape loop (`generateStar`/`generateRepeat`'s unbounded
            // case): `split_pc: SPLIT end, consume_pc; consume_pc: X; GOTO
            // split_pc; end: ...` -- X is followed by an explicit GOTO back.
            if (next_pc >= self.bytecode.len) return false;

            const inst2 = try format.decodeInstruction(self.bytecode, next_pc);
            if (inst2.opcode != .GOTO) return false;

            const goto_offset = @as(i32, @bitCast(inst2.operands[0]));
            const goto_target: i32 = @intCast(next_pc);
            const target_pc = goto_target + goto_offset;

            return target_pc == @as(i32, @intCast(split_pc));
        }

        /// Match a single instruction without advancing PC
        /// Used by star quantifiers to match the repeated element
        pub fn matchSingleInstruction(self: *Self, inst: Instruction, pc: usize, pos: usize) MatchError!struct { matched: bool, end_pos: usize } {
            switch (inst.opcode) {
                .BYTE => {
                    // A raw byte: compared, not decoded (see opcodes.zig); never
                    // in a UTF-16 subject.
                    if (Unit != u8 or pos >= self.input.len or self.input[pos] != inst.operands[0]) {
                        return .{ .matched = false, .end_pos = pos };
                    }
                    return .{ .matched = true, .end_pos = pos + 1 };
                },

                .CHAR32, .CHAR, .CHAR_ANY, .CHAR_RANGE, .CHAR_RANGE_INV, .CHAR_CLASS, .CHAR_CLASS_INV => {
                    const d = self.decodeAt(pos) orelse return .{ .matched = false, .end_pos = pos };
                    const matched = try self.charMatches(inst, pc, d);
                    return .{ .matched = matched, .end_pos = if (matched) d.pos else pos };
                },

                .CHAR_SET, .CHAR_SET_INV => {
                    const r = try self.checkCharSet(inst, pos);
                    return .{ .matched = r.matched, .end_pos = r.end_pos };
                },

                .UNICODE_PROPERTY => {
                    const r = try self.checkUnicodeProperty(pc, pos, false);
                    return .{ .matched = r.matched, .end_pos = r.end_pos };
                },

                .UNICODE_PROPERTY_INV => {
                    const r = try self.checkUnicodeProperty(pc, pos, true);
                    return .{ .matched = r.matched, .end_pos = r.end_pos };
                },

                .UNICODE_SCRIPT => {
                    const r = try self.checkUnicodeScript(pc, pos, false);
                    return .{ .matched = r.matched, .end_pos = r.end_pos };
                },

                .UNICODE_SCRIPT_INV => {
                    const r = try self.checkUnicodeScript(pc, pos, true);
                    return .{ .matched = r.matched, .end_pos = r.end_pos };
                },

                .UNICODE_SCRIPT_EXTENSIONS => {
                    const r = try self.checkUnicodeScriptExtensions(pc, pos, false);
                    return .{ .matched = r.matched, .end_pos = r.end_pos };
                },

                .UNICODE_SCRIPT_EXTENSIONS_INV => {
                    const r = try self.checkUnicodeScriptExtensions(pc, pos, true);
                    return .{ .matched = r.matched, .end_pos = r.end_pos };
                },

                .BACK_REF => {
                    const group = @as(usize, @intCast(inst.operands[0]));
                    const r = self.checkBackRef(pos, group, false);
                    return .{ .matched = r.matched, .end_pos = r.end_pos };
                },

                .BACK_REF_I => {
                    const group = @as(usize, @intCast(inst.operands[0]));
                    const r = self.checkBackRef(pos, group, true);
                    return .{ .matched = r.matched, .end_pos = r.end_pos };
                },

                else => {
                    // For other instructions (shouldn't happen in star loop)
                    return .{ .matched = false, .end_pos = pos };
                },
            }
        }

        /// The pc of the LOOKAHEAD_END or LOOKBEHIND_END that closes the
        /// lookaround whose body starts at `start_pc` (`behind` says which):
        /// nested lookarounds of the same kind are skipped whole.
        pub fn findLookEnd(self: Self, start_pc: usize, behind: bool) MatchError!usize {
            var pc = start_pc;
            var depth: usize = 1;
            while (pc < self.bytecode.len) {
                const inst = try format.decodeInstruction(self.bytecode, pc);
                const opens = if (behind) inst.opcode == .LOOKBEHIND_FIXED or inst.opcode == .NEGATIVE_LOOKBEHIND_FIXED else inst.opcode == .LOOKAHEAD or inst.opcode == .NEGATIVE_LOOKAHEAD;
                if (opens) depth += 1;
                if (inst.opcode == (if (behind) Opcode.LOOKBEHIND_END else Opcode.LOOKAHEAD_END)) {
                    depth -= 1;
                    if (depth == 0) return pc;
                }
                pc += inst.size;
            }
            return error.UnexpectedEndOfBytecode;
        }

        /// Shared backreference-matching logic for BACK_REF(_I), used by both
        /// the backtracker and its star-loop fast path
        /// (matchSingleInstruction). A backreference to a group that captured
        /// zero characters matches zero characters here too (`end_pos == pos`)
        /// -- callers that loop on this (e.g. `\1+`) must have their own
        /// zero-width-progress guard, same as any other quantified atom.
        pub fn checkBackRef(self: *Self, pos: usize, group: usize, case_insensitive: bool) struct { matched: bool, end_pos: usize } {
            if (group >= self.capture_slots) {
                return .{ .matched = false, .end_pos = pos };
            }

            const capture = self.caps()[group];
            if (!capture.isValid()) {
                // Per the ECMAScript spec, a backreference to a group that
                // hasn't participated in the match (e.g. an alternation branch
                // not taken, or a negative lookahead's own group -- see
                // matchLookahead) always succeeds, matching the empty string.
                // It must NOT fail outright: `/(a)?\1b/.exec("b")` matches in
                // JS with capture 1 left undefined.
                return .{ .matched = true, .end_pos = pos };
            }

            const cap_start = capture.start.?;
            const cap_end = capture.end.?;
            // A group re-entered but not closed yet in this iteration holds the
            // new start with the previous iteration's end (end < start): reached
            // from inside the group itself (`(a\1)*`, `(?<n>\k<n>x)`). The spec
            // clears the atom's captures at each iteration, so the group hasn't
            // participated yet: match empty. (Before F1c this subtraction
            // overflowed: a panic in safe builds; found by differential-v8.)
            if (cap_end < cap_start) return .{ .matched = true, .end_pos = pos };
            const cap_len = cap_end - cap_start;

            // Compare character by character: equal values that take the same
            // number of units (so an ill-formed byte never equals a code point
            // with its value). With `i`, equal under ECMA-262's Canonicalize
            // (F5b: `casefold`, the tables the lowering folds with), one
            // character of the pattern's mode at a time (a code point with
            // `u`/`v`, so an astral one canonicalizes whole).
            const decode_mode: Mode = if (case_insensitive) self.mode else .code_unit;
            const fold_mode: casefold.FoldMode = if (self.mode == .code_point) .unicode else .legacy;
            var cap_pos = cap_start;
            var cur_pos = pos;
            while (cap_pos < cap_end) {
                const a = self.subject().decodeAt(decode_mode, cap_pos).?;
                const b = self.subject().decodeAt(decode_mode, cur_pos) orelse return .{ .matched = false, .end_pos = pos };
                const eq = if (case_insensitive)
                    casefold.canonicalize(a.value, fold_mode) == casefold.canonicalize(b.value, fold_mode)
                else
                    a.value == b.value;
                // Under `i`, equal characters may take different lengths (k
                // and the Kelvin sign in WTF-8); an ill-formed byte still
                // never equals a code point (`invalid`).
                const same_len = case_insensitive or a.pos - cap_pos == b.pos - cur_pos;
                if (!eq or a.invalid != b.invalid or !same_len) return .{ .matched = false, .end_pos = pos };
                cap_pos = a.pos;
                cur_pos = b.pos;
            }
            _ = cap_len;

            return .{ .matched = true, .end_pos = cur_pos };
        }

        /// Check if position is at word boundary: WordCharacters
        /// (`ir.word`), extended under `u`/`v` + `i`.
        pub fn isWordBoundary(self: *const Self, pos: usize) bool {
            const extended = self.word_fold and self.mode == .code_point;
            const before_is_word = if (self.decodeBefore(pos)) |d| word.isWordChar(d.value, extended) else false;
            const after_is_word = if (self.decodeAt(pos)) |d| word.isWordChar(d.value, extended) else false;
            return before_is_word != after_is_word;
        }
    };
}

// =============================================================================
// Tests
// =============================================================================

test "GuardSet agrees with a scan of the guard stack under LIFO use (F7b(5))" {
    const gpa = std.testing.allocator;
    var set: GuardSet = .{};
    defer set.deinit(gpa);
    var stack: std.ArrayListUnmanaged(LoopState) = .empty;
    defer stack.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(0x7b5);
    const rnd = prng.random();
    for (0..4000) |_| {
        // Few pcs and positions: many collisions and refused duplicates.
        const e: LoopState = .{ .pc = rnd.uintLessThan(usize, 8), .pos = rnd.uintLessThan(usize, 400) };
        var present = false;
        for (stack.items) |g| present = present or (g.pc == e.pc and g.pos == e.pos);
        if (stack.items.len > 0) try std.testing.expectEqual(present, set.contains(e));
        if (rnd.uintLessThan(u8, 4) == 0 and stack.items.len > 0) {
            // Sometimes everything (`removeAll`: a clear or one by one).
            const h = if (rnd.uintLessThan(u8, 8) == 0) 0 else rnd.uintLessThan(usize, stack.items.len);
            if (h == 0) set.removeAll(stack.items) else {
                var i = stack.items.len;
                while (i > h) {
                    i -= 1;
                    set.removeNewest(stack.items[i]);
                }
            }
            stack.shrinkRetainingCapacity(h);
        } else if (!present) {
            try stack.append(gpa, e);
            if (stack.items.len == 1) try set.rebuild(gpa, stack.items) else try set.insert(gpa, e, stack.items);
        }
        try std.testing.expectEqual(stack.items.len, set.count);
        for (stack.items) |g| try std.testing.expect(set.contains(g));
    }
    set.clearRetainingCapacity();
    try std.testing.expect(!set.contains(.{ .pc = 0, .pos = 0 }));
}

test "GuardSet removals newest first leave no stale slot (F7b(5))" {
    const gpa = std.testing.allocator;
    var set: GuardSet = .{};
    defer set.deinit(gpa);
    const first: LoopState = .{ .pc = 1, .pos = 0 };
    try set.rebuild(gpa, &.{first});
    // Three keys with the same home slot: each probe crosses the older ones.
    const home = set.find(first);
    var keys: [3]LoopState = .{ first, undefined, undefined };
    var n: usize = 1;
    var pos: usize = 1;
    while (n < keys.len) : (pos += 1) {
        const e: LoopState = .{ .pc = 1, .pos = pos };
        set.removeNewest(first);
        const same = set.find(e) == home;
        try set.insert(gpa, first, &.{first});
        if (same) {
            keys[n] = e;
            n += 1;
        }
    }
    for (keys[1..], 2..) |e, len| try set.insert(gpa, e, keys[0..len]);
    // Partial truncation, then everything one by one (3 keys, 256 slots).
    set.removeNewest(keys[2]);
    try std.testing.expect(set.contains(keys[0]) and set.contains(keys[1]) and !set.contains(keys[2]));
    try set.insert(gpa, keys[2], &keys);
    set.removeAll(&keys);
    try std.testing.expectEqual(@as(usize, 0), set.count);
    for (set.slots) |s| try std.testing.expectEqual(GuardSet.free_pc, s.pc);
    // No ghost: the oldest key back in its home slot hides nothing.
    try set.insert(gpa, keys[0], keys[0..1]);
    try std.testing.expect(!set.contains(keys[1]) and !set.contains(keys[2]));
}
