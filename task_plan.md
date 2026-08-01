# Task Plan: libxev — 跨平台异步事件循环 (fixnet fork)

## 项目定位

本仓库是 [mitchellh/libxev](https://github.com/mitchellh/libxev) 的 fixnet fork，为 fixnet 生态（zigbox/zigtun/zigproxy/zigdns）提供跨平台异步 I/O 事件循环。

## 当前版本

v0.11.0 (2026-08-02) — 全项目统一版本对齐。
v0.10.2 (2026-07-31) — 日志英文规范规则 #6（不适用，底层 C fork）+ 规划文档同步。
v0.10.0 (2026-07-30) — CLAUDE.md 统一优化。
v0.8.5 (2026-07-30) — 跨项目统一发布，无代码变更，tag 对齐 zigbox WFP DNS 劫持修复。

## 已完成工作

| 类别 | 内容 | 关键 commit |
|------|------|------------|
| kqueue connect 修复 | EADDRNOTAVAIL/EHOSTDOWN 映射、EISCONN (errno 56) 未映射修复 | `7345361`, `b6aa7a7` |
| kqueue Timer | 时钟更新修复 — kevent 返回后更新时间戳 | `7e7d2f2` |
| io_uring close | close() 改为同步操作，避免生命周期竞争 | — |
| io_uring UDP | 不设 SOCK_NONBLOCK（设计选择） | — |
| IOCP ConnectEx | 异步连接替代同步 connect()，对标 AcceptEx 模式 | `b10ccf7`, `8132f5b` |
| IOCP stop_completion | 非 IOCP 操作 panic 修复 | `1a1eb49` |
| IOCP WSA 错误映射 | send/recv/sendto/recvfrom 完成阶段 12 种 WSA 错误码补全 | `ec2c332` |
| IOCP CloseHandle | STATUS_INVALID_HANDLE 修复 | `997f328` |
| TCP/UDP initFd | NONBLOCK 标志设置，防止阻塞事件循环 | `a3b02c2` |
| EINTR 处理 | kevent_syscall EINTR 自动重试 | — |
| 文档 | libxev.md 综合使用指南（1037 行） | `ea829d9` |

## 待完成工作

| 类别 | 内容 | 优先级 |
|------|------|--------|
| Windows IOCP | UDP connect 支持（目前仅 TCP ConnectEx） | P2 |
| io_uring | 高负载下的 SQ overflow 处理 | P2 |
| 跨平台 | Timer 取消竞态条件统一 | P2 |
| 文档 | Windows IOCP 开发指南补充 | P3 |

## 模块架构

```
libxev/
├── src/
│   ├── libxev.zig         # 主入口，后端选择
│   ├── backend/
│   │   ├── kqueue.zig     # macOS
│   │   ├── epoll.zig      # Linux (epoll)
│   │   ├── io_uring.zig   # Linux (io_uring)
│   │   └── iocp.zig       # Windows
│   ├── watcher/            # 事件监视器
│   │   ├── tcp.zig
│   │   ├── udp.zig
│   │   ├── timer.zig
│   │   └── ...
│   └── windows.zig         # Windows 平台特定
└── libxev.md               # 综合使用指南
```

## 版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| v0.7.4 | 2026-07-29 | 跨项目统一发布 (tag 对齐) |
| v0.7.3 | 2026-07-29 | libxev.md 文档同步 |
| v0.6.0 | 2026-07-25 | 跨项目统一发布 |
