//! What the lanes cost, measured.
//! Run it with `zig build bench`, which always builds ReleaseFast.
//!
//!   1. A barrier, spinning and asleep: the price of one "everybody wait here".
//!      And a `reduce`: a barrier with a value from every lane.
//!   2. A million cheap items, split by `staticRange` and by `forEachQueued` at several batch lengths.
//!      This shows what the shared counter costs when the work costs almost nothing.
const std = @import("std");
const autobahn = @import("autobahn");

const item_count = 1 << 20;
const lane_count = 4;

const Results = struct {
    sync_ns: f64 = 0,
    sleep_ns: f64 = 0,
    reduce_ns: f64 = 0,
    one_lane_ns: f64 = 0,
    static_ns: f64 = 0,
    queued_ns: [batch_lens.len]f64 = @splat(0),

    const empty: Results = .{};
};
const batch_lens = [_]usize{ 16, 64, 512, 4096, 65536 };

fn nanosecondsSince(io: std.Io, since: std.Io.Clock.Timestamp) f64 {
    return @floatFromInt(since.untilNow(io).raw.nanoseconds);
}

fn work(items: []u32, range: autobahn.Range) void {
    for (items[range.start..range.end()]) |*item| item.* +%= 1;
}

fn entry(lane: *autobahn.Lane, io: std.Io, items: []u32, results: *Results) void {
    const lead = lane.lane_idx == 0;

    const spins = 200_000;
    lane.barrier.sync(.spin);
    var start: std.Io.Clock.Timestamp = .now(io, .awake);
    for (0..spins) |_| lane.barrier.sync(.spin);
    if (lead) results.sync_ns = nanosecondsSince(io, start) / spins;

    lane.barrier.sync(.spin);
    start = .now(io, .awake);
    var total: u64 = 0;
    for (0..spins) |i| total +%= lane.reduce(u64, i + lane.lane_idx, .Add, .spin);
    std.mem.doNotOptimizeAway(total);
    if (lead) results.reduce_ns = nanosecondsSince(io, start) / spins;

    const sleeps = 5_000;
    lane.barrier.sync(.{ .sleep = io });
    start = .now(io, .awake);
    for (0..sleeps) |_| lane.barrier.sync(.{ .sleep = io });
    if (lead) results.sleep_ns = nanosecondsSince(io, start) / sleeps;

    const rounds = 50;
    // Lane 0 alone, for the baseline.
    lane.barrier.sync(.spin);
    start = .now(io, .awake);
    if (lead) {
        for (0..rounds) |_| work(items, .{ .start = 0, .len = items.len });
        results.one_lane_ns = nanosecondsSince(io, start) / rounds;
    }
    lane.barrier.sync(.spin);

    start = .now(io, .awake);
    for (0..rounds) |_| {
        work(items, lane.staticRange(items.len, null));
        lane.barrier.sync(.spin);
    }
    if (lead) results.static_ns = nanosecondsSince(io, start) / rounds;

    for (batch_lens, 0..) |batch_len, k| {
        lane.barrier.sync(.spin);
        start = .now(io, .awake);
        for (0..rounds) |_| {
            var it = lane.forEachQueued(items.len, batch_len, .{ .wait = .spin });
            while (it.next()) |range| work(items, range);
        }
        if (lead) results.queued_ns[k] = nanosecondsSince(io, start) / rounds;
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const items = try gpa.alloc(u32, item_count);
    defer gpa.free(items);
    @memset(items, 0);
    var results: Results = .empty;
    try autobahn.run(lane_count, entry, .{ init.io, items, &results });

    std.debug.print("{d} lanes\n\n", .{lane_count});
    std.debug.print("a barrier, spinning (.spin):     {d:.0} ns\n", .{results.sync_ns});
    std.debug.print("a barrier, asleep (.sleep):      {d:.0} ns\n", .{results.sleep_ns});
    std.debug.print("a reduce, spinning (.Add, u64):  {d:.0} ns\n\n", .{results.reduce_ns});
    std.debug.print("{d} items, one add each:\n", .{item_count});
    std.debug.print("  one lane:                      {d:.0} us\n", .{results.one_lane_ns / 1000});
    std.debug.print("  staticRange:                   {d:.0} us  ({d:.1}x)\n", .{
        results.static_ns / 1000,
        results.one_lane_ns / results.static_ns,
    });
    for (batch_lens, results.queued_ns) |batch_len, ns| {
        std.debug.print("  forEachQueued, batches of {d:<5} {d:.0} us  ({d:.1}x)\n", .{
            batch_len,
            ns / 1000,
            results.one_lane_ns / ns,
        });
    }
}
