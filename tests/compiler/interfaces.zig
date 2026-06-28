const std = @import("std");
const skarn = @import("skarn_compiler");

test "interfaces: explicit conformance and dynamic dispatch lower end to end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Writer :: interface {
        \\    write :: fn(self: *Self, data: []const u8) -> usize;
        \\    flush :: fn(self: *Self);
        \\}
        \\
        \\FileHandle :: struct { fd: i32, }
        \\
        \\FileHandle as Writer {
        \\    flush :: fn(self: *Self) {}
        \\    write :: fn(self: *Self, data: []const u8) -> usize {
        \\        return data.len;
        \\    }
        \\}
        \\
        \\consume :: fn(writer: *Writer) {
        \\    writer.flush();
        \\}
        \\
        \\make_writer :: fn(file: *FileHandle) -> *Writer {
        \\    return file;
        \\}
        \\
        \\use_writer :: fn(file: *FileHandle, data: []const u8) -> usize {
        \\    writer: *Writer = file;
        \\    writer2 := file as *Writer;
        \\    writer = file;
        \\    writer.flush();
        \\    writer2.flush();
        \\    consume(file);
        \\    return writer.write(data);
        \\}
    ;

    var fe = try skarn.compile(arena.allocator(), "interfaces.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    try std.testing.expectEqual(@as(usize, 1), m.vtables.len);
    try std.testing.expectEqual(@as(usize, 2), m.vtables[0].methods.len);
    try std.testing.expect(std.mem.endsWith(u8, m.vtables[0].methods[0], ".write"));
    try std.testing.expect(std.mem.endsWith(u8, m.vtables[0].methods[1], ".flush"));

    const use_writer = for (m.functions) |function| {
        if (std.mem.eql(u8, function.name, "use_writer")) break function;
    } else return error.FunctionNotFound;

    var makes: usize = 0;
    var method_loads: usize = 0;
    var indirect_calls: usize = 0;
    for (use_writer.blocks) |block| {
        for (block.instrs) |instr| switch (instr.kind) {
            .interface_make => makes += 1,
            .interface_method => method_loads += 1,
            .call_indirect => indirect_calls += 1,
            else => {},
        };
    }
    try std.testing.expectEqual(@as(usize, 4), makes);
    try std.testing.expectEqual(@as(usize, 3), method_loads);
    try std.testing.expectEqual(@as(usize, 3), indirect_calls);

    const make_writer = for (m.functions) |function| {
        if (std.mem.eql(u8, function.name, "make_writer")) break function;
    } else return error.FunctionNotFound;
    var return_make: usize = 0;
    for (make_writer.blocks) |block| for (block.instrs) |instr| {
        if (instr.kind == .interface_make) return_make += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), return_make);

    if (comptime skarn.llvm_enabled) {
        var backend = skarn.LlvmBackend.init(arena.allocator(), "interfaces");
        defer backend.deinit();
        try backend.lower(m);
        const llvm_ir = try backend.getIrText(arena.allocator());
        try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "FileHandle.Writer.vtable") != null);
        try std.testing.expect(std.mem.indexOf(u8, llvm_ir, "call") != null);
    }
}

test "interfaces: missing required method fails sema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\Writer :: interface {
        \\    write :: fn(self: *Self, data: []const u8) -> usize;
        \\    flush :: fn(self: *Self);
        \\}
        \\FileHandle :: struct { fd: i32, }
        \\FileHandle as Writer {
        \\    flush :: fn(self: *Self) {}
        \\}
    ;
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "missing_method.sk", bad));
}

test "interfaces: dynamic coercion requires explicit conformance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\Writer :: interface {
        \\    flush :: fn(self: *Self);
        \\}
        \\FileHandle :: struct { fd: i32, }
        \\bad :: fn(file: *FileHandle) {
        \\    writer: *Writer = file;
        \\}
    ;
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "missing_impl.sk", bad));
}
