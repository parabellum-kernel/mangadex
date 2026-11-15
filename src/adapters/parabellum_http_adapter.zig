const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("parabellum_abi");
const sdk = @import("mangadex_sdk");

pub const ParabellumHttpAdapter = struct {
    task_ctx: abi.TaskContext,

    comptime {
        sdk.HttpTransport.assertImplements(@This());
    }

    pub fn fromTaskContext(ctx: abi.TaskContext) ParabellumHttpAdapter {
        return .{ .task_ctx = ctx };
    }

    pub fn httpTransport(self: *ParabellumHttpAdapter) sdk.HttpTransport {
        return .{
            .ptr = self,
            .vtable = &.{ .execute = executeBridge },
        };
    }

    fn executeBridge(
        ctx: *anyopaque,
        allocator: Allocator,
        method: sdk.HttpMethod,
        url: []const u8,
        headers: []const sdk.HttpHeader,
        body: []const u8,
    ) sdk.HttpTransportError!sdk.HttpResponse {
        const self: *ParabellumHttpAdapter = @ptrCast(@alignCast(ctx));
        const task_ctx = self.task_ctx;

        var fields = std.ArrayListUnmanaged(abi.NamedField_ABI).empty;
        defer {
            for (fields.items) |f| allocator.free(std.mem.span(f.name_ptr));
            fields.deinit(allocator);
        }
        for (headers) |h| {
            const name_z = allocator.dupeSentinel(u8, h.name, 0) catch return error.OutOfMemory;
            fields.append(allocator, abi.NamedField_ABI.init(
                name_z,
                abi.Value_ABI.fromText(h.value),
            )) catch {
                allocator.free(name_z);
                return error.OutOfMemory;
            };
        }

        const res = task_ctx.netRequest(.{
            .url = abi.Slice_ABI.fromSlice(url),
            .operation = abi.Slice_ABI.fromSlice(method.asText()),
            .headers_ptr = if (fields.items.len > 0) fields.items.ptr else null,
            .headers_len = fields.items.len,
            .body = abi.Slice_ABI.fromSlice(body),
        }) catch |err| {
            task_ctx.logErrorFmt("netRequest failed for {s} '{s}': {s}", .{ method.asText(), url, @errorName(err) });
            return switch (err) {
                error.NetworkRateLimited => error.RateLimited,
                error.NetworkAcquireTimeout => error.Timeout,
                error.InvalidArgument => error.InvalidUrl,
                error.OutOfMemory => error.OutOfMemory,
                else => error.NetworkFailure,
            };
        };

        task_ctx.logInfoFmt("HTTP {s} {s} => status={d} len={d}", .{ method.asText(), url, res.status_code, res.body.toSlice().len });
        if (res.status_code >= 400) {
            task_ctx.logWarnFmt("HTTP error body: {s}", .{res.body.toSlice()});
        }

        return .{
            .status_code = res.status_code,
            .body = res.body.toSlice(),
            .retry_after_ms = 0,
        };
    }
};
