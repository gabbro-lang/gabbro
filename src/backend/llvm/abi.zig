//! Win64 (x86_64-pc-windows-msvc) C ABI for passing/returning by-value
//! aggregates across the `#extern`/`#foreign` boundary.
//!
//! Skarn's own calls pass structs as first-class LLVM aggregate values, which is
//! self-consistent for Skarn↔Skarn code. But the platform C ABI is *not* what LLVM
//! does with a raw `%Struct` value parameter — the front-end (here) must lower
//! aggregates to the ABI representation, exactly as Clang does. Without this,
//! every C function that takes/returns a struct by value (raylib's `Color`,
//! `Vector2`, `Rectangle`, `Camera2D`, …) is silently mis-called.
//!
//! Win64 is mercifully simple (no SysV eightbyte/SSE classification, no HFA):
//!   * an aggregate argument/return of size 1, 2, 4 or 8 bytes is passed in a
//!     single integer register — i.e. coerced to an `iN` of the same size;
//!   * any other size is passed **indirectly**: the caller allocates a copy and
//!     passes a pointer (`byval` for arguments, an `sret` hidden first parameter
//!     for returns).
//! Floating-point *struct members* do NOT go in XMM on Win64 (only naked
//! `float`/`double` scalar args do), so coercing a `{f32,f32}` to `i64` is
//! correct — that is precisely how `Vector2` reaches `DrawCircleV`.
//!
//! Scope: this applies only to functions with `extern_name` set (pure external
//! declarations, never defined here) and to their call sites. Skarn↔Skarn calls and
//! Skarn's internal aggregates (slices, optionals, fallibles, interfaces) are
//! untouched. Exposing struct-passing `#export` functions to C (callee-side
//! prologue reconstruction) is a separate, later step.

const std = @import("std");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const types = @import("types.zig");
const ModuleCg = @import("context.zig").ModuleCg;

/// How one value (a parameter or the return) crosses the C boundary.
pub const Class = union(enum) {
    /// Passed/returned unchanged: scalars, pointers, and anything that isn't a
    /// by-value struct.
    direct,
    /// A small aggregate (size 1/2/4/8) coerced to an integer of `bits` bits.
    coerce: u16,
    /// A larger/odd aggregate passed via a pointer (byval arg / sret return).
    indirect,
};

pub const ParamAbi = struct {
    class: Class,
    /// The original Skarn parameter type (used to lower `direct` params normally
    /// and to recover the `%Struct` LLVM type for coerced/indirect ones).
    ir_ty: ir.IrType,
    /// The named `%Struct` LLVM type, when `class` is `.coerce`/`.indirect`.
    llvm_struct: llvm.LLVMTypeRef = null,
};

pub const FnAbi = struct {
    /// Return is indirect: a hidden leading `ptr sret(%T)` parameter.
    sret: bool,
    /// Classification of the return value (`.direct` for scalar/void returns).
    ret: Class,
    /// The return `%Struct` LLVM type, when the return is an aggregate.
    ret_struct: llvm.LLVMTypeRef = null,
    /// One entry per original parameter, in source order (excludes the sret slot).
    params: []ParamAbi,
    /// True when any coercion/indirection/sret applies — i.e. the default
    /// (scalar) lowering would be wrong. Trivial signatures are never recorded.
    nontrivial: bool,

    pub fn deinit(self: *FnAbi, allocator: std.mem.Allocator) void {
        allocator.free(self.params);
    }
};

/// Byte size of an LLVM type under the default x86_64 layout (struct sizes match
/// Win64 for the aggregates we classify). Same approach as `variants.zig`.
fn sizeOf(cg: *ModuleCg, ty: llvm.LLVMTypeRef) u64 {
    return llvm.LLVMABISizeOfType(cg.targetData(), ty);
}

/// Classify a single Skarn type. Only named `struct` types are C aggregates; every
/// other type (including slices/optionals/etc., which never appear in a sane C
/// signature) passes through `.direct`, preserving today's behavior.
fn classify(cg: *ModuleCg, ty: ir.IrType) Class {
    return switch (ty) {
        .struct_type => |name| blk: {
            const st = cg.struct_types.get(name) orelse break :blk Class.direct;
            break :blk switch (sizeOf(cg, st)) {
                1, 2, 4, 8 => |sz| Class{ .coerce = @intCast(sz * 8) },
                else => Class.indirect,
            };
        },
        else => Class.direct,
    };
}

fn structTypeOf(cg: *ModuleCg, ty: ir.IrType) llvm.LLVMTypeRef {
    return switch (ty) {
        .struct_type => |name| cg.struct_types.get(name) orelse null,
        else => null,
    };
}

/// Compute the C ABI for an `#extern` function signature. Caller owns the
/// returned `FnAbi` (and must `deinit` it) — store it when `nontrivial`,
/// discard it otherwise.
pub fn computeFnAbi(cg: *ModuleCg, func: ir.IrFunction) !FnAbi {
    const params = try cg.allocator.alloc(ParamAbi, func.params.len);
    var nontrivial = false;

    for (func.params, 0..) |p, i| {
        const c = classify(cg, p.ty);
        params[i] = .{ .class = c, .ir_ty = p.ty, .llvm_struct = structTypeOf(cg, p.ty) };
        if (c != .direct) nontrivial = true;
    }

    // Fallible externs are unusual; leave their return alone.
    const ret_class: Class = if (func.error_ty != null) .direct else classify(cg, func.return_ty);
    if (ret_class != .direct) nontrivial = true;

    return .{
        .sret = ret_class == .indirect,
        .ret = ret_class,
        .ret_struct = structTypeOf(cg, func.return_ty),
        .params = params,
        .nontrivial = nontrivial,
    };
}

/// Build the ABI-lowered LLVM function type for an `#extern` declaration:
/// small aggregates become `iN`, large ones become pointers, and an indirect
/// return prepends a hidden `sret` pointer parameter (the function then returns
/// `void`).
pub fn externFnType(cg: *ModuleCg, func: ir.IrFunction, sig: FnAbi) !llvm.LLVMTypeRef {
    const ptr_ty = llvm.LLVMPointerTypeInContext(cg.ctx, 0);
    const tys = try cg.allocator.alloc(llvm.LLVMTypeRef, func.params.len + @as(usize, if (sig.sret) 1 else 0));
    defer cg.allocator.free(tys);

    var n: usize = 0;
    if (sig.sret) {
        tys[n] = ptr_ty;
        n += 1;
    }
    for (sig.params) |p| {
        tys[n] = switch (p.class) {
            // A `fn(...)` param at the C boundary is a THIN function pointer, not
            // skarn's fat `{fn, env}` closure — C expects a bare pointer.
            .direct => if (p.ir_ty == .fn_ptr) ptr_ty else types.lower(cg, p.ir_ty),
            .coerce => |bits| llvm.LLVMIntTypeInContext(cg.ctx, bits),
            .indirect => ptr_ty,
        };
        n += 1;
    }

    const ret_lty = switch (sig.ret) {
        .direct => if (func.return_ty == .fn_ptr) ptr_ty else types.lower(cg, func.return_ty),
        .coerce => |bits| llvm.LLVMIntTypeInContext(cg.ctx, bits),
        .indirect => llvm.LLVMVoidTypeInContext(cg.ctx),
    };
    return llvm.LLVMFunctionType(ret_lty, tys.ptr, @intCast(n), 0);
}

/// Attach `sret`/`byval` type attributes so LLVM's own Win64 lowering matches
/// Clang exactly (the indirect copy/return-slot handling).
pub fn applyAbiAttrs(cg: *ModuleCg, lv: llvm.LLVMValueRef, sig: FnAbi) void {
    if (sig.sret) addTypeAttr(cg, lv, 1, "sret", sig.ret_struct);
    const base: c_uint = if (sig.sret) 2 else 1; // 1-based; 0 is the return slot
    for (sig.params, 0..) |p, i| switch (p.class) {
        .indirect => addTypeAttr(cg, lv, base + @as(c_uint, @intCast(i)), "byval", p.llvm_struct),
        else => {},
    };
}

fn addTypeAttr(cg: *ModuleCg, lv: llvm.LLVMValueRef, index: c_uint, name: []const u8, ty: llvm.LLVMTypeRef) void {
    const kind = llvm.LLVMGetEnumAttributeKindForName(name.ptr, name.len);
    const attr = llvm.LLVMCreateTypeAttribute(cg.ctx, kind, ty);
    llvm.LLVMAddAttributeAtIndex(lv, index, attr);
}

// Call-site value coercions (round-trip through stack memory)
// You cannot bitcast an aggregate to/from an integer directly in LLVM, so the
// small-struct coercions go through an alloca, exactly like Clang.
//
// The scratch allocas are emitted in the *entry block*, not at the call site:
// an alloca anywhere else is a dynamic stack allocation, which on Windows x64
// emits a `__chkstk` stack-probe call that the CRT-less link can't resolve.
// Entry-block allocas fold into the fixed frame and need no probe.

/// Allocate scratch in the function's entry block (so it joins the fixed frame).
pub fn entryAlloca(cg: *ModuleCg, llvm_fn: llvm.LLVMValueRef, ty: llvm.LLVMTypeRef) llvm.LLVMValueRef {
    const entry = llvm.LLVMGetEntryBasicBlock(llvm_fn);
    const b = llvm.LLVMCreateBuilderInContext(cg.ctx);
    defer llvm.LLVMDisposeBuilder(b);
    if (llvm.LLVMGetFirstInstruction(entry)) |first|
        llvm.LLVMPositionBuilderBefore(b, first)
    else
        llvm.LLVMPositionBuilderAtEnd(b, entry);
    return llvm.LLVMBuildAlloca(b, ty, "");
}

/// `%Struct` value → `iN` (a small aggregate passed in a register).
pub fn structToInt(cg: *ModuleCg, llvm_fn: llvm.LLVMValueRef, val: llvm.LLVMValueRef, struct_ty: llvm.LLVMTypeRef, bits: u16) llvm.LLVMValueRef {
    const int_ty = llvm.LLVMIntTypeInContext(cg.ctx, bits);
    const tmp = entryAlloca(cg, llvm_fn, struct_ty);
    _ = llvm.LLVMBuildStore(cg.builder, val, tmp);
    return llvm.LLVMBuildLoad2(cg.builder, int_ty, tmp, "");
}

/// `iN` (a coerced return value) → `%Struct` value.
pub fn intToStruct(cg: *ModuleCg, llvm_fn: llvm.LLVMValueRef, val: llvm.LLVMValueRef, struct_ty: llvm.LLVMTypeRef) llvm.LLVMValueRef {
    const tmp = entryAlloca(cg, llvm_fn, struct_ty);
    _ = llvm.LLVMBuildStore(cg.builder, val, tmp);
    return llvm.LLVMBuildLoad2(cg.builder, struct_ty, tmp, "");
}

/// `%Struct` value → pointer to a fresh stack copy (a Win64 indirect argument).
pub fn structToPtr(cg: *ModuleCg, llvm_fn: llvm.LLVMValueRef, val: llvm.LLVMValueRef, struct_ty: llvm.LLVMTypeRef) llvm.LLVMValueRef {
    const tmp = entryAlloca(cg, llvm_fn, struct_ty);
    _ = llvm.LLVMBuildStore(cg.builder, val, tmp);
    return tmp;
}
