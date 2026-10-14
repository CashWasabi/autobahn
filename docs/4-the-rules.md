# 4. The rules

Break a rule and the lanes wait for each other for ever.
With `.spin`, every core but one sits at 100% and nothing moves.
With `.sleep`, the program just stops.
Either way, look here first.

All rules come down to one: **every lane walks the same path through the barriers.**

## 1. Every lane reaches every barrier the same number of times

```zig
// Wrong: lanes 1 and up never reach this barrier.
if (lane.lane_idx == 0) {
    load(s);
    lane.barrier.sync(.spin);
}

// Right: the work goes in the branch. The barrier stays outside.
if (lane.lane_idx == 0) load(s);
lane.barrier.sync(.spin);
```

Remember the barriers you do not write ([Barriers](2-barriers.md)).
A `forEachTask` inside `if (lane.lane_idx == 0)` breaks this rule too.

## 2. Every lane decides the path the same way

Loop counts, branches and early returns lead past barriers.
Every lane must decide them alike.

```zig
// Wrong: each lane reads the clock at its own moment. They may disagree.
while (timer.read() < budget) {
    work(lane);
    lane.barrier.sync(.spin);
}

// Right: one lane decides. Every lane reads that decision after a barrier.
while (true) {
    if (lane.lane_idx == 0) s.go_on = timer.read() < budget;
    lane.barrier.sync(.spin);
    if (!s.go_on) break;
    work(lane);
    lane.barrier.sync(.spin); // Also keeps lane 0 from writing `go_on` while others read it.
}
```

Safe to decide on:

- constants,
- values every lane computes the same way from the same input, such as `frame < 10`,
- anything one lane wrote before a barrier.

Not safe:

- clocks,
- atomics that other threads change,
- anything random,
- per-lane results, such as "did my share find it?".

For those, use `broadcast` or `reduce` ([Extras](6-extras.md)).
They give every lane the same value in one call.

## 3. At one barrier every lane waits the same way

All `.spin`, or all `.{ .sleep = io }`.
A spinning lane that arrives last does not wake the sleepers.
A debug build asserts this.
Make the wait a constant at each call.
Never compute it per lane.

## 4. Every lane calls a `forEachQueued`'s `next` until it returns null

The null is where the loop waits, with `.wait`.
It is also where the lane gives up its slot in the queue.
A lane that leaves early does neither.
With `.wait` the others wait for it at the closing barrier.
With `.no_wait` they wait `queue_slot_count` (2) calls later, when the slot comes round again.

```zig
var it = lane.forEachQueued(n, null, .no_wait);
defer it.finish(); // A `break`, `return` or `try` below still ends this lane's part.
while (it.next()) |r| try work(r);
```

`finish` ends the lane's part of the loop as the null would.
The other lanes finish the rest.
If a lane forgets, a debug build panics at its next `forEachQueued` or `forEachTask`.

Mind the error here.
It leaves on one lane only, which breaks rule 2.
For an error every lane sees, use `fail` and `result` ([Extras](6-extras.md)).

## 5. Some arguments must be the same on every lane

- `staticRange`: `item_count` and `min_per_lane`.
  Otherwise the shares do not fit together.
- `forEachQueued`: `item_count`, `batch_len` and the kind of `end`.
- `forEachTask`: the same tuple.
- `broadcast`, `reduce`, `scan`: the same `T` and `op`.

## Debug checks

A Debug or ReleaseSafe build catches some mistakes where they happen.
You get a panic instead of a hang:

| Mistake | Caught by |
| --- | --- |
| `.spin` and `.sleep` at one barrier | an assert, when a spinning lane arrives last |
| a `forEachQueued` loop left without the null or `finish` | a panic at that lane's next queue call |
| `fail` with `.no_wait` | a panic |
| a fresh copy of a group's `Lane` | a panic at its first queue call, once the group has made one |

## Finding a hang

1. Attach a debugger and look at each thread.
   Most lanes sit in `Barrier.sync` or `enterSlot`.
   One lane is somewhere else.
   That lane took another path.
2. Find the branch it took.
   Look for a decision that one lane did not make before a barrier.
3. Look for a barrier inside a branch on `lane_idx`.
   Look for one behind an early `return`.
   Calls that contain a barrier count too.
