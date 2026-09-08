/// Map Gabbro function attributes to LLVM function attributes.
/// Called from functions.zig after LLVMAddFunction.
const std = @import("std");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const ModuleCg = @import("context.zig").ModuleCg;
/// Apply all relevant Gabbro attributes to an LLVM function value.
pub fn applyFunctionAttrs(cg: *ModuleCg, func: ir.IrFunction, lv: llvm.LLVMValueRef) void {
    const fn_idx: c_uint = 0xFFFF_FFFF; // LLVMAttributeFunctionIndex

    if (func.inline_hint)
        addStrAttr(cg, lv, fn_idx, "alwaysinline", "");

    if (func.no_inline)
        addStrAttr(cg, lv, fn_idx, "noinline", "");

    if (func.no_return)
        addStrAttr(cg, lv, fn_idx, "noreturn", "");

    if (func.naked)
        addStrAttr(cg, lv, fn_idx, "naked", "");

    if (func.entry) {
        addStrAttr(cg, lv, fn_idx, "noinline", "");
    }

    if (func.export_sym) |sym| {
        // Ensure external linkage so the symbol survives the linker.
        llvm.LLVMSetLinkage(lv, llvm.LLVMExternalLinkage);
        // dllexport storage class: emits an `/EXPORT:name` directive into the
        // object so a `/DLL` link exports it automatically (and it's harmless in
        // an exe). This is what makes `#export` usable for building DLLs.
        llvm.LLVMSetDLLStorageClass(lv, llvm.LLVMDLLExportStorageClass);
        // If an explicit export name was given, rename the LLVM value.
        if (sym.len > 0 and !std.mem.eql(u8, sym, func.name)) {
            llvm.LLVMSetValueName2(lv, sym.ptr, sym.len);
        }
    }

    // `#cold` — a real LLVM enum attribute so the optimizer moves it off the hot path.
    if (func.cold) addEnumAttr(cg, lv, fn_idx, "cold");

    // `#weak` — a weak symbol that another definition can override at link time.
    if (func.weak) llvm.LLVMSetLinkage(lv, llvm.LLVMWeakAnyLinkage);

    // `#keep` — force external linkage so it isn't internalized/DCE'd when unused.
    if (func.keep) llvm.LLVMSetLinkage(lv, llvm.LLVMExternalLinkage);

    // `#section("name")` — place the function in a specific object section.
    if (func.section) |sec| {
        const secz = cg.allocator.dupeZ(u8, sec) catch return;
        defer cg.allocator.free(secz);
        llvm.LLVMSetSection(lv, secz.ptr);
    }

    // `#link_name("name")` — the external symbol name (renames without exporting).
    if (func.link_name) |ln| if (ln.len > 0) llvm.LLVMSetValueName2(lv, ln.ptr, ln.len);
}

// Helpers

/// Attach a real LLVM *enum* attribute (e.g. `cold`) so the optimizer acts on it,
/// unlike a string attribute which is opaque to LLVM.
fn addEnumAttr(cg: *ModuleCg, lv: llvm.LLVMValueRef, index: c_uint, name: []const u8) void {
    const kind = llvm.LLVMGetEnumAttributeKindForName(name.ptr, name.len);
    if (kind == 0) return;
    const attr = llvm.LLVMCreateEnumAttribute(cg.ctx, kind, 0);
    llvm.LLVMAddAttributeAtIndex(lv, index, attr);
}

fn addStrAttr(
    cg: *ModuleCg,
    lv: llvm.LLVMValueRef,
    index: c_uint,
    key: []const u8,
    val: []const u8,
) void {
    const attr = llvm.LLVMCreateStringAttribute(
        cg.ctx,
        key.ptr,
        @intCast(key.len),
        val.ptr,
        @intCast(val.len),
    );
    llvm.LLVMAddAttributeAtIndex(lv, index, attr);
}
