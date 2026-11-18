const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("parabellum_abi");
const Logger = abi.Logger;
const PayloadHandle_ABI = abi.PayloadHandle_ABI;
const WebClient = @import("parabellum_sdk").WebClient;
const CbzArchiveOutput = @import("build_cbz_archive.zig").CbzArchiveOutput;
const DetectContentTypeService = @import("detect_content_type.zig").DetectContentTypeService;

pub const DownloadCoverInputs = struct {
    cbz_archive: []const CbzArchiveOutput,
    series_id: []const u8 = "",
    title: []const u8 = "",
    cover_url: ?[]const u8 = null,
    library: ?[]const u8 = null,
    default_library: ?[]const u8 = null,
};

pub const CoverOutput = struct {
    series_id: []const u8 = "",
    series: []const u8 = "",
    library: []const u8 = "",
    chapter_number: []const u8 = "",
    ext: []const u8 = "",
    data: []const u8 = "",
};

fn coverExtensionForContentType(ct: []const u8) []const u8 {
    if (std.mem.eql(u8, ct, "image/png")) return "png";
    if (std.mem.eql(u8, ct, "image/jpeg")) return "jpg";
    if (std.mem.eql(u8, ct, "image/webp")) return "webp";
    if (std.mem.eql(u8, ct, "image/gif")) return "gif";
    return "jpg";
}

/// Service that downloads the series cover image from `cover_url` via `WebClient`
/// and emits a `CoverOutput` per built CBZ.
pub const DownloadCoverService = struct {
    web: WebClient,
    logger: Logger,

    pub fn canHandle(payload: *const PayloadHandle_ABI) bool {
        const expected = comptime abi.types.schemaId(CbzArchiveOutput);
        return payload.schema_id != 0 and expected != 0 and payload.schema_id == expected;
    }

    pub fn execute(self: *DownloadCoverService, alloc: Allocator, inputs: DownloadCoverInputs) ![]CoverOutput {
        if (inputs.cbz_archive.len == 0) {
            return &.{};
        }

        const first = inputs.cbz_archive[0];
        const resolved_series_id = if (inputs.series_id.len > 0) inputs.series_id else first.series_id;

        const cover_url = inputs.cover_url orelse {
            self.logger.info("No cover_url available for series '{s}'; skipping cover download", .{resolved_series_id});
            return &.{};
        };
        if (cover_url.len == 0) {
            self.logger.info("Empty cover_url for series '{s}'; skipping cover download", .{resolved_series_id});
            return &.{};
        }

        const series_label = blk: {
            if (first.series.len > 0) break :blk first.series;
            if (inputs.title.len > 0) break :blk inputs.title;
            break :blk resolved_series_id;
        };
        const resolved_library = blk: {
            if (first.library.len > 0) break :blk first.library;
            if (inputs.library) |lib| {
                if (lib.len > 0) break :blk lib;
            }
            if (inputs.default_library) |def_lib| {
                if (def_lib.len > 0) break :blk def_lib;
            }
            break :blk "Manga";
        };

        self.logger.info("Downloading cover for series '{s}' from '{s}'", .{ series_label, cover_url });

        const body = self.web.fetchBytes(alloc, "download_bytes", .{ .url = cover_url }) catch |err| {
            self.logger.warn("Cover download failed for '{s}': {s}; skipping", .{ series_label, @errorName(err) });
            return &.{};
        };
        if (body.len == 0) {
            alloc.free(body);
            return &.{};
        }

        const content_type = DetectContentTypeService.detect(body);
        const ext = coverExtensionForContentType(content_type);

        var outputs = try alloc.alloc(CoverOutput, inputs.cbz_archive.len);
        for (inputs.cbz_archive, 0..) |cbz, idx| {
            outputs[idx] = .{
                .series_id = try alloc.dupe(u8, if (cbz.series_id.len > 0) cbz.series_id else resolved_series_id),
                .series = try alloc.dupe(u8, if (cbz.series.len > 0) cbz.series else series_label),
                .library = try alloc.dupe(u8, if (cbz.library.len > 0) cbz.library else resolved_library),
                .chapter_number = try alloc.dupe(u8, cbz.chapter_number),
                .ext = try alloc.dupe(u8, ext),
                .data = try alloc.dupe(u8, body),
            };
        }
        alloc.free(body);

        return outputs;
    }
};
