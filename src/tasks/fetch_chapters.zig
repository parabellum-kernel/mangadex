const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("parabellum_sdk").task;
const Logger = abi.Logger;
const WebClient = @import("parabellum_sdk").client.Client;
const SeriesDetails = @import("fetch_series_details.zig").SeriesDetails;

pub const FetchChaptersInputs = struct {
    series_id: []const u8,
    languages: []const u8 = "en",
    datasource: ?[]const u8 = null,
    target_chapters: []const u8 = "all",
};

pub const ChapterItem = struct {
    source_chapter_id: []const u8,
    series_id: []const u8,
    chapter_number: []const u8,
    volume_number: ?[]const u8 = null,
    title: ?[]const u8 = null,
    language: []const u8,
    scanlation_group: ?[]const u8 = null,
    page_count: u32 = 0,
};

fn matchesSingleFilter(ch_num: []const u8, item: []const u8) bool {
    const target = std.mem.trim(u8, item, " \t\r\n");
    if (target.len == 0) return false;
    if (std.mem.eql(u8, target, "all") or std.mem.eql(u8, target, "*")) return true;
    if (std.mem.eql(u8, ch_num, target)) return true;

    // Suffix '+' notation: e.g. "2+" (chapter 2 onwards inclusive)
    if (std.mem.endsWith(u8, target, "+")) {
        const s_clean = std.mem.trim(u8, target[0 .. target.len - 1], " \t");
        const ch_val = std.fmt.parseFloat(f64, ch_num) catch return false;
        const s_val = std.fmt.parseFloat(f64, s_clean) catch return false;
        return ch_val >= s_val;
    }

    // Comparison operators: ">=2", ">2", "<=5", "<5"
    if (std.mem.startsWith(u8, target, ">=")) {
        const s_clean = std.mem.trim(u8, target[2..], " \t");
        const ch_val = std.fmt.parseFloat(f64, ch_num) catch return false;
        const s_val = std.fmt.parseFloat(f64, s_clean) catch return false;
        return ch_val >= s_val;
    } else if (std.mem.startsWith(u8, target, ">")) {
        const s_clean = std.mem.trim(u8, target[1..], " \t");
        const ch_val = std.fmt.parseFloat(f64, ch_num) catch return false;
        const s_val = std.fmt.parseFloat(f64, s_clean) catch return false;
        return ch_val > s_val;
    } else if (std.mem.startsWith(u8, target, "<=")) {
        const e_clean = std.mem.trim(u8, target[2..], " \t");
        const ch_val = std.fmt.parseFloat(f64, ch_num) catch return false;
        const e_val = std.fmt.parseFloat(f64, e_clean) catch return false;
        return ch_val <= e_val;
    } else if (std.mem.startsWith(u8, target, "<")) {
        const e_clean = std.mem.trim(u8, target[1..], " \t");
        const ch_val = std.fmt.parseFloat(f64, ch_num) catch return false;
        const e_val = std.fmt.parseFloat(f64, e_clean) catch return false;
        return ch_val < e_val;
    }

    // Detect range separators: "...", "..", ":", or "-"
    var start_str: ?[]const u8 = null;
    var end_str: ?[]const u8 = null;

    if (std.mem.indexOf(u8, target, "...")) |dot3_idx| {
        start_str = target[0..dot3_idx];
        end_str = target[dot3_idx + 3 ..];
    } else if (std.mem.indexOf(u8, target, "..")) |dot_idx| {
        start_str = target[0..dot_idx];
        end_str = target[dot_idx + 2 ..];
    } else if (std.mem.indexOfScalar(u8, target, ':')) |colon_idx| {
        start_str = target[0..colon_idx];
        end_str = target[colon_idx + 1 ..];
    } else if (std.mem.indexOfScalar(u8, target, '-')) |dash_idx| {
        start_str = target[0..dash_idx];
        end_str = target[dash_idx + 1 ..];
    }

    if (start_str) |s_raw| {
        const e_raw = end_str.?;
        const s_clean = std.mem.trim(u8, s_raw, " \t");
        const e_clean = std.mem.trim(u8, e_raw, " \t");

        // Must have at least start or end defined
        if (s_clean.len == 0 and e_clean.len == 0) return true;

        const ch_val = std.fmt.parseFloat(f64, ch_num) catch return false;

        // Both bounds are inclusive: [s_val, e_val]
        if (s_clean.len > 0) {
            const s_val = std.fmt.parseFloat(f64, s_clean) catch return false;
            if (ch_val < s_val) return false;
        }

        if (e_clean.len > 0) {
            const e_val = std.fmt.parseFloat(f64, e_clean) catch return false;
            if (ch_val > e_val) return false;
        }

        return true;
    }

    return false;
}

pub fn matchesChapterFilter(ch_num: []const u8, filter: []const u8) bool {
    const trimmed = std.mem.trim(u8, filter, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "all") or std.mem.eql(u8, trimmed, "*")) {
        return true;
    }
    var it = std.mem.tokenizeScalar(u8, trimmed, ',');
    while (it.next()) |item| {
        if (matchesSingleFilter(ch_num, item)) return true;
    }
    return false;
}

pub const FetchChaptersService = struct {
    web: WebClient,
    logger: Logger,

    /// Only accepts `SeriesDetails` payloads (`series_id` + `source_id`, without chapter/page fields),
    /// preventing re-entry on `DownloadedPageItem` (`series_id` + `status`).
    pub fn canHandle(payload: *const abi.abi.PayloadHandle_ABI) bool {
        return payload.getReflected("series_id") != null and
            payload.getReflected("source_id") != null and
            payload.getReflected("page_number") == null and
            payload.getReflected("source_chapter_id") == null;
    }

    pub fn execute(self: *FetchChaptersService, alloc: Allocator, inputs: FetchChaptersInputs) ![]ChapterItem {
        var chapters_list: std.ArrayListUnmanaged(ChapterItem) = .empty;

        var lang_iter = std.mem.tokenizeScalar(u8, inputs.languages, ',');
        while (lang_iter.next()) |raw_lang| {
            const lang = std.mem.trim(u8, raw_lang, " \t\r\n");
            if (lang.len == 0) continue;

            self.logger.info("Fetching chapters for series '{s}' in language '{s}' (filter: '{s}')", .{
                inputs.series_id,
                lang,
                inputs.target_chapters,
            });

            var offset: u32 = 0;
            const page_limit: u32 = 100;
            while (true) {
                const body = try self.web.fetchText(alloc, "get_manga_feed", .{
                    .manga_id = inputs.series_id,
                    .limit = page_limit,
                    .offset = offset,
                });
                defer alloc.free(body);

                const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
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

                    const t_lang = if (attrs.get("translatedLanguage")) |v| (if (v == .string) v.string else "") else "";
                    if (!std.mem.eql(u8, t_lang, lang)) continue;

                    const ch_num = if (attrs.get("chapter")) |v| (if (v == .string) v.string else "") else "";
                    if (!matchesChapterFilter(ch_num, inputs.target_chapters)) continue;

                    var already_exists = false;
                    for (chapters_list.items) |existing| {
                        if (std.mem.eql(u8, existing.chapter_number, ch_num)) {
                            already_exists = true;
                            break;
                        }
                    }
                    if (already_exists) continue;

                    const ch_id = if (obj.get("id")) |v| (if (v == .string) v.string else "") else "";
                    const vol: ?[]const u8 = if (attrs.get("volume")) |v| (if (v == .string) try alloc.dupe(u8, v.string) else null) else null;
                    const title: ?[]const u8 = if (attrs.get("title")) |v| (if (v == .string) try alloc.dupe(u8, v.string) else null) else null;
                    const pages: u32 = if (attrs.get("pages")) |pv| (if (pv == .integer) @intCast(@max(0, pv.integer)) else 0) else 0;

                    var group: ?[]const u8 = null;
                    if (obj.get("relationships")) |rels| {
                        if (rels == .array) {
                            for (rels.array.items) |rel| {
                                if (rel != .object) continue;
                                const rtype = if (rel.object.get("type")) |v| (if (v == .string) v.string else "") else "";
                                if (std.mem.eql(u8, rtype, "scanlation_group")) {
                                    if (rel.object.get("attributes")) |ra| {
                                        if (ra == .object) {
                                            if (ra.object.get("name")) |nv| {
                                                if (nv == .string) group = try alloc.dupe(u8, nv.string);
                                            }
                                        }
                                    }
                                    break;
                                }
                            }
                        }
                    }

                    try chapters_list.append(alloc, .{
                        .source_chapter_id = try alloc.dupe(u8, ch_id),
                        .series_id = inputs.series_id,
                        .chapter_number = try alloc.dupe(u8, ch_num),
                        .volume_number = vol,
                        .title = title,
                        .language = try alloc.dupe(u8, t_lang),
                        .scanlation_group = group,
                        .page_count = pages,
                    });
                }

                offset += @intCast(data_val.array.items.len);
                if (data_val.array.items.len < page_limit or (total > 0 and offset >= total)) {
                    break;
                }
            }
        }

        self.logger.info("Total chapters discovered for series '{s}': {d}", .{
            inputs.series_id,
            chapters_list.items.len,
        });
        return chapters_list.toOwnedSlice(alloc);
    }
};
