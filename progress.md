# Progress Log

> 第 4 轮瘦身：版本同步记录压缩为基线表；技术定论指针化（代码注释 / findings.md / git history）。

## 版本同步基线（全项目统一发布；本库除注明外无代码变更）

| 版本 | 日期 | 说明 |
|------|------|------|
| v0.22.0 | 2026-08-09 | 全项目统一版本发布 |
| v0.16.0 | 2026-08-05 | 全项目统一版本发布 |
| v0.13.3 | 2026-08-04 | zigoutbounds/zigbox 轻量协议物理搬迁，本库无代码变更 |
| v0.13.2 | 2026-08-04 | CLAUDE.md 新增 Zig 0.16.0 开发规则 + 全异步 IO 铁律；kqueue.zig 新增 recv/read 调试日志 |
| v0.7.3 ~ v0.11.0 | 2026-07-28 ~ 08-02 | IOCP ConnectEx/WSA 错误映射/CloseHandle/stop_completion、TCP/UDP NONBLOCK initFd、libxev.md 文档完善 |

## 2026-08-19: io_uring 零长度探词 → POLL_ADD（fork 维护）

> 技术细节已落代码注释：io_uring.zig `.recv`/`.send` 零长度 slice 分支（翻译为 POLL_ADD，完成时合成 res=0）。commit a9a3516。
背景：zigbox Linux VM 回归 trojan TLS 竞态挂死调查（主修在 zo tls.zig 的 fd 非阻塞，本修复为探词语义正确性保留）。详见 zigbox findings「VM 回归固化 + #61 真凶修正」。

## 历史要点

- libxev 处于 fixnet 依赖图最底层，不依赖 zigfoundation（见 CLAUDE.md 编码规则）。
- 跨后端踩坑记录见 findings.md；详细实现过程见 git history。
