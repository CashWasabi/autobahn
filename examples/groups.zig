//! Lanes going separate ways for a while.
//! One group loads, the other keeps running frames.
//! `zig build run_groups`
//!
//! A `Group` is some of the lanes with their own barrier and queue.
//! Inside it, the lanes follow the usual rules among themselves.
//! The parent's barrier brings every lane back together.
//! It needs 2 lanes or more.
const std = @import("std");
const autobahn = @import("autobahn");

const max_lanes = 8;
const chunk_count = 64;

const Shared = struct {
    loader: autobahn.Group,
    frames: autobahn.Group,
    chunks: [chunk_count]u64 = @splat(0),
    loaded: std.atomic.Value(bool) = .init(false), // Set by the loader, read by the frame group.
    frame_count: u32 = 0,
};

pub fn main(init: std.process.Init) !void {
    const lane_count: u8 = @intCast(@min(try autobahn.getCpuCount(), max_lanes));
    if (lane_count < 2) {
        std.debug.print("needs 2 lanes or more\n", .{});
        return;
    }
    // Lane 0 loads, and lanes 1 and up run frames.
    // Each group's lanes count from 0.
    var s: Shared = .{ .loader = .init(0, 1), .frames = .init(1, lane_count - 1) };
    try autobahn.run(lane_count, entry, .{ init.io, &s });
    for (s.chunks, 0..) |chunk, i| std.debug.assert(chunk == expensive(i));
    std.debug.print("{d} chunks loaded while the other {d} lane(s) ran {d} frames\n", .{
        chunk_count, lane_count - 1, s.frame_count,
    });
}

fn entry(lane: *autobahn.Lane, io: std.Io, s: *Shared) void {
    // Take each group's Lane once.
    // It is null if this lane is not in the group.
    var loader = s.loader.lane(lane);
    var frames = s.frames.lane(lane);

    if (loader) |*sub| {
        // The long job.
        // `sub` is a lane like any other, within its group.
        var it = sub.forEachQueued(chunk_count, 1, .{ .wait = .spin });
        while (it.next()) |c| s.chunks[c.start] = expensive(c.start);
        if (sub.lane_idx == 0) s.loaded.store(true, .release);
    } else if (frames) |*sub| {
        // Frames until the loader is done.
        // The group's lanes must agree when to stop.
        // So lane 0 of the group reads the flag, and `broadcast` hands its answer to the rest.
        while (!sub.broadcast(bool, sub.lane_idx == 0 and s.loaded.load(.acquire), .spin)) {
            const r = sub.staticRange(1000, null);
            var busy: u64 = 0;
            for (r.start..r.end()) |i| busy +%= i * i;
            std.mem.doNotOptimizeAway(busy);
            if (sub.lane_idx == 0) s.frame_count += 1;
        }
    }

    lane.barrier.sync(.{ .sleep = io }); // Every lane, back together. The chunks are loaded.
}

fn expensive(i: usize) u64 {
    var x: u64 = i + 1;
    for (0..200_000) |_| x = x *% 6364136223846793005 +% 1442695040888963407;
    return x;
}
