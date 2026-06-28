/// Function declaration + definition.
const std = @import("std");
const ir = @import("../../ir.zig");
const llvm = @import("c_api.zig").llvm;
const types_mod = @import("types.zig");
const local_vars = @import("local_vars.zig");
const instrs = @import("instrs.zig");
const terminators = @import("terminators.zig");
const attrs = @import("attrs.zig");
const abi = @import("abi.zig");
const ModuleCg = @import("context.zig").ModuleCg;

/// Per-function codegen state.
pub const FnCg = struct {
    cg: *ModuleCg,
    func: ir.IrFunction,
    llvm_fn: llvm.LLVMValueRef,

    blocks: std.AutoHashMap(ir.BlockId, llvm.LLVMBasicBlockRef),
    regs: std.AutoHashMap(ir.RegId, llvm.LLVMValueRef),
    locals: std.StringHashMap(llvm.LLVMValueRef), // name → alloca
    params: std.StringHashMap(llvm.LLVMValueRef), // name → param value

    /// IrType of each register result — used by field-access to determine struct layout.
    reg_ir_types: std.AutoHashMap(ir.RegId, ir.IrType),
    /// IrType of each local variable.
    local_ir_types: std.StringHashMap(ir.IrType),
    /// IrType of each parameter.
    param_ir_types: std.StringHashMap(ir.IrType),

    fn deinit(self: *FnCg) void {
        self.blocks.deinit();
        self.regs.deinit();
        self.locals.deinit();
        self.params.deinit();
        self.reg_ir_types.deinit();
        self.local_ir_types.deinit();
        self.param_ir_types.deinit();
    }

    /// Return the IrType of a Value (used by field-access lowering).
    pub fn irTypeOf(self: *const FnCg, val: ir.Value) ?ir.IrType {
        return switch (val) {
            .reg => |id| self.reg_ir_types.get(id),
            .param => |name| self.param_ir_types.get(name),
            .local => |name| self.local_ir_types.get(name),
            .global => |name| self.cg.global_ir_types.get(name),
            else => null,
        };
    }
};

pub fn declareAll(cg: *ModuleCg, funcs: []const ir.IrFunction) !void {
    for (funcs) |f| try declareOne(cg, f);
}

fn declareOne(cg: *ModuleCg, func: ir.IrFunction) !void {
    if (cg.fn_decls.contains(func.name)) return;

    // External C functions get Win64 C-ABI lowering for by-value aggregate
    // params/returns; everything else keeps its natural LLVM signature.
    var abi_sig: ?abi.FnAbi = null;
    const fn_ty = blk: {
        if (func.extern_name != null) {
            var sig = try abi.computeFnAbi(cg, func);
            if (sig.nontrivial) {
                abi_sig = sig;
                break :blk try abi.externFnType(cg, func, sig);
            }
            sig.deinit(cg.allocator);
        }
        break :blk try types_mod.fnType(cg, func);
    };

    const name_z = try cg.allocator.dupeZ(u8, func.name);
    defer cg.allocator.free(name_z);

    const lv = llvm.LLVMAddFunction(cg.mod, name_z, fn_ty);

    // Parameter names are cosmetic; skip them for ABI-lowered externs whose
    // LLVM parameters no longer correspond 1:1 to source parameters.
    if (abi_sig == null) {
        for (func.params, 0..) |p, i| {
            const pv = llvm.LLVMGetParam(lv, @intCast(i));
            llvm.LLVMSetValueName2(pv, p.name.ptr, p.name.len);
        }
    }

    if (func.extern_name) |_| llvm.LLVMSetLinkage(lv, llvm.LLVMExternalLinkage);
    attrs.applyFunctionAttrs(cg, func, lv);

    // A defined Skarn function that isn't the entry point, `#export`ed, or external
    // gets INTERNAL linkage. Skarn emits the whole program as one object, so these
    // are module-private — and a global symbol like `exit`/`abort` would clash
    // with the C runtime once `link_libc` is used. (Also lets LLVM drop dead ones.)
    // `#weak` (overridable symbol) and `#keep` (survives stripping) need non-internal
    // linkage, so they opt out of the module-private internalization.
    if (func.blocks.len > 0 and func.extern_name == null and func.export_sym == null and
        !func.entry and !func.weak and !func.keep)
        llvm.LLVMSetLinkage(lv, llvm.LLVMInternalLinkage);

    if (abi_sig) |sig| {
        abi.applyAbiAttrs(cg, lv, sig);
        try cg.fn_abi.put(func.name, sig);
    }
    try cg.fn_decls.put(func.name, lv);
}

pub fn defineAll(cg: *ModuleCg, funcs: []const ir.IrFunction) !void {
    for (funcs) |f| if (f.blocks.len > 0) try defineOne(cg, f);
}

fn defineOne(cg: *ModuleCg, func: ir.IrFunction) !void {
    const llvm_fn = cg.fn_decls.get(func.name) orelse return;

    // Create all basic blocks first (terminators reference them by id).
    var blocks = std.AutoHashMap(ir.BlockId, llvm.LLVMBasicBlockRef).init(cg.allocator);
    errdefer blocks.deinit();
    for (func.blocks) |block| {
        var bb_name_buf: [32]u8 = undefined;
        const name_z = try std.fmt.bufPrintZ(&bb_name_buf, "bb{d}", .{block.id});
        try blocks.put(block.id, llvm.LLVMAppendBasicBlockInContext(cg.ctx, llvm_fn, name_z));
    }

    // Emit allocas at the start of the entry block.
    const entry_bb = blocks.get(func.blocks[0].id).?;
    var locals = try local_vars.allocateLocals(cg, func, entry_bb);
    errdefer locals.deinit();

    // Build param maps.
    var params = std.StringHashMap(llvm.LLVMValueRef).init(cg.allocator);
    var param_tys = std.StringHashMap(ir.IrType).init(cg.allocator);
    errdefer {
        params.deinit();
        param_tys.deinit();
    }
    for (func.params, 0..) |p, i| {
        try params.put(p.name, llvm.LLVMGetParam(llvm_fn, @intCast(i)));
        try param_tys.put(p.name, p.ty);
    }

    // Build local type map (from store_local instructions).
    var local_tys = std.StringHashMap(ir.IrType).init(cg.allocator);
    errdefer local_tys.deinit();
    for (func.blocks) |block| {
        for (block.instrs) |instr| switch (instr.kind) {
            .store_local => |sl| if (!local_tys.contains(sl.name))
                try local_tys.put(sl.name, instr.ty),
            else => {},
        };
    }

    var fncg = FnCg{
        .cg = cg,
        .func = func,
        .llvm_fn = llvm_fn,
        .blocks = blocks,
        .regs = std.AutoHashMap(ir.RegId, llvm.LLVMValueRef).init(cg.allocator),
        .locals = locals,
        .params = params,
        .reg_ir_types = std.AutoHashMap(ir.RegId, ir.IrType).init(cg.allocator),
        .local_ir_types = local_tys,
        .param_ir_types = param_tys,
    };
    defer fncg.deinit();

    // Lower each block.
    for (func.blocks) |block| {
        llvm.LLVMPositionBuilderAtEnd(cg.builder, fncg.blocks.get(block.id).?);
        for (block.instrs) |instr| instrs.lower(cg, &fncg, instr);
        if (block.terminator) |term| terminators.lower(cg, &fncg, term, func);
    }
}
