//! async_wakeup_probe.zig — #66 ①「IOCP 唤醒路径优化」证明程序
//!
//! 独立精简程序：零 libxev 依赖，仅内联声明所需 Win32 API
//! （CreateIoCompletionPort / GQCS / PQCS / QPC）。
//! 精确复刻 libxev 两层唤醒协议中「async_notify → PQCS」的关键路径，
//! 在高频 notify + 慢消费（背压）的 zo bridge 典型负载下，对比两种实现：
//!
//!   1. bool_sticky（当前 #65 状态）：wakeup.store(true) + 无条件 PQCS
//!   2. seq_counter（#66 ① 目标）：  wakeup.swap(true) 判 prev，仅首次翻转才 PQCS
//!
//! 双重验证目标：
//!   · 正确性 —— seq 版若丢唤醒，主线程会卡死在 GQCS（超时报 Stuck），
//!     程序能跑完即证明简单 swap 方案不丢唤醒；
//!   · 性能   —— 对比两种实现的 PQCS 总次数与墙钟耗时。
//!
//! 决策门槛：若 bool 版 PQCS ≈ notify 数、seq 版 PQCS ≈ 消费周期数，且
//! 墙钟差异可测，则 #66 ① 值得做；否则是伪优化。
//!
//! 用法：async_wakeup_probe.exe [mode] [total] [backlog]
//!       mode: bool_sticky | seq_counter（默认 seq_counter）

const std = @import("std");
const win = std.os.windows;

pub const std_options: std.Options = .{ .log_level = .info };

// —— 内联 Win32 声明（零 libxev 依赖）——
const HANDLE = win.HANDLE;
const DWORD = win.DWORD;
const ULONG = win.ULONG;
const ULONG_PTR = win.ULONG_PTR;
const BOOL = win.BOOL;
const FALSE: BOOL = .FALSE;
const TRUE: BOOL = BOOL.TRUE;
const INVALID_HANDLE_VALUE = win.INVALID_HANDLE_VALUE;

const OVERLAPPED = extern struct {
    Internal: ULONG_PTR = 0,
    InternalHigh: ULONG_PTR = 0,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: DWORD,
            OffsetHigh: DWORD,
        },
        Pointer: ?*anyopaque,
    } = .{ .DUMMYSTRUCTNAME = .{ .Offset = 0, .OffsetHigh = 0 } },
    hEvent: ?HANDLE = null,
};

const OVERLAPPED_ENTRY = extern struct {
    lpCompletionKey: ULONG_PTR,
    lpOverlapped: *OVERLAPPED,
    Internal: ULONG_PTR,
    dwNumberOfBytesTransferred: DWORD,
};

const kernel32 = struct {
    pub extern "kernel32" fn CreateIoCompletionPort(
        FileHandle: HANDLE,
        ExistingCompletionPort: ?HANDLE,
        CompletionKey: ULONG_PTR,
        NumberOfConcurrentThreads: DWORD,
    ) callconv(.winapi) ?HANDLE;

    pub extern "kernel32" fn GetQueuedCompletionStatusEx(
        CompletionPort: HANDLE,
        lpCompletionPortEntries: [*]OVERLAPPED_ENTRY,
        ulCount: ULONG,
        ulNumEntriesRemoved: *ULONG,
        dwMilliseconds: DWORD,
        fAlertable: BOOL,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn PostQueuedCompletionStatus(
        CompletionPort: HANDLE,
        dwNumberOfBytesTransferred: DWORD,
        dwCompletionKey: ULONG_PTR,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(.winapi) BOOL;

    pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

    pub extern "kernel32" fn ExitProcess(uExitCode: DWORD) callconv(.winapi) noreturn;
};

const ntdll = struct {
    pub extern "ntdll" fn RtlQueryPerformanceCounter(lpPerformanceCount: *win.LARGE_INTEGER) callconv(.winapi) BOOL;
    pub extern "ntdll" fn RtlQueryPerformanceFrequency(lpFrequency: *win.LARGE_INTEGER) callconv(.winapi) BOOL;
};

// —— 调参（命令行可覆盖）——
var g_total: u64 = 10_000_000; // 总 buffer 数 = notify 总次数
var g_backlog: u64 = 1000; // 背压阈值：worker 领先主线程的最大 buffer 数
var g_mode: Mode = .seq_counter;
var g_emit: EmitField = .none;

const Mode = enum { bool_sticky, seq_counter };

// 结果输出字段（通过 32-bit 退出码返回，避开 download 小文件 flush bug）
const EmitField = enum { none, pqcs, callbacks, elapsed_ms, notify, acked };

// —— 共享状态 ——
const Shared = struct {
    iocp: HANDLE,

    // completion 层 wakeup，对应 iocp.zig `Completion.op.async_wait.wakeup`
    wakeup: std.atomic.Value(bool) = .{ .raw = false },

    // worker 已 notify 的 buffer 计数 / 主线程已消费的 buffer 计数
    notify_seq: std.atomic.Value(u64) = .{ .raw = 0 },
    acked_seq: std.atomic.Value(u64) = .{ .raw = 0 },

    // 统计：PQCS 总次数 / 消费周期（callback）总次数
    pqcs: std.atomic.Value(u64) = .{ .raw = 0 },
    callbacks: std.atomic.Value(u64) = .{ .raw = 0 },
};

// —— Win32 封装 ——
fn createIocp() !HANDLE {
    return kernel32.CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 1) orelse
        error.Unexpected;
}

fn postEmptyStatus(port: HANDLE) !void {
    if (kernel32.PostQueuedCompletionStatus(port, 0, 0, null) == FALSE)
        return error.Unexpected;
}

fn gqcs(port: HANDLE, entries: []OVERLAPPED_ENTRY, timeout_ms: DWORD) !u32 {
    var removed: ULONG = 0;
    const ok = kernel32.GetQueuedCompletionStatusEx(
        port,
        entries.ptr,
        @intCast(entries.len),
        &removed,
        timeout_ms,
        FALSE,
    );
    if (ok == FALSE) {
        if (win.GetLastError() == .WAIT_TIMEOUT) return error.Timeout;
        return error.Unexpected;
    }
    return @intCast(removed);
}

fn qpcNow() u64 {
    var v: win.LARGE_INTEGER = undefined;
    if (ntdll.RtlQueryPerformanceCounter(&v) == FALSE) @panic("RtlQueryPerformanceCounter 失败");
    return @as(u64, @bitCast(v));
}

fn qpcFreq() u64 {
    var v: win.LARGE_INTEGER = undefined;
    if (ntdll.RtlQueryPerformanceFrequency(&v) == FALSE) @panic("RtlQueryPerformanceFrequency 失败");
    return @as(u64, @bitCast(v));
}

// —— async_notify：复刻 iocp.zig 的 async_notify，按 mode 分支 ——
fn asyncNotify(s: *Shared) !void {
    switch (g_mode) {
        .bool_sticky => {
            // 当前 #65 状态：无条件 store(true) + 无条件 PQCS
            s.wakeup.store(true, .seq_cst);
            try postEmptyStatus(s.iocp);
            _ = s.pqcs.fetchAdd(1, .seq_cst);
        },
        .seq_counter => {
            // #66 ① 目标：swap(true) 判 prev，仅首次 false→true 翻转才 PQCS
            const prev = s.wakeup.swap(true, .seq_cst);
            if (!prev) {
                try postEmptyStatus(s.iocp);
                _ = s.pqcs.fetchAdd(1, .seq_cst);
            }
        },
    }
}

// —— worker 线程：持续 notify，带背压 ——
fn workerMain(s: *Shared) !void {
    while (true) {
        const seq = s.notify_seq.load(.seq_cst);
        if (seq >= g_total) break;

        // 背压：领先主线程超过阈值则自旋等待
        const acked = s.acked_seq.load(.seq_cst);
        if (seq - acked >= g_backlog) {
            std.atomic.spinLoopHint();
            continue;
        }

        _ = s.notify_seq.fetchAdd(1, .seq_cst);
        try asyncNotify(s);
    }
}

// —— 主线程：GQCS 消费循环 ——
fn consume(s: *Shared) !void {
    var entries: [256]OVERLAPPED_ENTRY = undefined;

    while (true) {
        if (s.acked_seq.load(.seq_cst) >= g_total) break;

        // 阻塞等第一个 PQCS（60s 超时用于暴露丢唤醒导致的卡死）
        const n = gqcs(s.iocp, &entries, 60_000) catch |err| switch (err) {
            error.Timeout => {
                std.log.err("STUCK: 主线程 60s 未收到唤醒，疑似丢唤醒", .{});
                return error.Stuck;
            },
            else => return err,
        };
        if (n == 0) continue;

        // 非阻塞 drain：取走内核队列中所有堆积的空触发 PQCS
        while (true) {
            const m = gqcs(s.iocp, &entries, 0) catch |err| switch (err) {
                error.Timeout => 0,
                else => return err,
            };
            if (m == 0) break;
        }

        // Process asyncs：swap(false) 消费，true 则 fire callback
        if (s.wakeup.swap(false, .seq_cst)) {
            // 消费：一次性确认所有 pending buffer（对应 zo bridge callback drain 语义）
            _ = s.acked_seq.store(s.notify_seq.load(.seq_cst), .seq_cst);
            _ = s.callbacks.fetchAdd(1, .seq_cst);
        }
    }
}

fn parseMode(s: []const u8) Mode {
    if (std.mem.eql(u8, s, "bool_sticky")) return .bool_sticky;
    if (std.mem.eql(u8, s, "seq_counter")) return .seq_counter;
    std.log.err("未知 mode '{s}'，可选 bool_sticky | seq_counter", .{s});
    std.process.exit(1);
}

fn parseEmit(s: []const u8) EmitField {
    if (std.mem.eql(u8, s, "none")) return .none;
    if (std.mem.eql(u8, s, "pqcs")) return .pqcs;
    if (std.mem.eql(u8, s, "callbacks")) return .callbacks;
    if (std.mem.eql(u8, s, "elapsed_ms")) return .elapsed_ms;
    if (std.mem.eql(u8, s, "notify")) return .notify;
    if (std.mem.eql(u8, s, "acked")) return .acked;
    std.log.err("未知 emit '{s}'，可选 none|pqcs|callbacks|elapsed_ms|notify|acked", .{s});
    std.process.exit(1);
}

// 以 32-bit 退出码返回结果（std.process.exit 只接受 u8，改用 ExitProcess）
fn exitWith(code: u32) noreturn {
    kernel32.ExitProcess(code);
}

pub fn main(init: std.process.Init) !void {
    // 解析命令行：mode total backlog
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1) g_mode = parseMode(args[1]);
    if (args.len > 2) g_total = try std.fmt.parseInt(u64, args[2], 10);
    if (args.len > 3) g_backlog = try std.fmt.parseInt(u64, args[3], 10);
    if (args.len > 4) g_emit = parseEmit(args[4]);

    const iocp = try createIocp();
    defer _ = kernel32.CloseHandle(iocp);

    var s = Shared{ .iocp = iocp };

    const freq = qpcFreq();
    const t0 = qpcNow();

    const worker = try std.Thread.spawn(.{}, workerMain, .{&s});
    try consume(&s);
    worker.join();

    const t1 = qpcNow();
    const elapsed_ms: u64 = @intCast(((t1 - t0) * 1000) / freq);

    // 汇总统计
    const notify = s.notify_seq.load(.seq_cst);
    const pqcs = s.pqcs.load(.seq_cst);
    const callbacks = s.callbacks.load(.seq_cst);
    const acked = s.acked_seq.load(.seq_cst);

    const pqcs_per_notify: f64 = @as(f64, @floatFromInt(pqcs)) / @as(f64, @floatFromInt(notify));
    const pqcs_per_cb: f64 = @as(f64, @floatFromInt(pqcs)) / @as(f64, @floatFromInt(@max(callbacks, 1)));

    // 汇总打印（std.debug.print 到 stderr，便于手动运行观察）
    std.debug.print("mode={s} total={d} backlog={d} elapsed_ms={d} notify={d} pqcs={d} callbacks={d} acked={d} expect={d} verify={s}\n", .{
        @tagName(g_mode), g_total, g_backlog, elapsed_ms, notify, pqcs, callbacks, acked, g_total,
        if (acked == g_total) "OK" else "FAIL",
    });
    _ = pqcs_per_notify;
    _ = pqcs_per_cb;

    // 按 --emit 通过 32-bit 退出码返回结果
    switch (g_emit) {
        .none => {},
        .pqcs => exitWith(@intCast(pqcs)),
        .callbacks => exitWith(@intCast(callbacks)),
        .elapsed_ms => exitWith(@intCast(elapsed_ms)),
        .notify => exitWith(@intCast(notify)),
        .acked => exitWith(@intCast(acked)),
    }

    if (acked != g_total) return error.LostWakeup;
}
