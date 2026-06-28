const std = @import("std");
const skarn = @import("skarn_compiler");

// Multi-file tests use compileMulti with pre-loaded sources, so they exercise
// module resolution without filesystem access.

test "modules: compileMulti with two source files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const math_src =
        \\pub add      :: fn(a: i32, b: i32) -> i32 { return a + b; }
        \\pub multiply :: fn(a: i32, b: i32) -> i32 { return a * b; }
    ;
    const main_src =
        \\#import math;
        \\run :: fn() -> i32 {
        \\    x := math::add(3, 4);
        \\    y := math::multiply(x, 2);
        \\    return y;
        \\}
    ;

    var fe = try skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "math.sk", .source = math_src },
        .{ .file_name = "main.sk", .source = main_src },
    });
    defer fe.deinit(arena.allocator());

    try std.testing.expectEqual(@as(usize, 4), fe.module.items.len);

    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);
    try std.testing.expectEqual(@as(usize, 3), m.functions.len);
}

test "modules: public symbols from imported file are visible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const utils =
        \\MAX :: 100;
        \\pub clamp :: fn(x: i32) -> bool { return x < MAX; }
    ;
    const app =
        \\#import utils;
        \\check :: fn(v: i32) -> bool { return utils::clamp(v); }
    ;

    var fe = try skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "utils.sk", .source = utils },
        .{ .file_name = "app.sk", .source = app },
    });
    defer fe.deinit(arena.allocator());

    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);
}

test "modules: namespace import forms — as alias and .* glob" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lib =
        \\pub twice :: fn(x: i32) -> i32 { return x * 2; }
    ;
    // `as` binds a custom namespace; `.*` glob brings names in unqualified.
    const aliased =
        \\#import lib as l;
        \\run :: fn() -> i32 { return l::twice(21); }
    ;
    const globbed =
        \\#import lib.*;
        \\go :: fn() -> i32 { return twice(21); }
    ;

    var fe1 = try skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "lib.sk", .source = lib },
        .{ .file_name = "aliased.sk", .source = aliased },
    });
    defer fe1.deinit(arena.allocator());
    try skarn.ir_mod.validateModule(try skarn.lowerFrontend(arena.allocator(), fe1));

    var fe2 = try skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "lib.sk", .source = lib },
        .{ .file_name = "globbed.sk", .source = globbed },
    });
    defer fe2.deinit(arena.allocator());
    try skarn.ir_mod.validateModule(try skarn.lowerFrontend(arena.allocator(), fe2));
}

test "modules: two modules may define the same name (collision mangling)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Both `a` and `b` declare `greet`; `main` uses both via their namespaces.
    // Per-module mangling gives each a distinct linkage name so this links.
    const a = "pub greet :: fn() -> i32 { return 1; }";
    const b = "pub greet :: fn() -> i32 { return 2; }";
    const main =
        \\#import a;
        \\#import b;
        \\main :: fn() -> i32 { return a::greet() + b::greet() * 10; }
    ;
    var fe = try skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "a.sk", .source = a },
        .{ .file_name = "b.sk", .source = b },
        .{ .file_name = "main.sk", .source = main },
    });
    defer fe.deinit(arena.allocator());

    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    // Two distinct `greet` functions must exist (mangled apart), plus `main`.
    var greets: usize = 0;
    for (m.functions) |f| {
        if (std.mem.endsWith(u8, f.name, "greet")) greets += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), greets);
}

test "modules: cross-module UFCS finds a method in the type's module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // `get` is NOT imported into `app` — only the type `Box` is. `b.get()` must
    // still resolve, because a method follows its type's module (UFCS).
    const lib =
        \\pub Box :: struct { v: i32 }
        \\pub get :: fn(self: *Box) -> i32 { return self.v; }
    ;
    const app =
        \\#import lib.{ Box };
        \\run :: fn(b: Box) -> i32 { return b.get(); }
    ;
    var fe = try skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "lib.sk", .source = lib },
        .{ .file_name = "app.sk", .source = app },
    });
    defer fe.deinit(arena.allocator());
    try skarn.ir_mod.validateModule(try skarn.lowerFrontend(arena.allocator(), fe));
}

test "modules: #run of a namespace call folds at comptime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lib = "pub twice :: fn(x: i32) -> i32 { return x * 2; }";
    const app =
        \\#import lib;
        \\main :: fn() -> i32 { return #run lib::twice(21); }
    ;
    var fe = try skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "lib.sk", .source = lib },
        .{ .file_name = "app.sk", .source = app },
    });
    defer fe.deinit(arena.allocator());

    const m = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(m);

    // `#run lib::twice(21)` must fold to a constant — `main` should contain no
    // runtime call instruction.
    const main_fn = for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, "main")) break f;
    } else return error.FunctionNotFound;
    for (main_fn.blocks) |b| for (b.instrs) |ins| {
        try std.testing.expect(ins.kind != .call);
    };
}

test "modules: bare import is namespace-only (no unqualified access)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const lib =
        \\pub helper :: fn() -> i32 { return 1; }
    ;
    // `#import lib;` binds the `lib` namespace but must NOT expose `helper`
    // unqualified — calling it bare is an error.
    const app =
        \\#import lib;
        \\run :: fn() -> i32 { return helper(); }
    ;
    const result = skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "lib.sk", .source = lib },
        .{ .file_name = "app.sk", .source = app },
    });
    try std.testing.expectError(error.SemanticFailed, result);
}

test "modules: compile parses imports without resolving them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src =
        \\#import std.io;
        \\hello :: fn() -> i32 { return 42; }
    ;
    var fe = try skarn.compile(arena.allocator(), "hello.sk", src);
    defer fe.deinit(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), fe.module.items.len);
}

test "modules: selective import exposes only selected public names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const math_src =
        \\pub add :: fn(a: i32, b: i32) -> i32 { return a + b; }
        \\pub multiply :: fn(a: i32, b: i32) -> i32 { return a * b; }
    ;
    const app_src =
        \\#import math.{add};
        \\run :: fn() -> i32 { return add(1, 2); }
    ;

    var fe = try skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "math.sk", .source = math_src },
        .{ .file_name = "app.sk", .source = app_src },
    });
    defer fe.deinit(arena.allocator());
}

test "modules: unselected and private names are not visible" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const dependency =
        \\private_value :: fn() -> i32 { return 1; }
        \\pub public_value :: fn() -> i32 { return private_value(); }
        \\pub other_value :: fn() -> i32 { return 2; }
    ;
    const private_use =
        \\#import dependency;
        \\run :: fn() -> i32 { return private_value(); }
    ;
    const unselected_use =
        \\#import dependency.{public_value};
        \\run :: fn() -> i32 { return other_value(); }
    ;

    try std.testing.expectError(error.SemanticFailed, skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "dependency.sk", .source = dependency },
        .{ .file_name = "private_use.sk", .source = private_use },
    }));
    try std.testing.expectError(error.SemanticFailed, skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "dependency.sk", .source = dependency },
        .{ .file_name = "unselected_use.sk", .source = unselected_use },
    }));
}

test "modules: selective imports reject missing and private declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const dependency =
        \\hidden :: fn() -> i32 { return 1; }
        \\pub #inline shown :: fn() -> i32 { return hidden(); }
    ;

    try std.testing.expectError(error.SemanticFailed, skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "dependency.sk", .source = dependency },
        .{ .file_name = "private.sk", .source = "#import dependency.{hidden};" },
    }));
    try std.testing.expectError(error.SemanticFailed, skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "dependency.sk", .source = dependency },
        .{ .file_name = "missing.sk", .source = "#import dependency.{missing};" },
    }));
}

test "modules: missing modules are errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.IoError, skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "app.sk", .source = "#import missing;" },
    }));
}

test "modules: std root resolves independently of importing directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "std/io.sk", .source = "pub write_stdout :: fn() {}" },
        .{ .file_name = "app/main.sk", .source = "#import std.io.{write_stdout}; run :: fn() { write_stdout(); }" },
    });
    defer fe.deinit(arena.allocator());
}

test "modules: public constants and types respect visibility" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const dependency =
        \\pub LIMIT :: 4;
        \\pub Value :: struct { item: i32, }
        \\Hidden :: struct { item: i32, }
    ;
    const app =
        \\#import dependency.{LIMIT, Value};
        \\limit :: fn() -> i32 { return LIMIT; }
        \\read :: fn(value: *Value) -> i32 { return value.item; }
    ;

    var fe = try skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "dependency.sk", .source = dependency },
        .{ .file_name = "app.sk", .source = app },
    });
    defer fe.deinit(arena.allocator());
}

test "modules: compileFile resolves local imports from disk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try skarn.compileFile(
        arena.allocator(),
        std.testing.io,
        "tests/fixtures/modules/main.sk",
    );
    defer fe.deinit(arena.allocator());

    const module = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(module);
}

test "modules: compileMulti normalizes logical module paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = ".\\app\\dependency.sk", .source = "pub answer :: fn() -> i32 { return 42; }" },
        .{ .file_name = "./app/main.sk", .source = "#import dependency.{answer}; run :: fn() -> i32 { return answer(); }" },
    });
    defer fe.deinit(arena.allocator());
}

test "modules: configured std root loads std.mem" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try skarn.compileFile(
        arena.allocator(),
        std.testing.io,
        "tests/fixtures/stdlib/mem_app.sk",
    );
    defer fe.deinit(arena.allocator());

    const module = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(module);
}

test "modules: configured std root loads std.io" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try skarn.compileFileWithRuntime(
        arena.allocator(),
        std.testing.io,
        "tests/fixtures/stdlib/io_app.sk",
    );
    defer fe.deinit(arena.allocator());

    const module = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(module);
}

test "modules: game stdlib (std.math + std.rand + std.color) resolves and lowers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try skarn.compileFileWithRuntime(
        arena.allocator(),
        std.testing.io,
        "tests/fixtures/stdlib/game_app.sk",
    );
    defer fe.deinit(arena.allocator());

    const module = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(module);
}

test "modules: general stdlib (std.path + std.time + std.crypto) resolves and lowers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    inline for (.{
        "tests/fixtures/stdlib/path_app.sk",
        "tests/fixtures/stdlib/time_app.sk",
        "tests/fixtures/stdlib/crypto_app.sk",
    }) |fixture| {
        var fe = try skarn.compileFileWithRuntime(arena.allocator(), std.testing.io, fixture);
        defer fe.deinit(arena.allocator());
        const module = try skarn.lowerFrontend(arena.allocator(), fe);
        try skarn.ir_mod.validateModule(module);
    }
}

test "modules: configured std root loads std.heap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fe = try skarn.compileFileWithRuntime(
        arena.allocator(),
        std.testing.io,
        "tests/fixtures/stdlib/heap_app.sk",
    );
    defer fe.deinit(arena.allocator());

    const module = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(module);
}

test "modules: imported self functions are extension methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const helpers =
        \\pub doubled :: fn(self: i32) -> i32 { return self * 2; }
        \\pub add :: fn(self: i32, value: i32) -> i32 { return self + value; }
    ;
    const app =
        \\#import helpers.{doubled, add};
        \\run :: fn() -> i32 { return 20.doubled().add(2); }
    ;

    var fe = try skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "helpers.sk", .source = helpers },
        .{ .file_name = "app.sk", .source = app },
    });
    defer fe.deinit(arena.allocator());

    const module = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(module);
}

test "parser: namespace-qualified generic type in a typed local (ns::Name(args))" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Regression: `parseType` handled `Name(args)` and `ns::Name`, but not the
    // combination — after the `::`-qualified name it expected `=` and reported
    // "expected = after typed local". The qualifier must now flow into the AST.
    const src =
        \\run :: fn() -> i32 {
        \\    c: atomics::Atomic(u32) = .{ 0u32 };
        \\    return 0;
        \\}
    ;
    const module = try skarn.parseSource(arena.allocator(), "q.sk", src);
    const ty = module.items[0].function.body.?.statements[0].local_typed.ty;
    try std.testing.expect(ty == .generic_inst);
    try std.testing.expectEqualStrings("Atomic", ty.generic_inst.name);
    try std.testing.expect(ty.generic_inst.namespace != null);
    try std.testing.expectEqualStrings("atomics", ty.generic_inst.namespace.?);
    try std.testing.expectEqual(@as(usize, 1), ty.generic_inst.args.len);
}

test "modules: namespace-qualified generic type resolves + lowers (ns::Name(args))" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The generic template is reached *only* through the namespace alias (a plain
    // `#import`, no selective `.{Pair}`), so `lib::Pair(i32)` exercises namespace
    // resolution of the template AND the non-generic-context instantiation.
    const lib =
        \\pub Pair :: struct($T: type) { a: T, b: T }
    ;
    const app =
        \\#import lib;
        \\sum :: fn() -> i32 {
        \\    p: lib::Pair(i32) = .{ 3, 4 };
        \\    return p.a + p.b;
        \\}
    ;
    var fe = try skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "lib.sk", .source = lib },
        .{ .file_name = "app.sk", .source = app },
    });
    defer fe.deinit(arena.allocator());

    const module = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(module);
}

test "modules: unimported self functions are not extension methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.SemanticFailed, skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "helpers.sk", .source = "pub doubled :: fn(self: i32) -> i32 { return self * 2; }" },
        .{ .file_name = "app.sk", .source = "run :: fn() -> i32 { return 20.doubled(); }" },
    }));
}

test "modules: generic extension methods retain explicit type arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const helpers =
        \\pub first_or :: fn($T: type, self: []const T, fallback: T) -> T {
        \\    if self.len == 0usize { return fallback; }
        \\    return self[0];
        \\}
    ;
    const app =
        \\#import helpers.{first_or};
        \\run :: fn() -> i32 {
        \\    values: [1]i32 = .{ 42 };
        \\    return values[:].first_or(i32, 0);
        \\}
    ;

    var fe = try skarn.compileMulti(arena.allocator(), &.{
        .{ .file_name = "helpers.sk", .source = helpers },
        .{ .file_name = "app.sk", .source = app },
    });
    defer fe.deinit(arena.allocator());

    const module = try skarn.lowerFrontend(arena.allocator(), fe);
    try skarn.ir_mod.validateModule(module);
}
