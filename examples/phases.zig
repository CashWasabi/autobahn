//! A frame loop: serial and parallel phases, kept in step by barriers.
//! `zig build run_phases`
//!
//! Each frame:
//!   1. lane 0 alone, long    (the others sleep: `sync(.{ .sleep = io })`)
//!   2. every lane, in parallel, each on its own share
//!   3. lane 0 alone, short   (the others spin: `sync(.spin)`)
//!   4. the decision to stop, made by lane 0 and read by every lane
//!
//! Step 4 is the one to watch.
//! Every lane must leave the loop at the same frame.
//! Otherwise the lanes still in it wait at a barrier for ever.
//! So one lane decides, and every lane reads that decision after a barrier.
const std = @import("std");
const autobahn = @import("autobahn");

const max_lanes = 8;
const cell_count = 1 << 16;

const Shared = struct {
    cells: []u32,
    step: u32 = 0, // Lane 0 writes it in phase 1. Every lane reads it in phase 2.
    sum: u64 = 0, // Lane 0 writes it in phase 3.
    stop: bool = false, // Lane 0 writes it in phase 4. Every lane reads it after the barrier.
};

pub fn main(init: std.process.Init) !void {
    const lane_count: u8 = @intCast(@min(try autobahn.getCpuCount(), max_lanes));
    var s: Shared = .{ .cells = try init.gpa.alloc(u32, cell_count) };
    defer init.gpa.free(s.cells);

    try autobahn.run(lane_count, entry, .{ init.io, &s });
    std.debug.print("stopped after step {d}, sum {d}\n", .{ s.step, s.sum });
}

fn entry(lane: *autobahn.Lane, io: std.Io, s: *Shared) void {
    while (true) {
        // 1. Lane 0 alone, for a while.
        //    The others sleep instead of burning their cores.
        if (lane.lane_idx == 0) {
            s.step += 1;
            if (s.step == 1) @memset(s.cells, 0); // Set-up: long and serial.
        }
        lane.barrier.sync(.{ .sleep = io });

        // 2. Every lane on its own share.
        //    `s.step` was written before the barrier, so every lane sees it.
        const r = lane.staticRange(s.cells.len, 1024);
        for (s.cells[r.start..r.end()], r.start..) |*cell, i| cell.* += @intCast((i % 7) * s.step);
        lane.barrier.sync(.spin); // Lane 0 reads every share next.

        // 3. Lane 0 alone, briefly.
        //    The others spin and are back the moment it is done.
        if (lane.lane_idx == 0) {
            var sum: u64 = 0;
            for (s.cells) |cell| sum += cell;
            s.sum = sum;
            s.stop = sum > 2_000_000; // 4. The decision, made once.
        }
        lane.barrier.sync(.spin);

        // 4. Every lane reads the same `stop`, so every lane leaves at the same frame.
        if (s.stop) break;

        // `s.stop` is written again in the next frame's phase 3.
        // The barriers of phases 1 and 2 come before that.
        // So no lane can overwrite it while another still reads it here.
    }
    // The same decision in one call: lane 0's value, on every lane.
    // `broadcast` is a barrier of its own.
    //     if (lane.broadcast(bool, lane.lane_idx == 0 and s.sum > 2_000_000, .spin)) break;
}
