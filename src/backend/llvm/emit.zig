/// Object file emission via LLVM TargetMachine.
///
/// Primary output: .o (native object file).
/// Debug helper:  dumpIr() prints the module as text to stderr.
const std = @import("std");
const llvm = @import("c_api.zig").llvm;
const ModuleCg = @import("context.zig").ModuleCg;

pub const EmitError = error{ TargetInitFailed, VerifyFailed, EmitFailed, OutOfMemory };

// Target setup

/// One-time global initialisation of the native target.
/// Safe to call multiple times (LLVM checks internally).
pub fn initNativeTarget() EmitError!void {
    if (llvm.LLVMInitializeNativeTarget() != 0)
        return error.TargetInitFailed;
    if (llvm.LLVMInitializeNativeAsmPrinter() != 0)
        return error.TargetInitFailed;
    if (llvm.LLVMInitializeNativeAsmParser() != 0)
        return error.TargetInitFailed;
}

pub const TargetMachine = struct {
    tm: llvm.LLVMTargetMachineRef,
    triple: [*c]u8,

    /// Create a TargetMachine for the host machine.
    /// `opt_level`: 0 = none, 1 = less, 2 = default, 3 = aggressive.
    pub fn initNative(opt_level: u2) EmitError!TargetMachine {
        try initNativeTarget();

        const triple = llvm.LLVMGetDefaultTargetTriple();

        var target: llvm.LLVMTargetRef = undefined;
        var err: [*c]u8 = null;
        if (llvm.LLVMGetTargetFromTriple(triple, &target, &err) != 0) {
            if (err) |msg| llvm.LLVMDisposeMessage(msg);
            llvm.LLVMDisposeMessage(triple);
            return error.TargetInitFailed;
        }

        // Use the host CPU name and its feature string so the emitted code
        // can use all available instruction sets (AVX, SSE4, etc.).
        const cpu = llvm.LLVMGetHostCPUName();
        const features = llvm.LLVMGetHostCPUFeatures();
        defer llvm.LLVMDisposeMessage(cpu);
        defer llvm.LLVMDisposeMessage(features);

        const llvm_opt: llvm.LLVMCodeGenOptLevel = switch (opt_level) {
            0 => llvm.LLVMCodeGenLevelNone,
            1 => llvm.LLVMCodeGenLevelLess,
            2 => llvm.LLVMCodeGenLevelDefault,
            3 => llvm.LLVMCodeGenLevelAggressive,
        };

        const tm = llvm.LLVMCreateTargetMachine(
            target,
            triple,
            cpu,
            features,
            llvm_opt,
            llvm.LLVMRelocDefault, // executables use absolute addressing; PIC is for DLLs
            llvm.LLVMCodeModelDefault,
        );

        return .{ .tm = tm, .triple = triple };
    }

    /// Create a TargetMachine for an explicit target OS (cross-compilation).
    /// Falls back to the host path when the target is the host. The only non-host
    /// target today is Linux x86-64: a static, non-PIE ELF using the SysV ABI
    /// (LLVM derives both from the triple).
    pub fn initTarget(target_os: std.Target.Os.Tag, opt_level: u2) EmitError!TargetMachine {
        if (target_os == @import("builtin").os.tag) return initNative(opt_level);
        try initNativeTarget(); // the host's X86 backend also emits for x86_64-linux

        const triple_lit = switch (target_os) {
            .linux => "x86_64-unknown-linux-musl",
            else => return error.TargetInitFailed,
        };
        const triple = llvm.LLVMCreateMessage(triple_lit); // disposable copy (deinit frees it)

        var target: llvm.LLVMTargetRef = undefined;
        var err: [*c]u8 = null;
        if (llvm.LLVMGetTargetFromTriple(triple, &target, &err) != 0) {
            if (err) |msg| llvm.LLVMDisposeMessage(msg);
            llvm.LLVMDisposeMessage(triple);
            return error.TargetInitFailed;
        }

        const llvm_opt: llvm.LLVMCodeGenOptLevel = switch (opt_level) {
            0 => llvm.LLVMCodeGenLevelNone,
            1 => llvm.LLVMCodeGenLevelLess,
            2 => llvm.LLVMCodeGenLevelDefault,
            3 => llvm.LLVMCodeGenLevelAggressive,
        };

        const tm = llvm.LLVMCreateTargetMachine(
            target,
            triple,
            "x86-64", // generic baseline CPU so the binary runs on any x86-64
            "",
            llvm_opt,
            llvm.LLVMRelocStatic, // static, non-PIE executable
            llvm.LLVMCodeModelDefault,
        );

        return .{ .tm = tm, .triple = triple };
    }

    pub fn deinit(self: TargetMachine) void {
        llvm.LLVMDisposeTargetMachine(self.tm);
        llvm.LLVMDisposeMessage(self.triple);
    }

    /// Stamp the target triple and data layout onto the LLVM module.
    /// Must be called before emitting — ensures the module matches the target.
    pub fn applyToModule(self: TargetMachine, cg: *ModuleCg) void {
        llvm.LLVMSetTarget(cg.mod, self.triple);

        const layout = llvm.LLVMCreateTargetDataLayout(self.tm);
        defer llvm.LLVMDisposeTargetData(layout);

        const layout_str = llvm.LLVMCopyStringRepOfTargetData(layout);
        defer llvm.LLVMDisposeMessage(layout_str);

        llvm.LLVMSetDataLayout(cg.mod, layout_str);
    }
};

// Verification

/// Verify the LLVM module.  On failure, prints LLVM's error to stderr and
/// returns `error.VerifyFailed`.
pub fn verify(cg: *ModuleCg) EmitError!void {
    var err: [*c]u8 = null;
    if (llvm.LLVMVerifyModule(cg.mod, llvm.LLVMReturnStatusAction, &err) != 0) {
        if (err) |msg| {
            std.debug.print("LLVM verification error:\n{s}\n", .{msg});
            llvm.LLVMDisposeMessage(msg);
        }
        return error.VerifyFailed;
    }
}

// Object file emission

/// Emit a native object file at `path`.
///
/// Typical usage:
///   const tm = try TargetMachine.initNative(2);   // opt level 2
///   defer tm.deinit();
///   tm.applyToModule(&cg);
///   try verify(&cg);
///   try emitObject(&cg, tm, "output.o");
/// Emit the object into an allocator-owned byte buffer (caller frees) instead of
/// a file — so the linker can consume it in memory with no disk round-trip.
pub fn emitObjectToMemory(cg: *ModuleCg, tm: TargetMachine, allocator: std.mem.Allocator) EmitError![]u8 {
    var err: [*c]u8 = null;
    var membuf: llvm.LLVMMemoryBufferRef = null;
    if (llvm.LLVMTargetMachineEmitToMemoryBuffer(
        tm.tm,
        cg.mod,
        llvm.LLVMObjectFile,
        &err,
        &membuf,
    ) != 0) {
        if (err) |msg| {
            std.debug.print("LLVM emit error: {s}\n", .{msg});
            llvm.LLVMDisposeMessage(msg);
        }
        return error.EmitFailed;
    }
    defer llvm.LLVMDisposeMemoryBuffer(membuf);
    const start = llvm.LLVMGetBufferStart(membuf);
    const size = llvm.LLVMGetBufferSize(membuf);
    const bytes = allocator.alloc(u8, size) catch return error.EmitFailed;
    @memcpy(bytes, start[0..size]);
    return bytes;
}

pub fn emitObject(cg: *ModuleCg, tm: TargetMachine, path: [*:0]const u8) EmitError!void {
    var err: [*c]u8 = null;
    if (llvm.LLVMTargetMachineEmitToFile(
        tm.tm,
        cg.mod,
        // LLVM C API takes a mutable char* here, but we only read it
        @constCast(path),
        llvm.LLVMObjectFile,
        &err,
    ) != 0) {
        if (err) |msg| {
            std.debug.print("LLVM emit error: {s}\n", .{msg});
            llvm.LLVMDisposeMessage(msg);
        }
        return error.EmitFailed;
    }
}

// Debug helpers

/// Print the module as LLVM text IR to stderr (useful for debugging codegen).
pub fn dumpIr(cg: *ModuleCg) void {
    llvm.LLVMDumpModule(cg.mod);
}

/// Return the module as an LLVM text IR string (caller frees with allocator).
pub fn getIrText(cg: *ModuleCg, allocator: std.mem.Allocator) ![]u8 {
    const raw = llvm.LLVMPrintModuleToString(cg.mod);
    defer llvm.LLVMDisposeMessage(raw);
    return allocator.dupe(u8, std.mem.span(raw));
}
