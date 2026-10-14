const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("autobahn", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    // `zig build run_<name>`: examples/<name>.zig. In reading order: the entrypoint, barriers, the ways of
    // sharing work, then the extras. `demo` has every way of sharing work in one.
    const examples = [_][]const u8{
        "hello", "phases", "even_split", "uneven_split", "tasks", // the core
        "search", "groups", "simd", // the extras
        "demo",
    };
    for (examples) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "autobahn", .module = mod }},
            }),
        });
        b.installArtifact(exe);
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        run_cmd.addPassthruArgs();
        b.step(b.fmt("run_{s}", .{name}), b.fmt("Run the '{s}' example", .{name})).dependOn(&run_cmd.step);
    }

    // `zig build bench`: examples/bench.zig, what the lanes cost.
    // Always ReleaseFast
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "autobahn", .module = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = target,
                .optimize = .ReleaseFast,
            }) }},
        }),
    });
    b.step("bench", "Measure the lanes (ReleaseFast)").dependOn(&b.addRunArtifact(bench).step);
}
