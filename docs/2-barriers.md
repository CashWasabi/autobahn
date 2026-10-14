# 2. Barriers

```zig
lane.barrier.sync(.spin);
lane.barrier.sync(.{ .sleep = io });
```

A lane that calls `sync` waits until all `lane_count` lanes have called it.
Then all go on.
With one lane it returns at once.

## What a barrier guarantees

**What any lane wrote before the barrier, every lane can read after it.**

That is the whole contract.
It is what makes the code readable as a procedure.
The code between two barriers is a **phase**.
Within a phase one rule is enough:

> In a phase, each piece of data is either read by any lanes and written by none, or touched by one lane only.

Break it and two lanes race on the same memory.
Keep it, and each phase is as simple as single-threaded code.
Nothing changes under a lane until the next barrier.

```zig
if (lane.lane_idx == 0) s.scale = 3; // Phase 1: only lane 0 touches `scale`.
lane.barrier.sync(.spin);
const r = lane.staticRange(n, null); // Phase 2: every lane reads `scale`. Nobody writes it.
for (s.items[r.start..r.end()]) |*x| x.* *= s.scale; // Each lane writes only its own items.
lane.barrier.sync(.spin);
```

No barrier is needed for:

- Data set up before `run`.
  Starting a thread makes it visible.
- Data read after `run` returns.
  `run` joins every thread first.
- Data only this lane touches.
  Its locals, or its own share.

## How many barriers: the overwrite race

One barrier lets readers see a write.
A second barrier must come before the next write to the same data.
Without it, the writer runs ahead and overwrites the value while a slow lane still reads it.

```zig
while (true) {
    if (lane.lane_idx == 0) s.stop = decide();
    lane.barrier.sync(.spin);
    if (s.stop) break;
    // No barrier here.
    // Lane 0 loops round and writes `s.stop` again.
    // Lane 3 may not have read the old value yet.
}
```

```
lane 0   write ─ X ─ read ─ write!  ─ X ─
lane 3   ─────── X ──────────── read ─ X      <- reads the new value, not the one it waited for
```

The fix is any barrier between a lane's read and the next write.
Real loops usually have one already, such as the next frame's work.
In [`examples/phases.zig`](../examples/phases.zig) two barriers come between, and a comment says so.
When there is none, add one.
Or use `broadcast` ([Extras](6-extras.md)).
It keeps two copies and needs only one barrier.

The rule: **between two writes of the same data, every lane must pass a barrier after its last read.**

## `.spin` or `.sleep`

| Wait | While waiting | Back after the last lane arrives | For |
| --- | --- | --- | --- |
| `.spin` | burns its core | in about 350 ns | short waits between parallel phases |
| `.{ .sleep = io }` | sleeps on a futex | in about 11 to 12 us | long waits and idle programs |

Choose by how long the lanes wait, not by how long the work takes:

- Every lane works and they finish about together: `.spin`.
- Lane 0 runs a long serial job while the others have nothing: `.sleep`.
  Otherwise N-1 cores burn for nothing.
- The program idles between frames: `.sleep`.

**At one barrier every lane waits the same way.**
A spinning lane does not wake sleepers.
If the last lane to arrive spins, the sleepers sleep for ever.
A debug build asserts this.
Different barriers may wait in different ways.

## Barriers you do not write

These calls contain a barrier.
For [the rules](4-the-rules.md) they count like any other.
Every lane must reach them.

| Call | Waits |
| --- | --- |
| `forEachQueued(..., .{ .wait = w })` | when `next` returns null, or at `finish` or `result` |
| `forEachTask(..., w)` | after every task has run |
| `broadcast`, `reduce`, `scan` | once each |

`staticRange`, `forEachQueued(..., .no_wait)` and `forEachTaskNoWait` contain none.
Put a barrier after them before anything reads what they wrote.

## How it works

A `Barrier` is 20 bytes.
It holds a count of arrived lanes and a generation number.
Each lane notes the generation and adds itself to the count.
The last lane resets the count and bumps the generation.
The others wait for the generation to change, by spinning or on a futex.
Nothing is allocated.
The barrier can be reused at once.
