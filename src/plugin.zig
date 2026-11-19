const abi = @import("mangadex_app").parabellum_sdk.task;
const app = @import("mangadex_app");

pub const manifest = app.manifest;

comptime {
    @export(&manifest, .{ .name = abi.abi.MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

