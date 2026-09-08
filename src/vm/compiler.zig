const std = @import("std");
const builtin = @import("builtin");
const ir = @import("../ir.zig");
const instructions = @import("instructions.zig");
const value = @import("value.zig");

const Instr = instructions.Instr;
const Opcode = instructions.Opcode;
const Reg = instructions.Reg;
const Value = value.Value;
const BytecodeFunction = instructions.BytecodeFunction;
const BytecodeModule = instructions.BytecodeModule;

pub const CompileError = error{
    /// An IR construct this compiler does not lower yet (slices, interfaces,
    /// globals, ranges, …). Honest failure rather than silent wrong code — the
    /// migration ports these incrementally.
    Unsupported,
    OutOfMemory,
};

/// Lower an entire IR module to a runnable bytecode module. Builds the
/// name→index table first so `call` instructions resolve across functions.
pub fn compileModule(allocator: std.mem.Allocator, module: ir.IrModule) CompileError!BytecodeModule {
    var func_map = std.StringHashMap(u32).init(allocator);
    defer func_map.deinit();
    for (module.functions, 0..) |f, i| {
        try func_map.put(f.name, @intCast(i));
    }

    var funcs = try allocator.alloc(BytecodeFunction, module.functions.len);
    var built: usize = 0;
    errdefer {
        for (funcs[0..built]) |*f| f.deinit(allocator);
        allocator.free(funcs);
    }
    for (module.functions) |f| {
        // `#extern("lib","sym")` functions have no body — compile them to an FFI
        // thunk the VM dispatches natively at call time.
        if (f.extern_name) |sym| {
            if (f.blocks.len == 0) {
                funcs[built] = .{
                    .name = f.name,
                    .instrs = &.{},
                    .num_regs = 0,
                    .num_locals = 0,
                    .num_params = @intCast(f.params.len),
                    .extern_call = .{
                        .lib = f.extern_lib orelse "",
                        .symbol = sym,
                        .returns_value = !f.return_ty.isVoid(),
                    },
                };
                built += 1;
                continue;
            }
        }
        // A function using constructs we can't lower yet becomes a trap stub so
        // the rest of the module still runs; calling it just triggers fallback.
        funcs[built] = compileFunction(allocator, f, &func_map, module) catch |e| switch (e) {
            error.Unsupported => try stubFunction(allocator, f.name),
            else => return e,
        };
        built += 1;
    }

    // Resolve each vtable's method names to function indices for dispatch.
    const vtables = try allocator.alloc([]const u32, module.vtables.len);
    errdefer allocator.free(vtables);
    for (module.vtables, 0..) |vt, i| {
        const slots = try allocator.alloc(u32, vt.methods.len);
        for (vt.methods, 0..) |method_name, j| {
            slots[j] = func_map.get(method_name) orelse 0; // 0 = trap stub if missing
        }
        vtables[i] = slots;
    }

    return .{ .functions = funcs, .vtables = vtables };
}

fn stubFunction(allocator: std.mem.Allocator, name: []const u8) CompileError!BytecodeFunction {
    const instrs = try allocator.alloc(Instr, 1);
    instrs[0] = Instr.with_imm(.trap, -1);
    return .{ .name = name, .instrs = instrs, .num_regs = 1, .num_locals = 0 };
}

/// Lower a single IR function. `func_map` resolves `call` targets; `module`
/// provides struct/variant/vtable layout. Pass null `func_map` and an empty
/// module for a standalone function with no calls or aggregates.
pub fn compileFunction(
    allocator: std.mem.Allocator,
    func: ir.IrFunction,
    func_map: ?*const std.StringHashMap(u32),
    module: ir.IrModule,
) CompileError!BytecodeFunction {
    var c = FnCompiler.init(allocator, func, func_map, module);
    defer c.deinit();
    return c.compile();
}

const FnCompiler = struct {
    allocator: std.mem.Allocator,
    func: ir.IrFunction,
    func_map: ?*const std.StringHashMap(u32),
    module: ir.IrModule,

    out: std.ArrayList(Instr) = .empty,
    constants: std.ArrayList(Value) = .empty,
    /// Parameter + named-local name → slot index.
    local_slots: std.StringHashMap(u32),
    /// IR block id → first instruction offset (filled as blocks are emitted).
    block_offsets: std.AutoHashMap(ir.BlockId, u32),
    /// Static type of each result register, for resolving field names.
    reg_types: std.AutoHashMap(ir.RegId, ir.IrType),
    /// Static type of each parameter/local, ditto.
    name_types: std.StringHashMap(ir.IrType),
    /// Register → its position in a `type_info(...)` reflection tree, so a chain
    /// like `type_info(T).fields[0].name` folds step by step.
    type_info_nodes: std.AutoHashMap(ir.RegId, TypeInfoNode),
    /// Scalar locals/params whose address is taken (`&x`). Their slot holds a
    /// pointer to a 1-cell zone block instead of the value, so the value is
    /// addressable; reads/writes go through the cell. (Aggregate locals already
    /// hold a cell pointer, so they're never spilled here.)
    addressed: std.StringHashMap(void),
    next_reg: Reg = 0,

    fn init(
        allocator: std.mem.Allocator,
        func: ir.IrFunction,
        func_map: ?*const std.StringHashMap(u32),
        module: ir.IrModule,
    ) FnCompiler {
        return .{
            .allocator = allocator,
            .func = func,
            .func_map = func_map,
            .module = module,
            .local_slots = std.StringHashMap(u32).init(allocator),
            .block_offsets = std.AutoHashMap(ir.BlockId, u32).init(allocator),
            .reg_types = std.AutoHashMap(ir.RegId, ir.IrType).init(allocator),
            .name_types = std.StringHashMap(ir.IrType).init(allocator),
            .type_info_nodes = std.AutoHashMap(ir.RegId, TypeInfoNode).init(allocator),
            .addressed = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *FnCompiler) void {
        self.out.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.local_slots.deinit();
        self.block_offsets.deinit();
        self.reg_types.deinit();
        self.name_types.deinit();
        self.type_info_nodes.deinit();
        self.addressed.deinit();
    }

    fn compile(self: *FnCompiler) CompileError!BytecodeFunction {
        try self.collectLocals();
        try self.collectTypes();
        try self.collectAddressed();
        self.seedScratchBase();
        try self.emitAddressedInit();

        for (self.func.blocks) |block| {
            try self.block_offsets.put(block.id, @intCast(self.out.items.len));
            for (block.instrs) |inst| try self.lowerInstr(inst);
            if (block.terminator) |term| try self.lowerTerminator(term);
        }

        try self.patchJumps();

        return .{
            .name = self.func.name,
            .instrs = try self.out.toOwnedSlice(self.allocator),
            .num_regs = self.next_reg,
            .num_locals = self.local_slots.count(),
            .num_params = @intCast(self.func.params.len),
            .constants = try self.constants.toOwnedSlice(self.allocator),
        };
    }

    // Setup passes

    /// Parameters take the leading slots; every `store_local` name gets one too.
    fn collectLocals(self: *FnCompiler) CompileError!void {
        for (self.func.params) |p| _ = try self.ensureSlot(p.name);
        for (self.func.blocks) |block| {
            for (block.instrs) |inst| switch (inst.kind) {
                .store_local => |sl| _ = try self.ensureSlot(sl.name),
                else => {},
            };
        }
    }

    /// Record the static type of every register and named local, so field
    /// accesses can map a field name to its cell offset within its struct.
    fn collectTypes(self: *FnCompiler) CompileError!void {
        for (self.func.params) |p| try self.name_types.put(p.name, p.ty);
        for (self.func.blocks) |block| {
            for (block.instrs) |inst| {
                if (inst.id) |id| {
                    try self.reg_types.put(id, inst.ty);
                    if (inst.kind == .builtin) {
                        const b = inst.kind.builtin;
                        if (std.mem.eql(u8, b.name, "type_info")) {
                            if (b.type_arg) |ta| try self.type_info_nodes.put(id, .{ .type = ta });
                        }
                    }
                }
            }
        }
        // Second pass: local types depend on register types resolved above.
        for (self.func.blocks) |block| {
            for (block.instrs) |inst| switch (inst.kind) {
                .store_local => |sl| try self.name_types.put(sl.name, self.typeOf(sl.value)),
                else => {},
            };
        }
    }

    /// Find scalar locals/params whose address is taken (`&x`). They get spilled
    /// to a 1-cell zone block so the value is addressable. Aggregates already
    /// hold a cell pointer, so they're skipped. Runs after `collectTypes`.
    fn collectAddressed(self: *FnCompiler) CompileError!void {
        for (self.func.blocks) |block| {
            for (block.instrs) |inst| {
                if (inst.kind != .unary) continue;
                const un = inst.kind.unary;
                if (un.op != .ref) continue;
                const name = switch (un.value) {
                    .local, .param => |n| n,
                    else => continue,
                };
                if (isAggregate(self.typeOf(un.value))) continue;
                try self.addressed.put(name, {});
            }
        }
    }

    /// Allocate a backing cell for each addressed scalar local at function entry
    /// and point its slot at the cell. An addressed parameter's incoming value is
    /// moved into the cell first.
    fn emitAddressedInit(self: *FnCompiler) CompileError!void {
        var it = self.addressed.keyIterator();
        while (it.next()) |key| {
            const name = key.*;
            const slot = try self.ensureSlot(name);
            const cell = self.newReg();
            if (self.isParam(name)) {
                const pval = self.newReg();
                try self.emit(Instr.r_imm(.load_local, pval, @intCast(slot)));
                try self.emit(Instr.r_imm(.zone_alloc, cell, 1));
                try self.emit(Instr.r_r_imm(.store_cell, cell, pval, 0));
            } else {
                try self.emit(Instr.r_imm(.zone_alloc, cell, 1));
            }
            try self.emit(Instr.r_r_imm(.store_local, 0, cell, @intCast(slot)));
        }
    }

    fn isParam(self: *FnCompiler, name: []const u8) bool {
        for (self.func.params) |p| if (std.mem.eql(u8, p.name, name)) return true;
        return false;
    }

    fn ensureSlot(self: *FnCompiler, name: []const u8) CompileError!u32 {
        if (self.local_slots.get(name)) |s| return s;
        const slot: u32 = self.local_slots.count();
        try self.local_slots.put(name, slot);
        return slot;
    }

    /// Scratch registers start just past the highest IR result id.
    fn seedScratchBase(self: *FnCompiler) void {
        var max_id: ?Reg = null;
        for (self.func.blocks) |block| {
            for (block.instrs) |inst| {
                if (inst.id) |id| {
                    if (max_id == null or id > max_id.?) max_id = id;
                }
            }
        }
        self.next_reg = if (max_id) |m| m + 1 else 0;
    }

    fn newReg(self: *FnCompiler) Reg {
        const r = self.next_reg;
        self.next_reg += 1;
        return r;
    }

    fn typeOf(self: *FnCompiler, v: ir.Value) ir.IrType {
        return switch (v) {
            .reg => |r| self.reg_types.get(r) orelse .unknown,
            .param, .local => |n| self.name_types.get(n) orelse .unknown,
            // A string literal lowers to a `.text` immediate; recovering that
            // type lets a `s := "…"` local answer `.len` (and other text ops).
            // Numeric widths stay `.unknown` (the instruction's result type
            // carries them), so this doesn't perturb arithmetic.
            .imm => |imm| if (imm == .text) .text else .unknown,
            .global => .unknown,
        };
    }

    // Operand resolution

    /// Resolve an IR value to a register, emitting loads for immediates and
    /// locals/params as needed.
    fn resolveReg(self: *FnCompiler, v: ir.Value) CompileError!Reg {
        switch (v) {
            .reg => |r| return r,
            .imm => |imm| {
                const dst = self.newReg();
                try self.materializeImm(dst, imm);
                return dst;
            },
            .param, .local => |name| {
                // A bare error variant `.code` (as in `e == .code`) lowers to a
                // dotted pseudo-local; resolve it to its error discriminant.
                if (name.len > 1 and name[0] == '.') {
                    if (self.errorVariantIndex(name[1..])) |idx| {
                        const dst = self.newReg();
                        try self.emit(Instr.r_imm(.load_imm, dst, idx));
                        return dst;
                    }
                }
                const slot = self.local_slots.get(name) orelse return error.Unsupported;
                // An addressed scalar's slot holds a pointer to its cell; read the
                // value back through it.
                if (self.addressed.contains(name)) {
                    const ptr = self.newReg();
                    try self.emit(Instr.r_imm(.load_local, ptr, @intCast(slot)));
                    const dst = self.newReg();
                    try self.emit(Instr.r_r_imm(.load_cell, dst, ptr, 0));
                    return dst;
                }
                const dst = self.newReg();
                try self.emit(Instr.r_imm(.load_local, dst, slot));
                return dst;
            },
            .global => |name| {
                // A top-level const's folded value is already in the module.
                for (self.module.globals) |g| {
                    if (!std.mem.eql(u8, g.name, name)) continue;
                    switch (g.init) {
                        .imm => |imm| {
                            const dst = self.newReg();
                            try self.materializeImm(dst, imm);
                            return dst;
                        },
                        // Unreachable today: the const lowering only ever emits
                        // `.imm` globals, and an aggregate top-level constant is
                        // rejected with a clear diagnostic at the const decl
                        // (`effectiveConstImm` in ir.zig). If aggregate consts are
                        // added, materialize the struct_init into cells here.
                        .struct_init => return error.Unsupported,
                    }
                }
                return error.Unsupported;
            },
        }
    }

    fn materializeImm(self: *FnCompiler, dst: Reg, imm: ir.Imm) CompileError!void {
        switch (imm) {
            // `load_imm` always yields a `.int`; bool/uint go through the
            // constant pool so their value tag is preserved (comptime callers
            // distinguish `.uint`/`.bool` from `.int`).
            .int => |v| {
                if (std.math.cast(i64, v)) |small| {
                    try self.emit(Instr.r_imm(.load_imm, dst, small));
                } else try self.loadConst(dst, Value.fromImm(imm));
            },
            else => try self.loadConst(dst, Value.fromImm(imm)),
        }
    }

    fn loadConst(self: *FnCompiler, dst: Reg, val: Value) CompileError!void {
        const idx = try self.addConst(val);
        try self.emit(Instr.r_imm(.load_const, dst, idx));
    }

    fn addConst(self: *FnCompiler, val: Value) CompileError!i64 {
        const idx: i64 = @intCast(self.constants.items.len);
        try self.constants.append(self.allocator, val);
        return idx;
    }

    // Instruction lowering

    fn lowerInstr(self: *FnCompiler, inst: ir.Instr) CompileError!void {
        const target: Reg = if (inst.id) |id| id else 0;
        switch (inst.kind) {
            .const_value => |imm| try self.materializeImm(target, imm),

            .unary => |un| {
                if (un.op == .deref) {
                    const ptr = try self.resolveReg(un.value);
                    // `*p` of an aggregate (struct/enum/slice/array) IS the pointer
                    // to its cell block — aggregates are addressed by pointer, so
                    // there's nothing to load. Only scalar pointees load a cell.
                    if (isAggregate(inst.ty)) {
                        try self.emit(Instr.r_r_imm(.copy, target, ptr, 0));
                    } else {
                        try self.emit(Instr.r_r_imm(.load_cell, target, ptr, 0));
                    }
                    return;
                }
                if (un.op == .ref) {
                    // `&x` of an addressed scalar: its slot already holds the cell
                    // pointer (spilled at entry), so the address is that pointer.
                    const ref_name: ?[]const u8 = switch (un.value) {
                        .local, .param => |n| n,
                        else => null,
                    };
                    if (ref_name) |nm| if (self.addressed.contains(nm)) {
                        const slot = self.local_slots.get(nm) orelse return error.Unsupported;
                        try self.emit(Instr.r_imm(.load_local, target, @intCast(slot)));
                        return;
                    };
                    // An aggregate local already holds a pointer to its cell
                    // block, so `&arr` / `&s` is that pointer.
                    if (!isAggregate(self.typeOf(un.value))) return error.Unsupported;
                    const vr = try self.resolveReg(un.value);
                    try self.emit(Instr.r_r_imm(.copy, target, vr, 0));
                    return;
                }
                const vr = try self.resolveReg(un.value);
                const op: Opcode = switch (un.op) {
                    .neg => if (isFloat(inst.ty)) .neg_f else .neg_i,
                    .not => .not_b,
                    .bit_not => .bitnot,
                    .ref, .deref => return error.Unsupported,
                };
                try self.emit(Instr.r_r_imm(op, target, vr, 0));
            },

            .binary => |bin| {
                const lr = try self.resolveReg(bin.lhs);
                const rr = try self.resolveReg(bin.rhs);
                // For arithmetic the result type tells us int vs float; for
                // comparisons (result `bool`) we must look at the operands,
                // whose types we tracked in the type pre-pass.
                const op_float = isFloat(inst.ty) or
                    isFloat(self.typeOf(bin.lhs)) or isFloat(self.typeOf(bin.rhs));
                const op = try mapBinOp(bin.op, op_float);
                try self.emit(Instr.r_r_r(op, target, lr, rr));
            },

            .cast => |cst| {
                const vr = try self.resolveReg(cst.value);
                const op: Opcode = if (isFloat(inst.ty)) .cast_to_float else .cast_to_int;
                try self.emit(Instr.r_r_imm(op, target, vr, 0));
            },

            .store_local => |sl| {
                const slot = self.local_slots.get(sl.name) orelse return error.Unsupported;
                const vr = try self.resolveReg(sl.value);
                // An addressed scalar is written through its backing cell.
                if (self.addressed.contains(sl.name)) {
                    const ptr = self.newReg();
                    try self.emit(Instr.r_imm(.load_local, ptr, @intCast(slot)));
                    try self.emit(Instr.r_r_imm(.store_cell, ptr, vr, 0));
                } else {
                    try self.emit(Instr.r_r_imm(.store_local, 0, vr, slot));
                }
            },

            .call => |ci| try self.lowerCall(target, ci),

            .call_indirect => |ci| {
                // A no-return runtime intrinsic (`@panic`/`exit`/`abort`) sometimes
                // lowers to an indirect call to a `.local`/`.param` of that name
                // (when sema didn't bind it to a top-level symbol). Trap instead —
                // see `isComptimeTrapCall`.
                const ind_name: ?[]const u8 = switch (ci.callee) {
                    .local => |n| n,
                    .param => |n| n,
                    else => null,
                };
                if (ind_name) |nm| if (isComptimeTrapCall(nm)) {
                    if (std.mem.eql(u8, nm, "@panic")) try self.emitTrapOrHalt(ci.args) else try self.emit(Instr.with_imm(.trap, -1));
                    return;
                };
                const callee = try self.resolveReg(ci.callee);
                const argc: u32 = @intCast(ci.args.len);
                const base = self.next_reg;
                self.next_reg += argc;
                for (ci.args, 0..) |arg, i| {
                    const ar = try self.resolveReg(arg);
                    try self.emit(Instr.r_r_imm(.copy, base + @as(Reg, @intCast(i)), ar, 0));
                }
                try self.emit(.{ .op = .call_indirect, .a = target, .b = callee, .c = base, .imm = argc });
            },

            .builtin => |b| {
                if (std.mem.eql(u8, b.name, "print") and b.args.len >= 1) {
                    const ar = try self.resolveReg(b.args[0]);
                    try self.emit(Instr.r_imm(.sys_print, ar, 0));
                } else if (std.mem.eql(u8, b.name, "panic")) {
                    try self.emitTrapOrHalt(b.args);
                } else if (std.mem.eql(u8, b.name, "compound_literal")) {
                    // Positional `.{ a, b, ... }` aggregate initializer.
                    try self.lowerCompoundLiteral(target, inst.ty, b.args);
                } else if (std.mem.startsWith(u8, b.name, "error.")) {
                    // The error *discriminant* for `fail .v`. Any payload travels
                    // separately through the fallible's value cell (see the `.fail`
                    // terminator and `try_payload`), so a caught `e == .v |p|`
                    // still recovers `p` — this just yields the tag.
                    const vname = b.name["error.".len..];
                    const idx = self.errorVariantIndex(vname) orelse 1; // non-zero = error
                    try self.emit(Instr.r_imm(.load_imm, target, idx));
                } else if (std.mem.eql(u8, b.name, "catch_handler")) {
                    // Marker emitted by `catch` lowering; nothing to execute.
                } else if (std.mem.eql(u8, b.name, "optional_some") and b.args.len >= 1) {
                    // `some(x)`: a 1-cell block holding the payload.
                    const pr = try self.resolveReg(b.args[0]);
                    try self.emit(Instr.r_imm(.zone_alloc, target, 1));
                    try self.emit(Instr.r_r_imm(.store_cell, target, pr, 0));
                } else if (std.mem.eql(u8, b.name, "__str_cat") and b.args.len == 2) {
                    const ar = try self.resolveReg(b.args[0]);
                    const br = try self.resolveReg(b.args[1]);
                    try self.emit(Instr.r_r_r(.str_concat, target, ar, br));
                } else if (std.mem.eql(u8, b.name, "compiler_error") and b.args.len == 1) {
                    // `compiler_error(msg)`: record the diagnostic and halt the hook.
                    const mr = try self.resolveReg(b.args[0]);
                    try self.emit(Instr.r_imm(.halt_msg, mr, 0));
                } else if (std.mem.eql(u8, b.name, "compiler_remove") and b.args.len == 1) {
                    // `compiler_remove(name)`: record the decl to drop (no halt).
                    const nr = try self.resolveReg(b.args[0]);
                    try self.emit(Instr.r_imm(.record_remove, nr, 0));
                } else if (std.mem.eql(u8, b.name, "ptr_from_int") and b.args.len >= 2) {
                    // `ptr_from_int(*T, addr)` → a real host pointer (the VM can now
                    // run byte-addressed std.heap). `size` = the pointee's byte size,
                    // so host loads/stores know their width.
                    const addr = try self.resolveReg(b.args[1]);
                    const size: u32 = switch (inst.ty) {
                        .ptr => |p| @intCast(self.byteSize(p.*) orelse 8),
                        else => 8,
                    };
                    try self.emit(Instr.r_r_imm(.host_ptr_make, target, addr, @intCast(size)));
                } else if (std.mem.eql(u8, b.name, "slice_from_raw_parts") and b.args.len >= 3) {
                    // `slice_from_raw_parts(T, ptr, n)` → a host slice (addr+len+stride).
                    const p = try self.resolveReg(b.args[1]);
                    const n = try self.resolveReg(b.args[2]);
                    const stride: u32 = switch (inst.ty) {
                        .slice => |e| @intCast(self.byteSize(e.*) orelse 1),
                        else => 1,
                    };
                    try self.emit(Instr{ .op = .host_buf_make, .a = target, .b = p, .c = n, .imm = @intCast(stride) });
                } else if (std.mem.eql(u8, b.name, "sizeof")) {
                    // `sizeof(T)` folds to a compile-time byte size (a `usize`).
                    const ta = b.type_arg orelse return error.Unsupported;
                    const size = self.byteSize(ta) orelse return error.Unsupported;
                    try self.materializeImm(target, .{ .uint = size });
                } else if (std.mem.eql(u8, b.name, "type_info")) {
                    // The TypeInfo value itself is only consumed via field access
                    // (folded in `.field`); leave a harmless placeholder here.
                    try self.emit(Instr.r_imm(.load_imm, target, 0));
                } else if (std.mem.eql(u8, b.name, "type_name")) {
                    // `type_name(T)` folds to the mangled type-name string.
                    const ta = b.type_arg orelse return error.Unsupported;
                    try self.loadConst(target, .{ .string = typeNameMangle(ta) });
                } else if (buildOpFor(b.name)) |op| {
                    // std.build `__build_*` intrinsic → a side-effecting host_call
                    // that the build driver records into a BuildPlan. Args go in a
                    // contiguous register window, like a normal call.
                    const argc: u32 = @intCast(b.args.len);
                    const base = self.next_reg;
                    self.next_reg += argc;
                    for (b.args, 0..) |arg, i| {
                        const ar = try self.resolveReg(arg);
                        try self.emit(Instr.r_r_imm(.copy, base + @as(Reg, @intCast(i)), ar, 0));
                    }
                    try self.emit(.{ .op = .host_call, .a = target, .b = base, .c = argc, .imm = @intCast(@intFromEnum(op)) });
                } else if (scalarOpId(b.name)) |op| {
                    // `core::` math / count_ones fold (the comptime VM computes them).
                    if (b.args.len < 1) return error.Unsupported;
                    const a0 = try self.resolveReg(b.args[0]);
                    const a1: Reg = if (b.args.len >= 2) try self.resolveReg(b.args[1]) else 0;
                    try self.emit(.{ .op = .scalar_builtin, .a = target, .b = a0, .c = a1, .imm = op });
                } else if (std.mem.eql(u8, b.name, "clamp") and b.args.len >= 3) {
                    // clamp(x, lo, hi) = max(min(x, hi), lo) — two scalar folds.
                    const x = try self.resolveReg(b.args[0]);
                    const lo = try self.resolveReg(b.args[1]);
                    const hi = try self.resolveReg(b.args[2]);
                    const tmp = self.newReg();
                    try self.emit(.{ .op = .scalar_builtin, .a = tmp, .b = x, .c = hi, .imm = @intFromEnum(instructions.ScalarOp.min) });
                    try self.emit(.{ .op = .scalar_builtin, .a = target, .b = tmp, .c = lo, .imm = @intFromEnum(instructions.ScalarOp.max) });
                } else return error.Unsupported;
            },

            // Aggregates (Tier C: structs)
            .struct_lit => |sl| try self.lowerStructLit(target, sl),

            .field => |f| {
                // TARGET pseudo-module: TARGET.os / TARGET.arch / TARGET.debug,
                // resolved to host constants at compile time.
                if (targetFieldImm(f.base, f.name)) |imm| {
                    try self.materializeImm(target, imm);
                    return;
                }
                // `type_info(T)...` reflection chains fold step by step.
                if (f.base == .reg) {
                    if (self.type_info_nodes.get(f.base.reg)) |node| {
                        const res = self.foldTypeInfoField(node, f.name) orelse return error.Unsupported;
                        switch (res) {
                            .scalar => |imm| try self.materializeImm(target, imm),
                            .node => |n| {
                                try self.type_info_nodes.put(target, n);
                                try self.emit(Instr.r_imm(.load_imm, target, 0)); // placeholder
                            },
                        }
                        return;
                    }
                }
                const base_ty = self.typeOf(f.base);
                // `.len` on arrays (static) and slices (runtime) is the builtin
                // length — but on a struct it is an ordinary field (handled below).
                if (std.mem.eql(u8, f.name, "len")) {
                    switch (base_ty) {
                        .array => |arr| {
                            try self.emit(Instr.r_imm(.load_imm, target, @intCast(arr.len)));
                            return;
                        },
                        // Slices carry their length in a cell; a `.text` string is
                        // a `Value.string` that carries its own. `slice_len`
                        // handles both value shapes in the engine.
                        .slice, .text => {
                            const base = try self.resolveReg(f.base);
                            try self.emit(Instr.r_r_imm(.slice_len, target, base, 0));
                            return;
                        },
                        else => {},
                    }
                }
                // `slice.ptr` — the base pointer (a host pointer for a host buffer
                // or a string constant, a cell pointer otherwise). Like `.len`, not
                // an ordinary field. `.text` belongs here for the same reason it
                // belongs on `.len` above: without it `s.ptr` on a string fell
                // through to `load_cell` and trapped, which is what kept every
                // `#extern` taking a string pointer from running at comptime.
                if (std.mem.eql(u8, f.name, "ptr") and (base_ty == .slice or base_ty == .text)) {
                    const base = try self.resolveReg(f.base);
                    try self.emit(Instr.r_r_imm(.slice_ptr, target, base, 0));
                    return;
                }
                const base = try self.resolveReg(f.base);
                const idx = try self.fieldOffset(base_ty, f.name);
                try self.emit(Instr.r_r_imm(.load_cell, target, base, idx));
            },
            .field_addr => |f| {
                const base = try self.resolveReg(f.base);
                const idx = try self.fieldOffset(self.typeOf(f.base), f.name);
                try self.emit(Instr.r_r_imm(.field_addr, target, base, idx));
            },

            // Arrays & slices
            .index => |ix| {
                // `type_info(T).fields[i]` advances into a field descriptor.
                if (ix.base == .reg) {
                    if (self.type_info_nodes.get(ix.base.reg)) |node| {
                        const idx = constIndexOf(ix.index) orelse return error.Unsupported;
                        const n = foldTypeInfoIndex(node, idx) orelse return error.Unsupported;
                        try self.type_info_nodes.put(target, n);
                        try self.emit(Instr.r_imm(.load_imm, target, 0)); // placeholder
                        return;
                    }
                }
                // Combined index+load: handles host strings (`[]const u8`) as
                // well as zone-backed slices/arrays (a string has no zone addr,
                // so the separate index_addr→load_cell pair can't serve it).
                const base = try self.resolveReg(ix.base);
                const idxr = try self.resolveReg(ix.index);
                try self.emit(.{ .op = .index_load, .a = target, .b = base, .c = idxr, .imm = @intCast(self.cellCount(inst.ty)) });
            },
            .index_addr => |ix| {
                const elem_ty: ir.IrType = switch (inst.ty) {
                    .ptr => |e| e.*,
                    else => inst.ty,
                };
                const addr = try self.lowerIndexAddr(ix.base, ix.index, self.cellCount(elem_ty));
                try self.emit(Instr.r_r_imm(.copy, target, addr, 0));
            },
            .slice_expr => |se| {
                const ptr = try self.resolveReg(se.ptr);
                const len = try self.resolveReg(se.len);
                try self.emit(Instr.r_r_r(.slice_make, target, ptr, len));
            },
            .store => |s| {
                const ptr = try self.resolveReg(s.target);
                const vr = try self.resolveReg(s.value);
                try self.emit(Instr.r_r_imm(.store_cell, ptr, vr, 0));
            },
            .at => |a| {
                const ptr = try self.resolveReg(a.value);
                try self.emit(Instr.r_r_imm(.load_cell, target, ptr, 0));
            },

            // Variants / enums
            // A variant value is a 2-cell block: [tag, payload].
            .variant_lit => |vl| {
                const idx = self.variantIndex(vl.type_name, vl.variant) orelse return error.Unsupported;
                try self.emit(Instr.r_imm(.zone_alloc, target, 2));
                const tagr = self.newReg();
                try self.emit(Instr.r_imm(.load_imm, tagr, idx));
                try self.emit(Instr.r_r_imm(.store_cell, target, tagr, 0));
                if (vl.payload) |p| {
                    const pr = try self.resolveReg(p);
                    try self.emit(Instr.r_r_imm(.store_cell, target, pr, 1));
                }
            },
            .variant_is => |vi| {
                const idx = self.variantIndex(vi.type_name, vi.variant) orelse return error.Unsupported;
                const subj = try self.resolveReg(vi.value);
                const tagr = self.newReg();
                try self.emit(Instr.r_r_imm(.load_cell, tagr, subj, 0));
                const idxr = self.newReg();
                try self.emit(Instr.r_imm(.load_imm, idxr, idx));
                try self.emit(Instr.r_r_r(.eq_i, target, tagr, idxr));
            },
            .variant_payload => |vp| {
                const subj = try self.resolveReg(vp.value);
                try self.emit(Instr.r_r_imm(.load_cell, target, subj, 1));
            },

            // Optionals
            // `some(x)` is a 1-cell block [x]; `none` is the bare null value.
            .optional_is_some => |v| {
                const r = try self.resolveReg(v);
                try self.emit(Instr.r_r_imm(.opt_is_some, target, r, 0));
            },
            .optional_payload => |v| {
                const r = try self.resolveReg(v);
                try self.emit(Instr.r_r_imm(.load_cell, target, r, 0));
            },

            // Fallible (T ! E)
            // A fallible value matches the LLVM layout: a 2-cell block
            // [value(0), discriminant(1)] where disc 0 means ok. The error
            // payload shares the value slot (field 0), like the LLVM backend.
            .try_is_ok => |v| {
                const r = try self.resolveReg(v);
                const disc = self.newReg();
                try self.emit(Instr.r_r_imm(.load_cell, disc, r, 1));
                const zero = try self.constReg(0);
                try self.emit(Instr.r_r_r(.eq_i, target, disc, zero));
            },
            .try_err => |v| {
                const r = try self.resolveReg(v);
                try self.emit(Instr.r_r_imm(.load_cell, target, r, 1)); // discriminant
            },
            .try_ok, .try_payload => |v| {
                const r = try self.resolveReg(v);
                try self.emit(Instr.r_r_imm(.load_cell, target, r, 0)); // value / payload
            },

            // Interfaces
            // A fat interface value is a 2-cell block: [data ptr, vtable index].
            .interface_make => |im| {
                const data = try self.resolveReg(im.data);
                const vt = self.vtableIndex(im.vtable) orelse return error.Unsupported;
                try self.emit(Instr.r_imm(.zone_alloc, target, 2));
                try self.emit(Instr.r_r_imm(.store_cell, target, data, 0));
                const vr = self.newReg();
                try self.emit(Instr.r_imm(.load_imm, vr, vt));
                try self.emit(Instr.r_r_imm(.store_cell, target, vr, 1));
            },
            .interface_data => |v| {
                const r = try self.resolveReg(v);
                try self.emit(Instr.r_r_imm(.load_cell, target, r, 0));
            },
            .interface_method => |im| {
                const r = try self.resolveReg(im.value);
                try self.emit(.{ .op = .interface_method, .a = target, .b = r, .imm = @intCast(im.index) });
            },

            .closure_make => |mk| {
                const map = self.func_map orelse return error.Unsupported;
                const fidx = map.get(mk.fn_link) orelse return error.Unsupported;
                const non_capturing = switch (mk.env) {
                    .imm => |im| im == .null,
                    else => false,
                };
                if (non_capturing) {
                    try self.loadConst(target, .{ .closure = .{ .fn_idx = @intCast(fidx), .takes_env = mk.fn_takes_env } });
                } else {
                    const env_reg = try self.resolveReg(mk.env);
                    try self.emit(.{ .op = .closure_make, .a = target, .b = env_reg, .c = if (mk.fn_takes_env) 1 else 0, .imm = @intCast(fidx) });
                }
            },
            .closure_env_make => |mk| {
                // One cell per capture (scalar captures only at comptime).
                try self.emit(Instr.r_imm(.zone_alloc, target, @intCast(mk.fields.len)));
                for (mk.fields, 0..) |f, i| {
                    const vr = try self.resolveReg(f.value);
                    try self.emit(Instr.r_r_imm(.store_cell, target, vr, @intCast(i)));
                }
            },
            .closure_env_load => |ld| {
                const env = try self.resolveReg(ld.env);
                try self.emit(Instr.r_r_imm(.load_cell, target, env, @intCast(ld.index)));
            },

            .alloc => |a| {
                const cells = self.cellCount(a.ty);
                try self.emit(Instr.r_imm(.zone_alloc, target, @intCast(cells)));
            },

            .zone_push => |zp| {
                const idx = try self.addConst(.{ .string = zp.name });
                try self.emit(Instr.with_imm(.zone_push, idx));
            },
            .zone_pop => try self.emit(Instr.with_imm(.zone_pop, 0)),
            .zone_free => {}, // freed wholesale on zone_pop; explicit free is a no-op here

            // Tier C+ (arrays/slices/variants/interfaces/globals) and beyond:
            // not lowered yet.
            else => return error.Unsupported,
        }
    }

    fn lowerStructLit(self: *FnCompiler, target: Reg, sl: ir.StructLitInstr) CompileError!void {
        const def = self.structDef(sl.ty_name) orelse return error.Unsupported;
        try self.emit(Instr.r_imm(.zone_alloc, target, @intCast(def.fields.len)));
        for (sl.fields) |field| {
            const idx = fieldIndex(def, field.name) orelse return error.Unsupported;
            const vr = try self.resolveReg(field.value);
            try self.emit(Instr.r_r_imm(.store_cell, target, vr, idx));
        }
    }

    /// Positional aggregate initializer `.{ v0, v1, ... }` for a struct or
    /// array: cells are filled in declaration / element order.
    fn lowerCompoundLiteral(self: *FnCompiler, target: Reg, ty: ir.IrType, args: []const ir.Value) CompileError!void {
        const slots: usize = switch (ty) {
            .array => |arr| @intCast(arr.len),
            else => blk: {
                const sname = structName(ty) orelse return error.Unsupported;
                const def = self.structDef(sname) orelse return error.Unsupported;
                break :blk def.fields.len;
            },
        };
        const stride: usize = switch (ty) {
            .array => |arr| self.cellCount(arr.elem.*),
            else => 1,
        };
        if (args.len > slots) return error.Unsupported;
        try self.emit(Instr.r_imm(.zone_alloc, target, @intCast(slots * stride)));
        for (args, 0..) |arg, i| {
            const vr = try self.resolveReg(arg);
            try self.emit(Instr.r_r_imm(.store_cell, target, vr, @intCast(i * stride)));
        }
    }

    /// Emit an `index_addr`, returning the register holding the element pointer.
    fn lowerIndexAddr(self: *FnCompiler, base_val: ir.Value, index_val: ir.Value, elem_cells: usize) CompileError!Reg {
        const base = try self.resolveReg(base_val);
        const idxr = try self.resolveReg(index_val);
        const dst = self.newReg();
        try self.emit(.{ .op = .index_addr, .a = dst, .b = base, .c = idxr, .imm = @intCast(elem_cells) });
        return dst;
    }

    /// A runtime "never returns" intrinsic (`@panic`/`exit`/`abort`). At comptime
    /// these can't run as real calls (no runtime to call into), but a function
    /// that merely *contains* one — e.g. `std.heap.alloc_bytes`, which `@panic`s
    /// only on a NULL out-of-memory branch that a valid alloc never hits — must
    /// still fold. Lower the call to a `trap`: harmless dead weight unless the
    /// branch is actually taken (in which case the comptime eval correctly halts).
    fn isComptimeTrapCall(name: []const u8) bool {
        return std.mem.eql(u8, name, "@panic") or
            std.mem.eql(u8, name, "exit") or
            std.mem.eql(u8, name, "abort");
    }

    /// A comptime `@panic("literal")` records its message via `halt_msg` (the same
    /// path `compiler_error` uses), so the `#run`/hook error surfaces it instead
    /// of a bare trap. `exit`/`abort`, or a non-constant/absent message, keep the
    /// plain `trap` — a never-taken panic still folds to harmless dead weight.
    fn emitTrapOrHalt(self: *FnCompiler, args: []const ir.Value) CompileError!void {
        if (args.len >= 1) switch (args[0]) {
            .imm => |imm| if (imm == .text) {
                const mr = try self.resolveReg(args[0]);
                try self.emit(Instr.r_imm(.halt_msg, mr, 0));
                return;
            },
            else => {},
        };
        try self.emit(Instr.with_imm(.trap, -1));
    }

    fn lowerCall(self: *FnCompiler, target: Reg, ci: ir.CallInstr) CompileError!void {
        if (isComptimeTrapCall(ci.callee)) {
            if (std.mem.eql(u8, ci.callee, "@panic")) try self.emitTrapOrHalt(ci.args) else try self.emit(Instr.with_imm(.trap, -1));
            return;
        }
        const map = self.func_map orelse return error.Unsupported;
        const fidx = map.get(ci.callee) orelse return error.Unsupported;

        // Reserve a contiguous argument window, then fill it.
        const argc: u32 = @intCast(ci.args.len);
        const base = self.next_reg;
        self.next_reg += argc;
        for (ci.args, 0..) |arg, i| {
            const ar = try self.resolveReg(arg);
            try self.emit(Instr.r_r_imm(.copy, base + @as(Reg, @intCast(i)), ar, 0));
        }
        try self.emit(.{ .op = .call, .a = target, .b = base, .c = argc, .imm = @intCast(fidx) });
    }

    fn lowerTerminator(self: *FnCompiler, term: ir.Terminator) CompileError!void {
        const fallible = self.func.error_ty != null;
        switch (term) {
            .return_value => |opt| {
                if (fallible) {
                    // ok: [value, disc=0].
                    const vr = if (opt) |v| try self.resolveReg(v) else try self.constReg(0);
                    const wrapped = try self.emitFallible(vr, try self.constReg(0));
                    try self.emit(Instr.r_imm(.ret, wrapped, 0));
                } else if (opt) |v| {
                    const r = try self.resolveReg(v);
                    try self.emit(Instr.r_imm(.ret, r, 0));
                } else try self.emit(Instr.with_imm(.ret_void, 0));
            },
            .fail => |ft| {
                // err: [payload, disc]; the payload shares the value slot.
                const disc = try self.resolveReg(ft.disc);
                const payload = if (ft.payload) |p| try self.resolveReg(p) else try self.constReg(0);
                const wrapped = try self.emitFallible(payload, disc);
                try self.emit(Instr.r_imm(.ret, wrapped, 0));
            },
            .branch => |bid| try self.emit(Instr.with_imm(.jmp, @intCast(bid))),
            .cond_branch => |cb| {
                const cr = try self.resolveReg(cb.cond);
                try self.emit(Instr.r_imm(.br_if, cr, @intCast(cb.then_block)));
                try self.emit(Instr.with_imm(.jmp, @intCast(cb.else_block)));
            },
            .panic => try self.emit(Instr.with_imm(.trap, -1)),
            .unreachable_term => try self.emit(Instr.with_imm(.trap, -1)),
        }
    }

    fn constReg(self: *FnCompiler, imm: i64) CompileError!Reg {
        const r = self.newReg();
        try self.emit(Instr.r_imm(.load_imm, r, imm));
        return r;
    }

    /// Build a fallible result block `[value(0), discriminant(1)]` (disc 0 = ok),
    /// matching the LLVM fallible layout, and return its register.
    fn emitFallible(self: *FnCompiler, value_reg: Reg, disc_reg: Reg) CompileError!Reg {
        const blk = self.newReg();
        try self.emit(Instr.r_imm(.zone_alloc, blk, 2));
        try self.emit(Instr.r_r_imm(.store_cell, blk, value_reg, 0));
        try self.emit(Instr.r_r_imm(.store_cell, blk, disc_reg, 1));
        return blk;
    }

    fn emit(self: *FnCompiler, instr: Instr) CompileError!void {
        try self.out.append(self.allocator, instr);
    }

    /// Rewrite jump targets from IR block ids to instruction offsets.
    fn patchJumps(self: *FnCompiler) CompileError!void {
        for (self.out.items) |*instr| {
            switch (instr.op) {
                .jmp, .br_if, .br_if_not => {
                    const bid: ir.BlockId = @intCast(instr.imm);
                    const off = self.block_offsets.get(bid) orelse return error.Unsupported;
                    instr.imm = @intCast(off);
                },
                else => {},
            }
        }
    }

    // Struct layout helpers

    fn structDef(self: *FnCompiler, name: []const u8) ?ir.StructDef {
        for (self.module.structs) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    /// Discriminant of an error variant by name, across all error sets. 1-based
    /// (matching the LLVM backend) so discriminant 0 is reserved for "ok".
    fn errorVariantIndex(self: *FnCompiler, variant: []const u8) ?i64 {
        for (self.module.errors) |e| {
            for (e.variants, 0..) |case, i| {
                if (std.mem.eql(u8, case.name, variant)) return @intCast(i + 1);
            }
        }
        return null;
    }

    /// Index of the vtable named `name` within the module's vtable table.
    fn vtableIndex(self: *FnCompiler, name: []const u8) ?u32 {
        for (self.module.vtables, 0..) |vt, i| {
            if (std.mem.eql(u8, vt.name, name)) return @intCast(i);
        }
        return null;
    }

    /// Discriminant (position) of `variant` within enum `type_name`.
    fn variantIndex(self: *FnCompiler, type_name: []const u8, variant: []const u8) ?u32 {
        for (self.module.variants) |v| {
            if (!std.mem.eql(u8, v.name, type_name)) continue;
            for (v.variants, 0..) |case, i| {
                if (std.mem.eql(u8, case.name, variant)) return @intCast(i);
            }
        }
        return null;
    }

    /// Cell offset of `field_name` within the struct named by `base_ty`.
    fn fieldOffset(self: *FnCompiler, base_ty: ir.IrType, field_name: []const u8) CompileError!i64 {
        const sname = structName(base_ty) orelse return error.Unsupported;
        const def = self.structDef(sname) orelse return error.Unsupported;
        return fieldIndex(def, field_name) orelse error.Unsupported;
    }

    /// Fold a scalar field of `type_info(ty)`. Conservative: only fields whose
    /// value provably matches the tree-walker's `typeInfo` (so the differential
    /// harness stays at disagree=0). `.size` reuses `byteSize` (== `typeSize`);
    /// `.name`/`.kind` only for named aggregates, where they are unambiguous.
    /// `type_info(T).kind` — disambiguates named types via the module tables,
    /// since `lowerNamedType` tags every named type as `.struct_type`.
    fn typeInfoKind(self: *FnCompiler, ty: ir.IrType) ?[]const u8 {
        return switch (ty) {
            .i, .u, .byte, .usize, .isize => "int",
            .f32, .f64 => "float",
            .bool => "bool",
            .void => "void",
            .ptr => "pointer",
            .slice => "slice",
            .optional => "optional",
            .array => "array",
            .struct_type, .variant_type => |n| blk: {
                if (self.structDef(n) != null) break :blk "struct";
                for (self.module.variants) |v| {
                    if (std.mem.eql(u8, v.name, n)) break :blk "enum";
                }
                break :blk null;
            },
            else => null,
        };
    }

    /// Fold one field access within a `type_info(...)` chain. Returns a scalar
    /// (the chain ends) or another node (it continues), or null to fall back.
    fn foldTypeInfoField(self: *FnCompiler, node: TypeInfoNode, field: []const u8) ?FoldResult {
        const eq = std.mem.eql;
        switch (node) {
            .type => |t| {
                if (eq(u8, field, "size")) return .{ .scalar = .{ .uint = self.byteSize(t) orelse return null } };
                if (eq(u8, field, "name")) return .{ .scalar = .{ .text = typeInfoName(t) } };
                if (eq(u8, field, "kind")) return .{ .scalar = .{ .text = self.typeInfoKind(t) orelse return null } };
                if (eq(u8, field, "bits")) return .{ .scalar = .{ .uint = typeInfoBits(t) orelse return null } };
                if (eq(u8, field, "signed")) return .{ .scalar = .{ .bool = typeInfoSigned(t) orelse return null } };
                if (eq(u8, field, "is_const")) return if (t == .ptr) .{ .scalar = .{ .bool = false } } else null;
                if (eq(u8, field, "len")) return switch (t) {
                    .array => |arr| .{ .scalar = .{ .uint = arr.len } },
                    else => null,
                };
                if (eq(u8, field, "elem") or eq(u8, field, "elem_info"))
                    return .{ .node = .{ .type = innerType(t) orelse return null } };
                if (eq(u8, field, "fields")) {
                    const n = switch (t) {
                        .struct_type, .variant_type => |nm| nm,
                        else => return null,
                    };
                    if (self.structDef(n) == null) return null; // only real structs have .fields
                    return .{ .node = .{ .fields_of = t } };
                }
                return null;
            },
            .fields_of => |t| {
                if (eq(u8, field, "len")) {
                    const def = self.structDef(structName(t) orelse return null) orelse return null;
                    return .{ .scalar = .{ .uint = def.fields.len } };
                }
                return null;
            },
            .field_at => |fa| {
                const def = self.structDef(structName(fa.ty) orelse return null) orelse return null;
                if (fa.index >= def.fields.len) return null;
                if (eq(u8, field, "name")) return .{ .scalar = .{ .text = def.fields[fa.index].name } };
                if (eq(u8, field, "offset")) return .{ .scalar = .{ .uint = 0 } };
                return null; // `.type` is a type_val — can't cross to a scalar
            },
        }
    }

    /// Byte size of `ty` for `sizeof`, mirroring the tree-walker's `typeSize`
    /// exactly. Returns null for types whose size this compiler can't yet
    /// compute (enums, interfaces, …), so the caller falls back.
    fn byteSize(self: *FnCompiler, ty: ir.IrType) ?u64 {
        return switch (ty) {
            .void => 0,
            .bool, .byte => 1,
            .i => |bits| (bits + 7) / 8,
            .u => |bits| (bits + 7) / 8,
            .f32 => 4,
            .f64 => 8,
            .usize, .isize, .addr => 8,
            .ptr => 8,
            .slice => 16, // ptr + len
            .optional => |inner| if (inner.* == .ptr) 8 else blk: {
                const s = self.byteSize(inner.*) orelse return null;
                break :blk 1 + s;
            },
            .array => |arr| blk: {
                const es = self.byteSize(arr.elem.*) orelse return null;
                break :blk arr.len * es;
            },
            .struct_type => |name| blk: {
                const def = self.structDef(name) orelse return null;
                var total: u64 = 0;
                for (def.fields) |f| total += self.byteSize(f.ty) orelse return null;
                break :blk total;
            },
            else => null,
        };
    }

    /// Number of cells a value of `ty` occupies in zone memory.
    fn cellCount(self: *FnCompiler, ty: ir.IrType) usize {
        return switch (ty) {
            .array => |arr| @as(usize, @intCast(arr.len)) * self.cellCount(arr.elem.*),
            else => blk: {
                if (structName(ty)) |sname| {
                    if (self.structDef(sname)) |def| break :blk def.fields.len;
                }
                break :blk 1;
            },
        };
    }
};

fn isFloat(ty: ir.IrType) bool {
    return ty == .f32 or ty == .f64;
}

/// A position within a `type_info(T)` reflection tree. Reflection is fully
/// compile-time constant, so rather than building runtime `TypeInfo` structs we
/// track which node each register denotes and fold field/index access directly.
const TypeInfoNode = union(enum) {
    /// `type_info(T)` — the TypeInfo of `T`.
    type: ir.IrType,
    /// `type_info(StructT).fields` — the array of field descriptors.
    fields_of: ir.IrType,
    /// `type_info(StructT).fields[i]` — one field descriptor.
    field_at: struct { ty: ir.IrType, index: usize },
};

const FoldResult = union(enum) {
    scalar: ir.Imm,
    node: TypeInfoNode,
};

/// Advance into `type_info(StructT).fields[index]`.
fn foldTypeInfoIndex(node: TypeInfoNode, index: usize) ?TypeInfoNode {
    return switch (node) {
        .fields_of => |t| .{ .field_at = .{ .ty = t, .index = index } },
        else => null,
    };
}

/// Compile-time-constant index value, or null for a dynamic index.
fn constIndexOf(v: ir.Value) ?usize {
    return switch (v) {
        .imm => |imm| switch (imm) {
            .int => |x| if (x >= 0) @intCast(x) else null,
            .uint => |x| @intCast(x),
            else => null,
        },
        else => null,
    };
}

/// Element/pointee type for pointer/slice/optional/array.
fn innerType(ty: ir.IrType) ?ir.IrType {
    return switch (ty) {
        .ptr => |p| p.*,
        .slice => |s| s.*,
        .optional => |o| o.*,
        .array => |arr| arr.elem.*,
        else => null,
    };
}

/// Bit width for `type_info(T).bits`.
fn typeInfoBits(ty: ir.IrType) ?u64 {
    return switch (ty) {
        .i => |b| b,
        .u => |b| b,
        .byte => 8,
        .usize, .isize => 64,
        .f32 => 32,
        .f64 => 64,
        else => null,
    };
}

/// Signedness for `type_info(T).signed`.
fn typeInfoSigned(ty: ir.IrType) ?bool {
    return switch (ty) {
        .i, .isize => true,
        .u, .byte, .usize => false,
        else => null,
    };
}

/// `type_info(T).name` — the reflective type name (NOT the mangled `tyMangle`).
fn typeInfoName(ty: ir.IrType) []const u8 {
    return switch (ty) {
        .i => |b| switch (b) {
            8 => "i8",
            16 => "i16",
            32 => "i32",
            64 => "i64",
            else => "int",
        },
        .u => |b| switch (b) {
            8 => "u8",
            16 => "u16",
            32 => "u32",
            64 => "u64",
            else => "uint",
        },
        .byte => "byte",
        .usize => "usize",
        .isize => "isize",
        .f32 => "f32",
        .f64 => "f64",
        .bool => "bool",
        .void => "void",
        .ptr => "pointer",
        .slice => "slice",
        .optional => "optional",
        .array => "array",
        .struct_type, .variant_type => |n| n,
        else => "unknown",
    };
}

/// Mangled type name for `type_name(T)`, replicating `sema.tyMangle` so the
/// result matches what the (now-retired) tree-walker produced. Note the quirks
/// it inherits: all named types mangle to "named", and types tyMangle doesn't
/// enumerate (floats, byte, …) mangle to "unknown".
/// Map a `std.build` intrinsic name to its host operation, or null if it isn't
/// one. Drives the `host_call` lowering in the `.builtin` case.
/// The `ScalarOp` id for a `core::` math/bit builtin the comptime VM folds, or
/// null (width-dependent bit ops + `fma` fall back to runtime at comptime).
fn scalarOpId(name: []const u8) ?i32 {
    const eq = std.mem.eql;
    const ops = .{
        .{ "count_ones", instructions.ScalarOp.count_ones }, .{ "abs", instructions.ScalarOp.abs },
        .{ "sqrt", instructions.ScalarOp.sqrt },   .{ "floor", instructions.ScalarOp.floor },
        .{ "ceil", instructions.ScalarOp.ceil },   .{ "round", instructions.ScalarOp.round },
        .{ "trunc", instructions.ScalarOp.trunc }, .{ "sin", instructions.ScalarOp.sin },
        .{ "cos", instructions.ScalarOp.cos },     .{ "min", instructions.ScalarOp.min },
        .{ "max", instructions.ScalarOp.max },     .{ "pow", instructions.ScalarOp.pow },
    };
    inline for (ops) |o| if (eq(u8, name, o[0])) return @intFromEnum(o[1]);
    return null;
}

fn buildOpFor(name: []const u8) ?instructions.BuildOp {
    const table = .{
        .{ "__build_artifact", instructions.BuildOp.artifact },
        .{ "__build_opt", instructions.BuildOp.opt },
        .{ "__build_link", instructions.BuildOp.link },
        .{ "__build_libpath", instructions.BuildOp.lib_path },
        .{ "__build_output", instructions.BuildOp.output },
        .{ "__build_define", instructions.BuildOp.define },
        .{ "__build_default", instructions.BuildOp.set_default },
        .{ "__build_run", instructions.BuildOp.run_step },
        .{ "__build_test", instructions.BuildOp.test_dir },
        .{ "__build_require", instructions.BuildOp.require },
        .{ "__build_depend", instructions.BuildOp.depend },
        .{ "__build_subsystem", instructions.BuildOp.subsystem },
        .{ "__build_entry", instructions.BuildOp.entry },
        .{ "__build_stack", instructions.BuildOp.stack },
        .{ "__build_linkflag", instructions.BuildOp.link_flag },
        .{ "__build_outdir", instructions.BuildOp.out_dir },
        .{ "__build_version", instructions.BuildOp.version },
        .{ "__build_desc", instructions.BuildOp.description },
        .{ "__build_workspace", instructions.BuildOp.workspace },
        .{ "__build_outroot", instructions.BuildOp.out_root },
        .{ "__build_install", instructions.BuildOp.install },
        .{ "__build_optionflag", instructions.BuildOp.option_flag },
        .{ "__build_optionstr", instructions.BuildOp.option_str },
        .{ "__build_summary", instructions.BuildOp.summary },
        .{ "__build_linkmode", instructions.BuildOp.link_mode },
        .{ "__build_runtimefile", instructions.BuildOp.runtime_file },
        .{ "__build_nodefaultlibs", instructions.BuildOp.no_default_libs },
        .{ "__build_linklibc", instructions.BuildOp.link_libc },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

pub fn typeNameMangle(ty: ir.IrType) []const u8 {
    return switch (ty) {
        .i => |bits| switch (bits) {
            8 => "i8",
            16 => "i16",
            32 => "i32",
            64 => "i64",
            else => "unknown",
        },
        .u => |bits| switch (bits) {
            8 => "u8",
            16 => "u16",
            32 => "u32",
            64 => "u64",
            else => "unknown",
        },
        .f32 => "f32",
        .f64 => "f64",
        .bool => "bool",
        .byte => "byte",
        .void => "void",
        .usize => "usize",
        .isize => "isize",
        .addr => "addr",
        .rune => "rune",
        .text => "str",
        .ptr => "ptr",
        .optional => "opt",
        .slice => "slice",
        // Named aggregates carry their own name.
        .struct_type, .variant_type, .opaque_type, .interface_value => |n| n,
        else => "unknown",
    };
}

/// Value of a `TARGET.<field>` access, resolved against the host build.
/// Only `debug` (a bool) folds end-to-end today; `TARGET.os`/`.arch`
/// *comparisons* are blocked by how the bare `.windows`/`.x86_64` operand
/// lowers, and aren't a parity gap (the tree-walker can't fold them either).
fn targetFieldImm(base: ir.Value, field: []const u8) ?ir.Imm {
    const name = switch (base) {
        .local, .global => |n| n,
        else => return null,
    };
    if (!std.mem.eql(u8, name, "TARGET")) return null;
    if (std.mem.eql(u8, field, "debug")) return .{ .bool = builtin.mode == .Debug };
    return null;
}

fn isAggregate(ty: ir.IrType) bool {
    return switch (ty) {
        // Arrays, slices, and variants are all zone-allocated cell blocks, so a
        // value of these types already holds a pointer to its block.
        .array, .slice, .variant_type => true,
        else => structName(ty) != null,
    };
}

/// Unwrap pointers/optionals to find the underlying struct type name, if any.
fn structName(ty: ir.IrType) ?[]const u8 {
    return switch (ty) {
        .struct_type => |n| n,
        .ptr, .optional => |inner| structName(inner.*),
        else => null,
    };
}

fn fieldIndex(def: ir.StructDef, name: []const u8) ?i64 {
    for (def.fields, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return @intCast(i);
    }
    return null;
}

fn mapBinOp(op: ir.BinOp, f: bool) CompileError!Opcode {
    return switch (op) {
        .add => if (f) .add_f else .add_i,
        .sub => if (f) .sub_f else .sub_i,
        .mul => if (f) .mul_f else .mul_i,
        .div => if (f) .div_f else .div_i,
        .rem => .rem_i,
        // Comptime arithmetic is wrapping already (the engine's `*_i` ops use
        // `+%`/`-%`/`*%`), so the wrapping operators reuse them.
        .wrap_add => .add_i,
        .wrap_sub => .sub_i,
        .wrap_mul => .mul_i,
        .shl => .shl,
        .shr => .shr,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .and_op => .bit_and, // booleans are 0/1
        .or_op => .bit_or,
        .eq => if (f) .eq_f else .eq_i,
        .ne => if (f) .ne_f else .ne_i,
        .lt => if (f) .lt_f else .lt_i,
        .le => if (f) .le_f else .le_i,
        .gt => if (f) .gt_f else .gt_i,
        .ge => if (f) .ge_f else .ge_i,
        .range, .range_exclusive => error.Unsupported,
    };
}
