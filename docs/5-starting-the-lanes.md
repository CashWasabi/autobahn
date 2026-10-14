# 5. Starting the lanes

## With `run`

```zig
const lane_count: u8 = @intCast(@min(try autobahn.getCpuCount(), 8));
try autobahn.run(lane_count, entry, .{ io, &shared });
```

`run` starts lanes 1 and up on threads.
It runs lane 0 on the calling thread.
It returns once every lane has returned from `entry`.
`entry` is `fn (lane: *Lane, ...args) void`.
The arguments in the tuple follow the lane.
The barrier, the queue and the lanes live on `run`'s stack.
Nothing is allocated.

If a thread cannot start, no lane runs `entry` and `run` returns the error.
`run` holds the lanes at a gate until every thread is up.
So a failed start never leaves lanes waiting for a lane that never came.

`run` starts up to `max_lanes` (64) lanes.

### How many lanes

`getCpuCount()` is the number of cores the OS offers.
Use it or fewer, never more.
A spinning lane would wait for one that is not running, and every barrier pays for it.

Cap the count at what the work can use.
A phase of 1000 items gains little from 32 lanes.
`staticRange`'s `min_per_lane` can leave lanes idle for one phase without changing the lane count.

## By hand

Set the lanes up yourself to keep them for the whole program.
Or do it to keep the calling thread free.
You need a `Barrier`, a `WorkQueue` and one `Lane` per lane.

```zig
var barrier: autobahn.Barrier = .init(4);
var queue: autobahn.WorkQueue = .empty;
var lanes: [4]autobahn.Lane = undefined;
for (&lanes, 0..) |*lane, i| lane.* = .init(&barrier, &queue, @intCast(i));

var threads: [3]std.Thread = undefined;
for (&threads, lanes[1..]) |*thread, *lane| thread.* = try std.Thread.spawn(.{}, entry, .{ lane, io, &shared });
entry(&lanes[0], io, &shared);
for (threads) |thread| thread.join();
```

`Lane.init` takes the lane count from the barrier.

A thread that fails to start leaves the running lanes waiting at their first barrier.
`run`'s gate prevents that.
A hand-made set-up must do the same, or treat a failed start as fatal.

Each lane needs the same `Lane` for its whole life.
The `Lane` counts the queue calls it has made.
That count must match the other lanes'.
Never make a fresh one halfway.

## Lanes for the whole program

A game or a server can start its lanes once and keep them.
The entrypoint is then the main loop:

```zig
fn entry(lane: *autobahn.Lane, io: std.Io, app: *App) void {
    while (true) {
        if (lane.lane_idx == 0) app.pollInput(); // Lane 0 alone talks to the OS.
        lane.barrier.sync(.{ .sleep = io }); // Idle lanes sleep.
        if (app.quit) return; // Every lane reads the same `quit`.
        update(lane, app); // Phases, barriers and the ways of sharing work.
        render(lane, app); // Their barriers keep lane 0 from writing `quit` too early.
    }
}
```

Use `.sleep` at the barrier where the program waits on the outside world.
Input, vsync or a timer.
Idle cores then cost nothing.

## `Io`

Nothing in autobahn keeps an `Io`.
Only sleeping at a barrier needs it, and that call takes it: `.{ .sleep = io }`.
Pass `io` into the entrypoint with the other arguments.
