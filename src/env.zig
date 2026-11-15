const std = @import("std");
const Allocator = std.mem.Allocator;

/// Lightweight `.env` parser and `${VAR}` / `${VAR:-default}` interpolator
/// using only `std` (zero dependency on `flowdata` core).
pub const EnvStore = struct {
    vars: std.StringHashMapUnmanaged([]const u8) = .{},
    use_process_env: bool = true,

    pub fn init(use_process_env: bool) EnvStore {
        return .{ .use_process_env = use_process_env };
    }

    pub fn deinit(self: *EnvStore, allocator: Allocator) void {
        var it = self.vars.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.vars.deinit(allocator);
    }

    pub fn put(self: *EnvStore, allocator: Allocator, key: []const u8, value: []const u8) !void {
        const k_dup = try allocator.dupe(u8, key);
        errdefer allocator.free(k_dup);
        const v_dup = try allocator.dupe(u8, value);
        errdefer allocator.free(v_dup);

        if (self.vars.fetchRemove(k_dup)) |old| {
            allocator.free(old.key);
            allocator.free(old.value);
        }
        try self.vars.put(allocator, k_dup, v_dup);
    }

    pub fn get(self: *const EnvStore, key: []const u8) ?[]const u8 {
        if (self.vars.get(key)) |v| return v;
        if (self.use_process_env and key.len < 256) {
            var buf: [256:0]u8 = undefined;
            @memcpy(buf[0..key.len], key);
            buf[key.len] = 0;
            if (std.c.getenv(&buf)) |c_str| {
                return std.mem.span(c_str);
            }
        }
        return null;
    }

    pub fn parseDotEnv(self: *EnvStore, allocator: Allocator, content: []const u8) !void {
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |raw_line| {
            const trimmed = std.mem.trim(u8, raw_line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            var line = trimmed;
            if (std.mem.startsWith(u8, line, "export ")) {
                line = std.mem.trimStart(u8, line["export ".len..], " \t");
            }

            const eq_idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq_idx], " \t");
            if (key.len == 0) continue;

            var val = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");
            if (val.len >= 2 and val[0] == '\'' and val[val.len - 1] == '\'') {
                try self.put(allocator, key, val[1 .. val.len - 1]);
                continue;
            }

            if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
                val = val[1 .. val.len - 1];
            }

            const expanded = try self.expand(allocator, val);
            defer allocator.free(expanded);
            try self.put(allocator, key, expanded);
        }
    }

    pub fn expand(self: *const EnvStore, allocator: Allocator, input: []const u8) ![]const u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(allocator);

        var i: usize = 0;
        while (i < input.len) {
            if (i + 1 < input.len and input[i] == '$' and input[i + 1] == '{') {
                if (std.mem.indexOfScalarPos(u8, input, i + 2, '}')) |close_idx| {
                    const expr = input[i + 2 .. close_idx];
                    if (std.mem.indexOf(u8, expr, ":-")) |def_idx| {
                        const var_name = expr[0..def_idx];
                        const default_val = expr[def_idx + 2 ..];
                        const resolved = if (self.get(var_name)) |v|
                            if (v.len > 0) v else default_val
                        else
                            default_val;
                        try out.appendSlice(allocator, resolved);
                    } else {
                        if (self.get(expr)) |v| {
                            try out.appendSlice(allocator, v);
                        }
                    }
                    i = close_idx + 1;
                    continue;
                }
            }
            try out.append(allocator, input[i]);
            i += 1;
        }
        return try out.toOwnedSlice(allocator);
    }
};
