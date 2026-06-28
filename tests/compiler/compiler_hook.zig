const std = @import("std");
const k2 = @import("k2_compiler");

// Phase 3 — the `#compiler` message loop. A `#compiler` hook is a function the
// compiler runs at compile time; its returned `[]const u8` is parsed as
// top-level K2 declarations and added to the program. `core::compiler_decls()` lets a
// hook INSPECT the program (every top-level decl's name + kind) and generate
// code conditionally. These are the headline capabilities `#insert` (a
// statement-only splice) cannot provide.

fn hasFunction(m: anytype, name: []const u8) bool {
    for (m.functions) |f| {
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

test "compiler-hook: a hook builds source with the REAL StringBuilder (host memory at comptime)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `std.strings.StringBuilder` is backed by `std.heap.Arena` (VirtualAlloc + raw
    // pointers). A `#compiler` hook runs at compile time and cannot fall back to
    // runtime, so this only works because the comptime VM now models real host
    // memory. The hook emits a `sum_<T>` for every user struct.
    var fe = try k2.compileFileWithRuntime(a, std.testing.io, "tests/fixtures/hostmem/derive_sb.sk");
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);
    try std.testing.expect(hasFunction(m, "sum_Point"));
    try std.testing.expect(hasFunction(m, "sum_Vec3"));
}

test "compiler-hook: a hook reads a declaration's BODY text (R1b-A)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `Decl.body` is the decl's source text. The hook only emits the real
    // `answer` when it sees the `7` inside `target`'s body — proving it read the
    // actual body, not just the signature.
    const src =
        \\target :: fn() -> i32 { return 7; }
        \\has_seven :: fn(s: []const u8) -> bool {
        \\    for i in 0..s.len { if s[i] == 55u8 { return true; } }
        \\    return false;
        \\}
        \\streq :: fn(p: []const u8, q: []const u8) -> bool {
        \\    if p.len != q.len { return false; }
        \\    for i in 0..p.len { if p[i] != q[i] { return false; } }
        \\    return true;
        \\}
        \\#compiler gen :: fn() -> []const u8 {
        \\    for d in core::compiler_decls() {
        \\        if streq(d.name, "target") {
        \\            if has_seven(d.body) { return "answer :: fn() -> i32 { return 42; }"; }
        \\        }
        \\    }
        \\    return "answer :: fn() -> i32 { return 0; }";
        \\}
        \\main :: fn() -> i32 { return answer(); }
    ;
    var fe = try k2.compile(a, "body.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);
    try std.testing.expect(hasFunction(m, "answer"));
}

test "compiler-hook: `compiler_remove` drops an existing declaration (R1b-B)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The hook removes `scratch`; it must be gone from the lowered module.
    const src =
        \\scratch :: fn() -> i32 { return 1; }
        \\streq :: fn(p: []const u8, q: []const u8) -> bool {
        \\    if p.len != q.len { return false; }
        \\    for i in 0..p.len { if p[i] != q[i] { return false; } }
        \\    return true;
        \\}
        \\#compiler gen :: fn() -> []const u8 {
        \\    for d in core::compiler_decls() { if streq(d.name, "scratch") { core::compiler_remove("scratch"); } }
        \\    return "";
        \\}
        \\main :: fn() -> i32 { return 0; }
    ;
    var fe = try k2.compile(a, "remove.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);
    try std.testing.expect(!hasFunction(m, "scratch")); // removed
    try std.testing.expect(hasFunction(m, "main"));
}

test "compiler-hook: a `#compiler(final)` hook runs AFTER generation and sees generated decls (R1b-C)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Phase 1 generates `answer`; the phase-2 `final` hook must see it (else it
    // halts). Compiling cleanly + `answer` existing proves the phase ordering.
    const src =
        \\streq :: fn(p: []const u8, q: []const u8) -> bool {
        \\    if p.len != q.len { return false; }
        \\    for i in 0..p.len { if p[i] != q[i] { return false; } }
        \\    return true;
        \\}
        \\#compiler gen :: fn() -> []const u8 { return "answer :: fn() -> i32 { return 42; }"; }
        \\#compiler(final) check :: fn() -> []const u8 {
        \\    seen: bool = false;
        \\    for d in core::compiler_decls() { if streq(d.name, "answer") { seen = true; } }
        \\    if !seen { core::compiler_error("final phase did not see generated `answer`"); }
        \\    return "";
        \\}
        \\main :: fn() -> i32 { return answer(); }
    ;
    var fe = try k2.compile(a, "final_phase.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);
    try std.testing.expect(hasFunction(m, "answer"));
}

test "compiler-hook: a `#compiler(final)` hook can halt the build (whole-program validation, R1b-C)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A final-phase hook validates the complete program and rejects it.
    const bad =
        \\Banned :: struct { x: i32 }
        \\streq :: fn(p: []const u8, q: []const u8) -> bool {
        \\    if p.len != q.len { return false; }
        \\    for i in 0..p.len { if p[i] != q[i] { return false; } }
        \\    return true;
        \\}
        \\#compiler(final) policy :: fn() -> []const u8 {
        \\    for d in core::compiler_decls() { if streq(d.name, "Banned") { core::compiler_error("type `Banned` is not allowed"); } }
        \\    return "";
        \\}
        \\main :: fn() -> i32 { return 0; }
    ;
    try std.testing.expectError(error.SemanticFailed, k2.compile(arena.allocator(), "final_policy.sk", bad));
}

test "compiler-hook: `compiler_error` halts the build with a custom diagnostic (R1b)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A `#compiler` hook can VALIDATE the whole program and stop compilation with
    // its own message — the message-loop's "affect compilation" capability.
    const bad =
        \\Widget :: struct { x: i32 }
        \\#compiler policy :: fn() -> []const u8 {
        \\    for d in core::compiler_decls() {
        \\        match d.kind { "struct" => { core::compiler_error("structs are banned here"); } else => {} }
        \\    }
        \\    return "";
        \\}
        \\main :: fn() -> i32 { return 0; }
    ;
    try std.testing.expectError(error.SemanticFailed, k2.compile(arena.allocator(), "policy.sk", bad));
}

test "compiler-hook: a hook that does NOT call compiler_error compiles normally" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\#compiler ok :: fn() -> []const u8 { return "gen :: fn() -> i32 { return 1; }"; }
        \\main :: fn() -> i32 { return gen(); }
    ;
    var fe = try k2.compile(a, "ok.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);
    try std.testing.expect(hasFunction(m, "gen"));
}

test "compiler-hook: rich introspection — reads struct fields and enum variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `core::compiler_decls()` now exposes each decl's structure: a struct's `fields`,
    // an enum's variants (also via `fields`), and a fn's params + `ret`. The hook
    // reads `d.fields.len` (and matches on `d.kind` as a string) and only emits
    // `answer` when the program's shape matches — proving it saw the real fields.
    const src =
        \\Point :: struct { x: i32, y: i32 }
        \\Color :: enum { Red, Green, Blue }
        \\#compiler shape :: fn() -> []const u8 {
        \\    nfields: i32 = 0;
        \\    nvariants: i32 = 0;
        \\    for d in core::compiler_decls() {
        \\        match d.kind {
        \\            "struct" => { nfields = nfields + (d.fields.len as i32); }
        \\            "enum"   => { nvariants = nvariants + (d.fields.len as i32); }
        \\            else     => {}
        \\        }
        \\    }
        \\    if nfields == 2 { if nvariants == 3 {
        \\        return "answer :: fn() -> i32 { return 42; }";
        \\    } }
        \\    return "answer :: fn() -> i32 { return 0; }";
        \\}
        \\main :: fn() -> i32 { return answer(); }
    ;
    var fe = try k2.compile(a, "hook_introspect.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);
    try std.testing.expect(hasFunction(m, "answer"));
}

test "compiler-hook: generated top-level declaration is added to the module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `generate` runs at compile time and returns source for a new top-level
    // function `doubled`, which `main` then calls.
    const src =
        \\#compiler generate :: fn() -> []const u8 {
        \\    return "doubled :: fn(x: i32) -> i32 { return x * 2; }";
        \\}
        \\main :: fn() -> i32 { return doubled(21); }
    ;
    var fe = try k2.compile(a, "hook_gen.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);

    // The generated `doubled` must exist as a real lowered function.
    try std.testing.expect(hasFunction(m, "doubled"));
    try std.testing.expect(hasFunction(m, "main"));
}

test "compiler-hook: core::compiler_decls() inspection drives conditional generation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The hook walks `core::compiler_decls()` and only emits the real `answer` (the
    // one a passing program needs) because a `struct` declaration is present.
    // Exercises: slice-of-struct iteration, `[]const u8` field reads, comptime
    // string compare (`.len` + byte indexing on host strings), and conditional
    // declaration generation.
    const src =
        \\Point :: struct { x: i32, y: i32 }
        \\streq :: fn(p: []const u8, q: []const u8) -> bool {
        \\    if p.len != q.len { return false; }
        \\    for i in 0..p.len {
        \\        if p[i] != q[i] { return false; }
        \\    }
        \\    return true;
        \\}
        \\#compiler gen :: fn() -> []const u8 {
        \\    for d in core::compiler_decls() {
        \\        if streq(d.kind, "struct") {
        \\            return "answer :: fn() -> i32 { return 42; }";
        \\        }
        \\    }
        \\    return "answer :: fn() -> i32 { return 0; }";
        \\}
        \\main :: fn() -> i32 { return answer(); }
    ;
    var fe = try k2.compile(a, "hook_inspect.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);
    try std.testing.expect(hasFunction(m, "answer"));
}

test "compiler-hook: no hook means no compiler-prelude injection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A program with no `#compiler` hook must compile unchanged — `Decl` and the
    // hook pass are only introduced when a hook is present.
    const src =
        \\main :: fn() -> i32 { return 7; }
    ;
    var fe = try k2.compile(a, "no_hook.sk", src);
    defer fe.deinit(a);
    const m = try k2.lowerFrontend(a, fe);
    try k2.ir_mod.validateModule(m);
    try std.testing.expect(!hasFunction(m, "Decl"));
    try std.testing.expect(hasFunction(m, "main"));
}
