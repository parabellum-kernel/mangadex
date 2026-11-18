const std = @import("std");
const sdk_abi = @import("parabellum_sdk").abi;
const WebClient = @import("parabellum_sdk").WebClient;
const sources = @import("mangadex_app").sources;
const MangaSource = sources.MangaSource;
const MangaDexSource = sources.MangaDexSource;

const MockSourceRepo = struct {
    const IterState = struct {
        body: []const u8,
        yielded: bool = false,
        field: sdk_abi.NamedField_ABI = undefined,
    };
    var iter_state: IterState = .{ .body = "" };

    fn getCaps(_: *const sdk_abi.driver.RepoHandle_ABI) callconv(.c) sdk_abi.DriverCapabilities_ABI {
        return .{ .read = true, .streaming_read = true };
    }
    fn recCount(_: *const sdk_abi.driver.RepoHandle_ABI, _: sdk_abi.Slice_ABI) callconv(.c) usize {
        return 0;
    }
    fn deinitRepo(_: *sdk_abi.driver.RepoHandle_ABI) callconv(.c) void {}

    fn iterNext(handle: *sdk_abi.driver.RowIteratorHandle_ABI, out_row: *sdk_abi.RowView_ABI) callconv(.c) sdk_abi.HostError_ABI {
        const st: *IterState = @ptrCast(@alignCast(handle));
        if (st.yielded) return .end_of_stream;
        st.yielded = true;
        st.field = .{
            .name = "body",
            .value = .{ .tag = .bytes_val, .payload = .{ .bytes = sdk_abi.Slice_ABI.from(st.body) } },
        };
        out_row.* = .{ .fields_ptr = (&st.field)[0..1].ptr, .fields_len = 1 };
        return .ok;
    }
    fn iterDeinit(_: *sdk_abi.driver.RowIteratorHandle_ABI) callconv(.c) void {}
    const iter_vt = sdk_abi.driver.RowIteratorVTable_ABI{ .next = iterNext, .deinit = iterDeinit };

    fn readStream(_: *sdk_abi.driver.RepoHandle_ABI, spec: *const sdk_abi.ReadSpec_ABI, out_iter: *sdk_abi.driver.RowIterator_ABI) callconv(.c) sdk_abi.HostError_ABI {
        const ep = spec.table.toSlice();
        const body: []const u8 = if (std.mem.eql(u8, ep, "get_manga_feed"))
            \\{
            \\  "result": "ok",
            \\  "data": [
            \\    {
            \\      "id": "ch-101",
            \\      "type": "chapter",
            \\      "attributes": {
            \\        "chapter": "1",
            \\        "volume": "1",
            \\        "title": "Chapter One",
            \\        "translatedLanguage": "en",
            \\        "pages": 12
            \\      },
            \\      "relationships": [
            \\        {
            \\          "id": "group-1",
            \\          "type": "scanlation_group",
            \\          "attributes": { "name": "SpeedScans" }
            \\        }
            \\      ]
            \\    },
            \\    {
            \\      "id": "ch-102",
            \\      "type": "chapter",
            \\      "attributes": {
            \\        "chapter": "1",
            \\        "volume": "1",
            \\        "title": "Capitulo Uno",
            \\        "translatedLanguage": "es-la",
            \\        "pages": 12
            \\      },
            \\      "relationships": [
            \\        {
            \\          "id": "group-1",
            \\          "type": "scanlation_group",
            \\          "attributes": { "name": "SpeedScans" }
            \\        }
            \\      ]
            \\    }
            \\  ]
            \\}
        else if (std.mem.eql(u8, ep, "get_manga"))
            \\{
            \\  "result": "ok",
            \\  "data": {
            \\    "id": "series-123",
            \\    "type": "manga",
            \\    "attributes": {
            \\      "title": { "en": "Grand Blue Dreaming" },
            \\      "altTitles": [{ "ja": "ぐらんぶる" }],
            \\      "availableTranslatedLanguages": ["en", "es-la", "fr"],
            \\      "description": { "en": "Diving manga" },
            \\      "status": "ongoing",
            \\      "year": 2014
            \\    },
            \\    "relationships": [
            \\      { "id": "a1", "type": "author", "attributes": { "name": "Inoue Kenji" } },
            \\      { "id": "a2", "type": "artist", "attributes": { "name": "Yoshioka Kimitake" } },
            \\      { "id": "c1", "type": "cover_art", "attributes": { "fileName": "cover.jpg" } }
            \\    ]
            \\  }
            \\}
        else if (std.mem.eql(u8, ep, "search_manga"))
            \\{
            \\  "result": "ok",
            \\  "data": [
            \\    {
            \\      "id": "series-123",
            \\      "type": "manga",
            \\      "attributes": { "title": { "en": "Grand Blue Dreaming" } },
            \\      "relationships": []
            \\    }
            \\  ]
            \\}
        else
            \\{
            \\  "result": "ok",
            \\  "baseUrl": "https://athome.mangadex.network",
            \\  "chapter": {
            \\    "hash": "hash101",
            \\    "data": ["01.png", "02.png"]
            \\  }
            \\}
        ;
        iter_state = .{ .body = body, .yielded = false };
        out_iter.* = .{ .handle = @ptrCast(&iter_state), .vtable = &iter_vt };
        return .ok;
    }

    const vt = sdk_abi.driver.StorageRepositoryVTable_ABI{
        .get_capabilities = getCaps,
        .record_count = recCount,
        .deinit = deinitRepo,
        .read_stream = readStream,
    };

    pub fn webClient(self: *MockSourceRepo) WebClient {
        return .{ .handle = @ptrCast(self), .vtable = &vt };
    }
};

test "MangaDexSource adapts WebClient JSON responses to MangaSource" {
    const allocator = std.testing.allocator;
    var mock = MockSourceRepo{};
    var md_source = MangaDexSource.init(mock.webClient());
    const source: MangaSource = md_source.mangaSource();

    // 1. Source ID
    try std.testing.expectEqualStrings("mangadex", source.getSourceId());

    // 2. Search
    const search_results = try source.search(allocator, "Grand Blue");
    defer {
        for (search_results) |item| {
            allocator.free(item.source_series_id);
            allocator.free(item.title);
            if (item.cover_url) |c| allocator.free(c);
        }
        allocator.free(search_results);
    }
    try std.testing.expectEqual(@as(usize, 1), search_results.len);
    try std.testing.expectEqualStrings("series-123", search_results[0].source_series_id);
    try std.testing.expectEqualStrings("Grand Blue Dreaming", search_results[0].title);

    // 3. Details
    const details = try source.getDetails(allocator, "series-123");
    defer {
        allocator.free(details.title);
        for (details.alt_titles) |a| allocator.free(a);
        allocator.free(details.alt_titles);
        for (details.available_languages) |l| allocator.free(l);
        allocator.free(details.available_languages);
        if (details.summary) |s| allocator.free(s);
        if (details.author) |a| allocator.free(a);
        if (details.artist) |ar| allocator.free(ar);
        allocator.free(details.status);
        if (details.cover_url) |c| allocator.free(c);
    }
    try std.testing.expectEqualStrings("Grand Blue Dreaming", details.title);
    try std.testing.expectEqualStrings("Inoue Kenji", details.author.?);
    try std.testing.expectEqualStrings("Yoshioka Kimitake", details.artist.?);
    try std.testing.expectEqual(@as(?u16, 2014), details.year);
    try std.testing.expectEqual(@as(usize, 3), details.available_languages.len);
    try std.testing.expectEqualStrings("es-la", details.available_languages[1]);

    // 4. Chapters
    const chapters = try source.getChapters(allocator, "series-123", "en");
    defer {
        for (chapters) |ch| {
            allocator.free(ch.source_chapter_id);
            allocator.free(ch.chapter_number);
            if (ch.volume_number) |v| allocator.free(v);
            if (ch.title) |t| allocator.free(t);
            allocator.free(ch.language_iso);
            if (ch.scanlation_group) |g| allocator.free(g);
        }
        allocator.free(chapters);
    }
    try std.testing.expectEqual(@as(usize, 1), chapters.len);
    try std.testing.expectEqualStrings("ch-101", chapters[0].source_chapter_id);
    try std.testing.expectEqualStrings("1", chapters[0].chapter_number);
    try std.testing.expectEqualStrings("SpeedScans", chapters[0].scanlation_group.?);

    // 5. Page URLs
    const pages = try source.getPageUrls(allocator, "ch-101");
    defer {
        for (pages) |p| {
            allocator.free(p.url);
        }
        allocator.free(pages);
    }
    try std.testing.expectEqual(@as(usize, 2), pages.len);
    try std.testing.expectEqual(@as(u32, 1), pages[0].page_number);
    try std.testing.expectEqualStrings("https://athome.mangadex.network/data/hash101/01.png", pages[0].url);
}

test "Plugin task inspects available languages and requests chapters in target language (e.g. Spanish es-la)" {
    const allocator = std.testing.allocator;
    var mock = MockSourceRepo{};
    var md_source = MangaDexSource.init(mock.webClient());
    const source: MangaSource = md_source.mangaSource();

    const details = try source.getDetails(allocator, "series-123");
    defer {
        allocator.free(details.title);
        for (details.alt_titles) |a| allocator.free(a);
        allocator.free(details.alt_titles);
        for (details.available_languages) |l| allocator.free(l);
        allocator.free(details.available_languages);
        if (details.summary) |s| allocator.free(s);
        if (details.author) |a| allocator.free(a);
        if (details.artist) |ar| allocator.free(ar);
        allocator.free(details.status);
        if (details.cover_url) |c| allocator.free(c);
    }

    var has_spanish = false;
    for (details.available_languages) |l| {
        if (std.mem.eql(u8, l, "es-la") or std.mem.eql(u8, l, "es")) {
            has_spanish = true;
            break;
        }
    }
    try std.testing.expect(has_spanish);

    const spanish_chapters = try source.getChapters(allocator, "series-123", "es-la");
    defer {
        for (spanish_chapters) |ch| {
            allocator.free(ch.source_chapter_id);
            allocator.free(ch.chapter_number);
            if (ch.volume_number) |v| allocator.free(v);
            if (ch.title) |t| allocator.free(t);
            allocator.free(ch.language_iso);
            if (ch.scanlation_group) |g| allocator.free(g);
        }
        allocator.free(spanish_chapters);
    }

    try std.testing.expectEqual(@as(usize, 1), spanish_chapters.len);
    try std.testing.expectEqualStrings("es-la", spanish_chapters[0].language_iso);
    try std.testing.expectEqualStrings("Capitulo Uno", spanish_chapters[0].title.?);
}
