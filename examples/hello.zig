//! The smallest lane program.
//! `zig build run_hello`
//!
//! Read `entry` from top to bottom as if one thread ran it.
//! That is how it is written.
//! Then remember that every lane runs it at the same time, each with its own `lane.lane_idx`.
//! A barrier is the one place where the lanes wait for each other.
//! What any lane wrote before it, every lane can read after it.
const std = @import("std");
const autobahn = @import("autobahn");

const max_lanes = 8;

pub fn main() !void {
    const lane_count: u8 = @intCast(@min(try autobahn.getCpuCount(), max_lanes));
    var arrived: [max_lanes]bool = @splat(false);

    // Lanes 1 and up run on threads, lane 0 on this one.
    // `run` returns when every lane has returned from `entry`.
    try autobahn.run(lane_count, entry, .{&arrived});
}

fn entry(lane: *autobahn.Lane, arrived: *[max_lanes]bool) void {
    // Every lane runs this line at the same time.
    // Each writes its own slot, so they do not clash.
    arrived[lane.lane_idx] = true;
    std.debug.print("lane {d} of {d}: here\n", .{ lane.lane_idx, lane.lane_count });

    // Wait here until every lane has arrived.
    lane.barrier.sync(.spin);

    // After the barrier, every lane's write above is done and visible.
    // Lane 0 checks them all.
    // The others skip the block and return.
    if (lane.lane_idx == 0) {
        for (arrived[0..lane.lane_count]) |a| std.debug.assert(a);
        std.debug.print("all {d} lanes passed the barrier\n", .{lane.lane_count});
    }
}
