const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("parabellum_abi");
const Logger = abi.Logger;
const WebClient = @import("parabellum_sdk").WebClient;
const ChapterPageItem = @import("fetch_chapter_pages.zig").ChapterPageItem;

pub const DownloadedPageItem = struct {
    source_chapter_id: []const u8,
    series_id: []const u8 = "",
    chapter_number: []const u8 = "",
    page_number: u32,
    url: []const u8,
    image_data: []const u8,
    image_blob: []const u8 = "",
    byte_size: i64 = 0,
    status: []const u8 = "downloaded",
    downloaded_at: i64 = 0,
};

/// Service that downloads a single chapter page image via `WebClient`
/// and returns a DownloadedPageItem containing the raw image bytes.
pub const DownloadChapterPageService = struct {
    web: WebClient,
    logger: Logger,

    pub fn execute(self: *DownloadChapterPageService, alloc: Allocator, item: ChapterPageItem) !DownloadedPageItem {
        if (item.url.len == 0) {
            self.logger.err("Page {d} in chapter '{s}' has an empty URL", .{
                item.page_number,
                item.source_chapter_id,
            });
            return error.EmptyPageUrl;
        }

        self.logger.info("Downloading page {d} from '{s}'", .{ item.page_number, item.url });

        const body = try self.web.fetchBytes(alloc, "download_bytes", .{ .url = item.url });
        if (body.len == 0) {
            alloc.free(body);
            self.logger.err("Received empty image payload for page {d} from '{s}'", .{
                item.page_number,
                item.url,
            });
            return error.EmptyImagePayload;
        }

        var tv: std.c.timeval = undefined;
        _ = std.c.gettimeofday(&tv, null);
        const now_sec: i64 = @intCast(tv.sec);

        return DownloadedPageItem{
            .source_chapter_id = try alloc.dupe(u8, item.source_chapter_id),
            .series_id = try alloc.dupe(u8, item.series_id),
            .chapter_number = try alloc.dupe(u8, item.chapter_number),
            .page_number = item.page_number,
            .url = try alloc.dupe(u8, item.url),
            .image_data = body,
            .image_blob = body,
            .byte_size = @intCast(body.len),
            .status = "downloaded",
            .downloaded_at = now_sec,
        };
    }
};
