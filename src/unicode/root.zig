//! `unicode`: the Unicode data (generated tables, properties, simple case
//! mapping). Depends on nothing; T0 must not depend on it (F2e).

pub const tables = @import("tables.zig");
pub const properties = @import("properties.zig");
pub const casefold = @import("casefold.zig");

test {
    _ = @import("unicode_tests.zig");
}
