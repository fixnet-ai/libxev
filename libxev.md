# libxev 使用技巧与注意事项

本文档记录项目中使用 [libxev](https://github.com/mitchellh/libxev) 积累的经验和踩过的坑。

## 架构概览

libxev 是编译时后端选择的异步事件循环库：

```
xev.Loop  →  kqueue (macOS) / epoll (Linux) / io_uring (Linux) / IOCP (Windows)
```

本项目使用 libxev 的**静态 API**：所有操作（TCP、UDP、Timer）通过 `xev.Loop` 调度，回调在事件循环线程中同步执行。

## 核心类型

| 类型 | 用途 |
|------|------|
| `xev.Loop` | 事件循环，`init(.{})` → `run(.until_done)` → `deinit()` |
| `xev.Completion` | 操作句柄，代表一个已提交的异步操作。用 `.{ }` 初始化 |
| `xev.CallbackAction` | 回调返回值：`.disarm` 停止，`.rearm` 继续 |
| `xev.TCP` | TCP 连接（accept / connect / read / write / close） |
| `xev.UDP` | UDP socket（init / read / write / close） |
| `xev.Timer` | 定时器（run / reset / cancel） |

## Completion 管理

### 初始化和重用

```zig
// 初始化为空 completion
var c: xev.Completion = .{};

// 传递给异步操作后，completion 被 loop 持有
// 回调触发后，completion 被"释放"，可以安全复用
self.socket.read(loop, &self.recv_c, ...); // 复用同一个 recv_c
```

### 关键规则

1. **不要在 completion 仍活跃时复用它**。回调还没触发就不能传给新的操作。
2. **Completion 可以原地复用**：回调触发后，可以在回调内部再次使用同一个 completion 提交新操作（如 recv 循环）。
3. **不同操作使用不同 completion**：不能把正在等待 TCP read 的 completion 同时用于 TCP write。

## 回调约定

### 标准回调签名

```zig
fn callback(
    ud: ?*Userdata,       // 用户数据指针
    l: *xev.Loop,         // 事件循环
    c: *xev.Completion,   // 触发本次回调的 completion
    // ... 操作相关参数 ...
    result: XxxError!T,   // 结果或错误
) xev.CallbackAction
```

### 必须遵守的规则

1. **检查 `ud` 是否为 null**，null 时返回 `.disarm`：
   ```zig
   const self = ud orelse return .disarm;
   ```

2. **大部分回调返回 `.disarm`**（不自动重新提交）。需要对同一 socket 继续读/写时，手动调用新的 async 操作。

3. **禁止在回调中进行阻塞操作**。回调在事件循环线程中执行，阻塞会拖死整个事件循环。

## ⚠️ 致命陷阱：close() 的正确用法

### 核心认知

**所有 libxev 后端的 `close()` 都是同步的**——`close(fd)` / `rawCloseHandle(fd)` 在 `start_completion()` 中直接调用，不经过异步 SQE/CQE。

关键区别在于**执行线程**：

| 后端 | close 执行位置 | 需要 ThreadPool |
|------|---------------|----------------|
| kqueue | ThreadPool 工作线程 | **是** |
| epoll | ThreadPool 工作线程 | **是** |
| io_uring | 事件循环线程（同步 `close(fd)`） | 否 |
| IOCP | 事件循环线程（同步 `rawCloseHandle`） | 否 |

kqueue/epoll 需要 ThreadPool 的原因：`stream.zig` 在构造 close Completion 时设置 `c.flags.threadpool = true`（第 434-436 行）。因为 `close(fd)` 可能阻塞（SO_LINGER + 发送缓冲区数据），不适合在事件循环线程执行。

### 致命场景：ThreadPool 缺失导致静默 fd 泄漏

```
1. zigbox 创建 Loop 时未传 ThreadPool
2. Session 关闭时调用 TCP.close()
3. stream.zig 设置 flags.threadpool = true
4. start_completion() 检测到需要 ThreadPool 但未提供
5. 返回 error.ThreadPoolRequired
6. 回调 onCloseComplete 的参数 _: xev.CloseError!void 静默丢弃错误
7. TCP socket 从未关闭 → fd 泄漏 → 客户端超时
```

**症状**：连接永远不关闭，客户端挂起直到超时。`lsof -p <pid>` 显示 fd 数量持续增长。

**此问题的唯一正确修复是调用方提供 ThreadPool。**

### 规则一：必须提供 ThreadPool

```zig
// ✅ 正确：创建 ThreadPool 并传入 Loop.init()
var thread_pool = xev.ThreadPool.init(.{});
defer thread_pool.deinit();
defer thread_pool.shutdown();

var loop = try xev.Loop.init(.{ .thread_pool = &thread_pool });
```

`ThreadPool.init(.{})` 返回配置结构体（零分配），线程延迟创建。Loop 持有指针，只要 ThreadPool 在 Loop 生命周期内有效即可。zigbox `main()` 中栈分配足够，无需堆分配。

IOCP / io_uring 后端的 close 不需要 ThreadPool，但传入也无副作用——未使用时不会启动工作线程。

### 规则二：close 使用独立 Completion

```zig
// Session 结构
client_c: xev.Completion,        // read/write 专用
client_close_c: xev.Completion,  // close 专用
remote_c: xev.Completion,
remote_close_c: xev.Completion,

// shutdown：用 close 专用 completion
self.client.close(l, &self.client_close_c, Self, self, onCloseComplete);

// onCloseComplete：通过 c 指针区分哪个 close 完成
fn onCloseComplete(ud, l, c, ...) {
    if (c == &self.client_close_c) {
        // client 关闭完成 → 链式关闭 remote（若活跃）
        if (self.close_pending.remote) {
            self.remote.close(l, &self.remote_close_c, Self, self, onCloseComplete);
            return .disarm;
        }
    } else if (c == &self.remote_close_c) {
        // remote 关闭完成
    } else return .disarm;
    // 两个都关闭完成 → deferred_free 或 destroy
}
```

不复用读写 completion 的原因：读/写 completion 正在活跃使用中（已提交到事件循环等待 I/O），用同一个 completion 调用 close 会覆写活跃状态，导致读/写回调或 close 回调被错误触发。

### 规则三：close() 返回后不访问 self

close 可能在同一 tick 内通过 completions 队列同步触发回调，`onCloseComplete` 可能在 `close()` 返回前已调用 `destroySession`。

```zig
// ✅ 正确：close 决策存到局部变量
const do_remote = self.remote_active;
if (do_remote) self.close_pending.remote = true;

self.client.close(l, &self.client_close_c, Self, self, onCloseComplete);
// ⚠️ 此后绝不访问 self — onCloseComplete 可能已释放它

if (do_remote) {
    // self 仍有效 — 两个 close 都 pending 时 onCloseComplete 不会释放
    self.remote.close(l, &self.remote_close_c, Self, self, onCloseComplete);
}
```

### 规则四：严格状态机 + 唯一关闭入口

```zig
close_pending: packed struct {
    client: bool = false,
    remote: bool = false,
    released: bool = false,
} = .{},

fn shutdown(self: *Self, l: *xev.Loop) void {
    if (self.state == .closing) return;                // 幂等
    if (self.state == .resolving) self.server.dns.cancel(self);  // 取消 DNS
    self.state = .closing;
    // 释放缓冲区（先于 close_pending 设置，见下方时序说明）
    self.close_pending.client = true;
    if (self.remote_active) self.close_pending.remote = true;
    self.client.close(l, &self.client_close_c, Self, self, onCloseComplete);
}
```

**所有回调**第一行检查关闭状态：`if (self.state == .closing) return .disarm;` 或 `if (self.close_pending.client or self.close_pending.remote) return .disarm;`

**所有错误路径**调用 `shutdown()`，不直接调 `close()`。

**不要用 `close_count` 计数器**——用 `packed struct` 的布尔标志，不可能溢出。`close_pending` 标志**永远不清除**（IOCP 需要它们作为陈旧完成项的永久防护）。

### close_pending 与缓冲区释放时序

**先释放缓冲区，再设置 close_pending**。此顺序对缓冲区池回收至关重要：

```zig
fn shutdown(self: *RelaySession, l: *xev.Loop) void {
    if (self.close_pending.client or self.close_pending.remote) return;
    // 1. 先释放缓冲区 — 此时读写回调尚未被 close_pending 阻挡
    if (self.client_buf) |b| {
        self.server.pool.release(b);
        self.client_buf = null;
    }
    if (self.remote_buf) |b| {
        self.server.pool.release(b);
        self.remote_buf = null;
    }
    self.server.maybeStartShrinkTimer(l);
    // 2. 最后设置 close_pending — 此后读/写回调检查 close_pending 返回 .disarm
    self.close_pending.client = true;
    if (self.remote_active) self.close_pending.remote = true;
    // 3. 直接关闭（仅 client，remote 在 onCloseComplete 中链式关闭）
    self.client.close(l, &self.client_close_c, RelaySession, self, onCloseComplete);
}
```

**为什么顺序重要**：单线程事件循环保证 `shutdown()` 执行期间不会有并发的读/写回调。如果先设 close_pending 再释放，回调中的 release 会被跳过，缓冲区永不归还。

### 规则五：IOCP 延迟释放（deferred free）

**仅适用于 IOCP 后端。** kqueue/epoll/io_uring 不需要此机制——`close(fd)` 后 OS 自动清理该 fd 上的所有待处理事件。

**问题**：IOCP 后端 `tick()` 的处理顺序是**内部完成队列优先于 IOCP 完成队列**：

```
tick() {
    submit();                          // close 操作在此同步完成
    while (true) {
        1. 处理 Timer 回调
        2. 处理内部 Completion 队列      // ← close 完成项在此触发！
        3. 处理 Asyncs
        4. GetQueuedCompletionStatusEx   // ← 取消的 I/O 完成项在此拿到
        5. 处理 IOCP 完成项             // ← 取消的读/写比 close 晚！
    }
}
```

由于 IOCP 的 close 是**同步**的（`perform()` 中直接调 `CloseHandle`/`closesocket`），关闭 socket 时取消的 I/O 完成项与 close 完成项在**同一次 tick** 中可用，但 close 完成项在步骤 2 先触发，取消的 I/O 完成项在步骤 5 后触发。

如果 close 回调中**清除 `close_pending` + 立即释放/归还池**，则步骤 5 的陈旧 I/O 完成项会访问已释放内存 → use-after-free。

**正确做法**：`close_pending` 永久不清除，close 完成后加入 `deferred_free` 链表，由心跳回调（200ms，步骤 1）在下一次触发时释放/归还池。此时步骤 5 的陈旧完成项已被排空。

```zig
// ✅ 正确：onCloseComplete 不清除 close_pending，加入 deferred_free
fn onCloseComplete(ud, l, c, _, _) CallbackAction {
    const self = ud orelse return .disarm;
    if (self.close_pending.released) return .disarm;           // 外层防护
    if (!self.close_pending.client and !self.close_pending.remote) return .disarm;
    // 注意: close_pending.client/remote 永远不清除！
    if (c == &self.client_close_c) {
        if (self.close_pending.remote) {
            self.remote.close(l, &self.remote_close_c, Self, self, onCloseComplete);
            return .disarm;
        }
    } else if (c == &self.remote_close_c) {
        // both closed
    } else return .disarm;
    self.close_pending.released = true;
    self.next = self.server.deferred_free_relays;
    self.server.deferred_free_relays = self;
    return .disarm;
}

// 心跳回调中释放
fn heartbeatCallback(ud, l, c, result) CallbackAction {
    self.freeDeferredRelays();  // 清空 deferred_free 链表
    self.heartbeat_timer.run(l, c, 200, ...);
    return .disarm;
}
```

**适用范围**：所有在 IOCP 上有持续读/写操作且 close 后可能复用的对象（RelaySession、UdpRelaySession、UotServerSession、Session、TcpRelaySession、TunUdpUotSession）。

### onCloseComplete 的 CloseError 静默丢弃

```zig
fn onCloseComplete(_: xev.TCP, _: xev.CloseError!void) xev.CallbackAction {
```

参数 `_: xev.CloseError!void` 静默丢弃所有错误，包括 `error.ThreadPoolRequired`。

**安全前提**：调用方必须提供 ThreadPool（规则一）。close 在所有后端都是同步成功或操作系统级失败（极其罕见）。若未配置 ThreadPool（kqueue/epoll），`error.ThreadPoolRequired` 被静默丢弃 → TCP socket 从未关闭 → fd 泄漏 + 客户端超时。不要在回调中添加错误处理来掩盖此配置错误——修复调用方。

## TCP 操作

### accept — 持续接受连接

```zig
// 在 accept 回调中预先注册下一个 accept，保持连接不丢失
fn acceptCallback(ud, l, c, client, result) {
    const sess = ud orelse return .disarm;
    const new_client = result catch |err| { ... };

    // 预注册下一个 accept（复用同一个 completion）
    const next = server.createSession() catch { ... };
    server.listener.accept(l, c, Session, next, acceptCallback);

    // 处理当前连接
    sess.client = new_client;
    sess.startHandshake(l);
    return .disarm;
}
```

### connect — 异步连接

```zig
self.remote.connect(l, &self.connect_c, ip_addr, Self, self, connectCallback);
```

### 双向转发模式

```zig
// 同时启动两个方向的 read
self.client.read(l, &self.client_c, .{ .slice = client_buf }, Self, self, clientReadCallback);
self.remote.read(l, &self.remote_c, .{ .slice = remote_buf }, Self, self, remoteReadCallback);

// clientReadCallback: client 读到数据 → 写到 remote → 继续读 client
// remoteReadCallback: remote 读到数据 → 写到 client → 继续读 remote
```

### close — 严格状态机 + pending 标志模式

**不要用计数器**（`close_count`）！计数器在 completion 复用 + 缺少 ThreadPool 时容易整数溢出。

**正确做法：严格状态机 + 布尔 pending 标志 + 独立 close completion**

（完整示例见上方「致命陷阱」章节）

### DNS / 异步查询的 cancel 模式

异步查询（如 DNS 解析）持有调用者的原始指针。调用者销毁前必须取消查询，否则回调会访问悬空指针。

```zig
/// DnsResolver: 取消指定 userdata 的所有待处理查询
pub fn cancel(self: *Self, userdata: ?*anyopaque) void {
    var mask = self.slot_mask;
    while (mask != 0) {
        const i: u4 = @intCast(@ctz(mask));
        mask &= mask - 1;
        if (self.slots[i].userdata == userdata) {
            self.freeSlot(i);  // 不触发回调
        }
    }
}
```

调用方在 shutdown 中，**设置 state = .closing 之前**取消：

```zig
fn shutdown(self: *Self, l: *xev.Loop) void {
    if (self.state == .closing) return;
    if (self.state == .resolving) self.server.dns.cancel(self);  // 先取消
    self.state = .closing;  // 再设状态
    // ... 发起 close ...
}
```

**顺序至关重要**：cancel → 设置 closing 状态 → 发起 close。单线程事件循环保证 cancel 和 state 设置之间无竞态。

## UDP 操作

### 初始化

```zig
const nameserver = try std.Io.net.IpAddress.parse("8.8.8.8", 53);
const socket = try xev.UDP.init(nameserver);
// socket 绑定到与 nameserver 匹配的地址族（IPv4/IPv6）
```

### 单 Socket 多路复用（DNS 解析器模式）

```zig
// 一个 UDP socket + 多个查询槽位 + TXID 匹配
// - read 和 write 各用一个 completion（复用）
// - 查询槽位由位图管理（16 槽位，O(1) 分配/释放）
// - 发送队列串行化（UDP sendto 非阻塞，瞬时完成）
// - 接收循环按 txid 路由响应到对应槽位
```

### UDP close

kqueue/epoll 后端：与 TCP close 机制相同，需要 ThreadPool，close 用独立 completion。
IOCP 后端：同步关闭（`closesocket`），需遵守规则五的 `deferred_free` 模式。

### UDP send 失败后 socket 异常（macOS EADDRNOTAVAIL / Linux EHOSTDOWN）

**问题**：macOS 上 UDP `sendto()` 失败（ICMP Host/Port Unreachable）后，socket 进入异常状态，后续 `recvfrom()` 返回 `EADDRNOTAVAIL` (errno 49)。Linux 上类似场景可能返回 `EHOSTDOWN` (errno 64)。

**根因（已修复）**：libxev 的 `posix.zig` 和各后端的 errno→error 映射中未处理 `EADDRNOTAVAIL` 和 `EHOSTDOWN`，这两个 errno 落入 `else => |err| posix.unexpectedErrno(err)` → `error.Unexpected`。

**修复（2025-07-13）**：在 libxev 层面增加了这两个 errno 的正确映射：

| errno | `recvfrom` | `sendto`/`sendmsg` | `read` | `write` |
|-------|-----------|-------------------|--------|---------|
| `EADDRNOTAVAIL` | `error.AddressNotAvailable` | 已有（`AddressNotAvailable`） | `error.AddressNotAvailable` | `error.AddressNotAvailable` |
| `EHOSTDOWN` | `error.NetworkSubsystemFailed` | `error.NetworkUnreachable` | `error.ConnectionResetByPeer` | `error.ConnectionResetByPeer` |

修改文件：
- `vendor/libxev/src/posix.zig` — 错误集 + `recvfrom`/`sendto`/`sendmsg`/`read`/`write` 函数
- `vendor/libxev/src/backend/io_uring.zig` — 错误集 + `readResult`/`invoke`
- `vendor/libxev/src/backend/kqueue.zig` — `mapReadError`/`mapWriteError` 保留新错误类型

**应用层处理**：应用层现在应检查 `error.AddressNotAvailable` 而非 `error.Unexpected` 来触发 rebind。`EHOSTDOWN` 的语义是主机不可达，rebind 对 UDP socket 同样是合理恢复策略。

正确做法：关闭旧 socket → 100ms 定时器 → 创建新 socket → 恢复收发。0ms 不够（OS 还没清理），100ms 是经过验证的可靠值。

```zig
// 触发 rebind（从 sendCallback 或 recvCallback 的 error.AddressNotAvailable 分支）
fn startRebind(self: *Self, loop: *xev.Loop) void {
    if (self.rebind_active) return;
    self.rebind_active = true;
    self.send_active = false;  // 停止收发
    self.recv_active = false;
    // 关闭旧 socket（用独立 completion，noop 回调）
    var cc: xev.Completion = .{};
    self.socket.close(loop, &cc, void, null, noopClose);
    // 等 100ms 后重新绑定
    self.rebind_timer.run(loop, &self.rebind_c, 100, Self, self, rebindCallback);
}

fn rebindCallback(ud, l, _, result) CallbackAction {
    const self = ud orelse return .disarm;
    self.rebind_active = false;
    _ = result catch return .disarm;
    // 重新创建 socket
    self.socket = xev.UDP.init(self.nameserver) catch |err| {
        // 创建失败，1 秒后重试
        self.rebind_active = true;
        self.rebind_timer.run(l, &self.rebind_c, 1000, Self, self, rebindCallback);
        return .disarm;
    };
    // 恢复收发
    if (self.slot_count > 0) {
        startRecv(self, l);
        if (self.send_queue_len > 0) startSend(self, l);
    }
    return .disarm;
}
```

**触发点**：
- `sendCallback` 的 error 分支：发送失败后 socket 可能进入异常状态，触发 rebind
- `recvCallback` 的 `error.AddressNotAvailable` 或 `error.NetworkSubsystemFailed` 分支：socket 异常状态信号，触发 rebind 而非重试

**重要**：`recvCallback` 中对 `error.AddressNotAvailable`/`error.NetworkSubsystemFailed` 必须特殊处理，不能走通用重试路径，否则无限循环。

### 网络 errno 错误映射完整表（2025-07-13 修复）

libxev 原来存在未捕获的网络 errno，落入 `unexpectedErrno`/`unexpectedWSAError` → `error.Unexpected`。应用层被迫猜测 `error.Unexpected` 含义。现已完整修复。

#### 修复文件清单

| 文件 | 变更 |
|------|------|
| `vendor/libxev/src/posix.zig` | 错误集 + `recvfrom`/`sendto`/`sendmsg`/`read`/`write` 函数 |
| `vendor/libxev/src/backend/io_uring.zig` | 错误集 + `readResult`/`invoke`(send/sendmsg/write/pwrite) |
| `vendor/libxev/src/backend/kqueue.zig` | 错误集 + `mapReadError`/`mapWriteError` 保留新错误类型 |
| `vendor/libxev/src/backend/iocp.zig` | 错误集 + `.send`/`.recv`/`.sendto`/`.recvfrom` 4 个 switch case |

#### POSIX errno 映射 (kqueue / epoll / io_uring)

| errno | `recvfrom` | `sendto`/`sendmsg` | `read` | `write` |
|-------|-----------|-------------------|--------|---------|
| `EADDRNOTAVAIL` | `error.AddressNotAvailable` | 已有（`AddressNotAvailable`） | `error.AddressNotAvailable` | `error.AddressNotAvailable` |
| `EHOSTDOWN` (errno 64) | `error.NetworkSubsystemFailed` | `error.NetworkUnreachable` | `error.ConnectionResetByPeer` | `error.ConnectionResetByPeer` |
| `HOSTUNREACH` / `NETUNREACH` | `error.NetworkUnreachable` | 已有（`NetworkUnreachable`） | `error.ConnectionResetByPeer` | `error.ConnectionResetByPeer` |

#### Winsock 错误映射 (IOCP / Windows)

| Winsock 错误 | recv/recvfrom | send/sendto |
|-------------|---------------|-------------|
| `WSAEADDRNOTAVAIL` (10049) | `error.AddressNotAvailable` | `error.AddressNotAvailable` |
| `WSAEHOSTDOWN` (10064) | `error.NetworkSubsystemFailed` | `error.NetworkUnreachable` |
| `WSAEHOSTUNREACH` (10065) | `error.NetworkUnreachable` | `error.NetworkUnreachable` |
| `WSAENETUNREACH` (10051) | `error.NetworkUnreachable` | `error.NetworkUnreachable` |

#### 跨平台 errno 处理技巧

- **直接枚举值**（`EADDRNOTAVAIL`、`HOSTUNREACH`、`NETUNREACH`）：所有 POSIX 平台均存在，直接用 `.ADDRNOTAVAIL =>` 等 switch 分支
- **Linux 专用值**（`EHOSTDOWN` = errno 64）：macOS 上不存在此枚举值，用 `@intFromEnum(err) == 64` 跨平台安全整数比较。**注意**：在 `invoke()` 等返回非 error union 的函数中，必须用 `blk: { break :blk value; }` 块标签而非 `return`


## Completion 生命周期深入

### 堆分配 Completion（持久）

Completion 嵌入在堆分配的结构体（Session、RelaySession、DnsResolver）中时，生命周期由所属结构体管理。只要结构体在回调触发前不被释放，就是安全的。

### 栈局部 Completion（瞬时）

`close()` 等操作可以使用栈局部变量 `var cc: xev.Completion = .{};`，如：

```zig
pub fn deinit(self: *Self, loop: *xev.Loop) void {
    var cc: xev.Completion = .{};
    self.socket.close(loop, &cc, void, null, noopClose);
}
```

**不需要堆分配**。原理：libxev 的 `close()` 将 Completion 的内容**复制**到内部 MPSC 队列（提交到 ThreadPool），函数返回后 `cc` 虽然栈帧销毁，但队列中的副本仍然有效。ThreadPool 处理 close 时用的是队列中已复制的数据。

**验证方法**：如果局部 Completion 不安全，`Server.deinit()` 等函数每次调用都会崩溃——但实际不会。

### Completion 复用 vs 独立

| 场景 | 策略 | 原因 |
|------|------|------|
| 持续读/写循环 | **复用同一个** Completion | 回调触发后 completion 已释放，可安全重新提交 |
| close 操作 | **独立** Completion（`*_close_c`） | 防止 kqueue 旧事件触发 close 回调导致 double free |
| 不同 fd 的读 | **不同** Completion | 每个 fd 有独立的事件注册 |
| 临时 close | **栈局部** Completion | 复制到队列，无需持久化 |

## Timer 操作

### 基本用法

```zig
// 初始化
const timer = try xev.Timer.init();

// 启动（一次性，不自动重复）
self.timer_active = true;
timer.run(loop, &self.timer_c, timeout_ms, Self, self, timerCallback);

// 回调
fn timerCallback(ud, l, c, r: xev.Timer.RunError!void) xev.CallbackAction {
    const self = ud orelse return .disarm;
    self.timer_active = false;
    _ = r catch return .disarm; // Canceled 时忽略
    // ... 处理超时 ...
    return .disarm;
}
```

### 单 Timer 管理多个超时（批量超时模式）

```zig
// 不要为每个查询创建单独的 timer。
// 用一个全局 timer 统一管理，到期时检查所有活跃槽位：

fn timerCallback(ud, l, c, r) {
    self.timer_active = false;
    _ = r catch return .disarm;

    // 检查所有活跃槽位是否超时
    const now = getNowUs();
    var mask = self.slot_mask;
    while (mask != 0) {
        const i = @ctz(mask);
        if (now -| slots[i].start_time_us > timeout_us) {
            // 超时 → 释放槽位，回调错误
        }
        mask &= mask - 1;
    }

    // 还有活跃槽位 → 重启 timer
    if (self.slot_count > 0) {
        self.timer_active = true;
        timer.run(l, &self.timer_c, self.timeout_ms, Self, self, timerCallback);
    }
}
```

### Timer 注意事项

1. **不要重复 `run()`**：timer 活跃时再次 `run()` 会创建第二个 timer。用 `timer_active` 布尔值追踪状态。
2. **`reset()` 需要两个 completion**：`c`（新 timer）+ `c_cancel`（取消旧 timer）。两个 completion 的回调都会触发。简单场景下不建议用 `reset()`，直接等当前 timer 到期后再 `run()` 更简单。
3. **回调中检查 `Canceled`**：`_ = r catch return .disarm` 忽略取消信号。
4. **`Timer.init()` 返回 `!Timer`**：虽然内部仍是零分配（返回 `{}`），但签名要求 `try`。可以确信 `init()` 不会失败。
5. **`Timer.deinit()` 是空操作**：不释放任何资源。Timer 不持有独立的 fd——定时器机制由 Loop 内部的 kqueue timer / timerfd 管理，随 Loop 生命周期自动清理。**不需要像 TCP/UDP 那样显式 close Timer。**

### Timer.init() / ThreadPool.init() 分配特性

在 libxev **静态 API**（本项目使用 `xev.Timer` / `xev.ThreadPool` 而非动态 `xev.Timer(backend)`)：

| 类型 | `init()` 签名 | 分配行为 | `deinit()` 行为 |
|------|--------------|---------|----------------|
| `xev.Timer` | `!Timer` (需 `try`) | 返回 `{}`，**零分配** | **空操作** |
| `xev.ThreadPool` | 返回配置结构体，**零分配**（线程延迟创建） | `shutdown()` + `deinit()` 回收线程 |
| `xev.TCP` | 创建 socket fd | `close()` 关闭 fd |
| `xev.UDP` | 创建 socket fd | `close()` 关闭 fd |
| `xev.Loop` | 创建 kqueue/epoll fd | `deinit()` 关闭 fd + 清理内部状态 |

**关键结论**：
- `xev.Timer.init()` 内部零分配，但签名返回 `!Timer`，调用时必须用 `try`（不会实际失败）
- `ThreadPool.init(.{})` 不分配内存。即使 errdefer `allocator.destroy(tp)` 跳过了 `shutdown()/deinit()`，也不会泄漏线程资源——因为没有线程被创建过。只有在 `run()` 过程中首次提交 threadpool 任务时才会 spawn 线程。

## 跨平台差异

| 操作 | kqueue (macOS) | epoll (Linux) | io_uring (Linux) | IOCP (Windows) |
|------|---------------|---------------|------------------|----------------|
| `TCP.close()` | 同步（ThreadPool 线程），**返回 void** | 同步（ThreadPool 线程），返回 error union | 同步（事件循环线程） | **同步** (`CloseHandle`/`closesocket`) |
| `UDP.close()` | 同步（ThreadPool 线程），**返回 void** | 同步（ThreadPool 线程），返回 error union | 同步（事件循环线程） | **同步** (`CloseHandle`/`closesocket`) |
| `Timer` | kqueue 定时器（Loop 内部管理） | timerfd（Loop 内部管理） | io_uring timeout | IO Completion 定时器 |
| `accept` | 异步 | 异步 | 异步 | AcceptEx (IOCP) |

**核心原则：**
1. 所有后端的 close 都是**同步**的——`close(fd)` / `rawCloseHandle(fd)` 直接调用，不经过异步 SQE/CQE
2. kqueue/epoll 必须提供 `ThreadPool`（stream.zig 设置 `flags.threadpool = true`，close 在 ThreadPool 工作线程中执行）
3. IOCP 的 close 在事件循环线程中同步执行。close 完成后同一 tick 内仍可能有被取消的 I/O 完成项触发（见规则五：IOCP deferred free）
4. close 用独立 completion，不复用读写 completion
5. close() 返回后不访问 self（用局部变量保存决策）

### ⚠️ kqueue 后端 close() 返回 void

在 macOS/BSD 的 kqueue 后端上，`TCP.close()` 和 `UDP.close()` **返回 `void`（不是 error union）**：

```zig
// macOS/BSD — 无错误返回
self.socket.close(loop, &cc, void, null, noopClose);

// Linux epoll — 返回 error union
self.socket.close(loop, &cc, void, null, noopClose); // 也可以统一用 void callback
```

**实际影响**：如果用 `try self.socket.close(...)` 会在 macOS 编译报错（无法 try void）。统一使用无错误回调签名 `CloseError!void`，各平台均兼容。回调中 `_ = result catch {}` 即可同时处理有/无错误的情况。

## 本项目中的时间获取

Zig 0.16.0 移除了 `std.time.microTimestamp()` 等函数，时间 API 迁移到了 `std.Io.Timestamp`（需要 Io 实例）。

libxev 项目不使用 `std.Io`，因此使用底层跨平台实现，统一在 `src/platform.zig` 中：

```zig
const platform = @import("platform.zig");

// 毫秒级单调时钟
const now_ms: i64 = platform.getNowMs();
// 微秒级单调时钟
const now_us: u64 = platform.getNowUs();
```

**实现**（`src/platform.zig`）：

```zig
/// 单调时钟毫秒时间戳。Windows: GetTickCount64, POSIX: CLOCK_MONOTONIC。
pub fn getNowMs() i64 {
    if (builtin.os.tag == .windows) {
        const kernel32 = struct {
            extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
        };
        return @as(i64, @intCast(kernel32.GetTickCount64()));
    }
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(@as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000));
}

/// 单调时钟微秒时间戳。Windows: GetTickCount64×1000, POSIX: CLOCK_MONOTONIC。
pub fn getNowUs() u64 {
    if (builtin.os.tag == .windows) {
        const kernel32 = struct {
            extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
        };
        return kernel32.GetTickCount64() * 1000;
    }
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @intCast(@as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000);
}
```

这是**非阻塞的只读 syscall**（纳秒级），不会阻塞事件循环。Zig 0.16.0 各平台 `timespec` 字段名统一为 `sec` / `nsec`。

**历史**（2025-07-15 前）：各模块（`dns.zig`、`tun_tcp_relay.zig`、`tun_udp_relay.zig`）各自实现 `getNowMs()`/`getNowUs()`，存在重复代码。2025-07-15 提交 `09a1281` 将其统一到 `platform.zig`，各模块改为 `const platform = @import("platform.zig");` 后调用 `platform.getNowUs()`。

## 事件循环模式

```zig
// 单次迭代（非阻塞）
try loop.xev_loop.run(.no_wait);

// 等待至少一个事件
try loop.xev_loop.run(.once);

// 持续运行直到 stop() 或没有活跃 completion
try loop.xev_loop.run(.until_done);
```

**注意**：`run(.until_done)` 在没有活跃 completion 时立即返回。因此必须确保在调用 `run()` 之前至少有一个异步操作已提交（如 listener.accept），否则事件循环会立刻退出。

## 信号处理与优雅退出

### ⚠️ macOS kqueue EINTR 无限重试问题

**问题**：`kevent()` 收到信号（SIGINT/SIGTERM）返回 EINTR 后，libxev 的 `kevent_syscall` **无限重试**（`.INTR => continue`），不返回给 `tick()` 检查 `flags.stopped`。信号处理器中调 `loop.stop()` 设置 `flags.stopped = true` 但永远不被检查到。

**根因**：`vendor/libxev/src/backend/kqueue.zig:kevent_syscall` 在 EINTR 时 `continue` 重新调用 `kevent64()`，不将 EINTR 传播给调用方。当没有定时器时 `kevent` 超时为 null（无限阻塞），没有任何机制能中断这个重试循环。

**正确方案：信号处理器只设标志，事件循环内执行实际 stop**：

```zig
// Server 字段
stop_requested: bool = false,
heartbeat_timer: xev.Timer,
heartbeat_c: xev.Completion = .{},

// 1. 信号处理器：仅设置原子标志（信号安全，不调任何 libxev API）
pub fn stop(self: *Self) void {
    self.stop_requested = true;
}

// 2. 心跳定时器回调（在事件循环内执行）：检测标志后执行实际 stop
fn heartbeatCallback(ud: ?*Server, l: *xev.Loop, c: *xev.Completion, result: xev.Timer.RunError!void) xev.CallbackAction {
    const self = ud orelse return .disarm;
    _ = result catch return .disarm;
    if (self.stop_requested) {
        self.doStop();  // 关闭 listener fd + loop.stop()
        return .disarm; // 不再续约
    }
    self.heartbeat_timer.run(l, c, 200, Server, self, heartbeatCallback);
    return .disarm;
}

fn doStop(self: *Self) void {
    if (self.listener_closed) return;
    _ = std.posix.system.close(self.listener.fd);  // 同步关闭，阻止新连接
    self.listener_closed = true;
    self.loop.stop();
}
```

**原理**：
1. 心跳定时器每 200ms 触发，确保 kevent 始终有超时
2. 信号到达 → `stop_requested = true` → kevent 靠心跳定时器超时返回
3. tick() 内部 while 循环第 368 行 `if (self.flags.stopped) return;` 每次迭代都检查
4. 定时器回调比 I/O 事件先处理，`doStop()` 关闭 listener fd 后，同一 tick 内的 accept 事件回调能检测到 `listener_closed`，不再创建新 Session

**为什么不在信号处理器中直接调 `loop.stop()` 或 `close(listener.fd)`**：
- `loop.stop()` 设了 flag 但 kevent 不返回 → 无效
- `close(listener.fd)` 是同步 syscall，信号处理器中可以调用，但 acceptCallback 可能在同一次 tick 的 I/O 事件处理中仍在运行（定时器回调处理早于 I/O 事件），关闭 listener 后 accept 的 I/O 事件回调会发现 fd 已关闭导致 EBADF

**关键洞察**：`tick()` 内部处理顺序是 **先定时器、后 I/O 事件**。因此心跳回调中的 `doStop()` 在 I/O 事件回调之前执行，`listener_closed` 标志对 accept 事件回调可见。

### 惰性 Session 创建 + 活跃对象追踪

**问题**：停止事件循环时，正在握手/检测阶段的 Session 和正在转发的 RelaySession 未被任何链表追踪，导致泄漏。

**方案：双向链表追踪 + deinit 兜底清理**：

```zig
// Server 字段
active_sessions: ?*Session = null,  // createSession 时加入，shutdown 时移除
active_relays: ?*RelaySession = null,  // acquireRelay 时加入，shutdown 时移除

fn createSession(self: *Self) !*Session {
    const s = try self.allocator.create(Session);
    // ... 初始化 ...
    s.next = self.active_sessions;
    self.active_sessions = s;
    return s;
}

fn destroySession(self: *Self, s: *Session) void {
    self.removeActiveSession(s);
    self.allocator.destroy(s);
}

// shutdown 将对象从活跃链表移除，直接调用 close()
fn shutdown(self: *Session, l: *xev.Loop) void {
    // ...
    self.server.removeActiveSession(self);
    self.client.close(l, &self.client_close_c, Session, self, onCloseComplete);
}

// deinit 兜底清理所有残留链表
pub fn deinit(self: *Self) void {
    // ... 正常清理 ...
    while (self.deferred_free_sessions) |s| { ... }  // IOCP 延迟释放队列
    while (self.deferred_free_relays) |r| { ... }
    while (self.relay_pool) |r| { ... }              // Relay 池
    while (self.active_relays) |r| { ... }           // 活跃 Relay（兜底）
    while (self.active_sessions) |s| { ... }         // 活跃 Session（兜底）
    self.pool.deinit();
}
```

**每个对象在任何时刻仅存在于一个链表中**：活跃链表 → (shutdown) close → deferred_free（IOCP）或直接 destroy（其他后端）。

## 检查清单

新代码提交前，确认以下事项：

- [ ] `Loop.init` 传入了 `ThreadPool`（kqueue/epoll 必需，见规则一）
- [ ] close 使用独立 completion（`client_close_c` / `remote_close_c`），不复用读写 completion（规则二）
- [ ] shutdown 中**先释放缓冲区，再设置 close_pending**（否则缓冲区永不归还）
- [ ] close() 返回后不访问 self（决策存局部变量，规则三）
- [ ] 所有回调有状态守卫：`if (self.state == .closing) return .disarm;`
- [ ] 读/写回调有 close_pending 守卫：`if (self.close_pending.client or self.close_pending.remote) return .disarm`
- [ ] 所有错误路径通过 `shutdown()` 统一关闭，不直接调 `close()`（规则四）
- [ ] `close_pending` 标志**永远不清除**（IOCP 陈旧完成项永久防护）
- [ ] IOCP: `onCloseComplete` 用 `deferred_free` + 心跳释放（规则五）
- [ ] IOCP: 各 Session 类型使用独立 `deferred_free` 链表
- [ ] `onCloseComplete` 参数 `_: xev.CloseError!void` 静默丢弃错误——调用方必须提供 ThreadPool，否则 `error.ThreadPoolRequired` 被丢弃导致 fd 泄漏
- [ ] Completion 不在活跃状态时被复用
- [ ] Timer 不重复 `run()`（有 `timer_active` 守卫）
- [ ] 无阻塞 syscall（无 `sleep`/`poll`/`getaddrinfo` 等）
- [ ] 无 `std.Io` 依赖（时间用 `clock_gettime`）
- [ ] UDP recvCallback 对 `error.AddressNotAvailable`/`error.NetworkSubsystemFailed`/`error.NetworkUnreachable` 走 rebind 路径，不走重试
- [ ] 回调中不依赖 `error.Unexpected` 判断网络错误（libxev 已正确映射所有网络 errno）
- [ ] 栈局部 Completion 仅用于一次性 close 操作（无需持久化时）
- [ ] kqueue 后端 `close()` 返回 void，不使用 `try` 调用
- [ ] ThreadPool 在 Loop 生命周期内保持有效（栈分配即可，`init(.{})` 零分配）
- [ ] 跨平台行为验证：通过 `utm-vm` skill 在三平台 VM (linuxvm/macvm/windowsvm) 上部署并执行功能测试，确认各后端行为一致

## io_uring 同步关闭修复

### 问题：use-after-free (segfault at cqe.user_data)

**症状**：Linux VM 上代理处理 1-3 个连接后崩溃在 `io_uring.zig:196`：
```zig
c.flags.state = .dead;  // SEGFAULT — c 指向已释放的 Completion
```

**根因**：io_uring 的 `IORING_OP_CLOSE` 是**异步**的。当 close SQE 完成、回调释放 Session 后，
之前提交的读/写 SQE 可能尚未被内核取消——它们的 CQE 随后到达时，`cqe.user_data`
指向已释放的 Completion 结构体。

对比 kqueue/epoll：close 同样是**同步**的（直接 `posix.close(fd)`），fd 关闭后 OS 自动清理该 fd 上的所有内核事件，确保不会再有旧事件触发。

**修复**（`vendor/libxev/src/backend/io_uring.zig`）：将 io_uring 的 close 操作改为同步，
在 `add_()` 中直接调用 `posix.close(fd)` 并立即触发回调，不再提交 `IORING_OP_CLOSE` SQE。

```
关键改动：.close 分支从 sqe.prep_close(v.fd) 改为同步 xev_posix.close(v.fd) + 内联回调
```

修复后，旧读/写 SQE 仍会因 fd 已关闭而返回 -EBADF，但此时 Completion 仍在
`deferred_free` 列表中（心跳延迟释放提供至少 200ms 安全窗口），内存有效。

**验证**：Linux VM 上单连接 → 5 顺序 → 10 并发 → 50 并发（25 本地 + 25 外部）全部通过，
无 segfault。
