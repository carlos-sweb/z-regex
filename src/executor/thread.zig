//! Capture group representation, shared by the executor's matchers.

const std = @import("std");

/// Maximum number of capture groups supported
pub const MAX_CAPTURES: usize = 32;

/// Capture group position
pub const Capture = struct {
    start: ?usize = null,
    end: ?usize = null,

    /// Check if capture is valid
    pub fn isValid(self: Capture) bool {
        return self.start != null and self.end != null;
    }

    /// Get capture length
    pub fn len(self: Capture) usize {
        if (!self.isValid()) return 0;
        return self.end.? - self.start.?;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Capture: isValid" {
    var cap = Capture{};
    try std.testing.expect(!cap.isValid());

    cap.start = 0;
    try std.testing.expect(!cap.isValid());

    cap.end = 5;
    try std.testing.expect(cap.isValid());
}

test "Capture: len" {
    var cap = Capture{ .start = 10, .end = 15 };
    try std.testing.expectEqual(@as(usize, 5), cap.len());

    cap.start = null;
    try std.testing.expectEqual(@as(usize, 0), cap.len());
}
