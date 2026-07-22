# CLAUDE.md

> **通用规则（日志规范、Zig 0.16.0、唯一实现源、行为准则、代码编写规范等）**
> 已在用户级 `~/.claude/CLAUDE.md` 中统一定义，本项目不再重复。
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
