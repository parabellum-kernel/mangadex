const std = @import("std");
const Allocator = std.mem.Allocator;
const Logger = @import("parabellum_sdk").task.Logger;
const EgressDeliveryRecord = @import("upload_cbz.zig").EgressDeliveryRecord;
const DownloadedPageItem = @import("download_chapter_page.zig").DownloadedPageItem;

pub const CleanupPageBlobsInputs = struct {
    egress_history: []const EgressDeliveryRecord,
    downloaded_pages: []const DownloadedPageItem,
};

pub const CleanedPageItem = struct {
    source_chapter_id: []const u8,
    page_number: u32,
    url: []const u8,
    image_blob: ?[]const u8 = null,
    byte_size: i64 = 0,
    status: []const u8 = "cleaned",
    downloaded_at: i64 = 0,
};

/// Pure CPU cleanup task that runs after `upload_cbz` succeeds and emits metadata-only
/// `discovered_pages` rows (`image_blob = null`, `status = "cleaned"`) for delivered chapters.
pub const CleanupPageBlobsService = struct {
    logger: Logger,

    pub fn execute(self: *CleanupPageBlobsService, alloc: Allocator, inputs: CleanupPageBlobsInputs) ![]CleanedPageItem {
        var out: std.ArrayListUnmanaged(CleanedPageItem) = .empty;
        errdefer out.deinit(alloc);

        for (inputs.downloaded_pages) |page| {
            var delivered = false;
            for (inputs.egress_history) |rec| {
                if (std.mem.eql(u8, rec.source_chapter_id, page.source_chapter_id) and
                    std.mem.eql(u8, rec.status, "delivered"))
                {
                    delivered = true;
                    break;
                }
            }
            if (!delivered) continue;

            try out.append(alloc, .{
                .source_chapter_id = page.source_chapter_id,
                .page_number = page.page_number,
                .url = page.url,
                .image_blob = null,
                .byte_size = page.byte_size,
                .status = "cleaned",
                .downloaded_at = page.downloaded_at,
            });
        }

        self.logger.info("Cleaned image_blob for {d} delivered page(s)", .{out.items.len});
        return out.toOwnedSlice(alloc);
    }
};
