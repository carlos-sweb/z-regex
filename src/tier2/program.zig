//! The backtracker's compiled program (F2e: moved here from the compile
//! pipeline so the executor doesn't depend on it): bytecode plus the tables
//! it needs to run, as `compile()` returns it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const format_mod = @import("bytecode/format.zig");
const charset_mod = @import("ir").charset;
const Mode = @import("subject").Mode;
const tier0 = @import("tier0");

pub const NamedGroup = format_mod.NamedGroup;
pub const CharSet = charset_mod.CharSet;

/// Compilation result
pub const CompileResult = struct {
    bytecode: []const u8,
    /// Owned copies of named-group name strings (see `NamedGroup`); empty for
    /// patterns with no named capture groups.
    named_groups: []const NamedGroup,
    /// Total number of capturing groups in the pattern (0 if none). Used to
    /// distinguish "group N doesn't exist in this pattern" from "group N
    /// exists but didn't participate in this match" -- e.g. for `$N`
    /// substitution in `Regex.replace`/`replaceAll`.
    group_count: u16,
    /// The CharSet table CHAR_SET/CHAR_SET_INV index into (F2b). Not part
    /// of the bytecode: the bytecode alone isn't executable, and isn't a
    /// stable serialization format (docs/REGEX_TIERS_PLAN.md, F2b).
    charsets: []const CharSet = &.{},
    /// What one character of the subject is (F3c): `code_point` when the
    /// pattern was compiled with `u` or `v`, `code_unit` otherwise. The
    /// matcher follows it from F3d; until then every pattern decodes code
    /// points, as before F3.
    mode: Mode = .code_unit,
    /// Whether the bytecode has a lookbehind: such a pattern runs on the
    /// recursive matcher until F6b, the rest on the explicit-stack
    /// backtracker (F6a).
    has_lookbehind: bool = false,
    /// `i` together with `u`/`v`: `\b`/`\B` count the extended
    /// WordCharacters (`ir.word`, F5b).
    word_fold: bool = false,
    /// The lookaheads T0's VM answers (F6a, LookLinear): bodies without
    /// captures, backreferences or nested lookarounds that `tier0.check`
    /// takes. Sorted by `pc`. Empty unless the pattern runs on the
    /// backtracker (and `CompileOptions.t2_look_linear`).
    linear: []const LinearSite = &.{},
    /// Their programs: sites that are copies of one HIR node (an unrolled
    /// counted repeat) with the same flags share one.
    linear_programs: []const tier0.Program = &.{},
    allocator: Allocator,

    /// Free the compilation result
    pub fn deinit(self: CompileResult) void {
        for (self.named_groups) |ng| self.allocator.free(ng.name);
        self.allocator.free(self.named_groups);
        freeCharSets(self.allocator, self.charsets);
        for (self.linear_programs) |prog| prog.deinit(self.allocator);
        self.allocator.free(self.linear_programs);
        self.allocator.free(self.linear);
        self.allocator.free(self.bytecode);
    }
};

/// A lookahead whose body T0's VM answers: LOOKAHEAD/NEGATIVE_LOOKAHEAD at
/// `pc`, its LOOKAHEAD_END at `end`, the body's program at
/// `linear_programs[program]`.
pub const LinearSite = struct { pc: u32, end: u32, program: u32 };

/// Whether `bytecode` has a LOOKBEHIND/NEGATIVE_LOOKBEHIND instruction.
pub fn hasLookbehind(bytecode: []const u8) bool {
    var pc: usize = 0;
    while (pc < bytecode.len) {
        const inst = format_mod.decodeInstruction(bytecode, pc) catch return false;
        switch (inst.opcode) {
            .LOOKBEHIND, .NEGATIVE_LOOKBEHIND => return true,
            else => {},
        }
        pc += inst.size;
    }
    return false;
}

pub fn freeCharSets(allocator: Allocator, charsets: []const CharSet) void {
    for (charsets) |cs| cs.deinit(allocator);
    allocator.free(charsets);
}
