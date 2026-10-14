# 1. Lanes and the entrypoint

A program has N **lanes**.
A lane is a thread plus a `Lane` value.
The `Lane` says which lane it is: `lane_idx`, from 0 to `lane_count - 1`.
It also points to what the lanes share: a barrier and a queue.

Every lane runs the same function, the **entrypoint**:

```zig
fn entry(lane: *autobahn.Lane, s: *Shared) void { ... }

try autobahn.run(4, entry, .{&shared}); // 4 lanes. Each runs entry(lane, &shared).
```

There is one copy of the code.
N copies run it at once, each at its own pace.

## Reading it

Read the entrypoint as one lane would, top to bottom.
At each line ask two questions:

1. **Which lanes run this line?**
   All of them, unless it sits in a branch on `lane.lane_idx`.
2. **What does it touch?**
   Its own data, its own share of shared data, or data every lane only reads.

Almost every line is one of three kinds:

| Kind | Looks like | Every lane |
| --- | --- | --- |
| Its own data | `var sum: u64 = 0;` | runs it on its own copy |
| Its own share | `lane.staticRange(n, null)` and a loop | does its part of one job |
| One lane | `if (lane.lane_idx == 0) { ... }` | skips it, except lane 0 |

Between them are **barriers**.
At `lane.barrier.sync(...)` every lane waits until all have arrived.
The code between two barriers is a **phase**.
See [Barriers](2-barriers.md).

From [`examples/hello.zig`](../examples/hello.zig):

```zig
fn entry(lane: *autobahn.Lane, arrived: *[max_lanes]bool) void {
    arrived[lane.lane_idx] = true; // Every lane writes its own slot.
    lane.barrier.sync(.spin); // Wait for all.
    if (lane.lane_idx == 0) { // One lane. Every slot is written now.
        for (arrived[0..lane.lane_count]) |a| std.debug.assert(a);
    }
}
```

## What is whose

- **Locals belong to one lane.**
  Each lane is a thread with its own stack.
  `var sum` in the entrypoint is N separate variables.
- **Shared state comes in through the arguments.**
  A pointer passed to `run` is the same on every lane.
  Lanes put there what other lanes read: inputs, outputs, decisions.
- **Each lane has its own `Lane`.**
  The `Barrier` and `WorkQueue` it points to are shared.

## Seeing it run

Four lanes run the snippet from the [wiki home](README.md):

```
          phase 1               barrier   phase 2                    barrier
lane 0  | s.scale = 3 |---------|  X  |   items[0   .. 250]  |-------|  X  |
lane 1  |  (skip)     |.........|  X  |   items[250 .. 500]  |-------|  X  |
lane 2  |  (skip)     |.........|  X  |   items[500 .. 750]  |-------|  X  |
lane 3  |  (skip)     |.........|  X  |   items[750 ..1000]  |-------|  X  |
                         ^ waiting
```

Lanes 1 to 3 reach the first barrier at once.
They wait there for lane 0.
Then all four start phase 2 together, each on its own quarter.
Nobody reads `s.scale` before it is written.
The barrier sits in between.

## Why this shape

A thread pool cuts the program into jobs.
You hand them off and wait on handles.
The order of the work then lives in the scheduler.

With lanes the program stays one procedure.
"This, then that in parallel" is written as "this, barrier, that".
You can read a frame top to bottom and know what has happened at each line.
Every core helps with every phase.

The price: every lane walks the same path.
You cannot run unrelated things at unrelated times.
[The rules](4-the-rules.md) are about this.
