# Findings: libxev — 技术定论指针表

> v0.34.0 里程碑：技术定论均已下沉源码注释（简体中文），本文件仅留指针表；
> 正文细节见 git history 与 libxev.md；本仓全部待办已 08-24 CLOSE 留档（见下方「跨项目指针」）。

## 定论 → 代码注释

| 定论 | 代码位置 |
|------|---------|
| ConnectEx 是唯一异步 connect（须先 bind 通配地址） | iocp.zig `.connect` :560-607 |
| WSA 错误映射：send/sendto/recv/recvfrom 各独立 switch，缺失归 Unexpected，须四处置同步 | iocp.zig 提交(:668-791) + 完成(:1232-1346) 分支 |
| stop_completion 非 IOCP op 直接 dead + active-1 | iocp.zig :920-931 |
| IOCP CloseHandle 用原始 kernel32（免 STATUS_INVALID_HANDLE） | iocp.zig :988-994 |
| IOCP Async sticky 消费（#65 自触发 PQCS 循环 / #168-#169 waiter 代际） | watcher/async.zig AsyncIOCP :621-662 |
| 0xaa memset：entries/cqes 移出栈为 Loop heap 字段 | iocp:75 / kqueue:96 / epoll:127 / io_uring:60 |
| fcntl 缓存：initFdNonblock 跳过每完成回调 2×fcntl syscall | watcher/stream.zig :27-36、watcher/tcp.zig :94-108 |
| readv/writev 批读批写（减少 read syscall + kevent 往返） | kqueue.zig Operation :1746-1757 |
| recvfrom/accept 地址缓冲须 28B(sockaddr_in6) 防截断/越界写 | kqueue.zig :1722-1729 / :1790-1798 |
| EISCONN(56) connect 视为成功 | kqueue.zig :1393-1396 |
| kevent/kevent64 EINTR 自动重试 | kqueue.zig kevent_syscall :2023-2079 |
| close 可能阻塞 → kqueue/epoll close 走 ThreadPool | watcher/stream.zig :443-449 |
| io_uring close 同步化（防旧操作 CQE use-after-free） | io_uring.zig :417-439 |
| io_uring 不设 SOCK_NONBLOCK（内核轮询；上层直读须自设） | watcher/tcp.zig :62-68 |
| io_uring 零长度探词 → POLL_ADD（完成时合成 res=0） | io_uring.zig :490-503 |

## 跨后端差异

| 操作 | kqueue | io_uring | IOCP |
|------|--------|----------|------|
| connect | EVFILT_WRITE | IORING_OP_CONNECT | ConnectEx |
| accept | EVFILT_READ | IORING_OP_ACCEPT | AcceptEx |
| close | 可能阻塞(ThreadPool) | 同步 | 同步 CloseHandle |
| Timer | 用户态堆式(kqueue:81) | 内核超时 | 用户态堆式(iocp:32) |

## 跨项目指针

- 使用指南（close 状态机 / deferred_free / ThreadPool 规则）→ libxev.md
- **结论（08-24 已 CLOSE 留档，定案不实施）**：xev-1 IOCP UDP connect（生态 UDP 走 sendto/recvfrom，零消费者）/ xev-2 io_uring CQ overflow（std copy_cqes 自动捞回 overflow list，CQE 不丢；IoUring init 断言非 deinit）/ xev-3 Timer 取消统一（kqueue/iocp 用户态堆 vs io_uring 内核超时 = 架构使然，timer.zig 已按后端分派）/ xev-4 IOCP 文档。
- **依据**：CLOSE 留档 commit git 5473f89 + zigbox task_plan.md「跨项目统一待办」libxev 段。勿按「开放待办」解读——本库无独立开放待办。
