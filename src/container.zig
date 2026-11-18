const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("parabellum_abi");
const WebClient = @import("parabellum_sdk").WebClient;
const sources = @import("sources/mod.zig");
const AppConfig = @import("config.zig").AppConfig;
const KomgaWebClient = @import("tasks/upload_cbz.zig").KomgaWebClient;

const TaskContext = abi.TaskContext;
const MangaSource = sources.MangaSource;
const MangaDexSource = sources.MangaDexSource;
const HtmlGenericSource = sources.HtmlGenericSource;

pub const MangaContext = struct {
    mangadex_web: ?WebClient = null,
    komga_web: ?WebClient = null,
    mangadex_driver: MangaDexSource = undefined,
    html_generic_driver: HtmlGenericSource = undefined,
    komga_library_id: ?[]const u8 = null,

    pub fn init(self: *MangaContext, alloc: Allocator, ctx: TaskContext) !void {
        self.mangadex_web = WebClient.fromContext(ctx, "mangadex_api") catch null;
        self.komga_web = WebClient.fromContext(ctx, "komga_api") catch null;

        const app_cfg = AppConfig.load(alloc, "configs/.env") catch AppConfig.load(alloc, ".env") catch AppConfig{};
        self.komga_library_id = app_cfg.komga_library_id;

        if (self.mangadex_web) |mw| {
            self.mangadex_driver = MangaDexSource.init(mw);
        }
        self.html_generic_driver = HtmlGenericSource.init("html_generic", "https://visortmo.com");
    }

    pub fn deinit(_: *MangaContext) void {}

    /// @Bean Factory Method: Injects `WebClient` (backed by `mangadex_api` datasource).
    pub fn provideWebClient(self: *MangaContext) !WebClient {
        return self.mangadex_web orelse error.DatasourceNotFound;
    }

    /// @Bean Factory Method: Injects `KomgaWebClient` (backed by `komga_api` datasource).
    pub fn provideKomgaClient(self: *MangaContext) !KomgaWebClient {
        return .{ .web = self.komga_web orelse return error.DatasourceNotFound };
    }

    /// @Bean Factory Method: Automatically discovered at comptime by Parabellum's DI engine
    /// whenever a Service declares a field `source: MangaSource`.
    pub fn provideMangaSource(self: *MangaContext, input: anytype) !MangaSource {
        const has_mangadex = self.mangadex_web != null;

        const InType = @TypeOf(input);

        // 1. Explicit datasource override in input DTO
        if (@typeInfo(InType) == .@"struct" and @hasField(InType, "datasource")) {
            if (input.datasource) |req_id| {
                if (req_id.len > 0) {
                    if (has_mangadex and std.mem.eql(u8, req_id, "mangadex")) {
                        return self.mangadex_driver.mangaSource();
                    }
                    if (std.mem.eql(u8, req_id, "html_generic")) {
                        return self.html_generic_driver.mangaSource();
                    }
                    return error.SourceNotFound;
                }
            }
        }

        // 2. Dynamic capability matching via canHandle (UUID v4 vs. URL pattern)
        const target_id: []const u8 = if (@typeInfo(InType) == .@"struct") blk: {
            if (@hasField(InType, "series_id")) {
                const sid = input.series_id;
                if (@TypeOf(sid) == []const u8) {
                    if (sid.len > 0) break :blk sid;
                }
            }
            if (@hasField(InType, "source_series_id")) {
                const ssid = input.source_series_id;
                if (@TypeOf(ssid) == []const u8) {
                    if (ssid.len > 0) break :blk ssid;
                }
            }
            if (@hasField(InType, "source_chapter_id")) {
                const scid = input.source_chapter_id;
                if (@TypeOf(scid) == []const u8) {
                    if (scid.len > 0) break :blk scid;
                }
            }
            break :blk "";
        } else "";

        if (target_id.len > 0) {
            if (has_mangadex) {
                const md = self.mangadex_driver.mangaSource();
                if (md.canHandle(target_id)) return md;
            }
            const hg = self.html_generic_driver.mangaSource();
            if (hg.canHandle(target_id)) return hg;
        }

        // 3. Default fallback
        if (has_mangadex) return self.mangadex_driver.mangaSource();
        return self.html_generic_driver.mangaSource();
    }
};

pub const MangaPluginContainer = abi.DiContainer(MangaContext);
