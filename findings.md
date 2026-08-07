# Findings: libxev — 踩坑记录 & 经验教训

## IOCP 后端

### ConnectEx 是 Windows 异步 connect 的唯一方式

`connect()` 在 overlapped socket 上对远程地址返回 `WSAEWOULDBLOCK`，不投递 IOCP 完成通知。
必须通过 `WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER)` 动态加载 ConnectEx。
教训：Windows 异步 socket API 不对称 — AcceptEx 可直接链接 mswsock，ConnectEx 必须动态加载。

### IOCP 完成阶段错误码映射

4 个完成处理器（send/sendto/recv/recvfrom）需独立映射 12 种 WSA 错误码。缺失映射时错误归类为 `error.Unexpected`。

### stop_completion 需处理非 IOCP 操作

`.cancel`/`.async_wait` 等队列型操作没有 IOCP overlapped 操作可取消。修复：标记为 dead 并递减 active 计数。

## kqueue 后端

### EISCONN (errno 56) 在 connect 回调中出现

`connect()` 成功后 kqueue 可能投递 EVFILT_WRITE，此时 getsockopt(SO_ERROR) 返回 EISCONN。修复：映射为成功。

### close() 可能阻塞

macOS kqueue `close()` 在内核中有阻塞路径。调用者需要 ThreadPool，否则走 RST 快速路径。

### kevent EINTR 需要重试

信号处理（SIGINT/SIGTERM）导致 kevent 返回 EINTR。修复：kevent_syscall 自动重试。

## io_uring 后端

### 不设 SOCK_NONBLOCK 是设计选择

io_uring 使用内核线程轮询，不需要非阻塞 socket。但上层代码（如 zigdns DnsClient）使用直接 read/recvfrom 时需自行设置 NONBLOCK。

### close() 同步化

异步 close 的生命周期竞争：回调可能在 close 完成后触发访问已释放资源。修复：close() 改为同步操作。

## 跨后端差异

| 操作 | kqueue | io_uring | IOCP |
|------|--------|----------|------|
| connect | EVFILT_WRITE | IORING_OP_CONNECT | ConnectEx |
| accept | EVFILT_READ | IORING_OP_ACCEPT | AcceptEx |
| close | 可能阻塞 | 同步 | CloseHandle |
| Timer | EVFILT_TIMER | IORING_OP_TIMEOUT | CreateWaitableTimer |
