/// Imm / Value → LLVMValueRef.
const std = @import("std");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const types = @import("types.zig");
const ModuleCg = @import("context.zig").ModuleCg;

/// Process Skarn string escape sequences: \n \r \t \\ \" \0 \xHH
/// The input is already quote-stripped (trimQuotes was applied in ir.zig).
/// Returns heap-allocated buffer; caller must free.
fn unescapeString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(allocator, s.len);
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            try out.append(allocator, s[i]);
            continue;
        }
        i += 1;
        switch (s[i]) {
            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            't' => try out.append(allocator, '\t'),
            '\\' => try out.append(allocator, '\\'),
            '"' => try out.append(allocator, '"'),
            '0' => try out.append(allocator, 0),
            'x' => {
                if (i + 2 < s.len) {
                    const hi = s[i + 1];
                    const lo = s[i + 2];
                    const nibble = [2]u8{ hi, lo };
                    const byte = std.fmt.parseInt(u8, &nibble, 16) catch {
                        try out.append(allocator, '\\');
                        try out.append(allocator, 'x');
                        continue;
                    };
                    try out.append(allocator, byte);
                    i += 2;
                } else {
                    try out.append(allocator, '\\');
                    try out.append(allocator, s[i]);
                }
            },
            else => {
                // Unknown escape — keep as-is
                try out.append(allocator, '\\');
                try out.append(allocator, s[i]);
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn lowerImm(cg: *ModuleCg, imm: ir.Imm, hint_ty: ir.IrType) llvm.LLVMValueRef {
    if (imm == .null) {
        // null for optional pointer → raw null pointer (not a struct)
        if (hint_ty == .optional) return optionalNone(cg, hint_ty.optional.*);
        // null for a raw pointer → raw null pointer
        if (hint_ty == .ptr) return llvm.LLVMConstNull(llvm.LLVMPointerTypeInContext(cg.ctx, 0));
    }
    const lty = types.lower(cg, hint_ty);
    return lowerImmAs(cg, imm, lty);
}

pub fn lowerImmAs(cg: *ModuleCg, imm: ir.Imm, lty: llvm.LLVMTypeRef) llvm.LLVMValueRef {
    return switch (imm) {
        // Low 64 bits (two's-complement); `LLVMConstInt` narrows them to `lty`'s
        // width. A comptime value may exceed i64 (the VM computes in i128, and
        // wrapping arithmetic overflows narrow types freely), so truncate rather
        // than `@intCast` — only the low bits matter at the destination width.
        .int => |v| llvm.LLVMConstInt(lty, @truncate(@as(u128, @bitCast(v))), 1),
        .uint => |v| llvm.LLVMConstInt(lty, @as(c_ulonglong, @truncate(v)), 0),
        .float => |v| llvm.LLVMConstReal(lty, v),
        .bool => |v| llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(cg.ctx), if (v) 1 else 0, 0),
        .null => llvm.LLVMConstNull(lty),
        .rune => |r| llvm.LLVMConstInt(llvm.LLVMInt32TypeInContext(cg.ctx), r, 0),

        // String literals → private global constant + { ptr, len } slice struct.
        // With LLVM opaque pointers (15+), the global value itself is already a ptr.
        .text => |s| blk: {
            var name_buf: [32]u8 = undefined;
            const name_z = std.fmt.bufPrintZ(&name_buf, ".str.{d}", .{cg.string_counter}) catch break :blk llvm.LLVMGetUndef(cg.getSliceType());
            cg.string_counter += 1;

            // Process escape sequences (\n, \t, \\, \", \0, \xHH) before emitting.
            const bytes = unescapeString(cg.allocator, s) catch s;
            defer if (bytes.ptr != s.ptr) cg.allocator.free(bytes);

            const i8_ty = llvm.LLVMInt8TypeInContext(cg.ctx);
            const arr_ty = llvm.LLVMArrayType2(i8_ty, bytes.len);

            const gv = llvm.LLVMAddGlobal(cg.mod, arr_ty, name_z);
            // dont_null_terminate=1: we store the raw string, no NUL
            llvm.LLVMSetInitializer(gv, llvm.LLVMConstStringInContext(cg.ctx, bytes.ptr, @intCast(bytes.len), 1));
            llvm.LLVMSetGlobalConstant(gv, 1);
            llvm.LLVMSetLinkage(gv, llvm.LLVMPrivateLinkage);
            llvm.LLVMSetUnnamedAddress(gv, llvm.LLVMGlobalUnnamedAddr);

            // Build slice struct { ptr=gv, len=bytes.len }
            const i64_ty = llvm.LLVMInt64TypeInContext(cg.ctx);
            var fields = [_]llvm.LLVMValueRef{
                gv,
                llvm.LLVMConstInt(i64_ty, bytes.len, 0),
            };
            break :blk llvm.LLVMConstStructInContext(cg.ctx, &fields, 2, 0);
        },
    };
}

pub fn optionalNone(cg: *ModuleCg, payload_ty: ir.IrType) llvm.LLVMValueRef {
    // Nullable pointer optimisation: ?*T → null ptr instead of { false, undef }
    if (payload_ty == .ptr)
        return llvm.LLVMConstNull(llvm.LLVMPointerTypeInContext(cg.ctx, 0));

    const opt_ty = types.optionalType(cg, payload_ty);
    var fields = [_]llvm.LLVMValueRef{
        llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(cg.ctx), 0, 0),
        llvm.LLVMGetUndef(types.optionalPayloadType(cg, payload_ty)),
    };
    _ = opt_ty;
    return llvm.LLVMConstStructInContext(cg.ctx, &fields, 2, 0);
}

pub fn optionalSome(cg: *ModuleCg, payload: llvm.LLVMValueRef, payload_ty: ir.IrType) llvm.LLVMValueRef {
    // Nullable pointer optimisation: ?*T → the pointer itself (non-null = some)
    if (payload_ty == .ptr) return payload;

    var opt = llvm.LLVMGetUndef(types.optionalType(cg, payload_ty));
    opt = llvm.LLVMBuildInsertValue(cg.builder, opt, llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(cg.ctx), 1, 0), 0, "");
    const stored_payload = if (payload_ty == .void)
        llvm.LLVMConstInt(llvm.LLVMInt8TypeInContext(cg.ctx), 0, 0)
    else
        coerce(cg.builder, cg.ctx, payload, types.optionalPayloadType(cg, payload_ty));
    return llvm.LLVMBuildInsertValue(cg.builder, opt, stored_payload, 1, "");
}

/// Resolve a Skarn Value to an LLVMValueRef.
/// `fncg` is *FnCg from functions.zig — passed as anytype to avoid circular imports.
pub fn resolveValue(
    cg: *ModuleCg,
    fncg: anytype,
    val: ir.Value,
    ty: ir.IrType,
) llvm.LLVMValueRef {
    const undef = llvm.LLVMGetUndef(types.lower(cg, ty));
    return switch (val) {
        .imm => |imm| lowerImm(cg, imm, ty),
        .reg => |id| fncg.regs.get(id) orelse undef,
        .param => |name| fncg.params.get(name) orelse undef,

        .local => |name| blk: {
            const alloca = fncg.locals.get(name) orelse break :blk undef;
            const load_ty = fncg.local_ir_types.get(name) orelse ty;
            break :blk llvm.LLVMBuildLoad2(cg.builder, types.lower(cg, load_ty), alloca, "");
        },

        .global => |name| blk: {
            if (cg.global_decls.get(name)) |gv| {
                // Always load with the global's OWN type, then coerce to the
                // requested type. Loading directly with the hint type reads the
                // wrong width for a constant of a different size — e.g. an `i32`
                // const used as `usize` would read 8 bytes from a 4-byte global
                // and pick up garbage in the high half.
                const gty = llvm.LLVMGlobalGetValueType(gv);
                const loaded = llvm.LLVMBuildLoad2(cg.builder, gty, gv, "");
                if (ty == .unknown) break :blk loaded;
                break :blk coerce(cg.builder, cg.ctx, loaded, types.lower(cg, ty));
            }
            // A reference to a top-level function used as a value (a function
            // pointer / callback): the LLVM function is already a `ptr`, so hand
            // it back directly — no load. Previously this fell through to `undef`,
            // which crashed when the pointer was later called.
            if (cg.fn_decls.get(name)) |fv| break :blk fv;
            break :blk undef;
        },
    };
}

/// Extracts field `index` from an aggregate (struct/array) value, but first
/// verifies that `agg` actually *is* an aggregate of the expected shape.
///
/// This exists because `LLVMBuildExtractValue` does not gracefully reject
/// shape mismatches — passing it a bare `ptr` (or any non-struct/array value)
/// asserts/crashes inside LLVM rather than returning an error. That is
/// precisely the failure mode behind a previous compiler segfault: a value
/// that the IR classified as an interface fat-pointer (`{ ptr, ptr }`) was
/// actually lowered as a thin `ptr`, and `LLVMBuildExtractValue` crashed the
/// whole process on the resulting shape mismatch.
///
/// On mismatch, records an internal lowering error (turned into a clean
/// `error.LoweringFailed` by `LlvmBackend.lower`) and returns `null` instead
/// of calling into LLVM with bad input — "malformed-but-typeable Skarn source
/// must never crash the compiler process" is the invariant this protects.
pub fn extractAggregateField(
    cg: *ModuleCg,
    agg: llvm.LLVMValueRef,
    index: c_uint,
    what: []const u8,
) ?llvm.LLVMValueRef {
    const lty = llvm.LLVMTypeOf(agg);
    const kind = llvm.LLVMGetTypeKind(lty);
    if (kind != llvm.LLVMStructTypeKind and kind != llvm.LLVMArrayTypeKind) {
        cg.recordLoweringError(
            "expected an aggregate value while lowering {s}, but found a value of a different shape (LLVM type kind {d}) — this points to an IR type-shape mismatch upstream",
            .{ what, @as(c_uint, kind) },
            @src(),
        );
        return null;
    }
    const elems: u64 = if (kind == llvm.LLVMStructTypeKind)
        llvm.LLVMCountStructElementTypes(lty)
    else
        llvm.LLVMGetArrayLength2(lty);
    if (@as(u64, index) >= elems) {
        cg.recordLoweringError(
            "field index {d} out of bounds while lowering {s} (aggregate has {d} element(s)) — this points to an IR type-shape mismatch upstream",
            .{ index, what, elems },
            @src(),
        );
        return null;
    }
    return llvm.LLVMBuildExtractValue(cg.builder, agg, index, "");
}

/// Emit a type-coercion from `v` to `dest_lty` if needed.
/// Handles integer widening (sext/zext), narrowing (trunc), and ptr↔int casts.
pub fn coerce(
    builder: llvm.LLVMBuilderRef,
    ctx: llvm.LLVMContextRef,
    v: llvm.LLVMValueRef,
    dest_lty: llvm.LLVMTypeRef,
) llvm.LLVMValueRef {
    const src_lty = llvm.LLVMTypeOf(v);
    if (src_lty == dest_lty) return v;

    const src_kind = llvm.LLVMGetTypeKind(src_lty);
    const dst_kind = llvm.LLVMGetTypeKind(dest_lty);

    if (src_kind == llvm.LLVMIntegerTypeKind and dst_kind == llvm.LLVMIntegerTypeKind) {
        const src_w = llvm.LLVMGetIntTypeWidth(src_lty);
        const dst_w = llvm.LLVMGetIntTypeWidth(dest_lty);

        // int → bool: compare ≠ 0, not truncate.
        //   Trunc(i32 2, i1) = i1 0 = false  ← WRONG
        //   ICmpNE(i32 2, 0) = i1 1 = true   ← CORRECT
        if (dst_w == 1 and src_w > 1) {
            const zero = llvm.LLVMConstInt(src_lty, 0, 0);
            return llvm.LLVMBuildICmp(builder, llvm.LLVMIntNE, v, zero, "");
        }

        // bool → int: zero-extend, not sign-extend.
        //   SExt(i1 true=-1, i8) = i8 0xFF  ← WRONG  (sign bit of i1=1 is -1)
        //   ZExt(i1 true=1,  i8) = i8 0x01  ← CORRECT
        if (src_w == 1 and dst_w > 1)
            return llvm.LLVMBuildZExt(builder, v, dest_lty, "");

        if (dst_w > src_w) return llvm.LLVMBuildSExt(builder, v, dest_lty, "");
        if (dst_w < src_w) return llvm.LLVMBuildTrunc(builder, v, dest_lty, "");
        return v; // same width, different signedness — no-op in LLVM
    }

    if (src_kind == llvm.LLVMPointerTypeKind and dst_kind == llvm.LLVMIntegerTypeKind)
        return llvm.LLVMBuildPtrToInt(builder, v, dest_lty, "");

    if (src_kind == llvm.LLVMIntegerTypeKind and dst_kind == llvm.LLVMPointerTypeKind)
        return llvm.LLVMBuildIntToPtr(builder, v, dest_lty, "");

    // Float ↔ integer conversions.
    const is_float_src = src_kind == llvm.LLVMFloatTypeKind or src_kind == llvm.LLVMDoubleTypeKind;
    const is_float_dst = dst_kind == llvm.LLVMFloatTypeKind or dst_kind == llvm.LLVMDoubleTypeKind;

    if (is_float_src and dst_kind == llvm.LLVMIntegerTypeKind)
        return llvm.LLVMBuildFPToSI(builder, v, dest_lty, "");

    if (src_kind == llvm.LLVMIntegerTypeKind and is_float_dst) {
        // i1 (bool) → float: use unsigned path so true→1.0 not -1.0
        const src_w = llvm.LLVMGetIntTypeWidth(src_lty);
        return if (src_w == 1)
            llvm.LLVMBuildUIToFP(builder, v, dest_lty, "")
        else
            llvm.LLVMBuildSIToFP(builder, v, dest_lty, "");
    }

    // Float ↔ float widening / narrowing.
    if (is_float_src and is_float_dst) {
        const src_is_double = src_kind == llvm.LLVMDoubleTypeKind;
        const dst_is_double = dst_kind == llvm.LLVMDoubleTypeKind;
        if (!src_is_double and dst_is_double) return llvm.LLVMBuildFPExt(builder, v, dest_lty, "");
        if (src_is_double and !dst_is_double) return llvm.LLVMBuildFPTrunc(builder, v, dest_lty, "");
        return v;
    }

    if (src_kind == llvm.LLVMStructTypeKind and dst_kind == llvm.LLVMStructTypeKind) {
        // e.g. slice struct passed where another struct is expected — alloca + bitload trick
        const tmp = llvm.LLVMBuildAlloca(builder, src_lty, "");
        _ = llvm.LLVMBuildStore(builder, v, tmp);
        return llvm.LLVMBuildLoad2(builder, dest_lty, tmp, "");
    }

    // Fallback: bitcast
    _ = ctx;
    return llvm.LLVMBuildBitCast(builder, v, dest_lty, "");
}

/// Type-aware numeric coercion. LLVM integer types do not retain signedness,
/// so explicit casts must use the Skarn source/destination types to select the
/// correct extension and float-conversion instructions.
pub fn coerceTyped(
    builder: llvm.LLVMBuilderRef,
    ctx: llvm.LLVMContextRef,
    v: llvm.LLVMValueRef,
    src_ty: ir.IrType,
    dest_ty: ir.IrType,
    dest_lty: llvm.LLVMTypeRef,
) llvm.LLVMValueRef {
    const src_lty = llvm.LLVMTypeOf(v);
    const src_kind = llvm.LLVMGetTypeKind(src_lty);
    const dst_kind = llvm.LLVMGetTypeKind(dest_lty);
    const src_float = src_kind == llvm.LLVMFloatTypeKind or src_kind == llvm.LLVMDoubleTypeKind;
    const dst_float = dst_kind == llvm.LLVMFloatTypeKind or dst_kind == llvm.LLVMDoubleTypeKind;

    if (src_float and dst_kind == llvm.LLVMIntegerTypeKind)
        return if (isUnsigned(dest_ty))
            llvm.LLVMBuildFPToUI(builder, v, dest_lty, "")
        else
            llvm.LLVMBuildFPToSI(builder, v, dest_lty, "");

    if (src_kind == llvm.LLVMIntegerTypeKind and dst_float)
        return if (isUnsigned(src_ty))
            llvm.LLVMBuildUIToFP(builder, v, dest_lty, "")
        else
            llvm.LLVMBuildSIToFP(builder, v, dest_lty, "");

    if (src_kind == llvm.LLVMIntegerTypeKind and dst_kind == llvm.LLVMIntegerTypeKind) {
        const src_w = llvm.LLVMGetIntTypeWidth(src_lty);
        const dst_w = llvm.LLVMGetIntTypeWidth(dest_lty);
        if (dst_w > src_w)
            return if (isUnsigned(src_ty))
                llvm.LLVMBuildZExt(builder, v, dest_lty, "")
            else
                llvm.LLVMBuildSExt(builder, v, dest_lty, "");
    }

    return coerce(builder, ctx, v, dest_lty);
}

fn isUnsigned(ty: ir.IrType) bool {
    return switch (ty) {
        .u, .byte, .usize, .addr, .bool => true,
        else => false,
    };
}
