const std = @import("std");
const abi = @import("parabellum_abi");
const ParabellumHttpAdapter = @import("mangadex_app").adapters.ParabellumHttpAdapter;
const ParabellumKomgaAdapter = @import("mangadex_app").adapters.ParabellumKomgaAdapter;
const sdk = @import("mangadex_sdk");
const komga_sdk = @import("mangadex_app").komga_sdk;

const MockNetMode = enum {
    normal,
    rate_limited_err,
};

const MockState = struct {
    mode: MockNetMode = .normal,
    last_method: []const u8 = "",
    last_url: []const u8 = "",
    last_header_count: usize = 0,
};

fn noopLog(_: *abi.TaskContext_ABI, _: abi.LogLevel_ABI, _: [*]const u8, _: usize) callconv(.c) void {}

fn mockNetRequest(
    ctx: *abi.TaskContext_ABI,
    req: *const abi.NetRequest_ABI,
    out_resp: *abi.NetResponse_ABI,
) callconv(.c) abi.HostError_ABI {
    const state: *MockState = @ptrCast(@alignCast(ctx.opaque_host_state));
    state.last_method = req.operation.toSlice();
    state.last_url = req.url.toSlice();
    state.last_header_count = req.headers_len;

    if (state.mode == .rate_limited_err) {
        return .network_rate_limited;
    }

    const url = req.url.toSlice();
    if (std.mem.indexOf(u8, url, "/ping") != null) {
        out_resp.* = .{
            .status_code = 200,
            .body = abi.Slice_ABI.fromSlice("pong"),
            .latency_ms = 5,
        };
        return .ok;
    }

    if (std.mem.indexOf(u8, url, "/rate-limited") != null) {
        out_resp.* = .{
            .status_code = 429,
            .body = abi.Slice_ABI.fromSlice("Too Many Requests"),
        };
        return .ok;
    }

    out_resp.* = .{
        .status_code = 200,
        .body = abi.Slice_ABI.fromSlice("{\"result\":\"ok\"}"),
    };
    return .ok;
}

fn makeMockTaskContext(state: *MockState, raw_ctx: *abi.TaskContext_ABI) abi.TaskContext {
    const vtable = &struct {
        const table = abi.HostApiVTable_ABI{
            .stream_size = undefined,
            .stream_read_at = undefined,
            .next_window = undefined,
            .window_read_at = undefined,
            .next_row = undefined,
            .get_param = undefined,
            .emit_row = undefined,
            .artifact_write_at = undefined,
            .artifact_zero_range = undefined,
            .artifact_truncate = undefined,
            .carve_to_quarantine = undefined,
            .log_event = noopLog,
            .net_request = mockNetRequest,
        };
    }.table;

    raw_ctx.* = .{
        .opaque_host_state = state,
        .host = vtable,
    };
    return .{ .raw = raw_ctx };
}

test "ParabellumHttpAdapter bridges TaskContext.netRequest to sdk.HttpTransport" {
    const allocator = std.testing.allocator;
    var state = MockState{};
    var raw_ctx: abi.TaskContext_ABI = undefined;
    const task_ctx = makeMockTaskContext(&state, &raw_ctx);

    var bridge = ParabellumHttpAdapter.fromTaskContext(task_ctx);
    const transport = bridge.httpTransport();

    const resp1 = try transport.execute(allocator, .GET, "https://api.mangadex.org/ping", &.{}, "");
    try std.testing.expectEqual(@as(u16, 200), resp1.status_code);
    try std.testing.expectEqualStrings("pong", resp1.body);
    try std.testing.expectEqualStrings("GET", state.last_method);

    const resp2 = try transport.execute(allocator, .GET, "https://api.mangadex.org/rate-limited", &.{}, "");
    try std.testing.expectEqual(@as(u16, 429), resp2.status_code);
}

test "ParabellumHttpAdapter maps network error properly" {
    var state = MockState{ .mode = .rate_limited_err };
    var raw_ctx: abi.TaskContext_ABI = undefined;
    const task_ctx = makeMockTaskContext(&state, &raw_ctx);

    var bridge = ParabellumHttpAdapter.fromTaskContext(task_ctx);
    const transport = bridge.httpTransport();

    const err = transport.execute(std.testing.allocator, .GET, "https://api.mangadex.org/test", &.{}, "");
    try std.testing.expectError(error.RateLimited, err);
}

test "ParabellumKomgaAdapter bridges TaskContext.netRequest to komga_sdk.HttpTransport" {
    const allocator = std.testing.allocator;
    var state = MockState{};
    var raw_ctx: abi.TaskContext_ABI = undefined;
    const task_ctx = makeMockTaskContext(&state, &raw_ctx);

    var bridge = ParabellumKomgaAdapter.fromTaskContext(task_ctx);
    const transport = bridge.httpTransport();

    const resp1 = try transport.execute(allocator, .GET, "http://localhost:25600/ping", &.{}, "");
    try std.testing.expectEqual(@as(u16, 200), resp1.status_code);
    try std.testing.expectEqualStrings("pong", resp1.body);

    const req_headers = [_]komga_sdk.HttpHeader{
        .{ .name = "X-Auth-Token", .value = "secret123" },
    };
    const resp2 = try transport.execute(allocator, .POST, "http://localhost:25600/api/v1/books", &req_headers, "{}");
    try std.testing.expectEqual(@as(u16, 200), resp2.status_code);
    try std.testing.expectEqualStrings("{\"result\":\"ok\"}", resp2.body);
    try std.testing.expectEqual(@as(usize, 1), state.last_header_count);

    const resp3 = try transport.execute(allocator, .GET, "http://localhost:25600/rate-limited", &.{}, "");
    try std.testing.expectEqual(@as(u16, 429), resp3.status_code);
}

test "ParabellumKomgaAdapter maps network error properly" {
    var state = MockState{ .mode = .rate_limited_err };
    var raw_ctx: abi.TaskContext_ABI = undefined;
    const task_ctx = makeMockTaskContext(&state, &raw_ctx);

    var bridge = ParabellumKomgaAdapter.fromTaskContext(task_ctx);
    const transport = bridge.httpTransport();

    const err = transport.execute(std.testing.allocator, .GET, "http://localhost:25600/api/v1/libraries", &.{}, "");
    try std.testing.expectError(error.RateLimited, err);
}
