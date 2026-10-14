//! SIMD inside each lane's share.
//! Particles are moved and tested with vectors, and split between the lanes.
//!
//! Every frame:
//!   1. move     `staticRange`   each lane integrates its share, `VecLen` particles per instruction
//!   2. count    `reduce`        particles near the centre, and the energy, the same on every lane
//!   3. compact  `scan`          the indices of the particles on screen, packed into one array
//!
//! Lane 0 checks every frame against one lane's answer.
//! So this doubles as a smoke test.
const std = @import("std");
pub const autobahn = @import("autobahn");

pub const VecLen = std.simd.suggestVectorLength(f32) orelse 4; // picks 8 on AVX2, 4 on SSE, etc.
pub const Vf = @Vector(VecLen, f32);
pub const Vi = @Vector(VecLen, i32);
pub const Vu8 = @Vector(VecLen, u8);

const particle_count = 100_003; // Not a multiple of VecLen, so the scalar tails run too.
const frames = 20;
const max_lanes = 8;
const frame_dt = 1.0 / 60.0;
const screen = 100.0; // the screen is 0 .. screen in x and y

/// The particles, one array per field.
/// So `VecLen` of them load at once.
const Shared = struct {
    pxs: []f32,
    pys: []f32,
    vxs: []f32,
    vys: []f32,
    widths: []f32,
    heights: []f32,
    near: []bool, // a lane's scratch, per particle
    on_screen: []bool,
    speeds_sq: []f32,
    visible: []u32, // step 3: the indices of the particles on screen, in order
    visible_len: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const lane_count: u8 = @intCast(@min(try autobahn.getCpuCount(), max_lanes));

    var s: Shared = undefined;
    inline for (.{ "pxs", "pys", "vxs", "vys", "widths", "heights", "speeds_sq" }) |name| {
        @field(s, name) = try gpa.alloc(f32, particle_count);
    }
    s.near = try gpa.alloc(bool, particle_count);
    s.on_screen = try gpa.alloc(bool, particle_count);
    s.visible = try gpa.alloc(u32, particle_count);
    s.visible_len = 0;
    defer {
        inline for (.{
            "pxs", "pys", "vxs", "vys", "widths", "heights", "speeds_sq", "near", "on_screen", "visible",
        }) |name| {
            gpa.free(@field(s, name));
        }
    }

    var rng: std.Random.DefaultPrng = .init(42);
    const random = rng.random();
    for (0..particle_count) |i| {
        s.pxs[i] = random.float(f32) * screen * 1.5 - screen * 0.25; // some start off screen
        s.pys[i] = random.float(f32) * screen * 1.5 - screen * 0.25;
        s.vxs[i] = random.float(f32) * 20 - 10;
        s.vys[i] = random.float(f32) * 20 - 10;
        s.widths[i] = 0.5 + random.float(f32);
        s.heights[i] = 0.5 + random.float(f32);
    }

    std.debug.print("autobahn simd: {d} lane(s), {d} particles, vectors of {d}\n", .{
        lane_count,
        particle_count,
        VecLen,
    });
    try autobahn.run(lane_count, entrypoint, .{&s});
    std.debug.print("all frames ok\n", .{});
}

fn entrypoint(lane: *autobahn.Lane, s: *Shared) void {
    for (0..frames) |frame| {
        // 1. Move. No lane reads another's share, so one barrier at the end is enough.
        const r = lane.staticRange(particle_count, 4096);
        const pxs = s.pxs[r.start..r.end()];
        const pys = s.pys[r.start..r.end()];
        integrate(pxs, pys, s.vxs[r.start..r.end()], s.vys[r.start..r.end()], frame_dt);

        // 2. Count. Each lane counts its share and `reduce` adds them up.
        //    `reduce` is a barrier too, so step 1 is done on every lane after it.
        //    Every lane gets the same numbers.
        withinRadius(pxs, pys, screen / 2, screen / 2, screen / 4, s.near[r.start..r.end()]);
        lengthSq(s.vxs[r.start..r.end()], s.vys[r.start..r.end()], s.speeds_sq[r.start..r.end()]);
        var near: u32 = 0;
        for (s.near[r.start..r.end()]) |n| near += @intFromBool(n);
        var energy: f64 = 0;
        for (s.speeds_sq[r.start..r.end()]) |sq| energy += sq / 2;
        const near_total = lane.reduce(u32, near, .Add, .spin);
        const energy_total = lane.reduce(f64, energy, .Add, .spin);

        // 3. Compact. Each lane counts what it keeps.
        //    `scan` gives it where to write, and the total length.
        const widths = s.widths[r.start..r.end()];
        const heights = s.heights[r.start..r.end()];
        withinBounds(pxs, pys, widths, heights, 0, 0, screen, screen, s.on_screen[r.start..r.end()]);
        var kept: usize = 0;
        for (s.on_screen[r.start..r.end()]) |on| kept += @intFromBool(on);
        const at = lane.scan(usize, kept, .Add, .spin);
        var pos = at.before;
        for (s.on_screen[r.start..r.end()], r.start..) |on, i| {
            if (!on) continue;
            s.visible[pos] = @intCast(i);
            pos += 1;
        }
        if (lane.lane_idx == 0) s.visible_len = at.total;
        lane.barrier.sync(.spin); // Every lane wrote its part of `visible`.

        if (lane.lane_idx == 0) {
            verify(s, near_total);
            if (frame % 5 == 0) {
                std.debug.print("frame {d:>2}: {d} near the centre, {d} on screen, energy {d:.1}\n", .{
                    frame,
                    near_total,
                    s.visible_len,
                    energy_total,
                });
            }
        }
        lane.barrier.sync(.spin); // Nobody moves the particles while lane 0 checks them.
    }
}

/// One lane's answer to steps 2 and 3, against the lanes'.
fn verify(s: *const Shared, near_total: u32) void {
    var near: u32 = 0;
    var visible: usize = 0;
    for (0..particle_count) |i| {
        const dx = s.pxs[i] - screen / 2;
        const dy = s.pys[i] - screen / 2;
        near += @intFromBool(dx * dx + dy * dy <= (screen / 4) * (screen / 4));
        const gap_x = @max(s.pxs[i] - screen, 0 - s.pxs[i] + s.widths[i]);
        const gap_y = @max(s.pys[i] - screen, 0 - s.pys[i] + s.heights[i]);
        if (@max(gap_x, gap_y) > 0) continue;
        std.debug.assert(s.visible[visible] == i);
        visible += 1;
    }
    std.debug.assert(near == near_total);
    std.debug.assert(visible == s.visible_len);
}

// common functions
pub fn integrate(pxs: []f32, pys: []f32, vxs: []const f32, vys: []const f32, dt: f32) void {
    const dtv: Vf = @splat(dt);
    var i: usize = 0;
    while (i + VecLen <= pxs.len) : (i += VecLen) {
        var xv: Vf = pxs[i..][0..VecLen].*; // direct load, one instruction
        var yv: Vf = pys[i..][0..VecLen].*;
        const vxv: Vf = vxs[i..][0..VecLen].*;
        const vyv: Vf = vys[i..][0..VecLen].*;

        xv += vxv * dtv;
        yv += vyv * dtv;

        pxs[i..][0..VecLen].* = xv; // direct store
        pys[i..][0..VecLen].* = yv;
    }
    while (i < pxs.len) : (i += 1) { // scalar tail for leftovers
        pxs[i] += vxs[i] * dt;
        pys[i] += vys[i] * dt;
    }
}

pub fn lengthSq(pxs: []const f32, pys: []const f32, out: []f32) void {
    var i: usize = 0;
    while (i + VecLen <= pxs.len) : (i += VecLen) {
        const xv: Vf = pxs[i..][0..VecLen].*;
        const yv: Vf = pys[i..][0..VecLen].*;
        out[i..][0..VecLen].* = xv * xv + yv * yv;
    }
    while (i < pxs.len) : (i += 1)
        out[i] = pxs[i] * pxs[i] + pys[i] * pys[i];
}

// instead of: for (values) |v| queue.push(v);  (N pushes, N bounds checks)
pub fn pushBatch(queue: []f32, write_pos: usize, values: Vf) void {
    queue[write_pos..][0..VecLen].* = values; // one store, VecLen elements
}

pub fn withinRadius(pxs: []const f32, pys: []const f32, cx: f32, cy: f32, r: f32, out_mask: []bool) void {
    const cxv: Vf = @splat(cx);
    const cyv: Vf = @splat(cy);
    const r2v: Vf = @splat(r * r);
    var i: usize = 0;
    while (i + VecLen <= pxs.len) : (i += VecLen) {
        const dx = pxs[i..][0..VecLen].* - cxv;
        const dy = pys[i..][0..VecLen].* - cyv;
        const d2 = dx * dx + dy * dy;
        const mask = d2 <= r2v; // @Vector(N, bool)
        inline for (0..VecLen) |lane| out_mask[i + lane] = mask[lane];
    }
    while (i < pxs.len) : (i += 1) { // scalar tail for leftovers
        const dx = pxs[i] - cx;
        const dy = pys[i] - cy;
        out_mask[i] = dx * dx + dy * dy <= r * r;
    }
}

// SIMD AABB CHECK
// chebyshev-distance style check
pub fn withinBounds(
    pxs: []const f32,
    pys: []const f32,
    width_s: []const f32,
    height_s: []const f32,
    bounds_min_x: f32,
    bounds_min_y: f32,
    bounds_max_x: f32,
    bounds_max_y: f32,
    out_mask: []bool,
) void {
    const bounds_min_x_v: Vf = @splat(bounds_min_x);
    const bounds_min_y_v: Vf = @splat(bounds_min_y);
    const bounds_max_x_v: Vf = @splat(bounds_max_x);
    const bounds_max_y_v: Vf = @splat(bounds_max_y);
    const zero_v: Vf = @splat(0.0);

    var i: usize = 0;
    while (i + VecLen <= pxs.len) : (i += VecLen) {
        const gap_x = @max(
            pxs[i..][0..VecLen].* - bounds_max_x_v,
            bounds_min_x_v - pxs[i..][0..VecLen].* + width_s[i..][0..VecLen].*,
        );
        const gap_y = @max(
            pys[i..][0..VecLen].* - bounds_max_y_v,
            bounds_min_y_v - pys[i..][0..VecLen].* + height_s[i..][0..VecLen].*,
        );
        const d = @max(gap_x, gap_y);
        const mask = d <= zero_v; // @Vector(N, bool)
        inline for (0..VecLen) |lane| out_mask[i + lane] = mask[lane];
    }
    while (i < pxs.len) : (i += 1) {
        const gap_x = @max(pxs[i] - bounds_max_x, bounds_min_x - pxs[i] + width_s[i]);
        const gap_y = @max(pys[i] - bounds_max_y, bounds_min_y - pys[i] + height_s[i]);
        out_mask[i] = @max(gap_x, gap_y) <= 0.0;
    }
}
