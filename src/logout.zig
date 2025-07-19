const std = @import("std");
const util = @import("./util.zig");

pub fn logout(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();

    // Check if user is currently logged in
    if (!util.hasValidAuth(allocator)) {
        try stdout.print("ℹ️  You are not currently logged in.\n", .{});
        return;
    }

    try stdout.print("🔄 Logging out...\n", .{});

    // Clear stored authentication
    util.clearAuth(allocator) catch |err| {
        try stdout.print("❌ Failed to clear authentication: {}\n", .{err});
        return;
    };

    try stdout.print("✅ Successfully logged out!\n", .{});
}
