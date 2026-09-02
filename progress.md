# Progress Log

> v0.34.0 里程碑：版本同步记录压缩为基线表；技术定论指针化（源码注释 / findings.md / git history）。

## 版本同步基线（全项目统一发布；本库除注明外无代码变更）

| 版本 | 日期 | 说明 |
|------|------|------|
| v0.34.0 | 2026-09-02 | 生态统一里程碑 tag（本库 v0.33.0 后仅文档同步 cf4a683/68dd4a7，无代码变更） |
| v0.33.0 | 2026-09-01 | 生态统一发布；v0.22.0..v0.33.0 含 22 个 fixnet 代码提交（IPv6 28B addr 缓冲 7f96ad7/0dfe6f2/7bcb818、IOCP AsyncIOCP UAF 8f118a7 + PQCS 合并 8747a31、readv/writev 06d0c35、TCP_NODELAY 440f056 等） |
| v0.22.0 | 2026-08-09 | 全项目统一版本发布 |
| v0.16.0 | 2026-08-05 | 全项目统一版本发布 |
| v0.13.3 | 2026-08-04 | zigoutbounds/zigbox 轻量协议物理搬迁，本库无代码变更 |
| v0.13.2 | 2026-08-04 | CLAUDE.md 新增 Zig 0.16.0 开发规则 + 全异步 IO 铁律；kqueue.zig 新增 recv/read 调试日志 |
| v0.7.3 ~ v0.11.0 | 2026-07-28 ~ 08-02 | IOCP ConnectEx/WSA 错误映射/CloseHandle/stop_completion、TCP/UDP NONBLOCK initFd、libxev.md 文档完善 |

## 历史要点

- **2026-08-19 io_uring 零长度探词 → POLL_ADD（fork 维护）**：commit a9a3516；背景 = zigbox Linux VM 回归 trojan TLS 竞态挂死调查（主修在 zo tls.zig fd 非阻塞，本修复为探词语义正确性保留）；技术细节见 findings.md 跨后端差异 + io_uring.zig :490-503。
- libxev 处于 fixnet 依赖图最底层，不依赖 zigfoundation（见 CLAUDE.md 编码规则）。
- 跨后端踩坑记录见 findings.md；详细实现过程见 git history。
