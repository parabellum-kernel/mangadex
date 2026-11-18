const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("parabellum_abi");
const Logger = abi.Logger;

pub const MangaJob = struct {
    series_id: []const u8,
    body: []const u8,
    datasource: ?[]const u8 = null,
    languages: []const u8 = "en",
    chapters: []const u8 = "all",
    library: ?[]const u8 = null,
};

pub const SeriesDetails = struct {
    series_id: []const u8,
    source_id: []const u8 = "mangadex",
    title: []const u8,
    author: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    status: []const u8,
    year: ?i64 = null,
    cover_url: ?[]const u8 = null,
    available_languages: []const u8 = "",
    summary: ?[]const u8 = null,
    target_chapters: []const u8 = "all",
    library: ?[]const u8 = null,
};

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

/// Pure CPU task that normalizes raw MangaDex `/manga/{series_id}` JSON into `SeriesDetails`.
pub const FetchSeriesDetailsService = struct {
    logger: Logger,

    pub fn canHandle(payload: *const abi.PayloadHandle_ABI) bool {
        return payload.getReflected("body") != null and payload.getReflected("series_id") != null;
    }

    pub fn execute(self: *FetchSeriesDetailsService, alloc: Allocator, job: MangaJob) !SeriesDetails {
        self.logger.info("Parsing series details for series_id={s}", .{job.series_id});

        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, job.body, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidMangaResponse;
        const data_val = parsed.value.object.get("data") orelse return error.InvalidMangaResponse;
        if (data_val != .object) return error.InvalidMangaResponse;

        const obj = data_val.object;
        const id = getAttrString(obj, "id") orelse job.series_id;
        const attrs = (obj.get("attributes") orelse return error.InvalidMangaResponse).object;

        const title = try alloc.dupe(u8, (if (attrs.get("title")) |t| extractLocalizedString(t) else null) orelse "Untitled");

        var langs_buf: std.ArrayListUnmanaged(u8) = .empty;
        if (attrs.get("availableTranslatedLanguages")) |langs| {
            if (langs == .array) {
                for (langs.array.items, 0..) |l, idx| {
                    if (l == .string) {
                        if (idx > 0) try langs_buf.append(alloc, ',');
                        try langs_buf.appendSlice(alloc, l.string);
                    }
                }
            }
        }

        const summary: ?[]const u8 = if (attrs.get("description")) |d|
            (if (extractLocalizedString(d)) |s| try alloc.dupe(u8, s) else null)
        else
            null;

        const status = try alloc.dupe(u8, getAttrString(attrs, "status") orelse "ongoing");
        const year: ?i64 = if (attrs.get("year")) |y| (if (y == .integer) y.integer else null) else null;

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
                        if (getAttrString(ra.?, "name")) |s| author = try alloc.dupe(u8, s);
                    } else if (std.mem.eql(u8, rtype, "artist")) {
                        if (getAttrString(ra.?, "name")) |s| artist = try alloc.dupe(u8, s);
                    } else if (std.mem.eql(u8, rtype, "cover_art")) {
                        if (getAttrString(ra.?, "fileName")) |fn_str| {
                            cover_url = std.fmt.allocPrint(alloc, "https://uploads.mangadex.org/covers/{s}/{s}", .{ id, fn_str }) catch null;
                        }
                    }
                }
            }
        }

        return SeriesDetails{
            .series_id = job.series_id,
            .source_id = "mangadex",
            .title = title,
            .author = author,
            .artist = artist,
            .status = status,
            .year = year,
            .cover_url = cover_url,
            .available_languages = langs_buf.items,
            .summary = summary,
            .target_chapters = job.chapters,
            .library = job.library,
        };
    }
};
