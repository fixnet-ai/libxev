# Findings: libxev — 踩坑记录 & 经验教训

> 第 4 轮瘦身：已落代码注释的技术定论仅留指针行；保留跨后端差异表与跨项目指针。

## IOCP 后端

### ConnectEx 是 Windows 异步 connect 的唯一方式
> 代码：windows.zig `loadConnectEx` / iocp.zig `.connect` 分支已有注释。
同步 `connect()` 在 overlapped socket 上对远程地址返回 `WSAEWOULDBLOCK` 且不投递 IOCP 完成通知。
教训：Windows 异步 socket API 不对称 — AcceptEx 可直接链接 mswsock，ConnectEx 必须 `WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER)` 动态加载。

### 完成阶段错误码映射（12 种 WSA）
> 代码：iocp.zig send/sendto/recv/recvfrom 四个完成处理器各有独立 switch（详见 code comments）。
四个处理器须各自维护 WSA 错误码映射，缺失映射的错误统一归类 `error.Unexpected`，新增/调整错误码须四处置同步。

### stop_completion 需处理非 IOCP 操作
> 代码：iocp.zig `stop_completion` 的 `.cancel`/`.async_wait` 分支（标记 dead + 递减 active）已有注释。
队列型操作没有 IOCP overlapped 操作可取消，直接标记为 dead 并递减 active 计数。

## kqueue 后端

### EISCONN (errno 56) 在 connect 回调中出现
macOS connect 成功后 kqueue 仍可能投递 EVFILT_WRITE，`getsockopt(SO_ERROR)` 返回 EISCONN — 这是连接已建立的正常信号，应视为成功，勿归 `error.Unexpected`。

### close() 可能阻塞
macOS kqueue `close()` 内核中有阻塞路径；调用方需 ThreadPool（文件等无异步 API 的操作），否则走 RST 快速路径。

### kevent EINTR 需要重试
> 代码：kqueue.zig `kevent_syscall`（kevent/kevent64 均 `.INTR => continue`）已有注释。
信号处理（SIGINT/SIGTERM）导致 kevent 返回 EINTR，自动重试。

## io_uring 后端

### 不设 SOCK_NONBLOCK 是设计选择
io_uring 使用内核线程轮询，socket 不需要非阻塞标志。但上层代码（如 zigdns DnsClient）直接 read/recvfrom 时须自行设置 NONBLOCK，否则阻塞事件循环。

### close() 同步化
> 代码：io_uring.zig `.close` 分支（同步 `xev_posix.close`）已有注释。
异步 close 的生命周期竞争：回调可能在 close 完成后触发访问已释放资源。

## 跨后端差异

| 操作 | kqueue | io_uring | IOCP |
|------|--------|----------|------|
| connect | EVFILT_WRITE | IORING_OP_CONNECT | ConnectEx |
| accept | EVFILT_READ | IORING_OP_ACCEPT | AcceptEx |
| close | 可能阻塞 | 同步 | CloseHandle |
| Timer | 用户态堆式 Timer（kqueue.zig:81，避免大量 syscall） | IORING_OP_TIMEOUT（内核超时，取消=timeout_remove） | 用户态堆式 Timer（iocp.zig:32 TimerHeap） |
