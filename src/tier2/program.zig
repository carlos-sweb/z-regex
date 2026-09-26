//! The backtracker's compiled program (F2e: moved here from the compile
//! pipeline so the executor doesn't depend on it): bytecode plus the tables
//! it needs to run, as `compile()` returns it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const format_mod = @import("bytecode/format.zig");
const charset_mod = @import("ir").charset;

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
    allocator: Allocator,

    /// Free the compilation result
    pub fn deinit(self: CompileResult) void {
        for (self.named_groups) |ng| self.allocator.free(ng.name);
        self.allocator.free(self.named_groups);
        freeCharSets(self.allocator, self.charsets);
        self.allocator.free(self.bytecode);
    }
};

pub fn freeCharSets(allocator: Allocator, charsets: []const CharSet) void {
    for (charsets) |cs| cs.deinit(allocator);
    allocator.free(charsets);
}
