/// The `Flow` manages the execution of nodes in a graph.
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Action = @import("node.zig").Action;
const BaseNode = @import("node.zig").BaseNode;
const Context = @import("context.zig").Context;
const Node = @import("node.zig").Node;

pub const Flow = struct {
    start_node: Node,
    allocator: Allocator,

    pub fn init(allocator: Allocator, start_node: Node) Flow {
        return .{
            .allocator = allocator,
            .start_node = start_node,
        };
    }

    pub fn run(self: *Flow, context: *Context) !void {
        var current_node: ?Node = self.start_node;

        while (current_node) |node| {
            const prep_res = try node.prep(self.allocator, context);
            defer node.cleanupPrep(self.allocator, prep_res);

            const exec_res = try node.exec(self.allocator, prep_res);
            defer node.cleanupExec(self.allocator, exec_res);

            const action = try node.post(self.allocator, context, prep_res, exec_res);

            const base_node: *BaseNode = @ptrCast(@alignCast(node.self));

            current_node = base_node.successors.get(action);
        }
    }
};

// ============================================================================
// TESTS
// ============================================================================

/// A counter node for testing flow execution
const CounterNode = struct {
    base: BaseNode,
    exec_count: *usize,
    node_id: usize,
    return_action: []const u8,

    pub fn init(allocator: Allocator, exec_count: *usize, node_id: usize, return_action: []const u8) *CounterNode {
        const self = allocator.create(CounterNode) catch @panic("oom");
        self.* = .{
            .base = BaseNode.init(allocator),
            .exec_count = exec_count,
            .node_id = node_id,
            .return_action = return_action,
        };
        return self;
    }

    pub fn deinit(self: *CounterNode, allocator: Allocator) void {
        self.base.deinit();
        allocator.destroy(self);
    }

    pub fn prep(_: *anyopaque, allocator: Allocator, _: *Context) !*anyopaque {
        const result = try allocator.create(u8);
        result.* = 0;
        return @ptrCast(result);
    }

    pub fn exec(self_ptr: *anyopaque, allocator: Allocator, _: *anyopaque) !*anyopaque {
        const self: *CounterNode = @ptrCast(@alignCast(self_ptr));
        self.exec_count.* += 1;

        const result = try allocator.create(usize);
        result.* = self.node_id;
        return @ptrCast(result);
    }

    pub fn post(self_ptr: *anyopaque, _: Allocator, context: *Context, _: *anyopaque, exec_res: *anyopaque) !Action {
        const self: *CounterNode = @ptrCast(@alignCast(self_ptr));
        const node_id: *usize = @ptrCast(@alignCast(exec_res));

        // Store the last executed node id in context
        try context.set("last_node", node_id.*);

        return self.return_action;
    }

    pub fn cleanup_prep(_: *anyopaque, allocator: Allocator, prep_res: *anyopaque) void {
        const ptr: *u8 = @ptrCast(@alignCast(prep_res));
        allocator.destroy(ptr);
    }

    pub fn cleanup_exec(_: *anyopaque, allocator: Allocator, exec_res: *anyopaque) void {
        const ptr: *usize = @ptrCast(@alignCast(exec_res));
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

test "Flow - init" {
    var exec_count: usize = 0;
    const node = CounterNode.init(testing.allocator, &exec_count, 1, "default");
    defer node.deinit(testing.allocator);

    const wrapper = Node{ .self = node, .vtable = &CounterNode.VTABLE };
    const flow = Flow.init(testing.allocator, wrapper);

    try testing.expect(flow.start_node.self == @as(*anyopaque, @ptrCast(node)));
}

test "Flow - run single node" {
    var exec_count: usize = 0;
    const node = CounterNode.init(testing.allocator, &exec_count, 1, "end");
    defer node.deinit(testing.allocator);

    const wrapper = Node{ .self = node, .vtable = &CounterNode.VTABLE };
    var flow = Flow.init(testing.allocator, wrapper);

    var context = Context.init(testing.allocator);
    defer context.deinit();

    try flow.run(&context);

    try testing.expectEqual(@as(usize, 1), exec_count);
    try testing.expectEqual(@as(?usize, 1), context.get(usize, "last_node"));
}

test "Flow - run chain of nodes" {
    var exec_count: usize = 0;

    const node1 = CounterNode.init(testing.allocator, &exec_count, 1, "default");
    defer node1.deinit(testing.allocator);

    const node2 = CounterNode.init(testing.allocator, &exec_count, 2, "default");
    defer node2.deinit(testing.allocator);

    const node3 = CounterNode.init(testing.allocator, &exec_count, 3, "end");
    defer node3.deinit(testing.allocator);

    const wrapper1 = Node{ .self = node1, .vtable = &CounterNode.VTABLE };
    const wrapper2 = Node{ .self = node2, .vtable = &CounterNode.VTABLE };
    const wrapper3 = Node{ .self = node3, .vtable = &CounterNode.VTABLE };

    // Chain: node1 -> node2 -> node3
    try node1.base.next("default", wrapper2);
    try node2.base.next("default", wrapper3);

    var flow = Flow.init(testing.allocator, wrapper1);

    var context = Context.init(testing.allocator);
    defer context.deinit();

    try flow.run(&context);

    try testing.expectEqual(@as(usize, 3), exec_count);
    try testing.expectEqual(@as(?usize, 3), context.get(usize, "last_node"));
}

test "Flow - branching based on action" {
    var exec_count: usize = 0;

    const node1 = CounterNode.init(testing.allocator, &exec_count, 1, "branch_a");
    defer node1.deinit(testing.allocator);

    const node_a = CounterNode.init(testing.allocator, &exec_count, 10, "end");
    defer node_a.deinit(testing.allocator);

    const node_b = CounterNode.init(testing.allocator, &exec_count, 20, "end");
    defer node_b.deinit(testing.allocator);

    const wrapper1 = Node{ .self = node1, .vtable = &CounterNode.VTABLE };
    const wrapper_a = Node{ .self = node_a, .vtable = &CounterNode.VTABLE };
    const wrapper_b = Node{ .self = node_b, .vtable = &CounterNode.VTABLE };

    // Branch: node1 can go to node_a or node_b
    try node1.base.next("branch_a", wrapper_a);
    try node1.base.next("branch_b", wrapper_b);

    var flow = Flow.init(testing.allocator, wrapper1);

    var context = Context.init(testing.allocator);
    defer context.deinit();

    try flow.run(&context);

    // Should have executed node1 and node_a (branch_a path)
    try testing.expectEqual(@as(usize, 2), exec_count);
    try testing.expectEqual(@as(?usize, 10), context.get(usize, "last_node"));
}

test "Flow - stops when no successor found" {
    var exec_count: usize = 0;

    const node1 = CounterNode.init(testing.allocator, &exec_count, 1, "nonexistent");
    defer node1.deinit(testing.allocator);

    const wrapper1 = Node{ .self = node1, .vtable = &CounterNode.VTABLE };

    var flow = Flow.init(testing.allocator, wrapper1);

    var context = Context.init(testing.allocator);
    defer context.deinit();

    try flow.run(&context);

    // Should only execute the first node, then stop (no successor for "nonexistent")
    try testing.expectEqual(@as(usize, 1), exec_count);
}
