/// LLVM codegen backend — entry point.
///
/// Quick start (Windows, no libc):
///
///   var be = LlvmBackend.init(allocator, "my_module");
///   defer be.deinit();
///   try be.lower(ir_module);
///   try be.emitObject("output.o", 2);          // → .o file
///   try be.linkWindows(.{                       // → .exe
///       .llvm_bin  = "Y:/SDK/llvm/bin",
///       .obj_files = &.{"output.o"},
///       .output    = "output.exe",
///   });
///
/// The Windows entry point (mainCRTStartup) is **automatically generated**
/// when the module contains a function marked as entry (`main` or `#entry`).
/// It calls the Skarn main, then ExitProcess — no separate skarnrt file needed.
const std = @import("std");
const ir = @import("../ir.zig");
const ctx_mod = @import("llvm/context.zig");
const structs = @import("llvm/structs.zig");
const globals = @import("llvm/globals.zig");
const fns = @import("llvm/functions.zig");
const emit = @import("llvm/emit.zig");
const link = @import("llvm/link.zig");
const vars_mod = @import("llvm/variants.zig");
const vtables = @import("llvm/vtables.zig");
const values = @import("llvm/values.zig");
const llvm_c = @import("llvm/c_api.zig").llvm;

pub const LlvmBackend = struct {
    cg: ctx_mod.ModuleCg,

    pub fn init(allocator: std.mem.Allocator, module_name: [*:0]const u8) LlvmBackend {
        return .{ .cg = ctx_mod.ModuleCg.init(allocator, module_name) };
    }

    pub fn deinit(self: *LlvmBackend) void {
        self.cg.deinit();
    }

    /// Configure optimization/safety mode before lowering.
    /// Level 0 inserts debug runtime checks; higher levels omit them.
    pub fn setOptLevel(self: *LlvmBackend, opt_level: u2) void {
        self.cg.opt_level = opt_level;
    }

    /// Set the target OS (cross-compilation). Must be called before `lower`.
    pub fn setTarget(self: *LlvmBackend, target_os: std.Target.Os.Tag) void {
        self.cg.target_os = target_os;
    }

    /// Lower a complete IrModule to LLVM IR in memory.
    pub fn lower(self: *LlvmBackend, module: ir.IrModule) !void {
        // Expose module metadata needed by instruction lowering.
        self.cg.error_defs = module.errors;

        // Target-specific module-level stubs (Windows `__chkstk`; nothing on Linux).
        self.cg.applyTargetStubs();

        // Order-independent type registration via shells, satisfying two opposing
        // constraints at once:
        //  1. A struct's by-value enum field (`color: Color`, even a payloaded enum)
        //     needs the enum's TYPE before the struct is bodied — else it falls back
        //     to a pointer (wrong-typed/sized field, breaks `match s.field`).
        //  2. A payloaded enum's `[N x i8]` payload must be sized against fully
        //     bodied struct variants (e.g. `TypeInfo.struct_: TiStruct` = 32 B).
        // So: declare all enum types (payloaded = named opaque shell), body structs
        // (their enum fields reference the shell, resolved lazily), then fill the
        // enum shells' bodies now that payload sizes are known.
        try vars_mod.declareAll(&self.cg, module.variants);
        try structs.lowerAll(&self.cg, module.structs);
        try vars_mod.bodyAll(&self.cg, module.variants);
        try globals.lowerAll(&self.cg, module.globals);
        try fns.declareAll(&self.cg, module.functions);
        try vtables.lowerAll(&self.cg, module.vtables);
        try fns.defineAll(&self.cg, module.functions);

        if (self.cg.target_os == .windows) {
            // Windows float-support marker, needed for a standalone exe under
            // /NODEFAULTLIB. Skipped for a `--no-entry` library object: the host
            // binary's CRT already provides `_fltused` (avoids a duplicate symbol).
            if (!self.cg.no_entry) {
                const i32_ty = llvm_c.LLVMInt32TypeInContext(self.cg.ctx);
                const fltused = llvm_c.LLVMAddGlobal(self.cg.mod, i32_ty, "_fltused");
                llvm_c.LLVMSetInitializer(fltused, llvm_c.LLVMConstInt(i32_ty, 1, 0));
                llvm_c.LLVMSetLinkage(fltused, llvm_c.LLVMExternalLinkage);
            }

            // The skarnld import map (a `.skimp` section). Lets the self-hosted
            // linker resolve each import's DLL without parsing any `.lib`.
            try emitImportMap(&self.cg, module);
            // The export map (`.skexp`) — `#export`ed symbol names, so skarnld can
            // build a DLL's export table (.edata) without /EXPORT: directives.
            try emitExportMap(&self.cg, module);
        }

        // Auto-generate the platform entry point. Windows: a `mainCRTStartup` that
        // calls `main` + `ExitProcess`. Linux: nothing — the runtime provides a
        // `#naked _start` that calls `main` + the exit syscall.
        if (self.cg.target_os == .windows and !self.cg.no_entry) {
            for (module.functions) |f| {
                if (f.entry) {
                    try emitWindowsEntryPoint(&self.cg, f);
                    break;
                }
            }
        }

        // If any instruction lowering detected an internal shape/invariant
        // mismatch (recorded via `cg.recordLoweringError`), fail the build
        // cleanly here rather than handing a malformed module to LLVM's
        // verifier/codegen — those paths assert/crash on bad input instead
        // of returning errors.
        if (self.cg.lowering_failed) return error.LoweringFailed;

        try emit.verify(&self.cg);
    }

    /// Emit a native object file.
    /// `opt_level`: 0=none 1=less 2=default 3=aggressive.
    pub fn emitObject(self: *LlvmBackend, path: [*:0]const u8, opt_level: u2) !void {
        self.setOptLevel(opt_level);
        const tm = try emit.TargetMachine.initNative(opt_level);
        defer tm.deinit();
        tm.applyToModule(&self.cg);
        try emit.verify(&self.cg);
        try emit.emitObject(&self.cg, tm, path);
    }

    /// Emit the object into an in-memory byte buffer (caller frees).
    pub fn emitObjectToMemory(self: *LlvmBackend, allocator: std.mem.Allocator, opt_level: u2) ![]u8 {
        self.setOptLevel(opt_level);
        const tm = try emit.TargetMachine.initTarget(self.cg.target_os, opt_level);
        defer tm.deinit();
        tm.applyToModule(&self.cg);
        try emit.verify(&self.cg);
        return emit.emitObjectToMemory(&self.cg, tm, allocator);
    }

    /// Link object files into a Windows executable via lld-link.
    pub fn linkWindows(self: *LlvmBackend, allocator: std.mem.Allocator, io: std.Io, opts: link.WindowsLinkOptions) !void {
        _ = self;
        return link.windows(allocator, io, opts);
    }

    /// Link an in-memory ELF object into a static Linux executable via ld.lld.
    pub fn linkLinuxMem(self: *LlvmBackend, allocator: std.mem.Allocator, io: std.Io, obj_path: []const u8, obj_bytes: []const u8, opts: link.LinuxLinkOptions) !void {
        _ = self;
        return link.linkLinux(allocator, io, obj_path, obj_bytes, opts);
    }

    /// Link straight from in-memory object bytes (no .obj on disk) — skarnld fast
    /// path; spills to disk only for the LLD fallback.
    pub fn linkWindowsMem(self: *LlvmBackend, allocator: std.mem.Allocator, io: std.Io, obj_bytes: []const u8, opts: link.WindowsLinkOptions) !void {
        _ = self;
        return link.windowsMem(allocator, io, obj_bytes, opts);
    }

    /// Dump the LLVM IR to stderr (debugging).
    pub fn dumpIr(self: *LlvmBackend) void {
        emit.dumpIr(&self.cg);
    }

    /// Return the LLVM IR as text (debugging/testing).
    pub fn getIrText(self: *LlvmBackend, allocator: std.mem.Allocator) ![]u8 {
        return emit.getIrText(&self.cg, allocator);
    }
};

/// Convenience wrapper — link step exposed at module level.
pub const linkWindows = link.windows;

// Windows entry point generator
//
// When the Skarn module has an `entry` function, automatically emit:
//
//   void mainCRTStartup() {
//       ExitProcess((u32)main());
//   }
//
// This replaces skarnrt — no separate object file to compile or distribute.

/// Emit the skarnld import map as a `.skimp` COFF section: a flat list of
/// `symbol\0dll\0` records, one per `#extern("dll","symbol")` import. The
/// self-hosted linker reads this to know each undefined symbol's DLL directly —
/// no `.lib` archive parsing (LLD's biggest cost). LLD ignores the section.
fn emitImportMap(cg: *ctx_mod.ModuleCg, module: ir.IrModule) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(cg.allocator);
    for (module.functions) |f| {
        const sym = f.extern_name orelse continue;
        const lib = f.extern_lib orelse continue;
        if (sym.len == 0 or lib.len == 0) continue;
        try buf.appendSlice(cg.allocator, sym);
        try buf.append(cg.allocator, 0);
        try buf.appendSlice(cg.allocator, lib);
        try buf.append(cg.allocator, 0);
    }
    if (buf.items.len == 0) return; // no DLL imports — nothing for skarnld to map

    const i8_ty = llvm_c.LLVMInt8TypeInContext(cg.ctx);
    const arr_ty = llvm_c.LLVMArrayType(i8_ty, @intCast(buf.items.len));
    const init = llvm_c.LLVMConstStringInContext(cg.ctx, buf.items.ptr, @intCast(buf.items.len), 1);
    const g = llvm_c.LLVMAddGlobal(cg.mod, arr_ty, "__skarn_import_map");
    llvm_c.LLVMSetInitializer(g, init);
    llvm_c.LLVMSetLinkage(g, llvm_c.LLVMExternalLinkage);
    llvm_c.LLVMSetGlobalConstant(g, 1);
    llvm_c.LLVMSetSection(g, ".skimp");
}

/// Emit the skarnld export map as a `.skexp` section: a flat list of `name\0`
/// records, one per `#export`ed function. skarnld reads it to build a DLL's export
/// directory (.edata) — no `/EXPORT:` linker directives, no .drectve parsing.
fn emitExportMap(cg: *ctx_mod.ModuleCg, module: ir.IrModule) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(cg.allocator);
    for (module.functions) |f| {
        const name = f.export_sym orelse continue;
        if (name.len == 0) continue;
        try buf.appendSlice(cg.allocator, name);
        try buf.append(cg.allocator, 0);
    }
    if (buf.items.len == 0) return; // nothing exported

    const i8_ty = llvm_c.LLVMInt8TypeInContext(cg.ctx);
    const arr_ty = llvm_c.LLVMArrayType(i8_ty, @intCast(buf.items.len));
    const init = llvm_c.LLVMConstStringInContext(cg.ctx, buf.items.ptr, @intCast(buf.items.len), 1);
    const g = llvm_c.LLVMAddGlobal(cg.mod, arr_ty, "__skarn_export_map");
    llvm_c.LLVMSetInitializer(g, init);
    llvm_c.LLVMSetLinkage(g, llvm_c.LLVMExternalLinkage);
    llvm_c.LLVMSetGlobalConstant(g, 1);
    llvm_c.LLVMSetSection(g, ".skexp");
}

fn emitWindowsEntryPoint(cg: *ctx_mod.ModuleCg, main: ir.IrFunction) !void {
    // Declare ExitProcess(u32) if not already present.
    const ep_sym = "ExitProcess";
    if (!cg.fn_decls.contains(ep_sym)) {
        const u32_ty = llvm_c.LLVMInt32TypeInContext(cg.ctx);
        const void_ty = llvm_c.LLVMVoidTypeInContext(cg.ctx);
        const ep_ty = llvm_c.LLVMFunctionType(void_ty, @constCast(&[_]llvm_c.LLVMTypeRef{u32_ty}), 1, 0);
        const ep = llvm_c.LLVMAddFunction(cg.mod, ep_sym, ep_ty);
        llvm_c.LLVMSetLinkage(ep, llvm_c.LLVMExternalLinkage);
        try cg.fn_decls.put(ep_sym, ep);
    }

    // Emit mainCRTStartup.
    const void_ty = llvm_c.LLVMVoidTypeInContext(cg.ctx);
    const crt_ty = llvm_c.LLVMFunctionType(void_ty, null, 0, 0);
    const crt_fn = llvm_c.LLVMAddFunction(cg.mod, "mainCRTStartup", crt_ty);
    const bb = llvm_c.LLVMAppendBasicBlockInContext(cg.ctx, crt_fn, "entry");
    llvm_c.LLVMPositionBuilderAtEnd(cg.builder, bb);

    // Call Skarn main.
    const main_fn = cg.fn_decls.get(main.name) orelse return;
    const main_fn_ty = llvm_c.LLVMGlobalGetValueType(main_fn);
    const main_ret = llvm_c.LLVMBuildCall2(cg.builder, main_fn_ty, main_fn, null, 0, "ret");

    // Coerce i32 → u32 (bitcast — same bits, different signedness).
    const u32_ty = llvm_c.LLVMInt32TypeInContext(cg.ctx);
    const exit_code = if (main.error_ty != null) blk: {
        const err = llvm_c.LLVMBuildExtractValue(cg.builder, main_ret, 1, "main_err");
        const ok = if (main.return_ty == .void)
            llvm_c.LLVMConstInt(u32_ty, 0, 0)
        else
            values.coerce(cg.builder, cg.ctx, llvm_c.LLVMBuildExtractValue(cg.builder, main_ret, 0, "main_ok"), u32_ty);
        const err_code = values.coerce(cg.builder, cg.ctx, err, u32_ty);
        const is_err = llvm_c.LLVMBuildICmp(
            cg.builder,
            llvm_c.LLVMIntNE,
            err_code,
            llvm_c.LLVMConstInt(u32_ty, 0, 0),
            "main_failed",
        );
        break :blk llvm_c.LLVMBuildSelect(cg.builder, is_err, err_code, ok, "exit_code");
    } else if (main.return_ty == .void)
        llvm_c.LLVMConstInt(u32_ty, 0, 0)
    else
        values.coerce(cg.builder, cg.ctx, main_ret, u32_ty);

    // Call ExitProcess.
    const ep_fn = cg.fn_decls.get(ep_sym).?;
    const ep_fn_ty = llvm_c.LLVMGlobalGetValueType(ep_fn);
    var ep_args = [_]llvm_c.LLVMValueRef{exit_code};
    _ = llvm_c.LLVMBuildCall2(cg.builder, ep_fn_ty, ep_fn, &ep_args, 1, "");
    _ = llvm_c.LLVMBuildUnreachable(cg.builder);
}
