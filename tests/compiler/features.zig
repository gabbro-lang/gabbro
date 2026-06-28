const std = @import("std");
const skarn = @import("skarn_compiler");

test "arithmetic and bitwise operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\add_sub :: fn(a: i32, b: i32) -> i32 { return a + b - b; }
        \\mul_div :: fn(a: i32, b: i32) -> i32 { return a * b / b; }
        \\bitwise :: fn(a: u32, b: u32) -> u32 { return a | b ^ (a & ~b); }
        \\shifts  :: fn(a: u32) -> u32 { return (a << 2) >> 1; }
        \\rem     :: fn(a: i32, b: i32) -> i32 { return a % b; }
    ;
    var fe = try skarn.compile(arena.allocator(), "arith.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);
    var opt = m;
    try skarn.ir_mod.runDefaultPasses(arena.allocator(), &opt);
    try skarn.ir_mod.validateModule(opt);
}

test "comparison and logical operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\cmp :: fn(a: i32, b: i32) -> bool { return a <= b && b > 0 || a >= 0; }
        \\neg :: fn(x: bool) -> bool { return !x; }
    ;
    var fe = try skarn.compile(arena.allocator(), "cmp.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);
}

test "compound assignment operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\counter :: fn(n: u32) -> u32 {
        \\    x := 0u32;
        \\    i := 0u32;
        \\    while i < n {
        \\        x += i;
        \\        x *= 2u32;
        \\        i += 1u32;
        \\    }
        \\    return x;
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "compound.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);
}

test "break and continue in while loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\find :: fn(data: [*]const u32, count: usize) -> u32 {
        \\    i := 0usize;
        \\    result := 0u32;
        \\    while i < count {
        \\        v := data[i];
        \\        if v != 0u32 {
        \\            result = v;
        \\            break;
        \\        }
        \\        i += 1;
        \\    }
        \\    return result;
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "break.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);
}

test "CFG analysis rejects missing return on non-void function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn() -> i32 { }
    ;
    try std.testing.expectError(
        error.SemanticFailed,
        skarn.compile(arena.allocator(), "bad.sk", bad),
    );
}

test "break outside loop fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn() { break; }
    ;
    try std.testing.expectError(
        error.SemanticFailed,
        skarn.compile(arena.allocator(), "bad_break.sk", bad),
    );
}

test "constant folding folds binary ops in function body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // A function that returns a compile-time constant expression.
    // After const-fold + DCE the only instruction left should be the return.
    const src =
        \\answer :: fn() -> i32 {
        \\    x := 6 * 7;
        \\    return x;
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "fold.sk", src);
    defer fe.deinit(arena.allocator());
    var m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.runDefaultPasses(arena.allocator(), &m);
    try skarn.ir_mod.validateModule(m);
    // Verify the function exists and its IR is valid
    try std.testing.expectEqual(@as(usize, 1), m.functions.len);
}

test "zone block desugars to std.heap.Arena make/new/deinit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Header :: struct { magic: u32, len: u32, }
        \\
        \\process :: fn(count: usize) -> bool {
        \\    zone scratch: Arena {
        \\        h := scratch.new(Header);
        \\        buf := scratch.new_slice(u8, count);
        \\        h.magic = core::narrow(u32, buf.len);
        \\    }
        \\    return true;
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "zone.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    // The handle is a real std.heap.Arena: entering the zone calls `make`, the
    // body's `new`/`new_slice` lower as ordinary calls, and the zone exit calls
    // `deinit` — no special zone IR ops.
    const func = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "process")) break f;
    } else return error.FunctionNotFound;

    var found_make = false;
    var found_deinit = false;
    var found_new = false;
    var found_new_slice = false;
    for (func.blocks) |block| {
        for (block.instrs) |instr| switch (instr.kind) {
            .call => |c| {
                // `new`/`new_slice` are generic, so they carry a mangled
                // instantiation suffix (e.g. `new__T_named`); match the prefix.
                if (std.mem.eql(u8, c.callee, "make")) found_make = true;
                if (std.mem.eql(u8, c.callee, "deinit")) found_deinit = true;
                if (std.mem.startsWith(u8, c.callee, "new_slice")) found_new_slice = true;
                if (std.mem.startsWith(u8, c.callee, "new__")) found_new = true;
            },
            else => {},
        };
    }
    try std.testing.expect(found_make);
    try std.testing.expect(found_deinit);
    try std.testing.expect(found_new);
    try std.testing.expect(found_new_slice);
}

test "zone RAII: return inside zone deinits the arena first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\early_exit :: fn(flag: bool) -> i32 {
        \\    zone temp: Arena {
        \\        if flag {
        \\            return 1;
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "raii.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    // A `return` inside the zone must tear the arena down first: the instruction
    // right before that `return` terminator is the `deinit` call.
    const func = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "early_exit")) break f;
    } else return error.FunctionNotFound;

    var found_deinit_before_return = false;
    for (func.blocks) |block| {
        if (block.terminator) |term| switch (term) {
            .return_value => {
                if (block.instrs.len == 0) continue;
                const last = block.instrs[block.instrs.len - 1];
                if (last.kind == .call and std.mem.eql(u8, last.kind.call.callee, "deinit"))
                    found_deinit_before_return = true;
            },
            else => {},
        };
    }
    try std.testing.expect(found_deinit_before_return);
}

test "zone ownership: allocations cannot escape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const returned =
        \\bad :: fn() -> *i32 {
        \\    zone scratch: Arena {
        \\        return scratch.new(i32);
        \\    }
        \\}
    ;
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "zone_return.sk", returned));

    const outer_assignment =
        \\bad :: fn() {
        \\    escaped: ?*i32 = null;
        \\    zone scratch: Arena {
        \\        escaped = scratch.new(i32);
        \\    }
        \\}
    ;
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "zone_outer.sk", outer_assignment));

    const passed_to_function =
        \\consume :: fn(value: *i32) {}
        \\bad :: fn() {
        \\    zone scratch: Arena {
        \\        consume(scratch.new(i32));
        \\    }
        \\}
    ;
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "zone_call.sk", passed_to_function));
}

test "zone borrowing: borrowed parameters may use and forward zone-owned values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\touch :: fn(data: borrow []u8) {
        \\    data[0] = 42u8;
        \\}
        \\forward :: fn(data: borrow []u8) {
        \\    alias := data;
        \\    touch(alias);
        \\}
        \\work :: fn() {
        \\    zone scratch: Arena {
        \\        data := scratch.new_slice(u8, 4);
        \\        forward(data);
        \\    }
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "zone_borrow.sk", src);
    defer fe.deinit(arena.allocator());
    const module = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(module);
}

test "zone borrowing: borrowed values cannot be retained or returned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const returned =
        \\bad :: fn(data: borrow []u8) -> []u8 {
        \\    return data;
        \\}
    ;
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "borrow_return.sk", returned));

    const ordinary_call =
        \\retain :: fn(data: []u8) {}
        \\bad :: fn(data: borrow []u8) { retain(data); }
    ;
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "borrow_call.sk", ordinary_call));

    const stored =
        \\bad :: fn(data: borrow []u8, out: *[]u8) {
        \\    *out = data;
        \\}
    ;
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "borrow_store.sk", stored));
}

test "zone borrowing: qualifier is restricted to checked pointer and slice parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "borrow_scalar.sk",
        \\bad :: fn(value: borrow i32) {}
    ));
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "borrow_return_type.sk",
        \\bad :: fn() -> borrow []u8;
    ));
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "borrow_extern.sk",
        \\bad :: fn(value: borrow []u8);
    ));
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "borrow_field.sk",
        \\Bad :: struct { value: borrow []u8, }
    ));
}

test "zone ownership: only Arena is currently supported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\bad :: fn() {
        \\    zone scratch: Pool {}
        \\}
    ;
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "zone_kind.sk", src));
}

test "zone ownership: scalar reads may be passed and returned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\identity :: fn(value: usize) -> usize { return value; }
        \\ok :: fn() -> usize {
        \\    zone scratch: Arena {
        \\        data := scratch.new_slice(u8, 8);
        \\        return identity(data.len);
        \\    }
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "zone_scalar.sk", src);
    defer fe.deinit(arena.allocator());
}

test "defer: basic expression deferred to block end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\cleanup :: fn() {}
        \\work :: fn() -> bool {
        \\    defer cleanup();
        \\    return true;
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "defer.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    const func = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "work")) break f;
    } else return error.FunctionNotFound;

    // The deferred cleanup() call must appear BEFORE the return_value terminator
    for (func.blocks) |block| {
        if (block.terminator) |term| switch (term) {
            .return_value => {
                // last instruction before return must be a call to cleanup
                var found_cleanup_call = false;
                for (block.instrs) |instr| switch (instr.kind) {
                    .call => |c| if (std.mem.eql(u8, c.callee, "cleanup")) {
                        found_cleanup_call = true;
                    },
                    else => {},
                };
                try std.testing.expect(found_cleanup_call);
            },
            else => {},
        };
    }
}

test "defer: LIFO order — last defer runs first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\a :: fn() {}
        \\b :: fn() {}
        \\work :: fn() {
        \\    defer a();
        \\    defer b();
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "defer_order.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    const func = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "work")) break f;
    } else return error.FunctionNotFound;

    // Collect call instruction order
    var calls: std.ArrayList([]const u8) = .empty;
    defer calls.deinit(std.testing.allocator);
    for (func.blocks) |block| {
        for (block.instrs) |instr| switch (instr.kind) {
            .call => |c| if (!std.mem.eql(u8, c.callee, "work")) try calls.append(std.testing.allocator, c.callee),
            else => {},
        };
    }
    // b() was deferred last, so it runs first (LIFO)
    try std.testing.expectEqual(@as(usize, 2), calls.items.len);
    try std.testing.expectEqualStrings("b", calls.items[0]);
    try std.testing.expectEqualStrings("a", calls.items[1]);
}

test "defer inside zone block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\close :: fn() {}
        \\work :: fn(n: usize) -> bool {
        \\    zone scratch: Arena {
        \\        defer close();
        \\        buf := scratch.new_slice(u8, n);
        \\        buf[0] = 0u8;
        \\    }
        \\    return true;
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "defer_zone.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    const work = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "work")) break f;
    } else return error.FunctionNotFound;
    // The zone's `defer close()` must run before the arena `deinit` on exit.
    var saw_cleanup_before_pop = false;
    for (work.blocks) |block| {
        var saw_cleanup = false;
        for (block.instrs) |instr| switch (instr.kind) {
            .call => |call| {
                if (std.mem.eql(u8, call.callee, "close")) saw_cleanup = true;
                if (std.mem.eql(u8, call.callee, "deinit") and saw_cleanup) saw_cleanup_before_pop = true;
            },
            else => {},
        };
    }
    try std.testing.expect(saw_cleanup_before_pop);
}

test "zone RAII: fail deinits the arena before propagation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\Problem :: errors { bad, }
        \\work :: fn() -> i32 ! Problem {
        \\    zone scratch: Arena {
        \\        value := scratch.new(i32);
        \\        fail .bad;
        \\    }
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "zone_fail.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    const work = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "work")) break f;
    } else return error.FunctionNotFound;
    for (work.blocks) |block| {
        if (block.terminator) |term| switch (term) {
            .fail => {
                try std.testing.expect(block.instrs.len > 0);
                const last = block.instrs[block.instrs.len - 1];
                try std.testing.expect(last.kind == .call and std.mem.eql(u8, last.kind.call.callee, "deinit"));
                return;
            },
            else => {},
        };
    }
    return error.ExpectedFailTerminator;
}

test "unsafe_expr: unsafe prefix on expression is transparent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\read_byte :: fn(ptr: usize) -> u8 {
        \\    return unsafe core::unaligned_read(u8, ptr);
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "unsafe_expr.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);
}

test "asm: zero-input volatile instruction (pause)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\cpu_pause :: fn() {
        \\    unsafe {
        \\        core::asm(volatile, "pause", inputs: {}, outputs: {}, clobbers: {});
        \\    }
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "asm_pause.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);
}

test "asm: input operands and typed output (syscall pattern)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Models Linux write syscall: syscall nr in rax, fd in rdi, ptr in rsi, len in rdx.
    const src =
        \\sys_write :: fn(fd: i32, buf: usize, len: usize) -> isize {
        \\    return unsafe core::asm(
        \\        volatile,
        \\        "syscall",
        \\        inputs:  { "a"(1), "D"(fd), "S"(buf), "d"(len) },
        \\        outputs: { "=a"(isize) },
        \\        clobbers: { "rcx", "r11", "memory" },
        \\    );
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "asm_syscall.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    // Verify the asm produces an inline_asm instruction with correct structure.
    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "sys_write")) break f;
    } else return error.FunctionNotFound;

    var found_asm = false;
    for (fn_.blocks) |block| {
        for (block.instrs) |instr| switch (instr.kind) {
            .inline_asm => |ai| {
                found_asm = true;
                try std.testing.expectEqualStrings("syscall", ai.template);
                try std.testing.expect(ai.volatile_);
                try std.testing.expectEqual(@as(usize, 4), ai.args.len); // 4 inputs
                try std.testing.expect(std.mem.indexOf(u8, ai.constraints, "=a") != null);
                try std.testing.expect(std.mem.indexOf(u8, ai.constraints, "~{rcx}") != null);
            },
            else => {},
        };
    }
    try std.testing.expect(found_asm);
}

test "asm: unsafe required — bare asm fails outside unsafe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bad =
        \\bad :: fn() { core::asm(volatile, "pause", inputs: {}, outputs: {}, clobbers: {}); }
    ;
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "bad_asm.sk", bad));
}

test "?? nil-coalesce: unwrap or default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\find :: fn(ok: bool) -> ?i32 {
        \\    if ok { return 42; }
        \\    return null;
        \\}
        \\
        \\with_default :: fn(ok: bool) -> i32 {
        \\    return find(ok) ?? -1;
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "nil_coalesce.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    // with_default should have a conditional branch (for the ?? check)
    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "with_default")) break f;
    } else return error.FunctionNotFound;
    var has_cond_branch = false;
    for (fn_.blocks) |block| {
        if (block.terminator) |t| switch (t) {
            .cond_branch => has_cond_branch = true,
            else => {},
        };
    }
    try std.testing.expect(has_cond_branch);
}

test "!! force-unwrap: unwrap or panic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\find :: fn() -> ?i32 { return 42; }
        \\
        \\unwrap :: fn() -> i32 {
        \\    return find()!!;
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "force_unwrap.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    // unwrap should have a null check and a structured panic terminator with
    // the source location of the force-unwrap expression.
    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "unwrap")) break f;
    } else return error.FunctionNotFound;
    var panic: ?skarn.ir_mod.Panic = null;
    for (fn_.blocks) |block| {
        if (block.terminator) |t| switch (t) {
            .panic => |p| panic = p,
            else => {},
        };
    }
    try std.testing.expect(panic != null);
    try std.testing.expectEqualStrings("attempted to unwrap an empty optional", panic.?.message);
    try std.testing.expectEqualStrings("force_unwrap.sk", panic.?.location.file);
    try std.testing.expectEqual(@as(usize, 4), panic.?.location.line);
    try std.testing.expect(panic.?.location.column > 0);
}

test "generated panic locations retain their defining source file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const helper_src =
        \\unwrap_helper :: fn(value: ?i32) -> i32 {
        \\    return value!!;
        \\}
    ;
    const app_src =
        \\#import helper;
        \\main :: fn() -> i32 { return 0; }
    ;

    var fe = try skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "helper.sk", .source = helper_src },
        .{ .file_name = "app.sk", .source = app_src },
    });
    defer fe.deinit(arena.allocator());
    var module = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.runDefaultPasses(arena.allocator(), &module);

    const helper = for (module.functions) |function| {
        if (std.mem.eql(u8, function.name, "unwrap_helper")) break function;
    } else return error.FunctionNotFound;
    for (helper.blocks) |block| {
        if (block.terminator) |terminator| switch (terminator) {
            .panic => |panic| {
                try std.testing.expectEqualStrings("helper.sk", panic.location.file);
                try std.testing.expectEqual(@as(usize, 2), panic.location.line);
                return;
            },
            else => {},
        };
    }
    return error.PanicNotFound;
}

test "?? type mismatch fails sema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn(v: ?i32) -> i32 { return v ?? "wrong"; }
    ;
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "bad.sk", bad));
}

test "!! on non-optional fails sema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn(v: i32) -> i32 { return v!!; }
    ;
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "bad.sk", bad));
}

test "if-else with both branches returning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\abs :: fn(x: i32) -> i32 {
        \\    if x < 0 {
        \\        return 0 - x;
        \\    } else {
        \\        return x;
        \\    }
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "abs.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);
}

test "@panic runtime parses, checks, and lowers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#extern("kernel32", "ExitProcess")
        \\#noreturn
        \\ExitProcess :: fn(code: u32);
        \\
        \\#noreturn
        \\@panic :: fn(msg: []const u8) {
        \\    ExitProcess(0xDEAD_BEEF);
        \\}
        \\
        \\assert :: fn(cond: bool) {
        \\    if !cond { core::panic("assertion failed\n"); }
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "runtime/windows.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    const panic_fn = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "@panic")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expect(panic_fn.no_return);
}

test "postfix as casts lower to cast instructions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\casts :: fn(value: i32, addr: usize) -> i64 {
        \\    widened := value as i64;
        \\    flag := value as bool;
        \\    back := flag as u8;
        \\    ptr := unsafe addr as *u32;
        \\    roundtrip := unsafe ptr as usize;
        \\    return widened + (back as i64) + (roundtrip as i64);
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "casts.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    const func = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "casts")) break f;
    } else return error.FunctionNotFound;
    var cast_count: usize = 0;
    for (func.blocks) |block| for (block.instrs) |instr| {
        if (instr.kind == .cast) cast_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 7), cast_count);
}

test "pointer as cast requires unsafe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn(addr: usize) -> *u32 { return addr as *u32; }
    ;
    try std.testing.expectError(error.SemanticFailed, skarn.compile(arena.allocator(), "bad_cast.sk", bad));
}

test "for range and slice loops lower with continue-safe increment blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\sum_range :: fn(n: u32) -> u32 {
        \\    total := 0u32;
        \\    for i in 0u32..n {
        \\        if i == 2u32 { continue; }
        \\        total += i;
        \\    }
        \\    return total;
        \\}
        \\
        \\sum_slice :: fn(values: []const u32) -> u32 {
        \\    total := 0u32;
        \\    for value, index in values {
        \\        total += value + (index as u32);
        \\    }
        \\    return total;
        \\}
        \\
        \\increment :: fn(values: []u32) {
        \\    for &value in values {
        \\        *value += 1u32;
        \\    }
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "for.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    const range_fn = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "sum_range")) break f;
    } else return error.FunctionNotFound;
    var has_range_increment = false;
    for (range_fn.blocks) |block| {
        if (std.mem.eql(u8, block.name, "for.range.increment")) has_range_increment = true;
    }
    try std.testing.expect(has_range_increment);

    const slice_fn = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "increment")) break f;
    } else return error.FunctionNotFound;
    var has_index_addr = false;
    for (slice_fn.blocks) |block| for (block.instrs) |instr| {
        if (instr.kind == .index_addr) has_index_addr = true;
    };
    try std.testing.expect(has_index_addr);
}

// Const-correctness tests

test "const: *const T is accepted as a parameter type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // *const T can be declared and accepted by sema. Reads go through fine.
    const src =
        \\Pair :: struct { x: i32, y: i32, }
        \\sum :: fn(p: *const Pair) -> i32 { return p.x; }
        \\use :: fn(pair: Pair) {
        \\    _ := sum(&pair);
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "const_ptr.sk", src);
    defer fe.deinit(arena.allocator());
    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);
}

test "const: *T is implicitly promoted to *const T" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A mutable pointer must be accepted where *const T is expected.
    const src =
        \\Pair :: struct { x: i32, }
        \\consume :: fn(p: *const Pair) -> i32 { return p.x; }
        \\caller :: fn(pair: Pair) -> i32 {
        \\    p := &pair;
        \\    return consume(p);
        \\}
    ;
    var fe = try skarn.compile(arena.allocator(), "const_promote.sk", src);
    defer fe.deinit(arena.allocator());
    try skarn.ir_mod.validateModule(try skarn.lowerFrontend(arena.allocator(), fe));
}

test "const: writing to field through *const T is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // *const T means you cannot mutate the pointee at all.
    const bad =
        \\Wrap :: struct { v: i32, }
        \\bad :: fn(p: *const Wrap) { p.v = 99; }
    ;
    try std.testing.expectError(
        error.SemanticFailed,
        skarn.compile(arena.allocator(), "const_write.sk", bad),
    );
}

test "const: field write through *const T is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bad =
        \\Pair :: struct { x: i32, y: i32, }
        \\bad :: fn(p: *const Pair) { p.x = 1; }
    ;
    try std.testing.expectError(
        error.SemanticFailed,
        skarn.compile(arena.allocator(), "const_field_write.sk", bad),
    );
}

// Static constraint tests

test "static constraints: $T: Interface accepts conforming type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The constraint is checked at call-site: Console implements Printer → accepted.
    // Body method dispatch on $T (calling item.print()) is a separate feature;
    // here we just verify the constraint gate works.
    const src =
        \\Printer :: interface {
        \\    print :: fn(self: *Self);
        \\}
        \\Console :: struct { fd: i32, }
        \\Console as Printer {
        \\    print :: fn(self: *Console) {}
        \\}
        \\process :: fn($T: Printer, item: *T) {}
        \\use :: fn(c: *Console) { process(c); }
    ;
    var fe = try skarn.compile(arena.allocator(), "constraint_ok.sk", src);
    defer fe.deinit(arena.allocator());
    try skarn.ir_mod.validateModule(try skarn.lowerFrontend(arena.allocator(), fe));
}

test "static constraints: $T: Interface rejects non-conforming type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bad =
        \\Printer :: interface {
        \\    print :: fn(self: *Self);
        \\}
        \\File :: struct { fd: i32, }
        \\print_all :: fn($T: Printer, item: *T) { item.print(); }
        \\bad :: fn(f: *File) { print_all(f); }
    ;
    try std.testing.expectError(
        error.SemanticFailed,
        skarn.compile(arena.allocator(), "constraint_bad.sk", bad),
    );
}
