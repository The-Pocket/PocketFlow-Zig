/// The `Node` defines the basic unit of work with `prep`, `exec`, and `post` methods.
/// We use a vtable to create a generic interface.
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Context = @import("context.zig").Context;

pub const Action = []const u8;

pub const Node = struct {
    self: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        prep: *const fn (self: *anyopaque, allocator: Allocator, context: *Context) anyerror!*anyopaque,
        exec: *const fn (self: *anyopaque, allocator: Allocator, prep_res: *anyopaque) anyerror!*anyopaque,
        post: *const fn (self: *anyopaque, allocator: Allocator, context: *Context, prep_res: *anyopaque, exec_res: *anyopaque) anyerror!Action,
        cleanup_prep: *const fn (self: *anyopaque, allocator: Allocator, prep_res: *anyopaque) void,
        cleanup_exec: *const fn (self: *anyopaque, allocator: Allocator, exec_res: *anyopaque) void,
    };

    pub fn prep(self: Node, allocator: Allocator, context: *Context) !*anyopaque {
        return self.vtable.prep(self.self, allocator, context);
    }

    pub fn exec(self: Node, allocator: Allocator, prep_res: *anyopaque) !*anyopaque {
        return self.vtable.exec(self.self, allocator, prep_res);
    }

    pub fn post(self: Node, allocator: Allocator, context: *Context, prep_res: *anyopaque, exec_res: *anyopaque) !Action {
        return self.vtable.post(self.self, allocator, context, prep_res, exec_res);
    }

    pub fn cleanupPrep(self: Node, allocator: Allocator, prep_res: *anyopaque) void {
        self.vtable.cleanup_prep(self.self, allocator, prep_res);
    }

    pub fn cleanupExec(self: Node, allocator: Allocator, exec_res: *anyopaque) void {
        self.vtable.cleanup_exec(self.self, allocator, exec_res);
    }
};

pub const BaseNode = struct {
    successors: std.StringHashMap(Node),

    pub fn init(allocator: Allocator) BaseNode {
        return .{
            .successors = std.StringHashMap(Node).init(allocator),
        };
    }

    pub fn deinit(self: *BaseNode) void {
        self.successors.deinit();
    }

    pub fn next(self: *BaseNode, action: Action, node: Node) !void {
        try self.successors.put(action, node);
    }
};

// ============================================================================
// TESTS
// ============================================================================

/// A simple test node implementation for unit testing
const TestNode = struct {
    base: BaseNode,
    prep_called: bool = false,
    exec_called: bool = false,
    post_called: bool = false,
    prep_value: i32 = 0,
    exec_value: i32 = 0,

    pub fn init(allocator: Allocator) *TestNode {
        const self = allocator.create(TestNode) catch @panic("oom");
        self.* = .{
            .base = BaseNode.init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *TestNode, allocator: Allocator) void {
        self.base.deinit();
        allocator.destroy(self);
    }

    pub fn prep(self_ptr: *anyopaque, allocator: Allocator, context: *Context) !*anyopaque {
        const self: *TestNode = @ptrCast(@alignCast(self_ptr));
        self.prep_called = true;

        // Get value from context if available
        const input = context.get(i32, "input") orelse 0;
        self.prep_value = input;

        const result = try allocator.create(i32);
        result.* = input * 2;
        return @ptrCast(result);
    }

    pub fn exec(_: *anyopaque, allocator: Allocator, prep_res: *anyopaque) !*anyopaque {
        const input: *i32 = @ptrCast(@alignCast(prep_res));

        const result = try allocator.create(i32);
        result.* = input.* + 10;
        return @ptrCast(result);
    }

    pub fn post(self_ptr: *anyopaque, _: Allocator, context: *Context, _: *anyopaque, exec_res: *anyopaque) !Action {
        const self: *TestNode = @ptrCast(@alignCast(self_ptr));
        self.post_called = true;

        const result: *i32 = @ptrCast(@alignCast(exec_res));
        self.exec_value = result.*;
        try context.set("output", result.*);

        return "next";
    }

    pub fn cleanup_prep(_: *anyopaque, allocator: Allocator, prep_res: *anyopaque) void {
        const ptr: *i32 = @ptrCast(@alignCast(prep_res));
        allocator.destroy(ptr);
    }

    pub fn cleanup_exec(_: *anyopaque, allocator: Allocator, exec_res: *anyopaque) void {
        const ptr: *i32 = @ptrCast(@alignCast(exec_res));
        allocator.destroy(ptr);
    }

    pub const VTABLE = Node.VTable{
        .prep = prep,
        .exec = exec,
        .post = post,
        .cleanup_prep = cleanup_prep,
        .cleanup_exec = cleanup_exec,
    };
};

test "BaseNode - init and deinit" {
    var base = BaseNode.init(testing.allocator);
    defer base.deinit();

    try testing.expectEqual(@as(usize, 0), base.successors.count());
}

test "BaseNode - add successors" {
    const node1 = TestNode.init(testing.allocator);
    defer node1.deinit(testing.allocator);

    const node2 = TestNode.init(testing.allocator);
    defer node2.deinit(testing.allocator);

    const wrapper2 = Node{ .self = node2, .vtable = &TestNode.VTABLE };

    try node1.base.next("default", wrapper2);

    try testing.expectEqual(@as(usize, 1), node1.base.successors.count());
    try testing.expect(node1.base.successors.get("default") != null);
}

test "BaseNode - multiple successors" {
    const node1 = TestNode.init(testing.allocator);
    defer node1.deinit(testing.allocator);

    const node2 = TestNode.init(testing.allocator);
    defer node2.deinit(testing.allocator);

    const node3 = TestNode.init(testing.allocator);
    defer node3.deinit(testing.allocator);

    const wrapper2 = Node{ .self = node2, .vtable = &TestNode.VTABLE };
    const wrapper3 = Node{ .self = node3, .vtable = &TestNode.VTABLE };

    try node1.base.next("success", wrapper2);
    try node1.base.next("failure", wrapper3);

    try testing.expectEqual(@as(usize, 2), node1.base.successors.count());
    try testing.expect(node1.base.successors.get("success") != null);
    try testing.expect(node1.base.successors.get("failure") != null);
}

test "Node - vtable prep/exec/post cycle" {
    const test_node = TestNode.init(testing.allocator);
    defer test_node.deinit(testing.allocator);

    const wrapper = Node{ .self = test_node, .vtable = &TestNode.VTABLE };

    var context = Context.init(testing.allocator);
    defer context.deinit();

    try context.set("input", @as(i32, 5));

    // Run prep
    const prep_res = try wrapper.prep(testing.allocator, &context);
    defer wrapper.cleanupPrep(testing.allocator, prep_res);

    try testing.expect(test_node.prep_called);
    try testing.expectEqual(@as(i32, 5), test_node.prep_value);

    // Run exec
    const exec_res = try wrapper.exec(testing.allocator, prep_res);
    defer wrapper.cleanupExec(testing.allocator, exec_res);

    // Run post
    const action = try wrapper.post(testing.allocator, &context, prep_res, exec_res);

    try testing.expect(test_node.post_called);
    try testing.expectEqualStrings("next", action);

    // Check output: input(5) * 2 = 10, then + 10 = 20
    const output = context.get(i32, "output");
    try testing.expectEqual(@as(?i32, 20), output);
}

test "Node - successor lookup returns null for unknown action" {
    const test_node = TestNode.init(testing.allocator);
    defer test_node.deinit(testing.allocator);

    const result = test_node.base.successors.get("unknown");
    try testing.expectEqual(@as(?Node, null), result);
}
