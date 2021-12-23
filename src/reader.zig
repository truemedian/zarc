const std = @import("std");

pub const tar = @import("reader/tar.zig");

comptime {
    std.testing.refAllDecls(@This());
}
