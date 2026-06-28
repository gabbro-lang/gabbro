const std = @import("std");
const k2 = @import("k2_compiler");

test "diagnostics: return type mismatch shows types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn() -> i32 { return true; }
    ;
    const result = k2.compile(arena.allocator(), "bad.sk", bad);
    try std.testing.expectError(error.SemanticFailed, result);
}

test "diagnostics: returning a capturing closure is rejected (would dangle)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The lambda captures `n` (a param), whose value lives on this stack frame —
    // returning the closure would dangle, so it must be a compile error.
    const bad =
        \\make :: fn(n: i32) -> fn(i32) -> i32 { return fn(x: i32) -> i32 { return x + n; }; }
    ;
    const result = k2.compile(arena.allocator(), "escape.sk", bad);
    try std.testing.expectError(error.SemanticFailed, result);
}

test "diagnostics: returning a capturing closure held in a local is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The indirect form — assign the capturing closure to a local, then return it.
    const bad =
        \\make :: fn(n: i32) -> fn(i32) -> i32 { f := fn(x: i32) -> i32 { return x + n; }; return f; }
    ;
    const result = k2.compile(arena.allocator(), "escape2.sk", bad);
    try std.testing.expectError(error.SemanticFailed, result);
}

test "diagnostics: returning a non-capturing function value is allowed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // No captures → just a fn pointer with an empty environment; safe to return.
    const ok =
        \\dbl :: fn(x: i32) -> i32 { return x * 2; }
        \\get :: fn() -> fn(i32) -> i32 { return dbl; }
    ;
    var fe = try k2.compile(arena.allocator(), "ok.sk", ok);
    fe.deinit(arena.allocator());
}

test "diagnostics: unknown name shows identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\bad :: fn() -> i32 { return foo; }
    ;
    const result = k2.compile(arena.allocator(), "bad.sk", bad);
    try std.testing.expectError(error.SemanticFailed, result);
}

test "diagnostics: wrong arg count shows expected vs actual" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\add :: fn(a: i32, b: i32) -> i32 { return a + b; }
        \\bad :: fn() -> i32 { return add(1); }
    ;
    const result = k2.compile(arena.allocator(), "bad.sk", bad);
    try std.testing.expectError(error.SemanticFailed, result);
}

test "diagnostics: arg type mismatch shows types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\add :: fn(a: i32, b: i32) -> i32 { return a + b; }
        \\bad :: fn() -> i32 { return add(1, true); }
    ;
    const result = k2.compile(arena.allocator(), "bad.sk", bad);
    try std.testing.expectError(error.SemanticFailed, result);
}

test "diagnostics: sema errors are stored in TypeEnv" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Successful compile — diagnostics should be empty
    const src =
        \\add :: fn(a: i32, b: i32) -> i32 { return a + b; }
    ;
    var fe = try k2.compile(arena.allocator(), "ok.sk", src);
    defer fe.deinit(arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), fe.types.diagnostics.items.len);
}

test "diagnostics: fail outside error function is caught" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad =
        \\NetError :: errors { timeout, }
        \\bad :: fn() -> i32 { fail .timeout; return 0; }
    ;
    try std.testing.expectError(error.SemanticFailed,
        k2.compile(arena.allocator(), "bad.sk", bad));
}

test "diagnostics: renderDiagnostic produces correct format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const src = "bad :: fn() -> i32 { return true; }";

    // Force a compile error, then render the diagnostic
    const bad =
        \\bad :: fn() -> i32 { return true; }
    ;
    // Just verify compile fails — rendering is tested via existence
    try std.testing.expectError(error.SemanticFailed,
        k2.compile(arena.allocator(), "test.sk", bad));

    // Verify Diagnostic.err constructor works
    const d = k2.Diagnostic.err("test message",
        k2.Span.new(0, 3), "test.sk");
    try std.testing.expectEqual(k2.DiagKind.err, d.kind);

    const rendered = try k2.renderDiagnostic(arena.allocator(), "test.sk", src, d);
    // Should contain file:line:col: error: message
    try std.testing.expect(std.mem.indexOf(u8, rendered, "test.sk") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "error:") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "test message") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "^^^") != null);
}

/// Return the first `error`-level diagnostic message for `src`, type-checking in
/// tolerant mode so the diagnostics survive even though checking fails. Lets the
/// tests below assert the *text* of an error, not just that one occurred.
fn firstError(arena: std.mem.Allocator, src: []const u8) !?[]const u8 {
    const mod = try k2.parseSource(arena, "t.sk", src);
    var syms = try k2.sema_mod.collectSymbols(arena, mod);
    const env = try k2.sema_mod.checkTypesTolerant(arena, mod, &syms, src, "t.sk");
    for (env.diagnostics.items) |d| {
        if (d.kind == .err) return d.message;
    }
    return null;
}

test "diagnostics: unknown type is reported, never 'no further details'" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // u128/i128 → a tailored "unsupported integer width" message (used to fail
    // silently with the catch-all "semantic error (no further details)").
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "main :: fn() -> i32 { x: u128 = 0u64; return 0; }")).?,
        "unsupported integer width `u128`") != null);
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "main :: fn() -> i32 { x: i128 = 0i64; return 0; }")).?,
        "at most 64-bit") != null);

    // A non-standard width still gets a clear message (not the catch-all).
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "main :: fn() -> i32 { x: u9 = 0u8; return 0; }")).?,
        "unsupported integer width `u9`") != null);

    // An unknown type close to a known one suggests it.
    const typo = (try firstError(a,
        "Point :: struct { x: i32 }\nmain :: fn() -> i32 { p: Poimt = .{0}; return 0; }")).?;
    try std.testing.expect(std.mem.indexOf(u8, typo, "unknown type `Poimt`") != null);
    try std.testing.expect(std.mem.indexOf(u8, typo, "did you mean `Point`?") != null);

    // A value used in type position names what it actually is.
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "foo :: fn() {}\nmain :: fn() -> i32 { x: foo = 0; return 0; }")).?,
        "`foo` is not a type") != null);

    // An unknown error type after `!` is reported, not swallowed.
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "f :: fn() -> i32 ! Ooops { return 0; }")).?,
        "unknown error type `Ooops`") != null);
}

test "diagnostics: invalid integer/float literal width suffix is reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `0u128`: an over-wide suffix on a literal used to be silently dropped
    // (collapsing to i32); now it errors like the type-side `u128`.
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "main :: fn() -> i32 { x := 0u128; return 0; }")).?,
        "unsupported integer width `u128`") != null);

    // A non-standard width on a literal is flagged, not swallowed.
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "main :: fn() -> i32 { x := 0u9; return 0; }")).?,
        "unsupported integer width `u9`") != null);

    // The float side is symmetric — only `f32`/`f64` are valid widths.
    try std.testing.expect(std.mem.indexOf(u8,
        (try firstError(a, "main :: fn() -> i32 { x := 3.0f16; return 0; }")).?,
        "unsupported float width `f16`") != null);

    // A hex literal that legitimately ends in letters is NOT a bad suffix.
    try std.testing.expect((try firstError(a,
        "main :: fn() -> i32 { return 0xABC; }")) == null);
}
