//! One test binary for the leaf layers, the modules with no dependencies
//! (F4a step 0): their tests used to be four binaries, and each binary costs
//! ~25 s of compilation in ReleaseSafe whatever its size. Test declarations
//! of an imported *module* don't run, so this file includes the leaves'
//! roots as files of one test module; that compiles only because a leaf
//! imports no other module. build.zig derives the list from its layer table
//! (every layer with no deps) and `check-layers` allows exactly these
//! imports from this file.

test {
    _ = @import("ir/root.zig");
    _ = @import("unicode/root.zig");
    _ = @import("utils/root.zig");
    _ = @import("subject/root.zig");
}
