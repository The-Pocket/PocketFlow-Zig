/// The `Context` is a thread-safe hash map that holds the shared state between nodes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const testing = std.testing;

const StoredValue = struct {
    ptr: *anyopaque,
    destructor: *const fn (allocator: Allocator, ptr: *anyopaque) void,
};

pub const Context = struct {
    allocator: Allocator,
    data: StringHashMap(StoredValue),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: Allocator) Context {
        return .{
            .allocator = allocator,
            .data = StringHashMap(StoredValue).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Context) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Free all stored values using their destructors
        var key_it = self.data.iterator();
        while (key_it.next()) |entry| {
            entry.value_ptr.destructor(self.allocator, entry.value_ptr.ptr);
        }

        self.data.deinit();
    }

    pub fn get(self: *Context, comptime T: type, key: []const u8) ?T {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.data.get(key)) |stored_value| {
            const typed_ptr: *const T = @ptrCast(@alignCast(stored_value.ptr));
            return typed_ptr.*;
        }
        return null;
    }

    pub fn set(self: *Context, key: []const u8, value: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const T = @TypeOf(value);

        // Check if we're replacing an existing value
        if (self.data.get(key)) |old_stored_value| {
            old_stored_value.destructor(self.allocator, old_stored_value.ptr);
        }

        // Always allocate space for T and store a pointer to it
        // This ensures consistent storage regardless of T being a pointer, struct, slice, etc.
        const ptr = try self.allocator.create(T);
        ptr.* = value;

        // Create a destructor function for this type
        const destructor = struct {
            fn destroy(allocator: Allocator, p: *anyopaque) void {
                const typed_ptr: *T = @ptrCast(@alignCast(p));
                allocator.destroy(typed_ptr);
            }
        }.destroy;

        const stored_value = StoredValue{
            .ptr = @ptrCast(ptr),
            .destructor = destructor,
        };

        try self.data.put(key, stored_value);
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "Context - init and deinit" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // Context should be usable after init
    try ctx.set("test", @as(i32, 42));
    const value = ctx.get(i32, "test");
    try testing.expectEqual(@as(?i32, 42), value);
}

test "Context - set and get basic types" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    // Test i32
    try ctx.set("int_val", @as(i32, 123));
    try testing.expectEqual(@as(?i32, 123), ctx.get(i32, "int_val"));

    // Test u64
    try ctx.set("u64_val", @as(u64, 999999999999));
    try testing.expectEqual(@as(?u64, 999999999999), ctx.get(u64, "u64_val"));

    // Test bool
    try ctx.set("bool_val", true);
    try testing.expectEqual(@as(?bool, true), ctx.get(bool, "bool_val"));

    // Test f32
    try ctx.set("float_val", @as(f32, 3.14));
    try testing.expectEqual(@as(?f32, 3.14), ctx.get(f32, "float_val"));
}

test "Context - get non-existent key returns null" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const result = ctx.get(i32, "non_existent");
    try testing.expectEqual(@as(?i32, null), result);
}

test "Context - set replaces existing value" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    try ctx.set("key", @as(i32, 100));
    try testing.expectEqual(@as(?i32, 100), ctx.get(i32, "key"));

    try ctx.set("key", @as(i32, 200));
    try testing.expectEqual(@as(?i32, 200), ctx.get(i32, "key"));
}

test "Context - set and get slices" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const original = "Hello, PocketFlow!";
    const slice: []const u8 = original;
    try ctx.set("message", slice);

    const retrieved = ctx.get([]const u8, "message");
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings(original, retrieved.?);
}

test "Context - multiple keys" {
    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    try ctx.set("key1", @as(i32, 1));
    try ctx.set("key2", @as(i32, 2));
    try ctx.set("key3", @as(i32, 3));

    try testing.expectEqual(@as(?i32, 1), ctx.get(i32, "key1"));
    try testing.expectEqual(@as(?i32, 2), ctx.get(i32, "key2"));
    try testing.expectEqual(@as(?i32, 3), ctx.get(i32, "key3"));
}

test "Context - set and get struct" {
    const TestStruct = struct {
        x: i32,
        y: i32,
        name: []const u8,
    };

    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    const value = TestStruct{ .x = 10, .y = 20, .name = "test" };
    try ctx.set("struct_val", value);

    const retrieved = ctx.get(TestStruct, "struct_val");
    try testing.expect(retrieved != null);
    try testing.expectEqual(@as(i32, 10), retrieved.?.x);
    try testing.expectEqual(@as(i32, 20), retrieved.?.y);
    try testing.expectEqualStrings("test", retrieved.?.name);
}
