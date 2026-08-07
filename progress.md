# Progress Log

## 2026-08-05: v0.16.0 — 全项目统一版本发布 ✅

libxev 无代码变更，参与版本同步。

## 2026-08-04: v0.13.x — 轻量协议搬迁 + 全项目统一版本发布 ✅

- v0.13.3: zigoutbounds/zigbox 轻量协议物理搬迁，libxev 无代码变更
- v0.13.2: CLAUDE.md 新增 Zig 0.16.0 开发规则 + 全异步 IO 铁律；kqueue.zig 新增 recv/read 调试日志

## 2026-07-28 ~ 08-02: v0.7.3 ~ v0.11.0 版本同步 ✅

IOCP ConnectEx/WSA 错误映射/CloseHandle/stop_completion、TCP/UDP NONBLOCK initFd、libxev.md 文档完善。
参与 fixnet 统一版本管理（v0.6.0 → v0.11.0）。

## 历史要点

- IOCP ConnectEx 异步连接 — 动态加载 ConnectEx 替代同步 connect()，修复 Windows 远程出站全断问题
- kqueue close 可能阻塞 — 调用者需配置 ThreadPool
- io_uring close 同步化 — 避免异步 close 的生命周期竞争
- libxev 处于 fixnet 依赖图最底层，不依赖 zigfoundation

> 详细实现过程见 git history。跨后端踩坑记录见 `findings.md`。
