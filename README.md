# Autobahn

```
  o----------------o
  |                |
  |      /||\      |
  |     /_||_\     |
  | =m==========m= |
  |   /   ||   \   |
  |  /____||____\  |
  |                |
  o----------------o
```

Autobahn is an opinionated approach to threading.
Every thread runs the same function, and barriers keep the threads in step.
It is partly inspired by ideas from Casey Muratori and Ryan Fleury.

Zig 0.17.
`std` only.
One file.

Every lane runs this function.
Between barriers the lanes share the work in one of four ways.
It is a short version of [`examples/demo.zig`](examples/demo.zig).

```zig
const std = @import("std");
const autobahn = @import("autobahn");

fn frame(lane: *autobahn.Lane, io: std.Io, s: *Shared) void {
    // 1. Lane 0 alone while the others sleep. For long serial work.
    if (lane.lane_idx == 0) @memset(s.scaled, 0);
    lane.barrier.sync(.{ .sleep = io });

    // 2. Lane 0 alone while the others spin. For short serial work.
    if (lane.lane_idx == 0) s.scale = 3;
    lane.barrier.sync(.spin);

    // 3. An even split. Each lane works out its own share.
    const r = lane.staticRange(s.scaled.len, 1024);
    for (s.scaled[r.start..r.end()], r.start..) |*out, i| out.* = @as(u32, @intCast(i)) *% s.scale;
    lane.barrier.sync(.spin); // staticRange does not wait.

    // 4. An uneven split. Lanes take batches from a shared counter.
    //    With `.no_wait` a lane out of batches goes straight on to step 5.
    var it = lane.forEachQueued(s.uneven.len, 4096, .no_wait);
    while (it.next()) |b| {
        for (s.uneven[b.start..b.end()], b.start..) |*out, i| out.* = costly(i);
    }

    // 5. Different jobs. Whichever lane is free takes the next one.
    //    The wait at the end covers step 4 too.
    lane.forEachTask(.{
        .{ fillSquares, .{s.squares} },
        .{ fillMarker, .{ s.marker, 7 } },
    }, .spin) catch |err| @panic(@errorName(err));
}
```

New to lanes?
The [wiki](docs/README.md) explains the model page by page.
It has an example for each idea.

## The model

There is no pool and no job object.
A program has N lanes.
Each lane walks the same code.
Where the code says `sync`, the lanes wait for each other.
Between two barriers they share the work:

| Way | Call | For |
| --- | --- | --- |
| Lane 0 alone | `if (lane.lane_idx == 0) ...` then a barrier | set-up and serial work |
| An even split | `lane.staticRange(item_count, min_per_lane)` | items of equal cost |
| An uneven split | `lane.forEachQueued(item_count, batch_len, end)` | items of uneven cost |
| Different jobs | `lane.forEachTask(.{ .{ f, .{args} }, ... }, wait)` | independent functions |
| Different jobs, no wait | `lane.forEachTaskNoWait(.{ .{ f, .{args} }, ... })` | tasks that cannot fail |
| Jobs known at run time | `lane.forEachQueued(jobs.len, 1, end)` | a list made while running |

`end` is `.{ .wait = .spin }`, `.{ .wait = .{ .sleep = io } }` or `.no_wait`.
With `.no_wait` a lane out of work goes on at once.
It takes work from the next `forEachQueued` or `forEachTask` while the others finish.
It waits only when it is `queue_slot_count` (2) calls ahead of the slowest lane.

A barrier waits in one of two ways:

| Call | While waiting | For |
| --- | --- | --- |
| `lane.barrier.sync(.spin)` | burns the core and is back at once | short waits |
| `lane.barrier.sync(.{ .sleep = io })` | costs nothing and needs a wake-up | lane 0 alone for long, an idle program |

At a barrier the lanes can also hand each other a value.
`T` fits in 8 bytes.
It works for up to `max_lanes` (64) lanes.

| Call | Every lane gets | For |
| --- | --- | --- |
| `lane.broadcast(T, value, wait)` | lane 0's `value` | a decision in one call |
| `lane.reduce(T, value, op, wait)` | all values combined | a sum, a count, the best result |
| `lane.scan(T, value, op, wait)` | `.before` and `.total` | where each lane writes its output |

`op` is a `std.lang.ReduceOp`, such as `.Add` or `.Max`.
`reduce` also takes a `fn (T, T) T`.
Every lane combines the values in lane order.
So every lane gets the same result, even for floats.
That makes the result safe to branch on.

A parallel filter with `scan`:

```zig
const r = lane.staticRange(items.len, null);
var kept: usize = 0;
for (items[r.start..r.end()]) |x| kept += @intFromBool(keep(x));
const at = lane.scan(usize, kept, .Add, .spin); // at.before: where this lane writes. at.total: how many.
var pos = at.before;
for (items[r.start..r.end()]) |x| {
    if (!keep(x)) continue;
    out[pos] = x;
    pos += 1;
}
lane.barrier.sync(.spin); // Every lane wrote its part.
```

## Rules

Break one and the lanes wait for each other for ever.

- Every lane reaches every barrier the same number of times.
- Every lane takes the same path through the code.
  Lane 0 writes what decides it before a barrier.
  Every lane reads it after.
- At one barrier every lane waits the same way.
  All `.spin` or all `.sleep`.
  A debug build asserts it.
- `broadcast`, `reduce` and `scan` are barriers.
  Every lane calls them with the same `T` and `op`.
- Every lane calls a `forEachQueued`'s `next` until it returns null.
  A loop a lane may leave early ends with `defer it.finish();`.
  That lane stops taking and the others finish the rest.
  A debug build panics if a lane forgets.
- `forEachQueued` and `forEachTask` do not wait on entry.
  When the work runs out they wait as told.
  With `.no_wait` and `forEachTaskNoWait` they do not wait.
  Then put a barrier before reading what the work wrote.
- A `forEachTask` error is returned on every lane, after every task has run.
  So `try` takes every lane the same way.
  Tasks of `forEachTaskNoWait` cannot return errors.
- Inside a `Group` these rules hold for the group's lanes.
  The parent's barrier waits for every lane.

## Errors and stopping early

A `try` inside a `forEachQueued` loop leaves on one lane only.
The other lanes go on, and the lanes no longer take the same path.
For an error every lane sees, note it with `fail`.
Then every lane calls `result` after the loop:

```zig
var it = lane.forEachQueued(item_count, null, .{ .wait = .spin });
while (it.next()) |range| work(range) catch |err| it.fail(err);
try it.result(); // The same error on every lane.
```

`fail` also stops every lane taking work.
It needs `.wait`.

`cancel` stops every lane taking work without an error.
Use it for a search that has found its target:

```zig
var it = lane.forEachQueued(items.len, 256, .{ .wait = .spin });
while (it.next()) |range| {
    if (find(items[range.start..range.end()])) |i| {
        s.found.store(range.start + i, .monotonic);
        it.cancel();
    }
}
```

## Groups

A `Group` is some of the lanes with their own barrier and queue.
One group can load something slow while the rest keep running frames.

```zig
// In the shared state, made before the lanes start:
//   loader: autobahn.Group = .init(0, 1),              // lane 0
//   frames: autobahn.Group = .init(1, lane_count - 1), // lanes 1 and up
fn entry(lane: *autobahn.Lane, io: std.Io, s: *Shared) void {
    var loader = s.loader.lane(lane); // Null if this lane is not in the group.
    var frames = s.frames.lane(lane); // Take it once and keep it.
    if (loader) |*sub| {
        load(sub, s);
    } else if (frames) |*sub| {
        while (!sub.broadcast(bool, sub.lane_idx == 0 and s.loaded.load(.acquire), .spin)) frame(sub, s);
    }
    lane.barrier.sync(.{ .sleep = io }); // Every lane, back together.
}
```

A group's lanes count from 0.
A group can be split again.

## What it costs

Measured with `zig build bench`.
ReleaseFast, Ryzen 7 2700U, 4 lanes, 2026-10-11.

| What | Cost |
| --- | --- |
| A barrier, spinning | about 350 ns |
| A barrier, asleep | about 11 to 12 us |
| A `reduce`, spinning | a spinning barrier plus 0 to 150 ns |
| `Barrier` | 20 bytes |
| `WorkQueue` | 1664 bytes on x86-64 |
| `Lane` | 24 bytes |
| `Group` | 1792 bytes on x86-64 |

Nothing is allocated.
The `reduce` figure comes from a busy machine on 2026-10-14.

A million items of one add each, shared by 4 lanes.
One lane takes 512 us.

| Split | Time | Against one lane |
| --- | --- | --- |
| `staticRange` | 124 to 157 us | 3.3 to 4.5 times faster |
| `forEachQueued`, batches of 4096 | 134 to 155 us | about 3.7 times faster |
| `forEachQueued`, batches of 512 (default) | about 215 us | about 2.5 times faster |
| `forEachQueued`, batches of 64 | about 560 us | no faster |
| `forEachQueued`, batches of 16 | about 1800 us | 3 times slower |

Split cheap items evenly, or queue them in big batches.
A small batch pays off only when one item costs far more than a trip to the shared counter.
That trip costs about 100 ns with four lanes.

The queue's counter has a cache line to itself.
That is about a third faster at batches of 16.
It makes no difference at 64 or 512.
Measured in five interleaved runs.

## Install

```sh
zig fetch --save git+https://github.com/CashWasabi/autobahn#0.6.0
```

```zig
// build.zig
const autobahn = b.dependency("autobahn", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("autobahn", autobahn.module("autobahn"));
```

Needs Zig 0.17.
Tested on x86-64 Linux and x86 Linux.
Tested on ARM64 Linux under qemu and x86-64 Windows under wine.
It builds for macOS, FreeBSD, 32-bit ARM and RISC-V.
Emscripten is not supported yet.

## Build

```sh
zig build test       # 28 tests, on real threads
zig build run_demo   # examples/demo.zig: every way of sharing work
zig build bench      # examples/bench.zig: the numbers above
```

One small example per idea, in reading order.
Each checks its own results.

```sh
zig build run_hello          # the entrypoint and one barrier
zig build run_phases         # a frame loop with serial and parallel phases
zig build run_even_split     # staticRange: a two-pass blur
zig build run_uneven_split   # forEachQueued against staticRange
zig build run_tasks          # forEachTask and an error every lane sees
zig build run_search         # cancel and fail
zig build run_groups         # a Group loading while the others run frames
zig build run_simd           # SIMD in each lane's share, with reduce and scan
```

## Starting the lanes

### With `run`

```zig
try autobahn.run(4, frame, .{ io, &shared }); // Lane 0 is this thread.
```

`autobahn.run(lane_count, entry, args)` starts lanes 1 and up on threads.
It runs lane 0 on the calling thread.
It returns when every lane has returned.
`entry` is `fn (lane: *Lane, ...args) void`.
If a thread cannot start, no lane runs `entry` and `run` returns the error.

### By hand

Set the lanes up yourself to keep them for the whole program, or to keep the calling thread free.
You need a `Barrier`, a `WorkQueue` and one `Lane` per lane.

```zig
var barrier: autobahn.Barrier = .init(4);
var queue: autobahn.WorkQueue = .empty;
var lanes: [4]autobahn.Lane = undefined;
for (&lanes, 0..) |*lane, i| lane.* = .init(&barrier, &queue, @intCast(i));

var threads: [3]std.Thread = undefined;
for (&threads, lanes[1..]) |*thread, *lane| thread.* = try std.Thread.spawn(.{}, frame, .{ lane, io, &shared });
frame(&lanes[0], io, &shared);
for (threads) |thread| thread.join();
```

Here a thread that fails to start leaves the others waiting at their first barrier.
`run` avoids that with a gate.
A hand-made set-up has to do the same.

## When not to use it

Lanes suit one program doing one thing at a time on all its cores.
A frame, a simulation step, a batch.
They do not suit:

- **Waiting on I/O.**
  A blocked lane holds up every lane at the next barrier.
  Do I/O on its own thread or in a `Group`.
- **Work that makes more work.**
  Recursion and trees built top down need work stealing.
  Split the work into levels, or use a work-stealing pool.
- **Many small unrelated jobs.**
  There is no queue to post them to.
  That is a thread pool's job.
- **More lanes than cores.**
  A spinning lane then waits for one that is not running.
- **A lane that panics or never returns.**
  The others wait for it for ever.

## Versions

Autobahn follows [Semantic Versioning](https://semver.org/).
The changes are in [CHANGELOG.md](CHANGELOG.md).
The rules and the release steps are in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT.
See [LICENSE](LICENSE).
