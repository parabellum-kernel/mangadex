const std = @import("std");
const Allocator = std.mem.Allocator;
const EnvInterpolator = @import("parabellum_yaml").EnvInterpolator;

pub const AppConfig = struct {
    api_url: []const u8 = "https://api.mangadex.org",
    auth_url: []const u8 = "https://auth.mangadex.org/realms/mangadex/protocol/openid-connect/token",
    user_agent: []const u8 = "ParabellumMangaDex/1.0.0 (https://github.com/parabellum)",

    // Komga integration settings
    komga_url: []const u8 = "http://localhost:25600",
    komga_api_key: ?[]const u8 = null,
    komga_username: ?[]const u8 = null,
    komga_password: ?[]const u8 = null,
    komga_library_id: ?[]const u8 = null,

    /// Loads configuration by resolving environment variables and/or parsing an optional `.env` file.
    pub fn load(allocator: Allocator, dot_env_path: ?[]const u8) !AppConfig {
        var env_arena = std.heap.ArenaAllocator.init(allocator);
        defer env_arena.deinit();
        const env_alloc = env_arena.allocator();

        var interp = EnvInterpolator.init(true);

        if (dot_env_path) |path| {
            if (readDotEnvFile(allocator, path)) |content| {
                defer allocator.free(content);
                interp.parseDotEnv(env_alloc, content) catch {};
            }
        }

        var cfg = AppConfig{};

        if (interp.get("MANGADEX_API_URL")) |url| {
            cfg.api_url = try allocator.dupe(u8, url);
        }
        if (interp.get("MANGADEX_AUTH_URL")) |url| {
            cfg.auth_url = try allocator.dupe(u8, url);
        }
        if (interp.get("MANGADEX_USER_AGENT")) |ua| {
            cfg.user_agent = try allocator.dupe(u8, ua);
        }

        if (interp.get("KOMGA_URL") orelse interp.get("KOMGA_BASE_URL")) |url| {
            cfg.komga_url = try allocator.dupe(u8, url);
        }
        if (interp.get("KOMGA_API_KEY")) |k| {
            cfg.komga_api_key = try allocator.dupe(u8, k);
        }
        if (interp.get("KOMGA_USERNAME")) |u| {
            cfg.komga_username = try allocator.dupe(u8, u);
        }
        if (interp.get("KOMGA_PASSWORD")) |p| {
            cfg.komga_password = try allocator.dupe(u8, p);
        }
        if (interp.get("KOMGA_LIBRARY_ID")) |l| {
            cfg.komga_library_id = try allocator.dupe(u8, l);
        }

        return cfg;
    }

    pub fn readDotEnvFile(allocator: Allocator, path: []const u8) ?[]const u8 {
        const null_path = allocator.dupeSentinel(u8, path, 0) catch return null;
        defer allocator.free(null_path);

        const fd = std.c.open(null_path, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return null;
        defer _ = std.c.close(fd);

        const size_long = std.c.lseek(fd, 0, 2);
        if (size_long <= 0) return null;
        _ = std.c.lseek(fd, 0, 0);

        const size: usize = @intCast(@min(size_long, 64 * 1024));
        const buf = allocator.alloc(u8, size) catch return null;
        errdefer allocator.free(buf);

        const n = std.c.read(fd, buf.ptr, size);
        if (n <= 0) return null;
        return buf[0..@intCast(n)];
    }
};
