const std = @import("std");
const skarn = @import("skarn_compiler");

const instructions = skarn.vm_instructions;
const engine = skarn.vm_engine;
const compiler = skarn.vm_compiler;
const Value = skarn.vm_value.Value;
const Instr = instructions.Instr;

// ── Engine: hand-assembled bytecode ──────────────────────────────────────

test "engine: hand-assembled arithmetic" {
    var vm = engine.Vm.init(std.testing.allocator);
    defer vm.deinit();

    const code = [_]Instr{
        Instr.r_imm(.load_imm, 1, 10),
        Instr.r_imm(.load_imm, 2, 32),
        Instr.r_r_r(.add_i, 3, 1, 2),
        Instr.r_imm(.ret, 3, 0),
    };
    const func = instructions.BytecodeFunction{
        .name = "add",
        .instrs = &code,
        .num_regs = 4,
        .num_locals = 0,
    };

    const result = try vm.execute(func);
    try std.testing.expectEqual(@as(i128, 42), result.int);
}

test "engine: hand-assembled loop (sum 1..=5)" {
    var vm = engine.Vm.init(std.testing.allocator);
    defer vm.deinit();

    // r0=acc r1=i r2=n r3=cond r4=one
    const code = [_]Instr{
        Instr.r_imm(.load_imm, 0, 0), // 0: acc = 0
        Instr.r_imm(.load_imm, 1, 1), // 1: i = 1
        Instr.r_imm(.load_imm, 2, 5), // 2: n = 5
        Instr.r_r_r(.le_i, 3, 1, 2), // 3: cond = i <= n
        Instr.r_imm(.br_if_not, 3, 9), // 4: if !cond goto 9
        Instr.r_r_r(.add_i, 0, 0, 1), // 5: acc += i
        Instr.r_imm(.load_imm, 4, 1), // 6: one = 1
        Instr.r_r_r(.add_i, 1, 1, 4), // 7: i += 1
        Instr.with_imm(.jmp, 3), // 8: goto 3
        Instr.r_imm(.ret, 0, 0), // 9: ret acc
    };
    const func = instructions.BytecodeFunction{
        .name = "loop",
        .instrs = &code,
        .num_regs = 5,
        .num_locals = 0,
    };

    const result = try vm.execute(func);
    try std.testing.expectEqual(@as(i128, 15), result.int);
}

test "engine: zone push/alloc/pop leaves no active zones" {
    var vm = engine.Vm.init(std.testing.allocator);
    defer vm.deinit();

    const consts = [_]Value{.{ .string = "scratch" }};
    const code = [_]Instr{
        Instr.with_imm(.zone_push, 0), // push zone named consts[0]
        Instr.r_imm(.zone_alloc, 0, 4), // r0 = alloc 4 bytes
        Instr.r_imm(.zone_alloc, 1, 8), // r1 = alloc 8 bytes
        Instr.with_imm(.zone_pop, 0), // free the zone
        Instr.with_imm(.ret_void, 0),
    };
    const func = instructions.BytecodeFunction{
        .name = "zones",
        .instrs = &code,
        .num_regs = 2,
        .num_locals = 0,
        .constants = &consts,
    };

    _ = try vm.execute(func);
    try std.testing.expectEqual(@as(usize, 0), vm.zone_stack.depth());
    // testing.allocator asserts the zone's host memory was freed.
}

test "engine: zones unwind on early return" {
    var vm = engine.Vm.init(std.testing.allocator);
    defer vm.deinit();

    const consts = [_]Value{.{ .string = "z" }};
    // Push a zone, allocate, then return WITHOUT popping — the frame must
    // unwind the zone itself.
    const code = [_]Instr{
        Instr.with_imm(.zone_push, 0),
        Instr.r_imm(.zone_alloc, 0, 16),
        Instr.r_imm(.load_imm, 1, 7),
        Instr.r_imm(.ret, 1, 0),
    };
    const func = instructions.BytecodeFunction{
        .name = "leaky",
        .instrs = &code,
        .num_regs = 2,
        .num_locals = 0,
        .constants = &consts,
    };

    const result = try vm.execute(func);
    try std.testing.expectEqual(@as(i128, 7), result.int);
    try std.testing.expectEqual(@as(usize, 0), vm.zone_stack.depth());
}

// ── End-to-end: Skarn source → IR → bytecode → run ──────────────────────────

/// Compile Skarn source, lower to IR, compile the named function's module, and
/// invoke it with `args`. Caller owns nothing; everything is freed here.
fn runSource(
    src: []const u8,
    func_name: []const u8,
    args: []const Value,
) !Value {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try skarn.compile(a, "vm_test.sk", src);
    defer fe.deinit(a);
    const ir_module = try skarn.lowerFrontend(a, fe);

    var bc = try compiler.compileModule(std.testing.allocator, ir_module);
    defer bc.deinit(std.testing.allocator);

    var vm = engine.Vm.initModule(std.testing.allocator, &bc);
    defer vm.deinit();
    return vm.call(func_name, args);
}

test "e2e: function with parameters" {
    const src =
        \\add :: fn(a: i32, b: i32) -> i32 {
        \\    return a + b;
        \\}
    ;
    const result = try runSource(src, "add", &.{ .{ .int = 17 }, .{ .int = 25 } });
    try std.testing.expectEqual(@as(i128, 42), result.int);
}

test "e2e: recursion (factorial)" {
    const src =
        \\fact :: fn(n: i32) -> i32 {
        \\    if n <= 1 {
        \\        return 1;
        \\    }
        \\    return n * fact(n - 1);
        \\}
    ;
    const result = try runSource(src, "fact", &.{.{ .int = 5 }});
    try std.testing.expectEqual(@as(i128, 120), result.int);
}

test "e2e: #run calls a function, folded to a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\square :: fn(x: i32) -> i32 { return x * x; }
        \\ANSWER :: #run square(7);
    ;
    var fe = try skarn.compile(a, "run.sk", src);
    defer fe.deinit(a);
    const m = try skarn.lowerFrontend(a, fe);

    const g = for (m.globals) |gg| {
        if (std.mem.eql(u8, gg.name, "ANSWER")) break gg;
    } else return error.GlobalNotFound;
    try std.testing.expectEqual(@as(i128, 49), g.init.imm.int);
}

fn globalInt(m: anytype, name: []const u8) !i128 {
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, name)) return switch (g.init.imm) {
            .int => |v| v,
            .uint => |v| @intCast(v),
            else => error.NotAnInt,
        };
    }
    return error.GlobalNotFound;
}

test "e2e: #run sizeof folds scalar, struct, and array sizes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\Point :: struct { x: i32, y: i32 }
        \\SI :: #run core::sizeof(i32);
        \\SP :: #run core::sizeof(Point);
        \\SA :: #run core::sizeof([4]i32);
    ;
    var fe = try skarn.compile(a, "sz.sk", src);
    defer fe.deinit(a);
    const m = try skarn.lowerFrontend(a, fe);

    try std.testing.expectEqual(@as(i128, 4), try globalInt(m, "SI"));
    try std.testing.expectEqual(@as(i128, 8), try globalInt(m, "SP"));
    try std.testing.expectEqual(@as(i128, 16), try globalInt(m, "SA"));
}

test "e2e: #run enum match folds to a constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\Dir :: enum { north, south, east, west }
        \\rank :: fn(d: Dir) -> i32 {
        \\    match d {
        \\        .north => return 1;
        \\        .south => return 2;
        \\        .east  => return 3;
        \\        .west  => return 4;
        \\        else   => return 0;
        \\    }
        \\}
        \\R :: #run rank(Dir.east);
    ;
    var fe = try skarn.compile(a, "enum.sk", src);
    defer fe.deinit(a);
    const m = try skarn.lowerFrontend(a, fe);
    try std.testing.expectEqual(@as(i128, 3), try globalInt(m, "R"));
}

test "e2e: #run optionals (?? coalesce and !! unwrap)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\some_or :: fn() -> i32 {
        \\    x: ?i32 = 5;
        \\    return x ?? 99;
        \\}
        \\none_or :: fn() -> i32 {
        \\    x: ?i32 = null;
        \\    return x ?? 99;
        \\}
        \\unwrapped :: fn() -> i32 {
        \\    x: ?i32 = 7;
        \\    return x!!;
        \\}
        \\SOME :: #run some_or();
        \\NONE :: #run none_or();
        \\UNW  :: #run unwrapped();
    ;
    var fe = try skarn.compile(a, "opt.sk", src);
    defer fe.deinit(a);
    const m = try skarn.lowerFrontend(a, fe);
    try std.testing.expectEqual(@as(i128, 5), try globalInt(m, "SOME"));
    try std.testing.expectEqual(@as(i128, 99), try globalInt(m, "NONE"));
    try std.testing.expectEqual(@as(i128, 7), try globalInt(m, "UNW"));
}

test "e2e: #run interface dynamic dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\Shape :: interface { area :: fn(self: *Self) -> i32; }
        \\Square :: struct { side: i32 }
        \\Square as Shape {
        \\    area :: fn(self: *Self) -> i32 { return self.side * self.side; }
        \\}
        \\compute :: fn(s: *Shape) -> i32 { return s.area(); }
        \\go :: fn() -> i32 {
        \\    sq: Square = .{ 5 };
        \\    s: *Shape = &sq;
        \\    return compute(s);
        \\}
        \\AREA :: #run go();
    ;
    var fe = try skarn.compile(a, "iface.sk", src);
    defer fe.deinit(a);
    const m = try skarn.lowerFrontend(a, fe);
    try std.testing.expectEqual(@as(i128, 25), try globalInt(m, "AREA"));
}

test "e2e: #run fallible with catch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\NetError :: errors { boom }
        \\risky :: fn(x: i32) -> i32 ! NetError {
        \\    if x < 0 {
        \\        fail .boom;
        \\    }
        \\    return x * 2;
        \\}
        \\safe :: fn(x: i32) -> i32 {
        \\    data := risky(x) catch e {
        \\        return -1;
        \\    };
        \\    return data;
        \\}
        \\OKV :: #run safe(5);
        \\BADV :: #run safe(-3);
    ;
    var fe = try skarn.compile(a, "fallible.sk", src);
    defer fe.deinit(a);
    const m = try skarn.lowerFrontend(a, fe);
    try std.testing.expectEqual(@as(i128, 10), try globalInt(m, "OKV"));
    try std.testing.expectEqual(@as(i128, -1), try globalInt(m, "BADV"));
}

test "e2e: float arithmetic" {
    const src =
        \\favg :: fn(a: f64, b: f64) -> f64 {
        \\    return (a + b) / 2.0;
        \\}
    ;
    const result = try runSource(src, "favg", &.{ .{ .float = 3.0 }, .{ .float = 5.0 } });
    try std.testing.expectEqual(@as(f64, 4.0), result.float);
}

test "e2e: float comparison" {
    const src =
        \\fmax :: fn(a: f64, b: f64) -> f64 {
        \\    if a > b {
        \\        return a;
        \\    }
        \\    return b;
        \\}
    ;
    const hi = try runSource(src, "fmax", &.{ .{ .float = 3.5 }, .{ .float = 2.25 } });
    try std.testing.expectEqual(@as(f64, 3.5), hi.float);
    const lo = try runSource(src, "fmax", &.{ .{ .float = 1.0 }, .{ .float = 9.0 } });
    try std.testing.expectEqual(@as(f64, 9.0), lo.float);
}

test "e2e: struct construct and field read" {
    const src =
        \\Point :: struct { x: i32, y: i32 }
        \\
        \\sum :: fn(a: i32, b: i32) -> i32 {
        \\    p: Point = .{ a, b };
        \\    return p.x + p.y;
        \\}
    ;
    const result = try runSource(src, "sum", &.{ .{ .int = 17 }, .{ .int = 25 } });
    try std.testing.expectEqual(@as(i128, 42), result.int);
}

test "e2e: struct field mutation" {
    const src =
        \\Point :: struct { x: i32, y: i32 }
        \\
        \\bump :: fn() -> i32 {
        \\    p: Point = .{ 1, 2 };
        \\    p.x = 10;
        \\    return p.x + p.y;
        \\}
    ;
    const result = try runSource(src, "bump", &.{});
    try std.testing.expectEqual(@as(i128, 12), result.int);
}

test "e2e: while loop with locals" {
    const src =
        \\sumto :: fn(n: i32) -> i32 {
        \\    total := 0;
        \\    i := 1;
        \\    while i <= n {
        \\        total = total + i;
        \\        i = i + 1;
        \\    }
        \\    return total;
        \\}
    ;
    const result = try runSource(src, "sumto", &.{.{ .int = 10 }});
    try std.testing.expectEqual(@as(i128, 55), result.int);
}

test "e2e: array indexing in a loop" {
    const src =
        \\asum :: fn() -> i32 {
        \\    arr: [3]i32 = .{ 5, 7, 9 };
        \\    total := 0;
        \\    i := 0;
        \\    while i < 3 {
        \\        total = total + arr[i];
        \\        i = i + 1;
        \\    }
        \\    return total;
        \\}
    ;
    const result = try runSource(src, "asum", &.{});
    try std.testing.expectEqual(@as(i128, 21), result.int);
}

test "e2e: array length" {
    const src =
        \\alen :: fn() -> i32 {
        \\    arr: [5]i32 = .{ 1, 2, 3, 4, 5 };
        \\    return arr.len as i32;
        \\}
    ;
    const result = try runSource(src, "alen", &.{});
    try std.testing.expectEqual(@as(i128, 5), result.int);
}

test "e2e: slice of an array (index + len)" {
    const src =
        \\ssum :: fn() -> i32 {
        \\    arr: [4]i32 = .{ 1, 2, 3, 4 };
        \\    s: []i32 = arr[1..3];
        \\    return s[0] + s[1] + (s.len as i32);
        \\}
    ;
    // s = {2, 3}; 2 + 3 + len(2) = 7
    const result = try runSource(src, "ssum", &.{});
    try std.testing.expectEqual(@as(i128, 7), result.int);
}
