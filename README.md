# PocketFlow-Zig

A Zig implementation of [PocketFlow](https://github.com/The-Pocket/PocketFlow), a minimalist flow-based programming framework for building LLM-powered workflows.

## Overview

PocketFlow-Zig is a port of the original Python PocketFlow framework, redesigned to leverage Zig's unique capabilities:

- **Compile-time polymorphism**: Uses vtables for type-erased node interfaces without runtime overhead
- **Explicit memory management**: No hidden allocations; all memory is managed through Zig allocators
- **Thread-safe context**: Built-in mutex protection for shared state between nodes
- **Zero dependencies**: Core framework has no external dependencies (Ollama client is optional)

## Features

- **Node-based architecture**: Define workflows as a graph of interconnected nodes
- **Type-erased interfaces**: Generic `Node` interface via vtables enables heterogeneous node types
- **Flow execution engine**: Automatic traversal and execution of node graphs
- **Thread-safe shared context**: Safe data passing between nodes with mutex protection
- **Ollama integration**: Built-in client for local LLM inference (optional)
- **Action-based routing**: Nodes return actions that determine the next node in the flow

## Installation

### Method 1: Using `zig fetch` (Recommended)

The easiest way to add PocketFlow-Zig to your project is using `zig fetch --save`:

```bash
# Fetch from a GitHub release tarball (recommended for stability)
zig fetch --save https://github.com/bkataru/PocketFlow-Zig/archive/refs/tags/v0.2.0.tar.gz

# Or fetch directly from a git repository
zig fetch --save git+https://github.com/bkataru/PocketFlow-Zig.git

# You can also specify a custom name for the dependency
zig fetch --save=pocketflow https://github.com/bkataru/PocketFlow-Zig/archive/refs/tags/v0.2.0.tar.gz
```

This automatically:
1. Downloads the package to Zig's global cache
2. Computes the package hash
3. Adds the dependency to your `build.zig.zon` file

After running `zig fetch --save`, your `build.zig.zon` will contain something like:

```zig
.dependencies = .{
    .pocketflow = .{
        .url = "https://github.com/bkataru/PocketFlow-Zig/archive/refs/tags/v0.2.0.tar.gz",
        .hash = "1220...", // Auto-generated hash
    },
},
```

Then add the import in your `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Fetch the pocketflow dependency
    const pocketflow_dep = b.dependency("pocketflow", .{
        .target = target,
        .optimize = optimize,
    });

    // Get the module from the dependency
    const pocketflow_mod = pocketflow_dep.module("pocketflow");

    // Create your executable
    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add the pocketflow import to your executable
    exe.root_module.addImport("pocketflow", pocketflow_mod);

    // Optional: also add the ollama module for LLM integration
    const ollama_mod = pocketflow_dep.module("ollama");
    exe.root_module.addImport("ollama", ollama_mod);

    b.installArtifact(exe);
}
```

### Method 2: Manual `build.zig.zon` Configuration

If you prefer to manually configure your dependencies, add the following to your `build.zig.zon`:

```zig
.{
    .name = .my_project,
    .version = "0.1.0",
    .minimum_zig_version = "0.15.0",
    .dependencies = .{
        .pocketflow = .{
            .url = "https://github.com/bkataru/PocketFlow-Zig/archive/refs/tags/v0.2.0.tar.gz",
            // Get the hash by running: zig fetch https://github.com/bkataru/PocketFlow-Zig/archive/refs/tags/v0.2.0.tar.gz
            .hash = "1220...",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

To get the correct hash, run:

```bash
zig fetch https://github.com/bkataru/PocketFlow-Zig/archive/refs/tags/v0.2.0.tar.gz
```

This prints the hash without modifying any files.

### Method 3: Git-based Dependency

For development or to track the latest changes:

```zig
.dependencies = .{
    .pocketflow = .{
        .url = "git+https://github.com/bkataru/PocketFlow-Zig.git",
        .hash = "1220...",
    },
},
```

Or with `zig fetch`:

```bash
zig fetch --save git+https://github.com/bkataru/PocketFlow-Zig.git
```

### Method 4: Local Path Dependency

For local development or when vendoring:

```zig
.dependencies = .{
    .pocketflow = .{
        .path = "../PocketFlow-Zig",
    },
},
```

### Building from Source

```bash
# Clone the repository
git clone https://github.com/bkataru/PocketFlow-Zig.git
cd PocketFlow-Zig

# Build the library
zig build

# Run the example (requires Ollama running locally)
zig build run

# Run tests
zig build test
```

## Quick Start

### 1. Define a Custom Node

Each node implements prep, exec, and post phases:

```zig
const std = @import("std");
const pocketflow = @import("pocketflow");
const Node = pocketflow.Node;
const BaseNode = pocketflow.BaseNode;
const Context = pocketflow.Context;

const MyNode = struct {
    base: BaseNode,

    pub fn init(allocator: std.mem.Allocator) *MyNode {
        const self = allocator.create(MyNode) catch @panic("oom");
        self.* = .{ .base = BaseNode.init(allocator) };
        return self;
    }

    pub fn deinit(self: *MyNode, allocator: std.mem.Allocator) void {
        self.base.deinit();
        allocator.destroy(self);
    }

    // Prepare: read from context, prepare data for execution
    pub fn prep(_: *anyopaque, allocator: std.mem.Allocator, context: *Context) !*anyopaque {
        const input = context.get([]const u8, "input") orelse "default";
        const result = try allocator.create([]const u8);
        result.* = input;
        return @ptrCast(result);
    }

    // Execute: perform the main work (can be CPU-intensive)
    pub fn exec(_: *anyopaque, allocator: std.mem.Allocator, prep_res: *anyopaque) !*anyopaque {
        const input: *[]const u8 = @ptrCast(@alignCast(prep_res));
        const output = try std.fmt.allocPrint(allocator, "Processed: {s}", .{input.*});
        const result = try allocator.create([]const u8);
        result.* = output;
        return @ptrCast(result);
    }

    // Post: save results to context, return action for routing
    pub fn post(_: *anyopaque, _: std.mem.Allocator, context: *Context, _: *anyopaque, exec_res: *anyopaque) ![]const u8 {
        const output: *[]const u8 = @ptrCast(@alignCast(exec_res));
        try context.set("output", output.*);
        return "default"; // Action determines next node
    }

    pub fn cleanup_prep(_: *anyopaque, allocator: std.mem.Allocator, prep_res: *anyopaque) void {
        const ptr: *[]const u8 = @ptrCast(@alignCast(prep_res));
        allocator.destroy(ptr);
    }

    pub fn cleanup_exec(_: *anyopaque, allocator: std.mem.Allocator, exec_res: *anyopaque) void {
        const ptr: *[]const u8 = @ptrCast(@alignCast(exec_res));
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
```

### 2. Build and Run a Flow

```zig
const pocketflow = @import("pocketflow");
const Flow = pocketflow.Flow;
const Context = pocketflow.Context;
const Node = pocketflow.Node;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create nodes
    const node1 = MyNode.init(allocator);
    defer node1.deinit(allocator);
    
    const node2 = MyNode.init(allocator);
    defer node2.deinit(allocator);

    // Wrap nodes with their vtables
    const wrapper1 = Node{ .self = node1, .vtable = &MyNode.VTABLE };
    const wrapper2 = Node{ .self = node2, .vtable = &MyNode.VTABLE };

    // Connect nodes: node1 --"default"--> node2
    try node1.base.next("default", wrapper2);

    // Create and run flow
    var flow = Flow.init(allocator, wrapper1);
    
    var context = Context.init(allocator);
    defer context.deinit();
    
    try context.set("input", @as([]const u8, "Hello, PocketFlow!"));
    try flow.run(&context);
    
    if (context.get([]const u8, "output")) |output| {
        std.debug.print("Result: {s}\n", .{output});
    }
}
```

### 3. Branching Flows

Nodes can return different actions to route to different successors:

```zig
pub fn post(_: *anyopaque, _: Allocator, context: *Context, _: *anyopaque, exec_res: *anyopaque) ![]const u8 {
    const result: *i32 = @ptrCast(@alignCast(exec_res));
    try context.set("result", result.*);
    
    // Branch based on result
    if (result.* > 100) {
        return "high";
    } else {
        return "low";
    }
}

// Later, when connecting nodes:
try node1.base.next("high", high_value_handler);
try node1.base.next("low", low_value_handler);
```

## Architecture

### Core Components

| Component | Description |
|-----------|-------------|
| `Node` | Type-erased interface for workflow steps (via vtable) |
| `BaseNode` | Provides successor management for routing |
| `Flow` | Executes nodes in sequence, following action-based routing |
| `Context` | Thread-safe key-value store for sharing data between nodes |

### Node Lifecycle

```
┌─────────┐     ┌─────────┐     ┌─────────┐
│  prep   │ --> │  exec   │ --> │  post   │
└─────────┘     └─────────┘     └─────────┘
     │               │               │
     v               v               v
 Read from       Process         Write to
 Context         Data            Context
                                     │
                                     v
                              Return Action
                              (routes to next node)
```

## Examples

See the `examples/` directory:

- **document_generator.zig**: Multi-node flow that generates documents using Ollama LLM
  - Generates an outline for a topic
  - Writes content for each outline point
  - Assembles the final document

Run the example:

```bash
# Requires Ollama running locally on port 11434
zig build run
```

## API Reference

### Context

```zig
// Initialize a new context
var ctx = Context.init(allocator);
defer ctx.deinit();

// Store a value
try ctx.set("key", value);

// Retrieve a value (returns null if not found)
if (ctx.get(MyType, "key")) |value| {
    // use value
}
```

### Flow

```zig
// Create a flow starting at a node
var flow = Flow.init(allocator, start_node);

// Run the flow with a context
try flow.run(&context);
```

### BaseNode

```zig
// Add a successor for an action
try node.base.next("action_name", successor_node);
```

## Testing

```bash
# Run all unit tests
zig build test

# Run integration tests (requires Ollama server)
zig build test-integration
```

## Project Structure

```
PocketFlow-Zig/
├── src/
│   ├── pocketflow.zig    # Main library exports
│   ├── node.zig          # Node interface and BaseNode
│   ├── flow.zig          # Flow execution engine
│   ├── context.zig       # Thread-safe context storage
│   └── ollama.zig        # Ollama LLM client (optional)
├── examples/
│   └── document_generator.zig
├── build.zig
├── build.zig.zon
├── README.md
└── LICENSE
```

## Contributing

Contributions are welcome! Areas of interest:

1. **Async support**: Implement async node execution using Zig 0.15+ async I/O
2. **Batch processing**: Add BatchNode for processing multiple items
3. **More examples**: Additional workflow examples (RAG, agents, etc.)
4. **Performance**: Benchmarks and optimizations

Please submit pull requests or open issues for discussion.

## Requirements

- Zig 0.15.0 or later
- (Optional) Ollama for LLM integration

## License

[MIT License](LICENSE)