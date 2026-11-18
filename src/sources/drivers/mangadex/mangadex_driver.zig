const std = @import("std");
const Allocator = std.mem.Allocator;
const contract = @import("../../contract.zig");
const MangaSource = contract.MangaSource;
const SourceMangaSummary = contract.SourceMangaSummary;
const SourceSeriesDetails = contract.SourceSeriesDetails;
const SourceChapter = contract.SourceChapter;
const SourcePageUrl = contract.SourcePageUrl;
const WebClient = @import("parabellum_sdk").WebClient;

const source_id = "mangadex";
const mangadex_host = "mangadex.org";
const default_title = "Untitled";
const default_status = "ongoing";

fn extractLocalizedString(val: std.json.Value) ?[]const u8 {
    if (val != .object) return null;
    if (val.object.get("en")) |en| {
        if (en == .string and en.string.len > 0) return en.string;
    }
    var it = val.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == .string and e.value_ptr.*.string.len > 0) return e.value_ptr.*.string;
    }
    return null;
}

fn getAttrString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

pub const MangaDexSource = struct {
    web: WebClient,

    comptime {
        MangaSource.assertImplements(@This());
    }

    pub fn init(web: WebClient) MangaDexSource {
        return .{ .web = web };
    }

    pub fn mangaSource(self: *MangaDexSource) MangaSource {
        return .{
            .ptr = self,
            .vtable = &.{
                .getSourceId = getSourceIdBridge,
                .search = searchBridge,
                .getDetails = getDetailsBridge,
                .getChapters = getChaptersBridge,
                .getPageUrls = getPageUrlsBridge,
                .canHandle = canHandleBridge,
            },
        };
    }

    fn getSourceIdBridge(_: *anyopaque) []const u8 {
        return source_id;
    }

    fn canHandleBridge(_: *anyopaque, identifier: []const u8) bool {
        if (std.mem.indexOf(u8, identifier, mangadex_host) != null) return true;
        if (identifier.len == 36 and
            identifier[8] == '-' and
            identifier[13] == '-' and
            identifier[18] == '-' and
            identifier[23] == '-')
        {
            return true;
        }
        return false;
    }

    fn searchBridge(ctx: *anyopaque, allocator: Allocator, query: []const u8) anyerror![]SourceMangaSummary {
        const self: *MangaDexSource = @ptrCast(@alignCast(ctx));
        const body = try self.web.fetchText(allocator, "search_manga", .{
            .title = query,
            .limit = @as(u64, 20),
        });
        defer allocator.free(body);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return &.{};
        const data_val = parsed.value.object.get("data") orelse return &.{};
        if (data_val != .array) return &.{};

        var list = try allocator.alloc(SourceMangaSummary, data_val.array.items.len);
        for (data_val.array.items, 0..) |item, idx| {
            const obj = item.object;
            const id = getAttrString(obj, "id") orelse "";
            const attrs = if (obj.get("attributes")) |a| (if (a == .object) a.object else null) else null;
            const title_str = if (attrs) |a| (if (a.get("title")) |t| extractLocalizedString(t) else null) else null;

            var cover_url: ?[]const u8 = null;
            if (obj.get("relationships")) |rels| {
                if (rels == .array) {
                    for (rels.array.items) |rel| {
                        if (rel != .object) continue;
                        const rtype = getAttrString(rel.object, "type") orelse continue;
                        if (std.mem.eql(u8, rtype, "cover_art")) {
                            if (rel.object.get("attributes")) |ra| {
                                if (ra == .object) {
                                    if (getAttrString(ra.object, "fileName")) |fn_str| {
                                        cover_url = std.fmt.allocPrint(allocator, "https://uploads.mangadex.org/covers/{s}/{s}.512.jpg", .{ id, fn_str }) catch null;
                                    }
                                }
                            }
                            break;
                        }
                    }
                }
            }

            list[idx] = .{
                .source_id = source_id,
                .source_series_id = try allocator.dupe(u8, id),
                .title = try allocator.dupe(u8, title_str orelse default_title),
                .cover_url = cover_url,
            };
        }
        return list;
    }

    fn getDetailsBridge(ctx: *anyopaque, allocator: Allocator, source_series_id: []const u8) anyerror!SourceSeriesDetails {
        const self: *MangaDexSource = @ptrCast(@alignCast(ctx));
        const body = try self.web.fetchText(allocator, "get_manga", .{
            .manga_id = source_series_id,
        });
        defer allocator.free(body);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidMangaResponse;
        const data_val = parsed.value.object.get("data") orelse return error.InvalidMangaResponse;
        if (data_val != .object) return error.InvalidMangaResponse;

        const obj = data_val.object;
        const id = getAttrString(obj, "id") orelse source_series_id;
        const attrs = (obj.get("attributes") orelse return error.InvalidMangaResponse).object;

        const title = try allocator.dupe(u8, (if (attrs.get("title")) |t| extractLocalizedString(t) else null) orelse default_title);

        var alt_list: std.ArrayListUnmanaged([]const u8) = .empty;
        if (attrs.get("altTitles")) |alts| {
            if (alts == .array) {
                for (alts.array.items) |am| {
                    if (am == .object) {
                        var it = am.object.iterator();
                        while (it.next()) |e| {
                            if (e.value_ptr.* == .string) {
                                try alt_list.append(allocator, try allocator.dupe(u8, e.value_ptr.*.string));
                            }
                        }
                    }
                }
            }
        }

        var lang_list: std.ArrayListUnmanaged([]const u8) = .empty;
        if (attrs.get("availableTranslatedLanguages")) |langs| {
            if (langs == .array) {
                for (langs.array.items) |l| {
                    if (l == .string) {
                        try lang_list.append(allocator, try allocator.dupe(u8, l.string));
                    }
                }
            }
        }

        const summary: ?[]const u8 = if (attrs.get("description")) |d|
            (if (extractLocalizedString(d)) |s| try allocator.dupe(u8, s) else null)
        else
            null;

        const status = try allocator.dupe(u8, getAttrString(attrs, "status") orelse default_status);
        const year: ?u16 = if (attrs.get("year")) |y| (if (y == .integer) @intCast(@max(0, y.integer)) else null) else null;

        var author: ?[]const u8 = null;
        var artist: ?[]const u8 = null;
        var cover_url: ?[]const u8 = null;

        if (obj.get("relationships")) |rels| {
            if (rels == .array) {
                for (rels.array.items) |rel| {
                    if (rel != .object) continue;
                    const rtype = getAttrString(rel.object, "type") orelse continue;
                    const ra = if (rel.object.get("attributes")) |a| (if (a == .object) a.object else null) else null;
                    if (ra == null) continue;

                    if (std.mem.eql(u8, rtype, "author")) {
                        if (getAttrString(ra.?, "name")) |s| author = try allocator.dupe(u8, s);
                    } else if (std.mem.eql(u8, rtype, "artist")) {
                        if (getAttrString(ra.?, "name")) |s| artist = try allocator.dupe(u8, s);
                    } else if (std.mem.eql(u8, rtype, "cover_art")) {
                        if (getAttrString(ra.?, "fileName")) |fn_str| {
                            cover_url = std.fmt.allocPrint(allocator, "https://uploads.mangadex.org/covers/{s}/{s}", .{ id, fn_str }) catch null;
                        }
                    }
                }
            }
        }

        return .{
            .title = title,
            .alt_titles = try alt_list.toOwnedSlice(allocator),
            .available_languages = try lang_list.toOwnedSlice(allocator),
            .summary = summary,
            .author = author,
            .artist = artist,
            .status = status,
            .year = year,
            .cover_url = cover_url,
        };
    }

    fn getChaptersBridge(ctx: *anyopaque, allocator: Allocator, source_series_id: []const u8, lang: []const u8) anyerror![]SourceChapter {
        const self: *MangaDexSource = @ptrCast(@alignCast(ctx));
        var all_chapters: std.ArrayListUnmanaged(SourceChapter) = .empty;

        var offset: u32 = 0;
        const page_limit: u32 = 100;

        while (true) {
            const body = try self.web.fetchText(allocator, "get_manga_feed", .{
                .manga_id = source_series_id,
                .limit = page_limit,
                .offset = offset,
            });
            defer allocator.free(body);

            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
            defer parsed.deinit();
            if (parsed.value != .object) break;

            const data_val = parsed.value.object.get("data") orelse break;
            if (data_val != .array or data_val.array.items.len == 0) break;

            const total: u32 = if (parsed.value.object.get("total")) |tv|
                (if (tv == .integer) @intCast(@max(0, tv.integer)) else 0)
            else
                0;

            for (data_val.array.items) |item| {
                if (item != .object) continue;
                const obj = item.object;
                const attrs = if (obj.get("attributes")) |a| (if (a == .object) a.object else continue) else continue;

                const t_lang = getAttrString(attrs, "translatedLanguage") orelse "";
                if (lang.len > 0 and !std.mem.eql(u8, t_lang, lang)) continue;

                const ch_id = try allocator.dupe(u8, getAttrString(obj, "id") orelse "");
                const ch_num = try allocator.dupe(u8, getAttrString(attrs, "chapter") orelse "");
                const vol: ?[]const u8 = if (getAttrString(attrs, "volume")) |v| try allocator.dupe(u8, v) else null;
                const title: ?[]const u8 = if (getAttrString(attrs, "title")) |t| try allocator.dupe(u8, t) else null;
                const lang_iso = try allocator.dupe(u8, t_lang);
                const pages: u32 = if (attrs.get("pages")) |pv| (if (pv == .integer) @intCast(@max(0, pv.integer)) else 0) else 0;

                var group: ?[]const u8 = null;
                if (obj.get("relationships")) |rels| {
                    if (rels == .array) {
                        for (rels.array.items) |rel| {
                            if (rel != .object) continue;
                            const rtype = getAttrString(rel.object, "type") orelse continue;
                            if (std.mem.eql(u8, rtype, "scanlation_group")) {
                                if (rel.object.get("attributes")) |ra| {
                                    if (ra == .object) {
                                        if (getAttrString(ra.object, "name")) |s| {
                                            group = try allocator.dupe(u8, s);
                                        }
                                    }
                                }
                                break;
                            }
                        }
                    }
                }

                try all_chapters.append(allocator, .{
                    .source_chapter_id = ch_id,
                    .chapter_number = ch_num,
                    .volume_number = vol,
                    .title = title,
                    .language_iso = lang_iso,
                    .scanlation_group = group,
                    .page_count = pages,
                });
            }

            offset += @intCast(data_val.array.items.len);
            if (data_val.array.items.len < page_limit or (total > 0 and offset >= total)) {
                break;
            }
        }

        return all_chapters.toOwnedSlice(allocator);
    }

    fn getPageUrlsBridge(ctx: *anyopaque, allocator: Allocator, source_chapter_id: []const u8) anyerror![]SourcePageUrl {
        const self: *MangaDexSource = @ptrCast(@alignCast(ctx));
        const body = try self.web.fetchText(allocator, "get_at_home_server", .{
            .chapter_id = source_chapter_id,
        });
        defer allocator.free(body);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidAtHomeResponse;

        const base_url = getAttrString(parsed.value.object, "baseUrl") orelse return error.InvalidAtHomeResponse;
        const chapter_val = parsed.value.object.get("chapter") orelse return error.InvalidAtHomeResponse;
        if (chapter_val != .object) return error.InvalidAtHomeResponse;

        const hash = getAttrString(chapter_val.object, "hash") orelse return error.InvalidAtHomeResponse;
        const data_pages = chapter_val.object.get("data") orelse return error.InvalidAtHomeResponse;
        if (data_pages != .array) return error.InvalidAtHomeResponse;

        var list = try allocator.alloc(SourcePageUrl, data_pages.array.items.len);
        for (data_pages.array.items, 0..) |p_val, idx| {
            const filename = if (p_val == .string) p_val.string else "";
            const page_url = try std.fmt.allocPrint(allocator, "{s}/data/{s}/{s}", .{ base_url, hash, filename });
            list[idx] = .{
                .page_number = @intCast(idx + 1),
                .url = page_url,
                .headers = &.{},
            };
        }

        return list;
    }
};
