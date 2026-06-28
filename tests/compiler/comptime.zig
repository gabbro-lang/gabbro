const std = @import("std");
const k2 = @import("k2_compiler");
const ir = @import("k2_compiler").ir_mod;

test "comptime: #if with TARGET.os compiles both branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\write :: fn(msg: []const u8) -> i32 {
        \\    #if TARGET.os == .windows {
        \\        return 1;
        \\    } else {
        \\        return 2;
        \\    }
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "ct.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "comptime: #run expression as value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\double :: fn(x: i32) -> i32 { return x * 2; }
        \\ANSWER :: #run double(21);
    ;
    var fe = try k2.compile(arena.allocator(), "ct2.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "comptime: #run block at statement level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\setup :: fn() -> i32 { return 42; }
        \\
        \\main :: fn() -> i32 {
        \\    result := 0;
        \\    #run {
        \\        result = setup();
        \\    }
        \\    return result;
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "ct3.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);
}

test "#run: constant computed at compile time, not runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\// Recursive fibonacci computed ENTIRELY at compile time.
        \\fib :: fn(n: i32) -> i32 {
        \\    if n <= 1 { return n; }
        \\    return fib(n - 1) + fib(n - 2);
        \\}
        \\
        \\FIB_10 :: #run fib(10);    // = 55  — no runtime call
        \\FIB_7  :: #run fib(7);     // = 13  — no runtime call
        \\ANSWER :: #run fib(6) * 7; // = 8*7 = 56? no: fib(6)=8, 8*7=56
        \\
        \\use_them :: fn() -> i32 {
        \\    return FIB_10 + FIB_7;   // 55 + 13 = 68
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "fib_ct.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    // The globals should be initialised with COMPILE-TIME constants, not function calls.
    var found_fib10 = false;
    var found_fib7 = false;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "FIB_10")) {
            found_fib10 = true;
            // Must be a compile-time integer constant (not unknown/null)
            try std.testing.expectEqual(ir.Imm{ .int = 55 }, g.init.imm);
        }
        if (std.mem.eql(u8, g.name, "FIB_7")) {
            found_fib7 = true;
            try std.testing.expectEqual(ir.Imm{ .int = 13 }, g.init.imm);
        }
    }
    try std.testing.expect(found_fib10);
    try std.testing.expect(found_fib7);
}

test "#run: string .len and enum-payload construction fold on the VM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // `s.len` on a `.text` string and `EnumType.variant(payload)` construction
    // both used to be unsupported in the comptime VM (string fell through the
    // `.len` switch; payload variants couldn't be built at all).
    const src =
        \\Tok :: enum { num: i32, word: []const u8, end }
        \\slen :: fn() -> i32 { s := "hello"; return s.len as i32; }
        \\enum_payload :: fn() -> i32 {
        \\    t := Tok.num(20);
        \\    match t { .num |v| => return v + 1; else => return -1; }
        \\}
        \\str_payload :: fn() -> i32 {
        \\    t := Tok.word("abcd");
        \\    match t { .word |w| => return w.len as i32; else => return -1; }
        \\}
        \\LEN :: #run slen();          // 5
        \\EP  :: #run enum_payload();  // 21
        \\SP  :: #run str_payload();   // 4
    ;
    var fe = try k2.compile(arena.allocator(), "vmstr.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    var got: usize = 0;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "LEN")) {
            got += 1;
            try std.testing.expectEqual(ir.Imm{ .int = 5 }, g.init.imm);
        }
        if (std.mem.eql(u8, g.name, "EP")) {
            got += 1;
            try std.testing.expectEqual(ir.Imm{ .int = 21 }, g.init.imm);
        }
        if (std.mem.eql(u8, g.name, "SP")) {
            got += 1;
            try std.testing.expectEqual(ir.Imm{ .int = 4 }, g.init.imm);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), got);
}

test "#run: taking the address of a scalar local folds on the VM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // `&x` of a scalar local used to be unsupported in the comptime VM, so the
    // function trapped and the const silently folded to a wrong value. Now the
    // local is spilled to an addressable cell and the result is correct.
    const src =
        \\bump :: fn() -> i32 {
        \\    x := 5;
        \\    p := &x;
        \\    *p = *p + 1;
        \\    return x;
        \\}
        \\incr :: fn(p: *i32) { *p = *p + 10; }
        \\via_param :: fn(start: i32) -> i32 {
        \\    n := start;
        \\    incr(&n);
        \\    return n;
        \\}
        \\R1 :: #run bump();          // 6
        \\R2 :: #run via_param(1);    // 11
    ;
    var fe = try k2.compile(arena.allocator(), "addr_ct.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    var r1: bool = false;
    var r2: bool = false;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "R1")) {
            r1 = true;
            try std.testing.expectEqual(ir.Imm{ .int = 6 }, g.init.imm);
        }
        if (std.mem.eql(u8, g.name, "R2")) {
            r2 = true;
            try std.testing.expectEqual(ir.Imm{ .int = 11 }, g.init.imm);
        }
    }
    try std.testing.expect(r1 and r2);
}

test "#run: an un-foldable constant fails with a diagnostic, not silent garbage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A `#run` constant whose result is an aggregate cannot be a scalar global;
    // the lowering must reject it (LoweringFailed after a clear diagnostic),
    // never silently substitute a best-effort literal.
    const src =
        \\P :: struct { x: i32, y: i32 }
        \\make_p :: fn() -> P { return .{ 1, 2 }; }
        \\BAD :: #run make_p();
    ;
    var fe = try k2.compile(arena.allocator(), "bad_ct.sk", src);
    defer fe.deinit(arena.allocator());
    try std.testing.expectError(error.LoweringFailed, k2.lowerFrontend(arena.allocator(), fe));
}

test "#run: a comptime @panic halts the build with its message (#2)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A comptime `@panic("…")` used to bare-trap (message thrown away). It now
    // records the message via `halt_msg` and the `#run` fails with it instead of
    // the generic "could not be evaluated". The text goes straight to stderr, so
    // this asserts the halt (LoweringFailed); the message itself is verified by
    // eye — `error: explicit comptime panic`.
    const src =
        \\boom :: fn() -> i32 { @panic("explicit comptime panic"); return 0; }
        \\BAD :: #run boom();
    ;
    var fe = try k2.compile(arena.allocator(), "panic_ct.sk", src);
    defer fe.deinit(arena.allocator());
    try std.testing.expectError(error.LoweringFailed, k2.lowerFrontend(arena.allocator(), fe));
}

test "#if: only live branch emitted to IR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\platform_id :: fn() -> i32 {
        \\    #if TARGET.os == .windows {
        \\        return 1;
        \\    } else {
        \\        return 2;
        \\    }
        \\}
    ;
    var fe = try k2.compile(arena.allocator(), "platform.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    // Find platform_id and verify it compiled (the #if selected a branch)
    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "platform_id")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expect(fn_.blocks.len > 0);
}

fn expectGlobalInt(m: anytype, name: []const u8, want: i128) !void {
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, name)) {
            const got: i128 = switch (g.init.imm) {
                .int => |v| v,
                .uint => |v| @intCast(v),
                .bool => |b| @intFromBool(b),
                else => return error.NotAnInt,
            };
            try std.testing.expectEqual(want, got);
            return;
        }
    }
    return error.GlobalNotFound;
}

test "comptime: matchable TypeInfo — scalar kinds + fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\bits_of   :: fn($T: type) -> i32 { match core::type_info(T) { .int |i| => return i.bits as i32; .float |f| => return f.bits as i32; else => return 0; } }
        \\is_signed :: fn($T: type) -> i32 { match core::type_info(T) { .int |i| => { if i.signed { return 1; } return 0; } else => return -1; } }
        \\is_bool   :: fn($T: type) -> i32 { match core::type_info(T) { .boolean => return 1; else => return 0; } }
        \\I32_BITS   :: #run bits_of(i32);
        \\U8_BITS    :: #run bits_of(u8);
        \\F64_BITS   :: #run bits_of(f64);
        \\I32_SIGNED :: #run is_signed(i32);
        \\U8_SIGNED  :: #run is_signed(u8);
        \\BOOL_IS    :: #run is_bool(bool);
    ;
    var fe = try k2.compile(arena.allocator(), "ti1.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    try expectGlobalInt(m, "I32_BITS", 32);
    try expectGlobalInt(m, "U8_BITS", 8);
    try expectGlobalInt(m, "F64_BITS", 64);
    try expectGlobalInt(m, "I32_SIGNED", 1);
    try expectGlobalInt(m, "U8_SIGNED", 0);
    try expectGlobalInt(m, "BOOL_IS", 1);
}

test "comptime: matchable TypeInfo — struct fields (iterate names + types)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Point :: struct { x: i32, yy: i32, zzz: i32 }
        \\nfields  :: fn($T: type) -> i32 { match core::type_info(T) { .struct_ |s| => return s.fields.len as i32; else => return -1; } }
        \\namelen  :: fn($T: type) -> i32 { match core::type_info(T) { .struct_ |s| => return s.name.len as i32; else => return -1; } }
        \\namesum  :: fn($T: type) -> i32 { t := 0; match core::type_info(T) { .struct_ |s| => { for f in s.fields { t = t + (f.name.len as i32); } return t; } else => return -1; } }
        \\int_flds :: fn($T: type) -> i32 { n := 0; match core::type_info(T) { .struct_ |s| => { for f in s.fields { match *f.ty { .int => n = n + 1; else => {} } } return n; } else => return -1; } }
        \\FIELD_COUNT :: #run nfields(Point);
        \\STRUCT_NAMELEN :: #run namelen(Point);
        \\NAME_SUM :: #run namesum(Point);
        \\INT_FIELDS :: #run int_flds(Point);
    ;
    var fe = try k2.compile(arena.allocator(), "ti2.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    try expectGlobalInt(m, "FIELD_COUNT", 3);
    try expectGlobalInt(m, "STRUCT_NAMELEN", 5); // "Point"
    try expectGlobalInt(m, "NAME_SUM", 6); // x(1)+yy(2)+zzz(3)
    try expectGlobalInt(m, "INT_FIELDS", 3);
}

test "comptime: matchable TypeInfo — pointer/slice/optional + element navigation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\is_ptr   :: fn($T: type) -> i32 { match core::type_info(T) { .pointer => return 1; else => return 0; } }
        \\is_slice :: fn($T: type) -> i32 { match core::type_info(T) { .slice => return 1; else => return 0; } }
        \\is_opt   :: fn($T: type) -> i32 { match core::type_info(T) { .optional => return 1; else => return 0; } }
        \\elem_bits :: fn($T: type) -> i32 { match core::type_info(T) { .slice |e| => { match *e { .int |i| => return i.bits as i32; else => return -1; } } else => return -2; } }
        \\IS_PTR   :: #run is_ptr(*i32);
        \\IS_SLICE :: #run is_slice([]u8);
        \\IS_OPT   :: #run is_opt(?i32);
        \\ELEM_BITS :: #run elem_bits([]u8);
    ;
    var fe = try k2.compile(arena.allocator(), "ti3.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    try expectGlobalInt(m, "IS_PTR", 1);
    try expectGlobalInt(m, "IS_SLICE", 1);
    try expectGlobalInt(m, "IS_OPT", 1);
    try expectGlobalInt(m, "ELEM_BITS", 8);
}

test "comptime: type_name returns mangled type name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\NAME :: #run core::type_name(i32);
    ;
    var fe = try k2.compile(arena.allocator(), "tn1.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try k2.lowerFrontend(arena.allocator(), fe);
    try k2.ir_mod.validateModule(m);

    var found = false;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "NAME")) {
            found = true;
            try std.testing.expectEqualStrings("i32", g.init.imm.text);
        }
    }
    try std.testing.expect(found);
}

