const std = @import("std");
const gabbro = @import("gabbro_compiler");

test "runtime: @panic and assert are available via compileWithRuntime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // User code that calls @panic and assert — both come from the embedded runtime.
    const src =
        \\main :: fn() -> i32 {
        \\    assert(1 + 1 == 2);
        \\    assert_msg(true, "always ok");
        \\    return 0;
        \\}
    ;
    // compile() alone would fail ("unknown function `assert`")
    var fe = try gabbro.compileWithRuntime(arena.allocator(), "main.gab", src);
    defer fe.deinit(arena.allocator());
    const m = try gabbro.lowerFrontend(arena.allocator(), fe);
    try gabbro.ir_mod.validateModule(m);

    // The complete core runtime contract should be present.
    const fn_names = [_][]const u8{ "assert", "assert_msg", "@panic", "write_stdout", "write_stderr", "exit", "abort" };
    for (fn_names) |name| {
        const found = for (m.functions) |f| {
            if (std.mem.eql(u8, f.name, name)) break true;
        } else false;
        if (!found) {
            std.debug.print("missing runtime function: {s}\n", .{name});
            return error.MissingRuntimeFunction;
        }
    }
}

test "runtime: supported platform sources are explicit and independently valid" {
    try std.testing.expect(gabbro.gabbro_runtime.runtimeSourceFor(.windows, false) != null);
    try std.testing.expect(gabbro.gabbro_runtime.runtimeSourceFor(.linux, false) != null);
    try std.testing.expect(gabbro.gabbro_runtime.runtimeSourceFor(.linux, true) != null); // linux-gnu
    try std.testing.expect(gabbro.gabbro_runtime.runtimeSourceFor(.macos, false) == null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try gabbro.compileMulti(arena.allocator(), &.{
        .{ .file_name = "<runtime-linux>", .source = gabbro.gabbro_runtime.runtimeSourceFor(.linux, false).? },
        .{ .file_name = "main.gab", .source = "main :: fn() -> i32 { return 0; }" },
    });
    defer fe.deinit(arena.allocator());
    const module = try gabbro.lowerFrontend(arena.allocator(), fe);
    try gabbro.ir_mod.validateModule(module);
}

test "runtime: compile() without runtime — assert not available" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\use :: fn() { assert(true); }
    ;
    // compile() has no runtime → assert is unknown → SemanticFailed
    try std.testing.expectError(error.SemanticFailed, gabbro.compile(arena.allocator(), "bare.gab", src));
}

test "runtime: write_stdout is available for programs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\main :: fn() -> i32 {
        \\    return write_stdout("Hello, Gabbro!\n") as i32;
        \\}
    ;
    var fe = try gabbro.compileWithRuntime(arena.allocator(), "hello.gab", src);
    defer fe.deinit(arena.allocator());
    const m = try gabbro.lowerFrontend(arena.allocator(), fe);
    try gabbro.ir_mod.validateModule(m);
}

test "runtime: exit and abort are terminating calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\stop :: fn(code: u32) -> i32 {
        \\    exit(code);
        \\}
        \\crash :: fn() -> i32 {
        \\    abort();
        \\}
    ;
    var fe = try gabbro.compileWithRuntime(arena.allocator(), "terminate.gab", src);
    defer fe.deinit(arena.allocator());
    const module = try gabbro.lowerFrontend(arena.allocator(), fe);
    try gabbro.ir_mod.validateModule(module);
}

test "runtime: @panic is #noreturn — CFG allows body without return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // validate :: fn with early @panic — should pass CFG (all paths return or panic)
    const src =
        \\validate :: fn(x: i32) -> i32 {
        \\    if x < 0 {
        \\        core::panic("negative input");
        \\        // no return needed — @panic is #noreturn
        \\    }
        \\    return x;
        \\}
    ;
    var fe = try gabbro.compileWithRuntime(arena.allocator(), "validate.gab", src);
    defer fe.deinit(arena.allocator());
    const m = try gabbro.lowerFrontend(arena.allocator(), fe);
    try gabbro.ir_mod.validateModule(m);
}
