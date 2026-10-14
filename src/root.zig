//! autobahn: lanes.
//! Every lane is a thread, and every lane runs the same function.
//!
//! There is no pool and no job object.
//! A program has N lanes.
//! Each lane walks the same code.
//! Where the code says `sync`, the lanes wait for each other.
//! Between two barriers they share the work:
//!
//!   lane 0 alone        `if (lane.lane_idx == 0) ...` then a barrier
//!   an even split       `staticRange`      each lane works out its own share
//!   an uneven split     `forEachQueued`    lanes take batches from a shared counter
//!   different jobs      `forEachTask`      whichever lane is free takes the next function
//!
//! At a barrier the lanes can also hand each other a value.
//! `broadcast` gives every lane lane 0's value.
//! `reduce` combines every lane's value.
//! `scan` gives each lane its offset in a shared output.
//! A `Group` gives some of the lanes their own barrier and queue for a while.
//!
//! The rules that keep lanes from waiting for ever:
//!   - Every lane reaches every barrier the same number of times.
//!   - Every lane takes the same path through the code.
//!     Lane 0 writes what decides it before a barrier.
//!     Every lane reads it after.
//!   - At one barrier every lane waits the same way.
//!     All `.spin` or all `.sleep`.
//!   - Every lane calls a `forEachQueued`'s `next` until it returns null, or calls `finish`.
//!   - Inside a `Group` these rules hold for the group's lanes.
//!
//! `forEachQueued` and `forEachTask` do not wait on entry.
//! At the end they wait for every lane.
//! With `.no_wait` and `forEachTaskNoWait` they do not.
//! Then a lane out of work goes on, and the caller puts a barrier before reading the results.
//!
//! Nothing is allocated.
//! Everything sits where the caller puts it.
//! Nothing keeps an `Io`.
//! The one call that sleeps takes it.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Atomic = std.atomic.Value;

/// How many lanes this machine can run at once.
pub fn getCpuCount() !u32 {
    // TODO: emscripten is not supported yet.
    // This branch is untested, and so is the rest of the library there.
    if (builtin.os.tag == .emscripten) {
        return @intCast(std.os.emscripten.emscripten_run_script_int("navigator.hardwareConcurrency"));
    }
    return @intCast(try std.Thread.getCpuCount());
}

/// Where the lanes wait for each other.
/// A lane that arrives waits until all `lane_count` lanes have arrived.
/// Then all go on.
/// With one lane it costs nothing.
pub const Barrier = struct {
    /// Lanes that have arrived at this barrier.
    arrived: Atomic(u32) = .init(0),
    /// Counts the times every lane has arrived.
    /// A waiting lane goes on when it changes.
    generation: Atomic(u32) = .init(0),
    /// What sleeping lanes sleep on (a futex word).
    phase: Atomic(u32) = .init(0),
    /// Lanes waiting with `.sleep`.
    /// For the check that no lane arrives with `.spin` while one sleeps.
    sleepers: Atomic(u32) = .init(0),
    lane_count: u8,

    pub fn init(lane_count: u8) Barrier {
        assert(lane_count >= 1);
        return .{ .lane_count = lane_count };
    }

    /// How a lane waits at a barrier.
    /// At one barrier every lane waits the same way.
    pub const Wait = union(enum) {
        /// Spin.
        /// The lane is back within nanoseconds of the last arrival, and burns its core meanwhile.
        /// For waits shorter than a wake-up, which takes a few microseconds.
        spin,
        /// Sleep.
        /// The lane costs nothing while it waits, and needs a wake-up to come back.
        /// For lane 0 working alone for long, or an idle program.
        sleep: std.Io,
    };

    /// Waits until every lane has arrived, the way `wait` says.
    pub fn sync(self: *Barrier, wait: Wait) void {
        if (self.lane_count == 1) return;
        const generation = self.generation.load(.acquire);
        switch (wait) {
            .spin => {
                if (self.arrived.fetchAdd(1, .acq_rel) + 1 == self.lane_count) {
                    // A lane sleeps at this barrier, and `.spin` wakes nobody.
                    assert(self.sleepers.load(.acquire) == 0);
                    self.arrived.store(0, .release);
                    self.generation.store(generation +% 1, .release);
                } else {
                    while (self.generation.load(.acquire) == generation) std.atomic.spinLoopHint();
                }
            },
            .sleep => |io| {
                _ = self.sleepers.fetchAdd(1, .acq_rel);
                if (self.arrived.fetchAdd(1, .acq_rel) + 1 == self.lane_count) {
                    self.arrived.store(0, .release);
                    self.generation.store(generation +% 1, .release);
                    _ = self.phase.fetchAdd(1, .release);
                    io.futexWake(u32, &self.phase.raw, self.lane_count - 1);
                } else {
                    while (self.generation.load(.acquire) == generation) {
                        const phase = self.phase.load(.acquire);
                        if (self.generation.load(.acquire) != generation) break;
                        io.futexWait(u32, &self.phase.raw, phase) catch {};
                    }
                }
                _ = self.sleepers.fetchSub(1, .acq_rel);
            },
        }
    }
};

/// Items `start .. start + len` of some array.
/// A lane's share of the work.
pub const Range = struct {
    start: usize,
    len: usize,

    pub fn end(range: Range) usize {
        return range.start + range.len;
    }
};

/// How many `forEachQueued` and `forEachTask` calls the lanes can be apart.
/// With `.no_wait`, a lane out of work in one call goes on to the next.
/// It waits there only if it is this many calls ahead of the slowest lane.
/// A power of two.
pub const queue_slot_count = 2;

/// The most lanes `run` starts.
/// Also the most lanes `broadcast`, `reduce` and `scan` work with.
/// A `Barrier` or a `Lane` alone allows up to 255.
pub const max_lanes = 64;

/// One word per lane, for `broadcast`, `reduce` and `scan`.
/// It holds any `T` of up to 8 bytes.
const Word = extern struct {
    raw: u64,

    comptime {
        assert(@sizeOf(Word) == 8 and @alignOf(Word) == @alignOf(u64));
    }

    fn get(word: *const Word, comptime T: type) T {
        return @as(*const T, @ptrCast(@alignCast(&word.raw))).*;
    }

    fn set(word: *Word, comptime T: type, value: T) void {
        word.* = .{ .raw = 0 }; // A `T` narrower than the word leaves no garbage behind.
        @as(*T, @ptrCast(@alignCast(&word.raw))).* = value;
    }
};

/// What the lanes share besides the barrier.
///
/// For `forEachQueued` and `forEachTask` it holds a counter per call.
/// Lanes take batches of work from it.
/// A lane with cheap items comes back for more while another is still busy.
/// The calls go round `queue_slot_count` slots.
/// The last lane to leave a call clears its slot for the call `queue_slot_count` later.
///
/// For `broadcast`, `reduce` and `scan` it holds a word per lane.
///
/// `.empty` is ready to use.
pub const WorkQueue = struct {
    slots: [queue_slot_count]Slot = initSlots(),
    /// A value per lane for `broadcast`, `reduce` and `scan`, in two sets.
    /// An exchange writes one set while slow lanes still read the other.
    /// The barrier's generation picks the set.
    /// It is the same on every lane between two barriers.
    /// The values are written before a barrier and read after it.
    /// The barrier orders them, so they need not be atomic.
    exchanged: [2][max_lanes]Word = undefined,
    /// The batch length `forEachQueued` uses when given none.
    /// Small batches meet at the counter often.
    /// Big batches may leave the last lane busy while the others have nothing.
    default_batch_len: usize = 512,

    pub const empty: WorkQueue = .{};

    /// An error as stored: its number, as wide as `anyerror`.
    const ErrorInt = @Int(.unsigned, @bitSizeOf(anyerror));

    const Slot = struct {
        /// The next item nobody has taken.
        /// Every `take` writes it, so it has a cache line to itself.
        /// The fields below are touched once per call and stay out of its way.
        next: Atomic(usize) align(std.atomic.cache_line) = .init(0),
        /// Lanes that are done with this call.
        left: Atomic(u32) align(std.atomic.cache_line) = .init(0),
        /// The call this slot is for.
        /// A lane that comes for a later call waits until the slot is cleared.
        call: Atomic(u32) = .init(0),
        /// An error from the work of this call.
        /// Of several errors, the last one noted stays.
        /// Every lane reads it after the closing barrier and before the slot is cleared.
        /// So every lane reads the same one.
        task_error: Atomic(ErrorInt) = .init(0),

        const empty: Slot = .{};

        /// The next batch of `item_count` items, or null when every item is taken.
        fn take(slot: *Slot, item_count: usize, batch_len: usize) ?Range {
            const start = slot.next.fetchAdd(batch_len, .monotonic);
            if (start >= item_count) return null;
            return .{ .start = start, .len = @min(batch_len, item_count - start) };
        }

        /// This lane is done with the slot.
        /// The last lane clears it for the call `queue_slot_count` later.
        fn leave(slot: *Slot, lane_count: u8) void {
            if (slot.left.fetchAdd(1, .acq_rel) + 1 < lane_count) return;
            slot.next.store(0, .monotonic);
            slot.left.store(0, .monotonic);
            slot.task_error.store(0, .monotonic);
            slot.call.store(slot.call.load(.monotonic) +% queue_slot_count, .release);
        }

        fn fail(slot: *Slot, err: anyerror) void {
            slot.task_error.store(@intFromError(err), .monotonic); // Read after a barrier.
        }

        fn failure(slot: *const Slot) ?anyerror {
            const seen = slot.task_error.load(.monotonic);
            return if (seen == 0) null else @errorFromInt(seen);
        }
    };

    fn initSlots() [queue_slot_count]Slot {
        comptime assert(std.math.isPowerOfTwo(queue_slot_count)); // So the call count may wrap.
        var slots: [queue_slot_count]Slot = undefined;
        for (&slots, 0..) |*slot, idx| slot.* = .{ .call = .init(@intCast(idx)) };
        return slots;
    }
};

/// What a lane does when a `forEachQueued` runs out of work.
pub const End = union(enum) {
    /// Wait for every lane, the way given.
    /// After it, all the work is done.
    wait: Barrier.Wait,
    /// Go on.
    /// Other lanes may still be at their last batch.
    /// The lane can go straight into the next `forEachQueued` or `forEachTask` and take work there.
    /// Put a barrier before reading what the work wrote.
    no_wait,
};

/// What `Lane.forEachQueued` returns: `while (it.next()) |range| ...`.
/// Every lane calls `next` until it returns null, or calls `finish`.
/// With `.wait`, the null has waited for every lane.
/// After it, all the work is done.
///
/// A loop that a lane may leave early ends with `defer it.finish();`.
/// That covers `break`, `return` and `try`:
///
///     var it = lane.forEachQueued(item_count, null, .no_wait);
///     defer it.finish();
///     while (it.next()) |range| try work(range);
///
/// That error stays on its lane.
/// For an error every lane sees, a lane notes it with `fail`.
/// Every lane then calls `result` after the loop.
/// This needs `.wait`:
///
///     var it = lane.forEachQueued(item_count, null, .{ .wait = .spin });
///     while (it.next()) |range| work(range) catch |err| it.fail(err);
///     try it.result();
pub const RangeIter = struct {
    lane: *Lane,
    slot: *WorkQueue.Slot,
    item_count: usize,
    batch_len: usize,
    end: End,
    done: bool = false,
    /// What `result` returns.
    /// An error a lane noted with `fail`, read after the closing barrier.
    failure: ?anyerror = null,

    pub fn next(self: *RangeIter) ?Range {
        if (self.done) return null;
        if (self.slot.take(self.item_count, self.batch_len)) |range| return range;
        self.finish();
        return null;
    }

    /// Ends this lane's part of the loop, as the null from `next` does.
    /// It waits as `end` says, and takes no more work.
    /// The other lanes finish what is left.
    /// After the null it does nothing.
    pub fn finish(self: *RangeIter) void {
        if (self.done) return;
        self.done = true;
        switch (self.end) {
            .wait => |wait| {
                self.lane.barrier.sync(wait); // Every lane is done taking.
                self.failure = self.slot.failure(); // Before the last lane out clears it.
            },
            .no_wait => {},
        }
        self.lane.leaveSlot(self.slot);
    }

    /// No lane takes any more work.
    /// Every lane's next `next` returns null.
    /// Lanes finish the batches they already hold.
    /// For a search that has found its target.
    pub fn cancel(self: *RangeIter) void {
        if (self.done) return; // Out of the slot, which may belong to another call by now.
        self.slot.next.store(self.item_count, .monotonic); // Every later take starts past the end.
    }

    /// Notes `err` for `result` to return on every lane, and cancels.
    /// Needs `.wait`, because with `.no_wait` no lane waits to hear of it.
    /// Of several errors, every lane gets the same one.
    pub fn fail(self: *RangeIter, err: anyerror) void {
        if (std.debug.runtime_safety and self.end == .no_wait) {
            @panic("RangeIter.fail needs `.wait`: with `.no_wait` no lane waits to hear of the error");
        }
        assert(!self.done); // A lane out of the loop has nothing left to fail.
        self.slot.fail(err);
        self.cancel();
    }

    /// Call it after the loop.
    /// It returns the error some lane noted with `fail`, the same on every lane.
    /// So `try` takes every lane the same way.
    /// It ends the loop first, as `finish` does, if it has not ended.
    pub fn result(self: *RangeIter) anyerror!void {
        self.finish();
        if (self.failure) |err| return err;
    }
};

/// A lane: which one it is, and what it shares with the others.
/// One per lane.
/// Every lane points at the same barrier and queue.
pub const Lane = struct {
    barrier: *Barrier,
    queue: *WorkQueue,
    lane_idx: u8,
    lane_count: u8,
    /// The `forEachQueued` and `forEachTask` calls this lane has made.
    /// The same on every lane.
    calls: u32 = 0,
    /// True between entering a call's slot and leaving it.
    /// For the check that a lane did not leave a `forEachQueued` loop without its null or `finish`.
    in_call: bool = false,

    /// Lane `lane_idx` of the lanes that share `barrier` and `queue`.
    /// The lane count comes from the barrier.
    pub fn init(barrier: *Barrier, queue: *WorkQueue, lane_idx: u8) Lane {
        assert(lane_idx < barrier.lane_count);
        return .{ .barrier = barrier, .queue = queue, .lane_idx = lane_idx, .lane_count = barrier.lane_count };
    }

    /// The uneven split.
    /// It hands out `item_count` items in batches of `batch_len` to whichever lane asks next.
    /// A null `batch_len` takes the queue's default.
    /// It does not wait on entry.
    /// When the items run out, it waits as `end` says.
    /// `item_count`, `batch_len` and the kind of `end` must be the same on every lane.
    pub fn forEachQueued(lane: *Lane, item_count: usize, batch_len: ?usize, end: End) RangeIter {
        const len = batch_len orelse lane.queue.default_batch_len;
        assert(len > 0);
        return .{ .lane = lane, .slot = lane.enterSlot(), .item_count = item_count, .batch_len = len, .end = end };
    }

    /// The even split.
    /// It returns this lane's share of `item_count` items, worked out from its index alone.
    /// The shares are in order and cover every item once.
    /// They differ by at most one item.
    /// With `min_per_lane`, only lanes that can get that many items get a share.
    /// The rest get an empty range.
    /// `item_count` and `min_per_lane` must be the same on every lane.
    /// It does not wait, so put a barrier after the work.
    pub fn staticRange(lane: *const Lane, item_count: usize, min_per_lane: ?usize) Range {
        assert(lane.lane_idx < lane.lane_count);
        const lanes: usize = if (min_per_lane) |min| blk: {
            assert(min > 0);
            break :blk std.math.clamp(item_count / min, 1, lane.lane_count);
        } else lane.lane_count;
        if (lane.lane_idx >= lanes) return .{ .start = 0, .len = 0 };

        const share = item_count / lanes;
        const leftover = item_count % lanes; // The first `leftover` lanes take one more.
        const extra = @intFromBool(lane.lane_idx < leftover);
        return .{ .start = share * lane.lane_idx + @min(lane.lane_idx, leftover), .len = share + extra };
    }

    /// Different jobs at once.
    /// `tasks` is a tuple of `.{ function, .{ arguments } }`.
    /// Each task runs once, on whichever lane is free.
    /// It does not wait on entry.
    /// At the end it waits for every lane, the way `wait` says.
    /// A task may return an error.
    /// After all tasks have run, every lane returns the same error.
    /// So `try` takes every lane the same way.
    /// The tuple must be the same on every lane.
    ///
    ///     try lane.forEachTask(.{
    ///         .{ updateGrid, .{ &grid, positions } },
    ///         .{ updateSounds, .{&mixer} },
    ///     }, .spin);
    pub fn forEachTask(lane: *Lane, tasks: anytype, wait: Barrier.Wait) anyerror!void {
        const slot = lane.enterSlot();
        runTasks(slot, tasks);
        lane.barrier.sync(wait);
        const failure = slot.failure();
        lane.leaveSlot(slot);
        if (failure) |err| return err;
    }

    /// `forEachTask` without the wait at the end.
    /// A lane that finds no task left goes on while others may still work.
    /// Put a barrier before reading what the tasks wrote.
    /// Without a barrier no error can reach every lane, so these tasks cannot return one.
    pub fn forEachTaskNoWait(lane: *Lane, tasks: anytype) void {
        inline for (tasks) |task| {
            if (@typeInfo(@typeInfo(@TypeOf(task[0])).@"fn".return_type.?) == .error_union) {
                @compileError("a task that can fail needs forEachTask, " ++
                    "which waits and returns its error on every lane");
            }
        }
        const slot = lane.enterSlot();
        runTasks(slot, tasks);
        lane.leaveSlot(slot);
    }

    /// Lane 0's `value`, on every lane.
    /// A decision about the path through the code, in one call.
    /// The other lanes' `value` is not read.
    /// It is a barrier, waiting the way `wait` says.
    ///
    ///     const quit = lane.broadcast(bool, lane.lane_idx == 0 and window.closed(), .spin);
    ///     if (quit) return;
    pub fn broadcast(lane: *Lane, comptime T: type, value: T, wait: Barrier.Wait) T {
        return lane.exchange(T, value, wait)[0].get(T);
    }

    /// Every lane's `value`, combined into one.
    /// Every lane gets the same result, bit for bit.
    /// Each lane combines the values in lane order, so this holds for floats too.
    /// `op` is a `std.lang.ReduceOp`, such as `.Add`, or a `fn (T, T) T`.
    /// It is a barrier, waiting the way `wait` says.
    /// `T` fits in 8 bytes.
    ///
    ///     const hits = lane.reduce(u32, myHits, .Add, .spin);
    pub fn reduce(lane: *Lane, comptime T: type, value: T, comptime op: anytype, wait: Barrier.Wait) T {
        const words = lane.exchange(T, value, wait);
        var total = words[0].get(T);
        for (words[1..]) |word| total = combine(T, op, total, word.get(T));
        return total;
    }

    /// What `scan` returns.
    pub fn Scan(comptime T: type) type {
        return struct {
            /// The lanes before this one, combined.
            /// For lane 0 it is the value that changes nothing, such as 0 for `.Add`.
            before: T,
            /// Every lane, combined.
            /// The same as `reduce`.
            total: T,
        };
    }

    /// The values of the lanes before this one, combined, and the values of all lanes.
    /// With `.Add`, `before` is where this lane's part of a shared output starts.
    /// `total` is the length of the whole output.
    /// `op` is a `std.lang.ReduceOp`.
    /// It is a barrier, waiting the way `wait` says.
    /// `T` fits in 8 bytes.
    ///
    ///     const r = lane.staticRange(items.len, null);
    ///     const at = lane.scan(usize, countKept(items[r.start..r.end()]), .Add, .spin);
    ///     // Lane 0 sizes the output to `at.total`, then a barrier.
    ///     writeKept(items[r.start..r.end()], out[at.before..]);
    pub fn scan(lane: *Lane, comptime T: type, value: T, comptime op: std.lang.ReduceOp, wait: Barrier.Wait) Scan(T) {
        const words = lane.exchange(T, value, wait);
        var result: Scan(T) = .{ .before = identity(T, op), .total = undefined };
        for (words[0..lane.lane_idx]) |word| result.before = combine(T, op, result.before, word.get(T));
        result.total = result.before;
        for (words[lane.lane_idx..]) |word| result.total = combine(T, op, result.total, word.get(T));
        return result;
    }

    /// Every lane's `value`, by lane index, after a barrier.
    fn exchange(lane: *Lane, comptime T: type, value: T, wait: Barrier.Wait) []const Word {
        comptime assert(@sizeOf(T) <= @sizeOf(u64) and @alignOf(T) <= @alignOf(u64));
        assert(lane.lane_count <= max_lanes);
        // The set the last exchange did not write.
        // Or a set every lane has passed a barrier since reading.
        const set = lane.barrier.generation.load(.acquire) % 2;
        const words = &lane.queue.exchanged[set];
        words[lane.lane_idx].set(T, value);
        lane.barrier.sync(wait);
        return words[0..lane.lane_count];
    }

    fn combine(comptime T: type, comptime op: anytype, a: T, b: T) T {
        if (@typeInfo(@TypeOf(op)) == .@"fn") return op(a, b);
        return switch (@as(std.lang.ReduceOp, op)) {
            .Add => a + b,
            .Mul => a * b,
            .Min => @min(a, b),
            .Max => @max(a, b),
            .And => if (T == bool) a and b else a & b,
            .Or => if (T == bool) a or b else a | b,
            .Xor => if (T == bool) a != b else a ^ b,
        };
    }

    /// The value that changes nothing when combined.
    fn identity(comptime T: type, comptime op: std.lang.ReduceOp) T {
        return switch (op) {
            .Add, .Or, .Xor => if (T == bool) false else 0,
            .Mul => 1,
            .And => if (T == bool) true else ~@as(T, 0),
            .Min => if (@typeInfo(T) == .float) std.math.inf(T) else std.math.maxInt(T),
            .Max => if (@typeInfo(T) == .float) -std.math.inf(T) else std.math.minInt(T),
        };
    }

    /// The slot of this lane's next call.
    /// It waits until every lane has left the call `queue_slot_count` back.
    fn enterSlot(lane: *Lane) *WorkQueue.Slot {
        if (std.debug.runtime_safety and lane.in_call) {
            @panic("a forEachQueued loop was left before `next` returned null: end it with `defer it.finish();`");
        }
        lane.in_call = true;
        const call = lane.calls;
        lane.calls +%= 1;
        const slot = &lane.queue.slots[call % queue_slot_count];
        if (std.debug.runtime_safety) {
            // The slot is at this call, or `queue_slot_count` calls before it.
            // It is never after it.
            // Half the u32 range tells "after" apart from "wrapped round".
            const ahead = slot.call.load(.acquire) -% call;
            if (ahead != 0 and ahead < 1 << 31) {
                @panic("this Lane has lost count of its calls: a fresh copy? Take a Group's Lane once and keep it");
            }
        }
        while (slot.call.load(.acquire) != call) std.atomic.spinLoopHint();
        return slot;
    }

    fn leaveSlot(lane: *Lane, slot: *WorkQueue.Slot) void {
        lane.in_call = false;
        slot.leave(lane.lane_count);
    }

    fn runTasks(slot: *WorkQueue.Slot, tasks: anytype) void {
        while (slot.take(tasks.len, 1)) |range| { // One task per batch.
            inline for (tasks, 0..) |task, index| {
                if (index == range.start) {
                    const Returned = @typeInfo(@TypeOf(task[0])).@"fn".return_type.?;
                    if (@typeInfo(Returned) == .error_union) {
                        @call(.auto, task[0], task[1]) catch |err| slot.fail(err);
                    } else {
                        @call(.auto, task[0], task[1]);
                    }
                }
            }
        }
    }
};

/// Some of the lanes, going their own way for a while.
/// It covers the parent's lanes `first .. first + lane_count`.
/// It has its own barrier and queue.
/// Lanes in different groups do not wait for each other.
/// So one group can load or simulate something slow while the other runs frames.
/// The group's lanes follow the rules among themselves.
/// The parent's barrier waits until every lane is back.
///
/// Make it with the shared state, before the lanes start.
/// Take each lane's `Lane` in it once:
///
///     // shared: loader: Group = .init(0, 1), frames: Group = .init(1, lane_count - 1)
///     if (shared.loader.lane(lane)) |sub_lane| {
///         var sub = sub_lane; // Keep it. It counts its calls, as every `Lane` does.
///         load(&sub, shared);
///     } else if (shared.frames.lane(lane)) |sub_lane| {
///         var sub = sub_lane;
///         while (!loadedYet(&sub, shared)) frame(&sub, shared);
///     }
///     lane.barrier.sync(.{ .sleep = io }); // Every lane, back together.
pub const Group = struct {
    barrier: Barrier,
    queue: WorkQueue = .empty,
    /// The parent's index of the group's lane 0.
    first: u8,

    pub fn init(first: u8, lane_count: u8) Group {
        assert(@as(u16, first) + lane_count <= std.math.maxInt(u8));
        return .{ .barrier = .init(lane_count), .first = first };
    }

    /// The `Lane` of `parent` in this group, or null if `parent` is not in it.
    /// Its index counts from the group's first lane.
    /// Take it once and keep it.
    /// A fresh copy has lost count of the group's calls.
    pub fn lane(group: *Group, parent: *const Lane) ?Lane {
        assert(@as(u16, group.first) + group.barrier.lane_count <= parent.lane_count);
        if (parent.lane_idx < group.first or parent.lane_idx - group.first >= group.barrier.lane_count) return null;
        return .init(&group.barrier, &group.queue, parent.lane_idx - group.first);
    }
};

/// Runs `entry` on `lane_count` lanes and returns when all have returned.
/// Lanes 1 and up run on threads of their own.
/// Lane 0 runs on the calling thread.
/// `entry` is `fn (lane: *Lane, ...args) void`.
/// The barrier, the queue and the lanes live on this call's stack.
///
/// If a thread cannot start, no lane runs `entry` and the error is returned.
/// So no lane is left waiting for one that never came.
pub fn run(
    lane_count: u8,
    comptime entry: anytype,
    args: anytype,
) std.Thread.SpawnError!void {
    assert(lane_count >= 1 and lane_count <= max_lanes);
    const Gate = enum(u32) { closed, open, abandoned };
    const RunLane = struct {
        fn main(gate: *const Atomic(Gate), lane: *Lane, lane_args: @TypeOf(args)) void {
            while (gate.load(.acquire) == .closed) std.Thread.yield() catch {};
            if (gate.load(.acquire) == .abandoned) return;
            @call(.auto, entry, .{lane} ++ lane_args);
        }
    };

    var barrier: Barrier = .init(lane_count);
    var queue: WorkQueue = .empty;
    var lanes: [max_lanes]Lane = undefined;
    for (lanes[0..lane_count], 0..) |*lane, idx| lane.* = .init(&barrier, &queue, @intCast(idx));

    var gate: Atomic(Gate) = .init(.closed);
    var threads: [max_lanes]std.Thread = undefined;
    var started: u8 = 0;
    errdefer {
        gate.store(.abandoned, .release);
        for (threads[0..started]) |thread| thread.join();
    }
    while (started + 1 < lane_count) : (started += 1) {
        threads[started] = try std.Thread.spawn(.{}, RunLane.main, .{ &gate, &lanes[started + 1], args });
    }
    gate.store(.open, .release);
    @call(.auto, entry, .{&lanes[0]} ++ args);
    for (threads[0..started]) |thread| thread.join();
}

// -- tests ---------------------------------------------------------------------------------------------------

const testing = std.testing;

test "this machine has at least one lane" {
    try testing.expect(try getCpuCount() >= 1);
}

test "staticRange: the shares are in order, cover every item once and differ by at most one" {
    var queue: WorkQueue = .empty;
    for ([_]usize{ 0, 1, 2, 7, 8, 9, 64, 1000, 1023 }) |item_count| {
        for ([_]u8{ 1, 2, 3, 4, 8, 13 }) |lane_count| {
            var barrier: Barrier = .init(lane_count);
            var next: usize = 0;
            var smallest: usize = std.math.maxInt(usize);
            var biggest: usize = 0;
            for (0..lane_count) |idx| {
                const lane: Lane = .init(&barrier, &queue, @intCast(idx));
                const range = lane.staticRange(item_count, null);
                try testing.expectEqual(next, range.start);
                next = range.end();
                smallest = @min(smallest, range.len);
                biggest = @max(biggest, range.len);
            }
            try testing.expectEqual(item_count, next);
            try testing.expect(biggest - smallest <= 1);
        }
    }
}

test "staticRange: with a minimum per lane, fewer lanes share the work and none gets a crumb" {
    var queue: WorkQueue = .empty;
    const cases = [_]struct { item_count: usize, min: usize, lane_count: u8, lanes_used: usize }{
        .{ .item_count = 1000, .min = 100, .lane_count = 4, .lanes_used = 4 }, // plenty for everyone
        .{ .item_count = 250, .min = 100, .lane_count = 4, .lanes_used = 2 }, // only two can have 100
        .{ .item_count = 99, .min = 100, .lane_count = 4, .lanes_used = 1 }, // one lane takes it all
        .{ .item_count = 0, .min = 100, .lane_count = 4, .lanes_used = 0 }, // nothing to do
        .{ .item_count = 400, .min = 100, .lane_count = 4, .lanes_used = 4 }, // exactly enough
    };
    for (cases) |case| {
        var barrier: Barrier = .init(case.lane_count);
        var covered: usize = 0;
        var used: usize = 0;
        for (0..case.lane_count) |idx| {
            const lane: Lane = .init(&barrier, &queue, @intCast(idx));
            const range = lane.staticRange(case.item_count, case.min);
            if (range.len == 0) continue;
            try testing.expectEqual(covered, range.start);
            try testing.expect(range.len >= @min(case.min, case.item_count));
            covered = range.end();
            used += 1;
        }
        try testing.expectEqual(case.item_count, covered);
        try testing.expectEqual(case.lanes_used, used);
    }
}

test "Lane.init: the lane count comes from the barrier, and the queue starts empty" {
    var queue: WorkQueue = .empty;
    for ([_]u8{ 1, 4, 255 }) |lane_count| {
        var barrier: Barrier = .init(lane_count);
        const last: Lane = .init(&barrier, &queue, lane_count - 1);
        try testing.expectEqual(lane_count, last.lane_count);
        try testing.expectEqual(lane_count - 1, last.lane_idx);
        try testing.expectEqual(&barrier, last.barrier);
    }
    for (queue.slots, 0..) |slot, idx| try testing.expectEqual(@as(u32, @intCast(idx)), slot.call.load(.monotonic));
}

test "WorkQueue: batches cover every item once, the last one short, then null for good" {
    var slot: WorkQueue.Slot = .empty;
    try testing.expectEqual(Range{ .start = 0, .len = 4 }, slot.take(10, 4).?);
    try testing.expectEqual(Range{ .start = 4, .len = 4 }, slot.take(10, 4).?);
    try testing.expectEqual(Range{ .start = 8, .len = 2 }, slot.take(10, 4).?);
    try testing.expectEqual(@as(?Range, null), slot.take(10, 4));
    try testing.expectEqual(@as(?Range, null), slot.take(10, 4));
    slot.leave(1); // The last lane out clears the slot for a later call.
    try testing.expectEqual(@as(u32, queue_slot_count), slot.call.load(.monotonic));
    try testing.expectEqual(@as(?Range, null), slot.take(0, 4)); // nothing to hand out
    slot.leave(1);
    try testing.expectEqual(Range{ .start = 0, .len = 3 }, slot.take(3, 4).?); // And it starts over.
}

test "WorkQueue: the counter every lane writes is a cache line away from what they touch once a call" {
    try testing.expect(@offsetOf(WorkQueue.Slot, "left") - @offsetOf(WorkQueue.Slot, "next") >= std.atomic.cache_line);
    try testing.expectEqual(@as(usize, 0), @offsetOf(WorkQueue.Slot, "next") % std.atomic.cache_line);
    try testing.expectEqual(@as(usize, 0), @sizeOf(WorkQueue.Slot) % std.atomic.cache_line);
}

const test_lanes = 4;

test "run: every lane runs the entry once, with its own index" {
    const Seen = struct {
        fn entry(lane: *Lane, seen: *[test_lanes]Atomic(u32), count: *Atomic(u32)) void {
            _ = seen[lane.lane_idx].fetchAdd(1, .monotonic);
            _ = count.fetchAdd(lane.lane_count, .monotonic);
        }
    };
    var seen: [test_lanes]Atomic(u32) = @splat(.init(0));
    var count: Atomic(u32) = .init(0);
    try run(test_lanes, Seen.entry, .{ &seen, &count });
    for (&seen) |*lane| try testing.expectEqual(@as(u32, 1), lane.load(.monotonic));
    try testing.expectEqual(@as(u32, test_lanes * test_lanes), count.load(.monotonic));

    var alone: [test_lanes]Atomic(u32) = @splat(.init(0));
    try run(1, Seen.entry, .{ &alone, &count }); // One lane: the calling thread alone.
    try testing.expectEqual(@as(u32, 1), alone[0].load(.monotonic));
    try testing.expectEqual(@as(u32, 0), alone[1].load(.monotonic));
}

test "sync(.spin): what lane 0 writes before a barrier, every lane reads after it, phase after phase" {
    const phases = 2000;
    const Lockstep = struct {
        fn entry(lane: *Lane, value: *u32, wrong: *Atomic(u32)) void {
            for (0..phases) |phase| {
                if (lane.lane_idx == 0) value.* = @intCast(phase * 3 + 1);
                lane.barrier.sync(.spin);
                if (value.* != phase * 3 + 1) _ = wrong.fetchAdd(1, .monotonic);
                lane.barrier.sync(.spin); // Nobody writes the next value while another lane reads this one.
            }
        }
    };
    var value: u32 = 0;
    var wrong: Atomic(u32) = .init(0);
    try run(test_lanes, Lockstep.entry, .{ &value, &wrong });
    try testing.expectEqual(@as(u32, 0), wrong.load(.monotonic));
    try testing.expectEqual(@as(u32, (phases - 1) * 3 + 1), value);
}

test "sync(.sleep): the same lockstep, asleep while waiting" {
    const phases = 300;
    const Lockstep = struct {
        fn entry(lane: *Lane, io: std.Io, value: *u32, wrong: *Atomic(u32)) void {
            for (0..phases) |phase| {
                if (lane.lane_idx == 0) value.* = @intCast(phase + 7);
                lane.barrier.sync(.{ .sleep = io });
                if (value.* != phase + 7) _ = wrong.fetchAdd(1, .monotonic);
                lane.barrier.sync(.{ .sleep = io });
            }
        }
    };
    var value: u32 = 0;
    var wrong: Atomic(u32) = .init(0);
    try run(test_lanes, Lockstep.entry, .{ testing.io, &value, &wrong });
    try testing.expectEqual(@as(u32, 0), wrong.load(.monotonic));
}

test "sync(.spin) and sync(.sleep) at different barriers of one run" {
    const Mixed = struct {
        fn entry(lane: *Lane, io: std.Io, value: *u32, wrong: *Atomic(u32)) void {
            for (0..200) |phase| {
                if (lane.lane_idx == 0) value.* = @intCast(phase);
                lane.barrier.sync(.{ .sleep = io }); // a long wait...
                if (value.* != phase) _ = wrong.fetchAdd(1, .monotonic);
                lane.barrier.sync(.spin); // ...then a short one
            }
        }
    };
    var value: u32 = 0;
    var wrong: Atomic(u32) = .init(0);
    try run(test_lanes, Mixed.entry, .{ testing.io, &value, &wrong });
    try testing.expectEqual(@as(u32, 0), wrong.load(.monotonic));
}

test "staticRange on lanes: every item is worked on exactly once" {
    const item_count = 10_007;
    const Split = struct {
        fn entry(lane: *Lane, touched: []u8) void {
            for (0..20) |_| {
                const range = lane.staticRange(touched.len, 64);
                for (touched[range.start..range.end()]) |*t| t.* += 1;
                lane.barrier.sync(.spin);
            }
        }
    };
    const touched = try testing.allocator.alloc(u8, item_count);
    defer testing.allocator.free(touched);
    @memset(touched, 0);
    try run(test_lanes, Split.entry, .{touched});
    for (touched) |t| try testing.expectEqual(@as(u8, 20), t);
}

test "forEachQueued: every item is worked on exactly once, whatever the batch size, and all is done at the null" {
    const item_count = 10_007;
    const Queued = struct {
        fn entry(lane: *Lane, touched: []u8, unfinished: *Atomic(u32)) void {
            for ([_]?usize{ 1, 7, 64, 4096, 100_000, null }) |batch_len| {
                var it = lane.forEachQueued(touched.len, batch_len, .{ .wait = .spin });
                while (it.next()) |range| {
                    for (touched[range.start..range.end()], range.start..) |*t, i| {
                        var spin = i % 50; // uneven cost
                        while (spin > 0) : (spin -= 1) std.mem.doNotOptimizeAway(spin);
                        t.* += 1;
                    }
                }
                // The null waited for every lane, so every lane may read every item now.
                const expected: u8 = switch (batch_len orelse 0) {
                    1 => 1,
                    7 => 2,
                    64 => 3,
                    4096 => 4,
                    100_000 => 5,
                    else => 6,
                };
                for (touched) |t| {
                    if (t != expected) _ = unfinished.fetchAdd(1, .monotonic);
                }
                lane.barrier.sync(.spin); // The next round's writes wait for these reads.
            }
        }
    };
    const touched = try testing.allocator.alloc(u8, item_count);
    defer testing.allocator.free(touched);
    @memset(touched, 0);
    var unfinished: Atomic(u32) = .init(0);
    try run(test_lanes, Queued.entry, .{ touched, &unfinished });
    try testing.expectEqual(@as(u32, 0), unfinished.load(.monotonic));
    for (touched) |t| try testing.expectEqual(@as(u8, 6), t);
}

test "forEachQueued: nothing to do is fine, and so is one lane" {
    const Empty = struct {
        fn entry(lane: *Lane, taken: *Atomic(u32)) void {
            var it = lane.forEachQueued(0, null, .{ .wait = .spin });
            while (it.next()) |_| _ = taken.fetchAdd(1, .monotonic);
            var some = lane.forEachQueued(5, 2, .{ .wait = .spin });
            while (some.next()) |range| _ = taken.fetchAdd(@intCast(range.len), .monotonic);
        }
    };
    var taken: Atomic(u32) = .init(0);
    try run(test_lanes, Empty.entry, .{&taken});
    try testing.expectEqual(@as(u32, 5), taken.load(.monotonic));
    taken.store(0, .monotonic);
    try run(1, Empty.entry, .{&taken});
    try testing.expectEqual(@as(u32, 5), taken.load(.monotonic));
}

test "forEachQueued(.no_wait): call after call with no barrier between, every item is worked on exactly once" {
    const calls = 300;
    const per_call = 97;
    const Ahead = struct {
        fn entry(lane: *Lane, io: std.Io, touched: []u8) void {
            for (0..calls) |call| {
                const end: End = if (call % 50 == 49) .{ .wait = .{ .sleep = io } } else .no_wait;
                var it = lane.forEachQueued(per_call, 3, end);
                while (it.next()) |range| {
                    for (touched[call * per_call ..][range.start..range.end()]) |*t| {
                        // One lane at a time is slow, so the others run calls ahead of it.
                        if (lane.lane_idx == call % lane.lane_count) {
                            var spin: usize = 200;
                            while (spin > 0) : (spin -= 1) std.mem.doNotOptimizeAway(spin);
                        }
                        t.* += 1;
                    }
                }
            }
            lane.barrier.sync(.spin);
        }
    };
    const touched = try testing.allocator.alloc(u8, calls * per_call);
    defer testing.allocator.free(touched);
    for ([_]u8{ test_lanes, 1 }) |lane_count| {
        @memset(touched, 0);
        try run(lane_count, Ahead.entry, .{ testing.io, touched });
        for (touched) |t| try testing.expectEqual(@as(u8, 1), t);
    }
}

test "forEachQueued(.no_wait): a lane out of work takes work from the next call while another is still busy" {
    const Ahead = struct {
        fn entry(lane: *Lane, went_ahead: *Atomic(bool)) void {
            var first = lane.forEachQueued(lane.lane_count, 1, .no_wait);
            while (first.next()) |range| {
                if (range.start != 0) continue;
                // Hold item 0 until another lane takes the next call's only item, or give up.
                var tries: usize = 0;
                while (!went_ahead.load(.acquire) and tries < 1 << 30) : (tries += 1) std.atomic.spinLoopHint();
            }
            var second = lane.forEachQueued(1, 1, .no_wait);
            while (second.next()) |_| went_ahead.store(true, .release);
            lane.barrier.sync(.spin);
        }
    };
    var went_ahead: Atomic(bool) = .init(false);
    try run(test_lanes, Ahead.entry, .{&went_ahead});
    try testing.expect(went_ahead.load(.monotonic));
}

test "RangeIter.finish: a lane that leaves its loop early leaves the rest to the others, call after call" {
    const calls = 200;
    const per_call = 64;
    const Early = struct {
        /// Lane 0 stops after its first batch.
        /// It uses `break` on odd calls and an error on even ones.
        fn work(lane: *Lane, io: std.Io, touched: []u8, call: usize) error{Stop}!void {
            const end: End = if (call % 20 == 19) .{ .wait = .{ .sleep = io } } else .no_wait;
            var it = lane.forEachQueued(per_call, 4, end);
            defer it.finish();
            while (it.next()) |range| {
                for (touched[call * per_call ..][range.start..range.end()]) |*t| t.* += 1;
                if (lane.lane_idx != 0) continue;
                if (call % 2 == 1) break;
                return error.Stop;
            }
        }

        fn entry(lane: *Lane, io: std.Io, touched: []u8) void {
            for (0..calls) |call| work(lane, io, touched, call) catch {};
            lane.barrier.sync(.spin);
        }
    };
    const touched = try testing.allocator.alloc(u8, calls * per_call);
    defer testing.allocator.free(touched);
    for ([_]u8{ test_lanes, 1 }) |lane_count| {
        @memset(touched, 0);
        try run(lane_count, Early.entry, .{ testing.io, touched });
        const expected: u8 = if (lane_count == 1) 0 else 1; // One lane alone stops after a batch.
        for (touched, 0..) |t, i| {
            if (i % per_call < 4) try testing.expectEqual(@as(u8, 1), t) else try testing.expectEqual(expected, t);
        }
    }
}

const TaskLog = struct {
    a: Atomic(u32) = .init(0),
    b: Atomic(u32) = .init(0),
    c: Atomic(u32) = .init(0),

    const empty: TaskLog = .{};

    fn runA(log: *TaskLog) void {
        _ = log.a.fetchAdd(1, .monotonic);
    }
    fn runB(log: *TaskLog, by: u32) void {
        _ = log.b.fetchAdd(by, .monotonic);
    }
    fn runC(log: *TaskLog, fail: bool) error{Broken}!void {
        _ = log.c.fetchAdd(1, .monotonic);
        if (fail) return error.Broken;
    }
    fn alwaysOther(log: *TaskLog) error{Other}!void {
        _ = log.a.fetchAdd(1, .monotonic);
        return error.Other;
    }
};

test "forEachTask: each task runs exactly once a call, whichever lane takes it" {
    const Tasks = struct {
        fn entry(lane: *Lane, log: *TaskLog, failed: *Atomic(u32)) void {
            for (0..50) |_| {
                lane.forEachTask(.{
                    .{ TaskLog.runA, .{log} },
                    .{ TaskLog.runB, .{ log, @as(u32, 10) } },
                    .{ TaskLog.runC, .{ log, false } },
                }, .spin) catch {
                    _ = failed.fetchAdd(1, .monotonic);
                };
            }
        }
    };
    var log: TaskLog = .empty;
    var failed: Atomic(u32) = .init(0);
    try run(test_lanes, Tasks.entry, .{ &log, &failed });
    try testing.expectEqual(@as(u32, 50), log.a.load(.monotonic));
    try testing.expectEqual(@as(u32, 500), log.b.load(.monotonic));
    try testing.expectEqual(@as(u32, 50), log.c.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), failed.load(.monotonic));
}

test "forEachTaskNoWait: each task runs exactly once a call, with lanes running on between calls" {
    const Tasks = struct {
        fn entry(lane: *Lane, log: *TaskLog) void {
            for (0..200) |_| {
                lane.forEachTaskNoWait(.{
                    .{ TaskLog.runA, .{log} },
                    .{ TaskLog.runB, .{ log, @as(u32, 10) } },
                });
            }
            lane.barrier.sync(.spin);
        }
    };
    var log: TaskLog = .empty;
    try run(test_lanes, Tasks.entry, .{&log});
    try testing.expectEqual(@as(u32, 200), log.a.load(.monotonic));
    try testing.expectEqual(@as(u32, 2000), log.b.load(.monotonic));
}

test "forEachTask: a task's error is returned on every lane alike, after every task has run, and not the call after" {
    const rounds = 60;
    const Tasks = struct {
        fn entry(lane: *Lane, log: *TaskLog, results: *[test_lanes][rounds]u8) void {
            for (0..rounds) |round| {
                const fail = round % 3 == 0;
                const result = lane.forEachTask(.{
                    .{ TaskLog.runA, .{log} },
                    .{ TaskLog.runC, .{ log, fail } },
                    .{ TaskLog.runB, .{ log, @as(u32, 1) } },
                }, .spin);
                results[lane.lane_idx][round] = if (result) |_| 'k' else |err| if (err == error.Broken) 'B' else '?';
                var it = lane.forEachQueued(test_lanes * 2, 1, .no_wait); // Lanes may run on into the next call.
                while (it.next()) |_| {}
            }
        }
    };
    var log: TaskLog = .empty;
    var results: [test_lanes][rounds]u8 = undefined;
    try run(test_lanes, Tasks.entry, .{ &log, &results });
    for (0..rounds) |round| {
        const expected: u8 = if (round % 3 == 0) 'B' else 'k';
        for (0..test_lanes) |lane| try testing.expectEqual(expected, results[lane][round]);
    }
    // A failing task did not stop the others of its call.
    try testing.expectEqual(@as(u32, rounds), log.a.load(.monotonic));
    try testing.expectEqual(@as(u32, rounds), log.b.load(.monotonic));
    try testing.expectEqual(@as(u32, rounds), log.c.load(.monotonic));
}

test "forEachTask: of two errors every lane gets the same one" {
    const Tasks = struct {
        fn entry(lane: *Lane, log: *TaskLog, results: *[test_lanes][40]anyerror) void {
            for (0..40) |round| {
                results[lane.lane_idx][round] = if (lane.forEachTask(.{
                    .{ TaskLog.alwaysOther, .{log} },
                    .{ TaskLog.runC, .{ log, true } },
                }, .spin)) |_| error.Unexpected else |err| err;
            }
        }
    };
    var log: TaskLog = .empty;
    var results: [test_lanes][40]anyerror = undefined;
    try run(test_lanes, Tasks.entry, .{ &log, &results });
    for (0..40) |round| {
        const first = results[0][round];
        try testing.expect(first == error.Other or first == error.Broken);
        for (1..test_lanes) |lane| try testing.expectEqual(first, results[lane][round]);
    }
}

test "broadcast: lane 0's value on every lane, exchange after exchange with no other barrier" {
    const rounds = 2000;
    const Broadcast = struct {
        fn entry(lane: *Lane, io: std.Io, wrong: *Atomic(u32)) void {
            for (0..rounds) |round| {
                const mine: u32 = @intCast(round * 10 + lane.lane_idx); // Only lane 0's value counts.
                const wait: Barrier.Wait = if (round % 100 == 0) .{ .sleep = io } else .spin;
                if (lane.broadcast(u32, mine, wait) != round * 10) _ = wrong.fetchAdd(1, .monotonic);
            }
        }
    };
    var wrong: Atomic(u32) = .init(0);
    for ([_]u8{ test_lanes, 1 }) |lane_count| {
        try run(lane_count, Broadcast.entry, .{ testing.io, &wrong });
        try testing.expectEqual(@as(u32, 0), wrong.load(.monotonic));
    }
}

test "reduce: every lane gets the same value, for each op and for a function of its own" {
    const ArgMax = extern struct {
        value: f32,
        lane: u32,

        fn pick(a: @This(), b: @This()) @This() {
            return if (b.value > a.value) b else a;
        }
    };
    const rounds = 500;
    const Reduce = struct {
        fn entry(lane: *Lane, wrong: *Atomic(u32)) void {
            const n: u32 = lane.lane_count;
            for (0..rounds) |round| {
                const r: u32 = @intCast(round);
                const i: u32 = lane.lane_idx;
                var ok = true;
                ok = ok and lane.reduce(u32, i + r, .Add, .spin) == n * r + n * (n - 1) / 2;
                ok = ok and lane.reduce(u32, i + r, .Max, .spin) == n - 1 + r;
                ok = ok and lane.reduce(i64, @as(i64, i) - 5, .Min, .spin) == -5;
                const bits: u16 = (@as(u16, 1) << @intCast(@min(n, 8))) - 1; // One bit per lane, up to 8.
                ok = ok and lane.reduce(u8, @as(u8, 1) << @intCast(i % 8), .Or, .spin) == bits;
                ok = ok and lane.reduce(bool, i == r % n, .Or, .spin);
                ok = ok and !lane.reduce(bool, i == r % n, .And, .spin) or n == 1;
                const mine: ArgMax = .{ .value = @floatFromInt((i * 7 + r) % n), .lane = i };
                const best = lane.reduce(ArgMax, mine, ArgMax.pick, .spin);
                ok = ok and best.value == @as(f32, @floatFromInt(n - 1));
                // Floats: the same bits on every lane, whatever order the lanes arrived in.
                const part = 0.1 * @as(f64, @floatFromInt(i + 1)) + 1e-9 * @as(f64, @floatFromInt(r));
                const sum = lane.reduce(f64, part, .Add, .spin);
                const sums = lane.reduce(u64, @bitCast(sum), .Xor, .spin); // Equal sums xor to 0 in pairs.
                ok = ok and (if (n % 2 == 0) sums == 0 else sums == @as(u64, @bitCast(sum)));
                if (!ok) _ = wrong.fetchAdd(1, .monotonic);
            }
        }
    };
    var wrong: Atomic(u32) = .init(0);
    for ([_]u8{ test_lanes, 3, 1 }) |lane_count| {
        try run(lane_count, Reduce.entry, .{&wrong});
        try testing.expectEqual(@as(u32, 0), wrong.load(.monotonic));
    }
}

test "scan: each lane's part of a shared output, in order, with nothing missed: a parallel filter" {
    const item_count = 10_007;
    const Filter = struct {
        fn keep(x: u32) bool {
            return x % 3 == 0 or x % 7 == 0;
        }

        fn entry(lane: *Lane, items: []const u32, out: []u32, length: *usize, wrong: *Atomic(u32)) void {
            for (0..20) |round| {
                const r = lane.staticRange(items.len, 64);
                const share = items[r.start..r.end()];
                var kept: usize = 0;
                for (share) |x| kept += @intFromBool(keep(x +% @as(u32, @intCast(round))));
                const at = lane.scan(usize, kept, .Add, .spin);
                var pos = at.before;
                for (share) |x| {
                    if (!keep(x +% @as(u32, @intCast(round)))) continue;
                    out[pos] = x;
                    pos += 1;
                }
                if (pos != at.before + kept) _ = wrong.fetchAdd(1, .monotonic);
                if (lane.lane_idx == 0) length.* = at.total;
                lane.barrier.sync(.spin);
                if (lane.lane_idx == 0) { // Every lane wrote its part. Check it against one lane's filter.
                    var expected: usize = 0;
                    for (items) |x| {
                        if (!keep(x +% @as(u32, @intCast(round)))) continue;
                        if (out[expected] != x) _ = wrong.fetchAdd(1, .monotonic);
                        expected += 1;
                    }
                    if (expected != length.*) _ = wrong.fetchAdd(1, .monotonic);
                }
                lane.barrier.sync(.spin);
            }
        }
    };
    const items = try testing.allocator.alloc(u32, item_count);
    defer testing.allocator.free(items);
    for (items, 0..) |*x, i| x.* = @intCast(i * 13 % 1000);
    const out = try testing.allocator.alloc(u32, item_count);
    defer testing.allocator.free(out);
    var length: usize = 0;
    var wrong: Atomic(u32) = .init(0);
    for ([_]u8{ test_lanes, 1 }) |lane_count| {
        try run(lane_count, Filter.entry, .{ items, out, &length, &wrong });
        try testing.expectEqual(@as(u32, 0), wrong.load(.monotonic));
    }
}

test "scan: lane 0 starts at nothing, as each op counts it" {
    var barrier: Barrier = .init(1);
    var queue: WorkQueue = .empty;
    var lane: Lane = .init(&barrier, &queue, 0);
    try testing.expectEqual(Lane.Scan(i32){ .before = 0, .total = 5 }, lane.scan(i32, 5, .Add, .spin));
    try testing.expectEqual(Lane.Scan(i32){ .before = 1, .total = 5 }, lane.scan(i32, 5, .Mul, .spin));
    try testing.expectEqual(Lane.Scan(u8){ .before = 255, .total = 5 }, lane.scan(u8, 5, .Min, .spin));
    try testing.expectEqual(Lane.Scan(f32){ .before = -std.math.inf(f32), .total = 5 }, lane.scan(f32, 5, .Max, .spin));
    try testing.expectEqual(Lane.Scan(bool){ .before = true, .total = false }, lane.scan(bool, false, .And, .spin));
}

test "RangeIter.fail: every lane returns the error, the others stop taking, the next call is clean" {
    const rounds = 100;
    const item_count = 1 << 20;
    const Fail = struct {
        fn work(lane: *Lane, io: std.Io, round: usize, taken: *Atomic(usize)) !void {
            const wait: Barrier.Wait = if (round % 10 == 0) .{ .sleep = io } else .spin;
            var it = lane.forEachQueued(item_count, 1, .{ .wait = wait });
            while (it.next()) |range| {
                _ = taken.fetchAdd(1, .monotonic);
                if (round % 2 == 0 and range.start == 100) it.fail(error.Broken);
            }
            try it.result();
        }

        fn entry(lane: *Lane, io: std.Io, results: *[test_lanes][rounds]u8, taken: *[rounds]Atomic(usize)) void {
            for (0..rounds) |round| {
                const result = work(lane, io, round, &taken[round]);
                results[lane.lane_idx][round] = if (result) |_| 'k' else |err| if (err == error.Broken) 'B' else '?';
            }
        }
    };
    var results: [test_lanes][rounds]u8 = undefined;
    var taken: [rounds]Atomic(usize) = @splat(.init(0));
    try run(test_lanes, Fail.entry, .{ testing.io, &results, &taken });
    for (0..rounds) |round| {
        const failed = round % 2 == 0;
        for (0..test_lanes) |lane| try testing.expectEqual(@as(u8, if (failed) 'B' else 'k'), results[lane][round]);
        if (failed) try testing.expect(taken[round].load(.monotonic) < item_count / 2) // Stopped well short.
        else try testing.expectEqual(@as(usize, item_count), taken[round].load(.monotonic));
    }
}

test "RangeIter.cancel: a search stops every lane once one has found it, with .no_wait as well" {
    const item_count = 1 << 20;
    const Search = struct {
        fn entry(lane: *Lane, found: *Atomic(usize), taken: *Atomic(usize)) void {
            for ([_]End{ .{ .wait = .spin }, .no_wait }) |end| {
                var it = lane.forEachQueued(item_count, 16, end);
                while (it.next()) |range| {
                    _ = taken.fetchAdd(range.len, .monotonic);
                    if (range.start <= 1000 and 1000 < range.end()) {
                        found.store(1000, .monotonic);
                        it.cancel();
                    }
                }
                lane.barrier.sync(.spin);
            }
        }
    };
    var found: Atomic(usize) = .init(0);
    var taken: Atomic(usize) = .init(0);
    try run(test_lanes, Search.entry, .{ &found, &taken });
    try testing.expectEqual(@as(usize, 1000), found.load(.monotonic));
    try testing.expect(taken.load(.monotonic) < item_count); // Both calls together took far less than one whole.
}

test "Group: two groups run on their own, the parent's barrier brings them back together, round after round" {
    const rounds = 30;
    const Shared = struct {
        loader: Group,
        frames: Group,
        loaded: Atomic(u32) = .init(0), // The loader group's progress, read by the others.
        frame_count: [rounds]u32 = @splat(0), // Frames the frame group ran while the loader worked.
        wrong: Atomic(u32) = .init(0),
    };
    const Split = struct {
        fn entry(lane: *Lane, io: std.Io, s: *Shared) void {
            var loader = s.loader.lane(lane); // Each lane is in one group. Taken once, kept for every round.
            var frames = s.frames.lane(lane);
            if ((loader == null) == (frames == null)) _ = s.wrong.fetchAdd(1, .monotonic);
            for (0..rounds) |round| {
                if (loader) |*sub| {
                    // A long job, shared by the group's lanes.
                    var it = sub.forEachQueued(200, 1, .{ .wait = .spin });
                    while (it.next()) |_| {
                        var spin: usize = 20_000;
                        while (spin > 0) : (spin -= 1) std.mem.doNotOptimizeAway(spin);
                    }
                    if (sub.reduce(u32, 1, .Add, .spin) != sub.lane_count) _ = s.wrong.fetchAdd(1, .monotonic);
                    if (sub.lane_idx == 0) s.loaded.store(@intCast(round + 1), .release);
                } else if (frames) |*sub| {
                    // Short frames until the loader is done. The group agrees when to stop.
                    while (!sub.broadcast(bool, s.loaded.load(.acquire) > round, .spin)) {
                        var it = sub.forEachQueued(64, 4, .no_wait);
                        while (it.next()) |_| {}
                        sub.forEachTask(.{.{ countFrame, .{ s, round, sub.lane_idx } }}, .spin) catch {};
                    }
                }
                lane.barrier.sync(.{ .sleep = io }); // every lane, back together
                if (lane.reduce(u32, 1, .Add, .spin) != lane.lane_count) _ = s.wrong.fetchAdd(1, .monotonic);
            }
        }

        fn countFrame(s: *Shared, round: usize, _: u8) void {
            s.frame_count[round] += 1; // One task per call, so one lane at a time.
        }
    };
    var s: Shared = .{ .loader = .init(0, 2), .frames = .init(2, test_lanes - 2) };
    try run(test_lanes, Split.entry, .{ testing.io, &s });
    try testing.expectEqual(@as(u32, 0), s.wrong.load(.monotonic));
    try testing.expectEqual(@as(u32, rounds), s.loaded.load(.monotonic));
    var frames_total: u32 = 0;
    for (s.frame_count) |count| frames_total += count;
    try testing.expect(frames_total > rounds); // The frame group ran on while the loader worked.
}

test "Group: a lane is in a group or not, and counts from the group's first lane" {
    var barrier: Barrier = .init(8);
    var queue: WorkQueue = .empty;
    var group: Group = .init(3, 4);
    for (0..8) |idx| {
        const parent: Lane = .init(&barrier, &queue, @intCast(idx));
        if (group.lane(&parent)) |sub| {
            try testing.expect(idx >= 3 and idx < 7);
            try testing.expectEqual(@as(u8, @intCast(idx - 3)), sub.lane_idx);
            try testing.expectEqual(@as(u8, 4), sub.lane_count);
            try testing.expectEqual(&group.barrier, sub.barrier);
        } else try testing.expect(idx < 3 or idx >= 7);
    }
}
