//! A step budget shared between executors (docs/REGEX_TIERS_PLAN.md, F4a).
//!
//! T2 hands one `Budget` to every T0 sub-match it delegates
//! (`tier0.existsAnchoredMatch`, F6a), so the whole execution draws on a
//! single allowance. It lives here, in a leaf layer, so `tier0` and `tier2`
//! both reach it without an edge between them.

const std = @import("std");

pub const Budget = struct {
    remaining: u64,

    pub const unlimited: Budget = .{ .remaining = std.math.maxInt(u64) };

    pub fn init(steps: u64) Budget {
        return .{ .remaining = steps };
    }

    /// Spend `n` steps, or fail once the allowance can't cover them (the
    /// same error the backtracker's own limit raises).
    pub inline fn charge(self: *Budget, n: u64) error{StepLimitExceeded}!void {
        if (self.remaining < n) {
            self.remaining = 0;
            return error.StepLimitExceeded;
        }
        self.remaining -= n;
    }
};

test "Budget: charge until exhausted" {
    var b: Budget = .init(5);
    try b.charge(3);
    try b.charge(2);
    try std.testing.expectError(error.StepLimitExceeded, b.charge(1));
    try std.testing.expectEqual(@as(u64, 0), b.remaining);
    var u: Budget = .unlimited;
    try u.charge(1 << 40);
}
