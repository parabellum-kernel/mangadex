const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("parabellum_sdk").task;
const Logger = abi.Logger;
const WebClient = @import("parabellum_sdk").client.Client;
const CbzArchiveOutput = @import("build_cbz_archive.zig").CbzArchiveOutput;

pub const KomgaWebClient = struct {
    web: WebClient,
};

pub const UploadCbzInputs = struct {
    cbz_archive: []const CbzArchiveOutput,
    series_title: ?[]const u8 = null,
    title: ?[]const u8 = null,
    library: ?[]const u8 = null,
    default_library: ?[]const u8 = null,
    /// Library scan strategy: "none", "normal" (default), or "deep"
    scan_mode: []const u8 = "normal",
    analyze_series: bool = true,
};

pub const EgressDeliveryRecord = struct {
    id: []const u8,
    source_chapter_id: []const u8,
    target: []const u8,
    external_book_id: ?[]const u8 = null,
    delivered_at: i64,
    status: []const u8,
    details: ?[]const u8 = null,
};

const LibraryDto = struct {
    id: []const u8,
    name: []const u8,
};

const SeriesPageDto = struct {
    content: []const struct {
        id: []const u8,
    } = &.{},
};

fn findLibraryId(libs: []const LibraryDto, target: ?[]const u8) ?[]const u8 {
    if (libs.len == 0) return null;
    if (target) |t| {
        if (t.len > 0) {
            for (libs) |lib| {
                if (std.mem.eql(u8, lib.id, t) or std.ascii.eqlIgnoreCase(lib.name, t)) {
                    return lib.id;
                }
            }
        }
    }
    return libs[0].id;
}

/// Service that synchronizes uploaded CBZ archives with a remote Komga server via `KomgaWebClient`
/// (`driver: rest_api` backed by `configs/api.komga.yaml`).
pub const UploadCbzService = struct {
    komga: KomgaWebClient,
    logger: Logger,
    default_library_id: ?[]const u8 = null,

    pub fn canHandle(payload: *const abi.abi.PayloadHandle_ABI) bool {
        const expected = comptime abi.abi.schemaId(CbzArchiveOutput);
        return payload.schema_id != 0 and expected != 0 and payload.schema_id == expected;
    }

    pub fn execute(self: *UploadCbzService, alloc: Allocator, inputs: UploadCbzInputs) ![]EgressDeliveryRecord {
        if (inputs.cbz_archive.len == 0) {
            self.logger.warn("No CBZ archives to synchronize with Komga", .{});
            return &.{};
        }

        const first = inputs.cbz_archive[0];
        const series_name = blk: {
            if (inputs.series_title) |st| {
                if (st.len > 0) break :blk st;
            }
            if (inputs.title) |t| {
                if (t.len > 0) break :blk t;
            }
            if (first.series.len > 0) break :blk first.series;
            break :blk first.series_id;
        };

        const requested_lib: ?[]const u8 = blk: {
            if (inputs.library) |l| {
                if (l.len > 0) break :blk l;
            }
            if (first.library.len > 0) break :blk first.library;
            if (inputs.default_library) |dl| {
                if (dl.len > 0) break :blk dl;
            }
            break :blk self.default_library_id;
        };

        // 1. Resolve target Komga library ID
        const libs_json = try self.komga.web.fetchText(alloc, "list_libraries", .{});
        defer alloc.free(libs_json);

        const libs_parsed = try std.json.parseFromSlice([]const LibraryDto, alloc, libs_json, .{
            .ignore_unknown_fields = true,
        });
        defer libs_parsed.deinit();

        const library_id = findLibraryId(libs_parsed.value, requested_lib) orelse return error.KomgaLibraryNotFound;

        const is_none = std.ascii.eqlIgnoreCase(inputs.scan_mode, "none");
        const is_deep = std.ascii.eqlIgnoreCase(inputs.scan_mode, "deep");
        const is_normal = std.ascii.eqlIgnoreCase(inputs.scan_mode, "normal");
        if (!is_none and !is_deep and !is_normal) {
            self.logger.err("Invalid scan_mode '{s}'; expected 'none', 'normal', or 'deep'", .{inputs.scan_mode});
            return error.InvalidScanMode;
        }

        // 2. Scan library so Komga discovers newly uploaded CBZ files
        if (!is_none) {
            self.logger.info("Triggering Komga library scan (library_id={s}, scan_mode={s}) for series '{s}'", .{
                library_id,
                inputs.scan_mode,
                series_name,
            });
            try self.komga.web.send(void, alloc, "scan_library", .{
                .library_id = library_id,
                .deep = if (is_deep) "true" else "false",
            }, "");
        } else {
            self.logger.info("Skipping Komga library scan (scan_mode=none) for series '{s}'", .{series_name});
        }

        // 3. Optionally locate the series and trigger analysis
        var komga_series_id: ?[]const u8 = null;
        if (series_name.len > 0) {
            if (self.komga.web.fetchText(alloc, "search_series", .{
                .search = series_name,
                .library_id = library_id,
            })) |search_json| {
                defer alloc.free(search_json);
                if (std.json.parseFromSlice(SeriesPageDto, alloc, search_json, .{ .ignore_unknown_fields = true })) |sp| {
                    defer sp.deinit();
                    if (sp.value.content.len > 0) {
                        komga_series_id = try alloc.dupe(u8, sp.value.content[0].id);
                        if (inputs.analyze_series) {
                            self.komga.web.send(void, alloc, "analyze_series", .{
                                .series_id = komga_series_id.?,
                            }, "") catch |err| {
                                self.logger.warn("Komga analyzeSeries failed for '{s}': {s}", .{
                                    komga_series_id.?,
                                    @errorName(err),
                                });
                            };
                        }
                    }
                } else |_| {}
            } else |err| {
                self.logger.warn("Komga searchSeries failed for '{s}': {s}", .{
                    series_name,
                    @errorName(err),
                });
            }
        }

        // 4. Emit egress_history audit records
        var tv: std.c.timeval = undefined;
        _ = std.c.gettimeofday(&tv, null);
        const now_sec: i64 = @intCast(tv.sec);

        const records = try alloc.alloc(EgressDeliveryRecord, inputs.cbz_archive.len);
        for (inputs.cbz_archive, 0..) |cbz, idx| {
            const chapter_ref = try std.fmt.allocPrint(alloc, "{s}:ch:{s}", .{
                if (cbz.series_id.len > 0) cbz.series_id else series_name,
                cbz.chapter_number,
            });
            const ch_id = if (cbz.source_chapter_id.len > 0) cbz.source_chapter_id else chapter_ref;
            const rec_id = try std.fmt.allocPrint(alloc, "komga:{s}:{d}", .{ ch_id, now_sec });
            const details = try std.fmt.allocPrint(alloc, "library={s} file={s} bytes={d}", .{
                library_id,
                cbz.filename,
                cbz.data.len,
            });
            records[idx] = .{
                .id = rec_id,
                .source_chapter_id = ch_id,
                .target = "komga",
                .external_book_id = if (komga_series_id) |kid| try alloc.dupe(u8, kid) else null,
                .delivered_at = now_sec,
                .status = "delivered",
                .details = details,
            };
        }

        return records;
    }
};
