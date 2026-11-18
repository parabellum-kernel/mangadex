const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("parabellum_abi");
const Logger = abi.Logger;
const WebClient = @import("parabellum_sdk").WebClient;
const fetch_chapters = @import("fetch_chapters.zig");

pub const ChapterItem = fetch_chapters.ChapterItem;
pub const FetchChapterPagesInputs = ChapterItem;

pub const ChapterPageItem = struct {
    source_chapter_id: []const u8,
    series_id: []const u8 = "",
    chapter_number: []const u8 = "",
    page_number: u32,
    url: []const u8,
};

pub const FetchChapterPagesService = struct {
    web: WebClient,
    logger: Logger,

    pub fn execute(self: *FetchChapterPagesService, alloc: Allocator, inputs: FetchChapterPagesInputs) ![]ChapterPageItem {
        self.logger.info("Fetching pages for chapter '{s}' (chapter_number: {s})", .{
            inputs.source_chapter_id,
            inputs.chapter_number,
        });

        const body = try self.web.fetchText(alloc, "get_at_home_server", .{
            .chapter_id = inputs.source_chapter_id,
        });
        defer alloc.free(body);

        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidAtHomeResponse;

        const base_url = if (parsed.value.object.get("baseUrl")) |v|
            (if (v == .string) v.string else return error.InvalidAtHomeResponse)
        else
            return error.InvalidAtHomeResponse;

        const chapter_val = parsed.value.object.get("chapter") orelse return error.InvalidAtHomeResponse;
        if (chapter_val != .object) return error.InvalidAtHomeResponse;

        const hash = if (chapter_val.object.get("hash")) |v|
            (if (v == .string) v.string else return error.InvalidAtHomeResponse)
        else
            return error.InvalidAtHomeResponse;

        const data_pages = chapter_val.object.get("data") orelse return error.InvalidAtHomeResponse;
        if (data_pages != .array) return error.InvalidAtHomeResponse;

        var page_list = try alloc.alloc(ChapterPageItem, data_pages.array.items.len);
        for (data_pages.array.items, 0..) |p_val, idx| {
            const filename = if (p_val == .string) p_val.string else "";
            page_list[idx] = .{
                .source_chapter_id = try alloc.dupe(u8, inputs.source_chapter_id),
                .series_id = try alloc.dupe(u8, inputs.series_id),
                .chapter_number = try alloc.dupe(u8, inputs.chapter_number),
                .page_number = @intCast(idx + 1),
                .url = try std.fmt.allocPrint(alloc, "{s}/data/{s}/{s}", .{ base_url, hash, filename }),
            };
        }

        self.logger.info("Total pages discovered for chapter '{s}': {d}", .{
            inputs.source_chapter_id,
            page_list.len,
        });
        return page_list;
    }
};
