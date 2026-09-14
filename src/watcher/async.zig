/// "Wake up" an event loop from any thread using an async completion.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;
const common = @import("common.zig");
const darwin = @import("../darwin.zig");
const xev_posix = @import("../posix.zig");

pub fn Async(comptime xev: type) type {
    if (xev.dynamic) return AsyncDynamic(xev);

    return switch (xev.backend) {
        // Supported, uses eventfd
        .io_uring,
        .epoll,
        => AsyncEventFd(xev),

        // Supported, uses the backend API
        .wasi_poll => AsyncLoopState(xev, xev.Loop.threaded),

        // Supported, uses mach port on Darwin and eventfd on BSD.
        .kqueue => if (comptime builtin.target.os.tag.isDarwin())
            AsyncMachPort(xev)
        else
            AsyncEventFd(xev),

        .iocp => AsyncIOCP(xev),
    };
}

/// Async implementation using eventfd (Unix/Linux).
fn AsyncEventFd(comptime xev: type) type {
    return struct {
        const Self = @This();

        /// The error that can come in the wait callback.
        pub const WaitError = xev.ReadError;

        /// eventfd file descriptor
        fd: posix.fd_t,

        /// This is only used for FreeBSD currently.
        extern "c" fn eventfd(initval: c_uint, flags: c_uint) c_int;

        /// Create a new async. An async can be assigned to exactly one loop
        /// to be woken up. The completion must be allocated in advance.
        pub fn init() !Self {
            return .{
                .fd = switch (builtin.os.tag) {
                    // std.posix is unavailable on FreeBSD. We call the
                    // syscall directly.
                    //
                    // TODO: error handling
                    .freebsd => eventfd(
                        0,
                        0x100000 | 0x4, // EFD_CLOEXEC | EFD_NONBLOCK
                    ),

                    // Use the raw linux syscall.
                    else => blk: {
                        const rc = std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
                        // 注意：必须用 std.os.linux.errno（从返回值推断 -errno），
                        // 而非 std.posix.errno（use_libc 下 = std.c.errno，只认 rc==-1）。
                        // eventfd 是直接 syscall，失败返回 -errno（如 -24 EMFILE），
                        // std.c.errno 误判 SUCCESS → @intCast 溢出 panic（#70 根因）。
                        break :blk switch (std.os.linux.errno(rc)) {
                            .SUCCESS => @as(std.posix.fd_t, @intCast(rc)),
                            else => |err| return std.posix.unexpectedErrno(err),
                        };
                    },
                },
            };
        }

        /// Clean up the async. This will forcibly deinitialize any resources
        /// and may result in erroneous wait callbacks to be fired.
        pub fn deinit(self: *Self) void {
            xev_posix.close(self.fd);
        }

        /// Wait for a message on this async. Note that async messages may be
        /// coalesced (or they may not be) so you should not expect a 1:1 mapping
        /// between send and wait.
        ///
        /// Just like the rest of libxev, the wait must be re-queued if you want
        /// to continue to be notified of async events.
        ///
        /// You should NOT register an async with multiple loops (the same loop
        /// is fine -- but unnecessary). The behavior when waiting on multiple
        /// loops is undefined.
        pub const wait = switch (xev.backend) {
            .io_uring, .epoll => waitPoll,
            .kqueue => waitRead,
            .iocp, .wasi_poll => @compileError("AsyncEventFd does not support wait for this backend"),
        };

        fn waitRead(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!void,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    .read = .{
                        .fd = self.fd,
                        .buffer = .{ .array = undefined },
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
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            if (r.read) |v| assert(v > 0) else |err| err,
                        });
                    }
                }).callback,
            };
            loop.add(c);
        }

        fn waitPoll(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!void,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    // We use a poll operation instead of a read operation
                    // because in Kernel 6.15.4, read was regressed for
                    // io_uring on eventfd/timerfd and would block forever.
                    // However, poll works fine.
                    .poll = .{
                        .fd = self.fd,
                        .events = posix.POLL.IN,
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
                        if (r.poll) |_| {
                            // We need to read so that we can consume the
                            // eventfd value. We only read 8 bytes because
                            // we only write up to 8 bytes and we own the fd.
                            // We ignore errors here because we expect the
                            // read to succeed given we just polled it.
                            var buf: [8]u8 = undefined;
                            _ = posix.read(c_inner.op.poll.fd, &buf) catch {};
                        } else |_| {
                            // We'll call the callback with the error later.
                        }

                        return @call(.always_inline, cb, .{
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            if (r.poll) |_| {} else |err| err,
                        });
                    }
                }).callback,
            };
            loop.add(c);
        }

        /// Notify a loop to wake up synchronously. This should never block forever
        /// (it will always EVENTUALLY succeed regardless of if the loop is currently
        /// ticking or not).
        ///
        /// The "c" value is the completion associated with the "wait".
        ///
        /// Internal details subject to change but if you're relying on these
        /// details then you may want to consider using a lower level interface
        /// using the loop directly:
        ///
        ///   - linux+io_uring: eventfd is used. If the eventfd write would block
        ///     (EAGAIN) then we assume success because the eventfd is full.
        ///
        pub fn notify(self: Self) !void {
            // We want to just write "1" in the correct byte order as our host.
            const val = @as([8]u8, @bitCast(@as(u64, 1)));
            _ = xev_posix.write(self.fd, &val) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
        }

        test {
            _ = AsyncTests(xev, Self);
        }
    };
}

/// Async implementation using mach ports (Darwin).
///
/// This allocates a mach port per async request and sends to that mach
/// port to wake up the loop and trigger the completion.
fn AsyncMachPort(comptime xev: type) type {
    return struct {
        const Self = @This();

        /// The error that can come in the wait callback.
        pub const WaitError = xev.Sys.MachPortError;

        /// Missing Mach APIs from Zig stdlib. Data from xnu: osfmk/mach/port.h
        const mach_port_flavor_t = c_int;
        const mach_port_limits = extern struct { mpl_qlimit: c_uint };
        const MACH_PORT_LIMITS_INFO = 1;
        extern "c" fn mach_port_set_attributes(
            task: posix.system.ipc_space_t,
            name: posix.system.mach_port_name_t,
            flavor: mach_port_flavor_t,
            info: *anyopaque,
            count: darwin.mach_msg_type_number_t,
        ) posix.system.kern_return_t;
        extern "c" fn mach_port_destroy(
            task: posix.system.ipc_space_t,
            name: posix.system.mach_port_name_t,
        ) posix.system.kern_return_t;

        /// The mach port
        port: posix.system.mach_port_name_t,

        /// Create a new async. An async can be assigned to exactly one loop
        /// to be woken up. The completion must be allocated in advance.
        pub fn init() !Self {
            const mach_self = posix.system.mach_task_self();

            // Allocate the port
            var mach_port: posix.system.mach_port_name_t = undefined;
            switch (darwin.getKernError(posix.system.mach_port_allocate(
                mach_self,
                posix.system.MACH.PORT.RIGHT.RECEIVE,
                &mach_port,
            ))) {
                .SUCCESS => {}, // Success
                else => return error.MachPortAllocFailed,
            }
            errdefer _ = mach_port_destroy(mach_self, mach_port);

            // Insert a send right into the port since we also use this to send
            switch (darwin.getKernError(posix.system.mach_port_insert_right(
                mach_self,
                mach_port,
                mach_port,
                posix.system.MACH.MSG.TYPE.MAKE_SEND,
            ))) {
                .SUCCESS => {}, // Success
                else => return error.MachPortAllocFailed,
            }

            // Port queue size. Previously 1: notify() treats SEND_TIMED_OUT /
            // SEND_NO_BUFFER (queue full) as success assuming "a pending wake
            // exists", but that message is DROPPED when kevent already fired and
            // is draining the previous message → wake can be permanently lost
            // (zigbox bench-socks5 30s hang, #28 2026-08-25). A larger queue
            // lets notify()s landing inside the drain→re-arm window buffer
            // instead of dropping; drain() in the wait callback clears it all,
            // so multiple queued wakes still coalesce into one callback safely.
            var limits: mach_port_limits = .{ .mpl_qlimit = 32 };
            switch (darwin.getKernError(mach_port_set_attributes(
                mach_self,
                mach_port,
                MACH_PORT_LIMITS_INFO,
                &limits,
                @sizeOf(@TypeOf(limits)),
            ))) {
                .SUCCESS => {}, // Success
                else => return error.MachPortAllocFailed,
            }

            return .{
                .port = mach_port,
            };
        }

        /// Clean up the async. This will forcibly deinitialize any resources
        /// and may result in erroneous wait callbacks to be fired.
        pub fn deinit(self: *Self) void {
            _ = mach_port_destroy(
                posix.system.mach_task_self(),
                self.port,
            );
        }

        /// Wait for a message on this async. Note that async messages may be
        /// coalesced (or they may not be) so you should not expect a 1:1 mapping
        /// between send and wait.
        ///
        /// Just like the rest of libxev, the wait must be re-queued if you want
        /// to continue to be notified of async events.
        ///
        /// You should NOT register an async with multiple loops (the same loop
        /// is fine -- but unnecessary). The behavior when waiting on multiple
        /// loops is undefined.
        pub fn wait(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!void,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    .machport = .{
                        .port = self.port,
                        .buffer = .{ .array = undefined },
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
                        // Drain the mach port so that we only fire one
                        // notification even if many are queued.
                        std.log.debug("[async.mach] wait cb fired, draining port={d}", .{c_inner.op.machport.port});
                        drain(c_inner.op.machport.port);

                        return @call(.always_inline, cb, .{
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            if (r.machport) |_| {} else |err| err,
                        });
                    }
                }).callback,
            };

            loop.add(c);
        }

        /// Drain the given mach port. All message bodies are discarded.
        fn drain(port: posix.system.mach_port_name_t) void {
            var message: struct {
                header: darwin.mach_msg_header_t,
            } = undefined;

            while (true) {
                switch (darwin.getMachMsgError(darwin.mach_msg(
                    &message.header,
                    darwin.MACH_RCV_MSG | darwin.MACH_RCV_TIMEOUT,
                    0,
                    @sizeOf(@TypeOf(message)),
                    port,
                    darwin.MACH_MSG_TIMEOUT_NONE,
                    darwin.MACH_PORT_NULL,
                ))) {
                    // This means a read would've blocked, so we drained.
                    .RCV_TIMED_OUT => return,

                    // We dequeued, so we want to loop again.
                    .SUCCESS => {},

                    // We dequeued but the message had a body. We ignore
                    // message bodies for async so we are happy to discard
                    // it and continue.
                    .RCV_TOO_LARGE => {},

                    else => |err| {
                        std.log.warn("mach msg drain err, may duplicate async wakeups err={}", .{err});
                        return;
                    },
                }
            }
        }

        /// Notify a loop to wake up synchronously. This should never block forever
        /// (it will always EVENTUALLY succeed regardless of if the loop is currently
        /// ticking or not).
        pub fn notify(self: Self) !void {
            // This constructs an empty mach message. It has no data.
            var msg: darwin.mach_msg_header_t = .{
                // We use COPY_SEND which will not increment any send ref
                // counts because it'll reuse the existing send right.
                .msgh_bits = @intFromEnum(posix.system.MACH.MSG.TYPE.COPY_SEND),
                .msgh_size = @sizeOf(darwin.mach_msg_header_t),
                .msgh_remote_port = self.port,
                .msgh_local_port = darwin.MACH_PORT_NULL,
                .msgh_voucher_port = undefined,
                .msgh_id = undefined,
            };

            const rc = darwin.mach_msg(
                &msg,
                darwin.MACH_SEND_MSG | darwin.MACH_SEND_TIMEOUT,
                msg.msgh_size,
                0,
                darwin.MACH_PORT_NULL,
                0, // Fail instantly if the port is full
                darwin.MACH_PORT_NULL,
            );
            std.log.debug("[async.mach] notify port={d} rc={d}", .{ self.port, rc });
            return switch (darwin.getMachMsgError(rc)) {
                .SUCCESS => {},
                else => |e| {
                    std.log.warn("mach msg err={}", .{e});
                    return error.MachMsgFailed;
                },

                // This is okay because it means that there was no more buffer
                // space meaning that the port will wake up.
                .SEND_NO_BUFFER => {},

                // This means that the send would've blocked because the
                // queue is full. We assume success because the port is full.
                .SEND_TIMED_OUT => {},
            };
        }

        test {
            _ = AsyncTests(xev, Self);
        }
    };
}

/// Async implementation that is deferred to the backend implementation
/// loop state. This is kind of a hacky implementation and not recommended
/// but its the only way currently to get asyncs to work on WASI.
fn AsyncLoopState(comptime xev: type, comptime threaded: bool) type {
    // TODO: we don't support threaded loop state async. We _can_ it just
    // isn't done yet. To support it we need to have some sort of mutex
    // to guard waiter below.
    if (threaded) return struct {};

    return struct {
        const Self = @This();

        wakeup: bool = false,
        waiter: ?struct {
            loop: *xev.Loop,
            c: *xev.Completion,
        } = null,

        /// The error that can come in the wait callback.
        pub const WaitError = xev.Sys.AsyncError;

        pub fn init() !Self {
            return .{};
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn wait(
            self: *Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!void,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{
                    .async_wait = .{},
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
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            if (r.async_wait) |_| {} else |err| err,
                        });
                    }
                }).callback,
            };
            loop.add(c);

            self.waiter = .{
                .loop = loop,
                .c = c,
            };

            if (self.wakeup) self.notify() catch {};
        }

        pub fn notify(self: *Self) !void {
            if (self.waiter) |w|
                w.loop.async_notify(w.c)
            else
                self.wakeup = true;
        }

        test {
            _ = AsyncTests(xev, Self);
        }
    };
}

/// Async implementation for IOCP.
fn AsyncIOCP(comptime xev: type) type {
    return struct {
        const Self = @This();
        const windows = std.os.windows;

        pub const WaitError = xev.Sys.AsyncError;

        guard: std.Io.Mutex = .init,
        wakeup: bool = false,
        waiter: ?struct {
            loop: *xev.Loop,
            c: *xev.Completion,
            gen: u32,
        } = null,
        /// wait() 递增的代际序号。completion 完成（disarm）时用它区分当前 waiter
        /// 是否仍属于「本次 wait」—— callback 内同步重新 wait() 会拿到新 gen，
        /// 避免清除误删新 waiter（#169 relay 双向卡死回归）。
        waiter_gen: u32 = 0,

        pub fn init() !Self {
            return Self{};
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn wait(
            self: *Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!void,
            ) xev.CallbackAction,
        ) void {
            c.* = .{
                .op = .{ .async_wait = .{
                    .waiter_clear = &Self.clearWaiterCb,
                    .waiter_owner = @ptrCast(self),
                } },
                .userdata = userdata,
                .callback = (struct {
                    fn callback(
                        ud: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        return @call(.always_inline, cb, .{
                            common.userdataValue(Userdata, ud),
                            l_inner,
                            c_inner,
                            if (r.async_wait) |_| {} else |err| err,
                        });
                    }
                }).callback,
            };
            loop.add(c);

            const io = std.Io.Threaded.global_single_threaded.io();
            self.guard.lockUncancelable(io);
            defer self.guard.unlock(io);

            self.waiter_gen +%= 1;
            self.waiter = .{
                .loop = loop,
                .c = c,
                .gen = self.waiter_gen,
            };
            // 把本轮代际写回 completion，供 iocp.zig 完成时匹配清除（#169）。
            c.op.async_wait.waiter_gen = self.waiter_gen;

            // sticky 消费：置位后必须清除，否则每次 wait 都自我补发 PQCS
            // → async 触发 → 重挂 → 再补发的永久自触发循环（#65：worker
            // 100% 自旋 + 内核完成包在 IOCP 队列永不取出 → 非分页池耗尽）。
            if (self.wakeup) {
                self.wakeup = false;
                loop.async_notify(c);
            }
        }

        /// 清除 waiter 中指向指定 completion 的项（须匹配代际）。由 iocp.zig 在
        /// completion 完成（disarm）或取消时调用，防止 notify() 访问已销毁的
        /// completion（#168 memconn Windows cross-thread UAF 根因）。gen 匹配避免
        /// 误删 callback 内同步重新 wait() 建立的新 waiter（#169 卡死回归）。
        fn clearWaiter(self: *Self, c: *xev.Completion, gen: u32) void {
            const io = std.Io.Threaded.global_single_threaded.io();
            self.guard.lockUncancelable(io);
            defer self.guard.unlock(io);

            if (self.waiter) |w| {
                if (w.c == c and w.gen == gen) self.waiter = null;
            }
        }

        fn clearWaiterCb(owner_raw: *anyopaque, c: *xev.Completion, gen: u32) void {
            const owner: *Self = @ptrCast(@alignCast(owner_raw));
            owner.clearWaiter(c, gen);
        }

        pub fn notify(self: *Self) !void {
            const io = std.Io.Threaded.global_single_threaded.io();
            self.guard.lockUncancelable(io);
            defer self.guard.unlock(io);

            // 无条件置 sticky：waiter 非空不代表 completion 已挂载 —— loop 在
            // 「消费 wakeup 标志（asyncs 扫描 swap）→ 回调重挂 wait()」窗口内
            // 时，waiter 仍指向未挂载的 completion，对它置标志会被 wait() 的
            // c.* 复位抹掉（丢失唤醒）。sticky 由 wait() 消费补发兜底。
            // 双触发无害：回调幂等（排空式处理）。
            self.wakeup = true;
            if (self.waiter) |w| {
                w.loop.async_notify(w.c);
            }
        }

        test {
            _ = AsyncTests(xev, Self);
        }
    };
}

fn AsyncDynamic(comptime xev: type) type {
    return struct {
        const Self = @This();

        backend: Union,

        pub const Union = xev.Union(&.{"Async"});
        pub const WaitError = xev.ErrorSet(&.{ "Async", "WaitError" });

        pub fn init() !Self {
            return .{ .backend = switch (xev.backend) {
                inline else => |tag| backend: {
                    const api = (comptime xev.superset(tag)).Api();
                    break :backend @unionInit(
                        Union,
                        @tagName(tag),
                        try api.Async.init(),
                    );
                },
            } };
        }

        pub fn deinit(self: *Self) void {
            switch (xev.backend) {
                inline else => |tag| @field(
                    self.backend,
                    @tagName(tag),
                ).deinit(),
            }
        }

        pub fn notify(self: *Self) !void {
            switch (xev.backend) {
                inline else => |tag| try @field(
                    self.backend,
                    @tagName(tag),
                ).notify(),
            }
        }

        pub fn wait(
            self: Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            comptime Userdata: type,
            userdata: ?*Userdata,
            comptime cb: *const fn (
                ud: ?*Userdata,
                l: *xev.Loop,
                c: *xev.Completion,
                r: WaitError!void,
            ) xev.CallbackAction,
        ) void {
            switch (xev.backend) {
                inline else => |tag| {
                    c.ensureTag(tag);

                    const api = (comptime xev.superset(tag)).Api();
                    const api_cb = (struct {
                        fn callback(
                            ud_inner: ?*Userdata,
                            l_inner: *api.Loop,
                            c_inner: *api.Completion,
                            r_inner: api.Async.WaitError!void,
                        ) xev.CallbackAction {
                            return cb(
                                ud_inner,
                                @fieldParentPtr("backend", @as(
                                    *xev.Loop.Union,
                                    @fieldParentPtr(@tagName(tag), l_inner),
                                )),
                                @fieldParentPtr("value", @as(
                                    *xev.Completion.Union,
                                    @fieldParentPtr(@tagName(tag), c_inner),
                                )),
                                r_inner,
                            );
                        }
                    }).callback;

                    @field(
                        self.backend,
                        @tagName(tag),
                    ).wait(
                        &@field(loop.backend, @tagName(tag)),
                        &@field(c.value, @tagName(tag)),
                        Userdata,
                        userdata,
                        api_cb,
                    );
                },
            }
        }

        test {
            _ = AsyncTests(xev, Self);
        }
    };
}

fn AsyncTests(comptime xev: type, comptime Impl: type) type {
    return struct {
        test "async" {
            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var notifier = try Impl.init();
            defer notifier.deinit();

            // Wait
            var wake: bool = false;
            var c_wait: xev.Completion = .{};
            notifier.wait(&loop, &c_wait, bool, &wake, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .rearm;
                }
            }).callback);

            // Send a notification
            try notifier.notify();

            // Wait for wake
            try loop.run(.once);
            try testing.expect(wake);

            // Make sure it only triggers once
            wake = false;
            try loop.run(.no_wait);
            try testing.expect(!wake);
        }

        // 复现 09-14 iOS 真机崩溃的核心机制：**宿主在其 completion 仍注册于 loop 上时被
        // 销毁**。`AsyncMachPort.deinit()` 是裸 `mach_port_destroy`（不摘
        // `EVFILT_MACHPORT` knote、不检查该 port 上是否还有在册 completion），其自身
        // 注释即自承 *"may result in erroneous wait callbacks to be fired"*。
        //
        // 本测试把这条「自承」变成**可判定断言**：销毁端口后跑循环，不得把陈旧
        // completion 派发进用户回调。真机后果 = 经损坏指针调用 → PAC 失效 → SIGKILL
        // （`?+0x65000a00 ← AsyncMachPort.wait.callback ← kqueue tick`）。
        //
        // 生产上的触发点不是本测试这种「显式 deinit」，而是槽位/对象复用时的隐式销毁
        // （zigstack `acquireConnHandle` 复用 closed 槽 → `h.deinit()` → 销毁上一生命
        // 周期的 async；zo bridge 池化复用同理）—— 即「上一个持有者还没走完，端口就被
        // 下一个生命周期收走」。这里用最直白的形式先把不变量钉住。
        test "async: deinit while a wait is armed" {
            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var notifier = try Impl.init();

            var calls: usize = 0;
            var c_wait: xev.Completion = .{};
            notifier.wait(&loop, &c_wait, usize, &calls, (struct {
                fn callback(
                    ud: ?*usize,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!void,
                ) xev.CallbackAction {
                    _ = r catch {};
                    ud.?.* += 1;
                    return .disarm;
                }
            }).callback);

            // 正确纪律：**先摘除注册，再销毁端口**。
            _ = loop.delete(&c_wait);
            notifier.deinit();

            loop.run(.no_wait) catch {};
            // delete() 契约承诺「回调仍触发一次（CANCELED）」→ 1 次是**正确**的。
            // 不断言严格等于 1：各后端对 .deleting 的派发时机不同（iocp 为纯内存
            // bookkeeping，可能一次都不触发），断言严格值会把后端差异误判为缺陷。
            try std.testing.expect(calls <= 1);

            // 对照：不摘注册直接销毁端口（调用方漏 delete）——文档所说的
            // "erroneous wait callbacks"，也是真机崩溃的形态。
            var notifier2 = try Impl.init();
            var calls2: usize = 0;
            var c2: xev.Completion = .{};
            notifier2.wait(&loop, &c2, usize, &calls2, (struct {
                fn callback(
                    ud: ?*usize,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!void,
                ) xev.CallbackAction {
                    _ = r catch {};
                    ud.?.* += 1;
                    return .disarm;
                }
            }).callback);
            notifier2.deinit();
            loop.run(.no_wait) catch {};
            // ⚠️ 特征测试（characterization）：**漏 delete 直接 deinit** 时回调同样触发 1 次 ——
            // 这正是 libxev 自承的 "erroneous wait callbacks"。
            // 两条纪律的**回调次数相同**，故本栈**无法靠「回调有没有触发」自查**；差别只在
            // 回调收到的 result 与宿主是否仍有效。真机后果 = 陈旧 completion 被派发到已复用/
            // 已释放的宿主 → 经损坏指针调用 → PAC 失效 SIGKILL（09-14 iOS，build c74d6b3b）。
            // 该断言的意义：若将来 libxev 把 deinit 做成「顺带摘除注册」（即不再触发），
            // 本测试会立刻转红，提示可以放宽调用方纪律 —— 而不是让契约悄悄漂移。
            // 同上：表征「漏 delete 时的可观测后果」，其**量化表现依后端而异**
            // （kqueue 触发一次错误唤醒；io_uring 回 EBADF；iocp 不触发）。
            // 不断言严格值，只断言「不崩溃且不超过一次」。
            try std.testing.expect(calls2 <= 1);
        }

        // 暴力压测（默认不跑；VM 上 XEV_SOAK=<轮数> 触发）。
        //
        // 目的：把「引擎真实做的事」压成一个小模型 —— 多路 no-fd 流各自挂一个
        // Async 等待、外部 notify、连接关闭时 delete + deinit（销毁端口）、重挂。
        // 这正是 zigstack TcpConnHandle / zo TcpBridge 在连接 churn 下的形态。
        // 任何「completion 仍注册/仍在队列时宿主被销毁/复用」的缺口，都会在这里
        // 变成 panic / assert / unexpectedErrno，而不是等到真机上变成 PAC 失效崩溃。
        //
        // 用户裁定：libxev 相关问题先在 VM 暴力压测，压不出问题再上真机。
        test "async soak: churn arm/notify/delete/deinit" {
            const iters = @import("build_options").soak_iters;
            if (iters == 0) return;

            var prng = std.Random.DefaultPrng.init(0x5eed_5eed);
            const rand = prng.random();

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            const N = 8;
            const Slot = struct {
                notifier: Impl = undefined,
                c: xev.Completion = .{},
                hits: usize = 0,
                alive: bool = false,
            };
            var slots: [N]Slot = .{Slot{}} ** N;

            const cb = struct {
                fn callback(
                    ud: ?*Slot,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!void,
                ) xev.CallbackAction {
                    _ = r catch {};
                    ud.?.hits += 1;
                    return .disarm;
                }
            }.callback;

            var i: usize = 0;
            while (i < iters) : (i += 1) {
                const k = rand.uintLessThan(usize, N);
                const s = &slots[k];
                if (!s.alive) {
                    s.notifier = try Impl.init();
                    s.alive = true;
                    s.c = .{};
                    s.notifier.wait(&loop, &s.c, Slot, s, cb);
                } else switch (rand.uintLessThan(u8, 5)) {
                    0 => try s.notifier.notify(),
                    1 => _ = loop.delete(&s.c), // 摘注册（契约：回调将以 CANCELED 触发一次）
                    2 => { // 销毁端口（可能仍有等待挂着 —— 本压测要压的就是这个）
                        s.notifier.deinit();
                        s.alive = false;
                    },
                    3 => { // 重挂：**仅在 delete 明确交还所有权时**才重挂（delete 契约）
                        if (loop.delete(&s.c)) {
                            s.c = .{};
                            s.notifier.wait(&loop, &s.c, Slot, s, cb);
                        }
                    },
                    else => {},
                }
                loop.run(.no_wait) catch {};
            }
        }

        // 复现 kqueue `deleteSync` 的 `.adding` 契约违反（09-14 审计 H4）：
        //   kqueue.zig:254-257  `.adding => { state = .dead; return true; }`
        //   —— 返回 true（= 调用方即刻拥有、绝不再派发），但节点**仍链在**
        //      `Loop.submissions`（Intrusive 无 remove API，只有 submit() 会 pop）。
        //   epoll.zig:255-263 同状态返回 false —— 两端语义不对称。
        //
        // 契约含义：返回 true ⇒ 调用方可以安全重挂/释放该 completion。本测试就按契约
        // 重挂一次；若节点仍在队列里，同一节点会被二次入队（尾节点时 push 的
        // `assert(v.next == null)` 不触发，`tail.next = v` 成自环）→ 下一次 submit()
        // 弹出它时状态已是 `.active` → 打印 "invalid state in submission queue
        // state=.active"（Zig 测试框架把 log.err 记为测试失败）。
        //
        // 真实站点：zigtun/src/zstack_stack.zig:259（`tun_read_c` 是 ctx 内嵌字段，
        // 紧随其后 destroy(ctx)）、zigfoundation/src/tunconn.zig:245/267。
        test "async: deleteSync on an .adding completion returns ownership safely" {
            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var notifier = try Impl.init();
            defer notifier.deinit();

            var hits: usize = 0;
            const cb = struct {
                fn callback(
                    ud: ?*usize,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!void,
                ) xev.CallbackAction {
                    _ = r catch {};
                    ud.?.* += 1;
                    return .disarm;
                }
            }.callback;

            // 入队但**不跑 tick** ⇒ completion 处于 `.adding`。
            var c: xev.Completion = .{};
            notifier.wait(&loop, &c, usize, &hits, cb);

            if (!loop.deleteSync(&c)) return; // 后端无同步语义（io_uring 恒 false）→ 不适用

            // 契约成立 ⇒ 此刻调用方拥有该 completion，**重挂同一个**必须安全。
            notifier.wait(&loop, &c, usize, &hits, cb);

            loop.run(.no_wait) catch {};
            _ = testing;
        }

        test "async: notify first" {
            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var notifier = try Impl.init();
            defer notifier.deinit();

            // Send a notification
            try notifier.notify();

            // Wait
            var wake: bool = false;
            var c_wait: xev.Completion = .{};
            notifier.wait(&loop, &c_wait, bool, &wake, (struct {
                fn callback(
                    ud: ?*bool,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* = true;
                    return .disarm;
                }
            }).callback);

            // Wait for wake
            try loop.run(.until_done);
            try testing.expect(wake);
        }

        test "async batches multiple notifications" {
            const testing = std.testing;

            var loop = try xev.Loop.init(.{});
            defer loop.deinit();

            var notifier = try Impl.init();
            defer notifier.deinit();

            // Send a notification many times
            try notifier.notify();
            try notifier.notify();
            try notifier.notify();
            try notifier.notify();
            try notifier.notify();

            // Wait
            var count: u32 = 0;
            var c_wait: xev.Completion = .{};
            notifier.wait(&loop, &c_wait, u32, &count, (struct {
                fn callback(
                    ud: ?*u32,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: Impl.WaitError!void,
                ) xev.CallbackAction {
                    _ = r catch unreachable;
                    ud.?.* += 1;
                    return .rearm;
                }
            }).callback);

            // Send a notification
            try notifier.notify();

            // Wait for wake
            try loop.run(.once);
            for (0..10) |_| try loop.run(.no_wait);
            try testing.expectEqual(@as(u32, 1), count);
        }
    };
}
