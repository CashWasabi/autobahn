# Autobahn wiki

Autobahn runs one function on every core at once.
You write it top to bottom like a single-threaded function.
You say where the lanes wait for each other.
That is the whole idea:

```zig
fn entry(lane: *autobahn.Lane, s: *Shared) void {
    if (lane.lane_idx == 0) s.scale = 3; // One lane.
    lane.barrier.sync(.spin); // Everyone waits here.

    const r = lane.staticRange(s.items.len, null); // Every lane, its own share.
    for (s.items[r.start..r.end()]) |*x| x.* *= s.scale;
    lane.barrier.sync(.spin);
}
```

It reads like a procedure.
It runs on many threads by default.
There is no pool, no job object and no future.
The order of the work is the order of the code.

## Pages

Read them in order.
The first four are the library.
The rest build on them.

1. [Lanes and the entrypoint](1-lanes-and-the-entrypoint.md): one function, N copies running.
2. [Barriers](2-barriers.md): where lanes wait and what a barrier guarantees.
3. [Sharing work](3-sharing-work.md): the four ways to split work between barriers.
4. [The rules](4-the-rules.md): what keeps lanes from waiting for ever.
5. [Starting the lanes](5-starting-the-lanes.md): `run`, or by hand.
6. [Extras](6-extras.md): values between lanes, stopping early, groups.

## Examples

Each one checks its own results.
Run one with `zig build run_<name>`.
Add `-Doptimize=ReleaseFast` for timings.

| Example | Shows | Page |
| --- | --- | --- |
| [`hello`](../examples/hello.zig) | the entrypoint and one barrier | 1, 2 |
| [`phases`](../examples/phases.zig) | a frame loop, `.sleep` and `.spin`, stopping together | 2, 4 |
| [`even_split`](../examples/even_split.zig) | `staticRange` in a two-pass blur | 3 |
| [`uneven_split`](../examples/uneven_split.zig) | `forEachQueued` against `staticRange` | 3 |
| [`tasks`](../examples/tasks.zig) | `forEachTask` and an error every lane sees | 3 |
| [`demo`](../examples/demo.zig) | every way of sharing work in one frame | 3 |
| [`search`](../examples/search.zig) | `cancel` and `fail` | 6 |
| [`groups`](../examples/groups.zig) | a `Group` loading while the others run frames | 6 |
| [`simd`](../examples/simd.zig) | SIMD in each lane's share, with `reduce` and `scan` | 6 |
| [`bench`](../examples/bench.zig) | what a barrier and the queue cost | |

## Is it for you?

Lanes suit one program doing one thing at a time on all its cores.
A game frame, a simulation step, an image, a batch of data.
The work comes in phases, and every core helps with each phase.

Lanes do not suit waiting on I/O.
One blocked lane holds up the rest.
They do not suit work that makes more work as it goes.
There is no stealing between lanes.
They do not suit many small unrelated jobs.
That is a thread pool's job.
And never run more lanes than cores.
