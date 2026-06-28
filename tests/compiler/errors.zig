const std = @import("std");
const k2 = @import("k2_compiler");

test "k2 errors: declarations fail propagate catch and split defer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\NetError :: errors {
        \\    timeout,
        \\    dns_failed: []const u8,
        \\    http: u16,
        \\}
        \\
        \\Socket :: struct { id: usize, }
        \\
        \\close :: fn() {}
        \\mark_ok :: fn() {}
        \\save :: fn(data: []const u8) {}
        \\print_error :: fn(e: NetError) {}
        \\log_status :: fn(code: u16) {}
        \\
        \\connect :: fn(host: []const u8, mode: u32) -> Socket ! NetError {
        \\    if mode == 1u32 {
        \\        fail .dns_failed { host };
        \\    }
        \\    if mode == 2u32 {
        \\        fail .timeout;
        \\    }
        \\    return .{};
        \\}
        \\
        \\read :: fn(sock: Socket) -> []const u8 ! {
        \\    return "ok";
        \\}
        \\
        \\fetch :: fn(host: []const u8) -> []const u8 ! {
        \\    defer.err close();
        \\    defer.ok mark_ok();
        \\    conn := connect(host, 0u32)?;
        \\    data := read(conn)?;
        \\    return data;
        \\}
        \\
        \\download :: fn(host: []const u8) -> bool {
        \\    data := fetch(host) catch e {
        \\        if e == .timeout {
        \\            return false;
        \\        }
        \\        if e == .http |code| {
        \\            log_status(code);
        \\            return false;
        \\        }
        \\        print_error(e);
        \\        return false;
        \\    };
        \\    save(data);
        \\    return true;
        \\}
    ;

    var fe = try k2.compile(arena.allocator(), "errors.sk", src);
    defer fe.deinit(arena.allocator());

    const module = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(module);

    try std.testing.expectEqual(@as(usize, 1), module.errors.len);
    try std.testing.expectEqualStrings("NetError", module.errors[0].name);
    try std.testing.expectEqual(@as(usize, 3), module.errors[0].variants.len);

    const connect = findFunction(module, "connect").?;
    try std.testing.expect(connect.error_ty != null);
    try std.testing.expect(hasFail(connect));

    const fetch = findFunction(module, "fetch").?;
    try std.testing.expect(fetch.error_ty != null);
    try std.testing.expect(hasBuiltin(fetch, "try_context"));
    try std.testing.expect(hasCall(fetch, "mark_ok"));
    try std.testing.expect(!hasCall(fetch, "close"));

    const download = findFunction(module, "download").?;
    try std.testing.expect(hasBuiltin(download, "catch_handler"));

    var opt = module;
    try k2.ir_mod.runDefaultPasses(arena.allocator(), &opt);
    try k2.ir_mod.validateModule(opt);
}

test "k2 errors: fail payload type is checked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\NetError :: errors { http: u16, }
        \\bad :: fn() -> u32 ! NetError {
        \\    fail .http { "nope" };
        \\}
    ;

    try std.testing.expectError(error.SemanticFailed, k2.compile(arena.allocator(), "bad_error_payload.sk", bad));
}

test "k2 errors: anonymous inline error sets are checked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\parse :: fn(src: []const u8) -> u32 ! { .empty, .invalid_token } {
        \\    if src.len == 0 {
        \\        fail .empty;
        \\    }
        \\    return 1u32;
        \\}
        \\
        \\use_parse :: fn(src: []const u8) -> u32 ! { .empty, .invalid_token } {
        \\    return parse(src)?;
        \\}
    ;

    var fe = try k2.compile(arena.allocator(), "anon_errors.sk", src);
    defer fe.deinit(arena.allocator());
    const module = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(module);
}

test "k2 errors: unknown variants in inline error sets fail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn() -> u32 ! { .known } {
        \\    fail .missing;
        \\}
    ;

    try std.testing.expectError(error.SemanticFailed, k2.compile(arena.allocator(), "bad_error_variant.sk", bad));
}

test "k2 errors: postfix try outside fallible function fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\may_fail :: fn() -> u32 ! { return 1u32; }
        \\bad :: fn() -> u32 {
        \\    return may_fail()?;
        \\}
    ;

    try std.testing.expectError(error.SemanticFailed, k2.compile(arena.allocator(), "bad_try.sk", bad));
}

fn findFunction(module: k2.IrModule, name: []const u8) ?k2.ir_mod.IrFunction {
    for (module.functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

fn hasFail(function: k2.ir_mod.IrFunction) bool {
    for (function.blocks) |block| {
        if (block.terminator) |term| switch (term) {
            .fail => return true,
            else => {},
        };
    }
    return false;
}

fn hasCall(function: k2.ir_mod.IrFunction, name: []const u8) bool {
    for (function.blocks) |block| {
        for (block.instrs) |instr| switch (instr.kind) {
            .call => |call| if (std.mem.eql(u8, call.callee, name)) return true,
            else => {},
        };
    }
    return false;
}

fn hasBuiltin(function: k2.ir_mod.IrFunction, name: []const u8) bool {
    for (function.blocks) |block| {
        for (block.instrs) |instr| switch (instr.kind) {
            .builtin => |builtin| if (std.mem.eql(u8, builtin.name, name)) return true,
            else => {},
        };
    }
    return false;
}
