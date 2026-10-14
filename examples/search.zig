//! Stopping early.
//! A search ends once any lane finds the answer, and an error reaches every lane.
//! `zig build run_search`
//!
//! Both use the queue's counter.
//! `cancel` pushes it past the end, so every lane's next `next` returns null.
//! `fail` does the same and notes an error.
//! `result` returns that error on every lane after the closing barrier.
const std = @import("std");
const autobahn = @import("autobahn");

const max_lanes = 8;
const item_count = 1 << 22;
const needle = 3_000_017;

const Shared = struct {
    items: []u32,
    found: std.atomic.Value(usize) = .init(std.math.maxInt(usize)),
    searched: std.atomic.Value(usize) = .init(0), // Items looked at, by all lanes.
    broken: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const lane_count: u8 = @intCast(@min(try autobahn.getCpuCount(), max_lanes));
    var s: Shared = .{ .items = try init.gpa.alloc(u32, item_count) };
    defer init.gpa.free(s.items);
    for (s.items, 0..) |*item, i| item.* = @intCast(i *% 7);
    s.items[needle] = 0xdead_beef;

    try autobahn.run(lane_count, entry, .{&s});
    std.debug.assert(s.found.load(.monotonic) == needle);
    std.debug.assert(s.broken);
    std.debug.print("found at {d} after looking at {d} of {d} items; the error reached every lane\n", .{
        s.found.load(.monotonic), s.searched.load(.monotonic), item_count,
    });
}

fn entry(lane: *autobahn.Lane, s: *Shared) void {
    // 1. Search, and stop every lane once one has found it.
    var it = lane.forEachQueued(s.items.len, 4096, .{ .wait = .spin });
    while (it.next()) |batch| {
        _ = s.searched.fetchAdd(batch.len, .monotonic);
        for (s.items[batch.start..batch.end()], batch.start..) |item, i| {
            if (item != 0xdead_beef) continue;
            s.found.store(i, .monotonic);
            it.cancel(); // Lanes finish the batches they hold and take no more.
        }
    }
    // The `.wait` null waited for every lane.
    // So `found` is final here, on every lane.

    // 2. An error in the work.
    //    `fail` notes it, and `result` returns it on every lane.
    check(lane, s) catch |err| {
        std.debug.assert(err == error.Corrupt);
        if (lane.lane_idx == 0) s.broken = true;
    };
}

fn check(lane: *autobahn.Lane, s: *Shared) !void {
    var it = lane.forEachQueued(s.items.len, 4096, .{ .wait = .spin });
    while (it.next()) |batch| {
        for (s.items[batch.start..batch.end()]) |item| {
            if (item == 0xdead_beef) it.fail(error.Corrupt); // Every lane stops taking.
        }
    }
    try it.result(); // The same on every lane, so `try` takes them all the same way.
}
