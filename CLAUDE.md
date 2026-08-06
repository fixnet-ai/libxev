# Zig 0.16.0 Development Rules

## Tech Stack & Environment
- **Language**: Zig 0.16.0 (Strictly enforce 0.16.0 syntax, DO NOT use 0.15.x or older deprecated patterns)
- **Tooling**: ZLS (Zig Language Server)

## Critical Code Style & Idioms for 0.16.0
1. **Async & Concurrency**: Zig 0.16.0 has removed the `async`/`await` keywords from the language, but has enhanced async IO through the `std.Io` interface (Future / Completion / event-driven non-blocking IO). Use `std.Io` abstractions; do not spawn raw OS threads unless explicitly required.
2. **Build System (`build.zig`)**: Always use the 0.16.0 `std.Build` API. Many older build functions have been consolidated or renamed. Never use `b.addBuildTask` or older 0.11-0.13 paradigms.
3. **Allocator Handling**: Always pass `allocator: std.mem.Allocator` as the first or last parameter to functions requiring allocation. Do not use global state for allocation.
4. **Error Handling**: Use `try`, `catch`, and `errdefer` for explicit resource tracking immediately after allocation or initialization.
5. **Memory Safety**: Prefer slices over raw pointers. Ensure `defer` and `errdefer` are used to prevent leaks.

## Verification Workflow
- BEFORE generating or refactoring any code, ALWAYS use the `zig-docs` MCP tool to query the Zig 0.16.0 standard library definition.
- DO NOT hallucinate standard library functions. Use `@memcpy` for regular memory copies; `std.mem.copyForwards` / `std.mem.copyBackwards` only for overlapping memory.


# CLAUDE.md

> **通用规则（日志规范、Zig 0.16.0、唯一实现源、行为准则、代码编写规范、调试铁律等）**
> 已在用户级 `~/.claude/CLAUDE.md` 中统一定义，本项目不再重复。
>
> **⚠️ `error.Unexpected` 致命错误**：开发测试阶段，`error.Unexpected`（或语义等价的意外状态错误）必须视为致命错误立即 panic，严禁静默吞掉。完整规则见用户级 CLAUDE.md § 调试铁律 #5。
>
> 本文件仅包含 libxev 项目特有信息（本 repo 是 mitchellh/libxev 的 fixnet fork）。

## 项目概述

libxev 是跨平台异步事件循环库。本 fork 在 upstream 基础上增加了修复和定制。

### 后端

| 后端 | 平台 | 文件 |
|------|------|------|
| **kqueue** | macOS | `src/backend/kqueue.zig` |
| **epoll** | Linux | `src/backend/epoll.zig` |
| **io_uring** | Linux | `src/backend/io_uring.zig` |
| **IOCP** | Windows | `src/backend/iocp.zig` |

### fork 定制 / 修复

- **EADDRNOTAVAIL / EHOSTDOWN 映射修复**: 在 `kqueue` 后端中映射为 `error.AddressNotAvailable` / `error.HostDown`
- **io_uring 同步 close 修复**: `close()` 操作改为同步而非异步，避免 lifecycle 竞争
- **kevent EINTR 无限重试**: `kevent_syscall` 在收到 `EINTR` 时自动重试
- **IOCP ConnectEx 异步连接**: `connect()` 替换为 `ConnectEx`，对标已有的 `AcceptEx` 模式。标准 `connect()` 在 overlapped socket 上对远程地址返回 `WSAEWOULDBLOCK` 且不投递 IOCP 完成通知，导致所有远程出站连接失败。修改涉及：`windows.zig`（WSAID_CONNECTEX、loadConnectEx）、`iocp.zig` 的 `handle()`/`start_completion`/`perform`/`stop_completion`

### close() 行为差异

| 后端 | close 方式 | 说明 |
|------|-----------|------|
| kqueue / epoll | 同步 `posix.close(fd)` | OS 自动取消该 fd 上的所有事件 |
| IOCP | 异步 close 队列 + delayed timer | 防止陈旧 I/O 完成项 crash（参见 zigproxy/libxev.md） |
| io_uring | 同步 close | 避免异步 close 的 completion 竞争 |

### Completion 生命周期规则

- completion 必须在对应 callback 返回后才能重用
- `c.* = .{...}` + `add(c)` 是惯用法，但 **completion 不能在 submissions 队列中时重复 add**
- kqueue 后端：在 callback 内部 add 是安全的（callback 在执行时已从 submissions 移除）
- IOCP 后端：close 后可能有陈旧 completion，需 delayed release 保护（见 zigproxy/libxev.md）

## 编码前必学：zig skill 与 zig-codegen.md

**编写任何 Zig 代码前，必须先学习以下两个资源，避免写出错误代码：**

1. **zig skill** — `.claude/skills/zig/SKILL.md`：Zig 0.16.0 语言模式、标准库用法、编码规范
2. **zig-codegen.md** — `../zigfoundation/zig-codegen.md`：fixnet 生态积累的编译错误经验与陷阱

**规则：**
- 编码前通读，目标是**一次性写对**，而非编码后修补
- 遇到编译错误后，必须更新 zig-codegen.md 并重新学习相关章节
- 不要凭其他语言经验猜测 Zig 语法，先查这两个资源

## 编码规则

libxev 处于 fixnet 依赖图最底层，不依赖 zigfoundation 或其他 fixnet 项目。编码时只使用 Zig 标准库和 libxev 自身 API。

## 全异步 IO 铁律

**本项目是异步 IO 事件循环库。所有 IO 操作必须异步完成，严禁任何同步阻塞 IO。**

libxev 的存在意义就是提供异步 IO。任何在 libxev 中使用同步阻塞 IO 的代码都是根本性设计错误。

**例外：** 测试/工具脚本（Python）是唯一允许使用同步 IO 的场景。

## 构建命令

```bash
zig build                    # 构建库
zig build test               # 运行所有测试
```

## 依赖

| 依赖 | 用途 |
|------|------|
| ThreadPool (可选) | 文件 I/O 等无异步 API 的操作 |


## 参考

- Upstream: https://github.com/mitchellh/libxev
- zigproxy/libxev.md: IOCP 延迟释放等集成经验
