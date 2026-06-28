const std = @import("std");
const k2 = @import("k2_compiler");

// Phase 2, slice 1: literal `#quote` + `#insert`. The operand of `#insert`
// must be a `#quote { ... }` block; its statements are spliced into the
// enclosing scope and re-checked there. No `$` splice / `macro` yet.

test "metaprogram: #insert literal #quote lowers to valid IR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\run :: fn() -> i32 {
        \\    x := 5;
        \\    #insert #quote {
        \\        y := x + 100;
        \\        x = y;
        \\    };
        \\    return x;
        \\}
    ;
    var fe = try k2.compile(a, "mp1.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);

    // The spliced statements land in `run` — there must be exactly one function
    // and it must have lowered (non-empty) blocks.
    const fn_ = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "run")) break f;
    } else return error.FunctionNotFound;
    try std.testing.expect(fn_.blocks.len > 0);
}

test "metaprogram: spliced locals are visible to following statements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `total` is introduced inside the quote and used AFTER the #insert — this
    // only type-checks if the splice lands in the enclosing scope, not a child.
    const src =
        \\run :: fn() -> i32 {
        \\    #insert #quote {
        \\        total := 7;
        \\    };
        \\    return total + 1;
        \\}
    ;
    var fe = try k2.compile(a, "mp2.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);
}

test "metaprogram: block macro expands and lowers to valid IR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\twice :: macro(body: Code) -> Code {
        \\    return #quote { $body; $body; };
        \\}
        \\run :: fn() -> i32 {
        \\    n := 0;
        \\    #insert twice(#quote { n = n + 1; });
        \\    return n;
        \\}
    ;
    var fe = try k2.compile(a, "mac1.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);

    // The macro decl must NOT survive into the lowered module.
    for (m.functions) |f| {
        try std.testing.expect(!std.mem.eql(u8, f.name, "twice"));
    }
}

test "metaprogram: #for unrolls and lowers to valid IR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\run :: fn() -> i32 {
        \\    total := 0;
        \\    #for i in 0..=3 {
        \\        total = total + $(i);
        \\    }
        \\    return total;
        \\}
    ;
    var fe = try k2.compile(a, "for1.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);
}

test "metaprogram: #for with non-constant bounds is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\run :: fn(n: i32) -> i32 {
        \\    total := 0;
        \\    #for i in 0..n {
        \\        total = total + $(i);
        \\    }
        \\    return total;
        \\}
    ;
    try std.testing.expectError(error.SemanticFailed, k2.compile(a, "for2.sk", src));
}

test "metaprogram: macro with wrong argument count is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\one :: macro(x: Code) -> Code { return #quote { use($x); }; }
        \\run :: fn() {
        \\    #insert one(#quote(1), #quote(2));
        \\}
    ;
    try std.testing.expectError(error.SemanticFailed, k2.compile(a, "mac2.sk", src));
}

test "metaprogram: stray $ splice outside a macro is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\run :: fn() -> i32 {
        \\    return $x;
        \\}
    ;
    try std.testing.expectError(error.SemanticFailed, k2.compile(a, "mac3.sk", src));
}

test "metaprogram: ast.* types resolve and match in a metaprogramming module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The `#insert` triggers injection of the compiler-provided ast.* types;
    // `describe` then resolves AstExpr and matches on its variants.
    const src =
        \\describe :: fn(e: AstExpr) -> i64 {
        \\    match e {
        \\        .int |v| => return v;
        \\        .ident |n| => return 0;
        \\        .binary |b| => return 1;
        \\        else => return -1;
        \\    }
        \\}
        \\trigger :: fn() -> i32 {
        \\    #insert #quote { };
        \\    return 0;
        \\}
    ;
    var fe = try k2.compile(a, "astuse.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);
}

test "metaprogram: #quote(expr) materializes an AstExpr value at comptime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `#quote(7)` materializes AstExpr.int(7); the match extracts 7.
    // `#quote(a + b)` materializes AstExpr.binary(...); the match sees `.binary`.
    // Both run on the comptime VM via #run and must fold to constants.
    const src =
        \\peek_int :: fn() -> i64 {
        \\    e := #quote(7);
        \\    match e {
        \\        .int |v| => return v;
        \\        else => return -1;
        \\    }
        \\}
        \\peek_kind :: fn() -> i64 {
        \\    e := #quote(a + b);
        \\    match e {
        \\        .binary |bb| => return 2;
        \\        .int |v| => return 0;
        \\        else => return -1;
        \\    }
        \\}
        \\SEVEN :: #run peek_int();
        \\KIND  :: #run peek_kind();
    ;
    var fe = try k2.compile(a, "mat.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);

    var seven: bool = false;
    var kind: bool = false;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "SEVEN")) {
            seven = true;
            try std.testing.expectEqual(k2.ir_mod.Imm{ .int = 7 }, g.init.imm);
        }
        if (std.mem.eql(u8, g.name, "KIND")) {
            kind = true;
            try std.testing.expectEqual(k2.ir_mod.Imm{ .int = 2 }, g.init.imm);
        }
    }
    try std.testing.expect(seven and kind);
}

test "metaprogram: #quote block materializes an AstBlock with its statements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `#quote { ... }` materializes an AstBlock; .stmts.len counts its
    // statements (here: an assign and a local → 2). Runs on the comptime VM.
    const src =
        \\blocklen :: fn() -> i64 {
        \\    b := #quote {
        \\        x = x + 1;
        \\        y := 2;
        \\    };
        \\    return b.stmts.len as i64;
        \\}
        \\LEN :: #run blocklen();
    ;
    var fe = try k2.compile(a, "blk.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);

    var found = false;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "LEN")) {
            found = true;
            try std.testing.expectEqual(k2.ir_mod.Imm{ .int = 2 }, g.init.imm);
        }
    }
    try std.testing.expect(found);
}

test "metaprogram: #insert #run gen() splices VM-computed code (two-pass)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The full generative round trip: `gen` runs on the VM at compile time and
    // returns an AstBlock; the pipeline reifies it, splices it into `run`, and
    // re-checks. `ANSWER` then evaluates the SPLICED `run` at comptime → 42.
    const src =
        \\gen :: fn() -> AstBlock {
        \\    return #quote {
        \\        x = x + 40;
        \\        x = x + 2;
        \\    };
        \\}
        \\run :: fn() -> i32 {
        \\    x := 0;
        \\    #insert #run gen();
        \\    return x;
        \\}
        \\ANSWER :: #run run();
    ;
    var fe = try k2.compile(a, "gen.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);

    var answer = false;
    var has_run = false;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "ANSWER")) {
            answer = true;
            try std.testing.expectEqual(k2.ir_mod.Imm{ .int = 42 }, g.init.imm);
        }
    }
    for (m.functions) |f| {
        // `gen` is comptime-only (returns AstBlock) — excluded from the final module.
        try std.testing.expect(!std.mem.eql(u8, f.name, "gen"));
        if (std.mem.eql(u8, f.name, "run")) has_run = true;
    }
    try std.testing.expect(answer);
    try std.testing.expect(has_run);
}

test "metaprogram: generative control flow picks different blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `pick` chooses which AST to return at comptime — generation driven by
    // ordinary control flow, not templates. true→+10, false→+99 ⇒ 109.
    const src =
        \\pick :: fn(flag: bool) -> AstBlock {
        \\    if flag {
        \\        return #quote { y = y + 10; };
        \\    }
        \\    return #quote { y = y + 99; };
        \\}
        \\run :: fn() -> i32 {
        \\    y := 0;
        \\    #insert #run pick(true);
        \\    #insert #run pick(false);
        \\    return y;
        \\}
        \\ANSWER :: #run run();
    ;
    var fe = try k2.compile(a, "pick.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);

    var found = false;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "ANSWER")) {
            found = true;
            try std.testing.expectEqual(k2.ir_mod.Imm{ .int = 109 }, g.init.imm);
        }
    }
    try std.testing.expect(found);
}

test "metaprogram: generated control flow (while + if) round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // gen() builds a while-loop + conditional; the spliced code runs on the
    // comptime VM via #run. sum = 0+1+2+3+4 = 10; the `if` does not fire.
    const src =
        \\gen :: fn() -> AstBlock {
        \\    return #quote {
        \\        i := 0;
        \\        while i < 5 {
        \\            sum = sum + i;
        \\            i = i + 1;
        \\        }
        \\        if sum > 100 {
        \\            sum = 0;
        \\        }
        \\    };
        \\}
        \\run :: fn() -> i32 {
        \\    sum := 0;
        \\    #insert #run gen();
        \\    return sum;
        \\}
        \\ANSWER :: #run run();
    ;
    var fe = try k2.compile(a, "wide.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);

    var found = false;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "ANSWER")) {
            found = true;
            try std.testing.expectEqual(k2.ir_mod.Imm{ .int = 10 }, g.init.imm);
        }
    }
    try std.testing.expect(found);
}

test "metaprogram: generated calls, unary, and negatives round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Generated code calls a real function with a negative literal argument.
    const src =
        \\helper :: fn(x: i32, y: i32) -> i32 { return x + y; }
        \\gen :: fn() -> AstBlock {
        \\    return #quote {
        \\        r = helper(10, -5);
        \\    };
        \\}
        \\run :: fn() -> i32 {
        \\    r := 0;
        \\    #insert #run gen();
        \\    return r;
        \\}
        \\ANSWER :: #run run();
    ;
    var fe = try k2.compile(a, "calls.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);

    var found = false;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "ANSWER")) {
            found = true;
            try std.testing.expectEqual(k2.ir_mod.Imm{ .int = 5 }, g.init.imm);
        }
    }
    try std.testing.expect(found);
}

test "metaprogram: ast.* exposes the widened node kinds for inspection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The widened AstExpr variants are matchable: a quoted call expression is a
    // `.call`, a quoted index is an `.index`, a string literal is a `.str`.
    const src =
        \\classify :: fn(e: AstExpr) -> i64 {
        \\    match e {
        \\        .call |c|  => return 1;
        \\        .index |i| => return 2;
        \\        .field |f| => return 3;
        \\        .unary |u| => return 4;
        \\        .str |s|   => return 5;
        \\        .float |f| => return 6;
        \\        .boolean |b| => return 7;
        \\        else       => return 0;
        \\    }
        \\}
        \\K_CALL  :: #run classify(#quote(f(1, 2)));
        \\K_INDEX :: #run classify(#quote(arr[0]));
        \\K_STR   :: #run classify(#quote("hi"));
    ;
    var fe = try k2.compile(a, "classify.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);

    var seen: usize = 0;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "K_CALL")) {
            seen += 1;
            try std.testing.expectEqual(k2.ir_mod.Imm{ .int = 1 }, g.init.imm);
        }
        if (std.mem.eql(u8, g.name, "K_INDEX")) {
            seen += 1;
            try std.testing.expectEqual(k2.ir_mod.Imm{ .int = 2 }, g.init.imm);
        }
        if (std.mem.eql(u8, g.name, "K_STR")) {
            seen += 1;
            try std.testing.expectEqual(k2.ir_mod.Imm{ .int = 5 }, g.init.imm);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), seen);
}

test "metaprogram: generated declared locals are visible after #insert" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The generated block DECLARES `a` and `b`; code after the #insert uses
    // them — only possible because pass 1 is tolerant and pass 2 re-checks.
    const src =
        \\gen :: fn() -> AstBlock { return #quote { a := 17; b := 25; }; }
        \\run :: fn() -> i32 {
        \\    #insert #run gen();
        \\    return a + b;
        \\}
        \\ANSWER :: #run run();
    ;
    var fe = try k2.compile(a, "decl.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);

    var found = false;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "ANSWER")) {
            found = true;
            try std.testing.expectEqual(k2.ir_mod.Imm{ .int = 42 }, g.init.imm);
        }
    }
    try std.testing.expect(found);
}

test "metaprogram: wide inspection covers types, slices, optionals, control flow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The widened surface is matchable for casts, slices, coalesce, and unwrap.
    const src =
        \\classify :: fn(e: AstExpr) -> i64 {
        \\    match e {
        \\        .cast |c|     => return 1;
        \\        .slice |s|    => return 2;
        \\        .coalesce |c| => return 3;
        \\        .unwrap |u|   => return 4;
        \\        else          => return 0;
        \\    }
        \\}
        \\K_CAST  :: #run classify(#quote(x as i64));
        \\K_SLICE :: #run classify(#quote(arr[1..3]));
        \\K_COAL  :: #run classify(#quote(opt ?? 9));
        \\K_UNWRAP :: #run classify(#quote(opt!!));
    ;
    var fe = try k2.compile(a, "wideinspect.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);

    const expected = [_]struct { name: []const u8, val: i128 }{
        .{ .name = "K_CAST", .val = 1 },
        .{ .name = "K_SLICE", .val = 2 },
        .{ .name = "K_COAL", .val = 3 },
        .{ .name = "K_UNWRAP", .val = 4 },
    };
    var seen: usize = 0;
    for (m.globals) |g| {
        for (expected) |e| {
            if (std.mem.eql(u8, g.name, e.name)) {
                seen += 1;
                try std.testing.expectEqual(k2.ir_mod.Imm{ .int = e.val }, g.init.imm);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 4), seen);
}

test "metaprogram: generated compound literal + call round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Generated code builds an array literal and calls a function with elements.
    const src =
        \\sum3 :: fn(x: i32, y: i32, z: i32) -> i32 { return x + y + z; }
        \\gen :: fn() -> AstBlock {
        \\    return #quote {
        \\        arr: [3]i32 = .{ 10, 20, 12 };
        \\        r = sum3(arr[0], arr[1], arr[2]);
        \\    };
        \\}
        \\run :: fn() -> i32 {
        \\    r := 0;
        \\    #insert #run gen();
        \\    return r;
        \\}
        \\ANSWER :: #run run();
    ;
    var fe = try k2.compile(a, "compound.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);

    var found = false;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "ANSWER")) {
            found = true;
            try std.testing.expectEqual(k2.ir_mod.Imm{ .int = 42 }, g.init.imm);
        }
    }
    try std.testing.expect(found);
}

test "metaprogram: #parse turns a comptime string into spliced code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The string escape hatch: a comptime-produced string is parsed and spliced.
    const src =
        \\gen_code :: fn() -> []const u8 { return "total = total + 42;"; }
        \\run :: fn() -> i32 {
        \\    total := 0;
        \\    #insert #parse(gen_code());
        \\    return total;
        \\}
        \\ANSWER :: #run run();
    ;
    var fe = try k2.compile(a, "parse.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);

    var found = false;
    for (m.globals) |g| {
        if (std.mem.eql(u8, g.name, "ANSWER")) {
            found = true;
            try std.testing.expectEqual(k2.ir_mod.Imm{ .int = 42 }, g.init.imm);
        }
    }
    try std.testing.expect(found);
}

test "metaprogram: typed macro param rejects a mismatched argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An `AstBlock` parameter requires a `#quote { }` block, not an expression.
    const src =
        \\wrap :: macro(body: AstBlock) -> AstBlock { return #quote { $body; }; }
        \\main :: fn() { #insert wrap(#quote(1 + 2)); }
    ;
    try std.testing.expectError(error.SemanticFailed, k2.compile(a, "tmacro.sk", src));
}

test "metaprogram: ast.* types are absent without metaprogramming" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // No #quote/#insert/#for/macro → the ast.* prelude is NOT injected, so
    // AstExpr is an unknown type.
    const src =
        \\describe :: fn(e: AstExpr) -> i64 { return 0; }
    ;
    try std.testing.expectError(error.SemanticFailed, k2.compile(a, "nometa.sk", src));
}

test "metaprogram: non-quote #insert operand is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\run :: fn() -> i32 {
        \\    #insert 42;
        \\    return 0;
        \\}
    ;
    // Sema must reject: the operand is not a #quote block.
    try std.testing.expectError(error.SemanticFailed, k2.compile(a, "mp3.sk", src));
}
