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

const TokenData = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8,
    expires_in: i64,
    token_type: []const u8,
    scope: ?[]const u8,
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
        const new_token = refreshToken(allocator, refresh_token) catch {
            return TokenError.RefreshFailed;
        };
        defer allocator.free(new_token);
        return allocator.dupe(u8, new_token);
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
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_response, .{}) catch {
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
fn getStoredToken(allocator: std.mem.Allocator) !TokenData {
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

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return TokenError.InvalidToken;
    };
    defer parsed.deinit();

    const json_obj = parsed.value.object;

    return TokenData{
        .access_token = try allocator.dupe(u8, json_obj.get("access_token").?.string),
        .refresh_token = if (json_obj.get("refresh_token")) |rt| try allocator.dupe(u8, rt.string) else null,
        .expires_in = json_obj.get("expires_in").?.integer,
        .token_type = try allocator.dupe(u8, json_obj.get("token_type").?.string),
        .scope = if (json_obj.get("scope")) |s| try allocator.dupe(u8, s.string) else null,
        .created_at = json_obj.get("created_at").?.integer,
    };
}

fn isTokenValid(token_data: TokenData) bool {
    const current_time = std.time.timestamp();
    const expiry_time = token_data.created_at + token_data.expires_in - TOKEN_EXPIRY_BUFFER_SECONDS;
    return current_time < expiry_time;
}

fn refreshToken(
    allocator: std.mem.Allocator,
    refresh_token: []const u8,
) ![]const u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const payload = try std.fmt.allocPrint(allocator, "client_id={s}&client_secret={s}&refresh_token={s}&grant_type=refresh_token", .{ env.GOOGLE_CLIENT_ID, env.GOOGLE_CLIENT_SECRET, refresh_token });
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

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body.items, .{}) catch {
        return TokenError.InvalidToken;
    };
    defer parsed.deinit();

    // Save the refreshed token (keep the original refresh_token)
    try saveTokenToFile(allocator, parsed.value, refresh_token);

    // Return the new access token
    const new_access_token = parsed.value.object.get("access_token").?.string;
    return allocator.dupe(u8, new_access_token);
}

fn saveTokenToFile(
    allocator: std.mem.Allocator,
    json_data: std.json.Value,
    existing_refresh_token: ?[]const u8,
) !void {
    const token_obj = json_data.object;
    const current_time = std.time.timestamp();

    var saved_token = std.json.ObjectMap.init(allocator);
    defer saved_token.deinit();

    try saved_token.put("access_token", std.json.Value{ .string = token_obj.get("access_token").?.string });
    try saved_token.put("token_type", std.json.Value{ .string = token_obj.get("token_type").?.string });
    try saved_token.put("expires_in", std.json.Value{ .integer = token_obj.get("expires_in").?.integer });
    try saved_token.put("created_at", std.json.Value{ .integer = current_time });

    // Handle refresh token - use new one if provided, otherwise keep existing
    if (token_obj.get("refresh_token")) |new_refresh_token| {
        try saved_token.put("refresh_token", std.json.Value{ .string = new_refresh_token.string });
    } else if (existing_refresh_token) |existing_token| {
        try saved_token.put("refresh_token", std.json.Value{ .string = existing_token });
    }

    if (token_obj.get("scope")) |scope| {
        try saved_token.put("scope", std.json.Value{ .string = scope.string });
    }

    try ensureConfigDirExists(allocator);

    const config_path = try getConfigFilePath(allocator);
    defer allocator.free(config_path);

    const file = try std.fs.createFileAbsolute(config_path, .{});
    defer file.close();

    const json_value = std.json.Value{ .object = saved_token };
    try std.json.stringify(json_value, .{}, file.writer());
}

/// return absolute path of config folder
fn getConfigFilePath(allocator: std.mem.Allocator) ![]u8 {
    const home_dir = std.posix.getenv("HOME") orelse return TokenError.FileError;
    return std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".config", CONFIG_DIR_NAME, CONFIG_FILE_NAME });
}

/// if config folder exist then return else wise create config folder
fn ensureConfigDirExists(allocator: std.mem.Allocator) !void {
    const home_dir = std.posix.getenv("HOME") orelse return TokenError.FileError;
    const config_dir_path = try std.fs.path.join(allocator, &[_][]const u8{ home_dir, ".config", CONFIG_DIR_NAME });
    defer allocator.free(config_dir_path);

    std.fs.makeDirAbsolute(config_dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return TokenError.FileError,
    };
}

/// free TokenData from memory
fn freeTokenData(
    allocator: std.mem.Allocator,
    token_data: TokenData,
) void {
    allocator.free(token_data.access_token);
    if (token_data.refresh_token) |rt| allocator.free(rt);
    allocator.free(token_data.token_type);
    if (token_data.scope) |s| allocator.free(s);
}
