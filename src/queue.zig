const std = @import("std");
const assert = std.debug.assert;

/// An intrusive queue implementation. The type T must have a field
/// "next" of type `?*T`.
///
/// For those unaware, an intrusive variant of a data structure is one in which
/// the data type in the list has the pointer to the next element, rather
/// than a higher level "node" or "container" type. The primary benefit
/// of this (and the reason we implement this) is that it defers all memory
/// management to the caller: the data structure implementation doesn't need
/// to allocate "nodes" to contain each element. Instead, the caller provides
/// the element and how its allocated is up to them.
pub fn Intrusive(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Head is the front of the queue and tail is the back of the queue.
        head: ?*T = null,
        tail: ?*T = null,

        /// Enqueue a new element to the back of the queue.
        pub fn push(self: *Self, v: *T) void {
            assert(v.next == null);

            if (self.tail) |tail| {
                // If we have elements in the queue, then we add a new tail.
                tail.next = v;
                self.tail = v;
            } else {
                // No elements in the queue we setup the initial state.
                self.head = v;
                self.tail = v;
            }
        }

        /// Dequeue the next element from the queue.
        pub fn pop(self: *Self) ?*T {
            // The next element is in "head".
            const next = self.head orelse return null;

            // If the head and tail are equal this is the last element
            // so we also set tail to null so we can now be empty.
            if (self.head == self.tail) self.tail = null;

            // Head is whatever is next (if we're the last element,
            // this will be null);
            self.head = next.next;

            // We set the "next" field to null so that this element
            // can be inserted again.
            next.next = null;
            return next;
        }

        /// 从队列中摘除指定节点（O(n)）。找到并摘除返回 true。
        ///
        /// 仅供「同步摘除」路径使用（kqueue `deleteSync`）：调用方若被告知**即刻拥有**
        /// 该节点（deleteSync 返回 true），就必须让它真正离开队列——否则同一节点可被
        /// 二次入队：尾节点时 `push` 的 `assert(v.next == null)` 不触发（尾节点 next
        /// 本就是 null），`tail.next = v` 直接构成自环，`pop()` 遂把同一节点返回两次，
        /// 第二次弹出时状态已被 `start()` 改成 `.active` → 打印
        /// "invalid state in submission queue state=.active" 并静默丢弃（既不补发
        /// EV_DELETE 也不触发 CANCELED 回调），knote 永生、每 tick 重派发。
        ///
        /// 真机实证（iOS，build c74d6b3b）与该场景对应的日志同源；本机最小复现见
        /// `watcher/async.zig` 的 `deleteSync on an .adding completion` 测试。
        pub fn remove(self: *Self, v: *T) bool {
            var prev: ?*T = null;
            var cur = self.head;
            while (cur) |c| {
                if (c == v) {
                    if (prev) |p| {
                        p.next = c.next;
                    } else {
                        self.head = c.next;
                    }
                    if (self.tail == c) self.tail = prev;
                    c.next = null;
                    return true;
                }
                prev = c;
                cur = c.next;
            }
            return false;
        }

        /// Returns true if the queue is empty.
        pub fn empty(self: *const Self) bool {
            return self.head == null;
        }
    };
}

test Intrusive {
    const testing = std.testing;

    // Types
    const Elem = struct {
        const Self = @This();
        next: ?*Self = null,
    };
    const Queue = Intrusive(Elem);
    var q: Queue = .{};
    try testing.expect(q.empty());

    // Elems
    var elems: [10]Elem = .{Elem{}} ** 10;

    // One
    try testing.expect(q.pop() == null);
    q.push(&elems[0]);
    try testing.expect(!q.empty());
    try testing.expect(q.pop().? == &elems[0]);
    try testing.expect(q.pop() == null);
    try testing.expect(q.empty());

    // Two
    try testing.expect(q.pop() == null);
    q.push(&elems[0]);
    q.push(&elems[1]);
    try testing.expect(q.pop().? == &elems[0]);
    try testing.expect(q.pop().? == &elems[1]);
    try testing.expect(q.pop() == null);

    // Interleaved
    try testing.expect(q.pop() == null);
    q.push(&elems[0]);
    try testing.expect(q.pop().? == &elems[0]);
    q.push(&elems[1]);
    try testing.expect(q.pop().? == &elems[1]);
    try testing.expect(q.pop() == null);
}
