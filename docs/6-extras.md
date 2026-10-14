# 6. Extras

Everything here is built from the barrier and the queue.
You could do all of it by hand.
These calls make the common cases one line.
They also get the subtle parts right.

## Handing values between lanes

At a barrier each lane hands in one value.
It gets back something made of all values.
`T` fits in 8 bytes.

| Call | Every lane gets | For |
| --- | --- | --- |
| `lane.broadcast(T, value, wait)` | lane 0's `value` | a decision in one call |
| `lane.reduce(T, value, op, wait)` | all values combined | a sum, a count, the best result |
| `lane.scan(T, value, op, wait)` | `.before` and `.total` | where each lane writes its output |

`op` is a `std.lang.ReduceOp`: `.Add`, `.Mul`, `.Min`, `.Max`, `.And`, `.Or` or `.Xor`.
`reduce` also takes a `fn (T, T) T`.
Each call is one barrier.
Every lane must call it ([the rules](4-the-rules.md)).

**Every lane gets the same result, bit for bit.**
Every lane combines the values in lane order.
That holds even for floats, where order changes the result.
So these values are safe to branch on (rule 2).

### `broadcast`: a decision in one call

```zig
// By hand: a field, a barrier, and another barrier before the next write.
if (lane.lane_idx == 0) s.quit = window.closed();
lane.barrier.sync(.spin);
if (s.quit) return;

// With broadcast: no field. Safe to call again at once.
if (lane.broadcast(bool, lane.lane_idx == 0 and window.closed(), .spin)) return;
```

Only lane 0's value is read.
The others may pass anything.

### `reduce`: one answer from every lane

```zig
var hits: u32 = 0;
for (s.items[r.start..r.end()]) |x| hits += @intFromBool(x.hit);
const total = lane.reduce(u32, hits, .Add, .spin); // The same total on every lane.

// The best of all lanes, with a combine function of your own.
const Best = extern struct { score: f32, index: u32 };
const best = lane.reduce(Best, my_best, pickBest, .spin);
```

### `scan`: a parallel filter

Each lane counts what it keeps of its share.
`scan` with `.Add` returns two numbers.
`before` is where this lane's part starts.
`total` is the length of the whole output.
Every lane then writes its part.
No lock and no atomic counter are needed:

```zig
const r = lane.staticRange(items.len, null);
var kept: usize = 0;
for (items[r.start..r.end()]) |x| kept += @intFromBool(keep(x));
const at = lane.scan(usize, kept, .Add, .spin);
var pos = at.before;
for (items[r.start..r.end()]) |x| {
    if (!keep(x)) continue;
    out[pos] = x;
    pos += 1;
}
lane.barrier.sync(.spin); // Every part is written: out[0..at.total].
```

The output keeps the input's order.
See [`examples/simd.zig`](../examples/simd.zig).

These calls work for up to `max_lanes` (64) lanes.
The values live in the `WorkQueue` in two sets.
So each call needs only one barrier.

## Stopping early

From [`examples/search.zig`](../examples/search.zig).

**`cancel`** makes every lane's next `next` return null.
Use it for a search that has found its target:

```zig
var it = lane.forEachQueued(items.len, 4096, .{ .wait = .spin });
while (it.next()) |b| {
    if (find(items[b.start..b.end()])) |i| {
        s.found.store(b.start + i, .monotonic);
        it.cancel(); // Lanes finish the batches they hold and take no more.
    }
}
```

It costs nothing until someone cancels.
It just moves the shared counter past the end.

**`fail` and `result`** give an error that every lane takes alike.
A `try` inside the loop leaves on one lane only ([the rules](4-the-rules.md), rule 4).
Instead, note the error.
Every lane returns it after the closing barrier:

```zig
var it = lane.forEachQueued(item_count, null, .{ .wait = .spin });
while (it.next()) |r| work(r) catch |err| it.fail(err); // Also cancels.
try it.result(); // The same error on every lane.
```

`fail` needs `.wait`.
With `.no_wait` no lane waits to hear of the error.
A debug build panics.
Of two errors, every lane gets the same one.

## Groups

A `Group` is some of the lanes with their own barrier and queue.
Lanes in different groups do not wait for each other.
So one group can work on something long while another keeps running frames.

```zig
// In main, before the lanes start:
//     var s: Shared = .{ .loader = .init(0, 1), .frames = .init(1, lane_count - 1) };

fn entry(lane: *autobahn.Lane, io: std.Io, s: *Shared) void {
    var loader = s.loader.lane(lane); // This lane's Lane in the group, or null.
    var frames = s.frames.lane(lane);
    if (loader) |*sub| {
        load(sub, s);
    } else if (frames) |*sub| {
        while (!sub.broadcast(bool, sub.lane_idx == 0 and s.loaded.load(.acquire), .spin)) frame(sub, s);
    }
    lane.barrier.sync(.{ .sleep = io }); // Every lane, back together.
}
```

- `Group.init(first, count)` covers the parent's lanes `first .. first + count`.
  Inside the group they count from 0.
- `sub` is a lane like any other.
  Barriers, the ways of sharing work and the extras all work among the group's lanes.
- The rules hold inside each group.
  The parent's barrier waits for every lane.
  So a group's lanes stay off it until the group is done.
- **Take a group's `Lane` once and keep it.**
  Every `Lane` counts its queue calls.
  A fresh copy has lost count, and a debug build panics.
- A group can be split again.

See [`examples/groups.zig`](../examples/groups.zig).
