const std = @import("std");
const util = @import("./util.zig");

pub fn logout(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();

    // Check if user is currently logged in
    if (!util.hasValidAuth(allocator)) {
        try stdout.print(">> You are not logged in. T_T\n", .{});
        return;
    }

    try stdout.print("Logging out...\n", .{});

    // Clear stored authentication
    util.clearAuth(allocator) catch |err| {
        try stdout.print("|Error| Failed to clear authentication: {}\n", .{err});
        return;
    };

    try stdout.print("Successfully logged out! May the force be with you.\n", .{});
}
