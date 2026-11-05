const std = @import("std");
const version = @import("src/version.zig");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    mod.addIncludePath(b.path("src/native"));
    mod.addIncludePath(b.path("assets"));
    mod.addCSourceFile(.{ .file = b.path("src/native/common.c"), .flags = &.{"-std=c11"} });
    switch (target.result.os.tag) {
        .macos => {
            if (b.option([]const u8, "macos-sdk", "Path to a macOS SDK when automatic SDK discovery is unavailable")) |sdk| {
                mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
                mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
                mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
            }
            mod.addCSourceFile(.{ .file = b.path("src/native/macos.m"), .flags = &.{"-fobjc-arc"} });
            mod.linkFramework("AppKit", .{});
            mod.linkFramework("Foundation", .{});
            mod.linkFramework("ServiceManagement", .{});
            mod.addCSourceFile(.{ .file = b.path("src/native/startup_macos.m"), .flags = &.{"-fobjc-arc"} });
        },
        .windows => {
            mod.addCSourceFile(.{ .file = b.path("src/native/windows.c"), .flags = &.{} });
            mod.addCSourceFile(.{ .file = b.path("src/native/startup_windows.c"), .flags = &.{} });
            mod.addWin32ResourceFile(.{ .file = b.path("assets/tray_icons.rc"), .include_paths = &.{ b.path("assets"), b.path("src/native") } });
            for ([_][]const u8{ "user32", "shell32", "ws2_32", "ole32", "gdi32", "advapi32" }) |lib| mod.linkSystemLibrary(lib, .{});
        },
        .linux => {
            mod.addCSourceFile(.{ .file = b.path("src/native/linux.c"), .flags = &.{"-Wno-deprecated-declarations"} });
            mod.linkSystemLibrary("gtk+-3.0", .{});
        },
        else => @panic("Supported platforms: macOS, Windows, Linux"),
    }
    const exe = b.addExecutable(.{ .name = "clipboard-sync", .root_module = mod });
    if (target.result.os.tag == .windows) exe.subsystem = .windows;
    b.installArtifact(exe);
    if (target.result.os.tag == .macos) {
        const app_dir = "Clipboard Sync.app";
        const app_binary = b.addInstallFile(exe.getEmittedBin(), app_dir ++ "/Contents/MacOS/clipboard-sync");
        const info_version = std.mem.replaceOwned(u8, b.graph.arena, @embedFile("packaging/macos/Info.plist"), "@APP_VERSION@", version.text) catch @panic("OOM");
        const info = std.mem.replaceOwned(u8, b.graph.arena, info_version, "@APP_BUILD@", version.build_number) catch @panic("OOM");
        const app_info = b.addInstallFile(b.addWriteFiles().add("Info.plist", info), app_dir ++ "/Contents/Info.plist");
        const app_icon = b.addInstallFile(b.path("assets/AppIcon.icns"), app_dir ++ "/Contents/Resources/AppIcon.icns");
        // Bind Info.plist and the bundle identifier into a local signature for SMAppService.
        // A Developer ID identity can replace the default ad-hoc identity for distribution.
        const identity = b.option([]const u8, "macos-sign-identity", "macOS codesign identity (default: local ad-hoc signing)") orelse "-";
        const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", identity });
        sign.addDirectoryArg(.{ .relative = .{ .base = .install_prefix, .sub_path = app_dir } });
        sign.step.dependOn(&app_binary.step);
        sign.step.dependOn(&app_info.step);
        sign.step.dependOn(&app_icon.step);
        b.getInstallStep().dependOn(&sign.step);
        // LaunchServices owns the app process, so closing the launching shell cannot quit it.
        const run = b.addSystemCommand(&.{"open"});
        run.addDirectoryArg(.{ .relative = .{ .base = .install_prefix, .sub_path = app_dir } });
        run.step.dependOn(b.getInstallStep());
        b.step("run", "Launch the menu-bar app without a terminal").dependOn(&run.step);
    } else {
        const run = b.addRunArtifact(exe);
        b.step("run", "Run the tray application").dependOn(&run.step);
    }
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/core.zig"), .target = target, .optimize = optimize }) });
    const test_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Test protocol, encryption, pairing, sync, history, and validation");
    test_step.dependOn(&test_run.step);
    const integration_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    integration_mod.addIncludePath(b.path("src/native"));
    integration_mod.addCSourceFile(.{ .file = b.path("tests/mock.c"), .flags = &.{} });
    const integration = b.addTest(.{ .root_module = integration_mod });
    test_step.dependOn(&b.addRunArtifact(integration).step);
    if (target.result.os.tag == .windows) {
        const startup_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        startup_mod.addIncludePath(b.path("src/native"));
        // A test-only key keeps the real login configuration untouched.
        startup_mod.addCMacro("CS_STARTUP_KEY", "L\"Software\\\\ClipboardSync\\\\StartupTest\"");
        startup_mod.addCSourceFiles(.{ .files = &.{ "src/native/startup_windows.c", "tests/startup_windows.c" }, .flags = &.{} });
        startup_mod.linkSystemLibrary("advapi32", .{});
        const startup_test = b.addExecutable(.{ .name = "startup-test", .root_module = startup_mod });
        test_step.dependOn(&b.addRunArtifact(startup_test).step);
    }
    const log_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    log_mod.addIncludePath(b.path("src/native"));
    log_mod.addCSourceFiles(.{ .files = &.{ "src/native/common.c", "tests/log.c" }, .flags = &.{} });
    if (target.result.os.tag == .windows) log_mod.linkSystemLibrary("ws2_32", .{});
    const log_test = b.addExecutable(.{ .name = "log-test", .root_module = log_mod });
    test_step.dependOn(&b.addRunArtifact(log_test).step);
    const transport_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    transport_mod.addIncludePath(b.path("src/native"));
    transport_mod.addCMacro("CS_PORT", "0");
    transport_mod.addCMacro("CS_TESTING", "1");
    transport_mod.addCSourceFiles(.{ .files = &.{ "src/native/common.c", "tests/transport.c" }, .flags = &.{} });
    if (target.result.os.tag == .windows) transport_mod.linkSystemLibrary("ws2_32", .{}) else transport_mod.linkSystemLibrary("pthread", .{});
    const transport = b.addExecutable(.{ .name = "transport-test", .root_module = transport_mod });
    test_step.dependOn(&b.addRunArtifact(transport).step);
}
