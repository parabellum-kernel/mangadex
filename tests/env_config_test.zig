const std = @import("std");
const EnvStore = @import("mangadex_app").env.EnvStore;
const AppConfig = @import("mangadex_app").AppConfig;

test "EnvInterpolator.parseDotEnv expands intra-file variables and preserves single-quoted literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interp = EnvStore.init(false);
    defer interp.deinit(alloc);

    const dotenv =
        \\KOMGA_HOST=192.168.1.50
        \\KOMGA_SSH_HOST=${KOMGA_HOST}
        \\KOMGA_URL="http://${KOMGA_HOST}:${KOMGA_PORT:-25600}"
        \\LITERAL_VAL='${KOMGA_HOST}'
    ;

    try interp.parseDotEnv(alloc, dotenv);

    try std.testing.expectEqualStrings("192.168.1.50", interp.get("KOMGA_HOST").?);
    try std.testing.expectEqualStrings("192.168.1.50", interp.get("KOMGA_SSH_HOST").?);
    try std.testing.expectEqualStrings("http://192.168.1.50:25600", interp.get("KOMGA_URL").?);
    try std.testing.expectEqualStrings("${KOMGA_HOST}", interp.get("LITERAL_VAL").?);
}
