const std = @import("std");
const Allocator = std.mem.Allocator;

const ollama = @import("ollama");
const Ollama = ollama.Ollama;
const pocketflow = @import("pocketflow");
const Node = pocketflow.Node;
const BaseNode = pocketflow.BaseNode;
const Context = pocketflow.Context;
const Flow = pocketflow.Flow;

// --- Node Implementations ---

const GenerateOutlineNode = struct {
    base: BaseNode,

    pub fn init(allocator: Allocator) *GenerateOutlineNode {
        const self = allocator.create(GenerateOutlineNode) catch @panic("oom");
        self.* = .{
            .base = BaseNode.init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *GenerateOutlineNode, allocator: Allocator) void {
        self.base.deinit();
        allocator.destroy(self);
    }

    pub fn prep(_: *anyopaque, allocator: Allocator, context: *Context) !*anyopaque {
        const topic = context.get([]const u8, "topic") orelse {
            std.debug.print("ERROR: topic not found in context!\n", .{});
            @panic("topic not found");
        };
        std.debug.print("Prep: Generating outline for topic: '{s}' (len: {})\n", .{ topic, topic.len });
        const prep_result = allocator.create([]const u8) catch @panic("oom");
        prep_result.* = topic;
        return @ptrCast(prep_result);
    }

    pub fn exec(_: *anyopaque, allocator: Allocator, prep_res: *anyopaque) !*anyopaque {
        const topic_ptr: *const []const u8 = @ptrCast(@alignCast(prep_res));
        const topic = topic_ptr.*;
        std.debug.print("Exec: Creating outline for topic: {s}...\n", .{topic});

        // Call Ollama to generate outline
        var client = try Ollama.init(allocator, "http://localhost:11434");
        defer client.deinit();

        const prompt = try std.fmt.allocPrint(allocator, "Create a simple outline with 3-4 main points for an article about: {s}. Return only the outline points, one per line, without numbers or bullets.", .{topic});
        defer allocator.free(prompt);

        const options = Ollama.GenerateOptions{
            .model = "granite4:350m-h",
            .temperature = 0.7,
            .top_p = null,
            .top_k = null,
            .num_predict = 200,
            .stop = null,
            .seed = null,
            .stream = false,
        };

        var response = client.generate(prompt, options) catch |err| {
            std.debug.print("Ollama generate failed: {}\n", .{err});
            // Fallback to default outline - need to allocate the strings
            const outline_literals = &[_][]const u8{ "Introduction", "Main Point 1", "Conclusion" };
            const outline_points = try allocator.alloc([]const u8, outline_literals.len);
            for (outline_literals, 0..) |literal, i| {
                outline_points[i] = try allocator.dupe(u8, literal);
            }
            const exec_result = allocator.create([][]const u8) catch @panic("oom");
            exec_result.* = outline_points;
            return @ptrCast(exec_result);
        };
        defer response.deinit();

        // Parse the response into outline points
        var outline_list = std.ArrayListUnmanaged([]const u8){};
        var lines = std.mem.splitScalar(u8, response.response, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0) {
                const owned_line = try allocator.dupe(u8, trimmed);
                try outline_list.append(allocator, owned_line);
            }
        }

        const exec_result = allocator.create([][]const u8) catch @panic("oom");
        exec_result.* = try outline_list.toOwnedSlice(allocator);
        return @ptrCast(exec_result);
    }

    pub fn post(_: *anyopaque, _: Allocator, context: *Context, _: *anyopaque, exec_res: *anyopaque) ![]const u8 {
        const outline_ptr: *const [][]const u8 = @ptrCast(@alignCast(exec_res));
        const outline = outline_ptr.*;
        try context.set("outline", outline);
        std.debug.print("Post: Outline generated with {d} points.\n", .{outline.len});
        return "default";
    }

    pub fn cleanup_prep(_: *anyopaque, allocator: Allocator, prep_res: *anyopaque) void {
        const topic_ptr: *const []const u8 = @ptrCast(@alignCast(prep_res));
        allocator.destroy(topic_ptr);
    }

    pub fn cleanup_exec(_: *anyopaque, allocator: Allocator, exec_res: *anyopaque) void {
        // Don't free the outline data - it's stored in context and will be freed during context cleanup
        const outline_ptr: *const [][]const u8 = @ptrCast(@alignCast(exec_res));
        allocator.destroy(outline_ptr);
    }

    pub const VTABLE = Node.VTable{
        .prep = prep,
        .exec = exec,
        .post = post,
        .cleanup_prep = cleanup_prep,
        .cleanup_exec = cleanup_exec,
    };
};

const WriteContentNode = struct {
    base: BaseNode,

    pub fn init(allocator: Allocator) *WriteContentNode {
        const self = allocator.create(WriteContentNode) catch @panic("oom");
        self.* = .{
            .base = BaseNode.init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *WriteContentNode, allocator: Allocator) void {
        self.base.deinit();
        allocator.destroy(self);
    }

    pub fn prep(_: *anyopaque, allocator: Allocator, context: *Context) !*anyopaque {
        const outline = context.get([][]const u8, "outline").?;

        std.debug.print("Prep: Writing content for {d} outline points.\n", .{outline.len});

        const prep_result = allocator.create([][]const u8) catch @panic("oom");

        prep_result.* = outline;

        return @ptrCast(prep_result);
    }

    pub fn exec(_: *anyopaque, allocator: Allocator, prep_res: *anyopaque) !*anyopaque {
        const outline_ptr: *const [][]const u8 = @ptrCast(@alignCast(prep_res));
        const outline = outline_ptr.*;
        std.debug.print("Exec: Generating content for each point...\n", .{});

        var client = try Ollama.init(allocator, "http://localhost:11434");

        defer client.deinit();

        var content_map = std.StringHashMap([]const u8).init(allocator);

        for (outline) |point| {
            std.debug.print("  Generating content for: {s}\n", .{point});

            const prompt = try std.fmt.allocPrint(allocator, "Write 2-3 sentences of content for this section: {s}", .{point});
            defer allocator.free(prompt);

            const options = Ollama.GenerateOptions{
                .model = "granite4:350m-h",
                .temperature = 0.7,
                .top_p = null,
                .top_k = null,
                .num_predict = 150,
                .stop = null,
                .seed = null,
                .stream = false,
            };

            var response = client.generate(prompt, options) catch |err| {
                std.debug.print("    Ollama generate failed for '{s}': {}\n", .{ point, err });
                // Fallback content
                const content = try std.fmt.allocPrint(allocator, "This is the content for {s}.", .{point});
                try content_map.put(point, content);
                continue;
            };

            const content = try allocator.dupe(u8, std.mem.trim(u8, response.response, " \t\r\n"));
            response.deinit();

            try content_map.put(point, content);
        }

        const exec_result = allocator.create(std.StringHashMap([]const u8)) catch @panic("oom");
        exec_result.* = content_map;
        return exec_result;
    }

    pub fn post(_: *anyopaque, _: Allocator, context: *Context, _: *anyopaque, exec_res: *anyopaque) ![]const u8 {
        const content: *std.StringHashMap([]const u8) = @ptrCast(@alignCast(exec_res));
        try context.set("content", content.*);
        std.debug.print("Post: Content generated.\n", .{});
        return "default";
    }

    pub fn cleanup_prep(_: *anyopaque, allocator: Allocator, prep_res: *anyopaque) void {
        const outline_ptr: *const [][]const u8 = @ptrCast(@alignCast(prep_res));
        allocator.destroy(outline_ptr);
    }

    pub fn cleanup_exec(_: *anyopaque, allocator: Allocator, exec_res: *anyopaque) void {
        // Don't free the content map data - it's stored in context and will be freed during context cleanup
        const content_map: *std.StringHashMap([]const u8) = @ptrCast(@alignCast(exec_res));
        allocator.destroy(content_map);
    }

    pub const VTABLE = Node.VTable{
        .prep = prep,
        .exec = exec,
        .post = post,
        .cleanup_prep = cleanup_prep,
        .cleanup_exec = cleanup_exec,
    };
};

const AssembleDocumentNode = struct {
    base: BaseNode,

    pub fn init(allocator: Allocator) *AssembleDocumentNode {
        const self = allocator.create(AssembleDocumentNode) catch @panic("oom");
        self.* = .{
            .base = BaseNode.init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *AssembleDocumentNode, allocator: Allocator) void {
        self.base.deinit();
        allocator.destroy(self);
    }

    pub fn prep(_: *anyopaque, allocator: Allocator, context: *Context) !*anyopaque {
        std.debug.print("Prep: Assembling final document.\n", .{});
        const outline = context.get([][]const u8, "outline").?;
        const content = context.get(std.StringHashMap([]const u8), "content").?;

        // Store both in a simple struct
        const PrepData = struct {
            outline: [][]const u8,
            content: std.StringHashMap([]const u8),
        };

        const prep_result = try allocator.create(PrepData);
        prep_result.* = .{
            .outline = outline,
            .content = content,
        };
        return prep_result;
    }

    pub fn exec(_: *anyopaque, allocator: Allocator, prep_res: *anyopaque) !*anyopaque {
        const PrepData = struct {
            outline: [][]const u8,
            content: std.StringHashMap([]const u8),
        };

        const data: *PrepData = @ptrCast(@alignCast(prep_res));
        const outline = data.outline;
        const content = data.content;

        std.debug.print("Exec: Combining outline and content...\n", .{});
        var document_parts = std.array_list.Managed(u8).init(allocator);
        defer document_parts.deinit();

        const writer = document_parts.writer();

        for (outline) |point| {
            try writer.print("## {s}\n", .{point});
            if (content.get(point)) |point_content| {
                try writer.print("{s}\n\n", .{point_content});
            }
        }

        const final_document = try document_parts.toOwnedSlice();
        const exec_result = allocator.create([]const u8) catch @panic("oom");
        exec_result.* = final_document;

        return @ptrCast(exec_result);
    }

    pub fn post(_: *anyopaque, _: Allocator, context: *Context, _: *anyopaque, exec_res: *anyopaque) ![]const u8 {
        const document_ptr: *const []const u8 = @ptrCast(@alignCast(exec_res));
        const document = document_ptr.*;
        try context.set("document", document);
        std.debug.print("Post: Final document assembled.\n", .{});
        return "end";
    }

    pub fn cleanup_prep(_: *anyopaque, allocator: Allocator, prep_res: *anyopaque) void {
        const PrepData = struct {
            outline: [][]const u8,
            content: std.StringHashMap([]const u8),
        };
        const data: *PrepData = @ptrCast(@alignCast(prep_res));
        allocator.destroy(data);
    }

    pub fn cleanup_exec(_: *anyopaque, allocator: Allocator, exec_res: *anyopaque) void {
        // Don't free the document data - it's stored in context and will be freed during context cleanup
        const document_ptr: *const []const u8 = @ptrCast(@alignCast(exec_res));
        allocator.destroy(document_ptr);
    }

    pub const VTABLE = Node.VTable{
        .prep = prep,
        .exec = exec,
        .post = post,
        .cleanup_prep = cleanup_prep,
        .cleanup_exec = cleanup_exec,
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== PocketFlow: AI Document Generator ===\n\n", .{});

    // --- Create Nodes ---
    const outline_node = GenerateOutlineNode.init(allocator);
    defer outline_node.deinit(allocator);
    const content_node = WriteContentNode.init(allocator);
    defer content_node.deinit(allocator);
    const assemble_node = AssembleDocumentNode.init(allocator);
    defer assemble_node.deinit(allocator);

    // --- Create Node wrappers ---
    const outline_node_wrapper = Node{ .self = outline_node, .vtable = &GenerateOutlineNode.VTABLE };
    const content_node_wrapper = Node{ .self = content_node, .vtable = &WriteContentNode.VTABLE };
    const assemble_node_wrapper = Node{ .self = assemble_node, .vtable = &AssembleDocumentNode.VTABLE };

    // --- Create the Flow ---
    try outline_node.base.next("default", content_node_wrapper);
    try content_node.base.next("default", assemble_node_wrapper);

    var flow = Flow.init(allocator, outline_node_wrapper);

    // --- Run the Flow ---
    var context = Context.init(allocator);
    defer {
        // Clean up context values (the actual data, not the wrappers)
        // Context.deinit() will free the pointer wrappers
        if (context.get([]const u8, "topic")) |topic| {
            allocator.free(topic);
        }
        if (context.get([][]const u8, "outline")) |outline| {
            for (outline) |point| {
                allocator.free(point);
            }
            allocator.free(outline);
        }
        if (context.get(std.StringHashMap([]const u8), "content")) |content| {
            var content_copy = content;
            var it = content_copy.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.value_ptr.*);
            }
            content_copy.deinit();
        }
        if (context.get([]const u8, "document")) |document| {
            allocator.free(document);
        }
        context.deinit();
    }

    // Store topic - duplicate the string so it's owned by the context
    const topic_str = try allocator.dupe(u8, "The Future of AI");
    try context.set("topic", topic_str);
    const test_topic = context.get([]const u8, "topic");
    std.debug.print("DEBUG: Stored topic, retrieved: '{?s}'\n", .{test_topic});

    try flow.run(&context);

    // --- Print Final Result ---
    if (context.get([]const u8, "document")) |document| {
        std.debug.print("\n=== FINAL DOCUMENT ===\n{s}\n", .{document});
    }
}
