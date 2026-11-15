const abi = @import("parabellum_abi");
const app = @import("mangadex_app");

pub const manifest = app.manifest;

comptime {
    @export(&manifest, .{ .name = abi.MANIFEST_SYMBOL_NAME, .linkage = .strong });
}

