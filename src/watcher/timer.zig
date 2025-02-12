/// A timer fires a callback after a specified amount of time and
/// can optionally repeat at a specified interval.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const os = std.os;

pub fn Timer(comptime xev: type) type {
    return struct {
        const Self = @This();

        /// Create a new timer.
        pub fn init() !Self {
            return .{};
        }

        pub fn deinit(self: *Self) void {
            // Nothing for now.
            _ = self;
        }

        /// Start the timer. The timer will execute in next_ms milliseconds from
        /// now.
        ///
        /// This will use the monotonic clock on your system if available so
        /// this is immune to system clock changes or drift. The callback is
        /// guaranteed to fire NO EARLIER THAN "next_ms" milliseconds. We can't
        /// make any guarantees about exactness or time bounds because its possible
        /// for your OS to just... pause.. the process for an indefinite period of
        /// time.
        ///
        /// Like everything else in libxev, if you want something to repeat, you
        /// must then requeue the completion manually. This punts off one of the
        /// "hard" aspects of timers: it is up to you to determine what the semantic
        /// meaning of intervals are. For example, if you want a timer to repeat every
        /// 10 seconds, is it every 10th second of a wall clock? every 10th second
        /// after an invocation? every 10th second after the work time from the
        /// invocation? You have the power to answer these questions, manually.
        pub fn run(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            next_ms: u64,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: RunError!void,
            ) xev.CallbackAction,
        ) void {
            _ = self;

            loop.timer(c, next_ms, userdata, (struct {
                fn callback(
                    ud: ?*anyopaque,
                    l_inner: *xev.Loop,
                    c_inner: *xev.Completion,
                    r: xev.Result,
                ) xev.CallbackAction {
                    return @call(.always_inline, cb, .{
                        @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), ud)),
                        l_inner,
                        c_inner,
                        if (r.timer) |trigger| @as(RunError!void, switch (trigger) {
                            .request, .expiration => {},
                            .cancel => error.Canceled,
                        }) else |err| err,
                    });
                }
            }).callback);
        }

        /// Cancel a previously started timer. The timer to cancel used the completion
        /// "c_cancel". A new completion "c" must be specified which will be called
        /// with the callback once cancellation is complete.
        ///
        /// The original timer will still have its callback fired but with the
        /// error "error.Canceled".
        pub fn cancel(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            c_cancel: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: CancelError!void,
            ) xev.CallbackAction,
        ) void {
            _ = self;

            c.* = switch (xev.backend) {
                .io_uring => .{
                    .op = .{
                        .timer_remove = .{
                            .timer = c_cancel,
                        },
                    },

                    .userdata = userdata,
                    .callback = (struct {
                        fn callback(
                            ud: ?*anyopaque,
                            l_inner: *xev.Loop,
                            c_inner: *xev.Completion,
                            r: xev.Result,
                        ) xev.CallbackAction {
                            return @call(.always_inline, cb, .{
                                @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), ud)),
                                l_inner,
                                c_inner,
                                if (r.timer_remove) |_| {} else |err| err,
                            });
                        }
                    }).callback,
                },

                .epoll,
                .kqueue,
                .wasi_poll,
                => .{
                    .op = .{
                        .cancel = .{
                            .c = c_cancel,
                        },
                    },

                    .userdata = userdata,
                    .callback = (struct {
                        fn callback(
                            ud: ?*anyopaque,
                            l_inner: *xev.Loop,
                            c_inner: *xev.Completion,
                            r: xev.Result,
                        ) xev.CallbackAction {
                            return @call(.always_inline, cb, .{
                                @ptrCast(?*Userdata, @alignCast(@max(1, @alignOf(Userdata)), ud)),
                                l_inner,
                                c_inner,
                                if (r.cancel) |_| {} else |err| err,
                            });
                        }
                    }).callback,
                },
            };

            loop.add(c);
        }

        /// Error that could happen while running a timer.
        pub const RunError = error{
            /// The timer was canceled before it could expire
            Canceled,

            /// Some unexpected error.
            Unexpected,
        };

        pub const CancelError = xev.CancelError;

        test "timer" {
            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var timer = try init();
            defer timer.deinit();

            // Add the timer
            var called = false;
            var c1: xev.Completion = undefined;
            timer.run(&loop, &c1, 1, bool, &called, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: RunError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);

            // Wait
            try loop.run(.until_done);
            try testing.expect(called);
        }

        test "timer cancel" {
            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var timer = try init();
            defer timer.deinit();

            // Add the timer
            var canceled = false;
            var c1: xev.Completion = undefined;
            timer.run(&loop, &c1, 100_000, bool, &canceled, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: RunError!void,
                ) xev.CallbackAction {
                    ud.?.* = if (r) false else |err| err == error.Canceled;
                    return .disarm;
                }
            }).callback);

            // Cancel
            var cancel_confirm = false;
            var c2: xev.Completion = undefined;
            timer.cancel(&loop, &c2, &c1, bool, &cancel_confirm, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: CancelError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);

            // Wait
            try loop.run(.until_done);
            try testing.expect(canceled);
            try testing.expect(cancel_confirm);
        }
    };
}
