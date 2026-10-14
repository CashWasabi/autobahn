# Changelog

## [Unreleased]

## [0.6.0] - 2026-10-14

First public release.

### Added

- `run` starts N lanes that all run the same entrypoint.
  Lane 0 runs on the calling thread.
  If a thread cannot start, no lane runs and `run` returns the error.
- `Barrier.sync` waits with `.spin` or `.{ .sleep = io }`.
- `Barrier.init`, `Lane.init` and `WorkQueue.empty` set up lanes by hand.
- `Lane.staticRange` splits work evenly.
- `Lane.forEachQueued` splits work unevenly through a shared counter.
  It ends with `.wait` or `.no_wait`.
- `Lane.forEachTask` and `Lane.forEachTaskNoWait` run different jobs.
  A task's error is returned on every lane.
- `RangeIter.finish` ends a loop that a lane leaves early.
- `RangeIter.cancel` stops every lane taking work.
- `RangeIter.fail` and `RangeIter.result` return an error on every lane.
- `Lane.broadcast`, `Lane.reduce` and `Lane.scan` hand values between lanes at a barrier.
  Every lane gets the same result, bit for bit.
- `Group` gives some of the lanes their own barrier and queue.
- Debug checks catch mixed `.spin` and `.sleep` at one barrier.
  They catch a `forEachQueued` loop left without its null or `finish`.
  They catch `fail` with `.no_wait`, and a fresh copy of a group's `Lane`.
- A wiki in `docs/`.
- Nine examples in `examples/`.
- `zig build bench`.

[Unreleased]: https://github.com/CashWasabi/autobahn/compare/0.6.0...HEAD
[0.6.0]: https://github.com/CashWasabi/autobahn/releases/tag/0.6.0
