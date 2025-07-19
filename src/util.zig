const std = @import("std");
const env = @import("./env.zig");

const TokenError = error{
    TokenNotFound,
    TokenExpired,
    RefreshFailed,
    InvalidToken,
    NetworkError,
    FileError,
};

const TOKEN_EXPIRY_BUFFER_SECONDS = 3600; // 1 hour
const CONFIG_DIR_NAME = "zsyncd";
const CONFIG_FILE_NAME = "auth.json";

// Struct for OAuth token response from Google
const OAuthResponse = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    expires_in: i64,
    token_type: []const u8,
    scope: ?[]const u8 = null,
};

// Struct for stored token data (includes created_at timestamp)
const StoredTokenData = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    expires_in: i64,
    token_type: []const u8,
    scope: ?[]const u8 = null,
    created_at: i64,
};

/// Get a valid access token for Google Drive API calls
/// This function handles everything: checking existing token, refreshing if expired
/// Returns the access token ready to use in Authorization headers
pub fn getValidToken(allocator: std.mem.Allocator) ![]const u8 {
    // Try to get existing token
    const token_data = getStoredToken(allocator) catch |err| switch (err) {
        TokenError.TokenNotFound => return TokenError.TokenNotFound,
        else => return err,
    };
    defer freeTokenData(allocator, token_data);

    // Check if token is still valid
    if (isTokenValid(token_data)) {
        return allocator.dupe(u8, token_data.access_token);
    }

    // Token expired, try to refresh
    if (token_data.refresh_token) |refresh_token| {
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        const payload = try std.fmt.allocPrint(
            allocator,
            "client_id={s}&client_secret={s}&refresh_token={s}&grant_type=refresh_token",
            .{ env.GOOGLE_CLIENT_ID, env.GOOGLE_CLIENT_SECRET, refresh_token },
        );
        defer allocator.free(payload);

        var response_body = std.ArrayList(u8).init(allocator);
        defer response_body.deinit();

        const headers = &[_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        };

        const response = client.fetch(.{
            .method = .POST,
            .location = .{ .url = "https://oauth2.googleapis.com/token" },
            .extra_headers = headers,
            .payload = payload,
            .response_storage = .{ .dynamic = &response_body },
        }) catch return TokenError.NetworkError;

        if (response.status != .ok) {
            return TokenError.RefreshFailed;
        }

        // Parse JSON response into OAuthResponse struct
        const parsed = std.json.parseFromSlice(
            OAuthResponse,
            allocator,
            response_body.items,
            .{ .ignore_unknown_fields = true },
        ) catch {
            return TokenError.InvalidToken;
        };
        defer parsed.deinit();

        // Save the refreshed token (keep the original refresh_token)
        try saveTokenToFile(allocator, parsed.value, refresh_token);

        // Return the new access token
        return allocator.dupe(u8, parsed.value.access_token);
    }

    return TokenError.TokenExpired;
}

/// Check if we have a valid token (either current or refreshable)
pub fn hasValidAuth(allocator: std.mem.Allocator) bool {
    const token_data = getStoredToken(allocator) catch return false;
    defer freeTokenData(allocator, token_data);

    // Token is current
    if (isTokenValid(token_data)) return true;

    // Token can be refreshed
    return token_data.refresh_token != null;
}

/// Save new token data from OAuth flow
pub fn saveNewToken(
    allocator: std.mem.Allocator,
    json_response: []const u8,
) !void {
    // Parse JSON response into OAuthResponse struct
    const parsed = std.json.parseFromSlice(
        OAuthResponse,
        allocator,
        json_response,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return TokenError.InvalidToken;
    };
    defer parsed.deinit();

    try saveTokenToFile(allocator, parsed.value, null);
}

/// Remove stored authentication
pub fn clearAuth(allocator: std.mem.Allocator) !void {
    const config_path = try getConfigFilePath(allocator);
    defer allocator.free(config_path);

    std.fs.deleteFileAbsolute(config_path) catch |err| switch (err) {
        error.FileNotFound => {}, // Already cleared
        else => return TokenError.FileError,
    };
}

// Private helper functions
fn getStoredToken(allocator: std.mem.Allocator) !StoredTokenData {
    const config_path = try getConfigFilePath(allocator);
    defer allocator.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch {
        return TokenError.TokenNotFound;
    };
    defer file.close();

    const file_size = try file.getEndPos();
    const content = try allocator.alloc(u8, file_size);
    defer allocator.free(content);
    _ = try file.readAll(content);

    // Parse JSON directly into StoredTokenData struct
    const parsed = std.json.parseFromSlice(
        StoredTokenData,
        allocator,
        content,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return TokenError.InvalidToken;
    };
    defer parsed.deinit();

    // Create a copy with allocated strings that we own
    return StoredTokenData{
        .access_token = try allocator.dupe(u8, parsed.value.access_token),
        .refresh_token = if (parsed.value.refresh_token) |rt| try allocator.dupe(u8, rt) else null,
        .expires_in = parsed.value.expires_in,
        .token_type = try allocator.dupe(u8, parsed.value.token_type),
        .scope = if (parsed.value.scope) |s| try allocator.dupe(u8, s) else null,
        .created_at = parsed.value.created_at,
    };
}

fn isTokenValid(token_data: StoredTokenData) bool {
    const current_time = std.time.timestamp();
    const expiry_time = token_data.created_at + token_data.expires_in - TOKEN_EXPIRY_BUFFER_SECONDS;
    return current_time < expiry_time;
}

fn saveTokenToFile(
    allocator: std.mem.Allocator,
    oauth_response: OAuthResponse,
    existing_refresh_token: ?[]const u8,
) !void {
    const current_time = std.time.timestamp();

    // Create stored token data with current timestamp
    const stored_token = StoredTokenData{
        .access_token = oauth_response.access_token,
        .refresh_token = oauth_response.refresh_token orelse existing_refresh_token,
        .expires_in = oauth_response.expires_in,
        .token_type = oauth_response.token_type,
        .scope = oauth_response.scope,
        .created_at = current_time,
    };

    // Merged ensureConfigDirExists inline
    const home_dir = std.posix.getenv("HOME") orelse return TokenError.FileError;
    const config_dir_path = try std.fs.path.join(
        allocator,
        &[_][]const u8{ home_dir, ".config", CONFIG_DIR_NAME },
    );
    defer allocator.free(config_dir_path);

    std.fs.makeDirAbsolute(config_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return TokenError.FileError,
    };

    const config_path = try getConfigFilePath(allocator);
    defer allocator.free(config_path);

    const file = try std.fs.createFileAbsolute(config_path, .{});
    defer file.close();

    // Use JSON stringify with the struct directly
    try std.json.stringify(stored_token, .{}, file.writer());
}

/// return absolute path of config folder
fn getConfigFilePath(allocator: std.mem.Allocator) ![]u8 {
    const home_dir = std.posix.getenv("HOME") orelse return TokenError.FileError;
    return std.fs.path.join(
        allocator,
        &[_][]const u8{ home_dir, ".config", CONFIG_DIR_NAME, CONFIG_FILE_NAME },
    );
}

/// free StoredTokenData from memory
fn freeTokenData(
    allocator: std.mem.Allocator,
    token_data: StoredTokenData,
) void {
    allocator.free(token_data.access_token);
    if (token_data.refresh_token) |rt| allocator.free(rt);
    allocator.free(token_data.token_type);
    if (token_data.scope) |s| allocator.free(s);
}
