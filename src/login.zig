const std = @import("std");
const env = @import("./env.zig");
const util = @import("./util.zig");

const AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth?client_id={s}&redirect_uri=urn:ietf:wg:oauth:2.0:oob&response_type=code&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive&access_type=offline&prompt=consent";
const TOKEN_EXCHANGE_URL = "https://oauth2.googleapis.com/token";
const writer = std.io.getStdOut().writer();
const reader = std.io.getStdIn().reader();

pub fn login(allocator: std.mem.Allocator) !void {
    // Check if user is already authenticated
    if (util.hasValidAuth(allocator)) {
        try writer.print(">> Already logged in. :) \n", .{});
        return;
    }

    // Show login instructions
    try writer.print(
        \\ ----------------------------------------
        \\       Google Drive Sync — Login
        \\ ----------------------------------------
        \\ Please open this URL in your browser:
        \\
    , .{});
    try writer.print(AUTH_URL, .{env.GOOGLE_CLIENT_ID});
    try writer.print(
        \\
        \\ After granting access, paste the code below.
        \\ ----------------------------------------
    , .{});

    // Get authorization code from user (merged from getAuthCodeFromUser)
    try writer.print("\nAuthorization code: ", .{});

    const input_buffer = try allocator.alloc(u8, 1024);
    defer allocator.free(input_buffer);

    const auth_code = if (try reader.readUntilDelimiterOrEof(input_buffer, '\n')) |input| blk: {
        const trimmed_code = std.mem.trim(u8, input, " \t\n\r");
        if (trimmed_code.len == 0) {
            try writer.print("|Error| No code provided\n", .{});
            return error.EmptyInput;
        }
        break :blk try allocator.dupe(u8, trimmed_code);
    } else {
        try writer.print("|Error| Failed to read input\n", .{});
        return error.ReadError;
    };
    defer allocator.free(auth_code);

    // Exchange code for tokens (merged from exchangeCodeForTokens, buildTokenExchangePayload, makeTokenRequest)
    try writer.print("Exchanging code for access token...\n", .{});

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build token exchange payload (merged from buildTokenExchangePayload)
    const payload = try std.fmt.allocPrint(allocator, "client_id={s}&client_secret={s}&code={s}&grant_type=authorization_code&redirect_uri=urn:ietf:wg:oauth:2.0:oob", .{
        env.GOOGLE_CLIENT_ID,
        env.GOOGLE_CLIENT_SECRET,
        auth_code,
    });
    defer allocator.free(payload);

    // Make token request (merged from makeTokenRequest)
    var response_body = std.ArrayList(u8).init(allocator);
    defer response_body.deinit();

    const headers = &[_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
    };

    const response = try client.fetch(.{
        .method = .POST,
        .location = .{ .url = TOKEN_EXCHANGE_URL },
        .extra_headers = headers,
        .payload = payload,
        .response_storage = .{ .dynamic = &response_body },
    });

    if (response.status != .ok) {
        std.debug.print("|Error| Authentication failed. Status: {}\n", .{response.status});
        std.debug.print("Response: {s}\n", .{response_body.items});
        return error.AuthenticationFailed;
    }

    const response_body_owned = try allocator.dupe(u8, response_body.items);
    defer allocator.free(response_body_owned);

    // Save the tokens using our utility
    try util.saveNewToken(allocator, response_body_owned);

    try writer.print("Successfully logged in! Enjoy Syncing :) \n", .{});
}
