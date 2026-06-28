const std = @import("std");
const ast = @import("ast.zig");
const Span = @import("lexer/span.zig").Span;
const diag_mod = @import("diagnostic.zig");
const Diagnostic = diag_mod.Diagnostic;
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const macroexpand = @import("macroexpand.zig");
const ast_prelude = @import("ast_prelude.zig");
const ir_mod = @import("ir.zig");

/// Node-id base for prelude nodes — high enough to never collide with a real
/// program's ids (which start at 1 and increment per parsed node).
const prelude_id_base: ast.NodeId = 900_000;
const runtime = @import("runtime.zig");
const std_prelude = @import("std_prelude.zig");
const build_options = @import("build_options");

/// Node-id bases for the embedded std.heap/std.ptr prelude. High enough not to
/// collide with a real program's ids (which start at 1), and below the ast.*
/// prelude base (900_000); ptr is parsed first and heap chains off its next id.
const heap_prelude_id_base: ast.NodeId = 600_000;
/// Node-id base for the injected `TypeInfo` reflection prelude (distinct range).
const reflection_prelude_id_base: ast.NodeId = 500_000;
const any_prelude_id_base: ast.NodeId = 400_000;
const fieldnav_prelude_id_base: ast.NodeId = 300_000;
/// Node-id base for the injected `Test` testing prelude (distinct range).
const testing_prelude_id_base: ast.NodeId = 200_000;

pub const FrontEnd = struct {
    module: ast.Module,
    symbols: sema.SymbolTable,
    types: sema.TypeEnv,
    arena: *std.heap.ArenaAllocator,

    pub fn deinit(self: *FrontEnd, allocator: std.mem.Allocator) void {
        const arena_allocator = self.arena.allocator();
        self.symbols.deinit(arena_allocator);
        self.types.deinit(arena_allocator);
        self.arena.deinit();
        allocator.destroy(self.arena);
    }

    /// Any sema diagnostics collected during compilation.
    pub fn diagnostics(self: *const FrontEnd) []const Diagnostic {
        return self.types.diagnostics.items;
    }
};

pub const SourceFile = struct {
    file_name: []const u8,
    source: []const u8,
};

pub const CompileError = error{
    ParseFailed,
    SemanticFailed,
    IoError,
    RuntimeUnavailable,
    OutOfMemory,
};

/// Runtime override for the standard-library root (the directory containing
/// `std/`). `null` → use the build-baked `build_options.stdlib_root`. The CLI
/// resolves this from an installed/dev layout (`--std-path`, `$K2_STD`,
/// `$K2_HOME/lib`, or exe-relative) so one binary finds its stdlib wherever it
/// lands. Set once at startup; the compiler is single-threaded per build.
pub var stdlib_root_override: ?[]const u8 = null;

// ── Public entry points ───────────────────────────────────────────────────────

/// Compile source text directly (no file I/O).
/// Does NOT include the runtime — used by tests and library consumers.
/// Use compileWithLlvm() in driver.zig for programs that need @panic/assert.
pub fn compile(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source: []const u8,
) CompileError!FrontEnd {
    const arena = try createFrontendArena(allocator);
    errdefer destroyFrontendArena(allocator, arena);
    const fe_allocator = arena.allocator();
    const module = parser.parseSource(fe_allocator, file_name, source) catch |err| switch (err) {
        error.ParseFailed => return error.ParseFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return runPipelineWithSource(fe_allocator, module, source, file_name, arena);
}

/// Compile source with the embedded platform runtime prepended.
/// This is what driver.compileWithLlvm() uses for real programs.
pub fn compileWithRuntime(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source: []const u8,
) CompileError!FrontEnd {
    return compileWithRuntimeTarget(allocator, file_name, source, @import("builtin").os.tag, false);
}

/// Like `compileWithRuntime`, but for an explicit target OS (cross-compilation):
/// selects that platform's embedded runtime. `link_libc` picks the glibc entry
/// point on Linux (the `linux-gnu` ABI).
pub fn compileWithRuntimeTarget(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source: []const u8,
    target_os: std.Target.Os.Tag,
    link_libc: bool,
) CompileError!FrontEnd {
    const rt_src = runtime.runtimeSourceFor(target_os, link_libc) orelse return error.RuntimeUnavailable;
    return compileMulti(allocator, &.{
        .{ .file_name = "<runtime>", .source = rt_src },
        .{ .file_name = file_name, .source = source },
    });
}

/// Compile multiple source texts at once (no file I/O).
pub fn compileMulti(allocator: std.mem.Allocator, files: []const SourceFile) CompileError!FrontEnd {
    const arena = try createFrontendArena(allocator);
    errdefer destroyFrontendArena(allocator, arena);
    const fe_allocator = arena.allocator();

    if (files.len == 0) return runPipelineWithSource(fe_allocator, ast.Module.empty(""), "", "", arena);

    var all_items: std.ArrayList(ast.Item) = .empty;
    errdefer all_items.deinit(fe_allocator);
    var modules: std.ArrayList(ast.Module) = .empty;
    defer modules.deinit(fe_allocator);
    var available = std.StringHashMap(void).init(fe_allocator);
    defer available.deinit();

    var next_id: ast.NodeId = 1;
    for (files) |file| {
        const normalized_name = normalizeLogicalPath(fe_allocator, file.file_name) catch return error.OutOfMemory;
        if (available.contains(normalized_name)) {
            std.debug.print("{s}: error: module was provided more than once\n", .{normalized_name});
            return error.IoError;
        }
        const parsed = parser.parseSourceFrom(fe_allocator, normalized_name, file.source, next_id) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        };
        next_id = parsed.next_id;
        try modules.append(fe_allocator, parsed.module);
        try available.put(normalized_name, {});
    }
    for (modules.items) |parsed_module| {
        const dir = std.fs.path.dirname(parsed_module.file_name) orelse ".";
        for (parsed_module.items) |item| switch (item) {
            .import => |imp| {
                const resolved = resolveImportPath(fe_allocator, dir, imp.path, null) catch return error.IoError;
                const normalized = normalizeLogicalPath(fe_allocator, resolved) catch return error.OutOfMemory;
                if (!available.contains(normalized)) {
                    std.debug.print("{s}: error: imported module `{s}` was not provided\n", .{ imp.file_name, normalized });
                    return error.IoError;
                }
                var resolved_import = imp;
                resolved_import.resolved_file = normalized;
                try all_items.append(fe_allocator, .{ .import = resolved_import });
            },
            else => try all_items.append(fe_allocator, item),
        };
    }

    const items = try all_items.toOwnedSlice(fe_allocator);
    // The root file (whose name/source drive sema visibility and prelude
    // injection) is the user's, not the embedded runtime prepended ahead of it.
    var root: usize = 0;
    if (std.mem.eql(u8, modules.items[0].file_name, "<runtime>") and modules.items.len > 1) root = 1;
    return runPipelineWithSource(fe_allocator, .{ .file_name = modules.items[root].file_name, .items = items }, files[root].source, modules.items[root].file_name, arena);
}

/// Compile a .k2 file from disk, resolving `#import` declarations recursively.
/// Requires an `std.Io` instance (Zig 0.16 explicit I/O).
pub fn compileFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) CompileError!FrontEnd {
    return compileFileInternal(allocator, io, path, false, @import("builtin").os.tag, false);
}

/// Compile a .k2 file and its imports with the embedded platform runtime.
pub fn compileFileWithRuntime(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) CompileError!FrontEnd {
    return compileFileWithRuntimeTarget(allocator, io, path, @import("builtin").os.tag, false);
}

/// Like `compileFileWithRuntime`, but for an explicit target OS.
pub fn compileFileWithRuntimeTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    target_os: std.Target.Os.Tag,
    link_libc: bool,
) CompileError!FrontEnd {
    return compileFileInternal(allocator, io, path, true, target_os, link_libc);
}

fn compileFileInternal(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    include_runtime: bool,
    target_os: std.Target.Os.Tag,
    link_libc: bool,
) CompileError!FrontEnd {
    const arena = try createFrontendArena(allocator);
    errdefer destroyFrontendArena(allocator, arena);
    const fe_allocator = arena.allocator();

    var loaded = std.StringHashMap(void).init(fe_allocator);
    defer loaded.deinit();

    var all_items: std.ArrayList(ast.Item) = .empty;
    errdefer all_items.deinit(fe_allocator);

    var root_source: []const u8 = "";
    var next_id: ast.NodeId = 1;

    if (include_runtime) {
        const rt_src = runtime.runtimeSourceFor(target_os, link_libc) orelse return error.RuntimeUnavailable;
        const parsed = parser.parseSourceFrom(fe_allocator, "<runtime>", rt_src, next_id) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        };
        next_id = parsed.next_id;
        for (parsed.module.items) |item| switch (item) {
            .import => {},
            else => try all_items.append(fe_allocator, item),
        };
    }

    loadFile(fe_allocator, io, path, &loaded, &all_items, &next_id, &root_source, true) catch |err| switch (err) {
        error.ParseFailed => return error.ParseFailed,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.IoError,
    };

    const items = try all_items.toOwnedSlice(fe_allocator);
    return runPipelineWithSource(fe_allocator, .{ .file_name = path, .items = items }, root_source, path, arena);
}

// ── Internal helpers ──────────────────────────────────────────────────────────

fn loadFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    loaded: *std.StringHashMap(void),
    all_items: *std.ArrayList(ast.Item),
    next_id: *ast.NodeId,
    root_source: *[]const u8,
    is_root: bool,
) !void {
    if (loaded.contains(path)) return;
    try loaded.put(path, {});

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| {
        std.debug.print("{s}: error: cannot read imported module: {s}\n", .{ path, @errorName(err) });
        // A missing `std/...` module almost always means the compiler can't find
        // its standard library — point the user at the relocation knobs.
        if (std.mem.indexOf(u8, path, "std") != null) {
            std.debug.print("  hint: the k2 standard library wasn't found at this path. " ++
                "Set K2_HOME to your k2 install dir, or pass --std-path <dir-containing-std>.\n", .{});
        }
        return err;
    };
    if (is_root) root_source.* = source;

    const parsed = try parser.parseSourceFrom(allocator, path, source, next_id.*);
    next_id.* = parsed.next_id;

    // Retain the import edge for visibility checking, then load the dependency.
    const dir = std.fs.path.dirname(path) orelse ".";
    for (parsed.module.items) |item| {
        switch (item) {
            .import => |imp| {
                const resolved = try resolveImportPath(allocator, dir, imp.path, stdlib_root_override orelse build_options.stdlib_root);
                var resolved_import = imp;
                resolved_import.resolved_file = resolved;
                try all_items.append(allocator, .{ .import = resolved_import });
                try loadFile(allocator, io, resolved, loaded, all_items, next_id, root_source, false);
            },
            else => try all_items.append(allocator, item),
        }
    }
}

/// True when `items` already contains an `#import std.heap…` (any form), so the
/// auto-injection for zone blocks doesn't add a duplicate edge.
fn moduleImportsStdHeap(items: []const ast.Item) bool {
    for (items) |item| switch (item) {
        .import => |imp| if (imp.path.len == 2 and
            std.mem.eql(u8, imp.path[0], "std") and
            std.mem.eql(u8, imp.path[1], "heap")) return true,
        else => {},
    };
    return false;
}

/// Turn an import path like ["utils", "math"] into "utils/math.sk"
/// relative to `base_dir`.
fn resolveImportPath(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    parts: []const []const u8,
    stdlib_root: ?[]const u8,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const is_std = parts.len > 0 and std.mem.eql(u8, parts[0], "std");
    if (is_std and stdlib_root != null) {
        try buf.appendSlice(allocator, stdlib_root.?);
        try buf.append(allocator, std.fs.path.sep);
    } else if (!is_std and base_dir.len > 0) {
        try buf.appendSlice(allocator, base_dir);
        try buf.append(allocator, std.fs.path.sep);
    }
    for (parts, 0..) |part, i| {
        if (i > 0) try buf.append(allocator, std.fs.path.sep);
        try buf.appendSlice(allocator, part);
    }
    try buf.appendSlice(allocator, ".sk");
    return buf.toOwnedSlice(allocator);
}

fn normalizeLogicalPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var start: usize = 0;
    while (std.mem.startsWith(u8, path[start..], "./") or std.mem.startsWith(u8, path[start..], ".\\")) {
        start += 2;
    }
    const normalized = try allocator.dupe(u8, path[start..]);
    for (normalized) |*ch| {
        if (ch.* != '\\') continue;
        ch.* = '/';
    }
    return normalized;
}

fn runPipelineWithSource(
    allocator: std.mem.Allocator,
    raw_module: ast.Module,
    source: []const u8,
    file: []const u8,
    arena: *std.heap.ArenaAllocator,
) CompileError!FrontEnd {
    // Phase 3 message loop: run `#compiler` hooks (compile-time functions that
    // return K2 source for top-level declarations) and add the generated
    // declarations to the module before the rest of the pipeline sees it.
    const base_module = if (ir_mod.hasCompilerHook(raw_module))
        try runCompilerHookPass(allocator, raw_module, source, file, arena)
    else
        raw_module;

    // Inject the compiler-provided `ast.*` metaprogramming types ONLY when the
    // module actually does metaprogramming (uses #quote/#insert/#for/macro), so
    // ordinary programs stay free of these types. Parsed with a high id base so
    // its node ids never collide with the program's; diagnostics keep the
    // user's source/file.
    const with_prelude = if (usesMetaprogramming(base_module))
        prependAstPrelude(allocator, base_module) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        base_module;

    // `type_info(T)` yields a matchable `TypeInfo` value; inject that reflection
    // surface when the module uses it (and doesn't already define `TypeInfo`).
    const with_reflect = if (moduleUsesReflection(with_prelude) and !moduleDefinesType(with_prelude, "TypeInfo"))
        prependReflectionPrelude(allocator, with_prelude) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        with_prelude;

    // `Any` (type-erased value + safe downcast) is mostly ordinary generic K2 —
    // inject it when the module uses `Any`/`any(`/`any_*` (and doesn't define its
    // own `Any`). Detected over the combined AST (not the source string, which in
    // a multi-module compile is only the first file). The wrap `any(x)` is the
    // only compiler-driven piece.
    const uses_any = moduleUsesAny(with_reflect) and !moduleDefinesType(with_reflect, "Any");
    const with_any = if (uses_any)
        prependAnyPrelude(allocator, with_reflect) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        with_reflect;

    // Generate `any_field_at`/`any_field_name` over the module's concrete structs,
    // so `Any` values navigate their fields (and `serialize` can walk them).
    const with_nav = if (uses_any)
        prependFieldNavPrelude(allocator, with_any) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        with_any;

    // A `zone X: Arena {}` handle is an ordinary `std.heap.Arena`, so any module
    // with a zone block depends on std.heap. Prepend the embedded bump-allocator
    // (and std.ptr, which it uses) so zones work in every compile path — even the
    // inline `compile(source)` path that never reads disk. Skipped when the
    // module already provides `Arena` (explicit `#import std.heap`).
    const with_heap = if (moduleUsesZone(with_nav) and !moduleProvidesArena(with_nav))
        prependHeapPrelude(allocator, with_nav) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        with_nav;

    // `#test` functions take a `*Test` context; inject the `Test` type (and its
    // assertion methods) when the module declares any test, so tests compile with
    // no import. The tests themselves run in the driver (comptime lane), not here.
    const with_testing = if (ir_mod.hasTestDecl(with_heap) and !moduleDefinesType(with_heap, "Test"))
        prependTestingPrelude(allocator, with_heap) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        with_heap;

    // Expand macros before any sema sees the tree: `#insert macrocall(...)`
    // becomes a literal `#insert #quote { ... }`, and macro decls are dropped.
    const module = macroexpand.expand(allocator, with_testing) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };

    // Two-pass `#insert`: a computed operand (`#insert #run gen()`) is run on
    // the VM using pass-1 results, reified into AST, and rewritten to a literal
    // `#quote { ... }`. The spliced module is then fully re-checked (pass 2) so
    // the generated code is type-checked exactly like hand-written code.
    //
    // Pass 1 must be TOLERANT: code after a computed insert may reference names
    // the generator declares, which pass 1 can't see yet. Pass 2 is strict.
    if (ir_mod.hasComputedInsert(module)) {
        const pass1 = try runSema(allocator, module, source, file, .tolerant);
        const fe1 = FrontEnd{ .module = module, .symbols = pass1.symbols, .types = pass1.types, .arena = arena };
        const spliced = ir_mod.expandComputedInserts(allocator, fe1) catch |err| switch (err) {
            error.SemanticFailed => return error.SemanticFailed,
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (spliced) |module2| {
            return strictPass(allocator, module2, source, file, arena);
        }
    }

    return strictPass(allocator, module, source, file, arena);
}

/// The final strict sema pass. If the module has `where` clauses, run it as a
/// two-pass resolution: a tolerant pre-pass builds a resolution `ComptimeVm`,
/// then the strict pass runs each generic instantiation's `where` predicate on
/// that VM *during* resolution (rejections become resolution errors, before the
/// body is checked). Otherwise it's a single strict pass.
fn strictPass(
    allocator: std.mem.Allocator,
    module: ast.Module,
    source: []const u8,
    file: []const u8,
    arena: *std.heap.ArenaAllocator,
) CompileError!FrontEnd {
    if (hasWhereClause(module)) {
        const pre = try runSema(allocator, module, source, file, .tolerant);
        const fe1 = FrontEnd{ .module = module, .symbols = pre.symbols, .types = pre.types, .arena = arena };
        var cvm = ir_mod.ComptimeVm.init(allocator, fe1);
        cvm.current_file = file;
        defer cvm.deinit();
        const pass = try runSemaResolved(allocator, module, source, file, .strict, &cvm, whereEvalThunk, whereTypeEvalThunk);
        return .{ .module = module, .symbols = pass.symbols, .types = pass.types, .arena = arena };
    }
    const pass = try runSema(allocator, module, source, file, .strict);
    return .{ .module = module, .symbols = pass.symbols, .types = pass.types, .arena = arena };
}

/// Adapts `ComptimeVm.evalWhere` to sema's opaque `WhereEvalFn` callback.
fn whereEvalThunk(
    ctx: *anyopaque,
    eval_file: []const u8,
    wc: ast.Block,
    type_args: []const sema.TypeArg,
    output_params: []const []const u8,
    expr_types: std.AutoHashMap(ast.NodeId, sema.Ty),
    out_alloc: std.mem.Allocator,
) ?[]const u8 {
    const cvm: *ir_mod.ComptimeVm = @ptrCast(@alignCast(ctx));
    cvm.current_file = eval_file;
    return cvm.evalWhere(wc, type_args, output_params, expr_types, out_alloc);
}

/// Adapts `ComptimeVm.evalWhereType` to sema's `WhereTypeEvalFn` callback.
fn whereTypeEvalThunk(
    ctx: *anyopaque,
    eval_file: []const u8,
    wc: ast.Block,
    type_args: []const sema.TypeArg,
    output_params: []const []const u8,
    expr_types: std.AutoHashMap(ast.NodeId, sema.Ty),
) ?u64 {
    const cvm: *ir_mod.ComptimeVm = @ptrCast(@alignCast(ctx));
    cvm.current_file = eval_file;
    return cvm.evalWhereType(wc, type_args, output_params, expr_types);
}

/// True if the module needs the resolution VM: any function with a `where { … }`
/// clause, or any `constraint Name($T) { … }` declaration (used at `$T: Name`).
fn hasWhereClause(module: ast.Module) bool {
    for (module.items) |item| switch (item) {
        .function => |f| if (f.where_clause != null or f.is_constraint) return true,
        else => {},
    };
    return false;
}

/// Run the module's `#compiler` hooks and return the module augmented with the
/// declarations they generated. The hooks need a runnable program, so this does
/// a throwaway prelude+macroexpand+tolerant-sema to build a FrontEnd, runs the
/// hooks on the VM, parses their output as top-level declarations, and appends
/// them to the RAW module (so the real pipeline re-applies prelude/macroexpand
/// to the whole thing).
fn runCompilerHookPass(
    allocator: std.mem.Allocator,
    raw_module: ast.Module,
    source: []const u8,
    file: []const u8,
    arena: *std.heap.ArenaAllocator,
) CompileError!ast.Module {
    // The `Decl` type backing `compiler_decls()` must be visible both to the
    // throwaway run below AND to the real compile, so prepend it up front; the
    // returned module carries it forward.
    const with_cprelude = prependCompilerPrelude(allocator, raw_module) catch |err| switch (err) {
        error.ParseFailed => return error.ParseFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const pre = if (usesMetaprogramming(with_cprelude))
        prependAstPrelude(allocator, with_cprelude) catch |err| switch (err) {
            error.ParseFailed => return error.ParseFailed,
            error.OutOfMemory => return error.OutOfMemory,
        }
    else
        with_cprelude;
    const expanded = macroexpand.expand(allocator, pre) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const pass0 = try runSema(allocator, expanded, source, file, .tolerant);
    const fe0 = FrontEnd{ .module = expanded, .symbols = pass0.symbols, .types = pass0.types, .arena = arena };

    // Phase 1 — GENERATE: bare `#compiler` hooks introspect the program and
    // emit/mutate declarations.
    const out1 = ir_mod.runCompilerHooks(allocator, fe0, false) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const m1 = try applyHookOutput(allocator, with_cprelude, out1, file);

    // Phase 2 — FINAL: `#compiler(final)` hooks run over the AUGMENTED program
    // (they see everything phase 1 generated) and can validate the whole program
    // (`compiler_error`) or mutate a second time. Skipped when there are none.
    if (!ir_mod.hasFinalHook(m1)) return m1;
    const exp1 = macroexpand.expand(allocator, m1) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const pass1 = try runSema(allocator, exp1, source, file, .tolerant);
    const fe1 = FrontEnd{ .module = exp1, .symbols = pass1.symbols, .types = pass1.types, .arena = arena };
    const out2 = ir_mod.runCompilerHooks(allocator, fe1, true) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return applyHookOutput(allocator, m1, out2, file);
}

/// Splice a hook pass's output into `base`: parse the generated source, then
/// build the new item list. A generated decl REPLACES an existing one of the
/// same name (rewrite, not just add); `compiler_remove(name)` drops a decl
/// outright. Prelude decls (`Decl`, `CodeBuf`, …) are never touched. Returns
/// `base` unchanged when the hooks produced nothing.
fn applyHookOutput(
    allocator: std.mem.Allocator,
    base: ast.Module,
    hook_out: ir_mod.HookOutput,
    file: []const u8,
) CompileError!ast.Module {
    // Generated decls share the user's file_name so they live in the same module
    // scope; ids start high to avoid colliding with user nodes.
    const gen_items: []const ast.Item = if (hook_out.source) |gsrc|
        (parser.parseSourceFrom(allocator, file, gsrc, 600_000) catch return error.ParseFailed).module.items
    else
        &.{};

    if (gen_items.len == 0 and hook_out.removed.len == 0) return base;

    var drop = std.StringHashMap(void).init(allocator);
    defer drop.deinit();
    for (gen_items) |gi| if (gi.name()) |gn| try drop.put(gn, {});
    for (hook_out.removed) |rn| try drop.put(rn, {});

    var items: std.ArrayList(ast.Item) = .empty;
    for (base.items) |it| {
        if (it.name()) |inm| {
            if (!ir_mod.isPreludeDeclName(inm) and drop.contains(inm)) continue;
        }
        try items.append(allocator, it);
    }
    try items.appendSlice(allocator, gen_items);
    return ast.Module{ .file_name = base.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// Inject the `std.compiler` `Decl` type so `#compiler` hooks can call
/// `compiler_decls()`. Parsed under the user's file name (K2 symbols are
/// file-private — a separate name would hide `Decl` from the hook), with a
/// distinct high id base so its nodes never collide with the user's.
fn prependCompilerPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    const parsed = try parser.parseSourceFrom(allocator, user.file_name, ast_prelude.compiler_source, 700_000);
    var items: std.ArrayList(ast.Item) = .empty;
    try items.appendSlice(allocator, parsed.module.items);
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// Prepend the embedded std.heap bump arena (and std.ptr, which it uses) to the
/// user's module so a `zone` block's `Arena` handle and allocator are in scope.
/// Parsed under the USER's file name (K2 symbols are file-private) with a high
/// id base; `ptr` is parsed first and `heap` chains off its next id. The
/// embedded `heap` imports `std.ptr` — stripped here, since ptr is inlined.
fn prependHeapPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    const ptr_parsed = try parser.parseSourceFrom(allocator, user.file_name, std_prelude.ptr_src, heap_prelude_id_base);
    const heap_parsed = try parser.parseSourceFrom(allocator, user.file_name, std_prelude.heap_src, ptr_parsed.next_id);

    var items: std.ArrayList(ast.Item) = .empty;

    // heap.k2 calls the platform runtime's page primitives (`os_reserve`, …).
    // The runtime-free `compile` path has no runtime, so supply a host shim
    // (VirtualAlloc-backed) — but only when no runtime already defines them, so
    // real builds (which prepend a runtime) don't see a duplicate declaration.
    if (!moduleDeclaresFunction(user, "os_reserve")) {
        const shim_parsed = try parser.parseSourceFrom(allocator, "<runtime>", os_host_shim_src, ptr_parsed.next_id + 4096);
        for (shim_parsed.module.items) |item| switch (item) {
            .import => {},
            else => try items.append(allocator, item),
        };
    }

    for (ptr_parsed.module.items) |item| switch (item) {
        .import => {},
        else => try items.append(allocator, item),
    };
    for (heap_parsed.module.items) |item| switch (item) {
        .import => {},
        else => try items.append(allocator, item),
    };
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// True when the module already declares a top-level function `name`.
fn moduleDeclaresFunction(module: ast.Module, name: []const u8) bool {
    for (module.items) |item| switch (item) {
        .function => |f| if (std.mem.eql(u8, f.name, name)) return true,
        else => {},
    };
    return false;
}

/// Host (Windows) page-memory shim for the runtime-free `compile` path. Mirrors
/// the `os_*` surface that windows.k2 provides at runtime; injected by
/// `prependHeapPrelude` only when no runtime is present (so it never collides).
const os_host_shim_src =
    \\#extern("kernel32", "VirtualAlloc")
    \\VirtualAlloc :: fn(addr: usize, size: usize, alloc_type: u32, protect: u32) -> usize;
    \\#extern("kernel32", "VirtualFree")
    \\VirtualFree :: fn(addr: usize, size: usize, free_type: u32) -> bool;
    \\os_reserve :: fn(size: usize) -> usize { return VirtualAlloc(0usize, size, 0x2000u32, 0x4u32); }
    \\os_commit :: fn(addr: usize, size: usize) -> bool { return VirtualAlloc(addr, size, 0x1000u32, 0x4u32) != 0usize; }
    \\os_alloc :: fn(size: usize) -> usize { return VirtualAlloc(0usize, size, 0x3000u32, 0x4u32); }
    \\os_release :: fn(addr: usize, size: usize) { ignored := VirtualFree(addr, 0usize, 0x8000u32); }
;

/// Prepend the `TypeInfo` reflection surface to the user's module. Parsed under
/// the user's file name (file-private symbols) with a high id base.
fn prependReflectionPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    // `<runtime>` so the reflection types are visible from every module (a serde
    // library, etc.), not just the root user file.
    const parsed = try parser.parseSourceFrom(allocator, "<runtime>", ast_prelude.reflection_source, reflection_prelude_id_base);
    var items: std.ArrayList(ast.Item) = .empty;
    try items.appendSlice(allocator, parsed.module.items);
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// Inject the `Test` context type (`fn(t: *Test)`) so `#test` functions compile
/// without importing anything. Parsed under `<runtime>` so it's visible from any
/// module that declares a test. Only injected when the module has a `#test` decl
/// and doesn't already define its own `Test`.
fn prependTestingPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    const parsed = try parser.parseSourceFrom(allocator, "<runtime>", ast_prelude.testing_source, testing_prelude_id_base);
    var items: std.ArrayList(ast.Item) = .empty;
    try items.appendSlice(allocator, parsed.module.items);
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// Generate `any_field_at(v, i)` / `any_field_name(v, i)` over the module's
/// concrete structs, so an `Any` can navigate its fields. Each struct gets a
/// `__fld_<S>` that returns the i-th field as an *in-place* `Any` (via `any_at` on
/// the field address) and a `__fldn_<S>` for the field name; two dispatchers
/// switch on the runtime `typeid`. Only structs whose fields are all simple named
/// types are included (others are skipped — their navigation returns null/"").
fn prependFieldNavPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    // NB: `src` must outlive this call — the parsed AST's string slices point into
    // it. It lives on the front-end arena, which frees it later.
    var src: std.ArrayList(u8) = .empty;

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    // Collected slice/pointer field types → element/pointee name. Generate one
    // `.elem`/`.deref` accessor per distinct type.
    var slice_elems = std.StringHashMap([]const u8).init(allocator);
    defer slice_elems.deinit();
    var ptr_targets = std.StringHashMap([]const u8).init(allocator);
    defer ptr_targets.deinit();
    // Every type seen → for `type_name_of(id)` / `type_size_of(id)` (the bare-id
    // lookup, `info_of`). Seeded with the scalars so they always resolve.
    var all_types = std.StringHashMap(void).init(allocator);
    defer all_types.deinit();
    for ([_][]const u8{ "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "usize", "isize", "f32", "f64", "bool" }) |t| try all_types.put(t, {});

    // Generated field navigators live in `<runtime>`, which sees every user type,
    // so they work no matter which module a struct (or the serializer) is in.
    const nav_file: []const u8 = "<runtime>";

    // Build the Any with `typeid_of`/`type_name` evaluated *here* (the nav file),
    // so a wrapped value's id matches the dispatchers' `core::type_id(...)` exactly.
    // (Routing through the generic `any_at` resolves the type via a binding, which
    // hashes compound types like `[]T` inconsistently with the direct form.)
    try src.appendSlice(allocator, "__any_make :: fn(ptr: *const u8, id: usize, nm: []const u8) -> Any { r: Any = .{ ptr, id, nm }; return r; }\n");

    for (user.items) |item| {
        const decl = switch (item) {
            .type_decl => |d| d,
            else => continue,
        };
        const strukt = switch (decl.kind) {
            .struct_type => |s| s,
            else => continue,
        };
        // Skip compiler-injected (`<runtime>`) structs; navigate every user struct.
        // The generated `__fld_<S>` lives in `<runtime>`, which can resolve `S` and
        // `Any` by bare name regardless of the file they're declared in.
        if (std.mem.eql(u8, decl.file_name, "<runtime>")) continue;
        if (strukt.type_params.len > 0 or strukt.fields.len == 0) continue;
        // Every field must render to a supported type (named, []named, *named).
        var ok = true;
        for (strukt.fields) |f| if ((try renderType(allocator, f.ty)) == null) {
            ok = false;
            break;
        };
        if (!ok) continue;

        try names.append(allocator, decl.name);
        try all_types.put(decl.name, {});
        try appendFmt(&src, allocator, "__fld_{s} :: fn(d: *const u8, i: usize) -> ?Any {{\n  unsafe {{\n    p := d as *const {s};\n", .{ decl.name, decl.name });
        for (strukt.fields, 0..) |f, j| {
            const tstr = (try renderType(allocator, f.ty)).?;
            try all_types.put(tstr, {});
            try appendFmt(&src, allocator, "    if i == {d}usize {{ return __any_make((&p.{s}) as *const u8, core::type_id({s}), core::type_name({s})); }}\n", .{ j, f.name, tstr, tstr });
            switch (f.ty) {
                .slice => |s| if (s.inner.* == .named) try slice_elems.put(tstr, s.inner.named.name),
                .pointer => |p| if (p.inner.* == .named) try ptr_targets.put(tstr, p.inner.named.name),
                else => {},
            }
        }
        try src.appendSlice(allocator, "  }\n  return null;\n}\n");

        try appendFmt(&src, allocator, "__fldn_{s} :: fn(i: usize) -> []const u8 {{\n", .{decl.name});
        for (strukt.fields, 0..) |f, j| {
            try appendFmt(&src, allocator, "  if i == {d}usize {{ return \"{s}\"; }}\n", .{ j, f.name });
        }
        try src.appendSlice(allocator, "  return \"\";\n}\n");
    }

    // Element / pointee accessors. A slice value is `{ ptr, len }`; a pointer Any
    // stores the pointer itself.
    try src.appendSlice(allocator, "__SliceHdr :: struct { ptr: *const u8, len: usize }\n");
    {
        var it = slice_elems.iterator();
        var k: usize = 0;
        while (it.next()) |e| : (k += 1) {
            try appendFmt(&src, allocator, "__elem_{d} :: fn(v: Any, idx: usize) -> ?Any {{\n  unsafe {{\n    h := v.data as *const __SliceHdr;\n    if idx >= h.len {{ return null; }}\n    ep := ((h.ptr as usize) + idx * core::sizeof({s})) as *const u8;\n    return __any_make(ep, core::type_id({s}), core::type_name({s}));\n  }}\n}}\n", .{ k, e.value_ptr.*, e.value_ptr.*, e.value_ptr.* });
        }
    }
    {
        var it = ptr_targets.iterator();
        var k: usize = 0;
        while (it.next()) |e| : (k += 1) {
            try appendFmt(&src, allocator, "__deref_{d} :: fn(v: Any) -> ?Any {{\n  unsafe {{\n    a := *(v.data as *const usize);\n    if a == 0usize {{ return null; }}\n    return __any_make(a as *const u8, core::type_id({s}), core::type_name({s}));\n  }}\n}}\n", .{ k, e.value_ptr.*, e.value_ptr.* });
        }
    }

    // `info_of` surface: name/size from a *bare* typeid (not just from an Any).
    try src.appendSlice(allocator, "type_name_of :: fn(id: usize) -> []const u8 {\n");
    {
        var it = all_types.keyIterator();
        while (it.next()) |k| try appendFmt(&src, allocator, "  if id == core::type_id({s}) {{ return core::type_name({s}); }}\n", .{ k.*, k.* });
    }
    try src.appendSlice(allocator, "  return \"?\";\n}\n");
    try src.appendSlice(allocator, "type_size_of :: fn(id: usize) -> usize {\n");
    {
        var it = all_types.keyIterator();
        while (it.next()) |k| try appendFmt(&src, allocator, "  if id == core::type_id({s}) {{ return core::sizeof({s}); }}\n", .{ k.*, k.* });
    }
    try src.appendSlice(allocator, "  return 0usize;\n}\n");

    // Dispatchers — always emitted so the `any_field_*`/`any_elem`/`any_deref`
    // surface exists whenever `Any` is in use.
    try src.appendSlice(allocator, "any_field_at :: fn(v: Any, i: usize) -> ?Any {\n");
    for (names.items) |n| try appendFmt(&src, allocator, "  if v.id == core::type_id({s}) {{ return __fld_{s}(v.data, i); }}\n", .{ n, n });
    try src.appendSlice(allocator, "  return null;\n}\n");

    try src.appendSlice(allocator, "any_field_name :: fn(v: Any, i: usize) -> []const u8 {\n");
    for (names.items) |n| try appendFmt(&src, allocator, "  if v.id == core::type_id({s}) {{ return __fldn_{s}(i); }}\n", .{ n, n });
    try src.appendSlice(allocator, "  return \"\";\n}\n");

    try src.appendSlice(allocator, "any_elem :: fn(v: Any, i: usize) -> ?Any {\n");
    {
        var it = slice_elems.keyIterator();
        var k: usize = 0;
        while (it.next()) |key| : (k += 1) {
            try appendFmt(&src, allocator, "  if v.id == core::type_id({s}) {{ return __elem_{d}(v, i); }}\n", .{ key.*, k });
        }
    }
    try src.appendSlice(allocator, "  return null;\n}\n");

    try src.appendSlice(allocator, "any_deref :: fn(v: Any) -> ?Any {\n");
    {
        var it = ptr_targets.keyIterator();
        var k: usize = 0;
        while (it.next()) |key| : (k += 1) {
            try appendFmt(&src, allocator, "  if v.id == core::type_id({s}) {{ return __deref_{d}(v); }}\n", .{ key.*, k });
        }
    }
    try src.appendSlice(allocator, "  return null;\n}\n");

    const parsed = try parser.parseSourceFrom(allocator, nav_file, src.items, fieldnav_prelude_id_base);
    var items: std.ArrayList(ast.Item) = .empty;
    try items.appendSlice(allocator, parsed.module.items);
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

fn appendFmt(src: *std.ArrayList(u8), a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(a, fmt, args);
    try src.appendSlice(a, s);
}

/// Render a field type for the navigation generator: a plain named type, a slice
/// of a named type (`[]T` / `[]const T`), or a pointer to one (`*T` / `*const T`).
/// Returns null for anything else (the struct is then skipped).
fn renderType(a: std.mem.Allocator, ty: ast.TypeRef) error{OutOfMemory}!?[]const u8 {
    return switch (ty) {
        .named => |n| n.name,
        .slice => |s| {
            const inner = (try renderType(a, s.inner.*)) orelse return null;
            return if (s.is_const)
                try std.fmt.allocPrint(a, "[]const {s}", .{inner})
            else
                try std.fmt.allocPrint(a, "[]{s}", .{inner});
        },
        .pointer => |p| {
            const inner = (try renderType(a, p.inner.*)) orelse return null;
            return if (p.is_const)
                try std.fmt.allocPrint(a, "*const {s}", .{inner})
            else
                try std.fmt.allocPrint(a, "*{s}", .{inner});
        },
        .optional => |o| {
            const inner = (try renderType(a, o.inner.*)) orelse return null;
            return try std.fmt.allocPrint(a, "?{s}", .{inner});
        },
        else => null,
    };
}

fn prependAnyPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    const parsed = try parser.parseSourceFrom(allocator, "<runtime>", ast_prelude.any_source, any_prelude_id_base);
    var items: std.ArrayList(ast.Item) = .empty;
    try items.appendSlice(allocator, parsed.module.items);
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// True when the module declares a top-level type named `name`.
fn moduleDefinesType(module: ast.Module, name: []const u8) bool {
    for (module.items) |item| switch (item) {
        .type_decl => |d| if (std.mem.eql(u8, d.name, name)) return true,
        else => {},
    };
    return false;
}

/// True when any expression in the module calls a reflection builtin
/// (`type_info`/`type_name`), which need the `TypeInfo` surface in scope.
fn moduleUsesReflection(module: ast.Module) bool {
    for (module.items) |item| switch (item) {
        .function => |f| {
            if (f.body) |b| if (blockUsesReflection(b)) return true;
            if (f.where_clause) |w| if (blockUsesReflection(w)) return true;
        },
        .const_decl => |d| if (exprUsesReflection(d.value)) return true,
        .interface_impl => |impl| for (impl.methods) |m| {
            if (m.body) |b| if (blockUsesReflection(b)) return true;
        },
        else => {},
    };
    return false;
}

/// True when the module references the `Any` type or calls an `any*` builtin
/// (`any`/`any_is`/`any_as`/`any_id`), so the `Any` prelude should be injected.
fn moduleUsesAny(module: ast.Module) bool {
    for (module.items) |item| switch (item) {
        .function => |f| {
            if (typeRefUsesAny(f.return_ty)) return true;
            for (f.params) |p| if (typeRefUsesAny(p.ty)) return true;
            if (f.body) |b| if (blockUsesAny(b)) return true;
        },
        .const_decl => |d| if (exprUsesAny(d.value)) return true,
        else => {},
    };
    return false;
}

fn typeRefUsesAny(ty: ast.TypeRef) bool {
    return switch (ty) {
        .named, .type_param => |n| std.mem.eql(u8, n.name, "Any"),
        .pointer, .many_pointer => |p| typeRefUsesAny(p.inner.*),
        .optional => |o| typeRefUsesAny(o.inner.*),
        .slice => |s| typeRefUsesAny(s.inner.*),
        .array => |a| typeRefUsesAny(a.inner.*),
        .atomic => |a| typeRefUsesAny(a.inner.*),
        .borrow => |b| typeRefUsesAny(b.inner.*),
        else => false,
    };
}

fn isAnyBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "any") or std.mem.eql(u8, name, "any_is") or
        std.mem.eql(u8, name, "any_as") or std.mem.eql(u8, name, "any_id");
}

/// If `callee` is `core::<member>` (the reserved builtin namespace), return the
/// member name — so the prelude-injection scanners detect builtins written as
/// `core::type_info(...)`/`core::any(...)`, not only the bare forms.
fn coreMemberOf(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .scope_access => |sa| if (sa.base.kind == .ident and std.mem.eql(u8, sa.base.kind.ident, "core")) sa.member else null,
        else => null,
    };
}

fn blockUsesAny(block: ast.Block) bool {
    for (block.statements) |stmt| if (stmtUsesAny(stmt)) return true;
    return false;
}

fn stmtUsesAny(stmt: ast.Stmt) bool {
    return switch (stmt) {
        .comptime_run, .unsafe_block => |b| blockUsesAny(b),
        .if_stmt => |s| blockUsesAny(s.then_block) or
            (if (s.else_block) |e| blockUsesAny(e) else false) or exprUsesAny(s.condition) or
            (if (s.binding) |bd| exprUsesAny(bd.value) else false),
        .while_stmt => |s| blockUsesAny(s.body) or exprUsesAny(s.condition),
        .for_range => |s| blockUsesAny(s.body) or exprUsesAny(s.start) or exprUsesAny(s.end),
        .for_slice => |s| blockUsesAny(s.body) or exprUsesAny(s.iter),
        .zone_block => |s| blockUsesAny(s.body),
        .defer_stmt => |s| blockUsesAny(s.body),
        .comptime_if => |s| blockUsesAny(s.then_block) or
            (if (s.else_block) |e| blockUsesAny(e) else false),
        .match_stmt => |s| blk: {
            for (s.arms) |a| if (blockUsesAny(a.body)) break :blk true;
            break :blk exprUsesAny(s.subject);
        },
        .local_typed => |s| typeRefUsesAny(s.ty) or exprUsesAny(s.value),
        .local_infer => |s| exprUsesAny(s.value),
        .assign => |s| exprUsesAny(s.target) or exprUsesAny(s.value),
        .return_stmt => |s| if (s.value) |v| exprUsesAny(v) else false,
        .expr => |e| exprUsesAny(e),
        else => false,
    };
}

fn exprUsesAny(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .call => |c| blk: {
            if (c.callee.kind == .ident and isAnyBuiltin(c.callee.kind.ident)) break :blk true;
            if (coreMemberOf(c.callee.*)) |m| if (isAnyBuiltin(m)) break :blk true;
            if (exprUsesAny(c.callee.*)) break :blk true;
            for (c.args) |a| switch (a) {
                .positional => |x| if (exprUsesAny(x)) break :blk true,
                .named => |nm| if (exprUsesAny(nm.value)) break :blk true,
            };
            break :blk false;
        },
        .binary => |b| exprUsesAny(b.left.*) or exprUsesAny(b.right.*),
        .unary => |u| exprUsesAny(u.expr.*),
        .field => |f| exprUsesAny(f.base.*),
        .index => |i| exprUsesAny(i.base.*) or exprUsesAny(i.index.*),
        .force_unwrap, .unsafe_expr, .run_expr => |inner| exprUsesAny(inner.*),
        .as_cast => |c| exprUsesAny(c.value.*),
        .nil_coalesce => |nc| exprUsesAny(nc.value.*) or exprUsesAny(nc.default.*),
        else => false,
    };
}

fn blockUsesReflection(block: ast.Block) bool {
    for (block.statements) |stmt| if (stmtUsesReflection(stmt)) return true;
    return false;
}

fn stmtUsesReflection(stmt: ast.Stmt) bool {
    return switch (stmt) {
        .comptime_run, .unsafe_block => |b| blockUsesReflection(b),
        .if_stmt => |s| blockUsesReflection(s.then_block) or
            (if (s.else_block) |e| blockUsesReflection(e) else false) or exprUsesReflection(s.condition),
        .while_stmt => |s| blockUsesReflection(s.body) or exprUsesReflection(s.condition),
        .for_range => |s| blockUsesReflection(s.body) or exprUsesReflection(s.start) or exprUsesReflection(s.end),
        .for_slice => |s| blockUsesReflection(s.body) or exprUsesReflection(s.iter),
        .zone_block => |s| blockUsesReflection(s.body),
        .defer_stmt => |s| blockUsesReflection(s.body),
        .comptime_if => |s| blockUsesReflection(s.then_block) or
            (if (s.else_block) |e| blockUsesReflection(e) else false),
        .match_stmt => |s| blk: {
            for (s.arms) |a| if (blockUsesReflection(a.body)) break :blk true;
            break :blk exprUsesReflection(s.subject);
        },
        .local_infer => |s| exprUsesReflection(s.value),
        .local_typed => |s| exprUsesReflection(s.value),
        .assign => |s| exprUsesReflection(s.target) or exprUsesReflection(s.value),
        .return_stmt => |s| if (s.value) |v| exprUsesReflection(v) else false,
        .expr => |e| exprUsesReflection(e),
        else => false,
    };
}

fn exprUsesReflection(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .call => |c| blk: {
            if (c.callee.kind == .ident) {
                const n = c.callee.kind.ident;
                if (std.mem.eql(u8, n, "type_info") or std.mem.eql(u8, n, "type_name")) break :blk true;
            }
            if (coreMemberOf(c.callee.*)) |n| {
                if (std.mem.eql(u8, n, "type_info") or std.mem.eql(u8, n, "type_name")) break :blk true;
            }
            if (exprUsesReflection(c.callee.*)) break :blk true;
            for (c.args) |a| switch (a) {
                .positional => |x| if (exprUsesReflection(x)) break :blk true,
                .named => |nm| if (exprUsesReflection(nm.value)) break :blk true,
            };
            break :blk false;
        },
        .binary => |b| exprUsesReflection(b.left.*) or exprUsesReflection(b.right.*),
        .unary => |u| exprUsesReflection(u.expr.*),
        .field => |f| exprUsesReflection(f.base.*),
        .index => |i| exprUsesReflection(i.base.*) or exprUsesReflection(i.index.*),
        .force_unwrap, .unsafe_expr, .run_expr => |inner| exprUsesReflection(inner.*),
        .as_cast => |c| exprUsesReflection(c.value.*),
        .nil_coalesce => |nc| exprUsesReflection(nc.value.*) or exprUsesReflection(nc.default.*),
        else => false,
    };
}

/// True when the module already supplies `std.heap.Arena` — either an explicit
/// `#import std.heap` or a top-level `Arena` type declaration — so the heap
/// prelude isn't injected twice (which would duplicate every heap symbol).
fn moduleProvidesArena(module: ast.Module) bool {
    if (moduleImportsStdHeap(module.items)) return true;
    for (module.items) |item| switch (item) {
        .type_decl => |d| if (std.mem.eql(u8, d.name, "Arena")) return true,
        else => {},
    };
    return false;
}

/// True when any function/impl body in the module contains a `zone` block.
fn moduleUsesZone(module: ast.Module) bool {
    for (module.items) |item| switch (item) {
        .function => |f| if (f.body) |b| {
            if (blockUsesZone(b)) return true;
        },
        .interface_impl => |impl| for (impl.methods) |m| {
            if (m.body) |b| if (blockUsesZone(b)) return true;
        },
        else => {},
    };
    return false;
}

fn blockUsesZone(block: ast.Block) bool {
    for (block.statements) |stmt| if (stmtUsesZone(stmt)) return true;
    return false;
}

fn stmtUsesZone(stmt: ast.Stmt) bool {
    return switch (stmt) {
        .zone_block => true,
        .comptime_run, .unsafe_block => |b| blockUsesZone(b),
        .if_stmt => |s| blockUsesZone(s.then_block) or
            (if (s.else_block) |e| blockUsesZone(e) else false),
        .while_stmt => |s| blockUsesZone(s.body),
        .for_range => |s| blockUsesZone(s.body),
        .for_slice => |s| blockUsesZone(s.body),
        .defer_stmt => |s| blockUsesZone(s.body),
        .comptime_if => |s| blockUsesZone(s.then_block) or
            (if (s.else_block) |e| blockUsesZone(e) else false),
        .match_stmt => |s| blk: {
            for (s.arms) |a| if (blockUsesZone(a.body)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

const SemaResult = struct {
    symbols: sema.SymbolTable,
    types: sema.TypeEnv,
};

const SemaMode = enum { strict, tolerant };

fn runSema(
    allocator: std.mem.Allocator,
    module: ast.Module,
    source: []const u8,
    file: []const u8,
    mode: SemaMode,
) CompileError!SemaResult {
    return runSemaResolved(allocator, module, source, file, mode, null, null, null);
}

/// `runSema` with an optional resolution-time `where`-predicate evaluator wired
/// into the strict pass (the two-pass rail).
fn runSemaResolved(
    allocator: std.mem.Allocator,
    module: ast.Module,
    source: []const u8,
    file: []const u8,
    mode: SemaMode,
    where_ctx: ?*anyopaque,
    where_fn: ?sema.WhereEvalFn,
    where_type_fn: ?sema.WhereTypeEvalFn,
) CompileError!SemaResult {
    var symbols = sema.collectSymbols(allocator, module) catch |err| switch (err) {
        error.SemanticFailed => return error.SemanticFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer symbols.deinit(allocator);

    sema.resolveNames(allocator, module, symbols) catch |err| switch (err) {
        error.SemanticFailed => {},
        error.OutOfMemory => return error.OutOfMemory,
    };
    sema.checkZones(allocator, module, symbols) catch |err| switch (err) {
        error.SemanticFailed => {},
        error.OutOfMemory => return error.OutOfMemory,
    };

    const types = switch (mode) {
        .tolerant => sema.checkTypesTolerant(allocator, module, &symbols, source, file) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        },
        .strict => sema.checkTypesWithResolution(allocator, module, &symbols, source, file, where_ctx, where_fn, where_type_fn) catch |err| switch (err) {
            error.SemanticFailed => return error.SemanticFailed,
            error.OutOfMemory => return error.OutOfMemory,
        },
    };

    return .{ .symbols = symbols, .types = types };
}

/// True if the module uses any metaprogramming construct that needs the `ast.*`
/// types in scope (`#quote`/`#insert`/`#for`/`macro`). Plain `#run`/`#if`
/// programs do NOT trigger injection, so they stay free of the ast.* types.
fn usesMetaprogramming(module: ast.Module) bool {
    for (module.items) |item| switch (item) {
        .function => |f| {
            if (f.is_macro) return true;
            if (f.body) |b| if (blockUsesMeta(b)) return true;
        },
        .interface_impl => |impl| for (impl.methods) |m| {
            if (m.body) |b| if (blockUsesMeta(b)) return true;
        },
        // Top-level `X :: #run ... #quote ...` constants also need the types.
        .const_decl => |d| if (exprUsesMeta(d.value)) return true,
        else => {},
    };
    return false;
}

fn blockUsesMeta(block: ast.Block) bool {
    for (block.statements) |stmt| if (stmtUsesMeta(stmt)) return true;
    return false;
}

fn stmtUsesMeta(stmt: ast.Stmt) bool {
    return switch (stmt) {
        .insert_stmt, .comptime_for => true,
        .comptime_run, .unsafe_block => |b| blockUsesMeta(b),
        .if_stmt => |s| blockUsesMeta(s.then_block) or
            (if (s.else_block) |e| blockUsesMeta(e) else false) or exprUsesMeta(s.condition),
        .while_stmt => |s| blockUsesMeta(s.body) or exprUsesMeta(s.condition),
        .for_range => |s| blockUsesMeta(s.body) or exprUsesMeta(s.start) or exprUsesMeta(s.end),
        .for_slice => |s| blockUsesMeta(s.body) or exprUsesMeta(s.iter),
        .zone_block => |s| blockUsesMeta(s.body),
        .defer_stmt => |s| blockUsesMeta(s.body),
        .comptime_if => |s| blockUsesMeta(s.then_block) or
            (if (s.else_block) |e| blockUsesMeta(e) else false),
        .match_stmt => |s| blk: {
            for (s.arms) |a| if (blockUsesMeta(a.body)) break :blk true;
            break :blk exprUsesMeta(s.subject);
        },
        .local_infer => |s| exprUsesMeta(s.value),
        .local_typed => |s| exprUsesMeta(s.value),
        .assign => |s| exprUsesMeta(s.target) or exprUsesMeta(s.value),
        .return_stmt => |s| if (s.value) |v| exprUsesMeta(v) else false,
        .expr => |e| exprUsesMeta(e),
        else => false,
    };
}

fn exprUsesMeta(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .quote, .quote_expr, .splice => true,
        .binary => |b| exprUsesMeta(b.left.*) or exprUsesMeta(b.right.*),
        .unary => |u| exprUsesMeta(u.expr.*),
        .call => |c| blk: {
            if (exprUsesMeta(c.callee.*)) break :blk true;
            for (c.args) |a| switch (a) {
                .positional => |x| if (exprUsesMeta(x)) break :blk true,
                .named => |n| if (exprUsesMeta(n.value)) break :blk true,
            };
            break :blk false;
        },
        .field => |f| exprUsesMeta(f.base.*),
        .index => |i| exprUsesMeta(i.base.*) or exprUsesMeta(i.index.*),
        .force_unwrap, .unsafe_expr, .run_expr => |inner| exprUsesMeta(inner.*),
        .as_cast => |c| exprUsesMeta(c.value.*),
        .nil_coalesce => |nc| exprUsesMeta(nc.value.*) or exprUsesMeta(nc.default.*),
        else => false,
    };
}

/// Parse the `ast.*` prelude and return a module with its items prepended to
/// the user's. The prelude is pure type declarations, so it carries no imports.
fn prependAstPrelude(allocator: std.mem.Allocator, user: ast.Module) !ast.Module {
    // Parse under the USER's file name so the prelude types share the user's
    // module — K2 symbols are file-private, so a separate file name would make
    // the ast.* types invisible to user code.
    const parsed = try parser.parseSourceFrom(allocator, user.file_name, ast_prelude.source, prelude_id_base);
    var items: std.ArrayList(ast.Item) = .empty;
    try items.appendSlice(allocator, parsed.module.items);
    try items.appendSlice(allocator, user.items);
    return .{ .file_name = user.file_name, .items = try items.toOwnedSlice(allocator) };
}

fn createFrontendArena(allocator: std.mem.Allocator) CompileError!*std.heap.ArenaAllocator {
    const arena = allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
    arena.* = std.heap.ArenaAllocator.init(allocator);
    return arena;
}

fn destroyFrontendArena(allocator: std.mem.Allocator, arena: *std.heap.ArenaAllocator) void {
    arena.deinit();
    allocator.destroy(arena);
}
