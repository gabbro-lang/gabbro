const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Optional LLVM backend ─────────────────────────────────────────────
    // Pass `-Dllvm-path=C:\LLVM` (or wherever LLVM is installed) to enable.
    // When omitted, the LLVM backend compiles but is a no-op at runtime.
    const llvm_path = b.option(
        []const u8,
        "llvm-path",
        "Path to LLVM installation (enables LLVM codegen backend)",
    );
    const windows_sdk_lib_path = b.option(
        []const u8,
        "windows-sdk-lib-path",
        "Path to Windows SDK um/x64 lib directory (for kernel32.lib)",
    ) orelse "C:/Program Files (x86)/Windows Kits/10/Lib/10.0.26100.0/um/x64";
    const msvc_lib_path = b.option(
        []const u8,
        "msvc-lib-path",
        "Path to the MSVC lib/x64 directory (for `link_libc`: vcruntime.lib, libcmt.lib)",
    ) orelse "";
    const stdlib_root = b.option(
        []const u8,
        "stdlib-root",
        "Path to the K2 modules directory containing std/",
    ) orelse b.pathFromRoot("lib");

    // Statically link the self-hosted linker (k2lnk) into k2.exe for a
    // single-binary release (no separate k2lnk.dll). Two-stage: the base k2.exe
    // compiles linker/k2lnk.k2 to a freestanding object, which the final k2.exe
    // links in and exports. Dev builds leave this off and ship the dll.
    const embed_linker = b.option(bool, "embed-linker", "Bake k2lnk into k2.exe (single-binary release)") orelse false;

    // ── Compiler library module ───────────────────────────────────────────
    const compiler_mod = b.addModule("k2_compiler", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Build option that drives conditional LLVM compilation.
    const opts = b.addOptions();
    opts.addOption(bool, "enable_llvm", llvm_path != null);
    opts.addOption([]const u8, "llvm_path", llvm_path orelse "");
    opts.addOption([]const u8, "windows_sdk_lib_path", windows_sdk_lib_path);
    opts.addOption([]const u8, "msvc_lib_path", msvc_lib_path);
    opts.addOption([]const u8, "stdlib_root", stdlib_root);
    // Single version source: build.zig.zon, with a best-effort `+<git-sha>` so
    // dev/nightly builds are identifiable. Overridable with `-Dversion=...`.
    const base_version = @import("build.zig.zon").version;
    const version = b.option([]const u8, "version", "Override the reported version") orelse
        gitVersion(b, base_version);
    opts.addOption([]const u8, "version", version);
    compiler_mod.addOptions("build_options", opts);

    // Embed the bump-allocator stdlib so a `zone` block (whose handle is a real
    // `std.heap.Arena`) works in every compile path — including the inline
    // `compile(source)` path that never touches disk. `@embedFile` resolves
    // these import names; the files remain the single source of truth in lib/.
    compiler_mod.addAnonymousImport("std_heap_k2", .{ .root_source_file = b.path("lib/std/heap.sk") });
    compiler_mod.addAnonymousImport("std_ptr_k2", .{ .root_source_file = b.path("lib/std/ptr.sk") });

    // Wire LLVM into the compiler library when a path is provided.
    if (llvm_path) |lp| {
        // Use b.fmt to avoid pathJoin stripping backslashes on Windows absolute paths.
        compiler_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{lp}) });
        compiler_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{lp}) });
        // Link the unified LLVM library.  Name varies by installation:
        //   Windows prebuilt (llvm.org): LLVM-C
        //   Linux/macOS:                 LLVM-17 / LLVM
        compiler_mod.linkSystemLibrary("LLVM-C", .{});
        // libclang (the C binding generator, `k2 bindgen`) is deliberately NOT
        // linked: the include path above gives `@cImport` its types, but the
        // functions are loaded at runtime via std.DynLib (see clang_c.zig). So
        // k2.exe carries no dependency on the 81 MB libclang.dll — it ships as
        // an optional component, loaded only when `k2 bindgen` actually runs.
    }

    // ── Optional in-process LLD (k2lld.dll) ───────────────────────────────
    // `-Din-process-lld` bundles the LLD COFF driver + its LLVM static deps
    // into a DLL exposing `k2_lld_link_coff`, so `k2 build` links in-process
    // instead of spawning a 69 MB lld-link.exe. Off by default; the spawn path
    // is the fallback. Requires the LLVM/LLD static libs in <llvm-path>/lib.
    const in_process_lld = b.option(bool, "in-process-lld", "Build k2lld.dll for in-process linking") orelse false;
    opts.addOption(bool, "in_process_lld", in_process_lld and llvm_path != null);
    if (in_process_lld) {
        if (llvm_path) |lp| {
            // The SDK's LLVM static libs are MSVC-ABI (/MT). Build the shim DLL
            // against the MSVC toolchain so the CRT/STL match.
            const msvc_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .msvc });
            // Always ReleaseFast + stripped: the DLL is loaded on every `k2
            // build`, so its size drives link latency. Debug info would bloat it
            // to ~77 MB and dominate the load.
            const k2lld = b.addLibrary(.{
                .name = "k2lld",
                .linkage = .dynamic,
                .root_module = b.createModule(.{ .target = msvc_target, .optimize = .ReleaseFast, .strip = true, .link_libc = true }),
            });
            k2lld.root_module.addCSourceFile(.{
                .file = b.path("src/backend/llvm/lld_shim.cpp"),
                .flags = &.{ "-std=c++17", "-fno-rtti" },
            });
            k2lld.root_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{lp}) });
            k2lld.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{lp}) });
            // LLD + the FULL LLVM static set (all targets — LLD's LTO path
            // references every target initializer), in `llvm-config --libnames
            // all` order, then the Windows system libs LLVM needs.
            const lld_llvm_libs = [_][]const u8{
                "lldCOFF",                  "lldCommon",
                "LLVMWindowsManifest",      "LLVMXRay",
                "LLVMLibDriver",            "LLVMDlltoolDriver",
                "LLVMTelemetry",            "LLVMTextAPIBinaryReader",
                "LLVMCoverage",             "LLVMLineEditor",
                "LLVMNVPTXCodeGen",         "LLVMNVPTXDesc",
                "LLVMNVPTXInfo",            "LLVMRISCVTargetMCA",
                "LLVMRISCVDisassembler",    "LLVMRISCVAsmParser",
                "LLVMRISCVCodeGen",         "LLVMRISCVDesc",
                "LLVMRISCVInfo",            "LLVMWebAssemblyDisassembler",
                "LLVMWebAssemblyAsmParser", "LLVMWebAssemblyCodeGen",
                "LLVMWebAssemblyUtils",     "LLVMWebAssemblyDesc",
                "LLVMWebAssemblyInfo",      "LLVMBPFDisassembler",
                "LLVMBPFAsmParser",         "LLVMBPFCodeGen",
                "LLVMBPFDesc",              "LLVMBPFInfo",
                "LLVMX86TargetMCA",         "LLVMX86Disassembler",
                "LLVMX86AsmParser",         "LLVMX86CodeGen",
                "LLVMX86Desc",              "LLVMX86Info",
                "LLVMARMDisassembler",      "LLVMARMAsmParser",
                "LLVMARMCodeGen",           "LLVMARMDesc",
                "LLVMARMUtils",             "LLVMARMInfo",
                "LLVMAArch64Disassembler",  "LLVMAArch64AsmParser",
                "LLVMAArch64CodeGen",       "LLVMAArch64Desc",
                "LLVMAArch64Utils",         "LLVMAArch64Info",
                "LLVMOrcDebugging",         "LLVMOrcJIT",
                "LLVMWindowsDriver",        "LLVMMCJIT",
                "LLVMJITLink",              "LLVMInterpreter",
                "LLVMExecutionEngine",      "LLVMRuntimeDyld",
                "LLVMOrcTargetProcess",     "LLVMOrcShared",
                "LLVMDWP",                  "LLVMDWARFCFIChecker",
                "LLVMDebugInfoLogicalView", "LLVMOption",
                "LLVMObjCopy",              "LLVMMCA",
                "LLVMMCDisassembler",       "LLVMDTLTO",
                "LLVMLTO",                  "LLVMPlugins",
                "LLVMPasses",               "LLVMHipStdPar",
                "LLVMCFGuard",              "LLVMCoroutines",
                "LLVMipo",                  "LLVMVectorize",
                "LLVMSandboxIR",            "LLVMLinker",
                "LLVMFrontendOpenMP",       "LLVMFrontendOffloading",
                "LLVMObjectYAML",           "LLVMFrontendOpenACC",
                "LLVMFrontendDriver",       "LLVMInstrumentation",
                "LLVMFrontendDirective",    "LLVMFrontendAtomic",
                "LLVMExtensions",           "LLVMDWARFLinkerParallel",
                "LLVMDWARFLinkerClassic",   "LLVMDWARFLinker",
                "LLVMGlobalISel",           "LLVMMIRParser",
                "LLVMAsmPrinter",           "LLVMSelectionDAG",
                "LLVMCodeGen",              "LLVMTarget",
                "LLVMObjCARCOpts",          "LLVMCodeGenTypes",
                "LLVMCGData",               "LLVMCAS",
                "LLVMIRPrinter",            "LLVMInterfaceStub",
                "LLVMFileCheck",            "LLVMFuzzMutate",
                "LLVMScalarOpts",           "LLVMInstCombine",
                "LLVMAggressiveInstCombine", "LLVMTransformUtils",
                "LLVMBitWriter",            "LLVMAnalysis",
                "LLVMProfileData",          "LLVMSymbolize",
                "LLVMDebugInfoBTF",         "LLVMDebugInfoPDB",
                "LLVMDebugInfoMSF",         "LLVMDebugInfoCodeView",
                "LLVMDebugInfoGSYM",        "LLVMDebugInfoDWARF",
                "LLVMObject",               "LLVMTextAPI",
                "LLVMMCParser",             "LLVMIRReader",
                "LLVMAsmParser",            "LLVMMC",
                "LLVMDebugInfoDWARFLowLevel", "LLVMBitReader",
                "LLVMFrontendHLSL",         "LLVMFuzzerCLI",
                "LLVMABI",                  "LLVMCore",
                "LLVMRemarks",              "LLVMBitstreamReader",
                "LLVMBinaryFormat",         "LLVMTargetParser",
                "LLVMTableGen",             "LLVMSupportLSP",
                "LLVMSupport",              "LLVMDemangle",
                // Windows system libs (`llvm-config --system-libs`).
                "xml2s",  "psapi",  "shell32", "ole32",
                "uuid",   "advapi32", "ws2_32", "ntdll",
            };
            for (lld_llvm_libs) |name| k2lld.root_module.linkSystemLibrary(name, .{});
            b.installArtifact(k2lld);
        }
    }

    // ── Basalt stub (kept for historical reasons, can be removed) ─────────
    const basalt_lib_dir = b.option(
        []const u8,
        "basalt-lib-dir",
        "Directory containing libbasalt.a",
    ) orelse "C:\\Users\\chris\\backend\\basalt\\bin";

    // ── CLI executable ────────────────────────────────────────────────────
    const exe_mod = b.addModule("skarn", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{ .name = "skarn", .root_module = exe_mod });
    exe.root_module.addImport("k2_compiler", compiler_mod);
    exe.root_module.addLibraryPath(.{ .cwd_relative = basalt_lib_dir });

    if (embed_linker and llvm_path != null) {
        // Stage 1: the base k2.exe compiles the linker to a freestanding object
        // (no entry / _fltused). It only does codegen, so it needs LLVM-C.dll on
        // PATH but no linker.
        const lp = llvm_path.?;
        const gen = b.addRunArtifact(exe);
        gen.addArg("object");
        gen.addFileArg(b.path("linker/k2lnk.sk"));
        gen.addArgs(&.{ "--no-entry", "-O2", "-o" });
        const k2lnk_obj = gen.addOutputFileArg("k2lnk.obj");
        gen.addPathDir(b.fmt("{s}/bin", .{lp})); // so LLVM-C.dll resolves at run time

        // Stage 2: the shipped k2.exe links that object in and exports k2_link_mem
        // (link.zig finds it via GetProcAddress on its own module). One binary.
        // A SEPARATE module so the object isn't pulled into the base exe above
        // (which would make the generator depend on its own output — a cycle).
        const final_mod = b.addModule("k2_embed", .{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        final_mod.addImport("k2_compiler", compiler_mod);
        final_mod.addLibraryPath(.{ .cwd_relative = basalt_lib_dir });
        final_mod.addObjectFile(k2lnk_obj);
        // The embedded object carries the k2 runtime, which references ws2_32
        // (the net module). kernel32 is already linked; add Winsock.
        final_mod.linkSystemLibrary("ws2_32", .{});
        const final = b.addExecutable(.{ .name = "skarn", .root_module = final_mod });
        final.win32_module_definition = b.path("linker/k2lnk_embed.def");
        b.installArtifact(final);
    } else {
        b.installArtifact(exe);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run skarn");
    run_step.dependOn(&run_cmd.step);

    // ── Tests ─────────────────────────────────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "k2_compiler", .module = compiler_mod }},
    });

    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this substring");
    const filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};
    const compiler_unit_tests = b.addTest(.{ .root_module = compiler_mod, .filters = filters });
    const exe_unit_tests = b.addTest(.{ .root_module = exe_mod, .filters = filters });
    const integration_tests = b.addTest(.{ .root_module = test_mod, .filters = filters });

    // Tests are a separate step — `zig build test` — not part of install.
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(compiler_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);
}

/// `base` version with a best-effort `+<git-short-sha>` appended — but only for a
/// pre-release version (one containing `-`, e.g. `0.1.0-dev`); a clean release is
/// returned as-is. Falls back to `base` when git isn't available.
fn gitVersion(b: *std.Build, base: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, base, '-') == null) return base;
    var code: u8 = 0;
    const out = b.runAllowFail(&.{ "git", "rev-parse", "--short", "HEAD" }, &code, .ignore) catch return base;
    const sha = std.mem.trim(u8, out, " \t\r\n");
    return if (sha.len == 0) base else b.fmt("{s}+{s}", .{ base, sha });
}
