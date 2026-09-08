const std = @import("std");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const values = @import("values.zig");
const ModuleCg = @import("context.zig").ModuleCg;

/// Lower a compiler-generated panic through the shared Gabbro runtime contract.
/// The declaration is synthesized when a library consumer lowers IR without
/// prepending the embedded runtime.
pub fn lower(cg: *ModuleCg, panic: ir.Panic) void {
    const message = std.fmt.allocPrint(
        cg.allocator,
        "{s} at {s}:{d}:{d}",
        .{ panic.message, panic.location.file, panic.location.line, panic.location.column },
    ) catch panic.message;
    defer if (message.ptr != panic.message.ptr) cg.allocator.free(message);

    const panic_fn = getOrDeclare(cg);
    const panic_fn_ty = llvm.LLVMGlobalGetValueType(panic_fn);
    var args = [_]llvm.LLVMValueRef{
        values.lowerImm(cg, .{ .text = message }, .text),
    };
    _ = llvm.LLVMBuildCall2(cg.builder, panic_fn_ty, panic_fn, &args, 1, "");
    _ = llvm.LLVMBuildUnreachable(cg.builder);
}

fn getOrDeclare(cg: *ModuleCg) llvm.LLVMValueRef {
    if (cg.fn_decls.get("@panic")) |panic_fn| return panic_fn;

    var params = [_]llvm.LLVMTypeRef{cg.getSliceType()};
    const fn_ty = llvm.LLVMFunctionType(
        llvm.LLVMVoidTypeInContext(cg.ctx),
        &params,
        1,
        0,
    );
    const panic_fn = llvm.LLVMAddFunction(cg.mod, "@panic", fn_ty);
    llvm.LLVMSetLinkage(panic_fn, llvm.LLVMExternalLinkage);
    cg.fn_decls.put("@panic", panic_fn) catch {};
    return panic_fn;
}
