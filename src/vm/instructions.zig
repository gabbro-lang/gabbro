const std = @import("std");
const value = @import("value.zig");

/// Virtual register index. One per IR result, plus scratch registers the
/// compiler allocates for materialised immediates and call arguments.
pub const Reg = u32;

pub const Opcode = enum(u8) {
    nop,

    // Constants & moves
    load_imm, // a = dst; imm = small integer literal
    load_const, // a = dst; imm = index into the function constant pool
    copy, // a = dst; b = src

    // Integer arithmetic
    add_i, sub_i, mul_i, div_i, rem_i, neg_i,

    // Float arithmetic
    add_f, sub_f, mul_f, div_f, neg_f,

    // Bitwise & logic
    bit_and, bit_or, bit_xor, bitnot, shl, shr, not_b,

    // Comparison (int)
    eq_i, ne_i, lt_i, le_i, gt_i, ge_i,

    // Comparison (float)
    eq_f, ne_f, lt_f, le_f, gt_f, ge_f,

    // Casts
    cast_to_float, cast_to_int,

    // Locals & globals
    load_local, // a = dst; imm = local slot
    store_local, // b = src; imm = local slot
    load_global, // a = dst; imm = global index
    store_global, // b = src; imm = global index

    // Control flow
    jmp, // imm = target instruction offset
    br_if, // a = cond; imm = target offset (taken when truthy)
    br_if_not, // a = cond; imm = target offset (taken when falsy)
    call, // a = dst; imm = function index; b = arg base reg; c = arg count
    ret, // a = value reg
    ret_void,

    // Zones & aggregates
    zone_push, // imm = const-pool index of the zone name string
    zone_pop,
    zone_alloc, // a = dst; imm = number of cells (allocated in the top zone)
    field_addr, // a = dst; b = base ptr/ref; imm = field/element cell offset
    load_cell, // a = dst; b = base ptr; imm = cell offset to read
    store_cell, // a = base ptr; b = src value; imm = cell offset to write
    index_addr, // a = dst; b = base ptr; c = index reg; imm = cells per element
    index_load, // a = dst; b = base (zone slice/ptr OR host string); c = index reg; imm = cells per element → loaded element
    slice_make, // a = dst; b = ptr reg; c = len reg → slice value
    slice_len, // a = dst; b = slice reg → its length as a uint
    slice_ptr, // a = dst; b = slice/host_buf reg → its base pointer
    str_concat, // a = dst; b = lhs string reg; c = rhs string reg → concatenated string
    halt_msg, // a = string reg → record it as a compiler diagnostic and halt (Trap)
    record_remove, // a = string reg → record a top-level decl name to remove (no halt)
    scalar_builtin, // a = dst; b = arg0; c = arg1; imm = op id → a `core::` math/bit fold
    // Host memory (run byte-addressed std.heap at comptime)
    host_ptr_make, // a = dst; b = addr reg (uint); imm = byte size of pointee → host_ptr
    host_buf_make, // a = dst; b = addr/host_ptr reg; c = len reg; imm = byte stride → host_buf
    opt_is_some, // a = dst; b = optional value → bool (non-null)
    interface_method, // a = dst; b = interface value; imm = method slot → fn_ref
    call_indirect, // a = dst; b = callee fn_ref reg; c = arg base reg; imm = arg count
    closure_make, // a = dst; b = env ptr reg; c = takes_env (0/1); imm = fn index → closure

    // System / diagnostics
    sys_print, // a = reg to print
    trap, // imm = const-pool index of message string, or -1 for none

    // Host call
    // A side-effecting call into the embedding host (e.g. the build driver).
    // imm = host-op id (see BuildOp); b = arg base reg; c = arg count;
    // a = dst reg for the returned value (e.g. a fresh artifact id).
    host_call,
};

/// Operation id carried in `scalar_builtin`'s `imm` — a `core::` math/bit fold the
/// comptime VM computes. (Width-dependent bit ops like `leading_zeros` aren't here;
/// they need the operand width and fall back to runtime at comptime.)
pub const ScalarOp = enum(i32) {
    count_ones = 1,
    abs = 7,
    sqrt = 8,
    floor = 9,
    ceil = 10,
    round = 11,
    trunc = 12,
    sin = 13,
    cos = 14,
    min = 15,
    max = 16,
    pow = 17,
};

/// Host operations dispatched by the `host_call` opcode. The VM is agnostic to
/// what these do — the embedding `Vm.host` callback interprets the id. Used by
/// the build system: `std.build`'s `__build_*` intrinsics lower to a `host_call`
/// carrying one of these, and the build driver records them into a BuildPlan.
pub const BuildOp = enum(u32) {
    artifact,   // (name, root, kind:i32) -> id     kind: 0 exe,1 shared,2 static,3 object
    opt,        // (id, level:i32)
    link,       // (id, libname)
    lib_path,   // (id, dir)
    output,     // (id, path)
    define,     // (id, key, val)
    set_default,// (id)
    run_step,   // (name, id)
    test_dir,   // (name, dir)
    require,    // (name, location, kind:i32) -> dep_id   kind: 0 path, 1 git
    depend,     // (id, dep_id)
    subsystem,  // (id, kind:i32)                   kind: 0 console, 1 windows (GUI)
    entry,      // (id, symbol)
    stack,      // (id, reserve:i64)
    link_flag,  // (id, raw-linker-flag)
    out_dir,    // (id, dir)
    version,    // (id, semver-string)
    description,// (id, text)
    workspace,  // (name)                           workspace-level metadata / default out dir
    out_root,   // (dir)                             workspace output directory for all artifacts
    install,    // (id)                              mark an artifact as installed (copied to out_root)
    option_flag,// (name) -> i32                     a `-Dname` build flag (1 if set)
    option_str, // (name, default) -> string         a `-Dname=value` build option
    summary,    // (on:i32)                          print a build summary when done
    link_mode,  // (id, mode:i32)                    0 dynamic, 1 static (static auto-links libc)
    runtime_file,// (id, path)                        copy a runtime dep (e.g. a .dll) next to the output
    no_default_libs,// (id)                           don't honor a C lib's /DEFAULTLIB directives
    link_libc,  // (id)                               link the host libc (Win CRT / glibc) — portable
};

pub const Instr = struct {
    op: Opcode,
    a: Reg = 0,
    b: Reg = 0,
    c: Reg = 0,
    /// Literal / slot / instruction-offset / pool index. Signed so small
    /// negative integer literals can be loaded directly via `load_imm`.
    imm: i64 = 0,

    pub fn r_r_r(op: Opcode, a: Reg, b: Reg, c: Reg) Instr {
        return .{ .op = op, .a = a, .b = b, .c = c };
    }
    pub fn r_r_imm(op: Opcode, a: Reg, b: Reg, immediate: i64) Instr {
        return .{ .op = op, .a = a, .b = b, .imm = immediate };
    }
    pub fn r_imm(op: Opcode, a: Reg, immediate: i64) Instr {
        return .{ .op = op, .a = a, .imm = immediate };
    }
    pub fn with_imm(op: Opcode, immediate: i64) Instr {
        return .{ .op = op, .imm = immediate };
    }
};

/// A compiled function: a flat instruction stream plus a constant pool for
/// values that don't fit in an inline immediate (wide ints, floats, strings,
/// type values, zone names).
/// A call into an external (DLL/C) function, resolved and invoked by the VM's
/// FFI bridge at compile time instead of running bytecode.
pub const ExternCall = struct {
    lib: []const u8,
    symbol: []const u8,
    returns_value: bool,
};

pub const BytecodeFunction = struct {
    name: []const u8,
    instrs: []const Instr,
    /// Size of the per-call register window.
    num_regs: u32,
    /// Number of local slots (parameters first, then named locals).
    num_locals: u32,
    /// How many of `num_locals` are parameters, bound from call arguments.
    num_params: u32 = 0,
    constants: []const value.Value = &.{},
    /// When set, calling this function invokes a native function via FFI rather
    /// than executing `instrs` (which is empty for extern functions).
    extern_call: ?ExternCall = null,

    pub fn deinit(self: *const BytecodeFunction, allocator: std.mem.Allocator) void {
        allocator.free(self.instrs);
        if (self.constants.len != 0) allocator.free(self.constants);
    }
};

/// A compiled module: the function table the VM resolves `call` against, plus
/// the interface vtables (`vtable index → method slot → function index`) that
/// `interface_method` dispatches through.
pub const BytecodeModule = struct {
    functions: []BytecodeFunction,
    vtables: []const []const u32 = &.{},

    pub fn deinit(self: *BytecodeModule, allocator: std.mem.Allocator) void {
        for (self.functions) |*f| f.deinit(allocator);
        allocator.free(self.functions);
        for (self.vtables) |vt| allocator.free(vt);
        if (self.vtables.len != 0) allocator.free(self.vtables);
    }

    pub fn find(self: *const BytecodeModule, name: []const u8) ?*const BytecodeFunction {
        for (self.functions) |*f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }
};
