# 3. Sharing work

Between two barriers the lanes share the work in one of four ways.
Each way is a call you make from the entrypoint.
There are no job objects and no scheduler.

| Way | Call | For |
| --- | --- | --- |
| Lane 0 alone | `if (lane.lane_idx == 0) ...` then a barrier | set-up and serial work |
| An even split | `lane.staticRange(item_count, min_per_lane)` | items of equal cost |
| An uneven split | `lane.forEachQueued(item_count, batch_len, end)` | items of uneven cost |
| Different jobs | `lane.forEachTask(.{ .{ f, .{args} }, ... }, wait)` | independent functions |

## Lane 0 alone

```zig
if (lane.lane_idx == 0) {
    s.step += 1;
    rebuildIndex(s);
}
lane.barrier.sync(.{ .sleep = io }); // Long work: the others sleep.
```

Use it for work that cannot be split, or is too small to split.
The others wait at the barrier.
Choose the wait by the length of the serial work ([Barriers](2-barriers.md)).
Any lane would do.
Lane 0 always exists, so it is the habit.

## The even split: `staticRange`

```zig
const r = lane.staticRange(s.items.len, 1024);
for (s.items[r.start..r.end()]) |*x| x.* = f(x.*);
lane.barrier.sync(.spin); // staticRange does not wait.
```

Each lane works out its own share from its index.
There is no shared counter and nothing to wait for.
The shares are in order and cover every item once.
They differ by at most one item.

`min_per_lane` keeps lanes from getting crumbs.
With 2500 items and a minimum of 1024, two lanes get a share.
The rest get an empty range.
With `null` every lane gets a share.
Every lane can run the same loop either way.
An empty range is a loop that does nothing.

`staticRange` does not wait.
Put a barrier after it before anything reads the results.
See the two-pass blur in [`examples/even_split.zig`](../examples/even_split.zig).
Its second pass reads rows that other lanes wrote in the first.

Use it when items cost about the same.
It is the cheapest split.

## The uneven split: `forEachQueued`

```zig
var it = lane.forEachQueued(height, 4, .{ .wait = .spin });
while (it.next()) |batch| {
    for (batch.start..batch.end()) |y| renderRow(y);
}
// With `.wait`, every lane's work is done here.
```

Lanes take batches of `batch_len` items from a shared counter.
Whichever lane asks next gets the next batch.
A lane with cheap items comes back for more while another is still busy.
So all lanes finish at about the same time.

In [`examples/uneven_split.zig`](../examples/uneven_split.zig) the middle rows of a Mandelbrot image cost the most.
The queue is about twice as fast as `staticRange` there.
`staticRange` leaves one lane with all the costly rows.

**Batch length.**
Every batch is one trip to the shared counter.
A trip costs about 100 ns with four lanes.
Small batches balance best but cost the most trips.
Big batches cost few trips but balance worse.
Make each batch cost far more than 100 ns.
For cheap items that means thousands.
For costly items, such as a row of pixels, 1 to a few.
`null` takes the queue's default of 512.

**The end.**
`end` says what a lane does when the items run out:

| `end` | The lane | After the loop |
| --- | --- | --- |
| `.{ .wait = .spin }` or `.{ .wait = .{ .sleep = io } }` | waits for every lane | all work is done |
| `.no_wait` | goes straight on | others may still work |

With `.no_wait` a lane out of work goes on to the next `forEachQueued` or `forEachTask`.
It takes work there instead of standing idle at a barrier:

```zig
var a = lane.forEachQueued(n, 512, .no_wait);
while (a.next()) |b| stepA(b);
var c = lane.forEachQueued(m, 512, .no_wait); // A lane done with A starts on C at once.
while (c.next()) |b| stepC(b);
lane.barrier.sync(.spin); // Both are done.
```

This is only correct if C does not read what A writes.
A lane can get `queue_slot_count` (2) calls ahead of the slowest lane.
Past that it spins until the slowest catches up.

**Every lane calls `next` until it returns null.**
A loop a lane can leave early needs `defer it.finish();`.
See [the rules](4-the-rules.md).

## Different jobs: `forEachTask`

```zig
try lane.forEachTask(.{
    .{ physics, .{world} },
    .{ audio, .{ world, mixer } },
    .{ think, .{world} },
}, .spin);
```

The argument is a tuple of `.{ function, .{ arguments } }`.
Each task runs once, on whichever lane is free.
With three tasks and eight lanes, five lanes find nothing to do.
They go straight to the closing barrier.
The tasks run in parallel.
So one task must not write what another reads.

**Errors.**
A task may return an error.
The other tasks still run.
Then every lane returns the same error.
So `try` or `catch` takes every lane the same way.
See [`examples/tasks.zig`](../examples/tasks.zig).
Of two errors, every lane gets the same one.

`forEachTaskNoWait` is the same without the closing barrier.
A lane with no task left goes on.
Without a barrier no lane can learn of an error.
So its tasks cannot return one.
That is a compile error.

**Jobs known only at run time.**
The tuple is fixed at compile time.
For a list made while running, use the queue with batches of one:

```zig
var it = lane.forEachQueued(jobs.len, 1, .{ .wait = .spin });
while (it.next()) |j| jobs[j.start].run();
```

## Choosing one

- One lane can do it, or it is too small to split: **lane 0 alone**.
- Many items of about equal cost: **`staticRange`**.
- Many items of uneven or unknown cost: **`forEachQueued`**.
  Make each batch worth well over 100 ns.
- A few different functions: **`forEachTask`**.

[`examples/demo.zig`](../examples/demo.zig) runs all four in one frame.
The README's first example is a short version of it.
