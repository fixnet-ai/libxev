# Findings: libxev — 技术定论指针表

> v0.37.0 里程碑：技术定论均已下沉源码注释（简体中文），本文件仅留指针表；
> 正文细节见 git history 与 libxev.md。xev-1..xev-4 于 08-24 CLOSE 留档（not-do 定案），
> xev-5..xev-9 均已闭环（各见下方「跨项目指针」/ zigbox 统一待办 libxev 段）。

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
- xev-1..xev-4（IOCP UDP connect / io_uring CQ overflow / Timer 取消统一 / IOCP 文档）08-24 CLOSE
  留档定案不实施：08-23 08fe943 为移交 commit（迁移至 zigbox 统一规划，非关闭记录），真正关闭记录
  = zigbox 5473f89（08-24）；权威 = zigbox task_plan「跨项目统一待办」libxev 段（audit #15）。
  勿按「开放待办」解读——本库无计划中的功能待办（已知休眠缺口见下「已知缺口」）。

## 已知缺口（跨仓记录、本仓规划零载体）

- `zig build test` c-api sizes 用例 pre-existing 失败 59/60（zigbox task_plan L410：既有
  pre-existing，#91 前即失败）；本仓根目录无 zigtester.yaml，测试不在统一基线框架内，长期无人发现。
  处置方向 = 修 c-api sizes 或登记豁免 + 补 zigtester.yaml（owner 未定）。
- Linux 后端 datagram sendmsg + 带 buffer 未实现 → io_uring.zig:534 / epoll.zig:801
  `@panic("TODO: sendmsg with buffer")`，消费者若触达即运行时 panic（kqueue.zig:1618 FreeBSD
  wakeup @panic 同理，BSD 不在消费范围）。「定论均已下沉、无待办」不遮蔽此休眠限制。
