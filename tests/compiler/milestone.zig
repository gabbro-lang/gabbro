const std = @import("std");
const gabbro = @import("gabbro_compiler");

const sample =
    \\#import std.io;
    \\#import std.mem;
    \\
    \\RawHandle :: distinct *opaque;
    \\
    \\STD_OUTPUT_HANDLE :: -11;
    \\
    \\#extern("kernel32", "GetStdHandle")
    \\GetStdHandle :: fn(id: i32) -> RawHandle;
    \\
    \\#extern("kernel32", "WriteFile")
    \\WriteFile :: fn(
    \\    handle: RawHandle,
    \\    buf: *const u8,
    \\    len: u32,
    \\    written: *u32,
    \\    overlapped: ?*void,
    \\) -> bool;
    \\
    \\#packed
    \\Header :: struct {
    \\    magic: u32,
    \\    flags: u16,
    \\    len: u16,
    \\}
    \\
    \\#align(64)
    \\RingBuffer :: struct {
    \\    head: atomic u32,
    \\    tail: atomic u32,
    \\    data: [4096]u8,
    \\}
    \\
    \\write_stdout :: fn(text: []const u8) -> bool {
    \\    handle := GetStdHandle(STD_OUTPUT_HANDLE);
    \\
    \\    written := 0u32;
    \\    ok := WriteFile(
    \\        handle,
    \\        text.ptr,
    \\        core::narrow(u32, text.len),
    \\        &written,
    \\        null,
    \\    );
    \\
    \\    return ok && written == text.len;
    \\}
    \\
    \\mmio_write32 :: fn(addr: usize, value: u32) {
    \\    unsafe {
    \\        reg := core::ptr_from_int(*volatile u32, addr);
    \\        core::volatile_store(reg, value);
    \\    }
    \\}
    \\
    \\read_header :: fn(bytes: []const u8) -> ?Header {
    \\    if bytes.len < core::sizeof(Header) {
    \\        return null;
    \\    }
    \\
    \\    h := unsafe core::unaligned_read(Header, bytes.ptr);
    \\
    \\    if h.magic != 0x324B_324B {
    \\        return null;
    \\    }
    \\
    \\    return h;
    \\}
    \\
    \\cpu_pause :: fn() {
    \\    unsafe {
    \\        core::asm(
    \\            volatile,
    \\            "pause",
    \\            inputs: {},
    \\            outputs: {},
    \\            clobbers: {},
    \\        );
    \\    }
    \\}
    \\
    \\spin_until_ready :: fn(flag: *atomic u32) {
    \\    while core::atomic_load(flag, .acquire) == 0 {
    \\        cpu_pause();
    \\    }
    \\}
    \\
    \\copy_words :: fn(dst: [*]u32, src: [*]const u32, count: usize) {
    \\    i := 0usize;
    \\
    \\    while i < count {
    \\        unsafe {
    \\            dst[i] = src[i];
    \\        }
    \\
    \\        i += 1;
    \\    }
    \\}
    \\
    \\main :: fn() -> i32 {
    \\    write_stdout("hello from gabbro\n");
    \\
    \\    mmio_write32(0x4000_0000, 1);
    \\
    \\    buf: [16]u8 = .{
    \\        0x4B, 0x32, 0x4B, 0x32,
    \\        0x01, 0x00,
    \\        0x08, 0x00,
    \\        0, 0, 0, 0, 0, 0, 0, 0,
    \\    };
    \\
    \\    if h := read_header(buf[:]) {
    \\        if h.flags & 1 != 0 {
    \\            write_stdout("packet flag set\n");
    \\        }
    \\    }
    \\
    \\    return 0;
    \\}
;

test "milestone syntax parses and checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var front_end = try gabbro.compile(arena.allocator(), "milestone.gab", sample);
    defer front_end.deinit(arena.allocator());

    try std.testing.expectEqual(@as(usize, 15), front_end.module.items.len);
    try std.testing.expect(front_end.types.expr_types.count() > 40);
    try std.testing.expect(front_end.types.fn_sigs.count() == 9);

    const module = try gabbro.lowerFrontend(arena.allocator(), front_end);
    try std.testing.expectEqual(@as(usize, 2), module.structs.len);
    try std.testing.expectEqual(@as(usize, 9), module.functions.len);
    try std.testing.expectEqual(@as(usize, 1), module.globals.len);

    const write_stdout = findFunction(module, "write_stdout").?;
    try std.testing.expect(write_stdout.blocks.len == 1);
    try std.testing.expect(write_stdout.blocks[0].instrs.len > 0);

    const main = findFunction(module, "main").?;
    try std.testing.expect(main.blocks.len > 1);
    try std.testing.expect(main.blocks[0].instrs.len > 0);

    const spin = findFunction(module, "spin_until_ready").?;
    try std.testing.expect(spin.blocks.len >= 4);
    try std.testing.expect(hasCondBranch(spin));

    const read_header = findFunction(module, "read_header").?;
    try std.testing.expect(read_header.blocks.len >= 5);
    try std.testing.expect(hasCondBranch(read_header));

    try gabbro.ir_mod.validateModule(module);
    var optimized = module;
    try gabbro.ir_mod.runDefaultPasses(arena.allocator(), &optimized);
    try gabbro.ir_mod.validateModule(optimized);
}

test "return type mismatch fails semantic checking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn() -> i32 {
        \\    return "not an integer";
        \\}
    ;

    try std.testing.expectError(error.SemanticFailed, gabbro.compile(arena.allocator(), "bad_return.gab", bad));
}

test "ir validation rejects missing branch targets" {
    const invalid = gabbro.IrModule{
        .file_name = "invalid.gab",
        .functions = &.{
            .{
                .name = "broken",
                .params = &.{},
                .return_ty = .void,
                .error_ty = null,
                .blocks = &.{
                    .{
                        .id = 0,
                        .name = "entry",
                        .instrs = &.{},
                        .terminator = .{ .branch = 404 },
                    },
                },
                .extern_name = null,
                .inline_hint = false,
                .no_inline   = false,
                .no_return   = false,
                .entry       = false,
                .naked       = false,
                .export_sym  = null,
            },
        },
    };

    try std.testing.expectError(error.InvalidIr, gabbro.ir_mod.validateModule(invalid));
}

fn findFunction(module: gabbro.IrModule, name: []const u8) ?gabbro.ir_mod.IrFunction {
    for (module.functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

fn hasCondBranch(function: gabbro.ir_mod.IrFunction) bool {
    for (function.blocks) |block| {
        if (block.terminator) |term| switch (term) {
            .cond_branch => return true,
            else => {},
        };
    }
    return false;
}
