const std = @import("std");
const backend = @import("backend.zig");
const ir = @import("ir.zig");
const pipeline = @import("pipeline.zig");
const diag_mod = @import("diagnostic.zig");
const runtime_mod = @import("runtime.zig");
const build_options = @import("build_options");

pub const BuildMode = enum { check, emit_ir, emit_object };

/// PE subsystem for an executable (mirrors the linker's `Subsystem`).
pub const Subsystem = enum { console, windows };

pub const CompileOptions = struct {
    mode: BuildMode = .check,
    output_path: ?[]const u8 = null,
    run_passes: bool = true,
};

pub const CompileOutput = union(enum) {
    checked,
    text_ir: []u8,
    object: []const u8,
};

pub const DriverError = error{
    CompileFailed,
    LoweringFailed,
    BackendFailed,
    OutOfMemory,
};

/// Compile source text using the legacy basalt backend stub.
pub fn compileSource(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    source: []const u8,
    active_backend: backend.Backend,
    options: CompileOptions,
) DriverError!CompileOutput {
    var fe = pipeline.compile(allocator, file_name, source) catch |err| switch (err) {
        error.ParseFailed, error.SemanticFailed, error.IoError, error.RuntimeUnavailable => return error.CompileFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer fe.deinit(allocator);
    if (fe.diagnostics().len != 0) {
        for (fe.diagnostics()) |d| {
            const rendered = diag_mod.renderDiagnostic(allocator, d.file, source, d) catch continue;
            defer allocator.free(rendered);
            std.debug.print("{s}\n", .{rendered});
        }
        return error.CompileFailed;
    }

    var module = ir.lowerFrontend(allocator, fe) catch |err| switch (err) {
        error.LoweringFailed => return error.LoweringFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (options.run_passes) ir.runDefaultPasses(allocator, &module) catch return error.LoweringFailed;
    ir.validateModule(module) catch return error.LoweringFailed;

    return switch (options.mode) {
        .check => .checked,
        .emit_ir => .{ .text_ir = active_backend.emitTextIr(allocator, module) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BackendFailed,
        } },
        .emit_object => blk: {
            const out = options.output_path orelse return error.BackendFailed;
            active_backend.emitObject(module, out) catch return error.BackendFailed;
            break :blk .{ .object = out };
        },
    };
}

// ── LLVM backend path ─────────────────────────────────────────────────────────

/// A compile phase, reported to a progress hook as it begins.
pub const Phase = enum {
    frontend, // parse + macro expand + type check (+ comptime two-pass)
    lower, // typed AST → IR (+ comptime `#run`)
    passes, // IR optimisation passes
    codegen, // IR → LLVM IR
    emit, // LLVM IR → object file
    link, // object → executable

    pub fn label(self: Phase) []const u8 {
        return switch (self) {
            .frontend => "checking",
            .lower => "lowering",
            .passes => "optimising",
            .codegen => "generating code",
            .emit => "emitting object",
            .link => "linking",
        };
    }
};

/// Called with each phase just before it runs, for a live status line.
pub const ProgressFn = *const fn (ctx: ?*anyopaque, phase: Phase) void;

/// Per-phase wall-clock timings (nanoseconds) filled in during a build.
pub const Timings = struct {
    frontend_ns: u64 = 0,
    lower_ns: u64 = 0,
    passes_ns: u64 = 0,
    codegen_ns: u64 = 0,
    emit_ns: u64 = 0,
    link_ns: u64 = 0,
    /// Of the above, time spent in compile-time evaluation (`#run`/FFI/macros).
    comptime_ns: u64 = 0,
    total_ns: u64 = 0,
};

pub const LlvmCompileOptions = struct {
    /// Source file path (for diagnostics).
    file_name: []const u8,
    /// Skarn source text.
    source: []const u8,
    /// Where to write the object file.
    obj_path: []const u8,
    /// Where to write the executable/DLL (null = stop at .o).
    exe_path: ?[]const u8 = null,
    /// Link a DLL (shared library) instead of an executable.
    dll: bool = false,
    /// LLVM opt level (0–3).
    opt_level: u2 = if (@import("builtin").mode == .Debug) 0 else 2,
    /// Target OS to generate for (cross-compilation). Defaults to the host.
    target_os: std.Target.Os.Tag = @import("builtin").os.tag,
    /// Emit no platform entry-point wrapper (`mainCRTStartup`) or `_fltused` — a
    /// freestanding library object to embed in another binary (skarnld into skarn.exe).
    no_entry: bool = false,
    /// Link dynamically against the system libc (the `linux-gnu` ABI). When false
    /// (default), Linux output is a static, freestanding, no-libc ELF.
    link_libc: bool = false,
    /// Sysroot holding libc.so.6 + the dynamic linker for `linux-gnu` links
    /// (empty → the runtime's default search). Only used when `link_libc`.
    sysroot: []const u8 = "",
    /// Path to the LLVM bin directory (for lld-link / ld.lld).
    llvm_bin: []const u8 = "",
    /// Extra library search paths for the linker.
    lib_paths: []const []const u8 = &.{},
    /// Extra import libraries to link (without the `.lib` extension), in
    /// addition to those inferred from `#extern("lib", "symbol")` decls —
    /// e.g. transitive system libs a C library depends on (gdi32, user32, ...).
    extra_libs: []const []const u8 = &.{},
    /// PE subsystem for an executable (`.console` shows a terminal window,
    /// `.windows` is a GUI app with no console).
    subsystem: Subsystem = .console,
    /// Override the linker entry symbol (default `mainCRTStartup`).
    entry: ?[]const u8 = null,
    /// Reserve this many bytes of stack (0 = linker default).
    stack_reserve: u64 = 0,
    /// Raw linker flags passed verbatim (escape hatch).
    link_flags: []const []const u8 = &.{},
    /// Honor the linked C library's own `/DEFAULTLIB` directives (its system deps)
    /// instead of blanket `/NODEFAULTLIB`. The build sets this for static C libs.
    honor_defaultlibs: bool = false,
    /// Optional progress hook, called at each phase boundary.
    progress: ?ProgressFn = null,
    progress_ctx: ?*anyopaque = null,
    /// If set, per-phase timings are written here.
    timings: ?*Timings = null,
};

const clock = @import("clock.zig");

fn nowNs() u64 {
    return clock.monoNs();
}

fn sinceNs(start: u64) u64 {
    return clock.sinceNs(start);
}

pub const LlvmDriverError = error{
    CompileFailed,
    LlvmNotEnabled,
    LoweringFailed,
    EmitFailed,
    LinkFailed,
    OutOfMemory,
};

/// Print diagnostics from a FrontEnd to stderr, using the correct source text
/// for each file (user file or embedded runtime).
fn printFeDiagnostics(
    allocator: std.mem.Allocator,
    diags: []const diag_mod.Diagnostic,
    user_file: []const u8,
    user_source: []const u8,
) void {
    const rt_src = runtime_mod.runtimeSource();
    for (diags) |d| {
        const src: []const u8 =
            if (std.mem.eql(u8, d.file, user_file)) user_source else if (std.mem.eql(u8, d.file, "<runtime>")) rt_src else "";
        const rendered = diag_mod.renderDiagnostic(allocator, d.file, src, d) catch continue;
        defer allocator.free(rendered);
        std.debug.print("{s}\n", .{rendered});
    }
}

/// Comptime test lane: run every `#test` function on the VM during compilation.
/// A failed assertion (`t.eq`, `t.expect`, …) becomes a build error — the program
/// does not compile, exactly like a type error. On success the test functions are
/// pruned so they never reach the backend. No-op when the module has no tests.
fn runComptimeTestLane(allocator: std.mem.Allocator, fe: *pipeline.FrontEnd, file_name: []const u8) LlvmDriverError!void {
    if (!ir.hasTestDecl(fe.module)) return;
    const report = ir.runComptimeTests(allocator, fe.*) catch {
        std.debug.print("{s}: internal compiler error while running comptime tests\n", .{file_name});
        return error.CompileFailed;
    };
    if (report.failed != 0) {
        for (report.failures) |f| {
            std.debug.print("comptime test '{s}' failed: {s}\n", .{ f.name, f.message });
        }
        std.debug.print("\n{d} passed, {d} failed (comptime)\n", .{ report.passed, report.failed });
        return error.CompileFailed;
    }
    // All green — drop the test functions so they never reach the backend.
    fe.module = ir.pruneTestDecls(fe.arena.allocator(), fe.module) catch fe.module;
}

/// Full pipeline: source → IR → LLVM IR → .o → (optional) .exe
pub fn compileWithLlvm(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: LlvmCompileOptions,
) LlvmDriverError!void {
    if (!build_options.enable_llvm) return error.LlvmNotEnabled;

    // compileWithRuntime auto-prepends the platform runtime (@panic, assert, etc.)
    var fe = pipeline.compileWithRuntimeTarget(allocator, opts.file_name, opts.source, opts.target_os, opts.link_libc) catch |err| switch (err) {
        error.ParseFailed, error.SemanticFailed, error.IoError, error.RuntimeUnavailable => return error.CompileFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer fe.deinit(allocator);
    if (fe.diagnostics().len != 0) {
        printFeDiagnostics(allocator, fe.diagnostics(), opts.file_name, opts.source);
        return error.CompileFailed;
    }

    try runComptimeTestLane(allocator, &fe, opts.file_name);
    try emitLlvmFromFrontend(allocator, io, fe, opts);
}

/// Full file pipeline: .sk path + imports -> IR -> LLVM IR -> .o -> (optional) .exe
pub fn compileFileWithLlvm(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: LlvmCompileOptions,
) LlvmDriverError!void {
    if (!build_options.enable_llvm) return error.LlvmNotEnabled;

    const ct0 = ir.comptime_ns;
    const t_total = nowNs();
    if (opts.progress) |p| p(opts.progress_ctx, .frontend);
    const t_fe = nowNs();
    var fe = pipeline.compileFileWithRuntimeTarget(allocator, io, opts.file_name, opts.target_os, opts.link_libc) catch |err| switch (err) {
        error.ParseFailed, error.SemanticFailed, error.IoError, error.RuntimeUnavailable => return error.CompileFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer fe.deinit(allocator);
    if (opts.timings) |tm| tm.frontend_ns = sinceNs(t_fe);
    if (fe.diagnostics().len != 0) {
        printFeDiagnostics(allocator, fe.diagnostics(), opts.file_name, opts.source);
        return error.CompileFailed;
    }

    try runComptimeTestLane(allocator, &fe, opts.file_name);
    try emitLlvmFromFrontend(allocator, io, fe, opts);

    if (opts.timings) |tm| {
        tm.comptime_ns = ir.comptime_ns - ct0;
        tm.total_ns = sinceNs(t_total);
    }
}

fn emitLlvmFromFrontend(
    allocator: std.mem.Allocator,
    io: std.Io,
    fe: pipeline.FrontEnd,
    opts: LlvmCompileOptions,
) LlvmDriverError!void {
    var ir_arena = std.heap.ArenaAllocator.init(allocator);
    defer ir_arena.deinit();
    const ir_allocator = ir_arena.allocator();

    // Middle-end
    if (opts.progress) |p| p(opts.progress_ctx, .lower);
    const t_lower = nowNs();
    var module = ir.lowerFrontend(ir_allocator, fe) catch |err| switch (err) {
        error.LoweringFailed => {
            // Lowering surfaces both ICEs and genuine user errors (e.g. a `#run`
            // the comptime VM can't evaluate); the specific diagnostic is already
            // printed above, so keep this summary neutral.
            std.debug.print("{s}: compilation failed (see errors above)\n", .{opts.file_name});
            return error.LoweringFailed;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (opts.timings) |tm| tm.lower_ns = sinceNs(t_lower);

    if (opts.progress) |p| p(opts.progress_ctx, .passes);
    const t_passes = nowNs();
    ir.runDefaultPasses(ir_allocator, &module) catch {
        std.debug.print("{s}: internal compiler error during IR optimisation passes\n", .{opts.file_name});
        return error.LoweringFailed;
    };
    ir.validateModule(module) catch {
        std.debug.print("{s}: internal compiler error: IR validation failed (malformed IR produced)\n", .{opts.file_name});
        return error.LoweringFailed;
    };
    if (opts.timings) |tm| tm.passes_ns = sinceNs(t_passes);

    // LLVM backend
    const llvm_backend = @import("backend/llvm.zig");
    const module_name = try allocator.dupeZ(u8, opts.file_name);
    defer allocator.free(module_name);

    var be = llvm_backend.LlvmBackend.init(allocator, module_name);
    defer be.deinit();

    be.setTarget(opts.target_os);
    be.cg.no_entry = opts.no_entry;
    be.setOptLevel(opts.opt_level);
    if (opts.progress) |p| p(opts.progress_ctx, .codegen);
    const t_codegen = nowNs();
    be.lower(module) catch {
        std.debug.print("{s}: compilation failed due to internal compiler error during code generation (see above)\n", .{opts.file_name});
        return error.LoweringFailed;
    };
    if (opts.timings) |tm| tm.codegen_ns = sinceNs(t_codegen);

    if (opts.exe_path) |exe| {
        // Linking: emit the object to MEMORY (no .obj round-trip) and hand the
        // bytes straight to the linker. The .obj is only written to disk if we
        // fall back to LLD.
        if (opts.progress) |p| p(opts.progress_ctx, .emit);
        const t_emit = nowNs();
        const obj_bytes = be.emitObjectToMemory(allocator, opts.opt_level) catch return error.EmitFailed;
        defer allocator.free(obj_bytes);
        if (opts.timings) |tm| tm.emit_ns = sinceNs(t_emit);

        if (opts.progress) |p| p(opts.progress_ctx, .link);
        const t_link = nowNs();
        // Combine libs inferred from `#extern("lib", "symbol")` decls with any
        // user-supplied `--lib` libraries (e.g. transitive system deps).
        var libs: std.ArrayList([]const u8) = .empty;
        defer libs.deinit(allocator);
        try libs.appendSlice(allocator, module.extern_libs);
        try libs.appendSlice(allocator, opts.extra_libs);

        if (opts.target_os == .linux) {
            be.linkLinuxMem(allocator, io, opts.obj_path, obj_bytes, .{
                .llvm_bin = opts.llvm_bin,
                .output = exe,
                .lib_paths = opts.lib_paths,
                .libs = libs.items,
                .entry = opts.entry orelse "_start",
                .extra_flags = opts.link_flags,
                .link_libc = opts.link_libc,
                .sysroot = opts.sysroot,
            }) catch return error.LinkFailed;
            if (opts.timings) |tm| tm.link_ns = sinceNs(t_link);
            return;
        }

        be.linkWindowsMem(allocator, io, obj_bytes, .{
            .llvm_bin = opts.llvm_bin,
            .obj_files = &.{opts.obj_path}, // path used only if we spill for LLD
            .output = exe,
            .lib_paths = opts.lib_paths,
            .libs = libs.items,
            .dll = opts.dll,
            .subsystem = switch (opts.subsystem) {
                .console => .console,
                .windows => .windows,
            },
            .entry = opts.entry,
            .stack_reserve = opts.stack_reserve,
            .extra_flags = opts.link_flags,
            .honor_defaultlibs = opts.honor_defaultlibs,
        }) catch return error.LinkFailed;
        if (opts.timings) |tm| tm.link_ns = sinceNs(t_link);
    } else {
        // Object-only output (`skarn object`): write the .obj file.
        const obj_z = try allocator.dupeZ(u8, opts.obj_path);
        defer allocator.free(obj_z);
        if (opts.progress) |p| p(opts.progress_ctx, .emit);
        const t_emit = nowNs();
        be.emitObject(obj_z, opts.opt_level) catch return error.EmitFailed;
        if (opts.timings) |tm| tm.emit_ns = sinceNs(t_emit);
    }
}
