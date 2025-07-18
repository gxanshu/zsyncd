const std = @import("std");

pub fn help() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Hello from zsyncd\n", .{});
}
