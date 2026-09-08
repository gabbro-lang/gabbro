/// End-to-end executable tests: compile Gabbro → .o → .exe → run → check exit code.
///
/// Requires LLVM (skipped when absent) and Windows (lld-link).
const std = @import("std");
const gabbro = @import("gabbro_compiler");
const builtin = @import("builtin");

/// Compile `src` to an executable and return its exit code.
fn compileAndRun(allocator: std.mem.Allocator, src: []const u8, label: []const u8) !u32 {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const io = std.testing.io;

    // Build paths under .zig-cache so they don't pollute the repo.
    const obj_path = try std.fmt.allocPrint(allocator, ".zig-cache/{s}.o", .{label});
    defer allocator.free(obj_path);
    const exe_path = try std.fmt.allocPrint(allocator, ".zig-cache/{s}.exe", .{label});
    defer allocator.free(exe_path);
    const obj_path_z = try allocator.dupeZ(u8, obj_path);
    defer allocator.free(obj_path_z);

    const lib_path = gabbro.windows_sdk_lib_path;
    const lib_paths: []const []const u8 = if (lib_path.len > 0) &.{lib_path} else &.{};
    try gabbro.compileWithLlvm(allocator, io, .{
        .file_name = label,
        .source = src,
        .obj_path = obj_path,
        .exe_path = exe_path,
        .opt_level = 2,
        .llvm_bin = gabbro.llvm_path ++ "/bin",
        .lib_paths = lib_paths,
    });

    // Run the compiled executable.
    const exe_argv = [_][]const u8{exe_path};
    var child = std.process.spawn(io, .{
        .argv = &exe_argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;

    const term = child.wait(io) catch return 255;
    return switch (term) {
        .exited => |code| @intCast(code),
        else => 255,
    };
}

/// Cross-compile `src` to a static Linux ELF and return its bytes. Runs on the
/// Windows host (cross-link via ld.lld) — no WSL needed, since the assertions
/// inspect the ELF header rather than executing it. Skips if ld.lld is absent.
fn compileLinuxElf(allocator: std.mem.Allocator, src: []const u8, label: []const u8) ![]u8 {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const obj_path = try std.fmt.allocPrint(allocator, ".zig-cache/{s}.o", .{label});
    const exe_path = try std.fmt.allocPrint(allocator, ".zig-cache/{s}.elf", .{label});
    gabbro.compileWithLlvm(allocator, io, .{
        .file_name = label,
        .source = src,
        .obj_path = obj_path,
        .exe_path = exe_path,
        .opt_level = 2,
        .llvm_bin = gabbro.llvm_path ++ "/bin",
        .target_os = .linux,
    }) catch return error.SkipZigTest;
    return std.Io.Dir.cwd().readFileAlloc(io, exe_path, allocator, .unlimited) catch return error.SkipZigTest;
}

test "exe: cross-compile to a static Linux ELF (format + resolved entry)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A program that uses the heap exercises the mmap-backed allocator seam too.
    const elf = try compileLinuxElf(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    zone a: Arena { buf := a.new_slice(u8, 64); buf[0] = 7u8; return buf[0] as i32; }
        \\}
    , "elf_smoke");
    try std.testing.expect(elf.len > 64);
    // ELF magic.
    try std.testing.expectEqualSlices(u8, "\x7fELF", elf[0..4]);
    // ET_EXEC (static, non-PIE) — e_type at offset 16.
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, elf[16..18], .little));
    // Non-zero entry — proves `ld.lld -e _start` resolved a GLOBAL `_start`.
    // A local `_start` links "successfully" with entry 0 → runtime segfault.
    try std.testing.expect(std.mem.readInt(u64, elf[24..32], .little) != 0);
}

test "exe: main returning 0 exits cleanly" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 { return 0; }
    , "exe_zero");
    try std.testing.expectEqual(@as(u32, 0), code);
}

test "exe: mutable top-level globals (read/write/compound, shared across fns)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `name: T = init;` is a mutable global — distinct from the immutable
    // `name :: …` (the `=` marks it mutable, like a local). It lives in static
    // storage shared across functions and supports `=` and compound `+=`. The
    // initializer must be a compile-time constant.
    const code = try compileAndRun(arena.allocator(),
        \\counter: i64 = 0i64;
        \\total: i32 = 5;
        \\bump :: fn() { counter = counter + 1i64; }
        \\main :: fn() -> i32 {
        \\    bump(); bump(); bump();   // counter: 0 → 3 (mutated in another fn)
        \\    counter += 10i64;          // compound assign → 13
        \\    total = total + (counter as i32);
        \\    return total;              // 5 + 13 = 18
        \\}
    , "exe_mutable_global");
    try std.testing.expectEqual(@as(u32, 18), code);
}

test "exe: `<literal> as <type>` casts and suffixed float literals" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Regression: casting an immediate (`7 as i32`) lowered the operand with an
    // unknown IR type → `ptr` → `ConstInt(ptr, 7)` = 0. And a suffixed float
    // literal (`3.9f64`) parsed to 0.0 (the suffix ends in digits, so the old
    // "strip trailing alphabetic" left `3.9f64`, which `parseFloat` rejected).
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    a: i32 = 7 as i32;
        \\    b: i64 = 5 as i64;
        \\    c: i32 = 100 as i64 as i32;
        \\    d: i32 = 3.9f64 as i32;
        \\    e: f64 = 2.5f64;
        \\    return a + (b as i32) + c + d + (e as i32);
        \\}
    , "exe_lit_cast");
    try std.testing.expectEqual(@as(u32, 117), code); // 7+5+100+3+2
}

test "exe: `Any` — wrap a value, dispatch on its runtime type, safe downcast" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `core::any(x)` wraps any value into a type-erased Any; `any_as(v, T) -> ?T` is a
    // safe downcast (null on type mismatch), `any_is(v, T)` an identity test —
    // both ordinary generic Gabbro over `typeid_of`. Verified across a value passed
    // through an `Any` parameter and recovered by its real type.
    const code = try compileAndRun(arena.allocator(),
        \\describe :: fn(v: Any) -> i32 {
        \\    if any_as(v, i32)  |x| { return x; }
        \\    if any_as(v, bool) |b| { if b { return 100; } return 200; }
        \\    return -1;
        \\}
        \\main :: fn() -> i32 {
        \\    a := describe(core::any(42));     // recovered as i32 -> 42
        \\    b := describe(core::any(true));   // recovered as bool -> 100
        \\    miss: i32 = 0;
        \\    if any_as(core::any(7i32), f64) |x| { miss = 999; }  // wrong type -> null
        \\    nm: i32 = 0;
        \\    if any_name(core::any(1i32)).len == 3 { nm = nm + 1; }  // "i32", metadata travels with the value
        \\    return a + b + miss + nm - 101;  // 42 + 100 + 0 + 1 - 101 = 42
        \\}
    , "exe_any");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: recursive `Any` field navigation (reflection-driven struct walk)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Generic walk over an erased value: recurses through nested struct fields
    // via the generated `any_field_at`/`any_field_name`/`any_field_count`,
    // touching both field NAMES (their lengths) and VALUES — the core of a
    // reflection-driven serializer, with no per-type code written by hand.
    const code = try compileAndRun(arena.allocator(),
        \\Inner :: struct { x: i32, y: i32 }
        \\Outer :: struct { a: i32, inner: Inner }
        \\digest :: fn(v: Any) -> i32 {
        \\    if any_as(v, i32) |x| { return x; }
        \\    total: i32 = 0;
        \\    n := any_field_count(v);
        \\    i: usize = 0;
        \\    while i < n {
        \\        total = total + (any_field_name(v, i).len as i32);   // field name length
        \\        if any_field_at(v, i) |f| { total = total + digest(f); }  // recurse into nested field
        \\        i = i + 1usize;
        \\    }
        \\    return total;
        \\}
        \\main :: fn() -> i32 {
        \\    o: Outer = .{ 10, .{ 12, 12 } };
        \\    return digest(core::any(o));   // names a(1)+inner(5)+x(1)+y(1)=8; values 10+12+12=34; =42
        \\}
    , "exe_any_nav");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: `info_of` (type_name_of/type_size_of) from a bare typeid + Any auto-wrap" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `type_name_of`/`type_size_of` resolve a *bare* typeid to name/size; a value
    // passed to an `Any` parameter auto-wraps (no explicit `core::any(...)`).
    const code = try compileAndRun(arena.allocator(),
        \\P :: struct { a: i32, b: i32 }
        \\kind :: fn(v: Any) -> i32 { if any_as(v, i32) |x| { return x; } return 0; }
        \\main :: fn() -> i32 {
        \\    total: i32 = 0;
        \\    if type_size_of(core::type_id(i32)) == 4usize { total = total + 1; }
        \\    if type_size_of(core::type_id(P)) == 8usize { total = total + 2; }   // 2*i32
        \\    if type_name_of(core::type_id(i32)).len == 3 { total = total + 4; }   // "i32"
        \\    total = total + kind(35);   // 35 auto-wrapped into Any, recovered
        \\    return total;               // 1+2+4+35 = 42
        \\}
    , "exe_info_of");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: `Any` slice navigation (any_elem) through a generic walker" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `any_elem(f, i)` indexes a slice field's elements; the walker sums scalars
    // anywhere — struct fields AND slice elements — with no per-type code.
    const code = try compileAndRun(arena.allocator(),
        \\Bag :: struct { items: []i32, count: i32 }
        \\sum_all :: fn(v: Any) -> i32 {
        \\    if any_as(v, i32) |x| { return x; }
        \\    total: i32 = 0;
        \\    nf := any_field_count(v); i: usize = 0;
        \\    while i < nf {
        \\        if any_field_at(v, i) |f| {
        \\            if any_as(f, i32) |x| { total = total + x; }
        \\            j: usize = 0; cont: bool = true;
        \\            while cont {
        \\                if any_elem(f, j) |e| { if any_as(e, i32) |x| { total = total + x; } j = j + 1usize; }
        \\                else { cont = false; }
        \\            }
        \\        }
        \\        i = i + 1usize;
        \\    }
        \\    return total;
        \\}
        \\main :: fn() -> i32 {
        \\    arr: [3]i32 = .{ 10, 12, 14 };
        \\    b: Bag = .{ arr[:], 6 };   // items 36 + count 6 = 42
        \\    return sum_all(core::any(b));
        \\}
    , "exe_any_elem");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: `Any` pointer navigation (any_deref) through a generic walker" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `any_deref(f)` follows a pointer field; the walker then recurses into the
    // pointee's fields — reflection across pointer indirection, no per-type code.
    const code = try compileAndRun(arena.allocator(),
        \\Node :: struct { val: i32 }
        \\Holder :: struct { node: *Node, extra: i32 }
        \\main :: fn() -> i32 {
        \\    n: Node = .{ 30 };
        \\    h: Holder = .{ &n, 12 };
        \\    v := core::any(h);
        \\    total: i32 = 0;
        \\    nf := any_field_count(v);
        \\    i: usize = 0;
        \\    while i < nf {
        \\        if any_field_at(v, i) |f| {
        \\            if any_as(f, i32) |x| { total = total + x; }           // extra = 12
        \\            if any_deref(f) |d| {                                   // *Node -> Node
        \\                if any_field_at(d, 0usize) |nv| { if any_as(nv, i32) |x| { total = total + x; } }  // val = 30
        \\            }
        \\        }
        \\        i = i + 1usize;
        \\    }
        \\    return total;  // 12 + 30 = 42
        \\}
    , "exe_any_deref");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: reflection-driven scalar serialization + any_at in-place wrap" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `ser_tag` dispatches on an erased value's runtime type (the core of a
    // reflection-driven serializer); `any_at` wraps a pointer in place (no copy).
    const code = try compileAndRun(arena.allocator(),
        \\to_bytes :: fn(p: *const i32) -> *const u8 { unsafe { return p as *const u8; } }
        \\ser_tag :: fn(v: Any) -> i32 {
        \\    if any_as(v, i32)  |x| { return 100 + x; }
        \\    if any_as(v, bool) |b| { if b { return 201; } return 200; }
        \\    if any_as(v, f64)  |f| { return 300 + (f as i32); }
        \\    return 0;
        \\}
        \\main :: fn() -> i32 {
        \\    s := ser_tag(core::any(7i32)) + ser_tag(core::any(false)) + ser_tag(core::any(2.5f64)); // 107+200+302
        \\    x: i32 = 33;
        \\    at := any_at(to_bytes(&x), i32);
        \\    av: i32 = 0;
        \\    if any_as(at, i32) |y| { av = y; }   // in-place wrap recovers 33
        \\    return s - 567 + av - 33;            // (609-567) + 0 = 42
        \\}
    , "exe_reflect_ser");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: `core::type_id(T)` is a stable runtime type identity" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Identical types share an id; distinct types (incl. `*i32`/`[]i32` vs `i32`,
    // and two structurally-identical structs) get distinct ids — all comparable
    // at runtime.
    const code = try compileAndRun(arena.allocator(),
        \\P :: struct { a: i32 }
        \\Q :: struct { a: i32 }
        \\main :: fn() -> i32 {
        \\    total: i32 = 0;
        \\    if core::type_id(i32) == core::type_id(i32) { total = total + 1; }
        \\    if core::type_id(i32) != core::type_id(f64) { total = total + 2; }
        \\    if core::type_id(*i32) != core::type_id(i32) { total = total + 4; }
        \\    if core::type_id([]i32) != core::type_id(i32) { total = total + 8; }
        \\    if core::type_id(P)   != core::type_id(Q)   { total = total + 16; }
        \\    return total;
        \\}
    , "exe_typeid");
    try std.testing.expectEqual(@as(u32, 31), code);
}

test "exe: `core::type_name(T)` returns the type's name at runtime" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // type_name used to fold only on the comptime VM (empty at runtime); now it
    // folds to the name string at lowering, so it's a real runtime value.
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    n := core::type_name(i32);
        \\    ok: i32 = 0;
        \\    if n.len == 3 { ok = ok + 1; }
        \\    if n[0] == 105 { ok = ok + 1; }  // 'i'
        \\    if n[1] == 51  { ok = ok + 1; }  // '3'
        \\    if n[2] == 50  { ok = ok + 1; }  // '2'
        \\    return ok;
        \\}
    , "exe_type_name");
    try std.testing.expectEqual(@as(u32, 4), code);
}

test "exe: `.len` read INLINE on a folded string constant (type_name / literal)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Regression: `.len` applied DIRECTLY to a folded string constant — the
    // `.imm.text` result of `core::type_name(T)`, or a string literal — used to read an
    // undef reg → garbage (`core::type_name(Point).len` returned 240). Through a local
    // it always worked. `type_name` and a bare literal fold to the identical
    // `.imm.text`, so this locks in both, plus the local for contrast.
    const code = try compileAndRun(arena.allocator(),
        \\Point :: struct { x: i32, y: i32 }
        \\main :: fn() -> i32 {
        \\    ok: i32 = 0;
        \\    if core::type_name(Point).len as i32 == 5 { ok = ok + 1; }  // inline "Point".len
        \\    if "hello".len as i32 == 5 { ok = ok + 1; }           // inline literal .len
        \\    nm := core::type_name(Point);
        \\    if nm.len as i32 == 5 { ok = ok + 1; }                // through a local
        \\    return ok;
        \\}
    , "exe_inline_strlen");
    try std.testing.expectEqual(@as(u32, 3), code);
}

test "exe: `where` output type param `-> $Acc` runs end to end" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The `where` computes the accumulator width from `core::type_info(T)` (sub-32-bit
    // ints widen to i32) and rejects non-integers; both monomorphizations run.
    const code = try compileAndRun(arena.allocator(),
        \\acc :: fn(x: $T) -> $Acc
        \\where { match core::type_info(T) { .int |i| => if i.bits < 32 { Acc = i32; } else { Acc = T; }  else => core::reject("acc: integer only"); } }
        \\{ total: Acc = x as Acc; return total +% (1 as Acc); }
        \\main :: fn() -> i32 { return acc(19u8) + acc(21i32); }
    , "exe_out_ty");
    try std.testing.expectEqual(@as(u32, 42), code); // (19+1) + (21+1)
}

test "exe: a function passed as a function-pointer value is called" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Regression: a bare function name used as a value used to lower to `ptr
    // undef` (crash). It must lower to the function's address so the callee can
    // call through it — this is what makes C callbacks work too.
    const code = try compileAndRun(arena.allocator(),
        \\apply :: fn(f: fn(i32) -> i32, a: i32) -> i32 { return f(a); }
        \\dbl :: fn(x: i32) -> i32 { return x * 2; }
        \\main :: fn() -> i32 { return apply(dbl, 21); }
    , "exe_fnptr");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: a top-level string constant and field access on a global work" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Regression: a `NAME :: "..."` string constant used to crash codegen (global
    // type/init mismatch), and reading a field of any `.global` (here `.len`)
    // used to lower to `undef`. Both are fixed.
    const code = try compileAndRun(arena.allocator(),
        \\VERSION  :: "5.5";
        \\GREETING :: "hello world";
        \\main :: fn() -> i32 { return (VERSION.len + GREETING.len) as i32; }
    , "exe_strconst");
    try std.testing.expectEqual(@as(u32, 14), code);
}

test "build: the expanded std.build API runs through the build hook" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    const dir = ".zig-cache/bt_api";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    // Exercises every new builder call; `--list` runs the hook (all `__build_*`
    // intrinsics on the comptime VM) then returns without compiling/linking.
    const build_src =
        \\#import std.build.{ Build, Artifact };
        \\build :: fn(b: Build) {
        \\    b.workspace("t");
        \\    b.out_root("bin");
        \\    app := b.executable("app", "src/main.gab");
        \\    app.optimize(.release_fast);
        \\    app.windowed();
        \\    app.entry("mainCRTStartup");
        \\    app.stack_size(1048576);
        \\    app.link("user32");
        \\    app.link("gdi32");
        \\    app.lib_path("vendor/lib");
        \\    app.link_flag("/DEBUG:NONE");
        \\    app.out_dir("out");
        \\    app.link_mode(.dynamic);
        \\    app.runtime_file("vendor/some.dll");
        \\    app.no_default_libs();
        \\    app.version("1.0.0");
        \\    app.description(b.option_str("desc", "a test app"));
        \\    app.install();
        \\    app.define("TRACE", "1");
        \\    if b.option("fast") { app.release_small(); }
        \\    b.run_step("run", app);
        \\    b.test_dir("test", "tests");
        \\    b.default(app);
        \\    b.summary();
        \\}
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/build.gab", .data = build_src });

    try gabbro.build_driver.run(arena.allocator(), io, dir ++ "/build.gab", .{
        .list = true,
        .quiet = true,
        .options = &.{ "fast", "name=cool" },
    });
}

test "build: a test_dir step compiles+runs tests and fails on a failing one" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;

    const dir = ".zig-cache/bt_test";
    std.Io.Dir.cwd().createDirPath(io, dir ++ "/tests") catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/tests/p1.gab", .data = "main :: fn() -> i32 { return 0; }\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/tests/p2.gab", .data = "main :: fn() -> i32 { return 0; }\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/tests/f1.gab", .data = "main :: fn() -> i32 { return 3; }\n" });
    const build_src =
        \\#import std.build.{ Build, Artifact };
        \\build :: fn(b: Build) {
        \\    app := b.executable("app", "tests/p1.gab");
        \\    b.test_dir("test", "tests");
        \\    b.default(app);
        \\}
    ;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/build.gab", .data = build_src });

    const lp = gabbro.windows_sdk_lib_path;
    const lib_paths: []const []const u8 = if (lp.len > 0) &.{lp} else &.{};
    // One test exits non-zero, so the test step must fail.
    try std.testing.expectError(error.RunFailed, gabbro.build_driver.run(arena.allocator(), io, dir ++ "/build.gab", .{
        .target = "test",
        .quiet = true,
        .llvm_bin = gabbro.llvm_path ++ "/bin",
        .lib_paths = lib_paths,
    }));
}

test "exe: error payload recovered via catch binding" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\EP :: errors { code: i32 }
        \\risky :: fn(x: i32) -> i32 ! EP { if x < 0 { fail .code { 77 }; } return x; }
        \\main :: fn() -> i32 {
        \\    return risky(-1) catch e {
        \\        if e == .code |c| { return c; }
        \\        return -1;
        \\    };
        \\}
    , "exe_errpayload");
    try std.testing.expectEqual(@as(u32, 77), code);
}

test "exe: #insert literal #quote splices and runs" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The spliced statements run in the enclosing scope: they read and mutate
    // `x` (5), so the program must exit 105.
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    x := 5;
        \\    #insert #quote {
        \\        x = x + 100;
        \\    };
        \\    return x;
        \\}
    , "exe_insert_quote");
    try std.testing.expectEqual(@as(u32, 105), code);
}

test "exe: block macro splices an argument body twice" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `twice` splices its `$body` argument block twice; the caller's body
    // increments n, so n goes 0 → 2.
    const code = try compileAndRun(arena.allocator(),
        \\twice :: macro(body: Code) -> Code {
        \\    return #quote {
        \\        $body;
        \\        $body;
        \\    };
        \\}
        \\main :: fn() -> i32 {
        \\    n := 0;
        \\    #insert twice(#quote { n = n + 1; });
        \\    return n;
        \\}
    , "exe_macro_twice");
    try std.testing.expectEqual(@as(u32, 2), code);
}

test "exe: macro local is hygienic (no capture of caller's name)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The macro introduces its own `tmp`; the caller also has a `tmp`. Hygiene
    // must keep them distinct, so the caller's tmp (=9) is returned unchanged
    // while the macro computes with its own tmp.
    const code = try compileAndRun(arena.allocator(),
        \\stash :: macro(e: Code) -> Code {
        \\    return #quote {
        \\        tmp := $(e) + 1;
        \\        marker = tmp;
        \\    };
        \\}
        \\main :: fn() -> i32 {
        \\    tmp := 9;
        \\    marker := 0;
        \\    #insert stash(#quote(40));
        \\    return tmp + marker;
        \\}
    , "exe_macro_hygiene");
    // caller tmp (9) untouched + marker (41) = 50
    try std.testing.expectEqual(@as(u32, 50), code);
}

test "exe: #for unrolls a comptime loop, baking the index" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Unrolls to total = 0 + 1 + 2 + 3 = 6.
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    total := 0;
        \\    #for i in 0..4 {
        \\        total = total + $(i);
        \\    }
        \\    return total;
        \\}
    , "exe_comptime_for");
    try std.testing.expectEqual(@as(u32, 6), code);
}

test "exe: #for generatively initializes an array" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Emits arr[0]=0; arr[1]=1; arr[2]=4; arr[3]=9 → sum 14.
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    arr: [4]i32 = .{ 0, 0, 0, 0 };
        \\    #for i in 0..4 {
        \\        arr[$(i)] = $(i) * $(i);
        \\    }
        \\    return arr[0] + arr[1] + arr[2] + arr[3];
        \\}
    , "exe_comptime_for_array");
    try std.testing.expectEqual(@as(u32, 14), code);
}

test "exe: generative macro unrolls a parameterized #for" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The macro's #for bound is its own argument (5) → 0+1+2+3+4 = 10.
    const code = try compileAndRun(arena.allocator(),
        \\sumup :: macro(n: Code) -> Code {
        \\    return #quote {
        \\        #for i in 0..$(n) {
        \\            acc = acc + $(i);
        \\        }
        \\    };
        \\}
        \\main :: fn() -> i32 {
        \\    acc := 0;
        \\    #insert sumup(#quote(5));
        \\    return acc;
        \\}
    , "exe_macro_for");
    try std.testing.expectEqual(@as(u32, 10), code);
}

test "exe: #insert #run gen() — VM-generated code compiled into the binary" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // gen() runs on the comptime VM, its AstBlock is reified and spliced into
    // main, then LLVM compiles the spliced code. gen itself (comptime-only,
    // returns AstBlock) is excluded from the binary.
    const code = try compileAndRun(arena.allocator(),
        \\gen :: fn() -> AstBlock {
        \\    return #quote {
        \\        x = x + 40;
        \\        x = x + 2;
        \\    };
        \\}
        \\main :: fn() -> i32 {
        \\    x := 0;
        \\    #insert #run gen();
        \\    return x;
        \\}
    , "exe_gen_insert");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: generated while-loop with conditional compiles and runs" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A generator emits a while-loop + if; the spliced code is compiled by LLVM.
    const code = try compileAndRun(arena.allocator(),
        \\gen :: fn() -> AstBlock {
        \\    return #quote {
        \\        i := 0;
        \\        while i < 9 {
        \\            sum = sum + i;
        \\            i = i + 1;
        \\        }
        \\        if sum > 100 { sum = 0; }
        \\    };
        \\}
        \\main :: fn() -> i32 {
        \\    sum := 0;
        \\    #insert #run gen();
        \\    return sum;
        \\}
    , "exe_gen_loop");
    // 0+1+...+8 = 36
    try std.testing.expectEqual(@as(u32, 36), code);
}

test "exe: generated for-range loop + typed local compiles and runs" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The generator declares a typed local and a `for`-range loop; `total` is
    // declared inside the generated code and used after the splice (tolerant
    // pass 1). 0+1+2+3+4 = 10.
    const code = try compileAndRun(arena.allocator(),
        \\gen :: fn() -> AstBlock {
        \\    return #quote {
        \\        total: i32 = 0;
        \\        for i in 0..=4 { total = total + i; }
        \\    };
        \\}
        \\main :: fn() -> i32 {
        \\    #insert #run gen();
        \\    return total;
        \\}
    , "exe_gen_for");
    try std.testing.expectEqual(@as(u32, 10), code);
}

test "exe: generated match + cast compiles and runs" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\gen :: fn() -> AstBlock {
        \\    return #quote {
        \\        match k {
        \\            0 => r = 30;
        \\            else => r = 0;
        \\        }
        \\        big: i64 = r as i64;
        \\        r = big as i32;
        \\    };
        \\}
        \\main :: fn() -> i32 {
        \\    k := 0;
        \\    r := 0;
        \\    #insert #run gen();
        \\    return r;
        \\}
    , "exe_gen_match");
    try std.testing.expectEqual(@as(u32, 30), code);
}

test "exe: comptime FFI from a pure #run is rejected (capability)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A bare `#run` carries no `ffi` capability, so reaching kernel32!MulDiv at
    // compile time must be denied — this is the build.rs surface, closed. (Only
    // `build.gab` is granted FFI.)
    if (compileAndRun(arena.allocator(),
        \\#extern("kernel32", "MulDiv")
        \\mul_div :: fn(a: i32, b: i32, c: i32) -> i32;
        \\RESULT :: #run mul_div(10, 6, 1);
        \\main :: fn() -> i32 { return RESULT; }
    , "exe_ffi_denied")) |_| {
        return error.TestUnexpectedResult; // it compiled — the capability gate didn't fire
    } else |_| {}
}

test "exe: comptime FFI with a string arg is rejected from #run too" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    if (compileAndRun(arena.allocator(),
        \\#extern("kernel32", "lstrlenA")
        \\str_len :: fn(s: []const u8) -> i32;
        \\LEN :: #run str_len("hello, world");
        \\main :: fn() -> i32 { return LEN; }
    , "exe_ffi_str_denied")) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "exe: main returning 42 propagates exit code" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 { return 42; }
    , "exe_42");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: @panic exits with panic status" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 { core::panic("test"); }
    , "exe_panic");
    // Zig's Windows child-process API reports the low byte of ExitProcess here.
    try std.testing.expectEqual(@as(u32, 0xEF), code);
}

test "exe: assert(false) panics" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 { assert(1 == 2); return 0; }
    , "exe_assert_fail");
    try std.testing.expectEqual(@as(u32, 0xEF), code);
}

test "exe: assert(true) does not panic" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 { assert(1 == 1); return 0; }
    , "exe_assert_ok");
    try std.testing.expectEqual(@as(u32, 0), code);
}

test "exe: runtime write reports bytes written" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 { return write_stdout("Gabbro") as i32; }
    , "exe_runtime_write");
    // "Gabbro" is 6 bytes; write_stdout returns the count written.
    try std.testing.expectEqual(@as(u32, 6), code);
}

test "exe: runtime exit terminates with requested status" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 { exit(37u32); }
    , "exe_runtime_exit");
    try std.testing.expectEqual(@as(u32, 37), code);
}

test "exe: fallible ? propagates error to caller, fallback returns sentinel" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // ok path: may_fail(0) -> ok 7. main propagates, returns 7.
    const code_ok = try compileAndRun(arena.allocator(),
        \\MyErr :: errors { bad, }
        \\may_fail :: fn(x: i32) -> i32 ! MyErr {
        \\    if x == 1 { fail .bad; }
        \\    return 7;
        \\}
        \\main :: fn() -> i32 ! MyErr {
        \\    v := may_fail(0)?;
        \\    return v;
        \\}
    , "exe_fallible_ok");
    try std.testing.expectEqual(@as(u32, 7), code_ok);
}

test "exe: catch executes its error handler" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const code = try compileAndRun(arena.allocator(),
        \\MyErr :: errors { bad, }
        \\may_fail :: fn() -> i32 ! MyErr { fail .bad; }
        \\main :: fn() -> i32 {
        \\    value := may_fail() catch err { return 9; };
        \\    return value;
        \\}
    , "exe_catch");
    try std.testing.expectEqual(@as(u32, 9), code);
}

test "exe: plain value coerces to optional parameter" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const code = try compileAndRun(arena.allocator(),
        \\unwrap_helper :: fn(value: ?i32) -> i32 { return value!!; }
        \\main :: fn() -> i32 {
        \\    unwrap_helper(43);
        \\    return 0;
        \\}
    , "exe_optional_coerce");
    try std.testing.expectEqual(@as(u32, 0), code);
}

test "exe: arena allocations are writable and cleaned on exit" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    zone scratch: Arena {
        \\        data := scratch.new_slice(u8, 4);
        \\        if data[0] != 0u8 { return 2; }
        \\        data[0] = 42u8;
        \\        if data[0] != 42u8 { return 1; }
        \\    }
        \\    return 0;
        \\}
    , "exe_zone");
    try std.testing.expectEqual(@as(u32, 0), code);
}

test "exe: zone allocation can be used through a borrow parameter" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const code = try compileAndRun(arena.allocator(),
        \\write :: fn(data: borrow []u8) { data[0] = 42u8; }
        \\main :: fn() -> i32 {
        \\    zone scratch: Arena {
        \\        data := scratch.new_slice(u8, 4);
        \\        write(data);
        \\        if data[0] != 42u8 { return 1; }
        \\    }
        \\    return 0;
        \\}
    , "exe_zone_borrow");
    try std.testing.expectEqual(@as(u32, 0), code);
}

test "exe: sizeof returns the actual size of its type argument" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // core::sizeof(u8) + core::sizeof(u16) + core::sizeof(u32) + core::sizeof(u64) == 1 + 2 + 4 + 8 == 15.
    // A compiler that always reports core::sizeof(T) == 8 would instead yield 32.
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    total := core::sizeof(u8) + core::sizeof(u16) + core::sizeof(u32) + core::sizeof(u64);
        \\    return core::narrow(i32, total);
        \\}
    , "exe_sizeof_widths");
    try std.testing.expectEqual(@as(u32, 15), code);
}

test "exe: sizeof on pointer types returns pointer width" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    total := core::sizeof(*i32) + core::sizeof([*]u8);
        \\    return core::narrow(i32, total);
        \\}
    , "exe_sizeof_pointers");
    try std.testing.expectEqual(@as(u32, 16), code);
}

test "exe: 0b binary integer literals parse to their numeric value" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // 0b1011 == 11; a misparse (e.g. treating 'b' as a hex digit) would give 111011.
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    return 0b1011;
        \\}
    , "exe_binary_literal");
    try std.testing.expectEqual(@as(u32, 11), code);
}

test "exe: dereference-load reads through a pointer" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Regression: `*p` as a value expression was broken — it bound looser than
    // binary operators (`*p + 1` parsed as `*(p + 1)`) and `*ident;` was parsed
    // as a pointer *type* (`x := *p;` became "declare x of type *p"). Now `*p`
    // dereferences for reading. `bump` does `*p = *p + 1` (load+store), main
    // returns `*p`. 41 -> 42.
    const code = try compileAndRun(arena.allocator(),
        \\bump :: fn(p: *i32) { *p = *p + 1; }
        \\main :: fn() -> i32 {
        \\    x: i32 = 41;
        \\    p := &x;
        \\    bump(p);
        \\    return *p;
        \\}
    , "exe_deref_load");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: fallible return type works inside generics" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Regression: a generic `fn(...) -> T ! Err` miscompiled — the instantiation
    // hardcoded error_ty=null and never set current_return_ty, so `fail`/`?`/`catch`
    // were lowered against a non-fallible signature (LLVM icmp i64/i32 mismatch, or
    // an extractAggregateField ICE in a `?`-propagating caller). `caller(i32,30)`
    // returns 30 via `?`; `checked(i32,5,true)` fails and the catch returns 30+7=37.
    const code = try compileAndRun(arena.allocator(),
        \\GErr :: errors { bad, }
        \\checked :: fn($T: type, x: T, fail_it: bool) -> T ! GErr {
        \\    if fail_it { fail .bad; }
        \\    return x;
        \\}
        \\caller :: fn($T: type, x: T) -> T ! GErr {
        \\    v := checked(T, x, false)?;
        \\    return v;
        \\}
        \\main :: fn() -> i32 {
        \\    a := caller(i32, 30) catch e { return 1; };
        \\    b := checked(i32, 5, true) catch e { return a + 7; };
        \\    return a + b;
        \\}
    , "exe_generic_fallible");
    try std.testing.expectEqual(@as(u32, 37), code);
}

test "exe: core::sizeof(T) and core::slice_raw(T) work inside generics" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Regression: a type parameter `T` used in `core::sizeof(T)` / `core::slice_raw(T)`
    // inside a generic body used to ICE (the builtin's type arg was lowered as a
    // value and `firstTypeArg` couldn't resolve a type param). Now both resolve to
    // the concrete instantiation. elem_bytes(i32)=4; the slice sums to 15 → 19.
    const code = try compileAndRun(arena.allocator(),
        \\elem_bytes :: fn($T: type) -> usize { return core::sizeof(T); }
        \\mkslice :: fn($T: type, p: *T, n: usize) -> []T {
        \\    return unsafe core::slice_raw(T, p, n);
        \\}
        \\main :: fn() -> i32 {
        \\    arr: [3]i32 = .{ 5, 9, 1 };
        \\    full := arr[:];
        \\    s := mkslice(i32, full.ptr, 3usize);
        \\    es := elem_bytes(i32);
        \\    return s[0] + s[1] + s[2] + (es as i32);
        \\}
    , "exe_generic_sizeof_slice");
    try std.testing.expectEqual(@as(u32, 19), code);
}

test "exe: usize const wider than 32 bits keeps its full width" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Regression: `inferConstType` emitted EVERY integer `const` as an i32 global
    // regardless of its type suffix, so a `usize`/`u64` const was an undersized
    // i32 global. A later i64 load then read 4 bytes of the value plus 4 bytes of
    // adjacent memory into the high word — corrupting any address built through
    // ptr_from_int / slice_from_raw_parts (segfaults in std.heap). With the fix
    // the high 32 bits survive: (0x5_0000_0000 >> 32) == 5; an i32 global would
    // truncate the low word to 0 and yield 0/garbage.
    const code = try compileAndRun(arena.allocator(),
        \\VAL :: 0x500000000usize;
        \\main :: fn() -> i32 { return (VAL >> 32usize) as i32; }
    , "exe_usize_const_width");
    try std.testing.expectEqual(@as(u32, 5), code);
}

test "exe: dynamic dispatch through an interface method that takes another interface pointer" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Regression: an interface impl method whose own parameter is itself an
    // interface pointer (`w: *Writer`) used to be lowered as a thin pointer
    // instead of a fat `{ data, vtable }` pointer (lowerTypeReplacingSelf
    // didn't recognize interface types). Calling a method on that nested
    // interface pointer then bitcast a thin `ptr` to `{ ptr, ptr }`, which
    // failed LLVM verification with "Invalid bitcast".
    const code = try compileAndRun(arena.allocator(),
        \\Writer :: interface {
        \\    write_all :: fn(self: *Self, s: []const u8) -> usize;
        \\}
        \\Display :: interface {
        \\    display :: fn(self: *Self, w: *Writer) -> usize;
        \\}
        \\Buf :: struct { total: usize }
        \\Buf as Writer {
        \\    write_all :: fn(self: *Self, s: []const u8) -> usize {
        \\        self.total = self.total + s.len;
        \\        return s.len;
        \\    }
        \\}
        \\Point :: struct { x: i64, y: i64 }
        \\Point as Display {
        \\    display :: fn(self: *Self, w: *Writer) -> usize {
        \\        return w.write_all("pt");
        \\    }
        \\}
        \\call_display :: fn(w: *Writer, value: *Display) -> usize {
        \\    return value.display(w);
        \\}
        \\main :: fn() -> i32 {
        \\    p: Point = .{ 1i64, 2i64 };
        \\    d: *Display = &p;
        \\    buf: Buf = .{ 0 };
        \\    w: *Writer = &buf;
        \\    n: usize = call_display(w, d);
        \\    return n as i32;
        \\}
    , "exe_iface_nested_dispatch_param");
    try std.testing.expectEqual(@as(u32, 2), code);
}

test "exe: nested dynamic dispatch on a parameter of an interface method" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Regression: previously crashed the compiler process with a segfault in
    // LLVM-C.dll while lowering `b.val()` inside `Foo.A.run`, because `b: *B`
    // was lowered as a thin pointer and lowerInterfaceData attempted to
    // extractvalue field 0 from a non-aggregate `ptr`. A malformed-but-valid
    // program must never crash the compiler outright.
    const code = try compileAndRun(arena.allocator(),
        \\A :: interface { run :: fn(self: *Self, b: *B) -> i32; }
        \\B :: interface { val :: fn(self: *Self) -> i32; }
        \\Foo :: struct { x: i32 }
        \\Bar :: struct { y: i32 }
        \\Foo as A {
        \\    run :: fn(self: *Self, b: *B) -> i32 { return b.val(); }
        \\}
        \\Bar as B {
        \\    val :: fn(self: *Self) -> i32 { return self.y; }
        \\}
        \\call_it :: fn(a: *A, b: *B) -> i32 { return a.run(b); }
        \\main :: fn() -> i32 {
        \\    foo: Foo = .{ 1i32 };
        \\    bar: Bar = .{ 99i32 };
        \\    a: *A = &foo;
        \\    b: *B = &bar;
        \\    return call_it(a, b);
        \\}
    , "exe_iface_nested_dispatch_segfault");
    try std.testing.expectEqual(@as(u32, 99), code);
}

test "exe: generic List(T) backed by Arena, with generic methods" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Exercises three fixes together: arena-allocating a generic struct instance
    // (correct allocation size, not a bare pointer), storing zone-owned memory
    // into a struct field (escape-ownership propagation), and dispatching a
    // generic method whose receiver is `*List(T)` (concrete-instance matching).
    const code = try compileAndRun(arena.allocator(),
        \\List :: struct($T: type) {
        \\    data: [*]T,
        \\    len:  usize,
        \\    cap:  usize,
        \\}
        \\set :: fn($T: type, self: borrow *List(T), i: usize, v: T) { self.data[i] = v; }
        \\get :: fn($T: type, self: borrow *List(T), i: usize) -> T { return self.data[i]; }
        \\main :: fn() -> i32 {
        \\    zone scope: Arena {
        \\        buf := scope.new_slice(i32, 8);
        \\        l := scope.new(List(i32));
        \\        l.data = buf.ptr;
        \\        l.cap  = 8usize;
        \\        l.len  = 3usize;
        \\        l.set(i32, 0usize, 10);
        \\        l.set(i32, 1usize, 20);
        \\        l.set(i32, 2usize, 12);
        \\        return l.get(i32, 0usize) + l.get(i32, 1usize) + l.get(i32, 2usize);
        \\    }
        \\    return 0;
        \\}
    , "exe_generic_list_arena");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: wrapping arithmetic wraps instead of trapping" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // +% / -% / *% never trap; plain + would panic on these overflows at -O0.
    // (Return a value < 256 so the process exit code isn't truncated.)
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    a := 250u8 +% 10u8;     // 4   (wraps at 256)
        \\    b := 200u8 *% 2u8;      // 144 (400 mod 256)
        \\    c := 0u8 -% 1u8;        // 255
        \\    if a == 4u8 && b == 144u8 && c == 255u8 { return 42; }
        \\    return 0;
        \\}
    , "exe_wrapping_arith");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: a wrapping-hash constant matches its runtime value (comptime == runtime)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // FNV-1a needs a wrapping multiply on every byte. Computing it at compile
    // time (the VM works in i128, wrapping) must agree with the runtime u32
    // computation — the low 32 bits are congruent regardless of intermediate width.
    const code = try compileAndRun(arena.allocator(),
        \\fnv1a :: fn(s: []const u8) -> u32 {
        \\    h := 2166136261u32;
        \\    i := 0usize;
        \\    while i < s.len { h = (h ^ (s[i] as u32)) *% 16777619u32; i = i + 1usize; }
        \\    return h;
        \\}
        \\HASH :: #run fnv1a("hello");
        \\main :: fn() -> i32 {
        \\    if fnv1a("hello") == HASH { return 1; }
        \\    return 0;
        \\}
    , "exe_wrapping_hash");
    try std.testing.expectEqual(@as(u32, 1), code);
}

test "exe: build AST programmatically (no #quote) and #insert it" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Construct `ast.*` values as data (AstExpr.int / AstStmt.ret_expr / AstBlock)
    // and splice the generated block — the "programmatic AST without #quote" path,
    // unblocked by enum-payload construction.
    const code = try compileAndRun(arena.allocator(),
        \\gen :: fn() -> AstBlock {
        \\    stmts: [1]AstStmt = .{ AstStmt.ret_expr(AstExpr.int(42)) };
        \\    b: AstBlock = .{ stmts[:] };
        \\    return b;
        \\}
        \\main :: fn() -> i32 {
        \\    #insert #run gen();
        \\    return 0;
        \\}
    , "exe_programmatic_ast");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: enum variant construction with payload (construct, then match)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `EnumType.variant(payload)` builds a payload-carrying enum; the match arm
    // recovers the payload. This exercised four latent backend bugs in the
    // payload-enum → LLVM path (binding type, store type, and two `__chkstk`
    // allocas) that no prior test reached, since payload enums were unbuildable.
    const code = try compileAndRun(arena.allocator(),
        \\Expr :: enum { num: i32, flag: bool, nothing }
        \\eval :: fn(e: Expr) -> i32 {
        \\    match e {
        \\        .num |n|  => return n;
        \\        .flag |b| => { if b { return 100; } return 200; }
        \\        else      => return 0;
        \\    }
        \\}
        \\main :: fn() -> i32 {
        \\    return eval(Expr.num(42)) + eval(Expr.flag(true)) - eval(Expr.nothing);
        \\}
    , "exe_enum_payload_construct");
    try std.testing.expectEqual(@as(u32, 142), code);
}

test "exe: a zone handle is a real std.heap.Arena (full library API)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The unified arena: a `zone` handle exposes both the `new`/`new_slice`
    // aliases AND the library API (dupe, mark/restore, alloc_bytes) — one
    // bump allocator, drained on zone exit. std.heap is auto-injected; the
    // module never imports it.
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    total := 0;
        \\    zone z: Arena {
        \\        a := z.new_slice(i32, 2usize);
        \\        a[0usize] = 3; a[1usize] = 4;
        \\        src: [3]u8 = .{ 1u8, 2u8, 3u8 };
        \\        d := z.dupe(u8, src[:]);
        \\        m := z.mark();
        \\        tmp := z.alloc_bytes(8usize);
        \\        tmp[0usize] = 100u8;
        \\        z.restore(m);
        \\        total = a[0usize] + a[1usize] + (d[0usize] as i32) + (d[2usize] as i32);
        \\    }
        \\    return total;
        \\}
    , "exe_zone_unified_arena");
    try std.testing.expectEqual(@as(u32, 11), code);
}

test "exe: a local shadows a top-level function of the same name" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Regression: `foo := 42` next to `foo :: fn()` previously resolved the
    // reference to the FUNCTION (`ret ptr @foo`) → LLVM verification error.
    const code = try compileAndRun(arena.allocator(),
        \\foo :: fn() -> i32 { return 5; }
        \\main :: fn() -> i32 {
        \\    foo := 42;
        \\    return foo;
        \\}
    , "exe_local_shadows_fn");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: a local inferred from a usize const stays integer-typed" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Regression: `to := SA` for a `usize` module const mistyped `to` as a
    // pointer → `add ptr` LLVM verification error. The const reference now
    // records its type, so the inferred local is `usize`.
    const code = try compileAndRun(arena.allocator(),
        \\SA :: 37usize;
        \\main :: fn() -> i32 {
        \\    to := SA;
        \\    return (to + 5usize) as i32;
        \\}
    , "exe_local_from_usize_const");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: macro templates substitute splices through match/for/compound/type" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Regression for the "total substitution" work: a macro body may contain a
    // `match`, a runtime `for`, a compound literal, and a type-position splice —
    // and `$param` holes inside all of them are substituted.
    const code = try compileAndRun(arena.allocator(),
        \\Pair :: struct { a: i32, b: i32 }
        \\build :: macro(out: Expr, ty: Expr, sel: Expr, lo: Expr, hi: Expr) {
        \\    return #quote {
        \\        p: Pair = .{ $lo, $hi };          // splice inside `.{ }`
        \\        acc: $ty = 0;                     // type-position splice
        \\        for k in p.a..p.b { acc = acc + k; } // splice-built bounds via fields
        \\        match $sel {                      // splice as match subject
        \\            1 => { $out = acc + p.a; }
        \\            else => { $out = acc; }
        \\        }
        \\    };
        \\}
        \\main :: fn() -> i32 {
        \\    r: i32 = 0;
        \\    #insert build(r, i32, 1, 10, 13);     // p=.{10,13}; acc=10+11+12=33; +p.a(10)=43?
        \\    return r - 1;                          // 33 + 10 = 43 -> 42
        \\}
    , "exe_macro_total_subst");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: macro locals are hygienic (don't capture the caller's same-named local)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The macro introduces its own `tmp` and a `for k`; both must be renamed so
    // they don't collide with the caller's `tmp`/`k`, including inside the match
    // arm and for body (hygiene now recurses those).
    const code = try compileAndRun(arena.allocator(),
        \\accumulate :: macro(out: Expr, n: Expr) {
        \\    return #quote {
        \\        tmp := 0;
        \\        for k in 0..$n { tmp = tmp + k; }
        \\        match tmp { else => { $out = tmp; } }
        \\    };
        \\}
        \\main :: fn() -> i32 {
        \\    tmp: i32 = 100;   // caller's `tmp` must survive the macro untouched
        \\    k: i32 = 7;       // caller's `k` likewise
        \\    r: i32 = 0;
        \\    #insert accumulate(r, 9);          // 0+1+..+8 = 36 into r
        \\    return r + (tmp - 100) + (k - 7);  // 36 + 0 + 0 = 36 iff tmp/k uncaptured
        \\}
    , "exe_macro_hygiene");
    try std.testing.expectEqual(@as(u32, 36), code);
}

test "exe: match as an expression (enum/int subjects, payload, positions)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\V :: enum { I: i32, N }
        \\Sign :: enum { Neg, Zero, Pos }
        \\sign_val :: fn(s: Sign) -> i32 {
        \\    // total enum match-expr, no else — used directly in `return`
        \\    return match s { .Neg => -1, .Zero => 0, .Pos => 1 };
        \\}
        \\main :: fn() -> i32 {
        \\    v := V.I(20);
        \\    a := match v { .I |p| => p, .N => 0 };       // payload binding -> 20
        \\    x: i32 = 2;
        \\    b := match x { 1 => 0, 2 => 21, else => 9 }; // int subject + else -> 21
        \\    c := sign_val(.Pos);                          // -> 1
        \\    return a + b + c;                             // 20 + 21 + 1 = 42
        \\}
    , "exe_match_expr");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: match range patterns, guards, and binding catch-all" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\bucket :: fn(n: i32) -> i32 {
        \\    return match n {
        \\        0..=9   => 1,          // inclusive range
        \\        10..20  => 2,          // exclusive range (excludes 20)
        \\        k if k == 20 => 3,     // guard on a binding
        \\        else    => 9,
        \\    };
        \\}
        \\main :: fn() -> i32 {
        \\    // 1 + 2 + 3 + ... arranged to total 42
        \\    total := bucket(5) * 10;   // 1*10 = 10
        \\    total = total + bucket(15) * 11; // 2*11 = 22
        \\    total = total + bucket(20);      // 3
        \\    total = total + bucket(99) - 2;  // 9 - 2 = 7
        \\    return total;              // 10 + 22 + 3 + 7 = 42
        \\}
    , "exe_match_range_guard");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: match string patterns (grouped, safe on shorter subject)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\rank :: fn(s: []const u8) -> i32 {
        \\    return match s {
        \\        "gold"          => 30,
        \\        "silver", "bronze" => 10,   // grouped
        \\        else            => 1,        // a 1-byte subject must not OOB-read "gold"
        \\    };
        \\}
        \\main :: fn() -> i32 {
        \\    a: []const u8 = "gold";
        \\    b: []const u8 = "bronze";
        \\    c: []const u8 = "x";
        \\    return rank(a) + rank(b) + rank(c) + 1;  // 30 + 10 + 1 + 1 = 42
        \\}
    , "exe_match_strings");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: match-expression threads the expected type into `.{ }` arms" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Untyped struct-literal arms get their type from the local/return context.
    const code = try compileAndRun(arena.allocator(),
        \\P :: struct { x: i32, y: i32 }
        \\T :: enum { A, B }
        \\main :: fn() -> i32 {
        \\    t := T.B;
        \\    p: P = match t { .A => .{ 1, 2 }, .B => .{ 40, 2 } };
        \\    return p.x + p.y;   // 40 + 2 = 42
        \\}
    , "exe_match_expr_typed");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: `#compiler` hook derives code from struct fields (R1c)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A `#compiler` hook reads each struct's fields (rich introspection, R1a) and
    // BUILDS generated source from them with the prelude's `CodeBuf`/`__str_cat`
    // (a VM-native string builder — no heap/raw pointers), emitting a `sum_<T>`
    // for every struct. This is the `#derive` capability, end-to-end.
    const code = try compileAndRun(arena.allocator(),
        \\Point :: struct { x: i32, y: i32 }
        \\Vec3  :: struct { a: i32, b: i32, c: i32 }
        \\#compiler derive_sum :: fn() -> []const u8 {
        \\    cb := gen_buf();
        \\    for d in core::compiler_decls() {
        \\        match d.kind {
        \\            "struct" => {
        \\                emit(&cb, "sum_"); emit(&cb, d.name);
        \\                emit(&cb, " :: fn(p: "); emit(&cb, d.name);
        \\                emit(&cb, ") -> i32 { return 0");
        \\                for f in d.fields { emit(&cb, " + p."); emit(&cb, f.name); }
        \\                emit(&cb, "; } ");
        \\            }
        \\            else => {}
        \\        }
        \\    }
        \\    return rendered(&cb);
        \\}
        \\main :: fn() -> i32 {
        \\    p: Point = .{ 30, 2 };
        \\    v: Vec3 = .{ 3, 3, 4 };
        \\    return sum_Point(p) + sum_Vec3(v);
        \\}
    , "exe_derive_sum");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: `core::` builtin namespace works at runtime" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Builtins live in the reserved `core::` namespace (no sigil). `core::sizeof`
    // and `core::type_name` (via a local — inline `.len` on a folded type_name is a
    // separate latent bug); `core::panic` is no-return so the `if` needs no trailing
    // return. Returns 8 (sizeof Point) + 5 (len "Point") = 13.
    const code = try compileAndRun(arena.allocator(),
        \\Point :: struct { x: i32, y: i32 }
        \\pick :: fn(n: i32) -> i32 {
        \\    nm := core::type_name(Point);
        \\    if n >= 0 { return (core::sizeof(Point) as i32) + (nm.len as i32); }
        \\    core::panic("negative");
        \\}
        \\main :: fn() -> i32 { return pick(1); }
    , "exe_core_builtins");
    try std.testing.expectEqual(@as(u32, 13), code);
}

test "exe: `core::` math + bit + location builtins (Phase 2)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // count_ones(255)=8, max(10,20)=20, min(10,20)=10, abs(-4)=4 → 42.
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    a := core::count_ones(255);
        \\    b := core::max(10, 20);
        \\    c := core::min(10, 20);
        \\    d := core::abs(-4);
        \\    return a + b + c + d;
        \\}
    , "exe_core_math");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: `core::` memcpy + memset + float math (Phase 2)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // memset 4 bytes to 9, memcpy them, read back 9+9=18; sqrt(16)+floor(9.9)=4+9=13; clamp(50,0,5)=5 → 36.
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    zone a: Arena {
        \\        s := a.alloc_bytes(8);
        \\        d := a.alloc_bytes(8);
        \\        core::memset(s.ptr, 9u8, 4usize);
        \\        core::memcpy(d.ptr, s.ptr, 4usize);
        \\        mem := (d[0] + d[1]) as i32;
        \\        fl  := (core::sqrt(16.0) as i32) + (core::floor(9.9) as i32);
        \\        return mem + fl + core::clamp(50, 0, 5);
        \\    }
        \\}
    , "exe_core_mem");
    try std.testing.expectEqual(@as(u32, 36), code);
}

test "exe: a `#compiler` hook REPLACES an existing decl by name (R1b-B)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `answer` starts as a placeholder returning 0; the hook emits a same-named
    // decl that REPLACES it. The program returns 42 only if the replacement won
    // (and there's no duplicate-decl error).
    const code = try compileAndRun(arena.allocator(),
        \\answer :: fn() -> i32 { return 0; }
        \\#compiler gen :: fn() -> []const u8 { return "answer :: fn() -> i32 { return 42; }"; }
        \\main :: fn() -> i32 { return answer(); }
    , "exe_hook_replace");
    try std.testing.expectEqual(@as(u32, 42), code);
}

/// Compile a Gabbro source FILE (resolving its `#import`s from disk) to an exe and
/// return its exit code. Unlike `compileAndRun`, this exercises cross-module
/// lowering (the std library, user modules, …).
fn compileFileAndRun(allocator: std.mem.Allocator, file_name: []const u8, label: []const u8) !u32 {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;

    const io = std.testing.io;
    const obj_path = try std.fmt.allocPrint(allocator, ".zig-cache/{s}.o", .{label});
    defer allocator.free(obj_path);
    const exe_path = try std.fmt.allocPrint(allocator, ".zig-cache/{s}.exe", .{label});
    defer allocator.free(exe_path);

    const lib_path = gabbro.windows_sdk_lib_path;
    const lib_paths: []const []const u8 = if (lib_path.len > 0) &.{lib_path} else &.{};
    try gabbro.compileFileWithLlvm(allocator, io, .{
        .file_name = file_name,
        .source = "",
        .obj_path = obj_path,
        .exe_path = exe_path,
        .opt_level = 2,
        .llvm_bin = gabbro.llvm_path ++ "/bin",
        .lib_paths = lib_paths,
    });

    const exe_argv = [_][]const u8{exe_path};
    var child = std.process.spawn(io, .{
        .argv = &exe_argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    const term = child.wait(io) catch return 255;
    return switch (term) {
        .exited => |code| @intCast(code),
        else => 255,
    };
}

test "exe: std.path / std.time / std.crypto / std.serde run correctly cross-module" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Each fixture self-checks its module's API and returns 42 iff all correct
    // (path: query/join; time: UTC calendar + live clocks; crypto: crc32/fnv;
    // serde: reflection-driven JSON for scalars/strings/nested structs/all widths).
    inline for (.{
        .{ "tests/fixtures/stdlib/path_app.gab", "exe_path_app" },
        .{ "tests/fixtures/stdlib/time_app.gab", "exe_time_app" },
        .{ "tests/fixtures/stdlib/crypto_app.gab", "exe_crypto_app" },
        .{ "tests/fixtures/stdlib/serde_app.gab", "exe_serde_app" },
        .{ "tests/fixtures/stdlib/slice_app.gab", "exe_slice_app" },
        .{ "tests/fixtures/stdlib/atomics_app.gab", "exe_atomics_app" },
        .{ "tests/fixtures/stdlib/atomics_thread_app.gab", "exe_atomics_thread_app" },
        .{ "tests/fixtures/stdlib/atomic_cell_app.gab", "exe_atomic_cell_app" },
        .{ "tests/fixtures/stdlib/atomic_qualified_app.gab", "exe_atomic_qualified_app" },
        .{ "tests/fixtures/lang/struct_methods_app.gab", "exe_struct_methods_app" },
        .{ "tests/fixtures/lang/extern_fnptr_app.gab", "exe_extern_fnptr_app" },
        .{ "tests/fixtures/lang/derive_eq_app.gab", "exe_derive_eq_app" },
        .{ "tests/fixtures/lang/user_derive_app.gab", "exe_user_derive_app" },
        .{ "tests/fixtures/stdlib/thread_app.gab", "exe_thread_app" },
        .{ "tests/fixtures/stdlib/net_addr_app.gab", "exe_net_addr_app" },
        .{ "tests/fixtures/stdlib/vec_app.gab", "exe_vec_app" },
        .{ "tests/fixtures/stdlib/map_app.gab", "exe_map_app" },
        .{ "tests/fixtures/stdlib/env_app.gab", "exe_env_app" },
    }) |c| {
        const code = try compileFileAndRun(arena.allocator(), c[0], c[1]);
        try std.testing.expectEqual(@as(u32, 42), code);
    }
}

test "exe: two generic structs sharing a method name + type arg don't collide" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A generic in-struct method used to mangle off the bare member name, so
    // `Box(i32).get` and `Cell(i32).get` both became `get__T_i32` — one
    // definition won and the other call passed mismatched arity (LLVM verify
    // error / miscompile). They must be distinct symbols now. `Box.get` takes no
    // extra arg, `Cell.get` takes one — different arity makes the collision fatal.
    const code = try compileAndRun(arena.allocator(),
        \\Box  :: struct($T: type) { v: T   pub get :: fn(self: *Self) -> T { return self.v; } }
        \\Cell :: struct($T: type) { v: T   pub get :: fn(self: *Self, add: T) -> T { return self.v + add; } }
        \\#entry
        \\main :: fn() -> i32 {
        \\    b: Box(i32)  = .{ 40 };
        \\    c: Cell(i32) = .{ 1 };
        \\    return b.get() + c.get(1);   // 40 + (1+1) = 42
        \\}
    , "exe_generic_method_no_collision");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: UFCS method call on a temporary receiver (chaining)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A method's `*Self` receiver auto-refs a value receiver. It used to require an
    // lvalue, so `mk().get()` and `a.method().other()` errored. Now a temporary is
    // spilled to a stack slot and pointed at, enabling method chaining on returned
    // values. Addressable receivers still point in place.
    const code = try compileAndRun(arena.allocator(),
        \\P :: struct {
        \\    v: i32
        \\    pub inc :: fn(self: *Self) -> P { return .{ self.v + 1 }; }
        \\    pub get :: fn(self: *Self) -> i32 { return self.v; }
        \\}
        \\mk :: fn(n: i32) -> P { return .{ n }; }
        \\#entry
        \\main :: fn() -> i32 {
        \\    a := mk(40).get();          // call temporary → 40
        \\    b := mk(40).inc().inc();    // chain on returned values → 42
        \\    return a - 40 + b.get();    // 0 + 42
        \\}
    , "exe_ufcs_temporary");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: fallible tail-forward + qualified `! ns::Error` return type" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `return inner();` passes a whole `{ok,err}` value through (no `?`); ok value
    // forwarded on success, error forwarded on failure. `-> T ! heap::MemError`
    // qualifies an error type from another module without a dual-import. (A fixture
    // because both features need a real cross-module import.)
    const code = try compileFileAndRun(arena.allocator(),
        "tests/fixtures/lang/fallible_forward_app.gab", "exe_fallible_forward_qualerr");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: if-expressions (value position, else-if, bidirectional typing)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `if c { a } else { b }` as a value: in a `:=`, a typed local (the branch
    // literal gets the local's type), an else-if chain, inside arithmetic, and a
    // struct-literal branch (bidirectional typing). Statement-`if` is unaffected.
    const code = try compileAndRun(arena.allocator(),
        \\P :: struct { x: i32, y: i32 }
        \\classify :: fn(n: i32) -> i32 { return if n == 1 { 100 } else if n == 2 { 7 } else { 0 }; }
        \\#entry
        \\main :: fn() -> i32 {
        \\    a := if true { 30 } else { 0 };          // := if
        \\    w: u32 = if a > 0 { 5u32 } else { 0u32 }; // typed-local branch literal
        \\    p: P = if a > 0 { .{ 1, 2 } } else { .{ 0, 0 } }; // struct branch
        \\    return a + (w as i32) + p.x + p.y + classify(2) - 3; // 30+5+1+2+7-3 = 42
        \\}
    , "exe_if_expression");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: compound literal `.{…}` as a function argument (slice + generic key)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `f(.{…})` used to silently miscompile and crash when the parameter was a
    // slice (the `{ptr,len}` was built with no backing storage → a dangling
    // pointer) or the struct's own type param (`key: K`, lowered untyped). Now the
    // slice case materialises a backing array and the type-param case resolves K
    // from the instantiation. Sum: 10+14+18 (slice) + 1+2 (struct key value 30→ via map).
    const code = try compileAndRun(arena.allocator(),
        \\Point :: struct { x: i32, y: i32 }
        \\sumv :: fn(a: []const i32) -> i32 { t: i32 = 0; for x in a { t += x; } return t; }
        \\Map :: struct($K: type, $V: type) {
        \\    key: K, val: V, set: bool
        \\    pub put :: fn(self: *Self, k: K, v: V) { self.key = k; self.val = v; self.set = true; }
        \\    pub val_of :: fn(self: *Self) -> V { return self.val; }
        \\}
        \\#entry
        \\main :: fn() -> i32 {
        \\    s := sumv(.{ 10, 14, 18 });            // slice arg → 42
        \\    m: Map(Point, i32) = .{ .{0,0}, 0, false };
        \\    m.put(.{ 1, 2 }, 7);                    // compound key (type param K)
        \\    return s - m.val_of() + m.val_of();     // 42, and proves put didn't crash
        \\}
    , "exe_compound_literal_arg");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: std.net layered TCP + UDP loopback round-trips (os/socket/tcp/udp)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Real loopback sockets across the layered std.net (os → socket → tcp/udp),
    // each fixture spawning a server thread and doing a client round-trip:
    //   tcp: connect / accept (with peer addr) / send_all / recv / local_addr
    //   udp: bind / recv_from / send_to / connected connect+send+recv
    // Each returns 42 iff the bytes echoed back intact.
    inline for (.{
        .{ "tests/fixtures/stdlib/net_echo_app.gab", "exe_net_echo_app" },
        .{ "tests/fixtures/stdlib/net_udp_app.gab", "exe_net_udp_app" },
    }) |c| {
        const code = try compileFileAndRun(arena.allocator(), c[0], c[1]);
        try std.testing.expectEqual(@as(u32, 42), code);
    }
}

test "exe: #extern links against its C symbol (2nd arg), not its gabbro name" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Regression: an `#extern("lib", "CSym")` used to emit its gabbro declaration name
    // as the link symbol (so `mul_div` → undefined symbol `mul_div`). The 2nd
    // `#extern` arg is now the real link name, so the gabbro name is free to differ.
    // Also: two externs with DIFFERENT gabbro names may bind the SAME C symbol without
    // colliding (distinct scope keys; LLVM dedups the one external decl).
    const code = try compileAndRun(arena.allocator(),
        \\#extern("kernel32", "MulDiv") mul_div :: fn(a: i32, b: i32, c: i32) -> i32;
        \\#extern("kernel32", "MulDiv") scale   :: fn(a: i32, b: i32, c: i32) -> i32;
        \\#entry
        \\main :: fn() -> i32 {
        \\    x := mul_div(6, 7, 1);   // round(42/1)  = 42
        \\    y := scale(84, 1, 2);    // round(84/2)  = 42
        \\    if x != y { return 1; }  // both reach the same MulDiv
        \\    return x;
        \\}
    , "exe_extern_rename");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: generic fn instantiated for two distinct struct types stays distinct" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `tyMangle(.named)` used to return the literal "named", so a generic
    // instantiated with two different structs collapsed into ONE body (the first
    // type's), and the second call silently reused it. Here `nf(A)` must see 2
    // fields and `nf(B)` must see 3 — distinct instantiations.
    const code = try compileAndRun(arena.allocator(),
        \\A :: struct { x: i32, y: i32 }
        \\B :: struct { p: i32, q: i32, r: i32 }
        \\nf :: fn($T: type, v: T) -> usize {
        \\    match core::type_info(T) { .struct_ |s| => return s.fields.len; else => return 0usize; }
        \\}
        \\#entry
        \\main :: fn() -> i32 {
        \\    a: A = .{ 1, 2 };
        \\    b: B = .{ 1, 2, 3 };
        \\    return (nf(A, a) * 10usize + nf(B, b)) as i32;
        \\}
    , "exe_generic_two_structs");
    try std.testing.expectEqual(@as(u32, 23), code); // 2*10 + 3
}

test "exe: same-named local of different types across disjoint scopes stays distinct" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The backend keys locals by name (one alloca per name). Reusing `n` as a
    // struct binding in one match arm and an i32 counter in another used to make
    // them share a slot (the loop `n` picked up the struct type → backend crash).
    // The IR now gives colliding same-name locals distinct slots (scope-aware).
    const code = try compileAndRun(arena.allocator(),
        \\Box :: struct { v: i32 }
        \\pick :: fn(sel: i32, b: Box, lim: i32) -> i32 {
        \\    match sel {
        \\        0 => { n: Box = b; return n.v; }       // `n` is a struct here
        \\        else => {
        \\            sum: i32 = 0;
        \\            n: i32 = 0;                          // `n` is an i32 here
        \\            while n < lim { sum = sum + n; n = n + 1; }
        \\            return sum;
        \\        }
        \\    }
        \\}
        \\#entry
        \\main :: fn() -> i32 {
        \\    bx: Box = .{ 100 };
        \\    return pick(0, bx, 5) + pick(1, bx, 5);   // 100 + (0+1+2+3+4=10) = 110
        \\}
    , "exe_local_scope_collision");
    try std.testing.expectEqual(@as(u32, 110), code);
}

test "exe: match on a by-value enum field of a struct (simple + payloaded)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A struct's by-value enum field must resolve to the enum's real type before
    // the struct is bodied; otherwise the field falls back to a pointer and a
    // `match s.field` lowers an `icmp ptr, i32` / extracts a discriminant from a
    // pointer (LLVM verify / ICE). Enums are now declared as shells before structs
    // (payloaded enums = named opaque shells, bodied after), so BOTH a simple enum
    // field AND a payloaded enum field work.
    const code = try compileAndRun(arena.allocator(),
        \\Color :: enum { Red, Green, Blue }
        \\Shape :: enum { Dot, Circle: i32 }
        \\Box :: struct { c: Color, s: Shape, n: i32 }
        \\color_score :: fn(b: Box) -> i32 {
        \\    match b.c { .Red => return 1; .Green => return 2; .Blue => return 3; }
        \\}
        \\#entry
        \\main :: fn() -> i32 {
        \\    b: Box = .{ Color.Blue, Shape.Circle(7), 9 };
        \\    r: i32 = 0;
        \\    match b.s { .Circle |x| => r = x; else => {} }       // payloaded field
        \\    return color_score(b) * 50 + r * 5 + b.n;            // 3*50 + 7*5 + 9 = 194 (< 256)
        \\}
    , "exe_enum_field_match");
    try std.testing.expectEqual(@as(u32, 194), code);
}

test "exe: `[N]T = .{}` actually zero-inits the whole array (issue #7)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `.{}` used to lower to a zero-length array store (the backend built a
    // `[0 x T]` from the literal's arg count), so the array kept whatever was on
    // the stack. `dirty` fills a frame with 0xff; `check` must then see all zeros.
    const code = try compileAndRun(arena.allocator(),
        \\dirty :: fn() -> u32 {
        \\    a: [128]u8 = .{};
        \\    i: usize = 0usize; while i < 128usize { a[i] = 0xffu8; i = i + 1usize; }
        \\    s: u32 = 0u32; i = 0usize; while i < 128usize { s = s +% (a[i] as u32); i = i + 1usize; }
        \\    return s;
        \\}
        \\check :: fn() -> u32 {
        \\    a: [128]u8 = .{};
        \\    s: u32 = 0u32; i: usize = 0usize; while i < 128usize { s = s +% (a[i] as u32); i = i + 1usize; }
        \\    return s;
        \\}
        \\main :: fn() -> i32 { _ := dirty(); return check() as i32; }
    , "exe_zero_init");
    try std.testing.expectEqual(@as(u32, 0), code);
}

test "exe: compound-lvalue field assignment lands (a.b.c, arr[i].f) (issue #8)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `l.p.x = 40` and `g.cells[2].y = 2` used to be silently dropped — the
    // address of the nested place wasn't taken, so the store hit a temp copy.
    const code = try compileAndRun(arena.allocator(),
        \\P :: struct { x: i32, y: i32 }
        \\L :: struct { p: P, n: i32 }
        \\Grid :: struct { cells: [4]P }
        \\main :: fn() -> i32 {
        \\    l: L = .{ .{1,2}, 0 };
        \\    l.p.x = 40;
        \\    g: Grid = .{ .{ .{0,0}, .{0,0}, .{0,0}, .{0,0} } };
        \\    g.cells[2].y = 2;
        \\    return l.p.x + g.cells[2].y;
        \\}
    , "exe_compound_lvalue");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: `[N]T` with a named-const size has the right length (issue #9)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `[N]u8` with a named const N used to get a garbage length (the const map
    // was populated after layout). Now `a.len == N` and the storage is real.
    const code = try compileAndRun(arena.allocator(),
        \\N :: 48;
        \\main :: fn() -> i32 {
        \\    a: [N]u8 = .{};
        \\    a[N - 1usize] = 7u8;
        \\    return (a.len as i32) + (a[N - 1usize] as i32);
        \\}
    , "exe_named_const_array");
    try std.testing.expectEqual(@as(u32, 55), code); // 48 + 7
}

test "exe: a nested `#run` in a top-level const folds (issue #4)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `10 + #run f()` used to drop the `#run` and fold to 0 — only a whole-RHS
    // `#run` was routed to the comptime VM. Now any embedded `#run` folds too.
    const code = try compileAndRun(arena.allocator(),
        \\f :: fn() -> i32 { return 5; }
        \\K :: 10 + #run f();
        \\P :: #run f() * 3;
        \\main :: fn() -> i32 { return K + P; }
    , "exe_nested_run_const");
    try std.testing.expectEqual(@as(u32, 30), code);
}

test "exe: for-in over an iterator (next protocol)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `for x in r` over a type with `next(self: *Self) -> ?T` desugars to a
    // `while r.next() |x|` loop; the iterator state advances in a hidden local.
    const code = try compileAndRun(arena.allocator(),
        \\Range :: struct { cur: i32, end: i32 }
        \\next :: fn(self: *Range) -> ?i32 {
        \\    if self.cur >= self.end { return null; }
        \\    v := self.cur; self.cur = self.cur + 1; return v;
        \\}
        \\main :: fn() -> i32 {
        \\    r: Range = .{ 1, 5 };
        \\    sum: i32 = 0;
        \\    for x in r { sum = sum + x; }
        \\    return sum;
        \\}
    , "exe_iterator");
    try std.testing.expectEqual(@as(u32, 10), code); // 1+2+3+4
}

test "exe: lambdas — inline, in a local, and a fn value held in a local" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `fn(x){…}` lifts to a top-level fn; storing a fn value in a local and
    // calling it types the (indirect) call's args from the fn-pointer signature
    // (regression: an `.imm` literal arg used to lower to a zero-width `i0`).
    const code = try compileAndRun(arena.allocator(),
        \\dbl :: fn(x: i32) -> i32 { return x * 2; }
        \\apply :: fn(g: fn(i32) -> i32, v: i32) -> i32 { return g(v); }
        \\main :: fn() -> i32 {
        \\    f := fn(x: i32) -> i32 { return x + 1; };      // lambda in a local
        \\    g := dbl;                                       // a fn value in a local
        \\    a := f(10);                                     // 11
        \\    b := g(16);                                     // 32
        \\    c := apply(fn(x: i32) -> i32 { return x * 3; }, 7); // 21 (lambda as a HOF arg)
        \\    return a + b + c;
        \\}
    , "exe_lambdas");
    try std.testing.expectEqual(@as(u32, 64), code); // 11 + 32 + 21
}

test "exe: a lambda captures enclosing locals by value (closure env)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `base` and `step` are captured by value into the closure's environment;
    // the lambda reads them through its hidden `__env` pointer — both when called
    // directly and when passed to a higher-order function.
    const code = try compileAndRun(arena.allocator(),
        \\apply :: fn(f: fn(i32) -> i32, v: i32) -> i32 { return f(v); }
        \\main :: fn() -> i32 {
        \\    base: i32 = 100;
        \\    step: i32 = 5;
        \\    f := fn(x: i32) -> i32 { return base + step * x; };
        \\    return apply(f, 3) + f(1); // (100 + 15) + (100 + 5) = 220
        \\}
    , "exe_capture");
    try std.testing.expectEqual(@as(u32, 220), code);
}

test "exe: a capturing closure's environment lives on the enclosing zone" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Created inside a `zone`, the closure's captured environment is allocated on
    // that zone's Arena (not the stack), so it survives being handed to another
    // function — the basis for escaping closures.
    const code = try compileAndRun(arena.allocator(),
        \\call_it :: fn(f: fn(i32) -> i32, v: i32) -> i32 { return f(v); }
        \\main :: fn() -> i32 {
        \\    r: i32 = 0;
        \\    zone scratch: Arena {
        \\        base: i32 = 100;
        \\        f := fn(x: i32) -> i32 { return base + x; };
        \\        r = call_it(f, 7); // 107
        \\    }
        \\    return r;
        \\}
    , "exe_zone_closure");
    try std.testing.expectEqual(@as(u32, 107), code);
}

test "exe: a fn-ptr struct field is a thin C pointer, not a fat closure" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A `fn(...)` field must be a single pointer (8 bytes) so the struct layout
    // matches C structs like Win32 `WNDCLASSEXA` — a fat `{fn, env}` closure would
    // make this 32. Layout: u32(4) + pad(4) + ptr(8) + u32(4) + tail pad(4) = 24.
    const code = try compileAndRun(arena.allocator(),
        \\WC :: struct { a: u32, proc: fn(usize) -> isize, b: u32 }
        \\handler :: fn(h: usize) -> isize { return 0isize; }
        \\main :: fn() -> i32 {
        \\    wc: WC = .{ 1u32, handler, 2u32 };
        \\    return core::sizeof(WC) as i32;
        \\}
    , "exe_fnptr_field");
    try std.testing.expectEqual(@as(u32, 24), code);
}

test "exe: a function pointer stored in a struct field can be called" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `b.op(args)` calls the function pointer stored in the field — a thin
    // indirect call (e.g. dispatch tables, stored C callbacks).
    const code = try compileAndRun(arena.allocator(),
        \\dbl :: fn(x: i32) -> i32 { return x * 2; }
        \\Box :: struct { op: fn(i32) -> i32, n: i32 }
        \\main :: fn() -> i32 {
        \\    b: Box = .{ dbl, 21 };
        \\    return b.op(b.n); // 42
        \\}
    , "exe_field_call");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: a factory returns escaping closures whose env lives in the caller's Arena" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `make_adder` takes an `*Arena`; the closure it returns allocates its capture
    // environment in that caller-owned region (region passing), so it can escape
    // the factory and stay valid for the zone's lifetime.
    const code = try compileAndRun(arena.allocator(),
        \\make_adder :: fn(into: *Arena, n: i32) -> fn(i32) -> i32 {
        \\    return fn(x: i32) -> i32 { return x + n; };
        \\}
        \\main :: fn() -> i32 {
        \\    r: i32 = 0;
        \\    zone z: Arena {
        \\        add5 := make_adder(&z, 5);
        \\        add100 := make_adder(&z, 100);
        \\        r = add5(10) + add100(1); // 15 + 101 = 116
        \\    }
        \\    return r;
        \\}
    , "exe_factory");
    try std.testing.expectEqual(@as(u32, 116), code);
}

test "exe: a non-capturing closure folds at compile time in #run" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The comptime VM can build a (non-capturing) closure value and call through
    // it, so a higher-order call folds to a constant at compile time.
    const code = try compileAndRun(arena.allocator(),
        \\dbl :: fn(x: i32) -> i32 { return x * 2; }
        \\apply :: fn(f: fn(i32) -> i32, v: i32) -> i32 { return f(v); }
        \\K :: #run apply(dbl, 21);
        \\main :: fn() -> i32 { return K; }
    , "exe_run_closure");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: a capturing closure folds at compile time in #run" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The comptime VM builds the closure's environment in its cell memory and
    // reads the captured value back, so a capturing closure folds too.
    const code = try compileAndRun(arena.allocator(),
        \\apply :: fn(f: fn(i32) -> i32, v: i32) -> i32 { return f(v); }
        \\compute :: fn() -> i32 {
        \\    factor: i32 = 10;
        \\    g := fn(x: i32) -> i32 { return x * factor; };
        \\    return apply(g, 5);
        \\}
        \\K :: #run compute();
        \\main :: fn() -> i32 { return K; }
    , "exe_run_capture");
    try std.testing.expectEqual(@as(u32, 50), code);
}

test "exe: while opt |x| walks an optional chain" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `while cur |n|` re-evaluates the optional each iteration, binds the unwrapped
    // payload, and exits on null — no `cont` bool flag needed.
    const code = try compileAndRun(arena.allocator(),
        \\Node :: struct { val: i32, next: ?*Node }
        \\main :: fn() -> i32 {
        \\    c: Node = .{ 4, null };
        \\    b: Node = .{ 3, &c };
        \\    a: Node = .{ 2, &b };
        \\    sum: i32 = 0;
        \\    cur: ?*Node = &a;
        \\    while cur |n| { sum = sum + n.val; cur = n.next; }
        \\    return sum;
        \\}
    , "exe_while_unwrap");
    try std.testing.expectEqual(@as(u32, 9), code); // 2+3+4
}

test "exe: else-if chains pick the right branch" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\bucket :: fn(x: i32) -> i32 {
        \\    if x < 0 { return 10; }
        \\    else if x < 10 { return 20; }
        \\    else if x < 20 { return 30; }
        \\    else { return 40; }
        \\}
        \\main :: fn() -> i32 { return bucket(-1) + bucket(5) + bucket(15) + bucket(99); }
    , "exe_else_if");
    try std.testing.expectEqual(@as(u32, 100), code); // 10+20+30+40
}

test "exe: character literals decode to their code points" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `'A'`, `'\n'`, `'\x05'` are untyped int literals; `s[i] == '.'` coerces the
    // literal to u8 in the comparison just like `s[i] == 46u8` would.
    const code = try compileAndRun(arena.allocator(),
        \\count_dots :: fn(s: []const u8) -> i32 {
        \\    n: i32 = 0; i: usize = 0usize;
        \\    while i < s.len { if s[i] == '.' { n = n + 1; } i = i + 1usize; }
        \\    return n;
        \\}
        \\main :: fn() -> i32 {
        \\    a: i32 = 'A';
        \\    nl: i32 = '\n';
        \\    hx: i32 = '\x05';
        \\    return a + nl + hx + count_dots("a.b.c");
        \\}
    , "exe_char_literals");
    try std.testing.expectEqual(@as(u32, 82), code); // 65 + 10 + 5 + 2
}

test "exe: a large stack frame links and runs (provides __chkstk)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // An 8 KiB stack frame exceeds one page, so LLVM emits a `__chkstk` probe.
    // The CRT-less link supplies its own `__chkstk` (module inline asm), so this
    // both links and runs correctly.
    const code = try compileAndRun(arena.allocator(),
        \\f :: fn(x: u32) -> u32 { w: [2048]u32 = .{}; w[0] = x; w[2047] = x + 1u32; return w[0] + w[2047]; }
        \\main :: fn() -> i32 { return f(20u32) as i32; }
    , "exe_big_frame");
    try std.testing.expectEqual(@as(u32, 41), code);
}

test "exe: std.list works cross-module (issue #6 + generic collision/realloc fixes)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The fixture self-checks every list op and returns 42 iff all are correct.
    // Exercises: a generic struct instantiated across a module boundary (#6),
    // `list::make` colliding with `heap::make`, and field types resolving in the
    // module that defines `List`.
    const code = try compileFileAndRun(
        arena.allocator(),
        "tests/fixtures/stdlib/list_app.gab",
        "exe_list_app",
    );
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: generic struct built inside a generic body resolves the concrete instance (issue #6)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Regression for issue #6: a `Box(T)` constructed/read inside an INSTANTIATED
    // generic body must lower to the concrete instance `Box__T_i32` (field
    // `value: i32`), not the template `Box` (whose `T`-typed field is opaque).
    // Before the fix this emitted `insertvalue %Box undef, i32 %v, 0` (invalid) /
    // a `ptr`-indexed GEP and failed LLVM verification.
    const code = try compileAndRun(arena.allocator(),
        \\Box :: struct($T: type) { value: T }
        \\box_make :: fn($T: type, v: T) -> Box(T) { r: Box(T) = .{ v }; return r; }
        \\box_get  :: fn($T: type, b: *Box(T)) -> T { return b.value; }
        \\main :: fn() -> i32 { b := box_make(i32, 42); return box_get(i32, &b); }
    , "exe_generic_struct_instance");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: generic-struct compound literal at a concrete instantiation in a non-generic fn" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The non-generic-context variant of issue #6: a local `p: Pair(i32) = .{...}`
    // (or a field of named type, `Pair(Point)`) declared directly in a NON-generic
    // function must resolve to the materialized instance struct (`Pair__T_i32`), not
    // the bare template `Pair`. Before the fix, `lowerAstTypeWithEnv` had no
    // `generic_inst` case, so the local typed as the template (opaque `T` fields) →
    // the compound literal lowered to `store %Pair zeroinitializer` (silently
    // dropping the field values) and `%Pair(i32)` failed LLVM verification.
    // Checks the field values round-trip: 3+4 (scalar arg) + 1+2+3+4 (named arg) = 17.
    const code = try compileAndRun(arena.allocator(),
        \\Point :: struct { x: i32, y: i32 }
        \\Pair :: struct($T: type) { a: T, b: T }
        \\main :: fn() -> i32 {
        \\    p: Pair(i32) = .{ 3, 4 };
        \\    q: Pair(Point) = .{ .{1,2}, .{3,4} };
        \\    return p.a + p.b + q.a.x + q.a.y + q.b.x + q.b.y;
        \\}
    , "exe_generic_struct_literal_nongeneric");
    try std.testing.expectEqual(@as(u32, 17), code);
}

test "exe: `==`/`!=` on `[]const u8` compares contents" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `s == t` on string slices used to lower to `icmp eq { ptr, i64 }` — an
    // aggregate compare LLVM rejects. Now it compares CONTENTS: length first,
    // then byte-wise (the match string-pattern lowering). Covers literal==literal
    // (`"a"=="a"` true, `"a"=="b"` false, `"ab"=="a"` false — different length),
    // local-vs-literal both orders, local-vs-local (dynamic loop), and `!=`.
    // The boolean checks dodge the 8-bit exit-code truncation; failure pinpoints.
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    if !("a" == "a") { return 2; }
        \\    if   "a" == "b"  { return 3; }
        \\    if   "ab" == "a" { return 4; }
        \\    if   "a" != "a"  { return 5; }
        \\    if !("a" != "b") { return 6; }
        \\    a: []const u8 = "abc";
        \\    b: []const u8 = "abc";
        \\    c: []const u8 = "abd";
        \\    d: []const u8 = "ab";
        \\    if !(a == b)    { return 7; }   // local == local, equal
        \\    if   a == c     { return 8; }   // same length, last byte differs
        \\    if   a == d     { return 9; }   // different length
        \\    if !(a == "abc"){ return 10; }  // local == literal
        \\    if !("abc" == a){ return 11; }  // literal == local
        \\    if !(a != c)    { return 12; }  // != differing
        \\    if   a != b     { return 13; }  // != equal
        \\    return 1;
        \\}
    , "exe_string_eq");
    try std.testing.expectEqual(@as(u32, 1), code);
}

test "exe: `[]const u8` `==` folds at compile time (`#run` / `#compiler` use)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The comptime VM runs the same IR, so string `==` must fold there too — a
    // `#compiler` hook does `if d.derives == "Sum"`. `cmp` (one literal operand →
    // `lowerStringEq`) and `cmp2` (both operands runtime → the dynamic loop) both
    // fold via `#run`. 8-bit exit code is fine here (all values < 256).
    const code = try compileAndRun(arena.allocator(),
        \\cmp  :: fn(s: []const u8) -> i32 { if s == "Sum" { return 42; } return 0; }
        \\cmp2 :: fn(a: []const u8, b: []const u8) -> i32 { if a == b { return 7; } return 0; }
        \\HIT  :: #run cmp("Sum");            // 42  (literal path)
        \\MISS :: #run cmp("Nope");           // 0
        \\EQ   :: #run cmp2("hello", "hello");// 7   (dynamic path)
        \\NE   :: #run cmp2("hello", "world");// 0
        \\LEN  :: #run cmp2("hi", "hello");   // 0   (different length)
        \\main :: fn() -> i32 {
        \\    if HIT != 42 { return 2; }
        \\    if MISS != 0 { return 3; }
        \\    if EQ != 7   { return 4; }
        \\    if NE != 0   { return 5; }
        \\    if LEN != 0  { return 6; }
        \\    return 1;
        \\}
    , "exe_string_eq_comptime");
    try std.testing.expectEqual(@as(u32, 1), code);
}

// Comptime test lane (#test)

test "exe: passing #test compiles and the program runs" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `Test` is auto-injected, so a `#test` needs no import. The assertions run on
    // the comptime VM during compilation; all pass, so the build succeeds and the
    // (test-free) program runs normally. The test fns are pruned before codegen.
    const code = try compileAndRun(arena.allocator(),
        \\#test
        \\arithmetic :: fn(t: *Test) {
        \\    t.eq(2 + 2, 4);
        \\    t.ne(2 + 2, 5);
        \\    t.expect((1 + 2) + 3 == 1 + (2 + 3));
        \\}
        \\main :: fn() -> i32 { return 7; }
    , "exe_ctest_pass");
    try std.testing.expectEqual(@as(u32, 7), code);
}

test "exe: failing #test fails the build" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A failed comptime assertion is a compile error — exactly like a type error.
    // The whole compilation fails; no executable is produced.
    try std.testing.expectError(error.CompileFailed, compileAndRun(arena.allocator(),
        \\#test
        \\broken :: fn(t: *Test) {
        \\    t.eq(2 + 2, 5);
        \\}
        \\main :: fn() -> i32 { return 0; }
    , "exe_ctest_fail"));
}

test "exe: t.fatal fails the build with its message" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.CompileFailed, compileAndRun(arena.allocator(),
        \\#test
        \\always :: fn(t: *Test) {
        \\    t.fatal("explicit failure");
        \\}
        \\main :: fn() -> i32 { return 0; }
    , "exe_ctest_fatal"));
}

test "exe: t.eq/t.ne compare []const u8 contents at comptime" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The generic `eq`/`ne` (V = []const u8) must run the content compare on the
    // VM — a regression guard for the type-binding resolution in `exprType`.
    const code = try compileAndRun(arena.allocator(),
        \\#test
        \\strings :: fn(t: *Test) {
        \\    t.eq("hello", "hello");
        \\    t.ne("hello", "world");
        \\}
        \\main :: fn() -> i32 { return 3; }
    , "exe_ctest_strings");
    try std.testing.expectEqual(@as(u32, 3), code);
}

test "exe: a wrong comptime string t.eq fails the build" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.CompileFailed, compileAndRun(arena.allocator(),
        \\#test
        \\wrong :: fn(t: *Test) { t.eq("abc", "xyz"); }
        \\main :: fn() -> i32 { return 0; }
    , "exe_ctest_str_fail"));
}

test "exe: generic []const u8 == folds in a #run (binding-resolved)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The latent bug behind the test failure: a generic function comparing two
    // `$V = []const u8` values lowered to a scalar compare on the fat slice, so
    // the comptime VM couldn't evaluate it. The instantiation binding must reach
    // the `==` lowering. 8-bit exit codes are fine (values < 256).
    const code = try compileAndRun(arena.allocator(),
        \\geq :: fn(a: $V, b: $V) -> bool { return a == b; }
        \\SAME :: #run geq("abc", "abc");   // true
        \\DIFF :: #run geq("abc", "xyz");   // false
        \\main :: fn() -> i32 {
        \\    if SAME == false { return 1; }
        \\    if DIFF { return 2; }
        \\    return 7;
        \\}
    , "exe_generic_streq_run");
    try std.testing.expectEqual(@as(u32, 7), code);
}

// Named struct literals + default field values

test "exe: named struct literal, fields out of order" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\P :: struct { x: i32, y: i32 }
        \\main :: fn() -> i32 { p: P = .{ .y = 20, .x = 22 }; return p.x + p.y; }
    , "exe_named_lit");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: named literal omits a defaulted field" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\P :: struct { x: i32, y: i32 = 100 }
        \\main :: fn() -> i32 { p: P = .{ .x = 5 }; return p.x + p.y; }
    , "exe_named_default");
    try std.testing.expectEqual(@as(u32, 105), code);
}

test "exe: default fields fill .{} and trailing positions" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `.{ 5 }` supplies `a`, `b` falls back to its default 50.
    const code = try compileAndRun(arena.allocator(),
        \\P :: struct { a: i32, b: i32 = 50 }
        \\main :: fn() -> i32 { p: P = .{ 5 }; return p.a + p.b; }
    , "exe_default_trailing");
    try std.testing.expectEqual(@as(u32, 55), code);
}

test "exe: unknown field in a struct literal fails the build" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.LoweringFailed, compileAndRun(arena.allocator(),
        \\P :: struct { x: i32, y: i32 }
        \\main :: fn() -> i32 { p: P = .{ .x = 1, .z = 2 }; return p.x; }
    , "exe_named_unknown"));
}

test "exe: missing required field (no default) fails the build" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.LoweringFailed, compileAndRun(arena.allocator(),
        \\P :: struct { x: i32, y: i32 }
        \\main :: fn() -> i32 { p: P = .{ .x = 1 }; return p.x; }
    , "exe_named_missing"));
}

// Calling interface methods on the implementing / constrained type

test "exe: interface method called directly on the implementing type" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\Calc :: interface { add :: fn(self: *Self, x: i32) -> i32; base :: fn(self: *Self) -> i32; }
        \\Acc :: struct { n: i32 }
        \\Acc as Calc {
        \\    add  :: fn(self: *Self, x: i32) -> i32 { return self.n + x; }
        \\    base :: fn(self: *Self) -> i32 { return self.n; }
        \\}
        \\main :: fn() -> i32 { a: Acc = .{ 10 }; return a.add(5) + a.base(); }   // 15 + 10
    , "exe_iface_method_direct");
    try std.testing.expectEqual(@as(u32, 25), code);
}

test "exe: interface method on a $T: Iface-constrained generic" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\Show :: interface { val :: fn(self: *Self) -> i32; }
        \\needs :: fn($T: Show, x: *T) -> i32 { return x.val(); }
        \\Good :: struct { z: i32 }
        \\Good as Show { val :: fn(self: *Self) -> i32 { return self.z; } }
        \\main :: fn() -> i32 { g: Good = .{ 9 }; return needs(&g); }
    , "exe_iface_method_constrained");
    try std.testing.expectEqual(@as(u32, 9), code);
}

test "exe: where T: Iface clause (single + multiple bounds)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\Show :: interface { val :: fn(self: *Self) -> i32; }
        \\one  :: fn($T, x: *T) -> i32 where T: Show { return x.val(); }
        \\both :: fn($T, $U, a: *T, b: *U) -> i32 where T: Show, U: Show { return a.val() + b.val(); }
        \\A :: struct { z: i32 }
        \\A as Show { val :: fn(self: *Self) -> i32 { return self.z; } }
        \\B :: struct { w: i32 }
        \\B as Show { val :: fn(self: *Self) -> i32 { return self.w; } }
        \\main :: fn() -> i32 { a: A = .{ 10 }; b: B = .{ 5 }; return one(&a) + both(&a, &b); }
    , "exe_where_clause");
    try std.testing.expectEqual(@as(u32, 25), code);
}

test "exe: where T: Iface rejects a non-conforming type" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.CompileFailed, compileAndRun(arena.allocator(),
        \\Show :: interface { val :: fn(self: *Self) -> i32; }
        \\needs :: fn($T, x: *T) -> i32 where T: Show { return x.val(); }
        \\Bad :: struct { z: i32 }
        \\main :: fn() -> i32 { b: Bad = .{ 3 }; return needs(&b); }
    , "exe_where_nonconforming"));
}

test "exe: $T: Iface still rejects a non-conforming type" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.CompileFailed, compileAndRun(arena.allocator(),
        \\Show :: interface { val :: fn(self: *Self) -> i32; }
        \\needs :: fn($T: Show, x: *T) -> i32 { return x.val(); }
        \\Bad :: struct { z: i32 }
        \\main :: fn() -> i32 { b: Bad = .{ 3 }; return needs(&b); }
    , "exe_iface_nonconforming"));
}

// Struct equality + interface-through-interface dispatch

test "exe: struct == compares field by field (nested + string fields)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\Inner :: struct { a: i32, name: []const u8 }
        \\Outer :: struct { p: Inner, n: i32 }
        \\main :: fn() -> i32 {
        \\    x: Outer = .{ .p = .{ .a = 1, .name = "hi" }, .n = 3 };
        \\    y: Outer = .{ .p = .{ .a = 1, .name = "hi" }, .n = 3 };
        \\    z: Outer = .{ .p = .{ .a = 1, .name = "bye" }, .n = 3 };
        \\    if x != y { return 1; }
        \\    if x == z { return 2; }   // differs in the nested string field
        \\    return 7;
        \\}
    , "exe_struct_eq");
    try std.testing.expectEqual(@as(u32, 7), code);
}

test "exe: struct == folds at comptime (#run)" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\P :: struct { x: i32, y: i32 }
        \\cmp :: fn() -> i32 { a: P = .{ 3, 4 }; b: P = .{ 3, 4 }; if a == b { return 11; } return 0; }
        \\R :: #run cmp();
        \\main :: fn() -> i32 { return R; }
    , "exe_struct_eq_comptime");
    try std.testing.expectEqual(@as(u32, 11), code);
}

test "exe: interface-through-interface dispatch" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A method on `*Wrapper` (interface) calls a method on a `*Display`
    // (interface) argument — previously an LLVM verification error.
    const code = try compileAndRun(arena.allocator(),
        \\Display :: interface { fmt :: fn(self: *Self) -> i32; }
        \\Wrapper :: interface { wrap :: fn(self: *Self, d: *Display) -> i32; }
        \\Num :: struct { v: i32 }
        \\Num as Display { fmt :: fn(self: *Self) -> i32 { return self.v; } }
        \\Box :: struct { mul: i32 }
        \\Box as Wrapper { wrap :: fn(self: *Self, d: *Display) -> i32 { return d.fmt() * self.mul; } }
        \\main :: fn() -> i32 {
        \\    n: Num = .{ 7 };
        \\    b: Box = .{ 6 };
        \\    w: *Wrapper = &b;
        \\    d: *Display = &n;
        \\    return w.wrap(d);
        \\}
    , "exe_iface_thru_iface");
    try std.testing.expectEqual(@as(u32, 42), code);
}

test "exe: array and slice == compare elementwise" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\sliceq :: fn(a: []const i32, b: []const i32) -> bool { return a == b; }
        \\S :: struct { v: [2]i32, n: i32 }
        \\main :: fn() -> i32 {
        \\    a: [3]i32 = .{ 1, 2, 3 };
        \\    b: [3]i32 = .{ 1, 2, 3 };
        \\    if a != b { return 1; }                 // array ==
        \\    x: S = .{ .v = .{ 4, 5 }, .n = 6 };
        \\    y: S = .{ .v = .{ 4, 5 }, .n = 6 };
        \\    if x != y { return 2; }                 // struct with array field
        \\    if sliceq(a[:], b[:]) == false { return 3; }  // []i32 ==
        \\    return 8;
        \\}
    , "exe_array_slice_eq");
    try std.testing.expectEqual(@as(u32, 8), code);
}

test "exe: payload-enum == .variant dispatches by discriminant" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\E :: enum { a, b, c: i32 }
        \\main :: fn() -> i32 {
        \\    x := E.b;
        \\    if x == .a { return 1; }
        \\    if x != .b { return 2; }
        \\    return 9;
        \\}
    , "exe_enum_variant_eq");
    try std.testing.expectEqual(@as(u32, 9), code);
}

test "exe: two payload-enum values compare by variant + scalar payload" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\E :: enum { a, b, c: i32 }
        \\main :: fn() -> i32 {
        \\    if E.c(5) != E.c(5) { return 1; }   // same variant + payload
        \\    if E.c(5) == E.c(9) { return 2; }   // same variant, different payload
        \\    if E.a == E.b { return 3; }         // different variant
        \\    return 8;
        \\}
    , "exe_enum_two_values");
    try std.testing.expectEqual(@as(u32, 8), code);
}

test "exe: comparing enum values with non-scalar payloads is a clean error" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // A clear diagnostic ("use `match`"), not an LLVM crash or garbage-memory read.
    try std.testing.expectError(error.LoweringFailed, compileAndRun(arena.allocator(),
        \\E :: enum { a, s: []const u8 }
        \\main :: fn() -> i32 { x := E.s("hi"); y := E.s("hi"); if x == y { return 1; } return 0; }
    , "exe_enum_agg_payload"));
}

// Operator precedence & chaining (locked for 0.1.0)

test "exe: operator precedence ladder is stable" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const code = try compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 {
        \\    if (1 << 3 > 3) == false { return 1; }  // shift tighter than `>`: (1<<3)>3
        \\    if (6 & 2 == 2) == false { return 2; }  // `&` tighter than `==`: (6&2)==2 (fixes C wart)
        \\    if 1 + 1 << 2 != 8 { return 3; }        // `+` tighter than `<<`: (1+1)<<2
        \\    if 1 << 2 << 1 != 8 { return 4; }        // `<<` left-associative
        \\    return 9;
        \\}
    , "exe_precedence");
    try std.testing.expectEqual(@as(u32, 9), code);
}

test "exe: chained comparison is rejected, not silently misparsed" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `(1 < 2) < 3` would compare a bool to an int — rejected, so the C footgun
    // (`1<2<3` quietly becoming `true<3`) can't fire.
    try std.testing.expectError(error.CompileFailed, compileAndRun(arena.allocator(),
        \\main :: fn() -> i32 { b := 1 < 2 < 3; if b { return 1; } return 0; }
    , "exe_chained_cmp"));
}

test "exe: a const with an expression initializer folds to its value" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Regression: `lowerImm` only produced an `Imm` for a direct literal and
    // mapped everything else to `.null`, so a const whose initializer was any
    // expression (`W * 3`, or even a plain alias `:: W`) was emitted with a
    // zero initializer and silently read back as 0 at runtime. Each mismatch
    // returns its own code so a failure says which form broke.
    const code = try compileAndRun(arena.allocator(),
        \\W      :: 8;
        \\STRIDE :: W * 3;
        \\ALIAS  :: STRIDE;
        \\FOLDED :: 5 * 4;
        \\main :: fn() -> i32 {
        \\    if STRIDE != 24 { return 10; }        // const over another const
        \\    if ALIAS != 24 { return 20; }         // const aliasing a const
        \\    if FOLDED != 20 { return 30; }        // const over two literals
        \\    if STRIDE * 2 != 48 { return 40; }    // and usable in arithmetic
        \\    return 0;
        \\}
    , "exe_const_expr_init");
    try std.testing.expectEqual(@as(u32, 0), code);
}

test "exe: constants fold through a chain of constants" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Regression: `buildCache` lowers the module with `cvm = null` to break the
    // recursion back into the VM, and that path fell back to `lowerImm` — so a
    // const whose initializer was an expression was zero *inside the module the
    // VM reads constants from*. One level survived (the outer VM folded it),
    // but two or more read the stale zero: `B :: A * 3; C :: B;` gave 0, and in
    // arithmetic it was a `ptr` ICE rather than a value.
    const code = try compileAndRun(arena.allocator(),
        \\A     :: 8;
        \\B     :: A * 3;
        \\C     :: B;
        \\D     :: C * 2;
        \\E     :: D + A;
        \\FL    :: 1.5;
        \\FL2   :: FL * 4.0;
        \\FLAG  :: A > 4;
        \\BITS  :: (A >> 1) | 1;
        \\main :: fn() -> i32 {
        \\    if C != 24 { return 10; }         // depth 2
        \\    if D != 48 { return 20; }         // depth 3
        \\    if E != 56 { return 30; }         // depth 4
        \\    if C - 24 != 0 { return 40; }     // and in arithmetic, not just ==
        \\    if FL2 != 6.0 { return 50; }      // floats fold too
        \\    if FLAG == false { return 60; }   // and comparisons
        \\    if BITS != 5 { return 70; }       // and bitwise
        \\    return 0;
        \\}
    , "exe_const_chain");
    try std.testing.expectEqual(@as(u32, 0), code);
}

test "exe: a bare `.variant` in a struct literal keeps its variant" {
    if (comptime !gabbro.llvm_enabled) return error.SkipZigTest;
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Regression: the expected type was pushed into a bare `.variant` for a
    // typed local, an assignment and a call argument, but never into a struct
    // literal's field positions — so `.glass` in a field silently lowered as
    // variant 0 (`.lambert`) with no diagnostic.
    const code = try compileAndRun(arena.allocator(),
        \\Mat :: enum { lambert, metal, glass }
        \\S :: struct { r: i32, mat: Mat }
        \\rank :: fn(s: S) -> i32 {
        \\    match s.mat {
        \\        .lambert => { return 1; }
        \\        .metal   => { return 2; }
        \\        .glass   => { return 3; }
        \\    }
        \\}
        \\mk :: fn() -> S { return .{ 7, .glass }; }
        \\main :: fn() -> i32 {
        \\    pos: S = .{ 1, .metal };
        \\    if rank(pos) != 2 { return 10; }              // positional literal
        \\    named: S = .{ .r = 1, .mat = .glass };
        \\    if rank(named) != 3 { return 20; }            // named-field literal
        \\    if rank(mk()) != 3 { return 30; }             // return position
        \\    if rank(.{ 1, .glass }) != 3 { return 40; }   // argument position
        \\    slot: S = .{ 1, .lambert };
        \\    slot = .{ 1, .metal };
        \\    if rank(slot) != 2 { return 50; }             // assignment position
        \\    return 0;
        \\}
    , "exe_enum_in_struct_literal");
    try std.testing.expectEqual(@as(u32, 0), code);
}
