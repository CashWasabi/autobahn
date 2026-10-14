//! The uneven split: a Mandelbrot image, where some rows cost far more than others.
//! `zig build run_uneven_split -Doptimize=ReleaseFast`
//!
//! Split evenly, the lane with the costly middle rows finishes last.
//! The others wait for it.
//! Through the queue, lanes take a few rows at a time from a shared counter.
//! A lane done with cheap rows comes back for more.
//! Both ways are timed, and the images come out the same.
const std = @import("std");
const autobahn = @import("autobahn");

const max_lanes = 8;
const width = 800;
const height = 600;
const max_iterations = 500;

const Shared = struct {
    even: []u16,
    queued: []u16,
    even_ns: u64 = 0,
    queued_ns: u64 = 0,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const lane_count: u8 = @intCast(@min(try autobahn.getCpuCount(), max_lanes));
    var s: Shared = .{ .even = try gpa.alloc(u16, width * height), .queued = try gpa.alloc(u16, width * height) };
    defer gpa.free(s.even);
    defer gpa.free(s.queued);

    try autobahn.run(lane_count, entry, .{ init.io, &s });

    std.debug.assert(std.mem.eql(u16, s.even, s.queued));
    std.debug.print("{d} lane(s)\n", .{lane_count});
    std.debug.print("  staticRange:              {d:>6} us\n", .{s.even_ns / 1000});
    std.debug.print("  forEachQueued, 4 rows:    {d:>6} us\n", .{s.queued_ns / 1000});
}

fn entry(lane: *autobahn.Lane, io: std.Io, s: *Shared) void {
    // Even: each lane gets its own block of rows, whatever they cost.
    lane.barrier.sync(.spin); // Start the clock with every lane ready.
    var start: std.Io.Clock.Timestamp = .now(io, .awake);
    const rows = lane.staticRange(height, null);
    for (rows.start..rows.end()) |y| renderRow(s.even, y);
    lane.barrier.sync(.spin); // Every row is done. The slowest lane sets the time.
    if (lane.lane_idx == 0) s.even_ns = @intCast(start.untilNow(io).raw.nanoseconds);

    // Queued: four rows at a time, to whichever lane asks next.
    // With `.wait`, the null at the end has waited for every lane.
    // So no barrier is needed after the loop.
    lane.barrier.sync(.spin);
    start = .now(io, .awake);
    var it = lane.forEachQueued(height, 4, .{ .wait = .spin });
    while (it.next()) |batch| {
        for (batch.start..batch.end()) |y| renderRow(s.queued, y);
    }
    if (lane.lane_idx == 0) s.queued_ns = @intCast(start.untilNow(io).raw.nanoseconds);
}

/// Iterations until the point escapes, for every pixel of row `y`.
/// Rows through the set cost the most.
fn renderRow(out: []u16, y: usize) void {
    const ci = (@as(f64, @floatFromInt(y)) / height) * 2.4 - 1.2;
    for (0..width) |x| {
        const cr = (@as(f64, @floatFromInt(x)) / width) * 3.2 - 2.2;
        var zr: f64 = 0;
        var zi: f64 = 0;
        var n: u16 = 0;
        while (n < max_iterations and zr * zr + zi * zi <= 4) : (n += 1) {
            const t = zr * zr - zi * zi + cr;
            zi = 2 * zr * zi + ci;
            zr = t;
        }
        out[y * width + x] = n;
    }
}
