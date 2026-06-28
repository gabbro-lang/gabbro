const std = @import("std");
const builtin = @import("builtin");
const skarn  = @import("skarn_compiler");

// ── Sub-byte integers ─────────────────────────────────────────────────────────

test "u1-u7 as struct fields in packed struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#packed
        \\ControlReg :: struct {
        \\    enable:   u1,
        \\    mode:     u3,
        \\    reserved: u3,
        \\    flag:     u1,
        \\}
        \\
        \\make_reg :: fn(en: u1, m: u3) -> ControlReg {
        \\    r: ControlReg = .{ en, m, 0u3, 0u1 };
        \\    return r;
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "subbyte.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    // The struct should have 4 fields
    const s = for (m.structs) |s| {
        if (std.mem.eql(u8, s.name, "ControlReg")) break s;
    } else return error.StructNotFound;
    try std.testing.expectEqual(@as(usize, 4), s.fields.len);

    // u1 field should have bit-width 1 in IR
    try std.testing.expectEqual(skarn.ir_mod.IrType{ .u = 1 }, s.fields[0].ty);
    try std.testing.expectEqual(skarn.ir_mod.IrType{ .u = 3 }, s.fields[1].ty);
}

test "u4 field: 4-bit integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Nibble :: struct { lo: u4, hi: u4 }
        \\pack :: fn(lo: u4, hi: u4) -> Nibble {
        \\    return .{ lo, hi };
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "nibble.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);
}

test "i1-i7 signed sub-byte integers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#packed
        \\SignedFlags :: struct {
        \\    delta: i3,   // signed 3-bit: -4..3
        \\    valid: i1,   // signed 1-bit: -1..0
        \\    pad:   u4,
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "signed_bits.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    const s = for (m.structs) |s| {
        if (std.mem.eql(u8, s.name, "SignedFlags")) break s;
    } else return error.StructNotFound;
    try std.testing.expectEqual(skarn.ir_mod.IrType{ .i = 3 }, s.fields[0].ty);
    try std.testing.expectEqual(skarn.ir_mod.IrType{ .i = 1 }, s.fields[1].ty);
}

// ── New attributes ────────────────────────────────────────────────────────────

test "#noreturn: function with noreturn attribute" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // #noreturn function doesn't need to have all paths return
    const src =
        \\#extern("kernel32", "ExitProcess")
        \\ExitProcess :: fn(code: u32);
        \\
        \\#noreturn
        \\panic :: fn(msg: []const u8) {
        \\    ExitProcess(1u32);
        \\    // no return statement — allowed because #noreturn
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "noreturn.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    // The function should have the no_return flag set
    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "panic")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expect(fn_.no_return);
}

test "#noinline: function with noinline attribute" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#noinline
        \\cold_path :: fn(x: i32) -> i32 {
        \\    return x * 2;
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "noinline.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "cold_path")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expect(fn_.no_inline);
}

test "#export: function marked for export" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#export("skarn_add")
        \\add :: fn(a: i32, b: i32) -> i32 { return a + b; }
        \\
        \\#export
        \\multiply :: fn(a: i32, b: i32) -> i32 { return a * b; }
    ;
    var fe = try skarn.compile(arena.allocator(), "export.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    const add_fn = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "add")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expectEqualStrings("skarn_add", add_fn.export_sym.?);

    const mul_fn = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "multiply")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expect(mul_fn.export_sym != null);
}

test "#deprecated: calling deprecated function emits warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#deprecated("use write_stdout instead")
        \\old_print :: fn(msg: []const u8) {}
        \\
        \\use :: fn() {
        \\    old_print("hello");   // should trigger warning
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "deprecated.sk", src);
    defer fe.deinit(arena.allocator());

    // Compile succeeds, but diagnostics contain a warning
    try std.testing.expectEqual(@as(usize, 1), fe.diagnostics().len);
    try std.testing.expectEqual(skarn.DiagKind.warning, fe.diagnostics()[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, fe.diagnostics()[0].message, "deprecated") != null);
}

// ── Jai-style #system_library / #foreign ─────────────────────────────────────

test "#system_library: standalone declaration is collected into IrModule.extern_libs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#system_library("raylib");
        \\#system_library("kernel32"); // always linked; should be skipped/deduped
        \\
        \\#extern("raylib", "InitWindow")
        \\InitWindow :: fn(width: i32, height: i32, title: *const u8);
        \\
        \\use_it :: fn() {
        \\    InitWindow(800, 450, "hi".ptr);
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "syslib.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    // "raylib" should appear exactly once (deduped between #system_library and #extern),
    // and "kernel32" should be skipped entirely (always linked by the backend).
    var raylib_count: usize = 0;
    for (m.extern_libs) |lib| {
        try std.testing.expect(!std.mem.eql(u8, lib, "kernel32"));
        if (std.mem.eql(u8, lib, "raylib")) raylib_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), raylib_count);
}

test "#foreign: alias for #extern binds external functions and contributes to extern_libs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#foreign("raylib", "WindowShouldClose")
        \\WindowShouldClose :: fn() -> bool;
        \\
        \\use_it :: fn() -> bool {
        \\    return WindowShouldClose();
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "foreign.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "WindowShouldClose")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expectEqualStrings("WindowShouldClose", fn_.extern_name.?);

    var found_raylib = false;
    for (m.extern_libs) |lib| {
        if (std.mem.eql(u8, lib, "raylib")) found_raylib = true;
    }
    try std.testing.expect(found_raylib);
}

// ── Distinct types ────────────────────────────────────────────────────────────

test "distinct integer type: lowers to underlying integer type in IR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\UserId :: distinct i32;
        \\
        \\make_user :: fn(raw: i32) -> UserId {
        \\    return raw as UserId;
        \\}
        \\
        \\unwrap :: fn(id: UserId) -> i32 {
        \\    return id as i32;
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "distinct_int.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    // `make_user` return type and `unwrap` param must be i32, not a struct_type.
    const make_fn = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "make_user")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expectEqual(skarn.ir_mod.IrType{ .i = 32 }, make_fn.return_ty);

    const unwrap_fn = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "unwrap")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expectEqual(skarn.ir_mod.IrType{ .i = 32 }, unwrap_fn.params[0].ty);
}

test "distinct pointer type: *opaque-based handle lowers to ptr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\RawHandle :: distinct *opaque;
        \\
        \\#extern("kernel32", "GetStdHandle")
        \\GetStdHandle :: fn(id: i32) -> RawHandle;
        \\
        \\stdout :: fn() -> RawHandle {
        \\    return GetStdHandle(-11);
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "distinct_ptr.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "stdout")) break f;
    } else return error.FunctionNotFound;
    // RawHandle is distinct *opaque — underlying is a pointer, should lower to ptr.
    try std.testing.expect(fn_.return_ty == .ptr);
}

test "distinct type in struct field lowers to underlying type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\EntityId :: distinct u32;
        \\
        \\Entity :: struct {
        \\    id:    EntityId,
        \\    alive: bool,
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "distinct_field.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    const s = for (m.structs) |s| {
        if (std.mem.eql(u8, s.name, "Entity")) break s;
    } else return error.StructNotFound;
    // EntityId is distinct u32 — the field must lower to u32, not struct_type.
    try std.testing.expectEqual(skarn.ir_mod.IrType{ .u = 32 }, s.fields[0].ty);
    try std.testing.expectEqual(skarn.ir_mod.IrType.bool, s.fields[1].ty);
}

// ── Opaque types ──────────────────────────────────────────────────────────────

test "opaque type: *Opaque parameter lowers to ptr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Context :: opaque;
        \\
        \\process :: fn(ctx: *Context) -> i32 {
        \\    return 0;
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "opaque_ptr.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "process")) break f;
    } else return error.FunctionNotFound;
    // *Context should lower to ptr (opaque pointer in LLVM 15+).
    try std.testing.expect(fn_.params[0].ty == .ptr);
}

// ── Atomic types ──────────────────────────────────────────────────────────────

test "atomic field: struct with atomic u32 fields lowers to regular u32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Counter :: struct {
        \\    value: atomic u32,
        \\    padding: u32,
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "atomic_field.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    const s = for (m.structs) |s| {
        if (std.mem.eql(u8, s.name, "Counter")) break s;
    } else return error.StructNotFound;
    // `atomic u32` strips the qualifier in the IR; field type must be u32.
    try std.testing.expectEqual(skarn.ir_mod.IrType{ .u = 32 }, s.fields[0].ty);
    try std.testing.expectEqual(skarn.ir_mod.IrType{ .u = 32 }, s.fields[1].ty);
}

test "atomic_load and atomic_store: parse, type-check, and lower to IR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Flag :: struct { ready: atomic u32 }
        \\
        \\set_ready :: fn(f: *Flag) {
        \\    core::atomic_store(&f.ready, 1u32, .release);
        \\}
        \\
        \\spin :: fn(f: *Flag) -> u32 {
        \\    while core::atomic_load(&f.ready, .acquire) == 0u32 {}
        \\    return core::atomic_load(&f.ready, .acquire);
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "atomic_ops.sk", src);
    defer fe.deinit(arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), fe.diagnostics().len);
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);
}

// ── Win64 C ABI for by-value aggregates (#extern) ─────────────────────────────
// raylib-style structs cross the C boundary by value. On Win64 a small struct
// (size 1/2/4/8) is coerced to an integer register; a larger one is passed by
// pointer (byval arg / sret return). Without this lowering every struct-passing
// C call is silently mis-ABI'd. See src/backend/llvm/abi.zig.

const raylib_abi_src =
    \\Color     :: struct { r: u8, g: u8, b: u8, a: u8 }
    \\Vector2   :: struct { x: f32, y: f32 }
    \\Rectangle :: struct { x: f32, y: f32, width: f32, height: f32 }
    \\
    \\#extern("raylib", "ClearBackground")
    \\clear_background :: fn(c: Color);
    \\
    \\#extern("raylib", "DrawCircleV")
    \\draw_circle_v :: fn(center: Vector2, radius: f32, color: Color);
    \\
    \\#extern("raylib", "DrawRectangleRec")
    \\draw_rect :: fn(rec: Rectangle);
    \\
    \\#extern("raylib", "GetCollisionRec")
    \\get_rect :: fn(a: Rectangle, b: Rectangle) -> Rectangle;
    \\
    \\forward :: fn(c: Color, v: Vector2, r: Rectangle, radius: f32) {
    \\    clear_background(c);
    \\    draw_circle_v(v, radius, c);
    \\    draw_rect(r);
    \\    r2 := get_rect(r, r);
    \\    draw_rect(r2);
    \\}
;

test "C ABI: #extern declarations lower by-value aggregates per Win64" {
    if (comptime !skarn.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try skarn.compile(arena.allocator(), "raylib_abi.sk", raylib_abi_src);
    defer fe.deinit(arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), fe.diagnostics().len);
    const m = try skarn.lowerFrontend(arena.allocator(), fe);

    var backend = skarn.LlvmBackend.init(arena.allocator(), "raylib_abi");
    defer backend.deinit();
    try backend.lower(m);
    const llvm_ir = try backend.getIrText(arena.allocator());

    inline for (.{
        // Symbols are the C names (the `#extern` 2nd arg), not the skarn decl names.
        "@ClearBackground(i32", // Color (4 bytes) → i32
        "@DrawCircleV(i64, float, i32", // Vector2 (8) → i64; radius f32; Color → i32
        "byval(%Rectangle)", // Rectangle (16) argument passed indirectly
        "sret(%Rectangle)", // Rectangle (16) returned via hidden sret pointer
    }) |needle| {
        std.testing.expect(std.mem.indexOf(u8, llvm_ir, needle) != null) catch |err| {
            std.debug.print("missing expected ABI fragment: {s}\n", .{needle});
            return err;
        };
    }
}

test "C ABI: call sites coerce by-value struct arguments and sret returns" {
    if (comptime !skarn.llvm_enabled) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try skarn.compile(arena.allocator(), "raylib_abi.sk", raylib_abi_src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);

    var backend = skarn.LlvmBackend.init(arena.allocator(), "raylib_abi_calls");
    defer backend.deinit();
    try backend.lower(m);
    const llvm_ir = try backend.getIrText(arena.allocator());

    inline for (.{
        // Call sites use the C symbol names too (`#extern` 2nd arg).
        "call void @ClearBackground(i32", // a %Color value coerced to i32 at the call
        "call void @GetCollisionRec(ptr", // sret slot + byval pointers passed to the call
    }) |needle| {
        std.testing.expect(std.mem.indexOf(u8, llvm_ir, needle) != null) catch |err| {
            std.debug.print("missing expected ABI call fragment: {s}\n", .{needle});
            return err;
        };
    }
}

// ── C binding generator (`skarn bindgen`, libclang) ──────────────────────────────

test "bindgen: C header lowers to Skarn structs, enum consts, and #extern fns" {
    if (comptime !skarn.llvm_enabled) return; // libclang ships with the LLVM build

    const csrc =
        \\typedef struct { float x; float y; } Vector2;
        \\typedef struct { unsigned char r, g, b, a; } Color;
        \\typedef struct { int type; int match; } Event;
        \\typedef enum { A = 0, B = 7 } E;
        \\void clear(Color c);
        \\Vector2 origin(void);
        \\int sum(int a, const char *s);
        \\void emit(int in);
        \\#define CLITERAL(type) (type)
        \\#define WHITE CLITERAL(Color){ 255, 255, 255, 255 }
        \\#define MAX_N 42
        \\#define SCALE 1.5f
        \\typedef union { int i; double d; } U;
        \\struct Opaque;
        \\void use_opaque(struct Opaque *o);
        \\typedef int (*BinOp)(int, int);
        \\int reduce(BinOp op, int a);
        \\int variadic(int n, ...);
    ;
    const out = try skarn.bindgen.generateString(std.testing.allocator, "t.h", csrc, "demo", &.{});
    defer std.testing.allocator.free(out);

    inline for (.{
        "#system_library(\"demo\");",
        "pub Vector2 :: struct {",
        "pub Color :: struct {",
        "pub A :: 0;",
        "pub B :: 7;",
        "#extern(\"demo\", \"clear\")",
        "pub clear :: fn(c: Color);",
        "pub origin :: fn() -> Vector2;",
        "pub sum :: fn(a: i32, s: [*]const u8) -> i32;",
        // Skarn keywords used as C identifiers get a trailing `_`, while the
        // `#extern` symbol keeps the original C name.
        "    type_: i32,",
        "    match_: i32,",
        "#extern(\"demo\", \"emit\")",
        "pub emit :: fn(in_: i32);",
        // #define constants: plain numeric/float, and a raylib-style color macro
        // (compound literal) materialized as a #run-folded typed constant.
        "pub MAX_N :: 42;",
        "pub SCALE :: 1.5;",
        "pub WHITE :: #run __lit_WHITE();",
        "__lit_WHITE :: fn() -> Color { return .{ 255 , 255 , 255 , 255 }; }",
        // hard constructs: union → sized blob, opaque type, fn-pointer param, variadic
        "pub U :: struct { _bytes: [8]u8 }",
        "pub Opaque :: opaque;",
        "pub use_opaque :: fn(o: *Opaque);",
        "pub reduce :: fn(op: fn(i32, i32) -> i32, a: i32) -> i32;",
        "// note: C variadic function",
    }) |needle| {
        std.testing.expect(std.mem.indexOf(u8, out, needle) != null) catch |err| {
            std.debug.print("bindgen output missing '{s}'\n--- full output ---\n{s}\n", .{ needle, out });
            return err;
        };
    }
}

// ── Linker: honoring a C library's /DEFAULTLIB directives ───────────────────────

fn argsContain(args: []const []const u8, needle: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, needle)) return true;
    return false;
}

test "link: honor_defaultlibs suppresses CRT umbrellas instead of blanket /NODEFAULTLIB" {
    if (comptime !skarn.llvm_enabled) return error.SkipZigTest;
    const a = std.testing.allocator;

    // Default (strict): blanket /NODEFAULTLIB, no per-umbrella suppression.
    {
        const args = try skarn.llvm_link.buildArgs(a, .{ .llvm_bin = "x", .output = "o.exe", .obj_files = &.{} });
        defer {
            for (args) |s| a.free(@constCast(s));
            a.free(args);
        }
        try std.testing.expect(argsContain(args, "/NODEFAULTLIB"));
        try std.testing.expect(!argsContain(args, "/NODEFAULTLIB:msvcrt"));
    }

    // Honoring: no blanket suppression; only the CRT-startup umbrellas are excluded,
    // so a C library's own /DEFAULTLIB:opengl32 etc. flow in.
    {
        const args = try skarn.llvm_link.buildArgs(a, .{ .llvm_bin = "x", .output = "o.exe", .obj_files = &.{}, .honor_defaultlibs = true });
        defer {
            for (args) |s| a.free(@constCast(s));
            a.free(args);
        }
        try std.testing.expect(!argsContain(args, "/NODEFAULTLIB"));
        try std.testing.expect(argsContain(args, "/NODEFAULTLIB:msvcrt"));
        try std.testing.expect(argsContain(args, "/NODEFAULTLIB:libcmt"));
    }
}

test "msvc: discoverLibX64 finds a vcruntime-bearing lib dir (or cleanly returns null)" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const a = std.testing.allocator; // also asserts the discovery routine doesn't leak
    if (skarn.msvc.discoverLibX64(a, std.testing.io)) |path| {
        defer a.free(path);
        // Whatever it finds must be a real x64 lib dir.
        try std.testing.expect(std.mem.endsWith(u8, path, "lib/x64"));
        try std.testing.expect(std.mem.indexOf(u8, path, "MSVC") != null);
    }
}

// ── `core::` builtin namespace ─────────────────────────────────────────────────

test "core::: a bare builtin call is rejected (must use core::)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Builtins live under `core::`; the bare spelling is a hard error.
    const src =
        \\P :: struct { x: i32 }
        \\main :: fn() -> i32 { return sizeof(P) as i32; }
    ;
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "bare.sk", src));
}

test "core::: `core::sizeof` and `core::type_id` are accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\P :: struct { x: i32, y: i32 }
        \\main :: fn() -> i32 { return (core::sizeof(P) as i32) + (core::type_id(P) as i32); }
    ;
    var fe = try skarn.compile(a, "ns.sk", src);
    defer fe.deinit(a);
    const m = try skarn.lowerFrontend(a, fe);
    try skarn.ir_mod.validateModule(m);
}

test "attrs: `#must_use` rejects a discarded call result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\#must_use
        \\compute :: fn() -> i32 { return 7; }
        \\main :: fn() -> i32 { compute(); return 0; }
    ;
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "mu.sk", src));
}

test "attrs: `#must_use` allows a used call result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\#must_use
        \\compute :: fn() -> i32 { return 7; }
        \\main :: fn() -> i32 { x := compute(); return x; }
    ;
    var fe = try skarn.compile(a, "mu_ok.sk", src);
    defer fe.deinit(a);
    const m = try skarn.lowerFrontend(a, fe);
    try skarn.ir_mod.validateModule(m);
}

test "core::: `core` is a reserved import alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A user module may not claim the `core` namespace.
    const src =
        \\#import std.heap as core;
        \\main :: fn() -> i32 { return 0; }
    ;
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "reserve.sk", src));
}
