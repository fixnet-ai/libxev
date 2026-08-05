# Progress Log

## 2026-08-05: v0.16.0 — 全项目统一版本发布 ✅

zigfoundation / libxev / zigtun / zigproxy / zigdns / zigoutbounds / zigbox 统一发布 v0.16.0。
libxev 无代码变更，参与版本同步。

## 2026-08-04: v0.13.3 — 轻量协议搬迁 + 全项目统一版本发布 ✅

核心变更：zigoutbounds/zigbox 轻量协议物理搬迁（7 文件移至 zigoutbounds/src/light/）。
libxev 无代码变更，参与版本同步。

## 2026-08-04: v0.13.2 — 全项目统一版本发布 ✅

- `CLAUDE.md` — 新增 Zig 0.16.0 开发规则 + 全异步 IO 铁律
- `kqueue.zig` — 新增 recv/read 调试日志
- `.claude/skills/zig-async-skill/` — 新增 Zig 异步编码 skill
- zigfoundation / libxev / zigtun / zigproxy / zigdns / zigoutbounds / zigbox 统一发布 v0.13.2。

## 2026-08-02: v0.11.0 — 全项目统一版本对齐 ✅

zigfoundation / libxev / zigtun / zigproxy / zigdns / zigbox 统一发布 v0.11.0。

## 2026-07-31: v0.10.2 — 日志英文规范 + zig skill 增强 + 软链接统一 ✅

### 日志规范规则 #6 审计
- libxev 是底层 C 项目 fork，不参与日志规范审计（无 std.log 使用）
- 无代码变更

### zig skill SKILL.md 增强
- zigfoundation 权威源末尾新增「编码前必读：zig-codegen.md」章节，通过软链接自动同步

### 软链接统一
- 新建 zig-codegen.md 软链接 → zigfoundation 权威源
- zig skill 软链接确认正常

### 规划文档同步
- progress.md / task_plan.md 同步至 v0.10.2

## 2026-07-30: v0.8.5 ✅

无代码变更。统一 tag 推进。

## 2026-07-30: v0.8.3 — libxev.md IO 解耦文档更新 ✅

### 变更

- `libxev.md`：新增"IO 解耦后的类型访问方式"章节，文档化 `@import("zigfoundation").io` 类型别名方式。
  所有示例代码改用 `const xev = @import("zigfoundation").io;`，后端行为差异描述保持不变。

### 背景

zigbox 全项目 IO 解耦后，libxev 类型通过 zigfoundation 的 io 模块统一导出，不再直接 `@import("xev")`。

## 2026-07-29 (session 19): libxev.md 同步 ✅

同步自 v0.7.3 以来的 8 个 commit 到 libxev.md：
- kqueue connect EISCONN 映射、Timer 时钟更新
- IOCP ConnectEx、stop_completion、WSA 错误映射、CloseHandle 修复
- TCP/UDP initFd NONBLOCK 设置

libxev.md：834 → 1037 行。

## 2026-07-29: v0.7.4 跨项目统一发布 ✅

全部 6 项目同步 tag v0.7.4。libxev 参与 tag 对齐，无代码变更。

## 2026-07-28: v0.7.3 发布 ✅

首次参与 fixnet 统一版本管理。

### 关键修复

| Commit | 内容 |
|--------|------|
| `ec2c332` | IOCP 完成阶段 WSA 错误码映射补全（send/recv/sendto/recvfrom） |
| `1a1eb49` | IOCP stop_completion panic for non-IOCP ops |
| `8132f5b` | IOCP ConnectEx 异步连接文档 |
| `b10ccf7` | IOCP ConnectEx 异步连接实现 |
| `a3b02c2` | TCP/UDP initFd 设置 NONBLOCK |

## 2026-07-25: v0.6.0 跨项目统一发布 ✅

首次使用 fixnet 统一版本号 v0.6.0。此前使用 upstream 的版本号体系。

## 历史关键修复

### IOCP ConnectEx 异步连接（2026-07-26）

**根因**：IOCP 后端 `connect()` 在 overlapped socket 上对远程地址返回 `WSAEWOULDBLOCK`，不投递 IOCP 完成通知。原代码将此当 fatal error，导致 Windows notun 模式所有远程出站连接失败。

**修复**：对标已有 `AcceptEx` 模式添加 `ConnectEx` 支持。ConnectEx 通过 `WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER)` 运行态加载。

### kqueue close 需要 ThreadPool

macOS kqueue 后端 `TCP.close()` 可能阻塞，调用者（zigbox `--local-echo`）必须配置 ThreadPool。

### io_uring close 同步化

close() 改为同步操作，避免异步 close 的生命周期竞争问题。

---

## 版本历史

| 版本 | 日期 | 关键变更 |
|------|------|---------|
| v0.7.4 | 2026-07-29 | 跨项目统一发布 |
| v0.7.3 | 2026-07-29 | libxev.md 文档同步 + IOCP 修复 |
| v0.6.0 | 2026-07-25 | 跨项目统一发布 |

## 2026-07-30 — v0.9.1 跨项目统一版本发布

- 统一版本号对齐 zigbox v0.9.1
- 本版本无代码变更，仅跟进跨项目统一发布

## v0.9.1 补充 — 撤销 CLAUDE.md 编码规则

- 撤销了错误添加的 zigfoundation 编码规则（libxev 是底层依赖，不应反向依赖 zigfoundation）
- Commit: `446200f` on main

## 2026-07-30 — v0.9.1 补充 — zig-codegen.md 重组（zigfoundation）

- zigfoundation 的 zig-codegen.md 重组：1794行/19章 → 1166行/12章+1附录
- 修正 async/await 替代方案描述，合并冗余的校验和/catch 章节
- Commit: `81f6c58` on zigfoundation main

## 2026-07-30 — v0.9.1 补充 — CLAUDE.md 学习规则

- **编码前必学规则**：CLAUDE.md 新增"zig skill + zig-codegen.md 学习要求"章节
- 新建 `.claude/skills/zig` symlink → zigfoundation 的 zig skill
- Commit: `851eeca` on main

## 2026-07-30 — v0.10.0 CLAUDE.md 统一优化

- **CLAUDE.md 统一优化**：新增"编码规则"章节说明 libxev 处于依赖图最底层、不依赖 zigfoundation
- Commit: `9476af0` on main
