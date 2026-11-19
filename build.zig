const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdk_dep = b.dependency("parabellum_sdk", .{
        .target = target,
        .optimize = optimize,
    });
    const libs_dep = b.dependency("parabellum_libs", .{
        .target = target,
        .optimize = optimize,
    });
    const parabellum_sdk_mod = sdk_dep.module("parabellum_sdk");
    const zip_archive_mod = libs_dep.module("parabellum_zip_archive");
    const comicinfo_mod = libs_dep.module("comicinfo");

    // 3. Unified App module (`src/root.zig`: Config, Sources, Container, Tasks, Catalog)
    const app_mod = b.addModule("mangadex_app", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    app_mod.addImport("parabellum_sdk", parabellum_sdk_mod);
    app_mod.addImport("zip_archive", zip_archive_mod);
    app_mod.addImport("comicinfo", comicinfo_mod);

    // 4. Standalone shared library plugin (`libmanga_catalog.so`)
    const plugin_entry_mod = b.createModule(.{
        .root_source_file = b.path("src/plugin.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    plugin_entry_mod.addImport("mangadex_app", app_mod);

    const catalog_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "manga_catalog",
        .root_module = plugin_entry_mod,
    });
    b.installArtifact(catalog_lib);

    // 5. Test suite (pure-SDK & app unit tests, zero parabellum core dependency)
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tests_mod.addImport("parabellum_sdk", parabellum_sdk_mod);
    tests_mod.addImport("mangadex_app", app_mod);
    tests_mod.addImport("zip_archive", zip_archive_mod);
    tests_mod.addImport("comicinfo", comicinfo_mod);

    const test_step = b.step("test", "Run MangaDex test suite");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = app_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = plugin_entry_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tests_mod })).step);
}
