const std = @import("std");
const instructions = @import("instructions.zig");
const value = @import("value.zig");
const zones = @import("zones.zig");
const ffi = @import("ffi.zig");

const Instr = instructions.Instr;
const Opcode = instructions.Opcode;
const BytecodeFunction = instructions.BytecodeFunction;
const BytecodeModule = instructions.BytecodeModule;
const Value = value.Value;

pub const VmError = error{
    DivisionByZero,
    InvalidInstruction,
    StackOverflow,
    StepLimitExceeded,
    OutOfBounds,
    TypeMismatch,
    Unsupported,
    NoModule,
    Trap,
    OutOfMemory,
    NoActiveZone,
    ZoneUnderflow,
};

/// One activation record. Registers are SSA-style temporaries (one per IR
/// result + scratch); locals are the named, mutable parameter/local slots.
const Frame = struct {
    func: *const BytecodeFunction,
    regs: []Value,
    locals: []Value,
    /// Zone-stack depth on entry; the frame unwinds back to this on return.
    zone_watermark: usize,
};

/// The Gabbro compile-time virtual machine.
/// A side-effecting bridge to the embedding host, invoked by the `host_call`
/// opcode. The build driver installs one so `std.build`'s `__build_*` intrinsics
/// record into a BuildPlan. `op` is a `BuildOp`; `args` are the call arguments
/// (strings/ints); the return is bound to the call's dst register.
pub const BuildHost = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, op: u32, args: []const Value) Value,
};

/// What a comptime run is allowed to do. A bare `#run` gets none of these — it is
/// pure — and the build driver grants `ffi` to `build.gab`. Capabilities only narrow
/// as the call stack descends; they can't be forged or widened. This is the
/// structural fix for the `build.rs` surface: a dependency's compile-time code
/// can't reach the host unless it was handed the capability to.
pub const Caps = struct {
    /// May call arbitrary host (DLL / C) functions while compiling.
    ffi: bool = false,
};

pub const Vm = struct {
    allocator: std.mem.Allocator,
    /// Function table for resolving `call`. Optional: a standalone function with
    /// no calls can run without one.
    module: ?*const BytecodeModule = null,
    zone_stack: zones.ZoneStack,
    /// Optional host bridge for `host_call` (the build driver). Null → trap.
    host: ?BuildHost = null,
    /// What this run may do. Default: nothing privileged (a pure `#run`). The build
    /// driver sets `caps.ffi = true` for `build.gab`. See `Caps`.
    caps: Caps = .{},
    call_depth: usize = 0,
    max_call_depth: usize = 512,
    /// Guard against runaway comptime loops (mirrors the tree-walker's cap).
    steps: u64 = 0,
    step_limit: u64 = 100_000_000,
    /// Strings built by `str_concat` (the comptime string builder); owned here and
    /// freed on `deinit` (callers dupe the final result out before then).
    concat_strings: std.ArrayList([]u8) = .empty,
    /// Set by `record_remove` (a `#compiler` hook calling `compiler_remove("...")`):
    /// names of top-level declarations the hook asked to drop. Owned here; the
    /// driver copies them out before `deinit`.
    compiler_removals: std.ArrayList([]u8) = .empty,
    /// Set by `halt_msg` (a `#compiler` hook calling `compiler_error("...")`): the
    /// diagnostic to report when the run halts. Points into `concat_strings` or a
    /// module constant, so it lives as long as the VM.
    compiler_error_msg: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Vm {
        return .{ .allocator = allocator, .zone_stack = zones.ZoneStack.init(allocator) };
    }

    pub fn initModule(allocator: std.mem.Allocator, module: *const BytecodeModule) Vm {
        return .{
            .allocator = allocator,
            .module = module,
            .zone_stack = zones.ZoneStack.init(allocator),
        };
    }

    /// FFI to these benign memory primitives is always allowed: the comptime heap
    /// (`std.heap`) reserves and frees pages through them, so gating them would
    /// break allocation inside a pure `#run`. They do nothing beyond memory.
    fn ffiAlwaysAllowed(ec: ffi.ExternCall) bool {
        return std.mem.eql(u8, ec.symbol, "VirtualAlloc") or
            std.mem.eql(u8, ec.symbol, "VirtualFree");
    }

    /// Call a host function, gated by the `ffi` capability. A pure `#run` may only
    /// reach the benign memory primitives above; anything else halts the build with
    /// a diagnostic. `build.gab` runs with `ffi` granted, so it reaches everything.
    fn callExtern(self: *Vm, ec: ffi.ExternCall, args: []const Value) error{Trap}!Value {
        if (!self.caps.ffi and !ffiAlwaysAllowed(ec)) {
            self.compiler_error_msg = std.fmt.allocPrint(
                self.allocator,
                "comptime FFI to `{s}` (in `{s}`) is not allowed here: this ran as a pure `#run`, which has no `ffi` capability. Only `build.gab` is granted FFI.",
                .{ ec.symbol, ec.lib },
            ) catch "comptime FFI requires the `ffi` capability (only `build.gab` has it)";
            return error.Trap;
        }
        return ffi.call(self.allocator, ec, args) catch error.Trap;
    }

    pub fn deinit(self: *Vm) void {
        self.zone_stack.deinit();
        for (self.concat_strings.items) |s| self.allocator.free(s);
        self.concat_strings.deinit(self.allocator);
        for (self.compiler_removals.items) |s| self.allocator.free(s);
        self.compiler_removals.deinit(self.allocator);
    }

    fn strLen(v: Value) ?usize {
        return switch (v) {
            .string => |s| s.len,
            .slice => |s| s.len,
            .host_buf => |hb| hb.len,
            else => null,
        };
    }

    fn copyStrBytes(self: *Vm, v: Value, dst: []u8) VmError!void {
        switch (v) {
            .string => |s| @memcpy(dst, s),
            .host_buf => |hb| {
                const p: [*]const u8 = @ptrFromInt(hb.addr);
                @memcpy(dst, p[0..hb.len]);
            },
            .slice => |s| {
                var i: usize = 0;
                while (i < s.len) : (i += 1) {
                    const cell = try self.zone_stack.getCell(s.zone, s.offset + @as(u32, @intCast(i)));
                    dst[i] = switch (cell) {
                        .int => |x| @intCast(@mod(x, 256)),
                        .uint => |x| @intCast(x % 256),
                        else => return error.TypeMismatch,
                    };
                }
            },
            else => return error.TypeMismatch,
        }
    }

    /// Execute a standalone function with no arguments. Kept for the simple
    /// hand-assembled smoke tests.
    pub fn execute(self: *Vm, function: BytecodeFunction) VmError!Value {
        return self.runTop(&function, &.{});
    }

    /// Like `execute`, but does NOT unwind the root zone on the way out, so the
    /// caller can still read the result's zone cells — used by the reifier to
    /// turn a comptime-built `AstBlock` back into front-end AST. All zone
    /// memory is freed by `deinit`.
    pub fn executeKeepZones(self: *Vm, function: BytecodeFunction) VmError!Value {
        if (self.zone_stack.depth() == 0) _ = try self.zone_stack.push("__root");
        return self.run(&function, &.{});
    }

    /// Look up a function by name in the bound module and run it with `args`.
    pub fn call(self: *Vm, name: []const u8, args: []const Value) VmError!Value {
        const mod = self.module orelse return error.NoModule;
        const f = mod.find(name) orelse return error.InvalidInstruction;
        return self.runTop(f, args);
    }

    /// Outermost entry: guarantee an active "root" zone so aggregate/`new`
    /// allocations always have somewhere to live, then unwind it on the way out.
    /// (Nested `call` opcodes reuse the existing zone stack and do not add one.)
    fn runTop(self: *Vm, func: *const BytecodeFunction, args: []const Value) VmError!Value {
        const root_mark = self.zone_stack.depth();
        if (root_mark == 0) _ = try self.zone_stack.push("__root");
        defer self.zone_stack.popTo(root_mark);
        return self.run(func, args);
    }

    /// Run `func`, binding `args` to its parameter slots.
    pub fn run(self: *Vm, func: *const BytecodeFunction, args: []const Value) VmError!Value {
        if (self.call_depth >= self.max_call_depth) return error.StackOverflow;
        self.call_depth += 1;
        defer self.call_depth -= 1;

        const regs = try self.allocator.alloc(Value, func.num_regs);
        defer self.allocator.free(regs);
        @memset(regs, .void);

        const locals = try self.allocator.alloc(Value, func.num_locals);
        defer self.allocator.free(locals);
        @memset(locals, .void);

        // Bind arguments to the leading parameter slots.
        const nparams = @min(args.len, func.num_params);
        for (args[0..nparams], 0..) |arg, i| locals[i] = arg;

        var frame = Frame{
            .func = func,
            .regs = regs,
            .locals = locals,
            .zone_watermark = self.zone_stack.depth(),
        };
        // On any early exit (error), make sure zones this frame opened are freed.
        errdefer self.zone_stack.popTo(frame.zone_watermark);

        return self.interpret(&frame);
    }

    fn interpret(self: *Vm, frame: *Frame) VmError!Value {
        const code = frame.func.instrs;
        const consts = frame.func.constants;
        var pc: usize = 0;

        while (pc < code.len) {
            self.steps += 1;
            if (self.steps > self.step_limit) return error.StepLimitExceeded;

            const inst = code[pc];
            pc += 1;

            switch (inst.op) {
                .nop => {},

                .load_imm => frame.regs[inst.a] = .{ .int = inst.imm },
                .load_const => frame.regs[inst.a] = consts[@intCast(inst.imm)],
                .copy => frame.regs[inst.a] = frame.regs[inst.b],

                // Integer arithmetic
                .add_i, .sub_i, .mul_i, .div_i, .rem_i => {
                    const l = frame.regs[inst.b].asI128() orelse return error.TypeMismatch;
                    const r = frame.regs[inst.c].asI128() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .int = switch (inst.op) {
                        .add_i => l +% r,
                        .sub_i => l -% r,
                        .mul_i => l *% r,
                        .div_i => if (r == 0) return error.DivisionByZero else @divTrunc(l, r),
                        .rem_i => if (r == 0) return error.DivisionByZero else @rem(l, r),
                        else => unreachable,
                    } };
                },
                .neg_i => {
                    const v = frame.regs[inst.b].asI128() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .int = -%v };
                },

                // Float arithmetic
                .add_f, .sub_f, .mul_f, .div_f => {
                    const l = frame.regs[inst.b].asF64() orelse return error.TypeMismatch;
                    const r = frame.regs[inst.c].asF64() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .float = switch (inst.op) {
                        .add_f => l + r,
                        .sub_f => l - r,
                        .mul_f => l * r,
                        .div_f => l / r,
                        else => unreachable,
                    } };
                },
                .neg_f => {
                    const v = frame.regs[inst.b].asF64() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .float = -v };
                },

                // Bitwise & logic
                .bit_and, .bit_or, .bit_xor, .shl, .shr => {
                    const l = frame.regs[inst.b].asI128() orelse return error.TypeMismatch;
                    const r = frame.regs[inst.c].asI128() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .int = switch (inst.op) {
                        .bit_and => l & r,
                        .bit_or => l | r,
                        .bit_xor => l ^ r,
                        .shl => l << @as(u7, @intCast(r & 0x7f)),
                        .shr => l >> @as(u7, @intCast(r & 0x7f)),
                        else => unreachable,
                    } };
                },
                .bitnot => {
                    const v = frame.regs[inst.b].asI128() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .int = ~v };
                },
                .not_b => frame.regs[inst.a] = .{ .bool = !frame.regs[inst.b].truthy() },

                // Comparison (int)
                .eq_i, .ne_i, .lt_i, .le_i, .gt_i, .ge_i => {
                    const l = frame.regs[inst.b].asI128() orelse return error.TypeMismatch;
                    const r = frame.regs[inst.c].asI128() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .bool = switch (inst.op) {
                        .eq_i => l == r,
                        .ne_i => l != r,
                        .lt_i => l < r,
                        .le_i => l <= r,
                        .gt_i => l > r,
                        .ge_i => l >= r,
                        else => unreachable,
                    } };
                },

                // Comparison (float)
                .eq_f, .ne_f, .lt_f, .le_f, .gt_f, .ge_f => {
                    const l = frame.regs[inst.b].asF64() orelse return error.TypeMismatch;
                    const r = frame.regs[inst.c].asF64() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .bool = switch (inst.op) {
                        .eq_f => l == r,
                        .ne_f => l != r,
                        .lt_f => l < r,
                        .le_f => l <= r,
                        .gt_f => l > r,
                        .ge_f => l >= r,
                        else => unreachable,
                    } };
                },

                // Casts
                .cast_to_float => {
                    const v = frame.regs[inst.b].asF64() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .float = v };
                },
                .cast_to_int => {
                    frame.regs[inst.a] = switch (frame.regs[inst.b]) {
                        .float => |f| .{ .int = @intFromFloat(f) },
                        .int => |v| .{ .int = v },
                        .uint => |v| .{ .int = std.math.cast(i128, v) orelse @bitCast(v) },
                        .bool => |bb| .{ .int = @intFromBool(bb) },
                        else => return error.TypeMismatch,
                    };
                },

                // Locals
                .load_local => frame.regs[inst.a] = frame.locals[@intCast(inst.imm)],
                .store_local => frame.locals[@intCast(inst.imm)] = frame.regs[inst.b],

                .load_global, .store_global => return error.Unsupported,

                // Control flow
                .jmp => pc = @intCast(inst.imm),
                .br_if => if (frame.regs[inst.a].truthy()) {
                    pc = @intCast(inst.imm);
                },
                .br_if_not => if (!frame.regs[inst.a].truthy()) {
                    pc = @intCast(inst.imm);
                },
                .call => {
                    const mod = self.module orelse return error.NoModule;
                    const idx: usize = @intCast(inst.imm);
                    if (idx >= mod.functions.len) return error.InvalidInstruction;
                    const callee = &mod.functions[idx];
                    const argc: usize = inst.c;
                    const base: usize = inst.b;
                    // Snapshot args (callee.run allocates its own frame).
                    var buf: [16]Value = undefined;
                    const arg_slice = if (argc <= buf.len) buf[0..argc] else try self.allocator.alloc(Value, argc);
                    defer if (argc > buf.len) self.allocator.free(arg_slice);
                    for (0..argc) |i| arg_slice[i] = frame.regs[base + i];
                    frame.regs[inst.a] = if (callee.extern_call) |ec|
                        try self.callExtern(ec, arg_slice)
                    else
                        try self.run(callee, arg_slice);
                },
                .call_indirect => {
                    const mod = self.module orelse return error.NoModule;
                    // The callee is a bare function reference (an interface method)
                    // or a closure value. A closure that `takes_env` (a lifted
                    // lambda) gets its environment passed as the leading argument;
                    // a plain function is called directly.
                    var idx: usize = undefined;
                    var lead_env: ?Value = null;
                    switch (frame.regs[inst.b]) {
                        .fn_ref => |fr| idx = fr,
                        .closure => |c| {
                            idx = c.fn_idx;
                            if (c.takes_env) lead_env = switch (c.env) {
                                .none => .void, // non-capturing: void env
                                .cell => |p| .{ .ptr = p },
                                .host => |h| .{ .host_ptr = h },
                            };
                        },
                        else => return error.TypeMismatch,
                    }
                    if (idx >= mod.functions.len) return error.InvalidInstruction;
                    const callee = &mod.functions[idx];
                    const argc: usize = @intCast(inst.imm);
                    const base: usize = inst.c;
                    const total = argc + @as(usize, if (lead_env != null) 1 else 0);
                    var buf: [16]Value = undefined;
                    const arg_slice = if (total <= buf.len) buf[0..total] else try self.allocator.alloc(Value, total);
                    defer if (total > buf.len) self.allocator.free(arg_slice);
                    const off: usize = if (lead_env) |e| blk: {
                        arg_slice[0] = e;
                        break :blk 1;
                    } else 0;
                    for (0..argc) |i| arg_slice[off + i] = frame.regs[base + i];
                    frame.regs[inst.a] = if (callee.extern_call) |ec|
                        try self.callExtern(ec, arg_slice)
                    else
                        try self.run(callee, arg_slice);
                },

                .ret => {
                    const result = frame.regs[inst.a];
                    self.zone_stack.popTo(frame.zone_watermark);
                    return result;
                },
                .ret_void => {
                    self.zone_stack.popTo(frame.zone_watermark);
                    return .void;
                },

                // Zones
                .zone_push => {
                    const name = constName(consts, inst.imm);
                    _ = try self.zone_stack.push(name);
                },
                .zone_pop => try self.zone_stack.pop(),
                .zone_alloc => {
                    frame.regs[inst.a] = try self.zone_stack.alloc(@intCast(inst.imm));
                },
                .field_addr => {
                    // A field of a HOST struct (e.g. `Chunk` reached via a real
                    // address): pointer-sized fields, so byte offset = index * 8.
                    if (frame.regs[inst.b] == .host_ptr) {
                        const hp = frame.regs[inst.b].host_ptr;
                        frame.regs[inst.a] = .{ .host_ptr = .{ .addr = hp.addr + @as(usize, @intCast(inst.imm)) * 8, .size = 8 } };
                    } else {
                        const base = try asPtr(frame.regs[inst.b]);
                        frame.regs[inst.a] = .{ .ptr = .{ .zone = base.zone, .offset = base.offset + @as(u32, @intCast(inst.imm)) } };
                    }
                },
                .load_cell => {
                    // On a host pointer, `imm` is a field index → byte offset *8;
                    // host struct fields are pointer-sized (read 8 bytes).
                    if (frame.regs[inst.b] == .host_ptr) {
                        const hp = frame.regs[inst.b].host_ptr;
                        frame.regs[inst.a] = hostLoad(hp.addr + @as(usize, @intCast(inst.imm)) * 8, 8);
                    } else {
                        const base = try asPtr(frame.regs[inst.b]);
                        frame.regs[inst.a] = try self.zone_stack.getCell(base.zone, base.offset + @as(u32, @intCast(inst.imm)));
                    }
                },
                .store_cell => {
                    // The target's offset is already baked in by `field_addr` /
                    // `index_addr`; write `hp.size` bytes at the host address.
                    if (frame.regs[inst.a] == .host_ptr) {
                        const hp = frame.regs[inst.a].host_ptr;
                        hostStore(hp.addr + @as(usize, @intCast(inst.imm)) * 8, hp.size, frame.regs[inst.b]);
                    } else {
                        const base = try asPtr(frame.regs[inst.a]);
                        try self.zone_stack.setCell(base.zone, base.offset + @as(u32, @intCast(inst.imm)), frame.regs[inst.b]);
                    }
                },
                .index_addr => {
                    const index = frame.regs[inst.c].asI128() orelse return error.TypeMismatch;
                    if (frame.regs[inst.b] == .host_buf) {
                        const hb = frame.regs[inst.b].host_buf;
                        frame.regs[inst.a] = .{ .host_ptr = .{ .addr = hb.addr + @as(usize, @intCast(index)) * hb.stride, .size = hb.stride } };
                    } else {
                        const base = try asPtr(frame.regs[inst.b]);
                        const stride: i128 = @intCast(inst.imm);
                        frame.regs[inst.a] = .{ .ptr = .{ .zone = base.zone, .offset = base.offset + @as(u32, @intCast(index * stride)) } };
                    }
                },
                .index_load => {
                    // Element read for zone aggregates, host strings, and host bufs.
                    const index = frame.regs[inst.c].asI128() orelse return error.TypeMismatch;
                    switch (frame.regs[inst.b]) {
                        .string => |s| {
                            const i: usize = std.math.cast(usize, index) orelse return error.TypeMismatch;
                            if (i >= s.len) return error.OutOfBounds;
                            frame.regs[inst.a] = .{ .uint = s[i] };
                        },
                        .host_buf => |hb| {
                            frame.regs[inst.a] = hostLoad(hb.addr + @as(usize, @intCast(index)) * hb.stride, hb.stride);
                        },
                        else => {
                            const base = try asPtr(frame.regs[inst.b]);
                            const stride: i128 = @intCast(inst.imm);
                            const off = base.offset + @as(u32, @intCast(index * stride));
                            frame.regs[inst.a] = try self.zone_stack.getCell(base.zone, off);
                        },
                    }
                },
                .slice_make => {
                    const base = try asPtr(frame.regs[inst.b]);
                    const len = frame.regs[inst.c].asI128() orelse return error.TypeMismatch;
                    frame.regs[inst.a] = .{ .slice = .{
                        .zone = base.zone,
                        .offset = base.offset,
                        .len = @intCast(len),
                    } };
                },
                .slice_len => {
                    frame.regs[inst.a] = switch (frame.regs[inst.b]) {
                        .slice => |s| .{ .uint = s.len },
                        // `[]const u8` string values carry their own length.
                        .string => |s| .{ .uint = s.len },
                        .host_buf => |hb| .{ .uint = hb.len },
                        else => return error.TypeMismatch,
                    };
                },
                .slice_ptr => {
                    frame.regs[inst.a] = switch (frame.regs[inst.b]) {
                        .host_buf => |hb| .{ .host_ptr = .{ .addr = hb.addr, .size = hb.stride } },
                        .slice => |s| .{ .ptr = .{ .zone = s.zone, .offset = s.offset } },
                        else => return error.TypeMismatch,
                    };
                },
                .halt_msg => {
                    // `compiler_error(msg)`: stash the message and halt the hook.
                    self.compiler_error_msg = switch (frame.regs[inst.a]) {
                        .string => |s| s,
                        else => "compiler hook requested a halt",
                    };
                    return error.Trap;
                },
                .record_remove => {
                    // `compiler_remove(name)`: record a decl name to drop. Does NOT
                    // halt — the hook keeps running and still returns its source.
                    const n = strLen(frame.regs[inst.a]) orelse return error.TypeMismatch;
                    const buf = self.allocator.alloc(u8, n) catch return error.OutOfMemory;
                    try self.copyStrBytes(frame.regs[inst.a], buf);
                    self.compiler_removals.append(self.allocator, buf) catch return error.OutOfMemory;
                },
                .scalar_builtin => frame.regs[inst.a] = computeScalar(
                    @enumFromInt(inst.imm),
                    frame.regs[inst.b],
                    frame.regs[inst.c],
                ) orelse return error.TypeMismatch,
                .host_ptr_make => frame.regs[inst.a] = .{ .host_ptr = .{
                    .addr = asAddr(frame.regs[inst.b]) orelse return error.TypeMismatch,
                    .size = @intCast(inst.imm),
                } },
                .host_buf_make => frame.regs[inst.a] = .{ .host_buf = .{
                    .addr = asAddr(frame.regs[inst.b]) orelse return error.TypeMismatch,
                    .len = @intCast(frame.regs[inst.c].asI128() orelse return error.TypeMismatch),
                    .stride = @intCast(inst.imm),
                } },
                .str_concat => {
                    const la = strLen(frame.regs[inst.b]) orelse return error.TypeMismatch;
                    const lb = strLen(frame.regs[inst.c]) orelse return error.TypeMismatch;
                    const buf = self.allocator.alloc(u8, la + lb) catch return error.OutOfMemory;
                    try self.copyStrBytes(frame.regs[inst.b], buf[0..la]);
                    try self.copyStrBytes(frame.regs[inst.c], buf[la..]);
                    self.concat_strings.append(self.allocator, buf) catch return error.OutOfMemory;
                    frame.regs[inst.a] = .{ .string = buf };
                },
                .opt_is_some => frame.regs[inst.a] = .{ .bool = switch (frame.regs[inst.b]) {
                    .null_ptr => false,
                    else => true,
                } },
                .interface_method => {
                    const mod = self.module orelse return error.NoModule;
                    const iface = try asPtr(frame.regs[inst.b]);
                    const vt_cell = try self.zone_stack.getCell(iface.zone, iface.offset + 1);
                    const vt_idx: usize = switch (vt_cell) {
                        .uint => |u| @intCast(u),
                        .int => |i| @intCast(i),
                        else => return error.TypeMismatch,
                    };
                    const method_idx: usize = @intCast(inst.imm);
                    if (vt_idx >= mod.vtables.len) return error.InvalidInstruction;
                    const vt = mod.vtables[vt_idx];
                    if (method_idx >= vt.len) return error.InvalidInstruction;
                    frame.regs[inst.a] = .{ .fn_ref = vt[method_idx] };
                },
                .closure_make => {
                    const env: Value.EnvRef = switch (frame.regs[inst.b]) {
                        .ptr => |p| .{ .cell = p },
                        .host_ptr => |h| .{ .host = h },
                        else => .none,
                    };
                    frame.regs[inst.a] = .{ .closure = .{
                        .fn_idx = @intCast(inst.imm),
                        .takes_env = inst.c != 0,
                        .env = env,
                    } };
                },

                // System
                .sys_print => printValue(frame.regs[inst.a]),
                .trap => return error.Trap,
                .host_call => {
                    const h = self.host orelse return error.InvalidInstruction;
                    const base: usize = inst.b;
                    const argc: usize = inst.c;
                    const args = frame.regs[base .. base + argc];
                    frame.regs[inst.a] = h.call(h.ctx, @intCast(inst.imm), args);
                },
            }
        }

        // Fell off the end without an explicit terminator.
        self.zone_stack.popTo(frame.zone_watermark);
        return .void;
    }
};

fn asPtr(v: Value) VmError!Value.Ptr {
    return switch (v) {
        .ptr => |p| p,
        .struct_ref => |r| .{ .zone = r.zone, .offset = r.offset },
        .slice => |s| .{ .zone = s.zone, .offset = s.offset },
        else => error.TypeMismatch,
    };
}

/// A raw host address from an int/uint/host pointer (for `ptr_from_int` etc.).
fn asAddr(v: Value) ?usize {
    return switch (v) {
        .uint => |u| std.math.cast(usize, u),
        .int => |i| std.math.cast(usize, i),
        .host_ptr => |hp| hp.addr,
        .null_ptr => 0,
        else => null,
    };
}

/// Compute a `core::` math/`count_ones` fold at comptime (the `scalar_builtin`
/// opcode). Float ops return `.float`; int ops return `.int`. Returns null on a
/// non-numeric operand (caller traps).
fn computeScalar(op: instructions.ScalarOp, a: Value, b: Value) ?Value {
    switch (op) {
        .sqrt, .floor, .ceil, .round, .trunc, .sin, .cos => {
            const x = a.asF64() orelse return null;
            return .{ .float = switch (op) {
                .sqrt => @sqrt(x),
                .floor => @floor(x),
                .ceil => @ceil(x),
                .round => @round(x),
                .trunc => @trunc(x),
                .sin => @sin(x),
                .cos => @cos(x),
                else => unreachable,
            } };
        },
        .pow => return .{ .float = std.math.pow(f64, a.asF64() orelse return null, b.asF64() orelse return null) },
        .min, .max => {
            if (a == .float or b == .float) {
                const x = a.asF64() orelse return null;
                const y = b.asF64() orelse return null;
                return .{ .float = if (op == .min) @min(x, y) else @max(x, y) };
            }
            const x = a.asI128() orelse return null;
            const y = b.asI128() orelse return null;
            return .{ .int = if (op == .min) @min(x, y) else @max(x, y) };
        },
        .abs => {
            if (a == .float) return .{ .float = @abs(a.float) };
            const x = a.asI128() orelse return null;
            return .{ .int = if (x < 0) -x else x };
        },
        .count_ones => {
            const u: u128 = switch (a) {
                .uint => |v| v,
                .int => |v| @bitCast(v),
                else => return null,
            };
            return .{ .int = @popCount(u) };
        },
    }
}

/// Read `size` (1–16) bytes of real host memory at `addr` as a little-endian uint.
fn hostLoad(addr: usize, size: u32) Value {
    if (addr == 0) return .{ .uint = 0 };
    const p: [*]const u8 = @ptrFromInt(addr);
    var v: u128 = 0;
    var i: u32 = 0;
    while (i < size and i < 16) : (i += 1) v |= @as(u128, p[i]) << @intCast(i * 8);
    return .{ .uint = v };
}

/// Write the low `size` bytes of `val` to real host memory at `addr`.
fn hostStore(addr: usize, size: u32, val: Value) void {
    if (addr == 0) return;
    const p: [*]u8 = @ptrFromInt(addr);
    const v: u128 = switch (val) {
        .uint => |x| x,
        .int => |x| @bitCast(x),
        .host_ptr => |hp| hp.addr,
        .bool => |b| @intFromBool(b),
        else => 0,
    };
    var i: u32 = 0;
    while (i < size and i < 16) : (i += 1) p[i] = @truncate(v >> @intCast(i * 8));
}

fn constName(consts: []const Value, imm: i64) []const u8 {
    if (imm < 0 or imm >= consts.len) return "<zone>";
    return switch (consts[@intCast(imm)]) {
        .string => |s| s,
        else => "<zone>",
    };
}

fn printValue(v: Value) void {
    switch (v) {
        .int => |x| std.debug.print("{d}\n", .{x}),
        .uint => |x| std.debug.print("{d}\n", .{x}),
        .float => |x| std.debug.print("{d}\n", .{x}),
        .bool => |x| std.debug.print("{}\n", .{x}),
        .string => |x| std.debug.print("{s}\n", .{x}),
        else => std.debug.print("{any}\n", .{v}),
    }
}
