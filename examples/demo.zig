//! Autobahn demo: every lane runs the same function in step.
//!
//! There is no pool object.
//! `autobahn.run` starts `lane_count - 1` threads and runs lane 0 on the calling thread.
//! Each lane gets its own `Lane`.
//! Every lane walks the same phases, and barriers keep them together.
//! The phases show each way of sharing work:
//!
//!   1. lane 0 alone, the others sleep   `sync(.sleep)`   (long single-threaded work)
//!   2. lane 0 alone, the others spin    `sync(.spin)`    (short single-threaded work)
//!   3. static split                     `staticRange`    (even cost per item)
//!   4. dynamic split                    `forEachQueued`  (uneven cost per item)
//!   5. different jobs in parallel       `forEachTask`    (independent functions)
//!
//! The rules that keep it from hanging:
//!   - Every lane reaches every barrier the same number of times.
//!   - Every lane decides the path the same way.
//!     Here the frame count is fixed.
//!     With an exit flag, lane 0 sets it before a barrier and every lane reads it after.
//!   - `forEachQueued` and `forEachTask` do not wait on entry.
//!     When the work runs out they wait as told.
//!     With `.no_wait` a lane goes straight on, and a later barrier comes before reading the results.
//!   - `staticRange` does not wait, so put a barrier after it.
//!   - Every lane calls `next` until it returns null.
//!   - At one barrier every lane waits the same way.
//!
//! The demo checks its own results.
//! So it doubles as a smoke test.
const std = @import("std");
const autobahn = @import("autobahn");

const item_count = 1 << 20;
const frames = 3;
const max_lanes = 4;

/// What the lanes work on.
/// Lane 0 writes `scale` before a barrier.
/// The arrays are split between the lanes.
const Shared = struct {
    scale: u32 = 0,
    scaled: []u32, // phase 3: index * scale
    uneven: []u32, // phase 4: index + (index % 64), costing index % 64
    squares: []u32, // phase 5, task 1
    doubled: []u32, // phase 5, task 2
    marker: []u32, // phase 5, task 3
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const lane_count: u8 = @intCast(@min(try autobahn.getCpuCount(), max_lanes));

    var shared: Shared = .{
        .scaled = try gpa.alloc(u32, item_count),
        .uneven = try gpa.alloc(u32, item_count),
        .squares = try gpa.alloc(u32, item_count),
        .doubled = try gpa.alloc(u32, item_count),
        .marker = try gpa.alloc(u32, item_count),
    };
    defer inline for (.{ shared.scaled, shared.uneven, shared.squares, shared.doubled, shared.marker }) |s| gpa.free(s);

    std.debug.print("autobahn demo: {d} lane(s), {d} items, {d} frames\n", .{ lane_count, item_count, frames });

    // Lanes 1 and up run on their own threads, lane 0 on this one.
    // `run` returns when all are done.
    // The barrier, the queue and each `Lane` live in `run`.
    // If a thread cannot start, no lane runs and `run` returns the error.
    try autobahn.run(lane_count, entrypoint, .{ init.io, &shared });
    std.debug.print("all frames ok\n", .{});
}

fn entrypoint(lane: *autobahn.Lane, io: std.Io, shared: *Shared) void {
    for (0..frames) |frame| {
        // 1. Serial work while the other lanes sleep on a futex.
        //    Use it when lane 0 will be busy for a while.
        if (lane.lane_idx == 0) {
            @memset(shared.scaled, 0);
            @memset(shared.uneven, 0);
        }
        lane.barrier.sync(.{ .sleep = io });

        // 2. Serial work while the other lanes spin.
        //    They come back faster but burn their cores, so keep it short.
        if (lane.lane_idx == 0) shared.scale = @intCast(frame + 2);
        lane.barrier.sync(.spin);

        // 3. Even split: each lane works out its own slice.
        //    Below 1024 items per lane, fewer lanes take part.
        {
            const r = lane.staticRange(item_count, 1024);
            for (shared.scaled[r.start..][0..r.len], r.start..) |*out, i| {
                out.* = @as(u32, @intCast(i)) *% shared.scale;
            }
            lane.barrier.sync(.spin); // staticRange does not wait.
        }

        // 4. Uneven split: lanes take batches from a shared queue.
        //    A lane stuck on costly items does not hold the others back.
        //    Phase 5 writes other arrays, so no lane waits here.
        //    `.no_wait` sends a lane out of items straight on to phase 5.
        {
            var it = lane.forEachQueued(item_count, 4096, .no_wait);
            while (it.next()) |r| {
                for (shared.uneven[r.start..][0..r.len], r.start..) |*out, i| {
                    var v: u32 = @intCast(i);
                    var n = i % 64; // The cost grows with the item.
                    while (n > 0) : (n -= 1) v +%= 1;
                    out.* = v;
                }
            }
            // The null from next() did not wait.
            // Phase 5's barrier covers this phase.
        }

        // 5. Different jobs: whichever lane is free takes the next one.
        //    Each entry is { function, .{ args } }.
        //    A function may return an error.
        //    After every task has run, every lane gets the same error.
        //    So every lane takes the same way out.
        //    The barrier at the end covers phase 4 as well.
        lane.forEachTask(.{
            .{ fillSquares, .{shared.squares} },
            .{ fillDoubled, .{shared.doubled} },
            .{ fillMarker, .{ shared.marker, @as(u32, @intCast(frame)) } },
        }, .spin) catch |err| @panic(@errorName(err));

        // Every lane is past the last barrier, and only lane 0 checks.
        // The others run ahead to the next frame's first barrier and wait there.
        if (lane.lane_idx == 0) {
            verify(shared, frame);
            std.debug.print("frame {d}: ok (scale {d})\n", .{ frame, shared.scale });
        }
    }
}

fn verify(shared: *const Shared, frame: usize) void {
    for (0..item_count) |i| {
        const idx: u32 = @intCast(i);
        std.debug.assert(shared.scaled[i] == idx *% shared.scale);
        std.debug.assert(shared.uneven[i] == idx + idx % 64);
        std.debug.assert(shared.squares[i] == idx *% idx);
        std.debug.assert(shared.doubled[i] == idx *% 2);
        std.debug.assert(shared.marker[i] == frame);
    }
}

fn fillSquares(out: []u32) void {
    for (out, 0..) |*o, i| o.* = @as(u32, @intCast(i)) *% @as(u32, @intCast(i));
}

fn fillDoubled(out: []u32) void {
    for (out, 0..) |*o, i| o.* = @as(u32, @intCast(i)) *% 2;
}

fn fillMarker(out: []u32, marker: u32) void {
    @memset(out, marker);
}
