# Task Plan: libxev — 跨平台异步事件循环 (fixnet fork)

> 技术定论指针 → findings.md；版本基线 → progress.md；使用指南 → libxev.md。
> 开放待办（IOCP UDP connect / SQ overflow / Timer 取消 / IOCP 文档）已移交
> zigbox task_plan.md「跨项目统一待办」。详细历史见 git log。

## 项目定位

本仓库是 [mitchellh/libxev](https://github.com/mitchellh/libxev) 的 fixnet fork，
为 fixnet 生态（zigbox/zigtun/zigproxy/zigdns）提供跨平台异步 I/O 事件循环；
处于依赖图最底层，不依赖 zigfoundation。

## 当前状态

- 当前版本 v0.33.0 (2026-09-01 生态 tag cut) — v0.22.0 (2026-08-09) 后本库有 fixnet
  代码变更（v0.22.0..v0.33.0 共 22 提交：IPv6 28B addr 缓冲 / IOCP AsyncIOCP UAF +
  PQCS 合并 / readv-writev 批量 / TCP_NODELAY 等，见 git log + progress「版本同步基线」）。
- 后端完备：kqueue(macOS/BSD) / epoll / io_uring(Linux) / IOCP(Windows) / wasi_poll。
- 已完成：kqueue connect errno 修复、Timer 时钟更新、io_uring 同步 close、IOCP
  ConnectEx/WSA 映射/CloseHandle/stop_completion、TCP/UDP NONBLOCK initFd、EINTR 重试等。

## 模块架构

```
libxev/
├── src/
│   ├── main.zig / api.zig      # 入口 / pub API
│   ├── backend/
│   │   ├── kqueue.zig          # macOS/BSD
│   │   ├── epoll.zig           # Linux (epoll)
│   │   ├── io_uring.zig        # Linux (io_uring)
│   │   ├── iocp.zig            # Windows
│   │   └── wasi_poll.zig       # WASI
│   ├── watcher/                # async/file/process/stream/tcp/timer/udp
│   └── windows.zig             # Windows 平台特定
└── libxev.md                   # 综合使用指南
```

## 开放待办

无本库独立待办；统一待办真相源 = zigbox task_plan.md「跨项目统一待办」。
