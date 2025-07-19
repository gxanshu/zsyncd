const std = @import("std");

pub const Command = enum {
    login,
    add,
    pause,
    remove,
    logout
};

pub fn help() !void {
    const writer = std.io.getStdOut().writer();
    const help_str =
        \\ZSync D - Command List
        \\  Usage: zsync <command>
        \\
        \\Commands:
        \\  login    : Connect your Google Drive account.
        \\  add      : Link a local folder to Google Drive for syncing.
        \\  pause    : Pause syncing for a folder.
        \\  remove   : Remove a synced folder.
        \\  logout   : Disconnect your Google Drive account.
    ;
    try writer.print("{s}\n", .{help_str});
}
