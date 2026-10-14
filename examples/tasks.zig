//! Different jobs in one phase: physics, audio and AI.
//! Whichever lane is free takes the next job.
//! `zig build run_tasks`
//!
//! `forEachTask` takes a tuple of `.{ function, .{ arguments } }`.
//! Each task runs once per call.
//! When one fails, the others still run.
//! Then every lane gets the same error back.
//! So `catch` or `try` takes every lane the same way.
//! No lane is left at a barrier the others skipped.
const std = @import("std");
const autobahn = @import("autobahn");

const max_lanes = 8;
const frames = 6;

const World = struct {
    positions: [1024]f32 = @splat(0),
    samples: [512]f32 = @splat(0),
    decisions: u32 = 0,
    frame: u32 = 0,
    skipped: u32 = 0, // Frames whose AI failed.

    const empty: World = .{};
};

pub fn main() !void {
    const lane_count: u8 = @intCast(@min(try autobahn.getCpuCount(), max_lanes));
    var world: World = .empty;
    try autobahn.run(lane_count, entry, .{&world});
    std.debug.assert(world.skipped == 2); // Frames 2 and 5.
    std.debug.assert(world.decisions == frames); // The AI ran every frame, failed or not.
    std.debug.print("{d} frames, {d} skipped after a failed task\n", .{ frames, world.skipped });
}

fn entry(lane: *autobahn.Lane, world: *World) void {
    for (0..frames) |_| {
        // Three jobs, so at most three lanes are busy at once.
        // The call waits for every lane at the end.
        // After it, all three jobs are done, on every lane.
        const thought = if (lane.forEachTask(.{
            .{ physics, .{world} },
            .{ audio, .{world} },
            .{ think, .{world} },
        }, .spin)) |_| true else |err| switch (err) {
            error.Confused => false, // Every lane gets here alike.
            else => unreachable,
        };

        // The rest of the frame: lane 0 alone, then a barrier.
        // The next frame's tasks read `world.frame`.
        // The barrier keeps them from starting while lane 0 still writes it.
        if (lane.lane_idx == 0) {
            if (!thought) world.skipped += 1;
            world.frame += 1;
        }
        lane.barrier.sync(.spin);
    }
}

fn physics(world: *World) void {
    for (&world.positions, 0..) |*p, i| p.* += @as(f32, @floatFromInt(i % 3)) * 0.016;
}

fn audio(world: *World) void {
    for (&world.samples, 0..) |*s, i| s.* = @sin(@as(f32, @floatFromInt(i + world.frame)));
}

fn think(world: *World) error{Confused}!void {
    world.decisions += 1;
    if (world.frame % 3 == 2) return error.Confused; // Every third frame the AI gives up.
}
