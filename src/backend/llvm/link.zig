/// Windows link step.
///
/// To link manually after emitObject("output.o"):
///   lld-link output.o /OUT:output.exe /SUBSYSTEM:CONSOLE /ENTRY:mainCRTStartup /NODEFAULTLIB kernel32.lib
const std = @import("std");
const builtin = @import("builtin");

// In-process LLD via gabbrolld.dll (built with `-Din-process-lld`). Loaded
// dynamically, so when the DLL is absent we transparently fall back to spawning
// lld-link.exe. The DLL exports a single C entry point; loading it lazily avoids
// any build-time dependency.
const win = struct {
    extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetModuleHandleA(lpModuleName: ?[*:0]const u8) callconv(.winapi) ?*anyopaque;
};

const LldLinkFn = *const fn (argc: c_int, argv: [*]const [*:0]const u8) callconv(.c) c_int;

// The Gabbro-written linker (gabld.dll), exporting `gabbro_link(in_obj, out_exe) -> int`.
const GabbroLinkFn = *const fn (in_path: [*:0]const u8, out_path: [*:0]const u8) callconv(.c) c_int;

/// gabld links a single COFF object into an exe or DLL. It reads the compiler's
/// `.skimp`/`.skexp` maps (so it needs no `.lib`), handles any DLL set, subsystem,
/// entry, stack, and DLL output. It bails (→ LLD) only on multiple objects,
/// arbitrary linker flags, or a C library's `/DEFAULTLIB` (static-CRT objects).
fn gabldEligible(opts: WindowsLinkOptions) bool {
    if (opts.obj_files.len != 1) return false;
    if (opts.extra_flags.len != 0) return false;
    if (opts.honor_defaultlibs) return false;
    return true;
}

/// Try the Gabbro-written linker (gabld.dll) — the self-hosted fast path. Returns
/// null when unavailable/ineligible (use LLD), true on success, false on a
/// reported link failure (also falls back to LLD).
fn tryGabld(allocator: std.mem.Allocator, opts: WindowsLinkOptions) ?bool {
    if (builtin.os.tag != .windows) return null;
    if (!gabldEligible(opts)) return null;
    // The file entry point (`gabbro_link`) uses default console-exe settings — a DLL /
    // GUI / custom entry / stack build must go through the in-memory path
    // (`gabbro_link_mem`), which carries those. Fall to LLD here.
    if (opts.dll or opts.subsystem != .console or opts.entry != null or opts.stack_reserve != 0) return null;
    const module = win.LoadLibraryA("gabld.dll") orelse return null;
    const proc = win.GetProcAddress(module, "gabbro_link") orelse return null;
    const link_fn: GabbroLinkFn = @ptrCast(proc);
    const obj_z = allocator.dupeZ(u8, opts.obj_files[0]) catch return false;
    defer allocator.free(obj_z);
    const out_z = allocator.dupeZ(u8, opts.output) catch return false;
    defer allocator.free(out_z);
    return link_fn(obj_z.ptr, out_z.ptr) == 0;
}

// In-memory variant: gabld reads the object bytes directly — no .obj on disk —
// plus the PE settings (subsystem / entry / stack / DLL) the compiler knows.
const GabbroLinkMemFn = *const fn (
    obj_ptr: [*]const u8,
    obj_len: usize,
    out_path: [*:0]const u8,
    subsystem: u32,
    entry: [*:0]const u8,
    stack_reserve: u64,
    is_dll: u32,
) callconv(.c) c_int;

// When gabld is statically linked into gabbro.exe (`-Dembed-linker`), it is exported
// from the exe itself, so we find it with GetProcAddress on our own module; else
// we load `gabld.dll`. (A weak `@extern` would be cleaner but COFF weak externs
// don't null-check reliably in Zig — they resolve to a 0 we'd call.)
fn resolveGabld() ?GabbroLinkMemFn {
    const self = win.GetModuleHandleA(null) orelse return null;
    if (win.GetProcAddress(self, "gabbro_link_mem")) |p| return @ptrCast(p); // embedded
    const dll = win.LoadLibraryA("gabld.dll") orelse return null;
    const proc = win.GetProcAddress(dll, "gabbro_link_mem") orelse return null;
    return @ptrCast(proc);
}

fn tryGabldMem(allocator: std.mem.Allocator, obj_bytes: []const u8, opts: WindowsLinkOptions) ?bool {
    if (builtin.os.tag != .windows) return null;
    if (!gabldEligible(opts)) return null;
    const link_fn = resolveGabld() orelse return null;
    const out_z = allocator.dupeZ(u8, opts.output) catch return false;
    defer allocator.free(out_z);
    const entry_z = allocator.dupeZ(u8, opts.entry orelse "") catch return false;
    defer allocator.free(entry_z);
    const subsystem: u32 = switch (opts.subsystem) {
        .console => 3,
        .windows => 2,
    };
    const is_dll: u32 = if (opts.dll) 1 else 0;
    return link_fn(obj_bytes.ptr, obj_bytes.len, out_z.ptr, subsystem, entry_z.ptr, @intCast(opts.stack_reserve), is_dll) == 0;
}

/// Try the in-process linker. Returns null if gabbrolld.dll is unavailable (caller
/// should fall back to spawning), true on a successful link, false on failure.
fn tryInProcess(allocator: std.mem.Allocator, args: []const []const u8) ?bool {
    if (builtin.os.tag != .windows) return null;
    const module = win.LoadLibraryA("gabbrolld.dll") orelse return null;
    const proc = win.GetProcAddress(module, "gabbro_lld_link_coff") orelse return null;
    const link_fn: LldLinkFn = @ptrCast(proc);

    var argv: std.ArrayList([*:0]const u8) = .empty;
    defer {
        for (argv.items[1..]) |a| allocator.free(std.mem.span(a));
        argv.deinit(allocator);
    }
    // argv[0] is the linker name (diagnostics only); the rest are the real args,
    // skipping `args[0]` which is the lld-link.exe path used for spawning.
    argv.append(allocator, "lld-link") catch return null;
    for (args[1..]) |a| {
        const z = allocator.dupeZ(u8, a) catch return false;
        argv.append(allocator, z.ptr) catch return false;
    }
    return link_fn(@intCast(argv.items.len), argv.items.ptr) == 0;
}

pub const LinkError = error{
    OutOfMemory,
    SpawnFailed,
    WaitFailed,
    ProcessTerminated,
    ExitCodeFailure,
};

/// PE subsystem: a console app gets a terminal window, a `windows` (GUI) app
/// doesn't — what you want for a game/windowed program (raylib, etc.).
pub const Subsystem = enum { console, windows };

pub const WindowsLinkOptions = struct {
    /// Directory containing lld-link.exe (e.g. <llvm>/bin).
    llvm_bin: []const u8,
    /// Object files to link.
    obj_files: []const []const u8,
    /// Output executable path.
    output: []const u8,
    /// Extra /LIBPATH: directories for kernel32.lib etc.
    lib_paths: []const []const u8 = &.{},
    /// Import library names (without the `.lib` extension) to link against,
    /// e.g. `&.{"raylib"}` becomes `raylib.lib` on the link command line.
    /// Resolved via `lib_paths` and the linker's default search paths.
    libs: []const []const u8 = &.{},
    /// Produce a DLL (shared library) instead of an executable. Uses `/DLL`
    /// with `/NOENTRY` (no CRT entry); `#export`ed functions are exported via
    /// their dllexport directives. This is how `gabld.dll` is built.
    dll: bool = false,
    /// PE subsystem for executables (console window or not).
    subsystem: Subsystem = .console,
    /// Override the entry symbol (default: `mainCRTStartup`).
    entry: ?[]const u8 = null,
    /// Reserve this many bytes of stack (`/STACK:`); 0 = the default.
    stack_reserve: u64 = 0,
    /// Raw flags passed verbatim to the linker — an escape hatch for anything
    /// the structured options don't cover.
    extra_flags: []const []const u8 = &.{},
    /// Honor the `/DEFAULTLIB` directives embedded in the linked objects/archives
    /// (a C library's own system deps — opengl32, gdi32, …), instead of blanket
    /// `/NODEFAULTLIB`. Only the CRT-startup umbrella libs are suppressed (they'd
    /// clash with Gabbro's own entry); the C runtime is provided via `ucrt`/`vcruntime`.
    honor_defaultlibs: bool = false,
};

/// Build the lld-link command line as a slice of argument strings (caller frees).
pub fn buildArgs(allocator: std.mem.Allocator, opts: WindowsLinkOptions) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);

    try args.append(allocator, try std.fmt.allocPrint(allocator, "{s}/lld-link.exe", .{opts.llvm_bin}));
    for (opts.obj_files) |obj| try args.append(allocator, try allocator.dupe(u8, obj));
    try args.append(allocator, try std.fmt.allocPrint(allocator, "/OUT:{s}", .{opts.output}));
    if (opts.dll) {
        // Shared library: no CRT entry point — `/NOENTRY` makes it a pure
        // code+exports container; exports come from dllexport directives.
        try args.append(allocator, try allocator.dupe(u8, "/DLL"));
        try args.append(allocator, try allocator.dupe(u8, "/NOENTRY"));
    } else {
        const sub = switch (opts.subsystem) {
            .console => "CONSOLE",
            .windows => "WINDOWS",
        };
        try args.append(allocator, try std.fmt.allocPrint(allocator, "/SUBSYSTEM:{s}", .{sub}));
        try args.append(allocator, try std.fmt.allocPrint(allocator, "/ENTRY:{s}", .{opts.entry orelse "mainCRTStartup"}));
        if (opts.stack_reserve != 0)
            try args.append(allocator, try std.fmt.allocPrint(allocator, "/STACK:{d}", .{opts.stack_reserve}));
    }
    if (opts.honor_defaultlibs) {
        // Honor the linked C library's own `/DEFAULTLIB` directives (so its system
        // deps — opengl32, gdi32, winmm, … — flow in automatically, C3-style), but
        // suppress only the CRT-startup *umbrella* libs: they provide their own
        // `mainCRTStartup`/`_DllMainCRTStartup` which would clash with Gabbro's entry.
        // The actual C runtime (malloc/__chkstk/…) comes from ucrt+vcruntime, which
        // the build links explicitly and which carry no startup.
        const crt_umbrellas = [_][]const u8{ "libcmt", "libcmtd", "msvcrt", "msvcrtd", "libc", "libcd" };
        for (crt_umbrellas) |u|
            try args.append(allocator, try std.fmt.allocPrint(allocator, "/NODEFAULTLIB:{s}", .{u}));
    } else {
        // Strict: ignore every embedded `/DEFAULTLIB` directive (Gabbro's minimal-runtime default).
        try args.append(allocator, try allocator.dupe(u8, "/NODEFAULTLIB"));
    }
    try args.append(allocator, try allocator.dupe(u8, "kernel32.lib"));
    for (opts.lib_paths) |lp|
        try args.append(allocator, try std.fmt.allocPrint(allocator, "/LIBPATH:{s}", .{lp}));
    for (opts.libs) |lib|
        try args.append(allocator, try std.fmt.allocPrint(allocator, "{s}.lib", .{lib}));
    for (opts.extra_flags) |f|
        try args.append(allocator, try allocator.dupe(u8, f));

    return args.toOwnedSlice(allocator);
}

/// Print the link command to stderr for manual execution.
pub fn printCommand(allocator: std.mem.Allocator, opts: WindowsLinkOptions) void {
    const args = buildArgs(allocator, opts) catch return;
    defer {
        for (args) |a| allocator.free(@constCast(a));
        allocator.free(args);
    }
    std.debug.print("Link command:\n  ", .{});
    for (args) |a| std.debug.print("{s} ", .{a});
    std.debug.print("\n", .{});
}

/// The LLD path: in-process (gabbrolld.dll) if available, else spawn lld-link.exe.
/// Reads the object(s) from disk (lld needs files).
fn linkWithLld(allocator: std.mem.Allocator, io: std.Io, opts: WindowsLinkOptions) LinkError!void {
    const args = buildArgs(allocator, opts) catch return error.OutOfMemory;
    defer {
        for (args) |a| allocator.free(@constCast(a));
        allocator.free(args);
    }

    if (tryInProcess(allocator, args)) |ok| {
        return if (ok) {} else error.ExitCodeFailure;
    }

    var child = std.process.spawn(io, .{
        .argv = args,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return error.SpawnFailed;

    const term = child.wait(io) catch return error.WaitFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.ExitCodeFailure,
        .signal, .stopped, .unknown => return error.ProcessTerminated,
    }
}

// Linux / ELF linking

pub const LinuxLinkOptions = struct {
    /// Directory containing `ld.lld[.exe]` (e.g. <llvm>/bin). Empty = use PATH.
    llvm_bin: []const u8 = "",
    output: []const u8,
    lib_paths: []const []const u8 = &.{},
    /// Libraries to link (`-l<name>`), e.g. "c" when the user opts into libc.
    libs: []const []const u8 = &.{},
    entry: []const u8 = "_start",
    extra_flags: []const []const u8 = &.{},
    /// Dynamically link against glibc (the `linux-gnu` ABI) instead of producing
    /// a static, freestanding ELF.
    link_libc: bool = false,
    /// Sysroot holding `libc.so.6` for a `link_libc` build (the dynamic linker is
    /// referenced at the standard target path).
    sysroot: []const u8 = "",
};

/// Link a single ELF object into a **static, non-PIE** Linux executable via
/// `ld.lld`. Freestanding by default (no libc) — a pure-Gabbro program has zero
/// dynamic dependencies. libc is pulled in only when the user's `#extern` /
/// `build.gab` adds `-lc`. Runs `ld.lld` on the host (cross-linking from Windows
/// works since LLD is target-agnostic).
pub fn linkLinux(
    allocator: std.mem.Allocator,
    io: std.Io,
    obj_path: []const u8,
    obj_bytes: []const u8,
    opts: LinuxLinkOptions,
) LinkError!void {
    // ld.lld reads the object from disk.
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = obj_path, .data = obj_bytes }) catch return error.OutOfMemory;

    var argv: std.ArrayList([]const u8) = .empty;
    defer {
        for (argv.items) |a| allocator.free(@constCast(a));
        argv.deinit(allocator);
    }
    const append = struct {
        fn one(a: std.mem.Allocator, list: *std.ArrayList([]const u8), s: []const u8) LinkError!void {
            list.append(a, a.dupe(u8, s) catch return error.OutOfMemory) catch return error.OutOfMemory;
        }
    }.one;

    const ld_name = if (builtin.os.tag == .windows) "ld.lld.exe" else "ld.lld";
    if (opts.llvm_bin.len > 0)
        try argv.append(allocator, std.fmt.allocPrint(allocator, "{s}/{s}", .{ opts.llvm_bin, ld_name }) catch return error.OutOfMemory)
    else
        try append(allocator, &argv, ld_name);

    try append(allocator, &argv, obj_path);
    if (opts.link_libc) {
        // Dynamically linked against glibc. Link libc.so.6 directly (a minimal
        // sysroot has no `libc.so` dev symlink), and point the interpreter at the
        // standard target path. Our `_start` calls __libc_start_main from libc.
        if (opts.sysroot.len > 0)
            try argv.append(allocator, std.fmt.allocPrint(allocator, "{s}/libc.so.6", .{opts.sysroot}) catch return error.OutOfMemory);
        try append(allocator, &argv, "-o");
        try append(allocator, &argv, opts.output);
        try append(allocator, &argv, "-dynamic-linker");
        try append(allocator, &argv, "/lib64/ld-linux-x86-64.so.2");
    } else {
        try append(allocator, &argv, "-o");
        try append(allocator, &argv, opts.output);
        try append(allocator, &argv, "-static"); // freestanding, ET_EXEC (no PIE / dynamic linker)
    }
    try append(allocator, &argv, "-e");
    try append(allocator, &argv, opts.entry);
    // Search the sysroot too, so `#extern("<lib>", …)` libraries (`-l<lib>`)
    // resolve from it (e.g. a libm.so the user dropped in alongside libc.so.6).
    if (opts.link_libc and opts.sysroot.len > 0)
        try argv.append(allocator, std.fmt.allocPrint(allocator, "-L{s}", .{opts.sysroot}) catch return error.OutOfMemory);
    for (opts.lib_paths) |p|
        try argv.append(allocator, std.fmt.allocPrint(allocator, "-L{s}", .{p}) catch return error.OutOfMemory);
    for (opts.libs) |l| {
        // In glibc mode, `#extern("c", …)` adds `c`, but libc.so.6 is already
        // linked directly — drop the redundant `-lc` (a minimal sysroot has no
        // `libc.so` for the linker to find).
        if (opts.link_libc and std.mem.eql(u8, l, "c")) continue;
        try argv.append(allocator, std.fmt.allocPrint(allocator, "-l{s}", .{l}) catch return error.OutOfMemory);
    }
    for (opts.extra_flags) |f| try append(allocator, &argv, f);

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return error.SpawnFailed;
    const term = child.wait(io) catch return error.WaitFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.ExitCodeFailure,
        .signal, .stopped, .unknown => return error.ProcessTerminated,
    }
}

/// A concrete reason the fast gabld path can't be used (null = it *would* have
/// been eligible, so the only explanation is gabld.dll being absent/failing —
/// not worth warning about, e.g. in the test runner). Used to explain the
/// slower LLD fallback to the user. These are exactly gabld's current gaps.
fn lldFallbackReason(opts: WindowsLinkOptions, obj_bytes: ?[]const u8) ?[]const u8 {
    if (opts.obj_files.len != 1) return "multiple object files (gabld links one object)";
    if (opts.extra_flags.len != 0) return "extra raw linker flags gabld can't apply";
    if (opts.honor_defaultlibs)
        return "honoring a C library's /DEFAULTLIB directives (gabld can't parse them)";
    _ = obj_bytes;
    return null;
}

fn noteLldFallback(opts: WindowsLinkOptions, obj_bytes: ?[]const u8) void {
    const reason = lldFallbackReason(opts, obj_bytes) orelse return;
    std.debug.print("note: linked with LLD — the gabld fast path was skipped ({s})\n", .{reason});
}

/// Link from object files on disk. Prefers the self-hosted Gabbro linker (gabld.dll),
/// then LLD.
pub fn windows(allocator: std.mem.Allocator, io: std.Io, opts: WindowsLinkOptions) LinkError!void {
    if (tryGabld(allocator, opts)) |ok| {
        if (ok) return;
    }
    noteLldFallback(opts, null);
    return linkWithLld(allocator, io, opts);
}

/// Link straight from in-memory object bytes — no `.obj` on disk. Hands the
/// bytes to gabld; only when gabld can't handle it (absent/ineligible/failed)
/// does it spill the object to `opts.obj_files[0]` and fall back to LLD.
pub fn windowsMem(allocator: std.mem.Allocator, io: std.Io, obj_bytes: []const u8, opts: WindowsLinkOptions) LinkError!void {
    if (tryGabldMem(allocator, obj_bytes, opts)) |ok| {
        if (ok) return;
    }
    noteLldFallback(opts, obj_bytes);
    // Spill the object so LLD can read it, then take the LLD path.
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = opts.obj_files[0], .data = obj_bytes }) catch return error.OutOfMemory;
    return linkWithLld(allocator, io, opts);
}
