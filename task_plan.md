# Task Plan: libxev — 跨平台异步事件循环 (fixnet fork)

> 技术定论指针 → findings.md；版本基线 → progress.md；使用指南 → libxev.md。
> xev-1..xev-4（IOCP UDP connect / SQ overflow / Timer 取消 / IOCP 文档）08-24 CLOSE
> 留档定案不实施（详见 findings「跨项目指针」）；本库无计划中的功能待办，详细历史见 git log。

## 项目定位

本仓库是 [mitchellh/libxev](https://github.com/mitchellh/libxev) 的 fixnet fork，
为 fixnet 生态（zigbox/zigtun/zigproxy/zigdns）提供跨平台异步 I/O 事件循环；
处于依赖图最底层，不依赖 zigfoundation。

## 当前状态

- 当前版本 v0.37.0（79a744d, 2026-09-06 生态 tag cut；v0.35/v0.36 = 无本仓代码提交、HEAD
  直 tag，v0.37.0 = e85719a iocp 修复 + 79a744d 文档）。版本与提交史 → progress.md
  「版本同步基线」表 + git log。
- 后端完备：kqueue(macOS/BSD) / epoll / io_uring(Linux) / IOCP(Windows) / wasi_poll。
- 历史完成项（kqueue connect errno / Timer 时钟 / io_uring 同步 close / IOCP ConnectEx-WSA
  -CloseHandle-stop_completion / NONBLOCK initFd / EINTR 重试等）→ progress「版本同步基线」
  v0.7.3~v0.11.0 行 + git log。

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
