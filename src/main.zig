const std = @import("std");
const builtin = @import("builtin");
const help_args = @import("help.zig");
const login_args = @import("login.zig");
const logout_args = @import("logout.zig");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const allocator, const is_debug = allocator: {
        break :allocator switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 1) {
        return help_args.help();
    }

    const command = std.meta.stringToEnum(help_args.Command, args[1]);

    if (command == null) {
        std.debug.print("Invalid command\n", .{});
        return help_args.help();
    }

    switch (command.?) {
        .login => return login_args.login(allocator),
        .logout => return logout_args.logout(allocator),
        else => {
            std.debug.print("Invalid command\n", .{});
            return help_args.help();
        },
    }
}
