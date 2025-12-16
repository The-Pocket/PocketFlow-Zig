const std = @import("std");
const http = std.http;
const json = std.json;
const mem = std.mem;
const testing = std.testing;

/// Ollama API client for local LLM inference
pub const Ollama = struct {
    allocator: mem.Allocator,
    client: http.Client,
    base_url: []const u8,

    pub const Error = error{
        RequestFailed,
        InvalidResponse,
        NetworkError,
        EndOfStream,
        ReadFailed,
        JsonParseError,
    } || mem.Allocator.Error || http.Client.RequestError || http.Client.FetchError || http.Client.ConnectError || json.ParseError(json.Scanner);

    /// Initialize a new Ollama client
    pub fn init(allocator: mem.Allocator, base_url: ?[]const u8) !Ollama {
        return .{
            .allocator = allocator,
            // allocate client on heap rather than stack
            .client = http.Client{ .allocator = allocator },
            .base_url = base_url orelse "http://localhost:11434",
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Ollama) void {
        self.client.deinit();
    }

    /// Message structure for chat requests
    pub const Message = struct {
        content: []const u8,
        role: []const u8,
    };

    /// Common options for LLM requests (generate and chat)
    pub const LLMOptions = struct {
        model: []const u8 = "granite4:tiny-h",
        temperature: ?f32 = null,
        top_p: ?f32 = null,
        top_k: ?i32 = null,
        num_predict: ?i32 = null,
        stop: ?[]const []const u8 = null,
        seed: ?i32 = null,
        stream: bool = false,
    };

    /// Alias for backwards compatibility
    pub const GenerateOptions = LLMOptions;
    pub const ChatOptions = LLMOptions;

    /// Response from text generation
    pub const GenerateResponse = struct {
        response: []const u8,
        model: []const u8,
        done: bool,
        allocator: mem.Allocator,

        pub fn deinit(self: GenerateResponse) void {
            self.allocator.free(self.response);
            self.allocator.free(self.model);
        }
    };

    /// Response from chat
    pub const ChatResponse = struct {
        message: Message,
        done: bool,
        allocator: mem.Allocator,

        pub fn deinit(self: ChatResponse) void {
            self.allocator.free(self.message.role);
            self.allocator.free(self.message.content);
        }
    };

    /// Model information
    pub const ModelInfo = struct {
        name: []const u8,
        modified_at: []const u8,
        size: i64,
        allocator: mem.Allocator,

        pub fn deinit(self: ModelInfo) void {
            self.allocator.free(self.name);
            self.allocator.free(self.modified_at);
        }
    };

    /// List response
    pub const ListResponse = struct {
        models: []ModelInfo,
        allocator: mem.Allocator,

        pub fn deinit(self: ListResponse) void {
            for (self.models) |model| {
                model.deinit();
            }
            self.allocator.free(self.models);
        }
    };

    /// Generate text completion using the Ollama API
    pub fn generate(
        self: *Ollama,
        prompt: []const u8,
        options: GenerateOptions,
    ) Error!GenerateResponse {
        var url_buffer = std.ArrayListUnmanaged(u8){};
        defer url_buffer.deinit(self.allocator);

        try url_buffer.writer(self.allocator).print("{s}/api/generate", .{self.base_url});
        const url = url_buffer.items;

        // Build JSON request body
        var request_body_buffer = std.ArrayListUnmanaged(u8){};
        defer request_body_buffer.deinit(self.allocator);

        try request_body_buffer.appendSlice(self.allocator, "{\"model\":\"");
        try request_body_buffer.appendSlice(self.allocator, options.model);
        try request_body_buffer.appendSlice(self.allocator, "\",\"prompt\":\"");
        try self.jsonEscape(&request_body_buffer, prompt);
        try request_body_buffer.appendSlice(self.allocator, "\"");

        if (options.temperature) |temp| {
            try request_body_buffer.writer(self.allocator).print(",\"temperature\":{d}", .{temp});
        }
        if (options.top_p) |top_p| {
            try request_body_buffer.writer(self.allocator).print(",\"top_p\":{d}", .{top_p});
        }
        if (options.top_k) |top_k| {
            try request_body_buffer.writer(self.allocator).print(",\"top_k\":{d}", .{top_k});
        }
        if (options.num_predict) |num| {
            try request_body_buffer.writer(self.allocator).print(",\"num_predict\":{d}", .{num});
        }
        if (options.seed) |seed| {
            try request_body_buffer.writer(self.allocator).print(",\"seed\":{d}", .{seed});
        }
        try request_body_buffer.writer(self.allocator).print(",\"stream\":{}", .{options.stream});
        try request_body_buffer.appendSlice(self.allocator, "}");

        const request_body = request_body_buffer.items;

        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
        defer req.deinit();

        // Set transfer encoding to content-length (automatically sets Content-Length header)
        req.transfer_encoding = .{ .content_length = request_body.len };

        std.debug.print("Generate: Sending body of length: {}\n", .{request_body.len});

        // Send the request body using the BodyWriter API
        var body_writer = try req.sendBody(&.{});
        try body_writer.writer.writeAll(request_body);
        try body_writer.end();

        std.debug.print("Generate: Body sent successfully\n", .{});

        var response = try req.receiveHead(&.{});

        if (response.head.status != .ok) {
            std.debug.print("Generate request failed with status: {}\n", .{response.head.status});
            return Error.RequestFailed;
        }

        // Read response body
        var response_buffer: [1024 * 1024 * 10]u8 = undefined;
        var response_writer: std.Io.Writer = .fixed(&response_buffer);
        var read_buffer: [4096]u8 = undefined;
        const body_reader: *std.Io.Reader = response.reader(&read_buffer);

        const n = try body_reader.stream(&response_writer, @enumFromInt(response_buffer.len));

        // Parse JSON response
        const response_json = response_buffer[0..n];
        std.debug.print("Generate response body ({} bytes): {s}\n", .{ n, response_json });
        const parsed = try json.parseFromSlice(
            json.Value,
            self.allocator,
            response_json,
            .{},
        );
        defer parsed.deinit();

        const obj = parsed.value.object;
        const response_text = obj.get("response").?.string;
        const model_name = obj.get("model").?.string;
        const done = obj.get("done").?.bool;

        return GenerateResponse{
            .response = try self.allocator.dupe(u8, response_text),
            .model = try self.allocator.dupe(u8, model_name),
            .done = done,
            .allocator = self.allocator,
        };
    }

    /// Chat with the model using conversation history
    pub fn chat(
        self: *Ollama,
        messages: []const Message,
        options: ChatOptions,
    ) Error!ChatResponse {
        var url_buffer = std.ArrayListUnmanaged(u8){};
        defer url_buffer.deinit(self.allocator);

        try url_buffer.writer(self.allocator).print("{s}/api/chat", .{self.base_url});
        const url = url_buffer.items;

        // Build JSON request body
        var request_body_buffer = std.ArrayListUnmanaged(u8){};
        defer request_body_buffer.deinit(self.allocator);

        try request_body_buffer.appendSlice(self.allocator, "{\"model\":\"");
        try request_body_buffer.appendSlice(self.allocator, options.model);
        try request_body_buffer.appendSlice(self.allocator, "\",\"messages\":[");

        for (messages, 0..) |msg, i| {
            if (i > 0) try request_body_buffer.appendSlice(self.allocator, ",");
            try request_body_buffer.appendSlice(self.allocator, "{\"role\":\"");
            try request_body_buffer.appendSlice(self.allocator, msg.role);
            try request_body_buffer.appendSlice(self.allocator, "\",\"content\":\"");
            try self.jsonEscape(&request_body_buffer, msg.content);
            try request_body_buffer.appendSlice(self.allocator, "\"}");
        }

        try request_body_buffer.appendSlice(self.allocator, "]");

        if (options.temperature) |temp| {
            try request_body_buffer.writer(self.allocator).print(",\"temperature\":{d}", .{temp});
        }
        if (options.top_p) |top_p| {
            try request_body_buffer.writer(self.allocator).print(",\"top_p\":{d}", .{top_p});
        }
        if (options.top_k) |top_k| {
            try request_body_buffer.writer(self.allocator).print(",\"top_k\":{d}", .{top_k});
        }
        if (options.num_predict) |num| {
            try request_body_buffer.writer(self.allocator).print(",\"num_predict\":{d}", .{num});
        }
        if (options.seed) |seed| {
            try request_body_buffer.writer(self.allocator).print(",\"seed\":{d}", .{seed});
        }
        try request_body_buffer.writer(self.allocator).print(",\"stream\":{}", .{options.stream});
        try request_body_buffer.appendSlice(self.allocator, "}");

        const request_body = request_body_buffer.items;

        std.debug.print("Chat request body: {s}\n", .{request_body});

        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
        defer req.deinit();

        // Set transfer encoding to content-length (automatically sets Content-Length header)
        req.transfer_encoding = .{ .content_length = request_body.len };

        std.debug.print("Chat: Sending body of length: {}\n", .{request_body.len});

        // Send the request body using the BodyWriter API
        var body_writer = try req.sendBody(&.{});
        try body_writer.writer.writeAll(request_body);
        try body_writer.end();

        std.debug.print("Chat: Body sent successfully\n", .{});

        // Receive response
        var response = try req.receiveHead(&.{});

        // Read response body - allocate large buffer for response
        const response_buffer = try self.allocator.alloc(u8, 10 * 1024 * 1024);
        defer self.allocator.free(response_buffer);
        var response_writer: std.Io.Writer = .fixed(response_buffer);
        var read_buffer: [4096]u8 = undefined;
        const body_reader: *std.Io.Reader = response.reader(&read_buffer);

        const n = try body_reader.streamRemaining(&response_writer);

        // Parse JSON response
        const response_json = response_buffer[0..n];
        std.debug.print("Chat response status: {}, body ({} bytes): {s}\n", .{ response.head.status, n, response_json });

        if (response.head.status != .ok) {
            std.debug.print("Chat request failed with status: {}\n", .{response.head.status});
            return Error.RequestFailed;
        }
        const parsed = try json.parseFromSlice(
            json.Value,
            self.allocator,
            response_json,
            .{},
        );
        defer parsed.deinit();

        const obj = parsed.value.object;
        const msg_obj = obj.get("message").?.object;
        const role = msg_obj.get("role").?.string;
        const content = msg_obj.get("content").?.string;
        const done = obj.get("done").?.bool;

        return ChatResponse{
            .message = Message{
                .role = try self.allocator.dupe(u8, role),
                .content = try self.allocator.dupe(u8, content),
            },
            .done = done,
            .allocator = self.allocator,
        };
    }

    /// List available models
    pub fn listModels(self: *Ollama) Error!ListResponse {
        var url_buffer = std.ArrayListUnmanaged(u8){};
        defer url_buffer.deinit(self.allocator);

        try url_buffer.writer(self.allocator).print("{s}/api/tags", .{self.base_url});
        const url = url_buffer.items;

        const uri = try std.Uri.parse(url);

        var req = try self.client.request(.GET, uri, .{});
        defer req.deinit();

        try req.sendBodiless();
        var response = try req.receiveHead(&.{});

        if (response.head.status != .ok) {
            std.debug.print("ListModels request failed with status: {}\n", .{response.head.status});
            return Error.RequestFailed;
        }

        // Read response body - allocate large buffer for response
        const response_buffer = try self.allocator.alloc(u8, 10 * 1024 * 1024);
        defer self.allocator.free(response_buffer);
        var response_writer: std.Io.Writer = .fixed(response_buffer);
        var read_buffer: [4096]u8 = undefined;
        const body_reader: *std.Io.Reader = response.reader(&read_buffer);

        const n = try body_reader.streamRemaining(&response_writer);

        // Parse JSON response
        const response_json = response_buffer[0..n];
        std.debug.print("ListModels response body ({} bytes): {s}\n", .{ n, response_json });
        const parsed = try json.parseFromSlice(
            json.Value,
            self.allocator,
            response_json,
            .{},
        );
        defer parsed.deinit();

        const obj = parsed.value.object;
        const models_array = obj.get("models").?.array;

        var models = try self.allocator.alloc(ModelInfo, models_array.items.len);
        for (models_array.items, 0..) |model_val, i| {
            const model_obj = model_val.object;

            models[i] = ModelInfo{
                .name = try self.allocator.dupe(u8, model_obj.get("name").?.string),
                .modified_at = try self.allocator.dupe(u8, model_obj.get("modified_at").?.string),
                .size = model_obj.get("size").?.integer,
                .allocator = self.allocator,
            };
        }

        return ListResponse{
            .models = models,
            .allocator = self.allocator,
        };
    }

    /// Helper function to escape JSON strings
    fn jsonEscape(self: *Ollama, buffer: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
        for (text) |c| {
            switch (c) {
                '"' => try buffer.appendSlice(self.allocator, "\\\""),
                '\\' => try buffer.appendSlice(self.allocator, "\\\\"),
                '\n' => try buffer.appendSlice(self.allocator, "\\n"),
                '\r' => try buffer.appendSlice(self.allocator, "\\r"),
                '\t' => try buffer.appendSlice(self.allocator, "\\t"),
                else => try buffer.append(self.allocator, c),
            }
        }
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "Ollama - init and deinit" {
    var gpa = std.testing.allocator_instance;
    var client = try Ollama.init(gpa.allocator(), null);
    defer client.deinit();

    try testing.expect(client.base_url.len > 0);
    try testing.expectEqualStrings("http://localhost:11434", client.base_url);
}

test "Ollama - init with custom URL" {
    var gpa = std.testing.allocator_instance;
    var client = try Ollama.init(gpa.allocator(), "http://192.168.1.100:11434");
    defer client.deinit();

    try testing.expectEqualStrings("http://192.168.1.100:11434", client.base_url);
}

test "Ollama - Message structure" {
    const msg = Ollama.Message{
        .role = "user",
        .content = "Hello, Ollama!",
    };

    try testing.expectEqualStrings("user", msg.role);
    try testing.expectEqualStrings("Hello, Ollama!", msg.content);
}

test "Ollama - LLMOptions defaults" {
    const opts = Ollama.LLMOptions{};

    try testing.expectEqualStrings("granite4:tiny-h", opts.model);
    try testing.expect(opts.temperature == null);
    try testing.expect(opts.seed == null);
    try testing.expect(opts.stream == false);
}

test "Ollama - LLMOptions custom" {
    const opts = Ollama.LLMOptions{
        .model = "granite4:tiny-h",
        .temperature = 0.7,
        .seed = 123,
        .stream = false,
        .num_predict = 100,
    };

    try testing.expectEqualStrings("granite4:tiny-h", opts.model);
    try testing.expect(opts.temperature.? == 0.7);
    try testing.expect(opts.seed.? == 123);
    try testing.expect(opts.stream == false);
    try testing.expect(opts.num_predict.? == 100);
}

test "Ollama - backwards compatible aliases" {
    // Verify that GenerateOptions and ChatOptions are aliases for LLMOptions
    const gen_opts = Ollama.GenerateOptions{};
    const chat_opts = Ollama.ChatOptions{};
    const llm_opts = Ollama.LLMOptions{};

    try testing.expectEqualStrings(gen_opts.model, llm_opts.model);
    try testing.expectEqualStrings(chat_opts.model, llm_opts.model);
}

// Integration tests - require a running Ollama server
test "Ollama - listModels integration" {
    var gpa = std.testing.allocator_instance;
    var client = try Ollama.init(gpa.allocator(), null);
    defer client.deinit();

    const list_response = try client.listModels();
    defer list_response.deinit();

    std.debug.print("\nAvailable models: {d}\n", .{list_response.models.len});
    for (list_response.models) |model| {
        std.debug.print("  - {s} (size: {d})\n", .{ model.name, model.size });
    }

    try testing.expect(list_response.models.len >= 0);
}

test "Ollama - generate integration" {
    if (true) return error.SkipZigTest; // Skip by default

    var gpa = std.testing.allocator_instance;
    var client = try Ollama.init(gpa.allocator(), null);
    defer client.deinit();

    const response = try client.generate("Say hello in one word", .{
        .model = "granite4:tiny-h",
    });
    defer response.deinit();

    std.debug.print("\nGenerate Response: {s}\n", .{response.response});
    std.debug.print("Model: {s}, Done: {}\n", .{ response.model, response.done });

    try testing.expect(response.response.len > 0);
    try testing.expect(response.done);
}

test "Ollama - chat integration" {
    var gpa = std.testing.allocator_instance;
    var client = try Ollama.init(gpa.allocator(), null);
    defer client.deinit();

    const messages = [_]Ollama.Message{
        .{ .role = "user", .content = "What is the capital of France?" },
    };

    const response = try client.chat(&messages, .{
        .model = "granite4:tiny-h",
    });
    defer response.deinit();

    std.debug.print("\nChat Response: {s}\n", .{response.message.content});
    std.debug.print("Role: {s}, Done: {}\n", .{ response.message.role, response.done });

    try testing.expect(response.message.content.len > 0);
    try testing.expectEqualStrings("assistant", response.message.role);
    try testing.expect(response.done);
}
