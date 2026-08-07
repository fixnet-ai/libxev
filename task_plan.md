# Task Plan: libxev — 跨平台异步事件循环 (fixnet fork)

## 项目定位

本仓库是 [mitchellh/libxev](https://github.com/mitchellh/libxev) 的 fixnet fork，为 fixnet 生态（zigbox/zigtun/zigproxy/zigdns）提供跨平台异步 I/O 事件循环。

## 当前版本

v0.16.0 (2026-08-05) — 全项目统一版本发布。详细版本历史见 git tag。

## 已完成工作

kqueue connect 修复（EADDRNOTAVAIL/EHOSTDOWN/EISCONN）、Timer 时钟更新、io_uring 同步 close、IOCP ConnectEx/WSA 错误映射/CloseHandle/stop_completion、TCP/UDP NONBLOCK initFd、EINTR 重试。详见 git history。

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
│   ├── main.zig           # 入口
│   ├── api.zig            # pub API
│   ├── backend/
│   │   ├── kqueue.zig     # macOS
│   │   ├── epoll.zig      # Linux (epoll)
│   │   ├── io_uring.zig   # Linux (io_uring)
│   │   ├── iocp.zig       # Windows
│   │   └── wasi_poll.zig  # WASI
│   ├── watcher/           # 事件监视器（async/file/process/stream/tcp/timer/udp）
│   └── windows.zig        # Windows 平台特定
└── libxev.md              # 综合使用指南
```
