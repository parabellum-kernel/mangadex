const std = @import("std");
const Allocator = std.mem.Allocator;
const abi = @import("parabellum_abi");
const WebClient = @import("parabellum_sdk").WebClient;
const AppConfig = @import("config.zig").AppConfig;
const KomgaWebClient = @import("tasks/upload_cbz.zig").KomgaWebClient;

const TaskContext = abi.TaskContext;

pub const MangaContext = struct {
    mangadex_web: ?WebClient = null,
    komga_web: ?WebClient = null,
    komga_library_id: ?[]const u8 = null,

    pub fn init(self: *MangaContext, alloc: Allocator, ctx: TaskContext) !void {
        self.mangadex_web = WebClient.fromContext(ctx, "mangadex_api") catch null;
        self.komga_web = WebClient.fromContext(ctx, "komga_api") catch null;

        const app_cfg = AppConfig.load(alloc, "configs/.env") catch AppConfig.load(alloc, ".env") catch AppConfig{};
        self.komga_library_id = app_cfg.komga_library_id;
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
};

pub const MangaPluginContainer = abi.DiContainer(MangaContext);
