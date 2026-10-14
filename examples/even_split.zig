//! The even split: a two-pass blur, every lane on its own rows.
//! `zig build run_even_split`
//!
//! `staticRange` works out a lane's share from its index alone.
//! There is no shared counter and nothing to wait for.
//! The barrier between the passes makes it correct.
//! Pass 2 reads the rows above and below each row.
//! Those rows belong to other lanes, so pass 1 must be done first.
const std = @import("std");
const autobahn = @import("autobahn");

const max_lanes = 8;
const width = 1024;
const height = 768;

const Image = struct {
    src: []f32,
    tmp: []f32, // Pass 1 writes it. Pass 2 reads it.
    dst: []f32,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const lane_count: u8 = @intCast(@min(try autobahn.getCpuCount(), max_lanes));
    var img: Image = undefined;
    inline for (.{ "src", "tmp", "dst" }) |name| @field(img, name) = try gpa.alloc(f32, width * height);
    defer inline for (.{ img.src, img.tmp, img.dst }) |buf| gpa.free(buf);
    for (img.src, 0..) |*px, i| px.* = @floatFromInt((i * 2654435761) % 256); // Noise.

    try autobahn.run(lane_count, entry, .{&img});

    // Check against one lane's blur.
    const tmp = try gpa.alloc(f32, width * height);
    defer gpa.free(tmp);
    const dst = try gpa.alloc(f32, width * height);
    defer gpa.free(dst);
    blurRows(img.src, tmp, 0, height);
    blurColumns(tmp, dst, 0, height);
    std.debug.assert(std.mem.eql(f32, dst, img.dst));
    std.debug.print("{d}x{d} blurred on {d} lane(s), same as on one\n", .{ width, height, lane_count });
}

fn entry(lane: *autobahn.Lane, img: *Image) void {
    // This lane's rows.
    // Below 32 rows per lane, fewer lanes take part and the rest get an empty range.
    const rows = lane.staticRange(height, 32);

    blurRows(img.src, img.tmp, rows.start, rows.end()); // Pass 1 touches only this lane's rows.
    lane.barrier.sync(.spin); // Every row of `tmp` is written.
    blurColumns(img.tmp, img.dst, rows.start, rows.end()); // Pass 2 also reads the neighbouring rows.

    // No barrier here.
    // `run` returns only once every lane has, and nothing reads `dst` before that.
}

/// Each pixel of rows `first .. last` becomes the mean of itself and its left and right neighbours.
fn blurRows(src: []const f32, dst: []f32, first: usize, last: usize) void {
    for (first..last) |y| {
        const row = src[y * width ..][0..width];
        for (0..width) |x| {
            const l = row[if (x == 0) 0 else x - 1];
            const r = row[@min(x + 1, width - 1)];
            dst[y * width + x] = (l + row[x] + r) / 3;
        }
    }
}

/// Each pixel of rows `first .. last` becomes the mean of itself and the pixels above and below.
fn blurColumns(src: []const f32, dst: []f32, first: usize, last: usize) void {
    for (first..last) |y| {
        const up: usize = if (y == 0) 0 else y - 1;
        const down: usize = @min(y + 1, height - 1); // Typed, or @min narrows it to u10.
        for (0..width) |x| {
            dst[y * width + x] = (src[up * width + x] + src[y * width + x] + src[down * width + x]) / 3;
        }
    }
}
