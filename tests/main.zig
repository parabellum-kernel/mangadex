const std = @import("std");

test {
    _ = @import("env_config_test.zig");
    _ = @import("catalog_plugin_test.zig");
    _ = @import("zip_archive_test.zig");
    _ = @import("comicinfo_test.zig");
}
