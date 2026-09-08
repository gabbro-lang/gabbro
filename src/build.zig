//! The `gabbro build` build system driver.
//!
//! Runs a project's `build.gab` `build :: fn(b: Build)` entry inside the comptime
//! VM (via `ir.runBuildHook`), recording each `std.build` call into a `BuildPlan`
//! through the VM's host-call bridge, then compiles + links the declared
//! artifacts with the normal LLVM/gabld driver.
//!
//! See docs/10_build_system.md for the design and `std/build.gab` for the API.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const pipeline = @import("pipeline.zig");
const ir = @import("ir.zig");
const driver = @import("driver.zig");
const diagnostic = @import("diagnostic.zig");
const vm_engine = @import("vm/engine.zig");
const vm_value = @import("vm/value.zig");
const instructions = @import("vm/instructions.zig");

const Value = vm_value.Value;
const BuildOp = instructions.BuildOp;

pub const BuildError = error{
    CompileFailed,
    NoBuildScript,
    NoBuildFn,
    NoArtifacts,
    UnknownTarget,
    RunFailed,
    OutOfMemory,
};

pub const ArtifactKind = enum(u8) { executable, shared_library, static_library, object };

pub const Artifact = struct {
    name: []const u8,
    root: []const u8,
    kind: ArtifactKind,
    opt: u2 = 0,
    out_path: ?[]const u8 = null,
    out_dir: ?[]const u8 = null,
    libs: std.ArrayList([]const u8) = .empty,
    lib_paths: std.ArrayList([]const u8) = .empty,
    link_flags: std.ArrayList([]const u8) = .empty,
    subsystem: u8 = 0, // 0 console, 1 windows (GUI)
    entry: ?[]const u8 = null,
    stack: u64 = 0,
    version: ?[]const u8 = null,
    description: ?[]const u8 = null,
    install: bool = false,
    /// 0 = dynamic (default), 1 = static. Static auto-links the C runtime.
    link_mode: u8 = 0,
    /// Files (e.g. a `.dll`) copied next to the output after building.
    runtime_files: std.ArrayList([]const u8) = .empty,
    /// Opt out of honoring a static C library's own `/DEFAULTLIB` directives
    /// (keep the strict `/NODEFAULTLIB` and list system deps yourself).
    no_default_libs: bool = false,
    /// Link the host's libc (`link_libc()`): the Windows CRT (ucrt+vcruntime) on
    /// Windows, glibc on Linux. Resolved per host below.
    link_libc: bool = false,
};

pub const StepKind = enum(u8) { run, test_dir };

pub const Step = struct {
    name: []const u8,
    kind: StepKind,
    target: usize = 0,
    dir: []const u8 = "",
};

pub const Dep = struct {
    name: []const u8,
    location: []const u8,
    kind: u8, // 0 path, 1 git
};

/// The configuration a `build.gab` produces. All strings are duped into `arena`,
/// so the plan outlives the FrontEnd the build script ran against.
pub const BuildPlan = struct {
    arena: std.heap.ArenaAllocator,
    artifacts: std.ArrayList(Artifact) = .empty,
    steps: std.ArrayList(Step) = .empty,
    deps: std.ArrayList(Dep) = .empty,
    default_idx: ?usize = null,
    /// Workspace-level metadata + default output directory for all artifacts.
    workspace_name: ?[]const u8 = null,
    out_root: ?[]const u8 = null,
    want_summary: bool = false,
    /// `-Dname` / `-Dname=value` build options forwarded from the CLI.
    options: []const []const u8 = &.{},
    oom: bool = false,

    fn init(gpa: std.mem.Allocator) BuildPlan {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    fn deinit(self: *BuildPlan) void {
        self.arena.deinit();
    }

    fn a(self: *BuildPlan) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn dupe(self: *BuildPlan, s: []const u8) []const u8 {
        return self.a().dupe(u8, s) catch {
            self.oom = true;
            return "";
        };
    }
};

// VM host-call bridge

fn argStr(args: []const Value, i: usize) []const u8 {
    if (i >= args.len) return "";
    return switch (args[i]) {
        .string => |s| s,
        else => "",
    };
}

fn argInt(args: []const Value, i: usize) i64 {
    if (i >= args.len) return 0;
    return @intCast(args[i].asI128() orelse 0);
}

/// Invoked by the `host_call` opcode for every `std.build` `__build_*` intrinsic.
fn hostCall(ctx: *anyopaque, op_raw: u32, args: []const Value) Value {
    const plan: *BuildPlan = @ptrCast(@alignCast(ctx));
    const op: BuildOp = @enumFromInt(op_raw);
    switch (op) {
        .artifact => {
            const kind: ArtifactKind = @enumFromInt(@as(u8, @intCast(argInt(args, 2))));
            const id = plan.artifacts.items.len;
            plan.artifacts.append(plan.a(), .{
                .name = plan.dupe(argStr(args, 0)),
                .root = plan.dupe(argStr(args, 1)),
                .kind = kind,
            }) catch {
                plan.oom = true;
                return .{ .int = 0 };
            };
            return .{ .int = @intCast(id) };
        },
        .opt => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) {
                plan.artifacts.items[id].opt = @intCast(@as(u8, @intCast(argInt(args, 1))) & 3);
            }
            return .void;
        },
        .link => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) {
                plan.artifacts.items[id].libs.append(plan.a(), plan.dupe(argStr(args, 1))) catch {
                    plan.oom = true;
                };
            }
            return .void;
        },
        .lib_path => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) {
                plan.artifacts.items[id].lib_paths.append(plan.a(), plan.dupe(argStr(args, 1))) catch {
                    plan.oom = true;
                };
            }
            return .void;
        },
        .output => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) {
                plan.artifacts.items[id].out_path = plan.dupe(argStr(args, 1));
            }
            return .void;
        },
        .define => {
            // Recorded for parity; comptime-define injection into the target build
            // lands with `#provided`. No-op for now.
            return .void;
        },
        .set_default => {
            plan.default_idx = @intCast(argInt(args, 0));
            return .void;
        },
        .run_step => {
            plan.steps.append(plan.a(), .{
                .name = plan.dupe(argStr(args, 0)),
                .kind = .run,
                .target = @intCast(argInt(args, 1)),
            }) catch {
                plan.oom = true;
            };
            return .void;
        },
        .test_dir => {
            plan.steps.append(plan.a(), .{
                .name = plan.dupe(argStr(args, 0)),
                .kind = .test_dir,
                .dir = plan.dupe(argStr(args, 1)),
            }) catch {
                plan.oom = true;
            };
            return .void;
        },
        .require => {
            const id = plan.deps.items.len;
            plan.deps.append(plan.a(), .{
                .name = plan.dupe(argStr(args, 0)),
                .location = plan.dupe(argStr(args, 1)),
                .kind = @intCast(@as(u8, @intCast(argInt(args, 2)))),
            }) catch {
                plan.oom = true;
                return .{ .int = 0 };
            };
            return .{ .int = @intCast(id) };
        },
        .depend => {
            // Dependency edges are recorded; the build-graph executor lands next.
            return .void;
        },
        .subsystem => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len)
                plan.artifacts.items[id].subsystem = @intCast(@as(u8, @intCast(argInt(args, 1))) & 1);
            return .void;
        },
        .entry => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) plan.artifacts.items[id].entry = plan.dupe(argStr(args, 1));
            return .void;
        },
        .stack => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) plan.artifacts.items[id].stack = @intCast(@max(argInt(args, 1), 0));
            return .void;
        },
        .link_flag => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len)
                plan.artifacts.items[id].link_flags.append(plan.a(), plan.dupe(argStr(args, 1))) catch {
                    plan.oom = true;
                };
            return .void;
        },
        .out_dir => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) plan.artifacts.items[id].out_dir = plan.dupe(argStr(args, 1));
            return .void;
        },
        .version => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) plan.artifacts.items[id].version = plan.dupe(argStr(args, 1));
            return .void;
        },
        .description => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) plan.artifacts.items[id].description = plan.dupe(argStr(args, 1));
            return .void;
        },
        .install => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) plan.artifacts.items[id].install = true;
            return .void;
        },
        .workspace => {
            plan.workspace_name = plan.dupe(argStr(args, 0));
            return .void;
        },
        .out_root => {
            plan.out_root = plan.dupe(argStr(args, 0));
            return .void;
        },
        .option_flag => return .{ .int = if (hasFlag(plan.options, argStr(args, 0))) 1 else 0 },
        .option_str => {
            if (findOption(plan.options, argStr(args, 0))) |v| return .{ .string = plan.dupe(v) };
            return .{ .string = argStr(args, 1) };
        },
        .summary => {
            plan.want_summary = argInt(args, 0) != 0;
            return .void;
        },
        .link_mode => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len)
                plan.artifacts.items[id].link_mode = @intCast(@as(u8, @intCast(argInt(args, 1))) & 1);
            return .void;
        },
        .runtime_file => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len)
                plan.artifacts.items[id].runtime_files.append(plan.a(), plan.dupe(argStr(args, 1))) catch {
                    plan.oom = true;
                };
            return .void;
        },
        .no_default_libs => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) plan.artifacts.items[id].no_default_libs = true;
            return .void;
        },
        .link_libc => {
            const id: usize = @intCast(argInt(args, 0));
            if (id < plan.artifacts.items.len) plan.artifacts.items[id].link_libc = true;
            return .void;
        },
    }
}

/// The value of a `-Dname=value` build option, or null if not set.
fn findOption(options: []const []const u8, name: []const u8) ?[]const u8 {
    for (options) |o| {
        const eq = std.mem.indexOfScalar(u8, o, '=') orelse continue;
        if (std.mem.eql(u8, o[0..eq], name)) return o[eq + 1 ..];
    }
    return null;
}

/// Whether a `-Dname` flag (bare or `name=...`) was passed.
fn hasFlag(options: []const []const u8, name: []const u8) bool {
    for (options) |o| {
        if (std.mem.eql(u8, o, name)) return true;
        const eq = std.mem.indexOfScalar(u8, o, '=') orelse continue;
        if (std.mem.eql(u8, o[0..eq], name)) return true;
    }
    return false;
}

// Options + entry

pub const RunOptions = struct {
    /// A requested target/step name (`gabbro build <name>`), or null for the default.
    target: ?[]const u8 = null,
    /// Override every artifact to a release optimization level.
    release: bool = false,
    /// Just print the artifacts and steps, build nothing.
    list: bool = false,
    quiet: bool = false,
    /// Force-link the C runtime for every artifact (`gabbro build --libc`), even if
    /// auto-detection didn't flag a static C lib. An escape hatch.
    link_libc: bool = false,
    /// LLVM bin dir + default library search paths, forwarded from the CLI.
    llvm_bin: []const u8 = "",
    lib_paths: []const []const u8 = &.{},
    /// Extra args passed through to a `run` step's executable.
    run_args: []const []const u8 = &.{},
    /// `-Dname` / `-Dname=value` build options, exposed to `b.option*` in build.gab.
    options: []const []const u8 = &.{},
};

/// Run `build_path` (a build.gab) and execute the resulting plan.
pub fn run(gpa: std.mem.Allocator, io: std.Io, build_path: []const u8, opts: RunOptions) BuildError!void {
    var plan = BuildPlan.init(gpa);
    defer plan.deinit();
    plan.options = opts.options; // visible to `b.option*` during the build hook

    // 1. Front-end the build script (resolves std.build + the runtime prelude).
    var fe = pipeline.compileFileWithRuntime(gpa, io, build_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CompileFailed,
    };
    defer fe.deinit(gpa);
    if (fe.diagnostics().len != 0) {
        const src = readSource(gpa, io, build_path);
        defer if (src) |s| gpa.free(s);
        for (fe.diagnostics()) |d| {
            const r = diagnostic.renderDiagnostic(gpa, build_path, src orelse "", d) catch continue;
            defer gpa.free(r);
            std.debug.print("{s}\n", .{r});
        }
        return error.CompileFailed;
    }

    // 2. Run `build(b)` on the comptime VM, recording into `plan`.
    const host = vm_engine.BuildHost{ .ctx = &plan, .call = hostCall };
    ir.runBuildHook(gpa, fe, host) catch return error.NoBuildFn;
    if (plan.oom) return error.OutOfMemory;
    if (plan.artifacts.items.len == 0) return error.NoArtifacts;

    if (opts.list) {
        printList(&plan);
        return;
    }

    // 3. Execute the plan.
    const base_dir = std.fs.path.dirname(build_path) orelse ".";
    try executePlan(gpa, io, &plan, base_dir, opts);
}

fn executePlan(gpa: std.mem.Allocator, io: std.Io, plan: *BuildPlan, base_dir: []const u8, opts: RunOptions) BuildError!void {
    // Resolve which artifact a run-step / target name refers to.
    var run_after: ?usize = null;
    var target_idx: ?usize = null;

    if (opts.target) |name| {
        // A step name?
        for (plan.steps.items) |st| {
            if (!std.mem.eql(u8, st.name, name)) continue;
            switch (st.kind) {
                .run => {
                    target_idx = st.target;
                    run_after = st.target;
                },
                .test_dir => return runTestDir(gpa, io, plan, base_dir, st.dir, opts),
            }
        }
        // An artifact name?
        if (target_idx == null) {
            for (plan.artifacts.items, 0..) |art, i| {
                if (std.mem.eql(u8, art.name, name)) target_idx = i;
            }
        }
        if (target_idx == null) {
            std.debug.print("gabbro build: no artifact or step named '{s}'\n", .{name});
            return error.UnknownTarget;
        }
    }

    // Which artifacts to build: the requested/default one, else all.
    if (target_idx) |idx| {
        try buildArtifact(gpa, io, plan, base_dir, idx, opts);
    } else if (plan.default_idx) |idx| {
        try buildArtifact(gpa, io, plan, base_dir, idx, opts);
    } else {
        for (0..plan.artifacts.items.len) |i| try buildArtifact(gpa, io, plan, base_dir, i, opts);
    }

    if (run_after) |idx| try runArtifact(gpa, io, plan, base_dir, idx, opts);

    if (plan.want_summary and !opts.quiet) printSummary(plan, base_dir);
}

/// A post-build summary of every artifact (kind, output path, opt level).
fn printSummary(plan: *BuildPlan, base_dir: []const u8) void {
    std.debug.print("\n── build summary", .{});
    if (plan.workspace_name) |w| std.debug.print(" · {s}", .{w});
    std.debug.print(" ──\n", .{});
    for (plan.artifacts.items) |art| {
        const out = resolveOutput(plan, base_dir, art) catch art.name;
        const opt = optName(art.opt);
        const inst: []const u8 = if (art.install) " [install]" else "";
        std.debug.print("  {s: <16} {s: <14} {s} ({s}){s}", .{ art.name, @tagName(art.kind), out, opt, inst });
        if (art.version) |v| std.debug.print(" v{s}", .{v});
        std.debug.print("\n", .{});
    }
}

fn buildArtifact(gpa: std.mem.Allocator, io: std.Io, plan: *BuildPlan, base_dir: []const u8, idx: usize, opts: RunOptions) BuildError!void {
    const art = plan.artifacts.items[idx];
    const a = plan.a();

    const root_path = joinPath(a, base_dir, art.root) catch return error.OutOfMemory;
    const out_path = try resolveOutput(plan, base_dir, art);
    const obj_path = std.fmt.allocPrint(a, "{s}.o", .{out_path}) catch return error.OutOfMemory;

    // Make sure the output directory exists (e.g. `bin/`, `out/`).
    if (std.fs.path.dirname(out_path)) |dir| {
        if (dir.len != 0) std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }

    // Library search paths: the CLI defaults + the artifact's own + the project
    // dir itself, so a `raylib.lib` sitting next to `build.gab` links regardless of
    // the working directory `gabbro build` was invoked from.
    var lib_paths: std.ArrayList([]const u8) = .empty;
    lib_paths.appendSlice(a, opts.lib_paths) catch return error.OutOfMemory;
    for (art.lib_paths.items) |lp| {
        const abs = joinPath(a, base_dir, lp) catch return error.OutOfMemory;
        lib_paths.append(a, abs) catch return error.OutOfMemory;
    }
    lib_paths.append(a, base_dir) catch return error.OutOfMemory;

    const opt_level: u2 = if (opts.release and art.opt == 0) 2 else art.opt;
    const is_lib = art.kind == .shared_library or art.kind == .static_library;
    const stop_at_obj = art.kind == .object;

    // Auto-detect each linked library by peeking inside the `.lib`: a static
    // archive needs the C runtime; an import library's sibling DLL is copied next
    // to the output. We search the artifact's own lib paths PLUS the project dir
    // itself — the linker also looks in the working directory, so running
    // `gabbro build` from a vendor lib folder (where `raylib.lib` sits next to
    // `build.gab`) still triggers detection. Explicit static_link()/runtime_file()
    // still apply on top of this.
    var search_dirs: std.ArrayList([]const u8) = .empty;
    for (art.lib_paths.items) |lp|
        search_dirs.append(a, joinPath(a, base_dir, lp) catch continue) catch {};
    search_dirs.append(a, base_dir) catch {};

    var need_libc = art.link_mode == 1 or opts.link_libc or art.link_libc;
    var auto_dlls: std.ArrayList([]const u8) = .empty;
    for (art.libs.items) |lib_name| {
        for (search_dirs.items) |dir| {
            const lib_file = std.fmt.allocPrint(a, "{s}/{s}.lib", .{ dir, lib_name }) catch continue;
            const data = readSource(gpa, io, lib_file) orelse continue;
            defer gpa.free(data);
            switch (inspectLib(a, data)) {
                .static => need_libc = true,
                .import_lib => |dll| if (dll.len != 0) {
                    // `static_link()` asserts intent: warn if the resolved lib is
                    // actually an import library (you'll get a dynamic link).
                    if (art.link_mode == 1)
                        std.debug.print("gabbro build: warning: '{s}' requested static linking, but '{s}/{s}.lib' is an import library — the link will be DYNAMIC. Point lib_path at the static archive.\n", .{ lib_name, dir, lib_name });
                    auto_dlls.append(a, joinPath(a, dir, dll) catch continue) catch {};
                    if (!opts.quiet) std.debug.print("  {s} → dynamic ({s})\n", .{ lib_name, dll });
                },
                .unknown => {},
            }
            break; // found the lib on this path; stop searching
        }
    }

    // Libraries to link: the artifact's own, plus the C runtime when a static C
    // library is involved (it brings code but not the CRT it depends on).
    var libs: std.ArrayList([]const u8) = .empty;
    libs.appendSlice(a, art.libs.items) catch return error.OutOfMemory;
    // "Link libc" resolves per host: the Windows CRT (ucrt + vcruntime) here; on
    // Linux the driver's `link_libc` path links glibc instead (no Windows libs).
    if (need_libc and builtin.os.tag == .windows) {
        libs.append(a, "ucrt") catch return error.OutOfMemory;
        libs.append(a, "vcruntime") catch return error.OutOfMemory;
    }

    // When a static C library is involved, honor ITS own `/DEFAULTLIB` directives
    // by default — so its system deps (opengl32, gdi32, …) flow in automatically,
    // C3-style — unless the artifact opted out with `no_default_libs()`.
    const honor_defaultlibs = need_libc and !art.no_default_libs;

    const src = readSource(gpa, io, root_path);
    defer if (src) |s| gpa.free(s);

    if (!opts.quiet) std.debug.print("  building {s} ({s})\n", .{ art.name, root_path });

    driver.compileFileWithLlvm(gpa, io, .{
        .file_name = root_path,
        .source = src orelse "",
        .obj_path = obj_path,
        .exe_path = if (stop_at_obj) null else out_path,
        .dll = is_lib,
        .opt_level = opt_level,
        .llvm_bin = opts.llvm_bin,
        .lib_paths = lib_paths.items,
        .extra_libs = libs.items,
        .subsystem = if (art.subsystem == 1) .windows else .console,
        .entry = art.entry,
        .stack_reserve = art.stack,
        .link_flags = art.link_flags.items,
        .honor_defaultlibs = honor_defaultlibs,
        .link_libc = need_libc,
    }) catch |err| {
        std.debug.print("gabbro build: failed to build '{s}': {s}\n", .{ art.name, @errorName(err) });
        return error.CompileFailed;
    };

    if (!opts.quiet) std.debug.print("  \u{2713} {s}\n", .{out_path});

    // Copy runtime dependencies next to the output — both the explicit
    // `runtime_file`s and the DLLs auto-detected from import libraries — so a
    // dynamically-linked program runs without manually shipping its DLLs.
    const out_dir = std.fs.path.dirname(out_path) orelse ".";
    var copy_srcs: std.ArrayList([]const u8) = .empty;
    for (art.runtime_files.items) |rf| copy_srcs.append(a, joinPath(a, base_dir, rf) catch continue) catch {};
    copy_srcs.appendSlice(a, auto_dlls.items) catch {};
    for (copy_srcs.items) |csrc| {
        const dst = joinPath(a, out_dir, std.fs.path.basename(csrc)) catch continue;
        if (std.mem.eql(u8, csrc, dst)) continue; // already in place
        const data = readSource(gpa, io, csrc) orelse {
            std.debug.print("gabbro build: runtime file not found: {s}\n", .{csrc});
            continue;
        };
        defer gpa.free(data);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = data }) catch continue;
        if (!opts.quiet) std.debug.print("  \u{2713} {s}\n", .{dst});
    }
}

fn runArtifact(gpa: std.mem.Allocator, io: std.Io, plan: *BuildPlan, base_dir: []const u8, idx: usize, opts: RunOptions) BuildError!void {
    const art = plan.artifacts.items[idx];
    const out_path = try resolveOutput(plan, base_dir, art);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    argv.append(gpa, out_path) catch return error.OutOfMemory;
    argv.appendSlice(gpa, opts.run_args) catch return error.OutOfMemory;

    if (!opts.quiet) std.debug.print("  running {s}\n", .{out_path});
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return error.RunFailed;
    const term = child.wait(io) catch return error.RunFailed;
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("  {s} exited with code {d}\n", .{ art.name, code });
        },
        else => return error.RunFailed,
    }
}

/// Run a `test_dir` step: compile + run every `*.gab` file directly under `dir`
/// as a standalone program. A test passes when it exits 0. Reports each result
/// and a pass/fail tally; fails the step if any test fails.
fn runTestDir(gpa: std.mem.Allocator, io: std.Io, plan: *BuildPlan, base_dir: []const u8, dir_rel: []const u8, opts: RunOptions) BuildError!void {
    const a = plan.a();
    const dir_abs = joinPath(a, base_dir, dir_rel) catch return error.OutOfMemory;

    var dir = std.Io.Dir.cwd().openDir(io, dir_abs, .{ .iterate = true }) catch {
        std.debug.print("gabbro build: cannot open test directory '{s}'\n", .{dir_abs});
        return error.RunFailed;
    };
    defer dir.close(io);
    std.Io.Dir.cwd().createDirPath(io, ".zig-cache/gabbrotest") catch {};

    if (!opts.quiet) std.debug.print("running tests in {s}/\n", .{dir_abs});
    var passed: u32 = 0;
    var failed: u32 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".gab")) continue;
        // `entry.name` is only valid until the next iteration — copy it.
        const name = a.dupe(u8, entry.name) catch continue;
        const src_path = joinPath(a, dir_abs, name) catch continue;
        const exe = std.fmt.allocPrint(a, ".zig-cache/gabbrotest/{s}.exe", .{name}) catch continue;
        const obj = std.fmt.allocPrint(a, "{s}.o", .{exe}) catch continue;
        const src = readSource(gpa, io, src_path) orelse continue;
        defer gpa.free(src);

        const ok = blk: {
            driver.compileFileWithLlvm(gpa, io, .{
                .file_name = src_path,
                .source = src,
                .obj_path = obj,
                .exe_path = exe,
                .opt_level = 0,
                .llvm_bin = opts.llvm_bin,
                .lib_paths = opts.lib_paths,
            }) catch break :blk false;
            var child = std.process.spawn(io, .{
                .argv = &.{exe},
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch break :blk false;
            break :blk switch (child.wait(io) catch break :blk false) {
                .exited => |code| code == 0,
                else => false,
            };
        };
        if (ok) {
            passed += 1;
            if (!opts.quiet) std.debug.print("  \u{2713} {s}\n", .{name});
        } else {
            failed += 1;
            std.debug.print("  \u{2717} {s}\n", .{name});
        }
    }

    std.debug.print("\n{d} passed, {d} failed\n", .{ passed, failed });
    if (failed != 0) return error.RunFailed;
}

// Library inspection (import lib vs static archive)

const LibKind = union(enum) {
    /// A static archive (regular COFF object members) — needs the C runtime.
    static,
    /// An import library — the value is the DLL its symbols come from.
    import_lib: []const u8,
    /// Not a recognizable COFF `.lib` archive.
    unknown,
};

/// Classify a Windows COFF `.lib`: an import library carries an
/// `__IMPORT_DESCRIPTOR_<dll>` symbol (true for both the short- and long-import
/// forms); a static archive doesn't. Returns the DLL name for an import lib.
fn inspectLib(arena: std.mem.Allocator, bytes: []const u8) LibKind {
    const magic = "!<arch>\n";
    if (bytes.len < magic.len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return .unknown;
    const needle = "__IMPORT_DESCRIPTOR_";
    const at = std.mem.indexOf(u8, bytes, needle) orelse return .static;
    var p = at + needle.len;
    const start = p;
    while (p < bytes.len and (std.ascii.isAlphanumeric(bytes[p]) or bytes[p] == '_')) p += 1;
    if (p == start) return .static;
    const dll = std.fmt.allocPrint(arena, "{s}.dll", .{bytes[start..p]}) catch return .static;
    return .{ .import_lib = dll };
}

// Helpers

fn resolveOutput(plan: *BuildPlan, base_dir: []const u8, art: Artifact) BuildError![]const u8 {
    const a = plan.a();
    if (art.out_path) |p| return joinPath(a, base_dir, p) catch return error.OutOfMemory;
    const ext = switch (art.kind) {
        .executable => ".exe",
        .shared_library => ".dll",
        .static_library => ".lib",
        .object => ".o",
    };
    const name = std.fmt.allocPrint(a, "{s}{s}", .{ art.name, ext }) catch return error.OutOfMemory;
    // Output directory precedence: per-artifact out_dir, then the workspace
    // out_root, then alongside the build script.
    if (art.out_dir orelse plan.out_root) |dir| {
        const out_dir_abs = joinPath(a, base_dir, dir) catch return error.OutOfMemory;
        return joinPath(a, out_dir_abs, name) catch return error.OutOfMemory;
    }
    return joinPath(a, base_dir, name) catch return error.OutOfMemory;
}

fn joinPath(a: std.mem.Allocator, base: []const u8, rel: []const u8) ![]const u8 {
    if (base.len == 0 or std.mem.eql(u8, base, ".")) return a.dupe(u8, rel);
    return std.fs.path.join(a, &.{ base, rel });
}

fn readSource(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch null;
}

fn optName(opt: u2) []const u8 {
    return switch (opt) {
        0 => "debug",
        1 => "release-safe",
        2 => "release-fast",
        3 => "release-small",
    };
}

fn printList(plan: *BuildPlan) void {
    if (plan.workspace_name) |w| std.debug.print("workspace: {s}\n", .{w});
    std.debug.print("artifacts:\n", .{});
    for (plan.artifacts.items, 0..) |art, i| {
        const star: []const u8 = if (plan.default_idx == i) " (default)" else "";
        std.debug.print("  {s: <16} {s: <14} {s}{s}", .{ art.name, @tagName(art.kind), optName(art.opt), star });
        if (art.version) |v| std.debug.print(" v{s}", .{v});
        if (art.install) std.debug.print(" [install]", .{});
        if (art.libs.items.len != 0) {
            std.debug.print("  links:", .{});
            for (art.libs.items) |l| std.debug.print(" {s}", .{l});
        }
        std.debug.print("\n", .{});
        if (art.description) |d| std.debug.print("    {s}\n", .{d});
    }
    if (plan.steps.items.len != 0) {
        std.debug.print("steps:\n", .{});
        for (plan.steps.items) |st| {
            const detail: []const u8 = switch (st.kind) {
                .run => if (st.target < plan.artifacts.items.len) plan.artifacts.items[st.target].name else "",
                .test_dir => st.dir,
            };
            std.debug.print("  {s: <16} {s: <10} {s}\n", .{ st.name, @tagName(st.kind), detail });
        }
    }
}
