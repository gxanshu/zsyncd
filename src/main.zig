const std = @import("std");
const builtin = @import("builtin");
const program_args = @import("./arguments/main.zig");

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

    if (args.len == 0) {
        return program_args.help();
    }

    for (args) |arg| {
        // help page
        if (std.mem.eql(u8, arg, "help")) {
            return program_args.help();
        }

        // login page
        if (std.mem.eql(u8, arg, "login")) {
            return program_args.login();
        }
    }
}
