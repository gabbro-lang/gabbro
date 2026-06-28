const std = @import("std");
const ast = @import("ast.zig");
const pipeline = @import("pipeline.zig");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const Span = @import("lexer/span.zig").Span;
const diag_mod = @import("diagnostic.zig");
const vm_compiler = @import("vm/compiler.zig");
const vm_engine = @import("vm/engine.zig");
const vm_instructions = @import("vm/instructions.zig");
const vm_value = @import("vm/value.zig");

pub const RegId = u32;
pub const BlockId = u32;

/// Wall-clock nanoseconds spent in compile-time evaluation on the VM (the
/// `#run`/`#insert`/`#parse` engine, including FFI). Accumulated globally; the
/// driver snapshots it around a build to report "Comptime" time. Single-threaded.
pub var comptime_ns: u64 = 0;

const clock = @import("clock.zig");

fn ctNow() u64 {
    return clock.monoNs();
}

fn ctAdd(start: u64) void {
    comptime_ns += clock.sinceNs(start);
}

pub const IrModule = struct {
    file_name: []const u8,
    structs: []const StructDef = &.{},
    errors: []const ErrorDef = &.{},
    variants: []const VariantDef = &.{},
    functions: []const IrFunction = &.{},
    globals: []const IrGlobal = &.{},
    vtables: []const InterfaceVTable = &.{},
    /// Distinct library names referenced by `#extern("lib", "symbol")` decls
    /// (excluding "kernel32", which the linker always includes). The Windows
    /// linker step appends "<name>.lib" for each of these.
    extern_libs: []const []const u8 = &.{},

    pub fn empty(file_name: []const u8) IrModule {
        return .{ .file_name = file_name };
    }
};

pub const InterfaceVTable = struct {
    name: []const u8,
    methods: []const []const u8,
};

pub const IrGlobal = struct {
    name: []const u8,
    ty: IrType,
    init: ConstInit,
    mutable: bool,
};

pub const ConstInit = union(enum) {
    imm: Imm,
    struct_init: StructInit,
};

pub const StructInit = struct {
    ty_name: []const u8,
    fields: []const ConstFieldInit,
};

pub const ConstFieldInit = struct {
    name: []const u8,
    value: ConstInit,
};

pub const IrFunction = struct {
    name: []const u8,
    params: []const IrParam,
    return_ty: IrType,
    error_ty: ?IrType,
    blocks: []const IrBlock,
    extern_name: ?[]const u8,
    /// Library for an `#extern("lib", "symbol")` function — used by the comptime
    /// FFI bridge to know which DLL to load. Null for non-extern functions.
    extern_lib: ?[]const u8 = null,
    inline_hint: bool,
    no_inline: bool,
    no_return: bool,
    entry: bool,
    naked: bool,
    export_sym: ?[]const u8,
    /// `#cold` — the function is rarely called (optimize for size / off the hot path).
    cold: bool = false,
    /// `#weak` — emit a weak symbol (overridable at link time).
    weak: bool = false,
    /// `#keep` — never strip, even if unused (best-effort: forces external linkage).
    keep: bool = false,
    /// `#section("name")` — place the function in a named object section.
    section: ?[]const u8 = null,
    /// `#link_name("name")` — the external symbol name (without exporting it).
    link_name: ?[]const u8 = null,
};

pub const IrParam = struct {
    name: []const u8,
    ty: IrType,
};

pub const IrBlock = struct {
    id: BlockId,
    name: []const u8,
    instrs: []const Instr,
    terminator: ?Terminator,
};

pub const IrType = union(enum) {
    i: u16,
    u: u16,
    f32,
    f64,
    bool,
    byte,
    usize,
    isize,
    addr,
    void,
    text,
    rune,
    zone,
    opaque_type: []const u8,
    ptr: *const IrType,
    optional: *const IrType,
    slice: *const IrType,
    array: ArrayType,
    range: *const IrType,
    struct_type: []const u8,
    variant_type: []const u8,
    fallible: FallibleType,
    fn_ptr: FnPtrType,
    interface_value: []const u8,
    list: *const IrType,
    map: *const IrType,
    unknown,

    pub fn isVoid(self: IrType) bool {
        return self == .void;
    }
};

pub const ArrayType = struct {
    elem: *const IrType,
    len: u64,
};

pub const FallibleType = struct {
    ok: *const IrType,
    err: *const IrType,
};

pub const FnPtrType = struct {
    params: []const IrType,
    ret: *const IrType,
    /// A THIN function pointer (a bare address, not k2's fat `{fn, env}` closure).
    /// Produced by reinterpreting a raw pointer/address as `fn(...)`; callable as a
    /// direct indirect call. This is what makes a dynamically-loaded function
    /// (`wglGetProcAddress`, `GetProcAddress`, a COM vtable slot) callable.
    thin: bool = false,
};

pub const StructDef = struct {
    name: []const u8,
    fields: []const FieldDef,
    is_packed: bool,
    alignment: u32 = 0, // 0 = default; set by #align(N)
};

pub const FieldDef = struct {
    name: []const u8,
    ty: IrType,
};

pub const VariantDef = struct {
    name: []const u8,
    variants: []const VariantCase,
};

pub const ErrorDef = struct {
    name: []const u8,
    variants: []const ErrorCase,
};

pub const ErrorCase = struct {
    name: []const u8,
    payload: ?IrType,
};

pub const VariantCase = struct {
    name: []const u8,
    payload: ?IrType,
};

pub const Instr = struct {
    id: ?RegId,
    ty: IrType,
    kind: InstrKind,
    location: SourceLocation = .{ .file = "", .line = 0, .column = 0 },
};

pub const InstrKind = union(enum) {
    const_value: Imm,
    unary: UnaryInstr,
    binary: BinaryInstr,
    cast: CastInstr,
    call: CallInstr,
    call_indirect: CallIndirectInstr,
    builtin: BuiltinInstr,
    inline_asm: InlineAsmInstr,
    struct_lit: StructLitInstr,
    variant_lit: VariantLitInstr,
    field: FieldInstr,
    field_addr: FieldInstr,
    index: IndexInstr,
    index_addr: IndexInstr,
    slice_expr: SliceInstr,
    variant_is: VariantCheckInstr,
    variant_payload: VariantCheckInstr,
    optional_is_some: Value,
    optional_payload: Value,
    try_is_ok: Value,
    try_ok: Value,
    try_err: Value,
    try_payload: Value,
    iter_init: Value,
    iter_has_next: Value,
    iter_next: Value,
    alloc: AllocInstr,
    alloc_slice: AllocSliceInstr,
    zone_push: ZonePushInstr,
    zone_pop: []const u8,
    zone_free: ZoneFreeInstr,
    at: AtInstr,
    raw_pointer: RawPointerInstr,
    interface_make: InterfaceMakeInstr,
    interface_data: Value,
    interface_method: InterfaceMethodInstr,
    /// Build a fat closure value `{ fn, env }` — a function (or thunk) pointer
    /// plus its captured environment (null when there are no captures).
    closure_make: ClosureMakeInstr,
    /// Allocate a capture environment and store the captured values into it,
    /// yielding a pointer (the closure's `env`).
    closure_env_make: ClosureEnvMakeInstr,
    /// Read capture field `index` out of a lambda's `__env` pointer.
    closure_env_load: ClosureEnvLoadInstr,
    store_local: StoreLocalInstr,
    global_load: []const u8,
    global_store: GlobalStoreInstr,
    store: StoreInstr,
};

pub const InterfaceMakeInstr = struct {
    data: Value,
    vtable: []const u8,
};

pub const InterfaceMethodInstr = struct {
    value: Value,
    index: u32,
};

pub const ClosureMakeInstr = struct {
    /// Linkage name of the function the closure calls.
    fn_link: []const u8,
    /// Captured environment pointer, or `.imm = .null` for no captures.
    env: Value,
    /// True when `fn_link` already takes a leading `__env` parameter (a lifted
    /// lambda). False for a plain top-level function — the backend wraps it in a
    /// forwarding thunk `__thunk_<fn>(__env, args)` so every closure is called
    /// uniformly as `fn(env, args)`.
    fn_takes_env: bool = false,
};

pub const EnvField = struct {
    value: Value,
    ty: IrType,
};

pub const ClosureEnvMakeInstr = struct {
    /// The captured values + their types, in capture order. The env is laid out
    /// as an anonymous struct `{ ty0, ty1, … }`.
    fields: []const EnvField,
    /// The `*Arena` region to allocate the env in (an enclosing `zone` handle's
    /// address, or a caller-supplied `*Arena` parameter) so the closure can escape
    /// the defining frame. `.imm = .null` = allocate on the stack (no escape).
    arena: Value = .{ .imm = .null },
};

pub const ClosureEnvLoadInstr = struct {
    /// The `__env` pointer (a lambda's first parameter).
    env: Value,
    index: u32,
    /// The env's field types (same order as `closure_env_make`), so the backend
    /// can GEP into the right anonymous-struct layout.
    fields: []const IrType,
};

pub const UnaryInstr = struct {
    op: UnaryOp,
    value: Value,
};

pub const BinaryInstr = struct {
    op: BinOp,
    lhs: Value,
    rhs: Value,
};

pub const CastInstr = struct {
    kind: CastKind,
    value: Value,
};

pub const CallInstr = struct {
    callee: []const u8,
    args: []const Value,
};

pub const CallIndirectInstr = struct {
    callee: Value,
    args: []const Value,
    /// Expected IR type per argument, from the callee's fn-pointer signature.
    /// Lets the backend type an untyped `.imm` literal arg (which otherwise has
    /// no tracked type and lowers to a zero-width `i0`). Empty = fall back to
    /// each arg's tracked type.
    param_tys: []const IrType = &.{},
    /// True when `callee` is a fat closure value `{ fn, env }` (a k2 function
    /// value) rather than a raw function pointer (an interface method). The
    /// backend extracts the `fn` field before calling.
    is_closure: bool = false,
};

pub const BuiltinInstr = struct {
    name: []const u8,
    args: []const Value,
    /// For builtins whose first argument is a type (e.g. `sizeof(T)`), the
    /// actual lowered type `T` — independent of the call's inferred result
    /// type, which sema may set to something else (e.g. `sizeof` → `.usize`).
    type_arg: ?IrType = null,
};

pub const StructFieldValue = struct {
    name: []const u8,
    value: Value,
};

pub const StructLitInstr = struct {
    ty_name: []const u8,
    fields: []const StructFieldValue,
};

pub const VariantLitInstr = struct {
    type_name: []const u8,
    variant: []const u8,
    payload: ?Value,
};

pub const FieldInstr = struct {
    base: Value,
    name: []const u8,
};

pub const IndexInstr = struct {
    base: Value,
    index: Value,
};

pub const SliceInstr = struct {
    ptr: Value,
    len: Value,
};

pub const VariantCheckInstr = struct {
    value: Value,
    type_name: []const u8, // enum type name for discriminant lookup
    variant: []const u8,
};

/// Inline assembly instruction with full operand constraint support.
/// Constraint string follows LLVM/GCC format: outputs first, then inputs, then clobbers.
/// Example for `syscall`:  "=a,{rdi},{rsi},{rdx},~{rcx},~{r11},~{memory}"
pub const InlineAsmInstr = struct {
    template: []const u8, // the assembly template, e.g. "syscall" or "pause"
    constraints: []const u8, // combined constraint string
    args: []const Value, // input operand values (in constraint order)
    volatile_: bool,
};

pub const AllocInstr = struct {
    ty: IrType,
    zone: []const u8,
};

pub const AllocSliceInstr = struct {
    elem_ty: IrType,
    count: Value,
    zone: []const u8,
};

pub const ZonePushInstr = struct {
    name: []const u8,
    kind: []const u8,
};

pub const ZoneFreeInstr = struct {
    zone: []const u8,
    ptr: Value,
};

pub const AtInstr = struct {
    value: Value,
    zone: []const u8,
};

pub const RawPointerInstr = struct {
    ty: IrType,
    address: Value,
};

pub const StoreLocalInstr = struct {
    name: []const u8,
    value: Value,
};

pub const GlobalStoreInstr = struct {
    name: []const u8,
    value: Value,
};

pub const StoreInstr = struct {
    target: Value,
    value: Value,
};

pub const Terminator = union(enum) {
    return_value: ?Value,
    fail: FailTerm,
    panic: Panic,
    branch: BlockId,
    cond_branch: CondBranch,
    unreachable_term,
};

pub const FailTerm = struct {
    /// The error discriminant (the `error.<variant>` value).
    disc: Value,
    /// The error variant's payload, stored into the fallible's value slot
    /// (field 0) so a `catch e { ... |c| ... }` can recover it. Null = no payload.
    payload: ?Value = null,
};

pub const Panic = struct {
    message: []const u8,
    location: SourceLocation,
};

pub const SourceLocation = struct {
    file: []const u8,
    line: usize,
    column: usize,
};

pub const CondBranch = struct {
    cond: Value,
    then_block: BlockId,
    else_block: BlockId,
};

pub const UnaryOp = enum {
    neg,
    not,
    bit_not,
    ref,
    deref,
};

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    rem,
    // Wrapping arithmetic — lowers to plain (non-trapping) add/sub/mul.
    wrap_add,
    wrap_sub,
    wrap_mul,
    shl,
    shr,
    lt,
    le,
    gt,
    ge,
    eq,
    ne,
    bit_and,
    bit_xor,
    bit_or,
    and_op,
    or_op,
    range,
    range_exclusive,
};

pub const CastKind = enum {
    as,
};

pub const Value = union(enum) {
    reg: RegId,
    param: []const u8,
    local: []const u8,
    global: []const u8,
    imm: Imm,
};

pub const Imm = union(enum) {
    int: i128,
    uint: u128,
    float: f64,
    bool: bool,
    text: []const u8,
    rune: u21,
    null,
};

pub const LowerError = error{
    LoweringFailed,
    OutOfMemory,
};

pub const ValidationError = error{
    InvalidIr,
};

pub const Pass = enum {
    const_fold,
    branch,
    dce,
};

pub fn lowerFrontend(allocator: std.mem.Allocator, front_end: pipeline.FrontEnd) LowerError!IrModule {
    return lowerModule(allocator, front_end);
}

pub fn lowerModule(allocator: std.mem.Allocator, front_end: pipeline.FrontEnd) LowerError!IrModule {
    var cvm = ComptimeVm.init(allocator, front_end);
    defer cvm.deinit();
    return lowerModuleInner(allocator, front_end, &cvm);
}

/// `cvm` is the VM-backed comptime evaluator threaded down to `#run` sites. It
/// is null while *building* the evaluator's own bytecode cache, so nested `#run`
/// there fall back to the tree-walker — which is exactly the recursion guard.
/// A stable content hash of a type, used as its runtime `typeid`. Streams a
/// canonical spelling of the type through FNV-1a, so identical types always hash
/// the same — no global registry, and stable across compilation units.
pub fn typeIdHash(ty: IrType) u64 {
    var h: u64 = 0xcbf29ce484222325; // FNV-1a offset basis
    hashTypeName(&h, ty);
    return h;
}

fn fnvFeed(h: *u64, bytes: []const u8) void {
    for (bytes) |b| {
        h.* ^= b;
        h.* = h.* *% 0x100000001b3; // FNV-1a prime
    }
}

fn fnvFeedInt(h: *u64, n: u64) void {
    var buf: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    fnvFeed(h, s);
}

fn hashTypeName(h: *u64, ty: IrType) void {
    switch (ty) {
        .i => |b| {
            fnvFeed(h, "i");
            fnvFeedInt(h, b);
        },
        .u => |b| {
            fnvFeed(h, "u");
            fnvFeedInt(h, b);
        },
        .f32 => fnvFeed(h, "f32"),
        .f64 => fnvFeed(h, "f64"),
        .bool => fnvFeed(h, "bool"),
        .byte => fnvFeed(h, "byte"),
        .usize => fnvFeed(h, "usize"),
        .isize => fnvFeed(h, "isize"),
        .addr => fnvFeed(h, "addr"),
        .void => fnvFeed(h, "void"),
        .text => fnvFeed(h, "str"),
        .rune => fnvFeed(h, "rune"),
        .zone => fnvFeed(h, "zone"),
        .ptr => |p| {
            fnvFeed(h, "*");
            hashTypeName(h, p.*);
        },
        .optional => |p| {
            fnvFeed(h, "?");
            hashTypeName(h, p.*);
        },
        .slice => |p| {
            fnvFeed(h, "[]");
            hashTypeName(h, p.*);
        },
        .array => |a| {
            fnvFeed(h, "[");
            fnvFeedInt(h, a.len);
            fnvFeed(h, "]");
            hashTypeName(h, a.elem.*);
        },
        .range => |p| {
            fnvFeed(h, "range ");
            hashTypeName(h, p.*);
        },
        .struct_type => |n| {
            fnvFeed(h, "struct ");
            fnvFeed(h, n);
        },
        .variant_type => |n| {
            fnvFeed(h, "enum ");
            fnvFeed(h, n);
        },
        .opaque_type => |n| {
            fnvFeed(h, "opaque ");
            fnvFeed(h, n);
        },
        .interface_value => |n| {
            fnvFeed(h, "iface ");
            fnvFeed(h, n);
        },
        .fallible => |f| {
            fnvFeed(h, "fallible ");
            hashTypeName(h, f.ok.*);
            fnvFeed(h, "!");
            hashTypeName(h, f.err.*);
        },
        .fn_ptr => fnvFeed(h, "fn"),
        .list => |p| {
            fnvFeed(h, "list ");
            hashTypeName(h, p.*);
        },
        .map => |p| {
            fnvFeed(h, "map ");
            hashTypeName(h, p.*);
        },
        .unknown => fnvFeed(h, "unknown"),
    }
}

fn lowerModuleInner(allocator: std.mem.Allocator, front_end: pipeline.FrontEnd, cvm: ?*ComptimeVm) LowerError!IrModule {
    var structs: std.ArrayList(StructDef) = .empty;
    var errors: std.ArrayList(ErrorDef) = .empty;
    var variants: std.ArrayList(VariantDef) = .empty;
    var functions: std.ArrayList(IrFunction) = .empty;
    var globals: std.ArrayList(IrGlobal) = .empty;
    var vtables: std.ArrayList(InterfaceVTable) = .empty;
    var extern_libs: std.ArrayList([]const u8) = .empty;
    errdefer structs.deinit(allocator);
    errdefer errors.deinit(allocator);
    errdefer variants.deinit(allocator);
    errdefer functions.deinit(allocator);
    errdefer globals.deinit(allocator);
    errdefer vtables.deinit(allocator);
    errdefer extern_libs.deinit(allocator);

    for (front_end.module.items) |item| {
        switch (item) {
            .import => {},
            .type_decl => |decl| switch (decl.kind) {
                .struct_type => |strukt| try structs.append(allocator, try lowerStruct(allocator, decl, strukt, front_end.types, front_end.symbols)),
                .errors => |error_decl| try errors.append(allocator, try lowerErrorDef(allocator, decl, error_decl)),
                .enum_type => |enum_decl| try variants.append(allocator, try lowerEnumDef(allocator, decl, enum_decl)),
                // Aliases are resolved away by sema (typeFromRef), so they have
                // no lowered type definition of their own.
                .distinct, .opaque_type, .interface_type, .alias => {},
            },
            .const_decl => |decl| {
                // #run expr on the right-hand side → evaluate at compile time.
                const effective_imm = try effectiveConstImm(decl.value, cvm, decl.file_name, decl.source);
                // A mutable global (`name: T = init;`) takes its explicit type;
                // an immutable constant derives it from the folded initializer
                // (`X :: #run f()` has no literal to infer from).
                var ty = if (decl.ty) |t|
                    try lowerAstTypeWithEnv(allocator, t, front_end.types, front_end.symbols)
                else
                    inferConstType(decl.value);
                if (ty == .unknown) ty = switch (effective_imm) {
                    .int => .{ .i = 32 },
                    .uint => .{ .u = 64 },
                    .float => .f64,
                    .bool => .bool,
                    .text => .text,
                    .rune => .rune,
                    .null => .unknown,
                };
                const clink = linkNameFor(front_end.symbols, decl.file_name, decl.name);
                try globals.append(allocator, .{
                    .name = clink,
                    .ty = ty,
                    .init = .{ .imm = effective_imm },
                    .mutable = decl.is_mutable,
                });
            },
            .function => |decl| {
                // Generic templates are lowered per-instantiation below; skip the template itself.
                // Comptime-only metaprogramming helpers (signatures or bodies that
                // build ast.* values) exist only for the VM: the cache build
                // (cvm == null) keeps them so `#insert #run gen()` can call them,
                // but the final module — and LLVM, which cannot lower the
                // recursive ast.* types — never sees them.
                const comptime_only = cvm != null and fnIsComptimeOnly(decl);
                if (decl.type_params.len == 0 and !comptime_only) {
                    try functions.append(allocator, try lowerFunction(allocator, front_end.types, front_end.symbols, front_end.module, decl, cvm));
                }
                if (externLibName(decl.attrs)) |lib| try addExternLib(allocator, &extern_libs, lib);
            },
            .interface_impl => |impl| {
                for (impl.methods) |method| {
                    const mangled = try interfaceMethodName(allocator, impl.type_name, impl.interface_name, method.name);
                    try functions.append(allocator, try lowerInterfaceMethod(
                        allocator,
                        front_end.types,
                        front_end.symbols,
                        front_end.module,
                        impl,
                        method,
                        mangled,
                        cvm,
                    ));
                }
                var method_names = std.ArrayList([]const u8).empty;
                errdefer method_names.deinit(allocator);
                const interface_id = front_end.symbols.resolve(front_end.symbols.root_scope, impl.interface_name) orelse {
                    diag_mod.printIce("interface symbol not found during vtable generation", @src());
                    return error.LoweringFailed;
                };
                const layout = front_end.types.layouts.get(interface_id) orelse {
                    diag_mod.printIce("interface layout not found during vtable generation", @src());
                    return error.LoweringFailed;
                };
                const interface_methods = switch (layout.kind) {
                    .interface_type => |methods| methods,
                    else => {
                        diag_mod.printIce("expected interface layout but found something else", @src());
                        return error.LoweringFailed;
                    },
                };
                for (interface_methods) |method| {
                    try method_names.append(allocator, try interfaceMethodName(
                        allocator,
                        impl.type_name,
                        impl.interface_name,
                        method.name,
                    ));
                }
                try vtables.append(allocator, .{
                    .name = try interfaceVTableName(allocator, impl.type_name, impl.interface_name),
                    .methods = try method_names.toOwnedSlice(allocator),
                });
            },
            .system_library => |decl| try addExternLib(allocator, &extern_libs, decl.name),
        }
    }

    // Emit generic struct instantiations as concrete StructDef entries.
    var inst_it = front_end.types.generic_struct_instances.iterator();
    while (inst_it.next()) |kv| {
        const inst_id = kv.value_ptr.*;
        const layout = front_end.types.layouts.get(inst_id) orelse continue;
        const mangled = kv.key_ptr.*;
        switch (layout.kind) {
            .struct_type => |fields| {
                var ir_fields: std.ArrayList(FieldDef) = .empty;
                errdefer ir_fields.deinit(allocator);
                for (fields) |f| {
                    try ir_fields.append(allocator, .{
                        .name = f.name,
                        .ty = try lowerSemaTypeWithEnv(allocator, f.ty, front_end.types, front_end.symbols),
                    });
                }
                try structs.append(allocator, .{
                    .name = mangled,
                    .fields = try ir_fields.toOwnedSlice(allocator),
                    .is_packed = layout.is_packed,
                    .alignment = 0,
                });
            },
            else => {},
        }
    }

    // Lower each generic function instantiation with its concrete type binding
    for (front_end.types.generic_instantiations.items) |*inst| {
        for (front_end.module.items) |item| {
            switch (item) {
                .function => |decl| {
                    if (decl.type_params.len == 0) continue;
                    // File-aware resolution: the root scope is keyed by *link_name*, so
                    // a bare `resolve(root, decl.name)` misses (or mis-resolves) a
                    // collision-mangled decl — e.g. `make` declared in two modules. Match
                    // the instantiation's owning decl exactly, mirroring sema's
                    // `checkGenericInstantiation`.
                    const sym_id = front_end.symbols.resolveVisible(decl.file_name, decl.name) orelse continue;
                    if (sym_id != inst.sym_id) continue;
                    // `where { … }` predicates are evaluated during *resolution*
                    // (sema's two-pass rail) — a rejected instantiation never
                    // reaches lowering, so nothing to check here.
                    //
                    // A comptime-only generic (e.g. one whose BODY calls `type_info`)
                    // is kept for the VM cache (cvm == null) but excluded from the
                    // final runtime module (cvm != null) — its body can't lower to LLVM.
                    if (cvm != null and fnIsComptimeOnly(decl)) continue;
                    var inst_types = front_end.types;
                    inst_types.expr_types = inst.expr_types;
                    // Per-instantiation generic-callee names: the same call node maps
                    // to a different concrete callee in each instantiation.
                    inst_types.generic_call_insts = inst.call_insts;
                    try functions.append(allocator, try lowerFunctionInstantiation(
                        allocator,
                        inst_types,
                        front_end.symbols,
                        decl,
                        inst.mangled_name,
                        inst.type_args,
                        cvm,
                    ));
                },
                else => {},
            }
        }
    }

    return .{
        .file_name = front_end.module.file_name,
        .structs = try structs.toOwnedSlice(allocator),
        .errors = try errors.toOwnedSlice(allocator),
        .variants = try variants.toOwnedSlice(allocator),
        .functions = try functions.toOwnedSlice(allocator),
        .globals = try globals.toOwnedSlice(allocator),
        .vtables = try vtables.toOwnedSlice(allocator),
        .extern_libs = try extern_libs.toOwnedSlice(allocator),
    };
}

pub fn validateModule(module: IrModule) ValidationError!void {
    for (module.functions) |function| {
        try validateFunction(function);
    }
}

pub fn runDefaultPasses(allocator: std.mem.Allocator, module: *IrModule) !void {
    try runPasses(allocator, module, &.{ .const_fold, .branch, .dce });
    try validateModule(module.*);
}

pub fn runPasses(allocator: std.mem.Allocator, module: *IrModule, passes: []const Pass) !void {
    for (passes) |pass| {
        switch (pass) {
            .const_fold => try foldConstants(allocator, module),
            .branch => try simplifyBranches(allocator, module),
            .dce => try eliminateDeadCode(allocator, module),
        }
    }
}

fn validateFunction(function: IrFunction) ValidationError!void {
    if (function.extern_name != null and function.blocks.len == 0) return;
    if (function.blocks.len == 0) return error.InvalidIr;
    if (function.blocks[0].id != 0) return error.InvalidIr;

    for (function.blocks, 0..) |block, block_index| {
        if (block.terminator == null) return error.InvalidIr;
        for (function.blocks[block_index + 1 ..]) |other| {
            if (block.id == other.id) return error.InvalidIr;
        }

        for (block.instrs, 0..) |instr, instr_index| {
            if (instr.id) |id| {
                for (function.blocks[0 .. block_index + 1], 0..) |seen_block, seen_block_index| {
                    const end = if (seen_block_index == block_index) instr_index else seen_block.instrs.len;
                    for (seen_block.instrs[0..end]) |seen| {
                        if (seen.id != null and seen.id.? == id) return error.InvalidIr;
                    }
                }
            }
            try validateInstr(function, instr);
        }

        try validateTerminator(function, block.terminator.?);
    }
}

fn validateInstr(function: IrFunction, instr: Instr) ValidationError!void {
    switch (instr.kind) {
        .const_value, .alloc, .alloc_slice, .zone_push, .zone_pop, .global_load => {},
        .inline_asm => |ai| for (ai.args) |v| try validateValue(function, v),
        .zone_free => |zf| try validateValue(function, zf.ptr),
        .unary => |unary| try validateValue(function, unary.value),
        .binary => |binary| {
            try validateValue(function, binary.lhs);
            try validateValue(function, binary.rhs);
        },
        .cast => |cast| try validateValue(function, cast.value),
        .call => |call| for (call.args) |arg| try validateValue(function, arg),
        .call_indirect => |call| {
            try validateValue(function, call.callee);
            for (call.args) |arg| try validateValue(function, arg);
        },
        .builtin => |builtin| for (builtin.args) |arg| try validateValue(function, arg),
        .struct_lit => |strukt| for (strukt.fields) |field| try validateValue(function, field.value),
        .variant_lit => |variant| if (variant.payload) |payload| try validateValue(function, payload),
        .field, .field_addr => |field| try validateValue(function, field.base),
        .index, .index_addr => |index| {
            try validateValue(function, index.base);
            try validateValue(function, index.index);
        },
        .slice_expr => |slice| {
            try validateValue(function, slice.ptr);
            try validateValue(function, slice.len);
        },
        .variant_is, .variant_payload => |variant| try validateValue(function, variant.value),
        .optional_is_some, .optional_payload, .try_is_ok, .try_ok, .try_err, .try_payload, .iter_init, .iter_has_next, .iter_next => |value| try validateValue(function, value),
        .at => |at| try validateValue(function, at.value),
        .raw_pointer => |ptr| try validateValue(function, ptr.address),
        .interface_make => |make| try validateValue(function, make.data),
        .interface_data => |value| try validateValue(function, value),
        .interface_method => |method| try validateValue(function, method.value),
        .closure_make => |mk| try validateValue(function, mk.env),
        .closure_env_make => |mk| {
            try validateValue(function, mk.arena);
            for (mk.fields) |f| try validateValue(function, f.value);
        },
        .closure_env_load => |ld| try validateValue(function, ld.env),
        .store_local => |store| try validateValue(function, store.value),
        .global_store => |store| try validateValue(function, store.value),
        .store => |store| {
            try validateValue(function, store.target);
            try validateValue(function, store.value);
        },
    }
}

fn validateTerminator(function: IrFunction, terminator: Terminator) ValidationError!void {
    switch (terminator) {
        .return_value => |value| if (value) |ret| try validateValue(function, ret),
        .fail => |ft| {
            try validateValue(function, ft.disc);
            if (ft.payload) |p| try validateValue(function, p);
        },
        .panic => {},
        .branch => |target| if (!hasBlock(function, target)) return error.InvalidIr,
        .cond_branch => |branch| {
            try validateValue(function, branch.cond);
            if (!hasBlock(function, branch.then_block)) return error.InvalidIr;
            if (!hasBlock(function, branch.else_block)) return error.InvalidIr;
        },
        .unreachable_term => {},
    }
}

fn validateValue(function: IrFunction, value: Value) ValidationError!void {
    switch (value) {
        .reg => |id| if (!hasReg(function, id)) return error.InvalidIr,
        .param => |name| if (!hasParam(function, name)) return error.InvalidIr,
        .local, .global, .imm => {},
    }
}

fn hasBlock(function: IrFunction, id: BlockId) bool {
    for (function.blocks) |block| {
        if (block.id == id) return true;
    }
    return false;
}

fn hasReg(function: IrFunction, id: RegId) bool {
    for (function.blocks) |block| {
        for (block.instrs) |instr| {
            if (instr.id != null and instr.id.? == id) return true;
        }
    }
    return false;
}

fn hasParam(function: IrFunction, name: []const u8) bool {
    for (function.params) |param| {
        if (std.mem.eql(u8, param.name, name)) return true;
    }
    return false;
}

fn foldConstants(allocator: std.mem.Allocator, module: *IrModule) !void {
    var functions: std.ArrayList(IrFunction) = .empty;
    errdefer functions.deinit(allocator);
    for (module.functions) |function| {
        try functions.append(allocator, try foldFunctionConstants(allocator, function));
    }
    module.functions = try functions.toOwnedSlice(allocator);
}

const ConstMap = std.AutoHashMap(RegId, Imm);

fn foldFunctionConstants(allocator: std.mem.Allocator, function: IrFunction) !IrFunction {
    var blocks: std.ArrayList(IrBlock) = .empty;
    errdefer blocks.deinit(allocator);

    var consts = ConstMap.init(allocator);
    defer consts.deinit();

    for (function.blocks) |block| {
        var instrs: std.ArrayList(Instr) = .empty;
        errdefer instrs.deinit(allocator);

        for (block.instrs) |instr| {
            const folded = tryFoldInstr(&consts, instr);
            if (folded.id) |id| {
                if (folded.kind == .const_value) {
                    try consts.put(id, folded.kind.const_value);
                }
            }
            try instrs.append(allocator, folded);
        }

        try blocks.append(allocator, .{
            .id = block.id,
            .name = block.name,
            .instrs = try instrs.toOwnedSlice(allocator),
            .terminator = foldTerminator(&consts, block.terminator),
        });
    }

    return .{
        .name = function.name,
        .params = function.params,
        .return_ty = function.return_ty,
        .error_ty = function.error_ty,
        .blocks = try blocks.toOwnedSlice(allocator),
        .extern_name = function.extern_name,
        .extern_lib = function.extern_lib,
        .inline_hint = function.inline_hint,
        .no_inline = function.no_inline,
        .no_return = function.no_return,
        .entry = function.entry,
        .naked = function.naked,
        .export_sym = function.export_sym,
    };
}

fn resolveVal(consts: *const ConstMap, value: Value) Value {
    return switch (value) {
        .reg => |id| if (consts.get(id)) |imm| .{ .imm = imm } else value,
        else => value,
    };
}

fn tryFoldInstr(consts: *const ConstMap, instr: Instr) Instr {
    switch (instr.kind) {
        .const_value => return instr,
        .binary => |binary| {
            const lhs = resolveVal(consts, binary.lhs);
            const rhs = resolveVal(consts, binary.rhs);
            if (lhs == .imm and rhs == .imm) {
                if (foldBinaryImm(binary.op, lhs.imm, rhs.imm)) |result| {
                    return .{ .id = instr.id, .ty = instr.ty, .kind = .{ .const_value = result }, .location = instr.location };
                }
            }
            return .{ .id = instr.id, .ty = instr.ty, .kind = .{ .binary = .{ .op = binary.op, .lhs = lhs, .rhs = rhs } }, .location = instr.location };
        },
        .unary => |unary| {
            const value = resolveVal(consts, unary.value);
            if (value == .imm) {
                if (foldUnaryImm(unary.op, value.imm)) |result| {
                    return .{ .id = instr.id, .ty = instr.ty, .kind = .{ .const_value = result }, .location = instr.location };
                }
            }
            return .{ .id = instr.id, .ty = instr.ty, .kind = .{ .unary = .{ .op = unary.op, .value = value } }, .location = instr.location };
        },
        else => return instr,
    }
}

fn foldTerminator(consts: *const ConstMap, terminator: ?Terminator) ?Terminator {
    const term = terminator orelse return null;
    return switch (term) {
        .cond_branch => |branch| {
            const cond = resolveVal(consts, branch.cond);
            if (cond == .imm) switch (cond.imm) {
                .bool => |b| return .{ .branch = if (b) branch.then_block else branch.else_block },
                else => {},
            };
            return .{ .cond_branch = .{ .cond = cond, .then_block = branch.then_block, .else_block = branch.else_block } };
        },
        .return_value => |v| if (v) |val| .{ .return_value = resolveVal(consts, val) } else term,
        .fail => |ft| .{ .fail = .{ .disc = resolveVal(consts, ft.disc), .payload = if (ft.payload) |p| resolveVal(consts, p) else null } },
        .panic => |panic| .{ .panic = panic },
        else => term,
    };
}

fn foldBinaryImm(op: BinOp, lhs: Imm, rhs: Imm) ?Imm {
    const l: i128 = switch (lhs) {
        .int => |v| v,
        .uint => |v| @intCast(v),
        else => return null,
    };
    const r: i128 = switch (rhs) {
        .int => |v| v,
        .uint => |v| @intCast(v),
        else => return null,
    };
    return switch (op) {
        .add, .wrap_add => .{ .int = l +% r },
        .sub, .wrap_sub => .{ .int = l -% r },
        .mul, .wrap_mul => .{ .int = l *% r },
        .div => if (r == 0) null else .{ .int = @divTrunc(l, r) },
        .rem => if (r == 0) null else .{ .int = @rem(l, r) },
        .shl => if (r >= 0 and r < 128) .{ .int = l << @as(u7, @intCast(r)) } else null,
        .shr => if (r >= 0 and r < 128) .{ .int = l >> @as(u7, @intCast(r)) } else null,
        .bit_and => .{ .int = l & r },
        .bit_or => .{ .int = l | r },
        .bit_xor => .{ .int = l ^ r },
        .eq => .{ .bool = l == r },
        .ne => .{ .bool = l != r },
        .lt => .{ .bool = l < r },
        .le => .{ .bool = l <= r },
        .gt => .{ .bool = l > r },
        .ge => .{ .bool = l >= r },
        else => null,
    };
}

fn foldUnaryImm(op: UnaryOp, value: Imm) ?Imm {
    return switch (op) {
        .neg => switch (value) {
            .int => |v| .{ .int = -%v },
            .uint => |v| .{ .int = -@as(i128, @intCast(v)) },
            else => null,
        },
        .not => switch (value) {
            .bool => |v| .{ .bool = !v },
            else => null,
        },
        .bit_not => switch (value) {
            .int => |v| .{ .int = ~v },
            .uint => |v| .{ .uint = ~v },
            else => null,
        },
        else => null,
    };
}

fn simplifyBranches(allocator: std.mem.Allocator, module: *IrModule) !void {
    var functions: std.ArrayList(IrFunction) = .empty;
    errdefer functions.deinit(allocator);

    for (module.functions) |function| {
        var blocks: std.ArrayList(IrBlock) = .empty;
        errdefer blocks.deinit(allocator);

        for (function.blocks) |block| {
            try blocks.append(allocator, .{
                .id = block.id,
                .name = block.name,
                .instrs = block.instrs,
                .terminator = simplifyTerminator(block.terminator),
            });
        }

        try functions.append(allocator, .{
            .name = function.name,
            .params = function.params,
            .return_ty = function.return_ty,
            .error_ty = function.error_ty,
            .blocks = try blocks.toOwnedSlice(allocator),
            .extern_name = function.extern_name,
            .extern_lib = function.extern_lib,
            .inline_hint = function.inline_hint,
            .no_inline = function.no_inline,
            .no_return = function.no_return,
            .entry = function.entry,
            .naked = function.naked,
            .export_sym = function.export_sym,
        });
    }

    module.functions = try functions.toOwnedSlice(allocator);
}

fn simplifyTerminator(terminator: ?Terminator) ?Terminator {
    const term = terminator orelse return null;
    return switch (term) {
        .cond_branch => |branch| if (branch.then_block == branch.else_block) .{ .branch = branch.then_block } else term,
        else => term,
    };
}

fn eliminateDeadCode(allocator: std.mem.Allocator, module: *IrModule) !void {
    var functions: std.ArrayList(IrFunction) = .empty;
    errdefer functions.deinit(allocator);

    for (module.functions) |function| {
        try functions.append(allocator, try eliminateFunctionDeadCode(allocator, function));
    }

    module.functions = try functions.toOwnedSlice(allocator);
}

fn eliminateFunctionDeadCode(allocator: std.mem.Allocator, function: IrFunction) !IrFunction {
    var blocks: std.ArrayList(IrBlock) = .empty;
    errdefer blocks.deinit(allocator);

    for (function.blocks) |block| {
        var instrs: std.ArrayList(Instr) = .empty;
        errdefer instrs.deinit(allocator);

        for (block.instrs) |instr| {
            if (instr.id) |id| {
                if (!instrHasSideEffects(instr) and !regIsUsed(function, id)) continue;
            }
            try instrs.append(allocator, instr);
        }

        try blocks.append(allocator, .{
            .id = block.id,
            .name = block.name,
            .instrs = try instrs.toOwnedSlice(allocator),
            .terminator = block.terminator,
        });
    }

    return .{
        .name = function.name,
        .params = function.params,
        .return_ty = function.return_ty,
        .error_ty = function.error_ty,
        .blocks = try blocks.toOwnedSlice(allocator),
        .extern_name = function.extern_name,
        .extern_lib = function.extern_lib,
        .inline_hint = function.inline_hint,
        .no_inline = function.no_inline,
        .no_return = function.no_return,
        .entry = function.entry,
        .naked = function.naked,
        .export_sym = function.export_sym,
    };
}

fn instrHasSideEffects(instr: Instr) bool {
    return switch (instr.kind) {
        .call, .call_indirect, .builtin, .inline_asm, .store_local, .global_store, .store, .alloc, .alloc_slice, .zone_push, .zone_pop, .zone_free => true,
        else => instr.id == null,
    };
}

fn regIsUsed(function: IrFunction, id: RegId) bool {
    for (function.blocks) |block| {
        for (block.instrs) |instr| {
            if (instrUsesReg(instr, id)) return true;
        }
        if (block.terminator) |terminator| {
            if (terminatorUsesReg(terminator, id)) return true;
        }
    }
    return false;
}

fn instrUsesReg(instr: Instr, id: RegId) bool {
    return switch (instr.kind) {
        .const_value, .alloc, .alloc_slice, .zone_push, .zone_pop, .global_load => false,
        .inline_asm => |ai| valuesUseReg(ai.args, id),
        .zone_free => |zf| valueUsesReg(zf.ptr, id),
        .unary => |unary| valueUsesReg(unary.value, id),
        .binary => |binary| valueUsesReg(binary.lhs, id) or valueUsesReg(binary.rhs, id),
        .cast => |cast| valueUsesReg(cast.value, id),
        .call => |call| valuesUseReg(call.args, id),
        .call_indirect => |call| valueUsesReg(call.callee, id) or valuesUseReg(call.args, id),
        .builtin => |builtin| valuesUseReg(builtin.args, id),
        .struct_lit => |strukt| for (strukt.fields) |field| {
            if (valueUsesReg(field.value, id)) break true;
        } else false,
        .variant_lit => |variant| variant.payload != null and valueUsesReg(variant.payload.?, id),
        .field, .field_addr => |field| valueUsesReg(field.base, id),
        .index, .index_addr => |index| valueUsesReg(index.base, id) or valueUsesReg(index.index, id),
        .slice_expr => |slice| valueUsesReg(slice.ptr, id) or valueUsesReg(slice.len, id),
        .variant_is, .variant_payload => |variant| valueUsesReg(variant.value, id),
        .optional_is_some, .optional_payload, .try_is_ok, .try_ok, .try_err, .try_payload, .iter_init, .iter_has_next, .iter_next => |value| valueUsesReg(value, id),
        .at => |at| valueUsesReg(at.value, id),
        .raw_pointer => |ptr| valueUsesReg(ptr.address, id),
        .interface_make => |make| valueUsesReg(make.data, id),
        .interface_data => |value| valueUsesReg(value, id),
        .interface_method => |method| valueUsesReg(method.value, id),
        .closure_make => |mk| valueUsesReg(mk.env, id),
        .closure_env_make => |mk| blk: {
            if (valueUsesReg(mk.arena, id)) break :blk true;
            for (mk.fields) |f| if (valueUsesReg(f.value, id)) break :blk true;
            break :blk false;
        },
        .closure_env_load => |ld| valueUsesReg(ld.env, id),
        .store_local => |store| valueUsesReg(store.value, id),
        .global_store => |store| valueUsesReg(store.value, id),
        .store => |store| valueUsesReg(store.target, id) or valueUsesReg(store.value, id),
    };
}

fn terminatorUsesReg(terminator: Terminator, id: RegId) bool {
    return switch (terminator) {
        .return_value => |value| value != null and valueUsesReg(value.?, id),
        .fail => |ft| valueUsesReg(ft.disc, id) or (ft.payload != null and valueUsesReg(ft.payload.?, id)),
        .panic, .branch, .unreachable_term => false,
        .cond_branch => |branch| valueUsesReg(branch.cond, id),
    };
}

fn valuesUseReg(values: []const Value, id: RegId) bool {
    for (values) |value| {
        if (valueUsesReg(value, id)) return true;
    }
    return false;
}

fn valueUsesReg(value: Value, id: RegId) bool {
    return switch (value) {
        .reg => |reg| reg == id,
        .param, .local, .global, .imm => false,
    };
}

fn lowerStruct(allocator: std.mem.Allocator, decl: ast.TypeDecl, strukt: ast.StructDecl, types: sema.TypeEnv, symbols: sema.SymbolTable) !StructDef {
    var fields: std.ArrayList(FieldDef) = .empty;
    errdefer fields.deinit(allocator);

    for (strukt.fields) |field| {
        try fields.append(allocator, .{
            .name = field.name,
            .ty = try lowerAstTypeWithEnv(allocator, field.ty, types, symbols),
        });
    }

    return .{
        .name = decl.name,
        .fields = try fields.toOwnedSlice(allocator),
        .is_packed = hasAttr(decl.attrs, "packed"),
        .alignment = alignAttr(decl.attrs),
    };
}

fn lowerEnumDef(allocator: std.mem.Allocator, decl: ast.TypeDecl, enum_decl: ast.EnumDecl) !VariantDef {
    var cases: std.ArrayList(VariantCase) = .empty;
    errdefer cases.deinit(allocator);
    for (enum_decl.variants) |v| {
        try cases.append(allocator, .{
            .name = v.name,
            .payload = if (v.payload) |p| try lowerType(allocator, p) else null,
        });
    }
    return .{ .name = decl.name, .variants = try cases.toOwnedSlice(allocator) };
}

fn lowerErrorDef(allocator: std.mem.Allocator, decl: ast.TypeDecl, error_decl: ast.ErrorDecl) !ErrorDef {
    var variants: std.ArrayList(ErrorCase) = .empty;
    errdefer variants.deinit(allocator);

    for (error_decl.variants) |variant| {
        try variants.append(allocator, .{
            .name = variant.name,
            .payload = if (variant.payload) |payload| try lowerType(allocator, payload) else null,
        });
    }

    return .{
        .name = decl.name,
        .variants = try variants.toOwnedSlice(allocator),
    };
}

fn lowerFunctionInstantiation(
    allocator: std.mem.Allocator,
    types: sema.TypeEnv,
    symbols: sema.SymbolTable,
    decl: ast.FunctionDecl,
    mangled_name: []const u8,
    type_args: []const sema.TypeArg,
    cvm: ?*ComptimeVm,
) !IrFunction {
    var params: std.ArrayList(IrParam) = .empty;
    errdefer params.deinit(allocator);

    for (decl.params) |param| {
        if (param.is_type_param) continue;
        try params.append(allocator, .{
            .name = param.name,
            .ty = lowerTypeWithBindingAndSymbols(allocator, param.ty, type_args, types, symbols) catch .unknown,
        });
    }
    const ret_ty = lowerTypeWithBindingAndSymbols(allocator, decl.return_ty, type_args, types, symbols) catch .unknown;

    const blocks = if (decl.body) |body| blk: {
        var lowerer = FunctionLowerer.init(allocator, types, symbols, decl);
        lowerer.cvm = cvm;
        lowerer.type_binding = type_args;
        // Without this the body lowers returns against `.void` and never wraps a
        // fallible return — generic `fn(...) -> T ! Err` then miscompiles.
        lowerer.current_return_ty = ret_ty;
        break :blk try lowerer.lowerBody(body);
    } else &.{};

    return .{
        .name = mangled_name,
        .params = try params.toOwnedSlice(allocator),
        .return_ty = ret_ty,
        // Propagate the error type so the backend lowers this instantiation as a
        // fallible `{ ok, err }` (was hardcoded null — broke `?`/`fail`/`catch`
        // and crashed callers that `?`-propagate a generic fallible result).
        .error_ty = if (decl.error_ty) |err| try lowerErrorSpec(allocator, err) else null,
        .blocks = blocks,
        .extern_name = null,
        .inline_hint = hasAttr(decl.attrs, "inline"),
        .no_inline = hasAttr(decl.attrs, "noinline"),
        .no_return = hasAttr(decl.attrs, "noreturn"),
        .entry = false,
        .naked = false,
        .export_sym = sema.exportSym(decl.attrs),
    };
}

fn lowerTypeWithBindingAndSymbols(allocator: std.mem.Allocator, ty: ast.TypeRef, binding: []const sema.TypeArg, types: sema.TypeEnv, symbols: sema.SymbolTable) !IrType {
    switch (ty) {
        .type_param => |tp| {
            for (binding) |arg| {
                if (std.mem.eql(u8, arg.name, tp.name))
                    return lowerSemaTypeWithEnv(allocator, arg.ty, types, symbols) catch .unknown;
            }
            return .unknown;
        },
        .named => |named| {
            for (binding) |arg| {
                if (std.mem.eql(u8, arg.name, named.name))
                    return lowerSemaTypeWithEnv(allocator, arg.ty, types, symbols) catch .unknown;
            }
            // Distinct type: substitute underlying type.
            if (symbols.resolve(symbols.root_scope, named.name)) |id| {
                if (types.distinct_types.get(id)) |underlying| {
                    return lowerSemaTypeWithEnv(allocator, underlying, types, symbols) catch .unknown;
                }
            }
            return lowerNamedType(named.name);
        },
        .pointer => |ptr| return .{ .ptr = try boxType(allocator, try lowerTypeWithBindingAndSymbols(allocator, ptr.inner.*, binding, types, symbols)) },
        .many_pointer => |ptr| return .{ .ptr = try boxType(allocator, try lowerTypeWithBindingAndSymbols(allocator, ptr.inner.*, binding, types, symbols)) },
        .optional => |opt| return .{ .optional = try boxType(allocator, try lowerTypeWithBindingAndSymbols(allocator, opt.inner.*, binding, types, symbols)) },
        .slice => |sl| return .{ .slice = try boxType(allocator, try lowerTypeWithBindingAndSymbols(allocator, sl.inner.*, binding, types, symbols)) },
        .borrow => |b| return lowerTypeWithBindingAndSymbols(allocator, b.inner.*, binding, types, symbols),
        .array => |arr| return .{ .array = .{
            .elem = try boxType(allocator, try lowerTypeWithBindingAndSymbols(allocator, arr.inner.*, binding, types, symbols)),
            .len = sema.resolveArrayLen(arr.len.*, types.const_ints),
        } },
        // `Box(T)` inside an instantiated generic body must resolve to the concrete
        // INSTANCE (`Box__T_i32`), not the template `Box` (whose `T`-typed fields are
        // opaque → invalid insertvalue / GEP). `mangleGenericInst` mirrors sema's
        // `instantiateConcrete`, resolving each arg through the binding.
        .generic_inst => |gi| {
            if (try mangleGenericInst(allocator, gi, binding, types, symbols)) |m|
                return .{ .struct_type = m };
            return lowerType(allocator, ty);
        },
        else => return lowerType(allocator, ty),
    }
}

fn lowerFunction(allocator: std.mem.Allocator, types: sema.TypeEnv, symbols: sema.SymbolTable, module: ast.Module, decl: ast.FunctionDecl, cvm: ?*ComptimeVm) !IrFunction {
    var params: std.ArrayList(IrParam) = .empty;
    errdefer params.deinit(allocator);

    // A lifted lambda takes a leading `__env: *u8` (the captured environment), so
    // every closure is called uniformly as `fn(env, args)`. The body looks params
    // up by name, so this extra leading param doesn't disturb the user params.
    if (std.mem.startsWith(u8, decl.name, "__lambda_")) {
        try params.append(allocator, .{ .name = "__env", .ty = .{ .ptr = try boxType(allocator, .void) } });
    }

    for (decl.params) |param| {
        if (param.is_type_param) continue;
        try params.append(allocator, .{
            .name = param.name,
            .ty = try lowerAstTypeWithEnv(allocator, param.ty, types, symbols),
        });
    }

    const return_ty = try lowerAstTypeWithEnv(allocator, decl.return_ty, types, symbols);
    const blocks = if (decl.body) |body| blk: {
        var lowerer = FunctionLowerer.init(allocator, types, symbols, decl);
        lowerer.module = module;
        lowerer.cvm = cvm;
        lowerer.current_return_ty = return_ty;
        break :blk try lowerer.lowerBody(body);
    } else &.{};

    // The IR/LLVM/VM name is the symbol's linkage name (module-qualified only on
    // a cross-module collision; bare otherwise).
    const link = linkNameFor(symbols, decl.file_name, decl.name);

    return .{
        .name = link,
        .params = try params.toOwnedSlice(allocator),
        .return_ty = return_ty,
        .error_ty = if (decl.error_ty) |err| try lowerErrorSpec(allocator, err) else null,
        .blocks = blocks,
        .extern_name = externName(decl.attrs),
        .extern_lib = externLibName(decl.attrs),
        .inline_hint = hasAttr(decl.attrs, "inline"),
        .no_inline = hasAttr(decl.attrs, "noinline"),
        .no_return = hasAttr(decl.attrs, "noreturn"),
        .entry = std.mem.eql(u8, decl.name, "main") or hasAttr(decl.attrs, "entry"),
        .naked = hasAttr(decl.attrs, "naked"),
        .export_sym = sema.exportSym(decl.attrs),
        .cold = hasAttr(decl.attrs, "cold"),
        .weak = hasAttr(decl.attrs, "weak"),
        .keep = hasAttr(decl.attrs, "keep"),
        .section = strAttrArg(decl.attrs, "section"),
        .link_name = strAttrArg(decl.attrs, "link_name"),
    };
}

/// The first string-literal argument of attribute `name` (e.g. `#section("x")`),
/// or null if the attribute is absent / has no string argument.
fn strAttrArg(attrs: []const ast.Attribute, name: []const u8) ?[]const u8 {
    for (attrs) |attr| {
        if (!std.mem.eql(u8, attr.name, name) or attr.args.len < 1) continue;
        return switch (attr.args[0].kind) {
            .string => |value| trimQuotes(value),
            else => null,
        };
    }
    return null;
}

fn lowerInterfaceMethod(
    allocator: std.mem.Allocator,
    types: sema.TypeEnv,
    symbols: sema.SymbolTable,
    module: ast.Module,
    impl: ast.InterfaceImpl,
    decl: ast.FunctionDecl,
    mangled_name: []const u8,
    cvm: ?*ComptimeVm,
) !IrFunction {
    var params: std.ArrayList(IrParam) = .empty;
    errdefer params.deinit(allocator);
    for (decl.params) |param| try params.append(allocator, .{
        .name = param.name,
        .ty = try lowerTypeReplacingSelf(allocator, param.ty, impl.type_name, types, symbols),
    });
    const return_ty = try lowerTypeReplacingSelf(allocator, decl.return_ty, impl.type_name, types, symbols);
    const blocks = if (decl.body) |body| blk: {
        var lowerer = FunctionLowerer.init(allocator, types, symbols, decl);
        lowerer.module = module;
        lowerer.cvm = cvm;
        lowerer.current_return_ty = return_ty;
        break :blk try lowerer.lowerBody(body);
    } else &.{};
    return .{
        .name = mangled_name,
        .params = try params.toOwnedSlice(allocator),
        .return_ty = return_ty,
        .error_ty = if (decl.error_ty) |err| try lowerErrorSpec(allocator, err) else null,
        .blocks = blocks,
        .extern_name = null,
        .inline_hint = false,
        .no_inline = false,
        .no_return = false,
        .entry = false,
        .naked = false,
        .export_sym = null,
    };
}

fn lowerTypeReplacingSelf(allocator: std.mem.Allocator, ty: ast.TypeRef, concrete_name: []const u8, types: sema.TypeEnv, symbols: sema.SymbolTable) !IrType {
    if (ty == .borrow) return lowerTypeReplacingSelf(allocator, ty.borrow.inner.*, concrete_name, types, symbols);
    // A pointer to a named interface type lowers to a fat interface pointer
    // ({ data: ptr, vtable: ptr }), not a thin pointer to the interface's
    // (nonexistent) struct layout — mirrors lowerAstTypeWithEnv.
    const ptr_inner_ast: ?ast.TypeRef = switch (ty) {
        .pointer => |p| p.inner.*,
        .many_pointer => |p| p.inner.*,
        else => null,
    };
    if (ptr_inner_ast) |inner_ty| switch (inner_ty) {
        .named => |named| if (!std.mem.eql(u8, named.name, "Self")) {
            if (symbols.resolve(symbols.root_scope, named.name)) |id| {
                if (types.layouts.get(id)) |layout| if (layout.kind == .interface_type)
                    return .{ .interface_value = named.name };
            }
        },
        else => {},
    };
    return switch (ty) {
        .named => |named| blk: {
            if (std.mem.eql(u8, named.name, "Self")) break :blk .{ .struct_type = concrete_name };
            if (symbols.resolve(symbols.root_scope, named.name)) |id| {
                if (types.distinct_types.get(id)) |underlying| {
                    break :blk lowerSemaTypeWithEnv(allocator, underlying, types, symbols) catch .unknown;
                }
            }
            break :blk lowerNamedType(named.name);
        },
        .pointer => |ptr| .{ .ptr = try boxType(allocator, try lowerTypeReplacingSelf(allocator, ptr.inner.*, concrete_name, types, symbols)) },
        .many_pointer => |ptr| .{ .ptr = try boxType(allocator, try lowerTypeReplacingSelf(allocator, ptr.inner.*, concrete_name, types, symbols)) },
        .optional => |opt| .{ .optional = try boxType(allocator, try lowerTypeReplacingSelf(allocator, opt.inner.*, concrete_name, types, symbols)) },
        .slice => |slice| .{ .slice = try boxType(allocator, try lowerTypeReplacingSelf(allocator, slice.inner.*, concrete_name, types, symbols)) },
        .borrow => |borrow| try lowerTypeReplacingSelf(allocator, borrow.inner.*, concrete_name, types, symbols),
        else => lowerType(allocator, ty),
    };
}

fn interfaceMethodName(allocator: std.mem.Allocator, type_name: []const u8, interface_name: []const u8, method_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ type_name, interface_name, method_name });
}

fn interfaceVTableName(allocator: std.mem.Allocator, type_name: []const u8, interface_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}.vtable", .{ type_name, interface_name });
}

const LoopContext = struct {
    cond_id: BlockId,
    continue_id: BlockId,
    after_id: BlockId,
    zone_depth: usize,
    defer_floor: usize,
};

const DeferPath = enum {
    ok,
    err,
};

fn deferRunsOn(mode: ast.DeferMode, path: DeferPath) bool {
    return switch (mode) {
        .always => true,
        .ok => path == .ok,
        .err => path == .err,
    };
}

const FunctionLowerer = struct {
    allocator: std.mem.Allocator,
    types: sema.TypeEnv,
    symbols: sema.SymbolTable,
    params: []const ast.Param,
    file_name: []const u8,
    source: []const u8,
    /// Name of the function being lowered, for `core::func`. "" when unknown
    /// (where/insert/synthetic lowerers).
    fn_name: []const u8 = "",
    blocks: std.ArrayList(IrBlock) = .empty,
    current_instrs: std.ArrayList(Instr) = .empty,
    current_id: BlockId = 0,
    current_name: []const u8 = "entry",
    current_terminated: bool = false,
    next_reg: RegId = 1,
    next_block_id: BlockId = 1,
    temp_id: u32 = 0,
    loop_stack: std.ArrayList(LoopContext) = .empty,
    local_types: std.StringHashMap(IrType),
    current_return_ty: IrType = .void,
    active_zones: std.ArrayList([]const u8) = .empty,
    defers: std.ArrayList(ast.DeferStmt) = .empty,
    type_binding: []const sema.TypeArg = &.{},
    /// True while lowering a `where { … }` predicate: a `reject(msg)` call
    /// terminates with `return msg` (the predicate returns the rejection message,
    /// or "" to accept).
    in_where: bool = false,
    /// True while lowering a `where` block to *compute an output type param*
    /// (`-> $Acc`): an `Acc = <type>` assignment terminates with `return <id>`,
    /// the node id of the right-hand type expression (sema resolves it back to a
    /// type). The predicate thus returns which type-expr the branch selected.
    in_where_type: bool = false,
    /// Output type param names (`-> $Acc`) for the `where` block being lowered.
    /// Assignments to these are handled specially in both `where` modes.
    where_output_params: []const []const u8 = &.{},
    module: ast.Module = .empty(""),
    /// VM-backed comptime evaluator for `#run`, or null to use the tree-walker.
    cvm: ?*ComptimeVm = null,
    /// Source name → its currently-active unique IR name, populated only when a
    /// name is re-declared with an incompatible type in a sibling/enclosing scope
    /// (e.g. two match arms each binding `i`). The backend keys locals by name with
    /// one alloca per name, so colliding names must get distinct IR slots. The map
    /// is snapshotted/restored around blocks and match arms (lexical scoping).
    local_alias: std.StringHashMap([]const u8),
    shadow_counter: u32 = 0,
    /// When lowering a lifted lambda body, the variables it captures (in env
    /// order). A reference to one reads field `index` out of the `__env` pointer.
    lambda_captures: []const sema.Capture = &.{},

    fn init(allocator: std.mem.Allocator, types: sema.TypeEnv, symbols: sema.SymbolTable, decl: ast.FunctionDecl) FunctionLowerer {
        const captures: []const sema.Capture = if (std.mem.startsWith(u8, decl.name, "__lambda_"))
            types.lambda_captures.get(linkNameFor(symbols, decl.file_name, decl.name)) orelse &.{}
        else
            &.{};
        return .{
            .allocator = allocator,
            .types = types,
            .symbols = symbols,
            .params = decl.params,
            .file_name = decl.file_name,
            .source = decl.source,
            .fn_name = decl.name,
            .local_types = std.StringHashMap(IrType).init(allocator),
            .local_alias = std.StringHashMap([]const u8).init(allocator),
            .lambda_captures = captures,
        };
    }

    /// The active IR slot name for a source local (identity unless it was renamed
    /// to dodge a same-name/incompatible-type collision in another scope).
    fn curLocal(self: *FunctionLowerer, name: []const u8) []const u8 {
        return self.local_alias.get(name) orelse name;
    }

    /// Register a user local/binding and return the IR name to store it under.
    /// Reuses the existing slot for a compatible re-declaration; allocates a fresh
    /// uniquely-suffixed slot (aliased for this scope) when the live local of the
    /// same name has an incompatible type, so the two never share one alloca.
    fn declareLocal(self: *FunctionLowerer, name: []const u8, ty: IrType) LowerError![]const u8 {
        const cur = self.curLocal(name);
        if (self.local_types.get(cur)) |old| {
            if (sameLocalType(old, ty)) return cur;
            const uniq = try std.fmt.allocPrint(self.allocator, "{s}#{d}", .{ name, self.shadow_counter });
            self.shadow_counter += 1;
            try self.local_alias.put(name, uniq);
            try self.local_types.put(uniq, ty);
            return uniq;
        }
        try self.local_types.put(name, ty);
        return name;
    }

    /// Conservative same-slot test: two locals share an alloca only when proven
    /// the same shape. Unknowns default to "different" (a fresh slot is always safe).
    fn sameLocalType(a: IrType, b: IrType) bool {
        const Tag = std.meta.Tag(IrType);
        if (@as(Tag, a) != @as(Tag, b)) return false;
        return switch (a) {
            .i => |bits| bits == b.i,
            .u => |bits| bits == b.u,
            .f32, .f64, .bool, .void, .usize, .isize, .addr, .byte, .rune, .ptr, .slice, .text => true,
            .struct_type => |n| std.mem.eql(u8, n, b.struct_type),
            .variant_type => |n| std.mem.eql(u8, n, b.variant_type),
            else => false,
        };
    }

    /// Save the current local-alias map so a nested lexical scope's renames can be
    /// undone on exit (`leaveScope`). Cheap when no collisions are active (the map
    /// is empty, which is the overwhelming common case).
    fn enterScope(self: *FunctionLowerer) LowerError!std.StringHashMap([]const u8) {
        return self.local_alias.clone();
    }

    fn leaveScope(self: *FunctionLowerer, saved: std.StringHashMap([]const u8)) void {
        self.local_alias.deinit();
        self.local_alias = saved;
    }

    fn lowerBody(self: *FunctionLowerer, body: ast.Block) LowerError![]const IrBlock {
        // Void functions fall through to ret void; non-void to unreachable
        // (sema already validated non-void functions have explicit returns).
        const fallthrough: Terminator = if (self.current_return_ty == .void)
            .{ .return_value = null }
        else
            .unreachable_term;
        try self.lowerBlock(body.statements, fallthrough);
        return self.blocks.toOwnedSlice(self.allocator);
    }

    // ── `zone X: Arena {}` desugar ─────────────────────────────────────────
    // A zone handle is a real `std.heap.Arena`. Entering a zone is `X := make()`;
    // every exit path runs `deinit(&X)`. The body's `X.method(...)` calls already
    // lowered as ordinary UFCS/extension calls (sema resolved them against the
    // Arena type), so the handle just needs to be a real Arena local here.
    fn lowerZoneEnter(self: *FunctionLowerer, name: []const u8) LowerError!void {
        const arena_ty: IrType = .{ .struct_type = "Arena" };
        const made = try self.emit(arena_ty, .{ .call = .{ .callee = "make", .args = &.{} } });
        try self.local_types.put(name, arena_ty);
        try self.emitNoResult(arena_ty, .{ .store_local = .{ .name = name, .value = made } });
    }

    fn lowerZoneExit(self: *FunctionLowerer, name: []const u8) LowerError!void {
        const arena_ty: IrType = .{ .struct_type = "Arena" };
        const ptr_ty: IrType = .{ .ptr = try boxType(self.allocator, arena_ty) };
        const addr = try self.emit(ptr_ty, .{ .unary = .{ .op = .ref, .value = .{ .local = name } } });
        const args = try self.allocator.dupe(Value, &[_]Value{addr});
        try self.emitNoResult(.void, .{ .call = .{ .callee = "deinit", .args = args } });
    }

    fn lowerStmt(self: *FunctionLowerer, stmt: ast.Stmt) LowerError!void {
        switch (stmt) {
            .local_infer => |local| {
                const value = try self.lowerExpr(local.value);
                const local_ty = self.exprType(local.value);
                const ir_name = try self.declareLocal(local.name, local_ty);
                try self.emitNoResult(local_ty, .{ .store_local = .{ .name = ir_name, .value = value } });
            },
            .local_typed => |local| {
                // Inside a generic instantiation, substitute the binding so
                // `total: T` gets the concrete type (T → i32), not the
                // unsubstituted param (which lowers to `unknown`/`ptr` and breaks
                // the return type). Outside generics, keep the env lowering, which
                // handles `Self`/aliases the binding-aware path doesn't.
                const local_ty = if (self.type_binding.len > 0)
                    try lowerTypeWithBindingAndSymbols(self.allocator, local.ty, self.type_binding, self.types, self.symbols)
                else
                    try lowerAstTypeWithEnv(self.allocator, local.ty, self.types, self.symbols);
                const value = try self.lowerExprAs(local.value, local_ty);
                const ir_name = try self.declareLocal(local.name, local_ty);
                try self.emitNoResult(local_ty, .{ .store_local = .{ .name = ir_name, .value = value } });
            },
            .assign => |assign| {
                // Output-type-param assignment (`Acc = <type>`) inside a `where`.
                if (assign.target.kind == .ident and nameInList(assign.target.kind.ident, self.where_output_params)) {
                    if (self.in_where_type) {
                        // Return the node id of the selected type expression; sema
                        // resolves it back to a concrete type for this instantiation.
                        try self.terminate(.{ .return_value = .{ .imm = .{ .uint = @intCast(assign.value.id) } } });
                    }
                    // In reject mode (or once terminated) the assignment is a no-op:
                    // computing the output type is the type-eval's job, not this one.
                    return;
                }
                const value = try self.lowerExprAs(assign.value, self.exprType(assign.target));
                const bin_op = assignBinOp(assign.op);
                switch (assign.target.kind) {
                    .ident => |name| {
                        const ir_name = self.curLocal(name);
                        // A name that isn't a local but resolves to a mutable
                        // top-level global stores through the global directly.
                        const gvar: ?[]const u8 = if (self.local_types.contains(ir_name)) null else gv: {
                            if (resolveTopLevel(self.symbols, self.file_name, name)) |id| {
                                if (self.symbols.symbol(id).kind == .global_var) break :gv self.symbols.symbol(id).link_name;
                            }
                            break :gv null;
                        };
                        if (gvar) |link| {
                            if (bin_op) |op| {
                                const current: Value = .{ .global = link };
                                const result = try self.emitAt(self.exprType(assign.target), .{ .binary = .{ .op = op, .lhs = current, .rhs = value } }, assign.span);
                                try self.emitNoResult(self.exprType(assign.target), .{ .global_store = .{ .name = link, .value = result } });
                            } else {
                                try self.emitNoResult(self.exprType(assign.target), .{ .global_store = .{ .name = link, .value = value } });
                            }
                        } else if (bin_op) |op| {
                            const current: Value = .{ .local = ir_name };
                            const result = try self.emitAt(self.exprType(assign.target), .{ .binary = .{ .op = op, .lhs = current, .rhs = value } }, assign.span);
                            try self.emitNoResult(self.exprType(assign.target), .{ .store_local = .{ .name = ir_name, .value = result } });
                        } else {
                            try self.emitNoResult(self.exprType(assign.target), .{ .store_local = .{ .name = ir_name, .value = value } });
                        }
                    },
                    else => {
                        const target = try self.lowerLValueAddress(assign.target);
                        if (bin_op) |op| {
                            const current = try self.emitAt(self.exprType(assign.target), .{ .unary = .{ .op = .deref, .value = target } }, assign.span);
                            const result = try self.emitAt(self.exprType(assign.target), .{ .binary = .{ .op = op, .lhs = current, .rhs = value } }, assign.span);
                            try self.emitNoResult(self.exprType(assign.target), .{ .store = .{ .target = target, .value = result } });
                        } else {
                            try self.emitNoResult(self.exprType(assign.target), .{ .store = .{ .target = target, .value = value } });
                        }
                    },
                }
            },
            .return_stmt => |ret| {
                const ret_val: ?Value = if (ret.value) |value| try self.lowerExprAs(value, self.current_return_ty) else null;
                try self.emitDefersDown(0, .ok);
                var i = self.active_zones.items.len;
                while (i > 0) {
                    i -= 1;
                    try self.lowerZoneExit(self.active_zones.items[i]);
                }
                try self.terminate(.{ .return_value = ret_val });
            },
            .fail_stmt => |fail| {
                var payload_values = std.ArrayList(Value).empty;
                errdefer payload_values.deinit(self.allocator);
                for (fail.payload) |payload| try payload_values.append(self.allocator, try self.lowerExpr(payload));
                const payloads = try payload_values.toOwnedSlice(self.allocator);
                const error_value = try self.emit(.{ .variant_type = "<error>" }, .{ .builtin = .{
                    .name = try std.fmt.allocPrint(self.allocator, "error.{s}", .{fail.variant}),
                    .args = payloads,
                } });
                try self.emitDefersDown(0, .err);
                var i = self.active_zones.items.len;
                while (i > 0) {
                    i -= 1;
                    try self.lowerZoneExit(self.active_zones.items[i]);
                }
                // Carry the first payload (if any) so a `catch` can recover it.
                try self.terminate(.{ .fail = .{ .disc = error_value, .payload = if (payloads.len > 0) payloads[0] else null } });
            },
            .if_stmt => |iff| try self.lowerIf(iff),
            .while_stmt => |while_stmt| try self.lowerWhile(while_stmt),
            .for_range => |for_stmt| try self.lowerForRange(for_stmt),
            .for_slice => |for_stmt| try self.lowerForSlice(for_stmt),
            .match_stmt => |m| try self.lowerMatch(m),
            // Compile-time if: evaluate condition NOW; only emit the live branch.
            .comptime_if => |ci| blk: {
                const live_block = self.evalComptimeIf(ci) orelse {
                    // Could not evaluate at compile time — emit as runtime if.
                    try self.lowerIf(.{
                        .binding = null,
                        .payload_binding = null,
                        .condition = ci.condition,
                        .then_block = ci.then_block,
                        .else_block = ci.else_block,
                        .span = ci.span,
                    });
                    break :blk;
                };
                try self.lowerBlock(live_block.statements, null);
                break :blk;
            },
            .comptime_run => |block| try self.lowerBlock(block.statements, null),
            // `#insert <literal #quote { ... }>` — splice the quoted block's
            // statements inline (sema already re-checked them in this scope).
            .insert_stmt => |ins| switch (ins.operand.kind) {
                .quote => |block| try self.lowerBlock(block.statements, null),
                // A computed operand (`#insert #run gen()`) is resolved by the
                // two-pass pipeline BEFORE final lowering. During the ComptimeVm
                // cache build (cvm == null) it may still be present — skip it so
                // the rest of the module reaches the cache; the cached copy of
                // this function is never the one that gets compiled.
                else => if (self.cvm != null) return error.LoweringFailed,
            },
            // Expanded away by the macroexpand pass before lowering.
            .comptime_for => return error.LoweringFailed,
            .zone_block => |zb| {
                try self.lowerZoneEnter(zb.name);
                try self.active_zones.append(self.allocator, zb.name);
                try self.lowerBlock(zb.body.statements, null);
                _ = self.active_zones.pop();
                if (!self.current_terminated) {
                    try self.lowerZoneExit(zb.name);
                }
            },
            .defer_stmt => |ds| try self.defers.append(self.allocator, ds),
            .unsafe_block => |block| try self.lowerBlock(block.statements, null),
            .break_stmt => {
                const ctx = self.loop_stack.items[self.loop_stack.items.len - 1];
                try self.emitDefersDown(ctx.defer_floor, .ok);
                var i = self.active_zones.items.len;
                while (i > ctx.zone_depth) {
                    i -= 1;
                    try self.lowerZoneExit(self.active_zones.items[i]);
                }
                try self.terminate(.{ .branch = ctx.after_id });
            },
            .continue_stmt => {
                const ctx = self.loop_stack.items[self.loop_stack.items.len - 1];
                try self.emitDefersDown(ctx.defer_floor, .ok);
                var i = self.active_zones.items.len;
                while (i > ctx.zone_depth) {
                    i -= 1;
                    try self.lowerZoneExit(self.active_zones.items[i]);
                }
                try self.terminate(.{ .branch = ctx.continue_id });
            },
            .expr => |expr| _ = try self.lowerExpr(expr),
        }
    }

    fn lowerIf(self: *FunctionLowerer, iff: ast.IfStmt) LowerError!void {
        var optional_binding_name: ?[]const u8 = null;
        var optional_binding_value: ?Value = null;
        var optional_payload_ty: ?IrType = null;
        // `if e == .variant |c|` inside a catch: bind c to the stashed payload.
        var error_payload_binding: ?[]const u8 = null;

        const cond = if (iff.binding) |binding| blk: {
            const value = try self.lowerExpr(binding.value);
            const value_ty = self.exprType(binding.value);
            switch (value_ty) {
                .optional => |inner| {
                    optional_binding_name = binding.name;
                    optional_binding_value = value;
                    optional_payload_ty = inner.*;
                    break :blk try self.emit(.bool, .{ .optional_is_some = value });
                },
                else => {
                    const ir_name = try self.declareLocal(binding.name, value_ty);
                    try self.emitNoResult(value_ty, .{ .store_local = .{ .name = ir_name, .value = value } });
                    break :blk value;
                },
            }
        } else blk: {
            const value = try self.lowerExpr(iff.condition);
            const value_ty = self.exprType(iff.condition);
            if (iff.payload_binding) |payload_name| switch (value_ty) {
                .optional => |inner| {
                    optional_binding_name = payload_name;
                    optional_binding_value = value;
                    optional_payload_ty = inner.*;
                    break :blk try self.emit(.bool, .{ .optional_is_some = value });
                },
                // `if e == .variant |c|`: the condition is the discriminant
                // comparison (bool); bind c to the payload stashed by `catch`.
                else => if (iff.condition.kind == .binary and iff.condition.kind.binary.op == .equal) {
                    error_payload_binding = payload_name;
                },
            };
            break :blk value;
        };

        const then_id = self.allocBlockId();
        const else_id = if (iff.else_block != null) self.allocBlockId() else null;
        const after_id = self.allocBlockId();
        try self.terminate(.{ .cond_branch = .{
            .cond = cond,
            .then_block = then_id,
            .else_block = else_id orelse after_id,
        } });

        self.startBlock(then_id, "if.then");
        // The `if … |x|` payload binding is only in scope in the then-block — scope
        // its alias so reusing the name in a sibling `if` (with a different type)
        // gets its own slot rather than aliasing.
        const then_scope = try self.enterScope();
        if (optional_binding_name) |name| {
            const opt_value = optional_binding_value.?;
            const payload_ty = optional_payload_ty.?;
            const payload = try self.emit(payload_ty, .{ .optional_payload = opt_value });
            const ir_name = try self.declareLocal(name, payload_ty);
            try self.emitNoResult(payload_ty, .{ .store_local = .{ .name = ir_name, .value = payload } });
        }
        if (error_payload_binding) |name| {
            const pty = self.local_types.get("__errpayload") orelse .unknown;
            const ir_name = try self.declareLocal(name, pty);
            try self.emitNoResult(pty, .{ .store_local = .{ .name = ir_name, .value = .{ .local = "__errpayload" } } });
        }
        try self.lowerBlock(iff.then_block.statements, .{ .branch = after_id });
        self.leaveScope(then_scope);

        if (iff.else_block) |else_block| {
            self.startBlock(else_id.?, "if.else");
            try self.lowerBlock(else_block.statements, .{ .branch = after_id });
        }

        self.startBlock(after_id, "if.after");
    }

    fn lowerWhile(self: *FunctionLowerer, while_stmt: ast.WhileStmt) LowerError!void {
        const cond_id = self.allocBlockId();
        const body_id = self.allocBlockId();
        const after_id = self.allocBlockId();

        try self.loop_stack.append(self.allocator, .{
            .cond_id = cond_id,
            .continue_id = cond_id,
            .after_id = after_id,
            .zone_depth = self.active_zones.items.len,
            .defer_floor = self.defers.items.len,
        });

        try self.terminate(.{ .branch = cond_id });

        self.startBlock(cond_id, "while.cond");
        const value = try self.lowerExpr(while_stmt.condition);
        const value_ty = self.exprType(while_stmt.condition);
        // `while opt |x|`: loop while the optional is non-null; the payload value
        // computed here dominates the body, so we unwrap it there.
        var payload_value: ?Value = null;
        var payload_ty: ?IrType = null;
        const cond = switch (value_ty) {
            .optional => |inner| blk: {
                payload_value = value;
                payload_ty = inner.*;
                break :blk try self.emit(.bool, .{ .optional_is_some = value });
            },
            else => value,
        };
        try self.terminate(.{ .cond_branch = .{
            .cond = cond,
            .then_block = body_id,
            .else_block = after_id,
        } });

        self.startBlock(body_id, "while.body");
        const body_scope = try self.enterScope();
        if (while_stmt.payload_binding) |name| {
            const payload = try self.emit(payload_ty.?, .{ .optional_payload = payload_value.? });
            const ir_name = try self.declareLocal(name, payload_ty.?);
            try self.emitNoResult(payload_ty.?, .{ .store_local = .{ .name = ir_name, .value = payload } });
        }
        try self.lowerBlock(while_stmt.body.statements, .{ .branch = cond_id });
        self.leaveScope(body_scope);

        _ = self.loop_stack.pop();
        self.startBlock(after_id, "while.after");
    }

    fn lowerForRange(self: *FunctionLowerer, for_stmt: ast.ForRangeStmt) LowerError!void {
        const loop_ty = self.exprType(for_stmt.start);
        const suffix = self.next_block_id;
        const end_name = try std.fmt.allocPrint(self.allocator, "__for_end_{d}", .{suffix});

        try self.emitNoResult(loop_ty, .{ .store_local = .{
            .name = for_stmt.binding,
            .value = try self.lowerExpr(for_stmt.start),
        } });
        try self.emitNoResult(loop_ty, .{ .store_local = .{
            .name = end_name,
            .value = try self.lowerExpr(for_stmt.end),
        } });

        const cond_id = self.allocBlockId();
        const body_id = self.allocBlockId();
        const increment_id = self.allocBlockId();
        const after_id = self.allocBlockId();
        try self.loop_stack.append(self.allocator, .{
            .cond_id = cond_id,
            .continue_id = increment_id,
            .after_id = after_id,
            .zone_depth = self.active_zones.items.len,
            .defer_floor = self.defers.items.len,
        });

        try self.terminate(.{ .branch = cond_id });
        self.startBlock(cond_id, "for.range.cond");
        const cond = try self.emit(.bool, .{ .binary = .{
            .op = if (for_stmt.inclusive) .le else .lt,
            .lhs = .{ .local = for_stmt.binding },
            .rhs = .{ .local = end_name },
        } });
        try self.terminate(.{ .cond_branch = .{
            .cond = cond,
            .then_block = body_id,
            .else_block = after_id,
        } });

        self.startBlock(body_id, "for.range.body");
        try self.lowerBlock(for_stmt.body.statements, .{ .branch = increment_id });

        self.startBlock(increment_id, "for.range.increment");
        const next = try self.emit(loop_ty, .{ .binary = .{
            .op = .add,
            .lhs = .{ .local = for_stmt.binding },
            .rhs = .{ .imm = .{ .int = 1 } },
        } });
        try self.emitNoResult(loop_ty, .{ .store_local = .{ .name = for_stmt.binding, .value = next } });
        try self.terminate(.{ .branch = cond_id });

        _ = self.loop_stack.pop();
        self.startBlock(after_id, "for.range.after");
    }

    fn lowerForSlice(self: *FunctionLowerer, for_stmt: ast.ForSliceStmt) LowerError!void {
        // `for x in it` over an iterator (sema recorded its `next` method) lowers
        // to a `while it.next() |x|` loop rather than slice indexing.
        if (self.types.iterator_fors.get(for_stmt.iter.id)) |next_sym| {
            return self.lowerForIterator(for_stmt, next_sym);
        }
        const iter_ty = self.exprType(for_stmt.iter);
        const elem_ty: IrType = switch (iter_ty) {
            .slice => |elem| elem.*,
            .array => |array| array.elem.*,
            else => .unknown,
        };
        const binding_ty: IrType = if (for_stmt.by_ref)
            .{ .ptr = try boxType(self.allocator, elem_ty) }
        else
            elem_ty;
        const suffix = self.next_block_id;
        const iter_name = try std.fmt.allocPrint(self.allocator, "__for_iter_{d}", .{suffix});
        const index_name = try std.fmt.allocPrint(self.allocator, "__for_index_{d}", .{suffix});

        try self.emitNoResult(iter_ty, .{ .store_local = .{
            .name = iter_name,
            .value = try self.lowerExpr(for_stmt.iter),
        } });
        try self.emitNoResult(.usize, .{ .store_local = .{
            .name = index_name,
            .value = .{ .imm = .{ .uint = 0 } },
        } });

        const cond_id = self.allocBlockId();
        const body_id = self.allocBlockId();
        const increment_id = self.allocBlockId();
        const after_id = self.allocBlockId();
        try self.loop_stack.append(self.allocator, .{
            .cond_id = cond_id,
            .continue_id = increment_id,
            .after_id = after_id,
            .zone_depth = self.active_zones.items.len,
            .defer_floor = self.defers.items.len,
        });

        try self.terminate(.{ .branch = cond_id });
        self.startBlock(cond_id, "for.slice.cond");
        const len: Value = switch (iter_ty) {
            .array => |array| .{ .imm = .{ .uint = array.len } },
            else => try self.emit(.usize, .{ .field = .{ .base = .{ .local = iter_name }, .name = "len" } }),
        };
        const cond = try self.emit(.bool, .{ .binary = .{
            .op = .lt,
            .lhs = .{ .local = index_name },
            .rhs = len,
        } });
        try self.terminate(.{ .cond_branch = .{
            .cond = cond,
            .then_block = body_id,
            .else_block = after_id,
        } });

        self.startBlock(body_id, "for.slice.body");
        const item = if (for_stmt.by_ref)
            try self.emit(binding_ty, .{ .index_addr = .{
                .base = .{ .local = iter_name },
                .index = .{ .local = index_name },
            } })
        else
            try self.emit(elem_ty, .{ .index = .{
                .base = .{ .local = iter_name },
                .index = .{ .local = index_name },
            } });
        try self.emitNoResult(binding_ty, .{ .store_local = .{ .name = for_stmt.binding, .value = item } });
        if (for_stmt.index_binding) |name| {
            try self.emitNoResult(.usize, .{ .store_local = .{ .name = name, .value = .{ .local = index_name } } });
        }
        try self.lowerBlock(for_stmt.body.statements, .{ .branch = increment_id });

        self.startBlock(increment_id, "for.slice.increment");
        const next = try self.emit(.usize, .{ .binary = .{
            .op = .add,
            .lhs = .{ .local = index_name },
            .rhs = .{ .imm = .{ .uint = 1 } },
        } });
        try self.emitNoResult(.usize, .{ .store_local = .{ .name = index_name, .value = next } });
        try self.terminate(.{ .branch = cond_id });

        _ = self.loop_stack.pop();
        self.startBlock(after_id, "for.slice.after");
    }

    /// `for x in it` over an iterator: store `it` in a local, then each iteration
    /// call `next(&it) -> ?T`, break on null, bind the payload to `x`. This is the
    /// same shape as `while it.next() |x|`.
    fn lowerForIterator(self: *FunctionLowerer, for_stmt: ast.ForSliceStmt, next_sym: sema.SymbolId) LowerError!void {
        const sig = self.types.fn_sigs.get(next_sym) orelse return error.LoweringFailed;
        const ret_ir = try lowerSemaTypeWithEnv(self.allocator, sig.return_ty, self.types, self.symbols);
        const elem_ir: IrType = switch (ret_ir) {
            .optional => |p| p.*,
            else => .unknown,
        };
        const next_link = self.symbols.symbol(next_sym).link_name;
        const iter_ty = self.exprType(for_stmt.iter);

        const suffix = self.next_block_id;
        const iter_name = try std.fmt.allocPrint(self.allocator, "__for_iter_{d}", .{suffix});
        const index_name = try std.fmt.allocPrint(self.allocator, "__for_index_{d}", .{suffix});

        // Hold the iterator in a local so `&it` is stable and `next` advances it.
        try self.emitNoResult(iter_ty, .{ .store_local = .{
            .name = iter_name,
            .value = try self.lowerExpr(for_stmt.iter),
        } });
        if (for_stmt.index_binding != null) {
            try self.emitNoResult(.usize, .{ .store_local = .{ .name = index_name, .value = .{ .imm = .{ .uint = 0 } } } });
        }

        const cond_id = self.allocBlockId();
        const body_id = self.allocBlockId();
        const incr_id = self.allocBlockId();
        const after_id = self.allocBlockId();
        try self.loop_stack.append(self.allocator, .{
            .cond_id = cond_id,
            .continue_id = incr_id,
            .after_id = after_id,
            .zone_depth = self.active_zones.items.len,
            .defer_floor = self.defers.items.len,
        });

        try self.terminate(.{ .branch = cond_id });
        self.startBlock(cond_id, "for.iter.cond");
        const recv = try self.emit(.{ .ptr = try boxType(self.allocator, iter_ty) }, .{ .unary = .{ .op = .ref, .value = .{ .local = iter_name } } });
        const opt = try self.emit(ret_ir, .{ .call = .{ .callee = next_link, .args = try self.allocator.dupe(Value, &.{recv}) } });
        const cond = try self.emit(.bool, .{ .optional_is_some = opt });
        try self.terminate(.{ .cond_branch = .{ .cond = cond, .then_block = body_id, .else_block = after_id } });

        self.startBlock(body_id, "for.iter.body");
        const payload = try self.emit(elem_ir, .{ .optional_payload = opt });
        try self.emitNoResult(elem_ir, .{ .store_local = .{ .name = for_stmt.binding, .value = payload } });
        if (for_stmt.index_binding) |name| {
            try self.emitNoResult(.usize, .{ .store_local = .{ .name = name, .value = .{ .local = index_name } } });
        }
        try self.lowerBlock(for_stmt.body.statements, .{ .branch = incr_id });

        self.startBlock(incr_id, "for.iter.incr");
        if (for_stmt.index_binding != null) {
            const nx = try self.emit(.usize, .{ .binary = .{ .op = .add, .lhs = .{ .local = index_name }, .rhs = .{ .imm = .{ .uint = 1 } } } });
            try self.emitNoResult(.usize, .{ .store_local = .{ .name = index_name, .value = nx } });
        }
        try self.terminate(.{ .branch = cond_id });

        _ = self.loop_stack.pop();
        self.startBlock(after_id, "for.iter.after");
    }

    // ── Materialization: quoted AST → ast.* construction IR ──────────────────
    // `#quote(expr)` / `#quote { ... }` become real `AstExpr`/`AstBlock` values
    // the VM can build, `match` on, and the reifier can turn back into AST.

    fn mkVariant(self: *FunctionLowerer, type_name: []const u8, variant: []const u8, payload: ?Value) LowerError!Value {
        return self.emit(.{ .variant_type = type_name }, .{ .variant_lit = .{
            .type_name = type_name,
            .variant = variant,
            .payload = payload,
        } });
    }

    fn mkStruct(self: *FunctionLowerer, ty_name: []const u8, fields: []const StructFieldValue) LowerError!Value {
        return self.emit(.{ .struct_type = ty_name }, .{ .struct_lit = .{
            .ty_name = ty_name,
            .fields = try self.allocator.dupe(StructFieldValue, fields),
        } });
    }

    fn astStr(text: []const u8) Value {
        return .{ .imm = .{ .text = text } };
    }

    /// A short kind name for types `TypeInfo` doesn't model in detail (`fn`,
    /// `interface`, …) — the payload of the `other` variant.
    fn typeInfoKindName(ty: IrType) []const u8 {
        return switch (ty) {
            .fn_ptr => "fn",
            .interface_value => "interface",
            .fallible => "fallible",
            .opaque_type => "opaque",
            .list => "list",
            .map => "map",
            .range => "range",
            .zone => "zone",
            else => "other",
        };
    }

    /// Phase 3: materialize the module's top-level declarations into a `[]Decl`
    /// slice the comptime VM can iterate (`Decl{ name, kind }`). Backs the
    /// `compiler_decls()` introspection builtin. Skips anonymous items (imports,
    /// impls) and the injected prelude types (`Decl`, `Ast*`).
    fn lowerCompilerDecls(self: *FunctionLowerer) LowerError!Value {
        var elems: std.ArrayList(Value) = .empty;
        defer elems.deinit(self.allocator);
        for (self.module.items) |item| {
            const nm = item.name() orelse continue;
            if (isPreludeDeclName(nm)) continue;
            // Only the program's OWN declarations — not types pulled in by an
            // `#import` (a hook that imports std for its codegen shouldn't see
            // `std.heap.Chunk` etc.). Generated decls share the root file name.
            if (!std.mem.eql(u8, item.fileName(), self.module.file_name)) continue;
            const v = try self.mkStruct("Decl", &.{
                .{ .name = "name", .value = astStr(nm) },
                .{ .name = "kind", .value = astStr(declKindName(item)) },
                .{ .name = "fields", .value = try self.lowerDeclFields(item) },
                .{ .name = "ret", .value = try self.lowerDeclRet(item) },
                .{ .name = "body", .value = astStr(declBodyText(item)) },
                .{ .name = "derives", .value = astStr(try declDerives(self.allocator, item)) },
            });
            try elems.append(self.allocator, v);
        }
        return self.materializeSlice(.{ .struct_type = "Decl" }, elems.items);
    }

    fn mkCField(self: *FunctionLowerer, name: []const u8, type_name: []const u8) LowerError!Value {
        return self.mkStruct("CField", &.{
            .{ .name = "name", .value = astStr(name) },
            .{ .name = "type_name", .value = astStr(type_name) },
        });
    }

    /// `Decl.fields` — a struct's fields, an enum's variants (`type_name` = the
    /// payload type, "" if none), or a fn's parameters; empty otherwise.
    fn lowerDeclFields(self: *FunctionLowerer, item: ast.Item) LowerError!Value {
        var fs: std.ArrayList(Value) = .empty;
        defer fs.deinit(self.allocator);
        switch (item) {
            .type_decl => |t| switch (t.kind) {
                .struct_type => |s| for (s.fields) |f| {
                    try fs.append(self.allocator, try self.mkCField(f.name, astTypeName(self.allocator, f.ty)));
                },
                .enum_type => |e| for (e.variants) |vrt| {
                    const pn = if (vrt.payload) |p| astTypeName(self.allocator, p) else "";
                    try fs.append(self.allocator, try self.mkCField(vrt.name, pn));
                },
                else => {},
            },
            .function => |fnd| for (fnd.params) |p| {
                try fs.append(self.allocator, try self.mkCField(p.name, astTypeName(self.allocator, p.ty)));
            },
            else => {},
        }
        return self.materializeSlice(.{ .struct_type = "CField" }, fs.items);
    }

    /// `Decl.ret` — a fn's return type name, "" otherwise.
    fn lowerDeclRet(self: *FunctionLowerer, item: ast.Item) LowerError!Value {
        return switch (item) {
            .function => |fnd| astStr(astTypeName(self.allocator, fnd.return_ty)),
            else => astStr(""),
        };
    }

    /// `*AstExpr` field value: materialize the expr, then take its address.
    fn materializeExprPtr(self: *FunctionLowerer, e: ast.Expr) LowerError!Value {
        const inner = try self.allocator.create(IrType);
        inner.* = .{ .variant_type = "AstExpr" };
        const v = try self.materializeExpr(e);
        return self.emit(.{ .ptr = inner }, .{ .unary = .{ .op = .ref, .value = v } });
    }

    /// Build a `[]<elem>` slice from already-materialized element values.
    fn materializeSlice(self: *FunctionLowerer, elem_ir: IrType, elems: []const Value) LowerError!Value {
        const inner = try self.allocator.create(IrType);
        inner.* = elem_ir;
        const arr = try self.emit(.{ .array = .{ .elem = inner, .len = elems.len } }, .{ .builtin = .{
            .name = "compound_literal",
            .args = try self.allocator.dupe(Value, elems),
        } });
        // A slice's `ptr` field is a real pointer, so spill the array to memory and
        // take its address (`&arr` == `&arr[0]`). Using the array *value* directly
        // produced `insertvalue [N x T]` into the `{ptr,i64}` slice — invalid LLVM.
        const arr_ty = try self.allocator.create(IrType);
        arr_ty.* = .{ .array = .{ .elem = inner, .len = elems.len } };
        const ptr = try self.emit(.{ .ptr = arr_ty }, .{ .unary = .{ .op = .ref, .value = arr } });
        return self.emit(.{ .slice = inner }, .{ .slice_expr = .{
            .ptr = ptr,
            .len = .{ .imm = .{ .uint = elems.len } },
        } });
    }

    // ── Materialization: `type_info(T)` → a `TypeInfo` value ──────────────────
    // Builds the matchable `TypeInfo` tagged enum from a type's layout, the same
    // way `materializeExpr` builds `ast.*`. Recursive payloads are `*TypeInfo`;
    // cycles (`Node { next: *Node }`) break with the `other` leaf.

    fn materializeTypeInfo(self: *FunctionLowerer, ty: IrType) LowerError!Value {
        var visiting = std.StringHashMap(void).init(self.allocator);
        defer visiting.deinit();
        return self.materializeTypeInfoRec(ty, &visiting);
    }

    /// Materialize `ty` and take its address as a `*TypeInfo` (for nested fields).
    fn tiPtr(self: *FunctionLowerer, ty: IrType, visiting: *std.StringHashMap(void)) LowerError!Value {
        const inner = try self.allocator.create(IrType);
        inner.* = .{ .variant_type = "TypeInfo" };
        const v = try self.materializeTypeInfoRec(ty, visiting);
        return self.emit(.{ .ptr = inner }, .{ .unary = .{ .op = .ref, .value = v } });
    }

    fn tiInt(self: *FunctionLowerer, bits: u64, signed: bool) LowerError!Value {
        const payload = try self.mkStruct("TiInt", &.{
            .{ .name = "bits", .value = .{ .imm = .{ .uint = bits } } },
            .{ .name = "signed", .value = .{ .imm = .{ .bool = signed } } },
        });
        return self.mkVariant("TypeInfo", "int", payload);
    }

    fn tiFloat(self: *FunctionLowerer, bits: u64) LowerError!Value {
        const payload = try self.mkStruct("TiFloat", &.{
            .{ .name = "bits", .value = .{ .imm = .{ .uint = bits } } },
        });
        return self.mkVariant("TypeInfo", "float", payload);
    }

    fn materializeTypeInfoRec(self: *FunctionLowerer, ty: IrType, visiting: *std.StringHashMap(void)) LowerError!Value {
        switch (ty) {
            .i => |b| return self.tiInt(b, true),
            .u => |b| return self.tiInt(b, false),
            .byte => return self.tiInt(8, false),
            .rune => return self.tiInt(32, false),
            .usize, .addr => return self.tiInt(64, false),
            .isize => return self.tiInt(64, true),
            .bool => return self.mkVariant("TypeInfo", "boolean", null),
            .void => return self.mkVariant("TypeInfo", "void_", null),
            .f32 => return self.tiFloat(32),
            .f64 => return self.tiFloat(64),
            .ptr => |inner| {
                const elem = try self.tiPtr(inner.*, visiting);
                const payload = try self.mkStruct("TiPtr", &.{
                    .{ .name = "elem", .value = elem },
                    .{ .name = "is_const", .value = .{ .imm = .{ .bool = false } } },
                });
                return self.mkVariant("TypeInfo", "pointer", payload);
            },
            .slice => |inner| return self.mkVariant("TypeInfo", "slice", try self.tiPtr(inner.*, visiting)),
            .text => return self.mkVariant("TypeInfo", "slice", try self.tiPtr(.byte, visiting)),
            .optional => |inner| return self.mkVariant("TypeInfo", "optional", try self.tiPtr(inner.*, visiting)),
            .array => |arr| {
                const elem = try self.tiPtr(arr.elem.*, visiting);
                const payload = try self.mkStruct("TiArray", &.{
                    .{ .name = "len", .value = .{ .imm = .{ .uint = arr.len } } },
                    .{ .name = "elem", .value = elem },
                });
                return self.mkVariant("TypeInfo", "array", payload);
            },
            .struct_type => |name| {
                // A *named* enum lowers to `.struct_type` (like any named type), so
                // disambiguate here: if it has variants it's an enum, else a struct.
                if (self.enumVariantInfos(name) != null) return self.tiEnum(name, visiting);
                return self.tiStruct(name, visiting);
            },
            .variant_type => |name| return self.tiEnum(name, visiting),
            else => return self.mkVariant("TypeInfo", "other", astStr(typeInfoKindName(ty))),
        }
    }

    fn tiStruct(self: *FunctionLowerer, name: []const u8, visiting: *std.StringHashMap(void)) LowerError!Value {
        if (visiting.contains(name)) return self.mkVariant("TypeInfo", "other", astStr(name));
        const fields = self.structFieldInfos(name) orelse return self.mkVariant("TypeInfo", "other", astStr(name));
        try visiting.put(name, {});
        defer _ = visiting.remove(name);

        var field_vals: std.ArrayList(Value) = .empty;
        defer field_vals.deinit(self.allocator);
        for (fields) |f| {
            const fty = lowerSemaTypeWithEnv(self.allocator, f.ty, self.types, self.symbols) catch IrType.unknown;
            const fv = try self.mkStruct("TiField", &.{
                .{ .name = "name", .value = astStr(f.name) },
                .{ .name = "ty", .value = try self.tiPtr(fty, visiting) },
            });
            try field_vals.append(self.allocator, fv);
        }
        const slice = try self.materializeSlice(.{ .struct_type = "TiField" }, field_vals.items);
        const payload = try self.mkStruct("TiStruct", &.{
            .{ .name = "name", .value = astStr(name) },
            .{ .name = "fields", .value = slice },
            // The type's stable runtime id (== `core::type_id(S)`), so a reflective
            // consumer (serde deserialize) can build an `Any` over a struct element
            // and look its size up via `type_size_of`.
            .{ .name = "id", .value = .{ .imm = .{ .uint = typeIdHash(.{ .struct_type = name }) } } },
        });
        return self.mkVariant("TypeInfo", "struct_", payload);
    }

    fn tiEnum(self: *FunctionLowerer, name: []const u8, visiting: *std.StringHashMap(void)) LowerError!Value {
        _ = visiting;
        const variants = self.enumVariantInfos(name) orelse return self.mkVariant("TypeInfo", "other", astStr(name));
        var vvals: std.ArrayList(Value) = .empty;
        defer vvals.deinit(self.allocator);
        for (variants) |v| {
            const vv = try self.mkStruct("TiVariant", &.{
                .{ .name = "name", .value = astStr(v.name) },
                .{ .name = "has_payload", .value = .{ .imm = .{ .bool = v.payload != null } } },
            });
            try vvals.append(self.allocator, vv);
        }
        const slice = try self.materializeSlice(.{ .struct_type = "TiVariant" }, vvals.items);
        const payload = try self.mkStruct("TiEnum", &.{
            .{ .name = "name", .value = astStr(name) },
            .{ .name = "variants", .value = slice },
        });
        return self.mkVariant("TypeInfo", "enum_", payload);
    }

    fn structFieldInfos(self: *FunctionLowerer, name: []const u8) ?[]const sema.FieldInfo {
        const id = self.symbols.resolve(self.symbols.root_scope, name) orelse return null;
        const layout = self.types.layouts.get(id) orelse return null;
        return switch (layout.kind) {
            .struct_type => |f| f,
            else => null,
        };
    }

    fn enumVariantInfos(self: *FunctionLowerer, name: []const u8) ?[]const sema.VariantInfo {
        const id = self.symbols.resolve(self.symbols.root_scope, name) orelse return null;
        const layout = self.types.layouts.get(id) orelse return null;
        return switch (layout.kind) {
            .variant_type => |v| v,
            else => null,
        };
    }

    fn materializeVariantSlice(self: *FunctionLowerer, elem_variant: []const u8, elems: []const Value) LowerError!Value {
        return self.materializeSlice(.{ .variant_type = elem_variant }, elems);
    }

    /// `*AstExpr` for an optional sub-expression (slice bounds), using the
    /// `nothing` AstExpr as the "absent" sentinel.
    fn materializeOptExprPtr(self: *FunctionLowerer, opt: ?*const ast.Expr) LowerError!Value {
        if (opt) |e| return self.materializeExprPtr(e.*);
        const inner = try self.allocator.create(IrType);
        inner.* = .{ .variant_type = "AstExpr" };
        const nothing = try self.mkVariant("AstExpr", "nothing", null);
        return self.emit(.{ .ptr = inner }, .{ .unary = .{ .op = .ref, .value = nothing } });
    }

    /// `*AstType` field value.
    fn materializeTypePtr(self: *FunctionLowerer, ty: ast.TypeRef) LowerError!Value {
        const inner = try self.allocator.create(IrType);
        inner.* = .{ .variant_type = "AstType" };
        const v = try self.materializeType(ty);
        return self.emit(.{ .ptr = inner }, .{ .unary = .{ .op = .ref, .value = v } });
    }

    /// Materialize a type reference into an `AstType` value.
    fn materializeType(self: *FunctionLowerer, ty: ast.TypeRef) LowerError!Value {
        switch (ty) {
            .named, .type_param => |n| return self.mkVariant("AstType", "named", astStr(n.name)),
            .pointer, .many_pointer => |p| return self.mkVariant("AstType", "ptr", try self.materializeTypePtr(p.inner.*)),
            .slice => |s| return self.mkVariant("AstType", "slice_of", try self.materializeTypePtr(s.inner.*)),
            .optional => |o| return self.mkVariant("AstType", "optional_of", try self.materializeTypePtr(o.inner.*)),
            .array => |arr| {
                const payload = try self.mkStruct("AstArrayTy", &.{
                    .{ .name = "len", .value = try self.materializeExprPtr(arr.len.*) },
                    .{ .name = "elem", .value = try self.materializeTypePtr(arr.inner.*) },
                });
                return self.mkVariant("AstType", "array_of", payload);
            },
            else => return error.LoweringFailed,
        }
    }

    fn materializeExpr(self: *FunctionLowerer, expr: ast.Expr) LowerError!Value {
        switch (expr.kind) {
            .int => |text| return self.mkVariant("AstExpr", "int", .{ .imm = .{ .int = parseIntLiteral(text) } }),
            .float => |text| return self.mkVariant("AstExpr", "float", .{ .imm = .{ .float = parseFloatLiteral(text) } }),
            // Raw (still-quoted) source text; the reifier hands it back verbatim
            // and the next sema pass trims the quotes.
            .string => |text| return self.mkVariant("AstExpr", "str", astStr(text)),
            .bool => |b| return self.mkVariant("AstExpr", "boolean", .{ .imm = .{ .bool = b } }),
            .null => return self.mkVariant("AstExpr", "nothing", null),
            .ident => |name| return self.mkVariant("AstExpr", "ident", astStr(name)),
            .unary => |u| {
                const op = astUnOpName(u.op) orelse return error.LoweringFailed;
                const payload = try self.mkStruct("AstUnary", &.{
                    .{ .name = "op", .value = try self.mkVariant("AstUnOp", op, null) },
                    .{ .name = "operand", .value = try self.materializeExprPtr(u.expr.*) },
                });
                return self.mkVariant("AstExpr", "unary", payload);
            },
            .binary => |b| {
                const op = astBinOpName(b.op) orelse return error.LoweringFailed;
                const payload = try self.mkStruct("AstBinary", &.{
                    .{ .name = "op", .value = try self.mkVariant("AstBinOp", op, null) },
                    .{ .name = "left", .value = try self.materializeExprPtr(b.left.*) },
                    .{ .name = "right", .value = try self.materializeExprPtr(b.right.*) },
                });
                return self.mkVariant("AstExpr", "binary", payload);
            },
            .call => |c| {
                var arg_vals = std.ArrayList(Value).empty;
                defer arg_vals.deinit(self.allocator);
                for (c.args) |arg| {
                    const pair: struct { name: []const u8, value: ast.Expr } = switch (arg) {
                        .positional => |e| .{ .name = "", .value = e },
                        .named => |n| .{ .name = n.name, .value = n.value },
                    };
                    try arg_vals.append(self.allocator, try self.mkStruct("AstArg", &.{
                        .{ .name = "name", .value = astStr(pair.name) },
                        .{ .name = "value", .value = try self.materializeExpr(pair.value) },
                    }));
                }
                const payload = try self.mkStruct("AstCall", &.{
                    .{ .name = "callee", .value = try self.materializeExprPtr(c.callee.*) },
                    .{ .name = "args", .value = try self.materializeSlice(.{ .struct_type = "AstArg" }, arg_vals.items) },
                });
                return self.mkVariant("AstExpr", "call", payload);
            },
            .field => |f| {
                const payload = try self.mkStruct("AstField", &.{
                    .{ .name = "base", .value = try self.materializeExprPtr(f.base.*) },
                    .{ .name = "name", .value = astStr(f.name) },
                });
                return self.mkVariant("AstExpr", "field", payload);
            },
            .index => |ix| {
                const payload = try self.mkStruct("AstIndex", &.{
                    .{ .name = "base", .value = try self.materializeExprPtr(ix.base.*) },
                    .{ .name = "idx", .value = try self.materializeExprPtr(ix.index.*) },
                });
                return self.mkVariant("AstExpr", "index", payload);
            },
            .slice => |s| {
                const payload = try self.mkStruct("AstSliceE", &.{
                    .{ .name = "base", .value = try self.materializeExprPtr(s.base.*) },
                    .{ .name = "start", .value = try self.materializeOptExprPtr(s.start) },
                    .{ .name = "end", .value = try self.materializeOptExprPtr(s.end) },
                });
                return self.mkVariant("AstExpr", "slice", payload);
            },
            .as_cast => |c| {
                const payload = try self.mkStruct("AstCastE", &.{
                    .{ .name = "value", .value = try self.materializeExprPtr(c.value.*) },
                    .{ .name = "to", .value = try self.materializeType(c.to) },
                });
                return self.mkVariant("AstExpr", "cast", payload);
            },
            .force_unwrap => |inner| return self.mkVariant("AstExpr", "unwrap", try self.materializeExprPtr(inner.*)),
            .nil_coalesce => |nc| {
                const payload = try self.mkStruct("AstCoalesce", &.{
                    .{ .name = "value", .value = try self.materializeExprPtr(nc.value.*) },
                    .{ .name = "default", .value = try self.materializeExprPtr(nc.default.*) },
                });
                return self.mkVariant("AstExpr", "coalesce", payload);
            },
            .try_expr => |t| return self.mkVariant("AstExpr", "try_q", try self.materializeExprPtr(t.value.*)),
            .catch_expr => |c| {
                const payload = try self.mkStruct("AstCatchE", &.{
                    .{ .name = "value", .value = try self.materializeExprPtr(c.value.*) },
                    .{ .name = "err_name", .value = astStr(c.err_name) },
                    .{ .name = "handler", .value = try self.materializeBlock(c.handler) },
                });
                return self.mkVariant("AstExpr", "catch_b", payload);
            },
            .compound_literal => |vals| {
                var elems = std.ArrayList(Value).empty;
                defer elems.deinit(self.allocator);
                for (vals) |v| try elems.append(self.allocator, try self.materializeExpr(v));
                return self.mkVariant("AstExpr", "compound", try self.materializeVariantSlice("AstExpr", elems.items));
            },
            .unsafe_expr => |inner| return self.mkVariant("AstExpr", "unsafe_e", try self.materializeExprPtr(inner.*)),
            else => return error.LoweringFailed,
        }
    }

    /// Materialize a quoted block into an `AstBlock` value.
    fn materializeBlock(self: *FunctionLowerer, block: ast.Block) LowerError!Value {
        var elems = std.ArrayList(Value).empty;
        defer elems.deinit(self.allocator);
        for (block.statements) |s| try elems.append(self.allocator, try self.materializeStmt(s));
        const slice = try self.materializeVariantSlice("AstStmt", elems.items);
        return self.mkStruct("AstBlock", &.{.{ .name = "stmts", .value = slice }});
    }

    fn materializeStmt(self: *FunctionLowerer, stmt: ast.Stmt) LowerError!Value {
        switch (stmt) {
            .local_infer => |l| {
                const payload = try self.mkStruct("AstLocal", &.{
                    .{ .name = "name", .value = astStr(l.name) },
                    .{ .name = "value", .value = try self.materializeExpr(l.value) },
                });
                return self.mkVariant("AstStmt", "local", payload);
            },
            .assign => |a| {
                // Desugar compound assignment (`x += y` → `x = x + y`) so the
                // ast.* surface needs no assignment-operator field.
                const value = if (assignOpToBinOpName(a.op)) |op| blk: {
                    const bin = try self.mkStruct("AstBinary", &.{
                        .{ .name = "op", .value = try self.mkVariant("AstBinOp", op, null) },
                        .{ .name = "left", .value = try self.materializeExprPtr(a.target) },
                        .{ .name = "right", .value = try self.materializeExprPtr(a.value) },
                    });
                    break :blk try self.mkVariant("AstExpr", "binary", bin);
                } else try self.materializeExpr(a.value);
                const payload = try self.mkStruct("AstAssign", &.{
                    .{ .name = "target", .value = try self.materializeExpr(a.target) },
                    .{ .name = "value", .value = value },
                });
                return self.mkVariant("AstStmt", "assign", payload);
            },
            .return_stmt => |r| {
                if (r.value) |v| return self.mkVariant("AstStmt", "ret_expr", try self.materializeExpr(v));
                return self.mkVariant("AstStmt", "ret", null);
            },
            .if_stmt => |iff| {
                if (iff.binding != null or iff.payload_binding != null) return error.LoweringFailed;
                const empty = ast.Block{ .statements = &.{}, .span = iff.span };
                const payload = try self.mkStruct("AstIf", &.{
                    .{ .name = "cond", .value = try self.materializeExpr(iff.condition) },
                    .{ .name = "then_block", .value = try self.materializeBlock(iff.then_block) },
                    .{ .name = "else_block", .value = try self.materializeBlock(iff.else_block orelse empty) },
                });
                return self.mkVariant("AstStmt", "cond", payload);
            },
            .while_stmt => |w| {
                const payload = try self.mkStruct("AstWhile", &.{
                    .{ .name = "cond", .value = try self.materializeExpr(w.condition) },
                    .{ .name = "body", .value = try self.materializeBlock(w.body) },
                });
                return self.mkVariant("AstStmt", "loop", payload);
            },
            .local_typed => |l| {
                const payload = try self.mkStruct("AstLocalTyped", &.{
                    .{ .name = "name", .value = astStr(l.name) },
                    .{ .name = "ty", .value = try self.materializeType(l.ty) },
                    .{ .name = "value", .value = try self.materializeExpr(l.value) },
                });
                return self.mkVariant("AstStmt", "local_typed", payload);
            },
            .for_range => |f| {
                const payload = try self.mkStruct("AstForRange", &.{
                    .{ .name = "binding", .value = astStr(f.binding) },
                    .{ .name = "start", .value = try self.materializeExpr(f.start) },
                    .{ .name = "end", .value = try self.materializeExpr(f.end) },
                    .{ .name = "inclusive", .value = .{ .imm = .{ .bool = f.inclusive } } },
                    .{ .name = "body", .value = try self.materializeBlock(f.body) },
                });
                return self.mkVariant("AstStmt", "for_range", payload);
            },
            .for_slice => |f| {
                const payload = try self.mkStruct("AstForSlice", &.{
                    .{ .name = "binding", .value = astStr(f.binding) },
                    .{ .name = "index_binding", .value = astStr(f.index_binding orelse "") },
                    .{ .name = "by_ref", .value = .{ .imm = .{ .bool = f.by_ref } } },
                    .{ .name = "iter", .value = try self.materializeExpr(f.iter) },
                    .{ .name = "body", .value = try self.materializeBlock(f.body) },
                });
                return self.mkVariant("AstStmt", "for_slice", payload);
            },
            .match_stmt => |m| {
                var arm_vals = std.ArrayList(Value).empty;
                defer arm_vals.deinit(self.allocator);
                for (m.arms) |arm| try arm_vals.append(self.allocator, try self.materializeMatchArm(arm));
                const payload = try self.mkStruct("AstMatch", &.{
                    .{ .name = "subject", .value = try self.materializeExpr(m.subject) },
                    .{ .name = "arms", .value = try self.materializeSlice(.{ .struct_type = "AstMatchArm" }, arm_vals.items) },
                });
                return self.mkVariant("AstStmt", "match_s", payload);
            },
            .zone_block => |z| {
                const payload = try self.mkStruct("AstZone", &.{
                    .{ .name = "name", .value = astStr(z.name) },
                    .{ .name = "kind", .value = astStr(z.kind) },
                    .{ .name = "body", .value = try self.materializeBlock(z.body) },
                });
                return self.mkVariant("AstStmt", "zone_s", payload);
            },
            .defer_stmt => |d| {
                const mode = switch (d.mode) {
                    .always => "always",
                    .ok => "ok_only",
                    .err => "err_only",
                };
                const payload = try self.mkStruct("AstDefer", &.{
                    .{ .name = "mode", .value = try self.mkVariant("AstDeferMode", mode, null) },
                    .{ .name = "body", .value = try self.materializeBlock(d.body) },
                });
                return self.mkVariant("AstStmt", "defer_s", payload);
            },
            .fail_stmt => |f| {
                var pvals = std.ArrayList(Value).empty;
                defer pvals.deinit(self.allocator);
                for (f.payload) |p| try pvals.append(self.allocator, try self.materializeExpr(p));
                const payload = try self.mkStruct("AstFail", &.{
                    .{ .name = "variant", .value = astStr(f.variant) },
                    .{ .name = "payload", .value = try self.materializeVariantSlice("AstExpr", pvals.items) },
                });
                return self.mkVariant("AstStmt", "fail_s", payload);
            },
            .unsafe_block => |b| return self.mkVariant("AstStmt", "unsafe_blk", try self.materializeBlock(b)),
            .break_stmt => return self.mkVariant("AstStmt", "brk", null),
            .continue_stmt => return self.mkVariant("AstStmt", "cont", null),
            .expr => |e| return self.mkVariant("AstStmt", "expr", try self.materializeExpr(e)),
            else => return error.LoweringFailed,
        }
    }

    fn materializeMatchArm(self: *FunctionLowerer, arm: ast.MatchArm) LowerError!Value {
        const pattern = switch (arm.pattern) {
            .enum_variant => |name| try self.mkVariant("AstPattern", "variant", astStr(name)),
            .int_values => |vals| blk: {
                var pvals = std.ArrayList(Value).empty;
                defer pvals.deinit(self.allocator);
                for (vals) |v| try pvals.append(self.allocator, try self.materializeExpr(v));
                break :blk try self.mkVariant("AstPattern", "ints", try self.materializeVariantSlice("AstExpr", pvals.items));
            },
            // `else`, and (for now) range/string/name patterns, reflect as the
            // catch-all `anything` — full fidelity for these in `#quote` is TODO.
            .else_arm, .range, .strings, .binding => try self.mkVariant("AstPattern", "anything", null),
        };
        return self.mkStruct("AstMatchArm", &.{
            .{ .name = "pattern", .value = pattern },
            .{ .name = "binding", .value = astStr(arm.binding orelse "") },
            .{ .name = "body", .value = try self.materializeBlock(arm.body) },
        });
    }

    /// The linkage name a bare top-level name resolves to from this function's
    /// file (module-qualified only on a cross-module collision). Falls back to the
    /// bare name when unresolved (locals, params, builtins).
    fn linkName(self: *FunctionLowerer, bare: []const u8) []const u8 {
        return linkNameFor(self.symbols, self.file_name, bare);
    }

    /// Resolve a `ns::member` scope-access to its symbol (file-aware).
    fn resolveScope(self: *FunctionLowerer, sa: ast.ScopeAccess) ?sema.SymbolId {
        const alias = switch (sa.base.kind) {
            .ident => |n| n,
            else => return null,
        };
        if (self.symbols.resolveScoped(self.file_name, alias, sa.member)) |id| return id;
        // `Type::method` — an associated function hoisted from a struct body to a
        // top-level `"<Type>.<member>"` (mirrors sema's resolveScopeAccessSymbol).
        if (resolveTopLevel(self.symbols, self.file_name, alias)) |tid| {
            if (self.symbols.symbol(tid).kind == .type) {
                var buf: [256]u8 = undefined;
                const dotted = std.fmt.bufPrint(&buf, "{s}.{s}", .{ alias, sa.member }) catch return null;
                const file = self.symbols.symbol(tid).file_name;
                for (self.symbols.symbols.items) |sym| {
                    if (sym.kind == .function and std.mem.eql(u8, sym.file_name, file) and
                        std.mem.eql(u8, sym.name, dotted))
                        return sym.id;
                }
            }
        }
        return null;
    }

    fn lowerExpr(self: *FunctionLowerer, expr: ast.Expr) LowerError!Value {
        return switch (expr.kind) {
            // `#quote(expr)` materializes its quoted expression into an AstExpr
            // value (the faithful ast.* surface). The block form `#quote { }`
            // (slices) and stray `$`-splices are not value-lowered here.
            .quote_expr => |inner| try self.materializeExpr(inner.*),
            .quote => |block| try self.materializeBlock(block),
            // `#parse` is resolved by the two-pass pipeline (string → AST), never
            // value-lowered; `$`-splices are macro internals.
            .splice, .parse_expr => return error.LoweringFailed,
            .match_expr => try self.lowerMatchExpr(expr, null),
            .if_expr => try self.lowerIfExpr(expr, null),
            .ident => |name| blk: {
                // Bare enum literal `.variant` resolved by sema against an
                // expected enum type → the corresponding variant value.
                if (self.types.enum_lits.get(expr.id)) |lit| {
                    break :blk try self.emit(self.exprType(expr), .{ .variant_lit = .{
                        .type_name = lit.type_name,
                        .variant = lit.variant,
                        .payload = null,
                    } });
                }
                // Inside a lambda body, a captured variable reads from `__env`.
                for (self.lambda_captures, 0..) |c, idx| {
                    if (std.mem.eql(u8, c.name, name)) {
                        const fields = try self.captureFieldTys();
                        break :blk try self.emit(fields[idx], .{ .closure_env_load = .{
                            .env = .{ .param = "__env" },
                            .index = @intCast(idx),
                            .fields = fields,
                        } });
                    }
                }
                for (self.params) |p| {
                    if (std.mem.eql(u8, p.name, name)) break :blk Value{ .param = name };
                }
                // A declared local shadows a top-level function/const of the same
                // name (matching sema's `lookupLocal`-first resolution). Without
                // this, `foo := 10` next to a `foo :: fn()` lowered to `@foo`.
                const cur = self.curLocal(name);
                if (self.local_types.contains(cur)) break :blk Value{ .local = cur };
                if (resolveTopLevel(self.symbols, self.file_name, name)) |id| {
                    const kind = self.symbols.symbol(id).kind;
                    const link = self.symbols.symbol(id).link_name;
                    // A function used as a VALUE (not a direct call) becomes a fat
                    // closure `{ fn, env }`. Phase 1: env is always null (no captures).
                    // Constraints/macros are compile-time templates, not callable
                    // values — keep them as a bare symbol reference.
                    if (kind == .function and !self.isTemplateFn(name)) {
                        const is_lambda = std.mem.startsWith(u8, name, "__lambda_");
                        break :blk try self.emit(self.fnPtrTypeOf(expr), .{ .closure_make = .{
                            .fn_link = link,
                            .env = if (is_lambda) try self.buildCaptureEnv(link) else .{ .imm = .null },
                            .fn_takes_env = is_lambda,
                        } });
                    }
                    if (kind == .function or kind == .const_symbol or kind == .global_var) break :blk Value{ .global = link };
                }
                break :blk Value{ .local = name };
            },
            .scope_access => |sa| blk: {
                // `core::<location constant>` — folds to a compile-time literal at
                // the use site: `core::file`/`func`/`module` → string, `core::line`/
                // `column` → int (no parens; this is value position).
                if (isCoreNs(sa)) {
                    const m = sa.member;
                    const eq = std.mem.eql;
                    if (eq(u8, m, "file")) break :blk astStr(self.file_name);
                    if (eq(u8, m, "func")) break :blk astStr(self.fn_name);
                    if (eq(u8, m, "module")) break :blk astStr(moduleNameOf(self.file_name));
                    if (eq(u8, m, "os")) break :blk astStr(@tagName(@import("builtin").os.tag));
                    if (eq(u8, m, "arch")) break :blk astStr(@tagName(@import("builtin").cpu.arch));
                    const lc = expr.span.line_col(self.source);
                    if (eq(u8, m, "line")) break :blk Value{ .imm = .{ .int = @intCast(lc.line) } };
                    if (eq(u8, m, "column")) break :blk Value{ .imm = .{ .int = @intCast(lc.col) } };
                    break :blk Value{ .imm = .null };
                }
                // `ns::member` as a value (function/const reference).
                const id = self.resolveScope(sa) orelse break :blk Value{ .imm = .null };
                break :blk Value{ .global = self.symbols.symbol(id).link_name };
            },
            .type_ref => .{ .imm = .null },
            .unsafe_expr => |inner| try self.lowerExpr(inner.*),
            .run_expr => |inner| blk: {
                // The VM is the sole comptime engine. If it can't fold the
                // expression to a constant, lower the operand directly so it is
                // computed at runtime instead — there is no tree-walker fallback.
                if (self.cvm) |c| {
                    c.current_file = self.file_name;
                    if (c.evalToValue(inner.*)) |v| break :blk v;
                }
                break :blk try self.lowerExpr(inner.*);
            },
            .force_unwrap => |inner| try self.lowerForceUnwrap(inner.*, expr),
            .nil_coalesce => |nc| try self.lowerNilCoalesce(nc, expr),
            .as_cast => |cast| if (self.exprType(expr) == .interface_value)
                try self.lowerInterfaceCoercion(cast.value.*, self.exprType(expr).interface_value)
            else
                try self.emit(self.exprType(expr), .{ .cast = .{
                    .kind = .as,
                    .value = try self.lowerExpr(cast.value.*),
                } }),
            .int => |text| .{ .imm = .{ .int = parseIntLiteral(text) } },
            .float => |text| .{ .imm = .{ .float = parseFloatLiteral(text) } },
            .string => |text| .{ .imm = .{ .text = trimQuotes(text) } },
            .bool => |value| .{ .imm = .{ .bool = value } },
            .null => .{ .imm = .null },
            .compound_literal => |values| blk: {
                var args = std.ArrayList(Value).empty;
                errdefer args.deinit(self.allocator);
                // Lower each element with its field/element type so nested
                // compound literals (`.{ .{1,2}, 3 }`) build their aggregate.
                const ct = self.exprType(expr);
                for (values, 0..) |value, i| {
                    if (self.compoundFieldType(ct, i)) |fty| {
                        // A `fn(...)` struct field holds a THIN raw function pointer.
                        if (fty == .fn_ptr)
                            try args.append(self.allocator, try self.lowerRawFnArg(value))
                        else
                            try args.append(self.allocator, try self.lowerExprAs(value, fty));
                    } else try args.append(self.allocator, try self.lowerExpr(value));
                }
                try self.appendTrailingDefaults(&args, ct, values.len);
                break :blk try self.emit(ct, .{ .builtin = .{ .name = "compound_literal", .args = try args.toOwnedSlice(self.allocator) } });
            },
            .struct_literal => |inits| try self.lowerStructLiteral(inits, self.exprType(expr), expr.span),
            .unary => |unary| blk: {
                // `&p.field` / `&arr[i]` must take the field/element address in
                // place (field_addr/index_addr), not `ref` a *loaded copy* —
                // otherwise the result dangles once the temporary is reused.
                if (unary.op == .address_of) switch (unary.expr.kind) {
                    .field, .index => break :blk try self.lowerLValueAddress(unary.expr.*),
                    else => {},
                };
                const value = try self.lowerExpr(unary.expr.*);
                break :blk switch (unary.op) {
                    .address_of => try self.emitAt(self.exprType(expr), .{ .unary = .{ .op = .ref, .value = value } }, expr.span),
                    .deref => try self.emitAt(self.exprType(expr), .{ .unary = .{ .op = .deref, .value = value } }, expr.span),
                    .neg => try self.emitAt(self.exprType(expr), .{ .unary = .{ .op = .neg, .value = value } }, expr.span),
                    .not => try self.emitAt(self.exprType(expr), .{ .unary = .{ .op = .not, .value = value } }, expr.span),
                    .bit_not => try self.emitAt(self.exprType(expr), .{ .unary = .{ .op = .bit_not, .value = value } }, expr.span),
                };
            },
            .binary => |binary| blk: {
                if (binary.op == .equal or binary.op == .not_equal) {
                    const optional_expr: ?ast.Expr = if (self.exprType(binary.left.*) == .optional and binary.right.kind == .null)
                        binary.left.*
                    else if (self.exprType(binary.right.*) == .optional and binary.left.kind == .null)
                        binary.right.*
                    else
                        null;
                    if (optional_expr) |optional| {
                        const value = try self.lowerExpr(optional);
                        const is_some = try self.emitAt(.bool, .{ .optional_is_some = value }, expr.span);
                        if (binary.op == .not_equal) break :blk is_some;
                        break :blk try self.emitAt(.bool, .{ .unary = .{ .op = .not, .value = is_some } }, expr.span);
                    }
                    // `s == t` / `s != t` on strings compares CONTENTS, not the
                    // fat `{ ptr, len }` slice value (LLVM can't `icmp` an
                    // aggregate). Reuse the match string-pattern lowering: a
                    // length check then a byte compare (eager `&&`-safe), so it
                    // folds in the comptime VM too (`#compiler` string compares).
                    const left_str = binary.left.kind == .string or isByteSliceTy(self.exprType(binary.left.*));
                    const right_str = binary.right.kind == .string or isByteSliceTy(self.exprType(binary.right.*));
                    if (left_str and right_str) {
                        // Two literals fold to a constant (no indexing needed).
                        if (binary.left.kind == .string and binary.right.kind == .string) {
                            const equal = std.mem.eql(u8, trimQuotes(binary.left.kind.string), trimQuotes(binary.right.kind.string));
                            break :blk .{ .imm = .{ .bool = if (binary.op == .equal) equal else !equal } };
                        }
                        const eqv = if (binary.right.kind == .string)
                            try self.lowerStringEq(try self.lowerExpr(binary.left.*), binary.right.kind.string)
                        else if (binary.left.kind == .string)
                            try self.lowerStringEq(try self.lowerExpr(binary.right.*), binary.left.kind.string)
                        else
                            try self.lowerStringEqDynamic(try self.lowerExpr(binary.left.*), try self.lowerExpr(binary.right.*));
                        if (binary.op == .not_equal) break :blk try self.emit(.bool, .{ .unary = .{ .op = .not, .value = eqv } });
                        break :blk eqv;
                    }
                    const lty = self.exprType(binary.left.*);
                    const rty = self.exprType(binary.right.*);
                    // Payload enums are aggregates `{tag, …}` (a simple/payloadless
                    // enum is a scalar and compares fine below). `e == .variant`
                    // becomes a discriminant check (`variant_is`); two full enum
                    // VALUES have no discriminant-extract op, so reject them cleanly
                    // (use `match`) rather than emit an invalid aggregate `icmp`.
                    if (self.payloadEnumName(lty) orelse self.payloadEnumName(rty)) |ename| {
                        var value_expr: ?ast.Expr = null;
                        var vname: ?[]const u8 = null;
                        if (bareEnumVariant(binary.right.*)) |vn| {
                            vname = vn;
                            value_expr = binary.left.*;
                        } else if (bareEnumVariant(binary.left.*)) |vn| {
                            vname = vn;
                            value_expr = binary.right.*;
                        }
                        if (vname) |vn| {
                            const v = try self.emit(.bool, .{ .variant_is = .{ .value = try self.lowerExpr(value_expr.?), .type_name = ename, .variant = vn } });
                            break :blk if (binary.op == .not_equal) try self.emit(.bool, .{ .unary = .{ .op = .not, .value = v } }) else v;
                        }
                        // Two enum values: equal iff same variant and equal payloads.
                        if (try self.lowerEnumEq(try self.lowerExpr(binary.left.*), try self.lowerExpr(binary.right.*), ename)) |eqv| {
                            break :blk if (binary.op == .not_equal) try self.emit(.bool, .{ .unary = .{ .op = .not, .value = eqv } }) else eqv;
                        }
                        diag_mod.printErrorAt("`==` on enum values with non-scalar payloads isn't supported — use `match`", self.file_name, self.source, expr.span);
                        return error.LoweringFailed;
                    }
                    // `a == b` / `a != b` on an aggregate (struct, array, or
                    // non-byte slice) compares element/field-wise — the backend
                    // can't `icmp` an aggregate. (Byte slices were handled above.)
                    if (lty == .struct_type or lty == .array or lty == .slice) {
                        const eqv = try self.lowerValueEq(try self.lowerExpr(binary.left.*), try self.lowerExpr(binary.right.*), lty);
                        if (binary.op == .not_equal) break :blk try self.emit(.bool, .{ .unary = .{ .op = .not, .value = eqv } });
                        break :blk eqv;
                    }
                }
                const lhs = try self.lowerExpr(binary.left.*);
                const rhs = try self.lowerExpr(binary.right.*);
                break :blk try self.emitAt(self.exprType(expr), .{ .binary = .{ .op = lowerBinOp(binary.op), .lhs = lhs, .rhs = rhs } }, expr.span);
            },
            .try_expr => |try_expr| blk: {
                const value = try self.lowerExpr(try_expr.value.*);
                const with_context = try self.emit(self.exprType(try_expr.value.*), .{ .builtin = .{
                    .name = "try_context",
                    .args = try self.allocator.dupe(Value, &.{value}),
                } });
                break :blk try self.emit(self.exprType(expr), .{ .try_ok = with_context });
            },
            .catch_expr => |catch_expr| blk: {
                const value = try self.lowerExpr(catch_expr.value.*);
                const error_ty: IrType = switch (self.exprType(catch_expr.value.*)) {
                    .fallible => |fallible| fallible.err.*,
                    else => .unknown,
                };
                const is_ok = try self.emit(.bool, .{ .try_is_ok = value });
                const ok_id = self.allocBlockId();
                const err_id = self.allocBlockId();
                try self.terminate(.{ .cond_branch = .{
                    .cond = is_ok,
                    .then_block = ok_id,
                    .else_block = err_id,
                } });

                self.startBlock(err_id, "catch.err");
                const err_value = try self.emit(error_ty, .{ .try_err = value });
                try self.emitNoResult(error_ty, .{ .store_local = .{ .name = catch_expr.err_name, .value = err_value } });
                // Stash the error payload so `if e == .v |c|` in the handler can
                // recover it (the binding loads `__errpayload`). The payload
                // shares the fallible's value slot, so its type is the ok type.
                const ok_ty: IrType = switch (self.exprType(catch_expr.value.*)) {
                    .fallible => |fallible| fallible.ok.*,
                    else => .unknown,
                };
                const payload_value = try self.emit(ok_ty, .{ .try_payload = value });
                try self.emitNoResult(ok_ty, .{ .store_local = .{ .name = "__errpayload", .value = payload_value } });
                try self.local_types.put("__errpayload", ok_ty);
                _ = try self.emit(.void, .{ .builtin = .{
                    .name = "catch_handler",
                    .args = try self.allocator.dupe(Value, &.{err_value}),
                } });
                try self.lowerBlock(catch_expr.handler.statements, .unreachable_term);

                self.startBlock(ok_id, "catch.ok");
                break :blk try self.emit(self.exprType(expr), .{ .try_ok = value });
            },
            .call => |call| blk: {
                // `EnumType.variant(payload)` construction: sema recorded it under
                // the callee id (like a bare enum literal). Lower to `variant_lit`
                // with the payload, if any.
                if (self.types.enum_lits.get(call.callee.id)) |lit| {
                    const payload: ?Value = if (call.args.len > 0) p: {
                        const arg = switch (call.args[0]) {
                            .positional => |e| e,
                            .named => |n| n.value,
                        };
                        // Lower with the variant's payload type, and materialize a
                        // bare immediate into a typed register: the backend resolves
                        // a variant_lit payload against `.unknown`, so an untyped
                        // imm would collapse to a zero-width `i0`.
                        const pty = self.variantPayloadIrType(lit.type_name, lit.variant);
                        const raw = try self.lowerExprAs(arg, pty);
                        break :p switch (raw) {
                            .imm => |im| try self.emitAt(pty, .{ .const_value = im }, expr.span),
                            else => raw,
                        };
                    } else null;
                    break :blk try self.emit(self.exprType(expr), .{ .variant_lit = .{
                        .type_name = lit.type_name,
                        .variant = lit.variant,
                        .payload = payload,
                    } });
                }
                // Detect zone method calls: sema marks the field-callee expr with zone_handle.
                if (call.callee.kind == .field) {
                    const fld = call.callee.kind.field;
                    // `g.val()` resolved to an interface-impl method: a direct call to
                    // the `{type}.{interface}.{method}` function the vtable lowering
                    // already emits. The value receiver is `&`-d when sema flagged it.
                    if (self.types.impl_method_calls.get(call.callee.id)) |ic| {
                        const mangled = try interfaceMethodName(self.allocator, ic.type_name, ic.interface_name, ic.method_name);
                        var args = std.ArrayList(Value).empty;
                        errdefer args.deinit(self.allocator);
                        const recv = if (self.types.receiver_auto_addr.contains(call.callee.id))
                            try self.lowerLValueAddress(fld.base.*)
                        else
                            try self.lowerExpr(fld.base.*);
                        try args.append(self.allocator, recv);
                        for (call.args) |arg| {
                            const v = switch (arg) {
                                .positional => |e| e,
                                .named => |n| n.value,
                            };
                            try args.append(self.allocator, try self.lowerExpr(v));
                        }
                        break :blk try self.emit(self.exprType(expr), .{ .call = .{ .callee = mangled, .args = try args.toOwnedSlice(self.allocator) } });
                    }
                    if (self.exprType(fld.base.*) == .interface_value) {
                        const iface_name = self.exprType(fld.base.*).interface_value;
                        if (self.interfaceMethodIndex(iface_name, fld.name)) |method_index| {
                            const iface = try self.lowerExpr(fld.base.*);
                            const data = try self.emit(.{ .ptr = try boxType(self.allocator, .void) }, .{ .interface_data = iface });
                            const callee = try self.emit(.{ .ptr = try boxType(self.allocator, .void) }, .{ .interface_method = .{
                                .value = iface,
                                .index = method_index,
                            } });
                            var args = std.ArrayList(Value).empty;
                            errdefer args.deinit(self.allocator);
                            try args.append(self.allocator, data);
                            for (call.args) |arg| switch (arg) {
                                .positional => |value| try args.append(self.allocator, try self.lowerExpr(value)),
                                .named => |named| try args.append(self.allocator, try self.lowerExpr(named.value)),
                            };
                            break :blk try self.emit(self.exprType(expr), .{ .call_indirect = .{
                                .callee = callee,
                                .args = try args.toOwnedSlice(self.allocator),
                            } });
                        }
                    }
                    if (self.types.expr_types.get(call.callee.id)) |callee_ty| {
                        if (callee_ty == .zone_handle) {
                            const zone_field = call.callee.kind.field;
                            const zone_name = switch (zone_field.base.kind) {
                                .ident => |n| n,
                                else => break :blk Value{ .imm = .null },
                            };
                            break :blk try self.lowerZoneMethod(zone_name, zone_field.name, call.args, expr);
                        }
                        // `b.f(args)` where `f` is a fn-pointer struct field → a THIN
                        // indirect call through the stored pointer (no env: a struct
                        // fn-ptr field is a thin C pointer, not a fat closure).
                        if (callee_ty == .fn_ptr) {
                            const fp = callee_ty.fn_ptr;
                            const callee_val = try self.lowerExpr(call.callee.*);
                            var args = std.ArrayList(Value).empty;
                            errdefer args.deinit(self.allocator);
                            var arg_ts = std.ArrayList(IrType).empty;
                            errdefer arg_ts.deinit(self.allocator);
                            for (call.args, 0..) |arg, i| {
                                const v = switch (arg) {
                                    .positional => |e| e,
                                    .named => |n| n.value,
                                };
                                const ety: ?IrType = if (i < fp.params.len)
                                    (lowerSemaTypeWithEnv(self.allocator, fp.params[i], self.types, self.symbols) catch null)
                                else
                                    null;
                                try args.append(self.allocator, if (ety) |t| try self.lowerExprAs(v, t) else try self.lowerExpr(v));
                                try arg_ts.append(self.allocator, ety orelse .unknown);
                            }
                            break :blk try self.emit(self.exprType(expr), .{ .call_indirect = .{
                                .callee = callee_val,
                                .args = try args.toOwnedSlice(self.allocator),
                                .param_tys = try arg_ts.toOwnedSlice(self.allocator),
                                .is_closure = false,
                            } });
                        }
                    }
                    if (self.types.extension_calls.get(call.callee.id)) |extension_id| {
                        const sig = self.types.fn_sigs.get(extension_id) orelse {
                            diag_mod.printIce("extension call target has no signature record", @src());
                            return error.LoweringFailed;
                        };
                        const symbol = self.symbols.symbol(extension_id);
                        var args = std.ArrayList(Value).empty;
                        errdefer args.deinit(self.allocator);

                        var source_index: usize = 0;
                        var inserted_receiver = false;
                        for (sig.params) |param| {
                            if (param.is_type_param) {
                                const constrained = for (sig.type_constraints) |constraint| {
                                    if (std.mem.eql(u8, constraint.param, param.name)) break true;
                                } else false;
                                if (constrained) continue;
                                source_index += 1;
                                continue;
                            }

                            const is_receiver = !inserted_receiver;
                            const value = if (!inserted_receiver) receiver: {
                                inserted_receiver = true;
                                break :receiver fld.base.*;
                            } else source: {
                                if (source_index >= call.args.len) {
                                    diag_mod.printIce("extension call: argument index out of range", @src());
                                    return error.LoweringFailed;
                                }
                                const source_arg = call.args[source_index];
                                source_index += 1;
                                break :source switch (source_arg) {
                                    .positional => |value| value,
                                    .named => |named| named.value,
                                };
                            };
                            // UFCS auto-ref: a value receiver for a `*Self` method
                            // is lowered as `&receiver` (sema flagged it).
                            if (is_receiver and self.types.receiver_auto_addr.contains(call.callee.id)) {
                                try args.append(self.allocator, try self.lowerLValueAddress(value));
                            } else {
                                var expected = try lowerSemaTypeWithEnv(self.allocator, param.ty, self.types, self.symbols);
                                // A param typed as the struct's own type param (`key: K`)
                                // lowers to `.unknown` here. Resolve it against THIS call's
                                // instantiation binding (K→Point) so an inline `.{ … }`
                                // argument is materialized at its real type, not garbage.
                                if (expected == .unknown) {
                                    if (self.types.generic_call_insts.get(call.callee.id)) |mangled| {
                                        for (self.types.generic_instantiations.items) |inst| {
                                            if (!std.mem.eql(u8, inst.mangled_name, mangled)) continue;
                                            const r = lowerSemaTypeWithEnv(self.allocator, resolveTypeParamInTy(param.ty, inst.type_args), self.types, self.symbols) catch IrType.unknown;
                                            if (r != .unknown) expected = r;
                                            break;
                                        }
                                    }
                                    if (expected == .unknown) {
                                        const et = self.exprType(value);
                                        if (et != .unknown) expected = et;
                                    }
                                }
                                try args.append(self.allocator, try self.lowerExprAs(value, expected));
                            }
                        }

                        const callee_name = self.types.generic_call_insts.get(call.callee.id) orelse symbol.name;
                        break :blk try self.emit(self.exprType(expr), .{ .call = .{
                            .callee = callee_name,
                            .args = try args.toOwnedSlice(self.allocator),
                        } });
                    }
                }

                const callee_name = switch (call.callee.kind) {
                    .ident => |name| name,
                    // `core::panic` maps to the `@panic` intrinsic so it reuses the
                    // existing runtime-symbol + VM-trap lowering. Other `core::`
                    // members map their friendly spelling to the internal builtin
                    // name (routed via `isBuiltinName`).
                    .scope_access => |sa| if (isCoreNs(sa)) coreCanonical(sa.member) else sa.member,
                    else => "<expr>",
                };
                // The callee's top-level symbol, resolved file-aware (so a
                // collision-mangled function links by its module-qualified name).
                // `core::` is not a real module, so its symbol is always null (like a
                // bare builtin) — routed by `callee_name` below.
                const callee_sym: ?sema.SymbolId = switch (call.callee.kind) {
                    .ident => resolveTopLevel(self.symbols, self.file_name, callee_name),
                    // `core::` resolves its CANONICAL name (= `callee_name`): a real
                    // builtin like `sizeof` has no symbol (→ builtin path), but
                    // `core::panic`→`@panic` resolves the runtime symbol so it lowers
                    // as a DIRECT call exactly like bare `@panic` (same exit status).
                    .scope_access => |sa| if (isCoreNs(sa)) resolveTopLevel(self.symbols, self.file_name, callee_name) else self.resolveScope(sa),
                    else => null,
                };
                // compiler_decls() (Phase 3 introspection): materialize the
                // program's top-level declarations as a `[]Decl` the hook can
                // `for`-iterate. Handled before the generic builtin path because
                // it reads the live module rather than lowering value args.
                if (std.mem.eql(u8, callee_name, "compiler_decls")) {
                    break :blk try self.lowerCompilerDecls();
                }
                // asm(...) needs structural constraint parsing — handle before generic builtin path.
                if (std.mem.eql(u8, callee_name, "asm")) {
                    break :blk try self.lowerAsmCall(call, expr);
                }
                // core::fn_ptr(f) — the RAW thin function pointer of a top-level
                // function, as a `*void` usable as a C callback / thread entry.
                // Bypasses k2's fat `{fn, env}` closure (which a C ABI can't call):
                // reuses the same raw-function-arg lowering as a direct extern call.
                if (call.callee.kind == .scope_access and isCoreNs(call.callee.kind.scope_access) and
                    std.mem.eql(u8, callee_name, "fn_ptr") and call.args.len == 1)
                {
                    const fn_arg = switch (call.args[0]) {
                        .positional => |e| e,
                        .named => |n| n.value,
                    };
                    break :blk try self.lowerRawFnArg(fn_arg);
                }
                // sizeof/type_info/type_name take a TYPE as their sole argument,
                // not a value — it goes into `type_arg`, never lowered as a value
                // (lowering a type parameter `T` as a value produces a bad reg
                // and crashes a later pass).
                const is_type_arg_builtin = std.mem.eql(u8, callee_name, "sizeof") or
                    std.mem.eql(u8, callee_name, "type_info") or
                    std.mem.eql(u8, callee_name, "type_name");
                // These take a TYPE as their first argument (the rest are
                // values). The type is not lowered as a value — it would crash
                // on a type parameter `T` — but a placeholder keeps the value
                // args at their expected indices (the LLVM lowerings read
                // args[1]+ and ignore args[0]).
                const type_first_builtin = std.mem.eql(u8, callee_name, "truncate_to") or
                    std.mem.eql(u8, callee_name, "ptr_from_int") or
                    std.mem.eql(u8, callee_name, "unaligned_read") or
                    std.mem.eql(u8, callee_name, "slice_from_raw_parts");

                var args = std.ArrayList(Value).empty;
                errdefer args.deinit(self.allocator);
                // Parallel to `args`: the expected IR type of each argument (or
                // `.unknown`). Used to type an indirect call's `.imm` literal args.
                var arg_tys = std.ArrayList(IrType).empty;
                errdefer arg_tys.deinit(self.allocator);
                const direct_sig = if (callee_sym) |id| self.types.fn_sigs.get(id) else null;
                // For an INDIRECT call (a fn-pointer local/param, e.g. a lambda or
                // `f := dbl`) there's no direct signature — type the args from the
                // callee's fn-pointer signature so an untyped literal gets the
                // right width instead of a zero-width `i0`.
                const indirect_params: ?[]const sema.Ty = if (direct_sig == null) ip: {
                    const cty = self.types.expr_types.get(call.callee.id) orelse break :ip null;
                    break :ip switch (cty) {
                        .fn_ptr => |fp| fp.params,
                        else => null,
                    };
                } else null;
                var value_param_index: usize = 0;
                // Bind explicit type arguments (e.g. the `Point` in `f(Point, v)`)
                // so a following value param declared `v: T` gets `T`'s concrete
                // type as its expected type — otherwise an inline `.{…}` argument
                // is lowered untyped and reads as garbage.
                var call_tp_ir = std.StringHashMap(IrType).init(self.allocator);
                defer call_tp_ir.deinit();
                if (!is_type_arg_builtin) for (call.args, 0..) |arg, arg_idx| {
                    if (type_first_builtin and arg_idx == 0) {
                        try args.append(self.allocator, .{ .imm = .null });
                        try arg_tys.append(self.allocator, .unknown);
                        continue;
                    }
                    const value = switch (arg) {
                        .positional => |value| value,
                        .named => |named| named.value,
                    };
                    var expected: ?IrType = null;
                    var is_explicit_type_arg = false;
                    var raw_fn_ptr = false;
                    if (direct_sig) |sig| {
                        while (value_param_index < sig.params.len and sig.params[value_param_index].is_type_param) {
                            const type_param = sig.params[value_param_index];
                            value_param_index += 1;
                            const is_constrained = for (sig.type_constraints) |constraint| {
                                if (std.mem.eql(u8, constraint.param, type_param.name)) break true;
                            } else false;
                            if (!is_constrained) {
                                is_explicit_type_arg = true;
                                // Remember the concrete type this `$T` is bound to.
                                if (self.lowerTypeArg(value)) |bound_ty| {
                                    call_tp_ir.put(type_param.name, bound_ty) catch {};
                                } else |_| {}
                                break;
                            }
                        }
                        if (is_explicit_type_arg) continue;
                        if (value_param_index < sig.params.len) {
                            const pty = sig.params[value_param_index].ty;
                            if (pty == .type_param) {
                                if (call_tp_ir.get(pty.type_param)) |bound| expected = bound;
                            }
                            if (expected == null)
                                expected = lowerSemaTypeWithEnv(self.allocator, pty, self.types, self.symbols) catch null;
                            // A `fn(...)` arg to an `#extern` C function is a THIN raw
                            // pointer (no closure/env) — C cannot call a fat closure.
                            if (sig.extern_name != null and pty == .fn_ptr) raw_fn_ptr = true;
                            value_param_index += 1;
                        }
                    } else if (indirect_params) |params| {
                        if (arg_idx < params.len)
                            expected = lowerSemaTypeWithEnv(self.allocator, params[arg_idx], self.types, self.symbols) catch null;
                    }
                    if (raw_fn_ptr) {
                        try args.append(self.allocator, try self.lowerRawFnArg(value));
                    } else try args.append(self.allocator, if (expected) |ty| try self.lowerExprAs(value, ty) else try self.lowerExpr(value));
                    try arg_tys.append(self.allocator, expected orelse .unknown);
                };
                const arg_slice = try args.toOwnedSlice(self.allocator);
                const arg_ty_slice = try arg_tys.toOwnedSlice(self.allocator);
                // `require(T, Other)` is a constraint-composition guard checked in
                // sema (runConstraintPredicate), so it's a no-op at eval time.
                if (self.in_where and std.mem.eql(u8, callee_name, "require")) {
                    break :blk .{ .imm = .null };
                }
                // `reject(msg)` inside a `where` predicate terminates with
                // `return msg` (the predicate returns the rejection message).
                if (self.in_where and std.mem.eql(u8, callee_name, "reject")) {
                    const msg: Value = if (call.args.len > 0) m: {
                        const arg = switch (call.args[0]) {
                            .positional => |e| e,
                            .named => |n| n.value,
                        };
                        break :m try self.lowerExpr(arg);
                    } else .{ .imm = .{ .text = "rejected" } };
                    try self.terminate(.{ .return_value = msg });
                    break :blk .{ .imm = .null };
                }
                // `type_info(T)` materializes a matchable `TypeInfo` value instead
                // of a folded builtin — `match`/field access then work normally.
                if (std.mem.eql(u8, callee_name, "type_info") and call.args.len > 0) {
                    const first = switch (call.args[0]) {
                        .positional => |e| e,
                        .named => |n| n.value,
                    };
                    const ty = try self.lowerTypeArg(first);
                    break :blk try self.materializeTypeInfo(ty);
                }
                // `typeid_of(T)` folds to a stable content hash of the type — a
                // runtime identity that's cheap to compare and stable across
                // compilation units (the same type always hashes the same).
                if (std.mem.eql(u8, callee_name, "typeid_of") and call.args.len > 0) {
                    const first = switch (call.args[0]) {
                        .positional => |e| e,
                        .named => |n| n.value,
                    };
                    const ty = try self.lowerTypeArg(first);
                    break :blk .{ .imm = .{ .uint = typeIdHash(ty) } };
                }
                // `__str_cat(a, b)` — VM-native comptime string concat (CodeBuf).
                if (std.mem.eql(u8, callee_name, "__str_cat") and call.args.len == 2) {
                    const a0 = switch (call.args[0]) {
                        .positional => |e| e,
                        .named => |n| n.value,
                    };
                    const a1 = switch (call.args[1]) {
                        .positional => |e| e,
                        .named => |n| n.value,
                    };
                    const lhs = try self.lowerExpr(a0);
                    const rhs = try self.lowerExpr(a1);
                    break :blk try self.emit(string_slice_ty, .{ .builtin = .{
                        .name = "__str_cat",
                        .args = try self.allocator.dupe(Value, &.{ lhs, rhs }),
                    } });
                }
                // `compiler_error(msg)` — VM halts the hook with the diagnostic; at
                // runtime it's never executed (hooks aren't run), so it's a no-op.
                if (std.mem.eql(u8, callee_name, "compiler_error") and call.args.len == 1) {
                    const m = switch (call.args[0]) {
                        .positional => |e| e,
                        .named => |n| n.value,
                    };
                    const msg = try self.lowerExpr(m);
                    break :blk try self.emit(.void, .{ .builtin = .{
                        .name = "compiler_error",
                        .args = try self.allocator.dupe(Value, &.{msg}),
                    } });
                }
                // `compiler_remove(name)` — a hook records a top-level decl to drop
                // (mutation; unlike compiler_error it does NOT halt). No-op at runtime.
                if (std.mem.eql(u8, callee_name, "compiler_remove") and call.args.len == 1) {
                    const m = switch (call.args[0]) {
                        .positional => |e| e,
                        .named => |n| n.value,
                    };
                    const nm = try self.lowerExpr(m);
                    break :blk try self.emit(.void, .{ .builtin = .{
                        .name = "compiler_remove",
                        .args = try self.allocator.dupe(Value, &.{nm}),
                    } });
                }
                // `type_name(T)` folds to the type's name string at lowering, so it
                // works at runtime (not just on the VM) — same string as comptime.
                if (std.mem.eql(u8, callee_name, "type_name") and call.args.len > 0) {
                    const first = switch (call.args[0]) {
                        .positional => |e| e,
                        .named => |n| n.value,
                    };
                    const ty = try self.lowerTypeArg(first);
                    break :blk .{ .imm = .{ .text = vm_compiler.typeNameMangle(ty) } };
                }
                // `any(x)` wraps a value into a type-erased `Any { data, id, name }`.
                // Only when `any` isn't a user function: a user fn named `any`
                // (e.g. `slice::any`) resolves to a symbol and takes precedence,
                // just like the math builtins defer to a user `min`/`max`.
                if (std.mem.eql(u8, callee_name, "any") and call.args.len > 0 and callee_sym == null) {
                    const arg = switch (call.args[0]) {
                        .positional => |e| e,
                        .named => |n| n.value,
                    };
                    break :blk try self.lowerAnyWrap(arg);
                }
                // Route to a `.builtin` node. The newer math/bit/memory families
                // share names with plausible user functions (`min`, `max`, `abs`, …),
                // so they only become builtins under `core::` — a bare `min(...)`
                // still resolves to a user function below.
                const is_core_call = call.callee.kind == .scope_access and isCoreNs(call.callee.kind.scope_access);
                if (isBuiltinName(callee_name) and (is_core_call or !isCoreOnlyBuiltin(callee_name))) {
                    var type_arg: ?IrType = null;
                    if (is_type_arg_builtin and call.args.len > 0) {
                        const first = switch (call.args[0]) {
                            .positional => |e| e,
                            .named => |n| n.value,
                        };
                        type_arg = try self.lowerTypeArg(first);
                    }
                    break :blk try self.emit(self.exprType(expr), .{ .builtin = .{ .name = callee_name, .args = arg_slice, .type_arg = type_arg } });
                }

                // Determine if this is a direct (top-level function) or indirect (fn-ptr variable) call.
                const is_direct = if (callee_sym) |id| self.symbols.symbol(id).kind == .function else false;

                if (!is_direct and callee_name.len > 0 and callee_name[0] != '<') {
                    // Function-pointer call: resolve the callee as a Value (param or local).
                    const callee_val: Value = cv: {
                        for (self.params) |p| {
                            if (std.mem.eql(u8, p.name, callee_name)) break :cv .{ .param = callee_name };
                        }
                        break :cv .{ .local = callee_name };
                    };
                    // Only a genuine k2 function VALUE (a fat `{ fn, env }` closure)
                    // is called through its env. A THIN `extern fn(...)` pointer and
                    // other raw callees (`@`-prefixed runtime fns) are called by
                    // their bare pointer — a direct indirect call.
                    const callee_is_closure = switch (self.exprType(call.callee.*)) {
                        .fn_ptr => |fp| !fp.thin,
                        else => false,
                    };
                    break :blk try self.emit(self.exprType(expr), .{ .call_indirect = .{
                        .callee = callee_val,
                        .args = arg_slice,
                        .param_tys = arg_ty_slice,
                        .is_closure = callee_is_closure,
                    } });
                }

                // Emit the callee's linkage name: a generic instantiation's
                // mangled name if sema recorded one, else the symbol's link_name
                // (module-qualified on a collision), else the bare name.
                const call_callee = self.types.generic_call_insts.get(call.callee.id) orelse
                    (if (callee_sym) |id| self.symbols.symbol(id).link_name else callee_name);
                break :blk try self.emit(self.exprType(expr), .{ .call = .{ .callee = call_callee, .args = arg_slice } });
            },
            .field => |field| blk: {
                // Detect enum variant access: `Direction.north`
                // The base is an ident that resolves to a TYPE symbol (not a value).
                if (field.base.kind == .ident) {
                    const base_ident = field.base.kind.ident;
                    if (self.symbols.resolve(self.symbols.root_scope, base_ident)) |sym_id| {
                        if (self.symbols.symbol(sym_id).kind == .type) {
                            break :blk try self.emit(self.exprType(expr), .{ .variant_lit = .{
                                .type_name = base_ident,
                                .variant = field.name,
                                .payload = null,
                            } });
                        }
                    }
                }
                const base = try self.lowerExpr(field.base.*);
                break :blk try self.emitAt(self.exprType(expr), .{ .field = .{ .base = base, .name = field.name } }, expr.span);
            },
            .index => |index| blk: {
                const base = try self.lowerExpr(index.base.*);
                const idx = try self.lowerExpr(index.index.*);
                break :blk try self.emitAt(self.exprType(expr), .{ .index = .{ .base = base, .index = idx } }, expr.span);
            },
            .slice => |slice| blk: {
                const base_ty = self.exprType(slice.base.*);
                if (slice.start != null or slice.end != null) {
                    // An `.unknown` base happens when lowering for the comptime
                    // cache from the hook-pass's *tolerant* sema; treat it as a
                    // slice-of-unknown rather than a hard ICE (the VM cell model
                    // doesn't need a precise element type).
                    const is_array = base_ty == .array;
                    const elem_ty: IrType = switch (base_ty) {
                        .array => |array| array.elem.*,
                        .slice => |inner| inner.*,
                        else => .unknown,
                    };

                    const start_val: Value = if (slice.start) |start_expr|
                        try self.lowerExpr(start_expr.*)
                    else
                        .{ .imm = .{ .uint = 0 } };

                    const base_len: Value = if (is_array)
                        .{ .imm = .{ .uint = base_ty.array.len } }
                    else
                        try self.emit(.usize, .{ .field = .{ .base = try self.lowerExpr(slice.base.*), .name = "len" } });
                    const end_val: Value = if (slice.end) |end_expr|
                        try self.lowerExpr(end_expr.*)
                    else
                        base_len;

                    const base_addr = if (is_array)
                        try self.lowerLValueAddress(slice.base.*)
                    else
                        try self.lowerExpr(slice.base.*);
                    const ptr_ty: IrType = .{ .ptr = try boxType(self.allocator, elem_ty) };
                    const offset_ptr = try self.emitAt(ptr_ty, .{ .index_addr = .{ .base = base_addr, .index = start_val } }, expr.span);
                    const len = try self.emit(.usize, .{ .binary = .{ .op = .sub, .lhs = end_val, .rhs = start_val } });
                    break :blk try self.emit(self.exprType(expr), .{ .slice_expr = .{ .ptr = offset_ptr, .len = len } });
                }
                switch (base_ty) {
                    .array => |array| {
                        const ptr = try self.lowerLValueAddress(slice.base.*);
                        const len: Value = .{ .imm = .{ .uint = array.len } };
                        break :blk try self.emit(self.exprType(expr), .{ .slice_expr = .{ .ptr = ptr, .len = len } });
                    },
                    .slice => break :blk try self.lowerExpr(slice.base.*),
                    else => {
                        const base = try self.lowerExpr(slice.base.*);
                        break :blk try self.emit(self.exprType(expr), .{ .builtin = .{ .name = "slice", .args = try self.allocator.dupe(Value, &.{base}) } });
                    },
                }
            },
        };
    }

    /// Wrap `arg` into a type-erased `Any { data, id, name }`: spill it to a
    /// temporary, take its address, and record its typeid + name. Shared by the
    /// `any(x)` builtin and the value→`Any` auto-wrap.
    fn lowerAnyWrap(self: *FunctionLowerer, arg: ast.Expr) LowerError!Value {
        const val = try self.lowerExpr(arg);
        const val_ty = self.exprType(arg);
        // An immediate has no address; force it into a register (a no-op cast) so
        // `.ref` spills it to a temporary we can point at.
        const spillable: Value = if (val == .imm)
            try self.emit(val_ty, .{ .cast = .{ .kind = .as, .value = val } })
        else
            val;
        const ptr = try self.emit(.{ .ptr = try boxType(self.allocator, val_ty) }, .{ .unary = .{ .op = .ref, .value = spillable } });
        const id_val: Value = .{ .imm = .{ .uint = typeIdHash(val_ty) } };
        const name_val: Value = .{ .imm = .{ .text = vm_compiler.typeNameMangle(val_ty) } };
        return self.emit(.{ .struct_type = "Any" }, .{ .builtin = .{
            .name = "compound_literal",
            .args = try self.allocator.dupe(Value, &.{ ptr, id_val, name_val }),
        } });
    }

    fn lowerExprAs(self: *FunctionLowerer, expr: ast.Expr, expected_ty: IrType) LowerError!Value {
        // A `match` in value position threads the expected type into its arms, so
        // untyped arm values (`.{ … }`, `.variant`) get the right target type.
        if (expr.kind == .match_expr) return self.lowerMatchExpr(expr, expected_ty);
        if (expr.kind == .if_expr) return self.lowerIfExpr(expr, expected_ty);
        // A value passed where an `Any` is expected auto-wraps (compiler inserts
        // `any(x)`) — unless it's already an `Any`, or a literal that *constructs*
        // the `Any` (`.{ data, id, name }`), or an unknown-typed expr.
        if (expected_ty == .struct_type and std.mem.eql(u8, expected_ty.struct_type, "Any") and
            expr.kind != .compound_literal)
        {
            const et = self.exprType(expr);
            const already_any = et == .unknown or
                (et == .struct_type and std.mem.eql(u8, et.struct_type, "Any"));
            if (!already_any) return self.lowerAnyWrap(expr);
        }
        if (expected_ty == .interface_value and self.exprType(expr) != .interface_value) {
            return self.lowerInterfaceCoercion(expr, expected_ty.interface_value);
        }
        if (expected_ty == .optional and self.exprType(expr) != .optional and expr.kind != .null) {
            // Lower the payload AT the optional's payload type so a nested literal
            // (`here: ?Point = .{7,8}`) gets the right field types, not an untyped
            // aggregate that reads back as garbage.
            const payload = try self.lowerExprAs(expr, expected_ty.optional.*);
            return self.emit(expected_ty, .{ .builtin = .{
                .name = "optional_some",
                .args = try self.allocator.dupe(Value, &.{payload}),
            } });
        }
        // `.{ a, b, … }` where a SLICE is expected: materialize a backing array on
        // the stack and take a full slice of it (otherwise the `{ptr,len}` slice is
        // built with no storage → a dangling pointer that crashes when read).
        if (expected_ty == .slice and expr.kind == .compound_literal) {
            const values = expr.kind.compound_literal;
            const elem_ty = expected_ty.slice.*;
            const arr_ty: IrType = .{ .array = .{ .elem = try boxType(self.allocator, elem_ty), .len = values.len } };
            var arr_args = std.ArrayList(Value).empty;
            errdefer arr_args.deinit(self.allocator);
            for (values) |value| try arr_args.append(self.allocator, try self.lowerExprAs(value, elem_ty));
            const arr_val = try self.emit(arr_ty, .{ .builtin = .{ .name = "compound_literal", .args = try arr_args.toOwnedSlice(self.allocator) } });
            self.temp_id += 1;
            const name = try std.fmt.allocPrint(self.allocator, "__slicelit_{d}", .{self.temp_id});
            try self.local_types.put(name, arr_ty);
            try self.emitNoResult(arr_ty, .{ .store_local = .{ .name = name, .value = arr_val } });
            const ptr_ty: IrType = .{ .ptr = try boxType(self.allocator, elem_ty) };
            const elem0 = try self.emit(ptr_ty, .{ .index_addr = .{ .base = .{ .local = name }, .index = .{ .imm = .{ .uint = 0 } } } });
            return self.emit(expected_ty, .{ .slice_expr = .{ .ptr = elem0, .len = .{ .imm = .{ .uint = values.len } } } });
        }
        return switch (expr.kind) {
            .compound_literal => |values| blk: {
                var args = std.ArrayList(Value).empty;
                errdefer args.deinit(self.allocator);
                for (values, 0..) |value, i| {
                    if (self.compoundFieldType(expected_ty, i)) |fty| {
                        // A `fn(...)` struct field holds a THIN raw function pointer.
                        if (fty == .fn_ptr)
                            try args.append(self.allocator, try self.lowerRawFnArg(value))
                        else
                            try args.append(self.allocator, try self.lowerExprAs(value, fty));
                    } else try args.append(self.allocator, try self.lowerExpr(value));
                }
                try self.appendTrailingDefaults(&args, expected_ty, values.len);
                break :blk try self.emit(expected_ty, .{ .builtin = .{ .name = "compound_literal", .args = try args.toOwnedSlice(self.allocator) } });
            },
            .struct_literal => |inits| try self.lowerStructLiteral(inits, expected_ty, expr.span),
            else => try self.lowerExpr(expr),
        };
    }

    /// Type of the i-th element of a compound literal of aggregate type `ty`
    /// (array element or struct field), or null if it can't be determined.
    fn compoundFieldType(self: *FunctionLowerer, ty: IrType, index: usize) ?IrType {
        switch (ty) {
            .array => |arr| return arr.elem.*,
            .struct_type => |name| {
                const id = self.symbols.resolve(self.symbols.root_scope, name) orelse return null;
                const layout = self.types.layouts.get(id) orelse return null;
                switch (layout.kind) {
                    .struct_type => |fields| {
                        if (index >= fields.len) return null;
                        return lowerSemaTypeWithEnv(self.allocator, fields[index].ty, self.types, self.symbols) catch null;
                    },
                    else => return null,
                }
            },
            else => return null,
        }
    }

    /// The declared fields of a struct `IrType` (declaration order), or null if
    /// `ty` is not a resolvable struct.
    fn structFields(self: *FunctionLowerer, ty: IrType) ?[]const sema.FieldInfo {
        if (ty != .struct_type) return null;
        const id = self.symbols.resolve(self.symbols.root_scope, ty.struct_type) orelse return null;
        const layout = self.types.layouts.get(id) orelse return null;
        return switch (layout.kind) {
            .struct_type => |fields| fields,
            else => null,
        };
    }

    /// Lower a named struct literal `.{ .x = …, .y = … }` against `struct_ty`:
    /// reorder the inits into declaration order, fill an omitted field from its
    /// declared default (and error if it has none), reject unknown field names,
    /// then build the aggregate exactly like a positional literal.
    fn lowerStructLiteral(self: *FunctionLowerer, inits: []const ast.FieldInit, struct_ty: IrType, span: Span) LowerError!Value {
        const fields = self.structFields(struct_ty) orelse {
            diag_mod.printErrorAt("a `.{ .field = … }` struct literal needs a known struct type here", self.file_name, self.source, span);
            return error.LoweringFailed;
        };
        // Reject names that aren't fields of the struct.
        for (inits) |fi| {
            var known = false;
            for (fields) |f| if (std.mem.eql(u8, f.name, fi.name)) {
                known = true;
                break;
            };
            if (!known) {
                const msg = std.fmt.allocPrint(self.allocator, "no field `{s}` in struct `{s}`", .{ fi.name, struct_ty.struct_type }) catch "unknown field in struct literal";
                diag_mod.printErrorAt(msg, self.file_name, self.source, fi.span);
                return error.LoweringFailed;
            }
        }
        var args = std.ArrayList(Value).empty;
        errdefer args.deinit(self.allocator);
        for (fields) |field| {
            const fty = lowerSemaTypeWithEnv(self.allocator, field.ty, self.types, self.symbols) catch IrType.unknown;
            var provided: ?ast.Expr = null;
            for (inits) |fi| if (std.mem.eql(u8, fi.name, field.name)) {
                provided = fi.value;
                break;
            };
            const value = provided orelse field.default orelse {
                const msg = std.fmt.allocPrint(self.allocator, "missing field `{s}` in struct literal (it has no default value)", .{field.name}) catch "missing field in struct literal";
                diag_mod.printErrorAt(msg, self.file_name, self.source, span);
                return error.LoweringFailed;
            };
            if (fty == .fn_ptr)
                try args.append(self.allocator, try self.lowerRawFnArg(value))
            else
                try args.append(self.allocator, try self.lowerExprAs(value, fty));
        }
        return self.emit(struct_ty, .{ .builtin = .{ .name = "compound_literal", .args = try args.toOwnedSlice(self.allocator) } });
    }

    /// If `ty` is a PAYLOAD enum (an aggregate `{tag, payload}`), its type name;
    /// else null. A simple/payloadless enum is a scalar and is not flagged here.
    /// (An enum's IR type is `.struct_type "E"`; its layout kind is `.variant_type`.)
    fn payloadEnumName(self: *FunctionLowerer, ty: IrType) ?[]const u8 {
        if (ty != .struct_type) return null;
        const id = self.symbols.resolve(self.symbols.root_scope, ty.struct_type) orelse return null;
        const layout = self.types.layouts.get(id) orelse return null;
        return switch (layout.kind) {
            .variant_type => |variants| blk: {
                for (variants) |v| if (v.payload != null) break :blk ty.struct_type;
                break :blk null;
            },
            else => null,
        };
    }

    /// `e1 == e2` on a payload enum: same variant AND (payloadless OR payloads
    /// equal). Built as OR over variants of `is(e1,V) && is(e2,V) && payloadEq`.
    /// Returns null when any variant carries a non-scalar payload — reading the
    /// wrong variant's payload as an aggregate from a garbage slot is unsafe — so
    /// the caller falls back to an error there.
    fn lowerEnumEq(self: *FunctionLowerer, lhs: Value, rhs: Value, ename: []const u8) LowerError!?Value {
        const id = self.symbols.resolve(self.symbols.root_scope, ename) orelse return null;
        const layout = self.types.layouts.get(id) orelse return null;
        const variants = switch (layout.kind) {
            .variant_type => |vs| vs,
            else => return null,
        };
        for (variants) |v| if (v.payload) |pty| {
            const ip = lowerSemaTypeWithEnv(self.allocator, pty, self.types, self.symbols) catch return null;
            if (!isScalarPayload(ip)) return null;
        };
        var result: ?Value = null;
        for (variants) |v| {
            const is1 = try self.emit(.bool, .{ .variant_is = .{ .value = lhs, .type_name = ename, .variant = v.name } });
            const is2 = try self.emit(.bool, .{ .variant_is = .{ .value = rhs, .type_name = ename, .variant = v.name } });
            var term = try self.emit(.bool, .{ .binary = .{ .op = .and_op, .lhs = is1, .rhs = is2 } });
            if (v.payload) |pty| {
                const ip = lowerSemaTypeWithEnv(self.allocator, pty, self.types, self.symbols) catch return null;
                const p1 = try self.emit(ip, .{ .variant_payload = .{ .value = lhs, .type_name = ename, .variant = v.name } });
                const p2 = try self.emit(ip, .{ .variant_payload = .{ .value = rhs, .type_name = ename, .variant = v.name } });
                const peq = try self.lowerValueEq(p1, p2, ip);
                term = try self.emit(.bool, .{ .binary = .{ .op = .and_op, .lhs = term, .rhs = peq } });
            }
            result = if (result) |r| try self.emit(.bool, .{ .binary = .{ .op = .or_op, .lhs = r, .rhs = term } }) else term;
        }
        return result orelse .{ .imm = .{ .bool = true } };
    }

    /// `a == b` on a struct: compare field by field (recursing into nested
    /// structs and byte-slice fields) and AND the results. This is valid LLVM
    /// (extractvalue + icmp + and) and runs on the comptime VM, replacing the
    /// invalid aggregate `icmp` that a scalar compare would emit.
    fn lowerStructEq(self: *FunctionLowerer, lhs: Value, rhs: Value, struct_ty: IrType) LowerError!Value {
        const fields = self.structFields(struct_ty) orelse
            return self.emit(.bool, .{ .binary = .{ .op = .eq, .lhs = lhs, .rhs = rhs } });
        var acc: ?Value = null;
        for (fields) |field| {
            const fty = lowerSemaTypeWithEnv(self.allocator, field.ty, self.types, self.symbols) catch IrType.unknown;
            const lf = try self.emit(fty, .{ .field = .{ .base = lhs, .name = field.name } });
            const rf = try self.emit(fty, .{ .field = .{ .base = rhs, .name = field.name } });
            const feq = try self.lowerValueEq(lf, rf, fty);
            acc = if (acc) |a| try self.emit(.bool, .{ .binary = .{ .op = .and_op, .lhs = a, .rhs = feq } }) else feq;
        }
        return acc orelse .{ .imm = .{ .bool = true } }; // a field-less struct is always equal
    }

    /// Equality of two values of IR type `ty`, choosing the right comparison:
    /// nested struct → field-by-field, array → element-by-element, slice →
    /// length + element compare, else a scalar `eq` (ints, floats, bools, plain
    /// enums, pointers). All of these are aggregates LLVM can't `icmp` directly.
    fn lowerValueEq(self: *FunctionLowerer, a: Value, b: Value, ty: IrType) LowerError!Value {
        if (ty == .struct_type) return self.lowerStructEq(a, b, ty);
        if (isByteSliceTy(ty)) return self.lowerStringEqDynamic(a, b);
        if (ty == .slice) return self.lowerSliceEqDynamic(a, b, ty.slice.*);
        if (ty == .array) {
            const arr = ty.array;
            var acc: ?Value = null;
            var i: u64 = 0;
            while (i < arr.len) : (i += 1) {
                const le = try self.emit(arr.elem.*, .{ .index = .{ .base = a, .index = .{ .imm = .{ .uint = i } } } });
                const re = try self.emit(arr.elem.*, .{ .index = .{ .base = b, .index = .{ .imm = .{ .uint = i } } } });
                const eeq = try self.lowerValueEq(le, re, arr.elem.*);
                acc = if (acc) |x| try self.emit(.bool, .{ .binary = .{ .op = .and_op, .lhs = x, .rhs = eeq } }) else eeq;
            }
            return acc orelse .{ .imm = .{ .bool = true } };
        }
        return self.emit(.bool, .{ .binary = .{ .op = .eq, .lhs = a, .rhs = b } });
    }

    /// `a == b` on a slice of any element type: equal length, then element by
    /// element (recursing via `lowerValueEq`). The byte-slice specialization is
    /// `lowerStringEqDynamic`; this is the general form for `[]T`.
    fn lowerSliceEqDynamic(self: *FunctionLowerer, lhs_in: Value, rhs_in: Value, elem_ty: IrType) LowerError!Value {
        const lhs = try self.materializeStrOperand(lhs_in);
        const rhs = try self.materializeStrOperand(rhs_in);
        const suffix = self.next_block_id;
        const res_name = try std.fmt.allocPrint(self.allocator, "__sliceq_{d}", .{suffix});
        const idx_name = try std.fmt.allocPrint(self.allocator, "__sliceq_i_{d}", .{suffix});
        try self.local_types.put(res_name, .bool);
        try self.local_types.put(idx_name, .usize);
        try self.emitNoResult(.bool, .{ .store_local = .{ .name = res_name, .value = .{ .imm = .{ .bool = false } } } });

        const lhs_len = try self.emit(.usize, .{ .field = .{ .base = lhs, .name = "len" } });
        const rhs_len = try self.emit(.usize, .{ .field = .{ .base = rhs, .name = "len" } });
        const len_eq = try self.emit(.bool, .{ .binary = .{ .op = .eq, .lhs = lhs_len, .rhs = rhs_len } });

        const init_id = self.allocBlockId();
        const cond_id = self.allocBlockId();
        const body_id = self.allocBlockId();
        const incr_id = self.allocBlockId();
        const matched_id = self.allocBlockId();
        const done_id = self.allocBlockId();

        try self.terminate(.{ .cond_branch = .{ .cond = len_eq, .then_block = init_id, .else_block = done_id } });

        self.startBlock(init_id, "sliceq.init");
        try self.emitNoResult(.usize, .{ .store_local = .{ .name = idx_name, .value = .{ .imm = .{ .uint = 0 } } } });
        try self.terminate(.{ .branch = cond_id });

        self.startBlock(cond_id, "sliceq.cond");
        const more = try self.emit(.bool, .{ .binary = .{ .op = .lt, .lhs = .{ .local = idx_name }, .rhs = lhs_len } });
        try self.terminate(.{ .cond_branch = .{ .cond = more, .then_block = body_id, .else_block = matched_id } });

        self.startBlock(body_id, "sliceq.body");
        const ea = try self.emit(elem_ty, .{ .index = .{ .base = lhs, .index = .{ .local = idx_name } } });
        const eb = try self.emit(elem_ty, .{ .index = .{ .base = rhs, .index = .{ .local = idx_name } } });
        const eeq = try self.lowerValueEq(ea, eb, elem_ty);
        try self.terminate(.{ .cond_branch = .{ .cond = eeq, .then_block = incr_id, .else_block = done_id } });

        self.startBlock(incr_id, "sliceq.incr");
        const nx = try self.emit(.usize, .{ .binary = .{ .op = .add, .lhs = .{ .local = idx_name }, .rhs = .{ .imm = .{ .uint = 1 } } } });
        try self.emitNoResult(.usize, .{ .store_local = .{ .name = idx_name, .value = nx } });
        try self.terminate(.{ .branch = cond_id });

        self.startBlock(matched_id, "sliceq.matched");
        try self.emitNoResult(.bool, .{ .store_local = .{ .name = res_name, .value = .{ .imm = .{ .bool = true } } } });
        try self.terminate(.{ .branch = done_id });

        self.startBlock(done_id, "sliceq.done");
        return .{ .local = res_name };
    }

    /// For a POSITIONAL struct literal that supplied fewer values than there are
    /// fields, append the declared defaults of the trailing fields (`.{}` and
    /// short `.{ a }` literals pick up defaults). Stops at the first remaining
    /// field with no default — the builtin zero-fills whatever is left — so
    /// defaults behave like trailing default arguments. No-op for non-structs.
    fn appendTrailingDefaults(self: *FunctionLowerer, args: *std.ArrayList(Value), ty: IrType, start: usize) LowerError!void {
        const fields = self.structFields(ty) orelse return;
        var i = start;
        while (i < fields.len) : (i += 1) {
            const dflt = fields[i].default orelse return;
            const fty = lowerSemaTypeWithEnv(self.allocator, fields[i].ty, self.types, self.symbols) catch IrType.unknown;
            if (fty == .fn_ptr)
                try args.append(self.allocator, try self.lowerRawFnArg(dflt))
            else
                try args.append(self.allocator, try self.lowerExprAs(dflt, fty));
        }
    }

    fn lowerLValueAddress(self: *FunctionLowerer, expr: ast.Expr) LowerError!Value {
        const ptr_ty: IrType = .{ .ptr = try boxType(self.allocator, self.exprType(expr)) };
        return switch (expr.kind) {
            .ident => |name| blk: {
                const local: Value = .{ .local = self.curLocal(name) };
                break :blk try self.emit(ptr_ty, .{ .unary = .{ .op = .ref, .value = local } });
            },
            .field => |field| blk: {
                // Take the base's ADDRESS when the base is itself an lvalue (a field
                // or index access). Lowering it as a value loads a COPY, so the store
                // would land on a throwaway temp and be silently dropped (`a.b.c = v`,
                // `arr[i].f = v`, `s[i].f = v`). For ident/pointer bases `lowerExpr`
                // already yields the alloca/pointer address, so keep that.
                const base = switch (field.base.*.kind) {
                    .field, .index => try self.lowerLValueAddress(field.base.*),
                    else => try self.lowerExpr(field.base.*),
                };
                break :blk try self.emitAt(ptr_ty, .{ .field_addr = .{ .base = base, .name = field.name } }, expr.span);
            },
            .index => |index| blk: {
                const base_ty = self.exprType(index.base.*);
                const base = switch (base_ty) {
                    .array => try self.lowerLValueAddress(index.base.*),
                    else => try self.lowerExpr(index.base.*),
                };
                const idx = try self.lowerExpr(index.index.*);
                break :blk try self.emitAt(ptr_ty, .{ .index_addr = .{ .base = base, .index = idx } }, expr.span);
            },
            .unary => |unary| switch (unary.op) {
                .deref => try self.lowerExpr(unary.expr.*),
                else => try self.emit(ptr_ty, .{ .unary = .{ .op = .ref, .value = try self.lowerExpr(expr) } }),
            },
            else => try self.emit(ptr_ty, .{ .unary = .{ .op = .ref, .value = try self.lowerExpr(expr) } }),
        };
    }

    /// Try to evaluate a #if condition at compile time.
    /// Returns the block to emit (then or else), or null if condition is dynamic.
    /// `expr!!` — unwrap or call the runtime panic path.
    fn lowerForceUnwrap(self: *FunctionLowerer, inner: ast.Expr, outer: ast.Expr) LowerError!Value {
        const lhs = try self.lowerExpr(inner);
        const is_some = try self.emit(.bool, .{ .optional_is_some = lhs });

        const value_id = self.allocBlockId();
        const panic_id = self.allocBlockId();
        try self.terminate(.{ .cond_branch = .{
            .cond = is_some,
            .then_block = value_id,
            .else_block = panic_id,
        } });

        // All generated traps share the structured panic terminator.
        self.startBlock(panic_id, "force_unwrap.panic");
        try self.terminatePanic("attempted to unwrap an empty optional", outer.span);

        // Happy path — extract the payload.
        self.startBlock(value_id, "force_unwrap.ok");
        return try self.emit(self.exprType(outer), .{ .optional_payload = lhs });
    }

    /// `expr ?? default` — use default value when expr is null/error.
    fn lowerNilCoalesce(self: *FunctionLowerer, nc: ast.NilCoalesceExpr, outer: ast.Expr) LowerError!Value {
        const lhs = try self.lowerExpr(nc.value.*);
        const result_ty = self.exprType(outer);

        const is_some = try self.emit(.bool, .{ .optional_is_some = lhs });
        const value_id = self.allocBlockId();
        const default_id = self.allocBlockId();
        const after_id = self.allocBlockId();

        try self.terminate(.{ .cond_branch = .{
            .cond = is_some,
            .then_block = value_id,
            .else_block = default_id,
        } });

        // Value path — extract payload.
        self.startBlock(value_id, "coalesce.value");
        const payload = try self.emit(result_ty, .{ .optional_payload = lhs });
        try self.emitNoResult(result_ty, .{ .store_local = .{ .name = "__coalesce", .value = payload } });
        try self.terminate(.{ .branch = after_id });

        // Default path — evaluate the default expression.
        self.startBlock(default_id, "coalesce.default");
        const def_val = try self.lowerExpr(nc.default.*);
        try self.emitNoResult(result_ty, .{ .store_local = .{ .name = "__coalesce", .value = def_val } });
        try self.terminate(.{ .branch = after_id });

        // After — load the result.
        self.startBlock(after_id, "coalesce.after");
        return .{ .local = "__coalesce" };
    }

    fn evalComptimeIf(self: *FunctionLowerer, ci: ast.ComptimeIfStmt) ?ast.Block {
        const empty_block = ast.Block{ .statements = &.{}, .span = ci.span };
        // The VM is the sole comptime engine; a non-bool or unevaluable
        // condition yields null so the caller can report it.
        if (self.cvm) |c| {
            c.current_file = self.file_name;
            if (c.evalToImm(ci.condition)) |imm| switch (imm) {
                .bool => |b| return if (b) ci.then_block else ci.else_block orelse empty_block,
                else => {},
            };
        }
        return null;
    }

    /// The IrType of variant `variant_name`'s payload in enum `enum_name`, for a
    /// `match … |v|` binding. Returns `.unknown` only when the enum/variant can't
    /// be resolved (no payload → `.unknown` is also fine, the binding is unused).
    fn variantPayloadIrType(self: *FunctionLowerer, enum_name: []const u8, variant_name: []const u8) IrType {
        const id = self.symbols.resolve(self.symbols.root_scope, enum_name) orelse return .unknown;
        const layout = self.types.layouts.get(id) orelse return .unknown;
        const variants = switch (layout.kind) {
            .variant_type => |v| v,
            else => return .unknown,
        };
        for (variants) |v| {
            if (!std.mem.eql(u8, v.name, variant_name)) continue;
            const pty = v.payload orelse return .unknown;
            return lowerSemaTypeWithEnv(self.allocator, pty, self.types, self.symbols) catch .unknown;
        }
        return .unknown;
    }

    /// Resolve the enum type name of a match subject for `variant_is`/payload
    /// instructions. Tries, in order: sema `expr_types`, a param's annotated type,
    /// the lowerer-tracked local type; "" if none (the match still lowers).
    fn matchEnumName(self: *FunctionLowerer, subject: ast.Expr) []const u8 {
        if (self.types.expr_types.get(subject.id)) |sema_ty| switch (sema_ty) {
            .named => |id| return self.symbols.symbol(id).name,
            else => {},
        };
        if (subject.kind == .ident) {
            const ident_name = subject.kind.ident;
            for (self.params) |p| {
                if (std.mem.eql(u8, p.name, ident_name)) switch (p.ty) {
                    .named => |named| return named.name,
                    else => {},
                };
            }
            if (self.local_types.get(self.curLocal(ident_name))) |lty| switch (lty) {
                .variant_type, .struct_type => |n| return n,
                else => {},
            };
        }
        return "";
    }

    /// The boolean test for `pattern` against `subject`, or null when the pattern
    /// always matches (`else` / a bare `name` binding).
    fn lowerPatternCheck(self: *FunctionLowerer, subject: Value, enum_name: []const u8, pattern: ast.MatchPattern) LowerError!?Value {
        switch (pattern) {
            .else_arm, .binding => return null,
            .enum_variant => |variant| return try self.emit(.bool, .{ .variant_is = .{
                .value = subject,
                .type_name = enum_name,
                .variant = variant,
            } }),
            .int_values => |values| {
                var combined: ?Value = null;
                for (values) |value| {
                    const equal = try self.emit(.bool, .{ .binary = .{ .op = .eq, .lhs = subject, .rhs = try self.lowerExpr(value) } });
                    combined = if (combined) |p| try self.emit(.bool, .{ .binary = .{ .op = .or_op, .lhs = p, .rhs = equal } }) else equal;
                }
                return combined orelse Value{ .imm = .{ .bool = false } };
            },
            .range => |r| {
                const lo = try self.lowerExpr(r.lo);
                const hi = try self.lowerExpr(r.hi);
                const ge = try self.emit(.bool, .{ .binary = .{ .op = .ge, .lhs = subject, .rhs = lo } });
                const hi_op: BinOp = if (r.inclusive) .le else .lt;
                const le = try self.emit(.bool, .{ .binary = .{ .op = hi_op, .lhs = subject, .rhs = hi } });
                return try self.emit(.bool, .{ .binary = .{ .op = .and_op, .lhs = ge, .rhs = le } });
            },
            .strings => |strs| {
                var combined: ?Value = null;
                for (strs) |s| {
                    const eq = try self.lowerStringEq(subject, s);
                    combined = if (combined) |p| try self.emit(.bool, .{ .binary = .{ .op = .or_op, .lhs = p, .rhs = eq } }) else eq;
                }
                return combined orelse Value{ .imm = .{ .bool = false } };
            },
        }
    }

    /// Spill a folded string constant (`.imm.text`, e.g. a string literal or
    /// `core::file`) into a typed `[]byte` local so it can be `.field`/`.index`-ed
    /// — a bare `.imm.text` has no slice irType and can't be indexed. Non-`.imm`
    /// values (locals, params, registers) already carry a slice type, so pass
    /// through untouched.
    fn materializeStrOperand(self: *FunctionLowerer, v: Value) LowerError!Value {
        if (v != .imm) return v;
        const name = try std.fmt.allocPrint(self.allocator, "__streq_s_{d}", .{self.next_block_id});
        try self.local_types.put(name, byteSliceType);
        try self.emitNoResult(byteSliceType, .{ .store_local = .{ .name = name, .value = v } });
        return .{ .local = name };
    }

    /// Compare a `[]const u8` subject to a string literal, byte by byte. The
    /// literal's bytes are read only inside a block guarded by a length match, so
    /// a shorter subject is never read out of bounds (K2's `&&` is eager).
    fn lowerStringEq(self: *FunctionLowerer, subject_in: Value, literal_raw: []const u8) LowerError!Value {
        const subject = try self.materializeStrOperand(subject_in);
        const lit = trimQuotes(literal_raw);
        const res_name = try std.fmt.allocPrint(self.allocator, "__streq_{d}", .{self.next_block_id});
        try self.local_types.put(res_name, .bool);
        try self.emitNoResult(.bool, .{ .store_local = .{ .name = res_name, .value = .{ .imm = .{ .bool = false } } } });

        const subj_len = try self.emit(.usize, .{ .field = .{ .base = subject, .name = "len" } });
        const len_eq = try self.emit(.bool, .{ .binary = .{ .op = .eq, .lhs = subj_len, .rhs = .{ .imm = .{ .uint = lit.len } } } });
        const cmp_id = self.allocBlockId();
        const done_id = self.allocBlockId();
        try self.terminate(.{ .cond_branch = .{ .cond = len_eq, .then_block = cmp_id, .else_block = done_id } });

        self.startBlock(cmp_id, "streq.cmp");
        var acc: Value = .{ .imm = .{ .bool = true } };
        for (lit, 0..) |c, i| {
            const byte = try self.emit(.byte, .{ .index = .{ .base = subject, .index = .{ .imm = .{ .uint = i } } } });
            const beq = try self.emit(.bool, .{ .binary = .{ .op = .eq, .lhs = byte, .rhs = .{ .imm = .{ .uint = c } } } });
            acc = try self.emit(.bool, .{ .binary = .{ .op = .and_op, .lhs = acc, .rhs = beq } });
        }
        try self.emitNoResult(.bool, .{ .store_local = .{ .name = res_name, .value = acc } });
        try self.terminate(.{ .branch = done_id });

        self.startBlock(done_id, "streq.done");
        return .{ .local = res_name };
    }

    /// Compare two `[]const u8` slices for content equality when neither length
    /// is known at compile time: match `.len`, then a byte-by-byte loop. The
    /// loop body is reached only after the length check, so the eager `&&`-free
    /// structure never reads past either slice. Same op set as `lowerStringEq`,
    /// so it folds in the comptime VM too (`#compiler` string compares).
    fn lowerStringEqDynamic(self: *FunctionLowerer, lhs_in: Value, rhs_in: Value) LowerError!Value {
        const lhs = try self.materializeStrOperand(lhs_in);
        const rhs = try self.materializeStrOperand(rhs_in);
        const suffix = self.next_block_id;
        const res_name = try std.fmt.allocPrint(self.allocator, "__streq_{d}", .{suffix});
        const idx_name = try std.fmt.allocPrint(self.allocator, "__streq_i_{d}", .{suffix});
        try self.local_types.put(res_name, .bool);
        try self.local_types.put(idx_name, .usize);
        // result starts false; only the all-bytes-matched path sets it true.
        try self.emitNoResult(.bool, .{ .store_local = .{ .name = res_name, .value = .{ .imm = .{ .bool = false } } } });

        const lhs_len = try self.emit(.usize, .{ .field = .{ .base = lhs, .name = "len" } });
        const rhs_len = try self.emit(.usize, .{ .field = .{ .base = rhs, .name = "len" } });
        const len_eq = try self.emit(.bool, .{ .binary = .{ .op = .eq, .lhs = lhs_len, .rhs = rhs_len } });

        const init_id = self.allocBlockId();
        const cond_id = self.allocBlockId();
        const body_id = self.allocBlockId();
        const incr_id = self.allocBlockId();
        const matched_id = self.allocBlockId();
        const done_id = self.allocBlockId();

        // Different lengths → done (result stays false), never touching the loop.
        try self.terminate(.{ .cond_branch = .{ .cond = len_eq, .then_block = init_id, .else_block = done_id } });

        self.startBlock(init_id, "streq.init");
        try self.emitNoResult(.usize, .{ .store_local = .{ .name = idx_name, .value = .{ .imm = .{ .uint = 0 } } } });
        try self.terminate(.{ .branch = cond_id });

        self.startBlock(cond_id, "streq.cond");
        const more = try self.emit(.bool, .{ .binary = .{ .op = .lt, .lhs = .{ .local = idx_name }, .rhs = lhs_len } });
        try self.terminate(.{ .cond_branch = .{ .cond = more, .then_block = body_id, .else_block = matched_id } });

        self.startBlock(body_id, "streq.body");
        const a = try self.emit(.byte, .{ .index = .{ .base = lhs, .index = .{ .local = idx_name } } });
        const b = try self.emit(.byte, .{ .index = .{ .base = rhs, .index = .{ .local = idx_name } } });
        const beq = try self.emit(.bool, .{ .binary = .{ .op = .eq, .lhs = a, .rhs = b } });
        // A mismatched byte → done (result stays false).
        try self.terminate(.{ .cond_branch = .{ .cond = beq, .then_block = incr_id, .else_block = done_id } });

        self.startBlock(incr_id, "streq.incr");
        const nx = try self.emit(.usize, .{ .binary = .{ .op = .add, .lhs = .{ .local = idx_name }, .rhs = .{ .imm = .{ .uint = 1 } } } });
        try self.emitNoResult(.usize, .{ .store_local = .{ .name = idx_name, .value = nx } });
        try self.terminate(.{ .branch = cond_id });

        self.startBlock(matched_id, "streq.matched");
        try self.emitNoResult(.bool, .{ .store_local = .{ .name = res_name, .value = .{ .imm = .{ .bool = true } } } });
        try self.terminate(.{ .branch = done_id });

        self.startBlock(done_id, "streq.done");
        return .{ .local = res_name };
    }

    /// In the arm's block, bind any local the pattern introduces: an enum payload
    /// (`.V |x|`), an `else |x|` subject, or a `name`-pattern's subject.
    fn bindMatchArm(self: *FunctionLowerer, subject: Value, subject_ty: IrType, enum_name: []const u8, pattern: ast.MatchPattern, payload_binding: ?[]const u8) LowerError!void {
        switch (pattern) {
            .binding => |name| {
                const ir_name = try self.declareLocal(name, subject_ty);
                try self.emitNoResult(subject_ty, .{ .store_local = .{ .name = ir_name, .value = subject } });
            },
            .enum_variant => |variant| if (payload_binding) |bname| {
                const payload_ty = self.variantPayloadIrType(enum_name, variant);
                const payload = try self.emit(payload_ty, .{ .variant_payload = .{ .value = subject, .type_name = enum_name, .variant = variant } });
                const ir_name = try self.declareLocal(bname, payload_ty);
                try self.emitNoResult(payload_ty, .{ .store_local = .{ .name = ir_name, .value = payload } });
            },
            .else_arm => if (payload_binding) |bname| {
                const ir_name = try self.declareLocal(bname, subject_ty);
                try self.emitNoResult(.void, .{ .store_local = .{ .name = ir_name, .value = subject } });
            },
            else => {},
        }
    }

    fn lowerMatch(self: *FunctionLowerer, m: ast.MatchStmt) LowerError!void {
        const subject = try self.lowerExpr(m.subject);
        const subject_ty = self.exprType(m.subject);
        const enum_name = self.matchEnumName(m.subject);
        const after_id = self.allocBlockId();

        for (m.arms) |arm| {
            const check = try self.lowerPatternCheck(subject, enum_name, arm.pattern);
            const arm_id = self.allocBlockId();
            const needs_next = check != null or arm.guard != null;
            const next_id = if (needs_next) self.allocBlockId() else after_id;

            if (check) |c| {
                try self.terminate(.{ .cond_branch = .{ .cond = c, .then_block = arm_id, .else_block = next_id } });
            } else {
                try self.terminate(.{ .branch = arm_id });
            }

            self.startBlock(arm_id, "match.arm");
            const arm_scope = try self.enterScope(); // scope the pattern binding to this arm
            try self.bindMatchArm(subject, subject_ty, enum_name, arm.pattern, arm.binding);
            if (arm.guard) |g| {
                const gv = try self.lowerExpr(g);
                const body_id = self.allocBlockId();
                try self.terminate(.{ .cond_branch = .{ .cond = gv, .then_block = body_id, .else_block = next_id } });
                self.startBlock(body_id, "match.body");
            }
            try self.lowerBlock(arm.body.statements, .{ .branch = after_id });
            self.leaveScope(arm_scope);

            if (needs_next) {
                self.startBlock(next_id, "match.next");
            } else break; // unguarded catch-all — the cascade ends here
        }

        if (!self.current_terminated) try self.terminate(.{ .branch = after_id });
        self.startBlock(after_id, "match.after");
    }

    /// `match subject { pattern => value, ... }` as a value. Lowers to a branch
    /// cascade where each arm stores its value into a result slot; the merge
    /// block loads it. The match is exhaustive (sema-guaranteed), so the `else`
    /// arm — or, when absent, the last arm — is the unconditional fallthrough,
    /// keeping the result slot defined on every path.
    fn lowerMatchExpr(self: *FunctionLowerer, expr: ast.Expr, expected: ?IrType) LowerError!Value {
        const me = expr.kind.match_expr;
        // Prefer an expected type from context (e.g. `p: P = match …`) so untyped
        // arm values like `.{ … }` get the right target type; otherwise use the
        // type sema inferred from the arms.
        const sema_ty = self.exprType(expr);
        const result_ty: IrType = if (expected) |e|
            (if (e == .unknown) sema_ty else e)
        else
            sema_ty;
        const result_name = try std.fmt.allocPrint(self.allocator, "__match_res_{d}", .{self.next_block_id});

        const subject = try self.lowerExpr(me.subject.*);
        const subject_ty = self.exprType(me.subject.*);
        const enum_name = self.matchEnumName(me.subject.*);
        const after_id = self.allocBlockId();

        for (me.arms) |arm| {
            const check = try self.lowerPatternCheck(subject, enum_name, arm.pattern);
            const arm_id = self.allocBlockId();
            const needs_next = check != null or arm.guard != null;
            const next_id = if (needs_next) self.allocBlockId() else after_id;

            if (check) |c| {
                try self.terminate(.{ .cond_branch = .{ .cond = c, .then_block = arm_id, .else_block = next_id } });
            } else {
                try self.terminate(.{ .branch = arm_id });
            }

            self.startBlock(arm_id, "match.arm");
            const arm_scope = try self.enterScope(); // scope the pattern binding to this arm
            try self.bindMatchArm(subject, subject_ty, enum_name, arm.pattern, arm.binding);
            if (arm.guard) |g| {
                const gv = try self.lowerExpr(g);
                const body_id = self.allocBlockId();
                try self.terminate(.{ .cond_branch = .{ .cond = gv, .then_block = body_id, .else_block = next_id } });
                self.startBlock(body_id, "match.body");
            }
            const value = try self.lowerExprAs(arm.value, result_ty);
            try self.emitNoResult(result_ty, .{ .store_local = .{ .name = result_name, .value = value } });
            self.leaveScope(arm_scope);
            try self.terminate(.{ .branch = after_id });

            if (needs_next) {
                self.startBlock(next_id, "match.next");
            } else break; // unguarded catch-all — the cascade ends here
        }

        if (!self.current_terminated) try self.terminate(.{ .branch = after_id });
        self.startBlock(after_id, "match.after");
        try self.local_types.put(result_name, result_ty);
        return .{ .local = result_name };
    }

    /// `if cond { a } else { b }` in value position: branch on `cond`, each branch
    /// stores its value into a result local, then both join.
    fn lowerIfExpr(self: *FunctionLowerer, expr: ast.Expr, expected: ?IrType) LowerError!Value {
        const ie = expr.kind.if_expr;
        const sema_ty = self.exprType(expr);
        const result_ty: IrType = if (expected) |e|
            (if (e == .unknown) sema_ty else e)
        else
            sema_ty;
        self.temp_id += 1;
        const result_name = try std.fmt.allocPrint(self.allocator, "__if_res_{d}", .{self.temp_id});
        try self.local_types.put(result_name, result_ty);

        const cond = try self.lowerExpr(ie.cond);
        const then_id = self.allocBlockId();
        const else_id = self.allocBlockId();
        const after_id = self.allocBlockId();
        try self.terminate(.{ .cond_branch = .{ .cond = cond, .then_block = then_id, .else_block = else_id } });

        self.startBlock(then_id, "ifx.then");
        const tv = try self.lowerExprAs(ie.then_value, result_ty);
        try self.emitNoResult(result_ty, .{ .store_local = .{ .name = result_name, .value = tv } });
        try self.terminate(.{ .branch = after_id });

        self.startBlock(else_id, "ifx.else");
        const ev = try self.lowerExprAs(ie.else_value, result_ty);
        try self.emitNoResult(result_ty, .{ .store_local = .{ .name = result_name, .value = ev } });
        try self.terminate(.{ .branch = after_id });

        self.startBlock(after_id, "ifx.after");
        return .{ .local = result_name };
    }

    fn emitDefersDown(self: *FunctionLowerer, floor: usize, path: DeferPath) LowerError!void {
        var i = self.defers.items.len;
        while (i > floor) {
            i -= 1;
            const deferred = self.defers.items[i];
            if (!deferRunsOn(deferred.mode, path)) continue;
            for (deferred.body.statements) |ds| try self.lowerStmt(ds);
        }
    }

    // Lower a lexical block with automatic defer cleanup on normal fallthrough.
    // on_fallthrough: terminator to emit if the block does not terminate itself
    // (pass null to let the caller handle it).
    fn lowerBlock(self: *FunctionLowerer, stmts: []const ast.Stmt, on_fallthrough: ?Terminator) LowerError!void {
        const floor = self.defers.items.len;
        const alias_scope = try self.enterScope();
        defer self.leaveScope(alias_scope);
        for (stmts) |s| try self.lowerStmt(s);
        if (!self.current_terminated) {
            try self.emitDefersDown(floor, .ok);
            if (on_fallthrough) |term| try self.terminate(term);
        }
        self.defers.items.len = floor;
    }

    /// Parse asm(volatile, "template", inputs: { "D"(v), ... }, outputs: { "=a"(T) }, clobbers: { "rcx" })
    /// and lower it to an InlineAsmInstr with a proper LLVM constraint string.
    fn lowerAsmCall(self: *FunctionLowerer, call: ast.CallExpr, expr: ast.Expr) LowerError!Value {
        var is_volatile = false;
        var template: []const u8 = "";
        var constraints = std.ArrayList(u8).empty;
        errdefer constraints.deinit(self.allocator);
        var input_args = std.ArrayList(Value).empty;
        errdefer input_args.deinit(self.allocator);

        // Positional args: [volatile_kw, template_str]
        var pos: usize = 0;
        for (call.args) |arg| {
            const e = switch (arg) {
                .positional => |e| e,
                else => continue,
            };
            if (pos == 0) is_volatile = e.kind == .ident and std.mem.eql(u8, e.kind.ident, "volatile");
            if (pos == 1) template = switch (e.kind) {
                .string => |s| trimQuotes(s),
                else => "",
            };
            pos += 1;
        }

        // LLVM constraint order: outputs, inputs, clobbers.
        for (call.args) |arg| {
            const n = switch (arg) {
                .named => |n| n,
                else => continue,
            };
            const items = switch (n.value.kind) {
                .compound_literal => |c| c,
                else => continue,
            };

            if (std.mem.eql(u8, n.name, "outputs")) {
                for (items) |item| {
                    const c = extractAsmConstraint(item) orelse continue;
                    try constraints.appendSlice(self.allocator, c);
                    try constraints.append(self.allocator, ',');
                    // outputs don't add args — they're return slots
                }
            } else if (std.mem.eql(u8, n.name, "inputs")) {
                for (items) |item| {
                    const c = extractAsmConstraint(item) orelse continue;
                    try constraints.appendSlice(self.allocator, c);
                    try constraints.append(self.allocator, ',');
                    // Lower the input value
                    if (item.kind == .call) {
                        const c_args = item.kind.call.args;
                        if (c_args.len > 0) {
                            const val_expr = switch (c_args[0]) {
                                .positional => |e| e,
                                .named => |nn| nn.value,
                            };
                            try input_args.append(self.allocator, try self.lowerExpr(val_expr));
                        }
                    }
                }
            } else if (std.mem.eql(u8, n.name, "clobbers")) {
                for (items) |item| {
                    const s = switch (item.kind) {
                        .string => |s| trimQuotes(s),
                        else => continue,
                    };
                    try constraints.appendSlice(self.allocator, "~{");
                    try constraints.appendSlice(self.allocator, s);
                    try constraints.append(self.allocator, '}');
                    try constraints.append(self.allocator, ',');
                }
            }
        }

        // Remove trailing comma.
        if (constraints.items.len > 0 and constraints.items[constraints.items.len - 1] == ',')
            constraints.items.len -= 1;

        const ty = self.exprType(expr);
        return try self.emit(ty, .{ .inline_asm = .{
            .template = template,
            .constraints = try constraints.toOwnedSlice(self.allocator),
            .args = try input_args.toOwnedSlice(self.allocator),
            .volatile_ = is_volatile,
        } });
    }

    /// `zone_handle.free(ptr)` — the only zone method still lowered specially.
    /// `new`/`new_slice`/`alloc`/… are ordinary `std.heap.Arena` calls (resolved
    /// by sema via UFCS). A bump arena frees in bulk on `deinit`, so per-pointer
    /// `free` is a runtime no-op (sema already verified the ownership); it emits
    /// `zone_free`, which the backend drops.
    fn lowerZoneMethod(self: *FunctionLowerer, zone_name: []const u8, method: []const u8, args: []const ast.CallArg, expr: ast.Expr) LowerError!Value {
        _ = expr;
        if (std.mem.eql(u8, method, "free") and args.len > 0) {
            const ptr_expr = switch (args[0]) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            const ptr = try self.lowerExpr(ptr_expr);
            try self.emitNoResult(.void, .{ .zone_free = .{ .zone = zone_name, .ptr = ptr } });
        }
        return .{ .imm = .null };
    }

    fn lowerTypeArg(self: *FunctionLowerer, expr: ast.Expr) LowerError!IrType {
        return switch (expr.kind) {
            .type_ref => |ty| lowerType(self.allocator, ty),
            // A bare ident may be a generic type parameter — resolve it to the
            // concrete type bound for this instantiation, so `sizeof(T)` etc.
            // get the real type instead of an unknown one.
            .ident => |name| blk: {
                for (self.type_binding) |arg| {
                    if (std.mem.eql(u8, arg.name, name))
                        break :blk lowerSemaTypeWithEnv(self.allocator, arg.ty, self.types, self.symbols) catch .unknown;
                }
                break :blk lowerNamedType(name);
            },
            // Generic instantiation (e.g. `List(i32)`) parses as a call. Sema
            // records its resolved type in `expr_types`; reuse that so the
            // allocation gets the concrete struct size, not a bare pointer.
            else => self.exprType(expr),
        };
    }

    fn emit(self: *FunctionLowerer, ty: IrType, kind: InstrKind) LowerError!Value {
        if (self.current_terminated) return .{ .imm = .null };
        const id = self.next_reg;
        self.next_reg += 1;
        try self.current_instrs.append(self.allocator, .{ .id = id, .ty = ty, .kind = kind });
        return .{ .reg = id };
    }

    fn emitAt(self: *FunctionLowerer, ty: IrType, kind: InstrKind, span: Span) LowerError!Value {
        if (self.current_terminated) return .{ .imm = .null };
        const id = self.next_reg;
        self.next_reg += 1;
        try self.current_instrs.append(self.allocator, .{
            .id = id,
            .ty = ty,
            .kind = kind,
            .location = self.sourceLocation(span),
        });
        return .{ .reg = id };
    }

    fn emitNoResult(self: *FunctionLowerer, ty: IrType, kind: InstrKind) LowerError!void {
        if (self.current_terminated) return;
        try self.current_instrs.append(self.allocator, .{ .id = null, .ty = ty, .kind = kind });
    }

    /// Lower a `fn(...)` argument passed to an `#extern` C function as a THIN raw
    /// function pointer (C cannot call k2's fat `{fn, env}` closure). Only a plain
    /// top-level function works — its signature matches C; a lambda/closure carries
    /// an environment, so it is rejected.
    fn lowerRawFnArg(self: *FunctionLowerer, value: ast.Expr) LowerError!Value {
        if (value.kind == .ident) {
            if (resolveTopLevel(self.symbols, self.file_name, value.kind.ident)) |id| {
                if (self.symbols.symbol(id).kind == .function and !std.mem.startsWith(u8, value.kind.ident, "__lambda_")) {
                    return Value{ .global = self.symbols.symbol(id).link_name };
                }
            }
        }
        diag_mod.printErrorAt(
            "a C callback argument must be a plain top-level function — a lambda or " ++
                "captured closure carries an environment that C cannot call",
            self.file_name,
            self.source,
            value.span,
        );
        return error.LoweringFailed;
    }

    /// Build a capture environment for a lambda: allocate it and store the
    /// current value of each captured enclosing local (capture by value).
    fn buildCaptureEnv(self: *FunctionLowerer, link: []const u8) LowerError!Value {
        const caps = self.types.lambda_captures.get(link) orelse return .{ .imm = .null };
        if (caps.len == 0) return .{ .imm = .null };
        const fields = try self.allocator.alloc(EnvField, caps.len);
        for (caps, 0..) |c, i| {
            const cty = lowerSemaTypeWithEnv(self.allocator, c.ty, self.types, self.symbols) catch .unknown;
            // The captured variable may be a parameter or a local of the enclosing
            // function — read whichever it is (a param isn't a local alloca).
            const val: Value = vblk: {
                for (self.params) |p| if (std.mem.eql(u8, p.name, c.name)) break :vblk Value{ .param = c.name };
                break :vblk Value{ .local = self.curLocal(c.name) };
            };
            fields[i] = .{ .value = val, .ty = cty };
        }
        // Allocate the env on a region so the closure can escape the current
        // frame: the innermost enclosing `zone`, else a caller-supplied `*Arena`
        // parameter, else the stack (non-escaping).
        const arena: Value = if (self.active_zones.items.len > 0) blk: {
            const handle = self.active_zones.items[self.active_zones.items.len - 1];
            const arena_ty: IrType = .{ .ptr = try boxType(self.allocator, .{ .struct_type = "Arena" }) };
            break :blk try self.emit(arena_ty, .{ .unary = .{ .op = .ref, .value = .{ .local = handle } } });
        } else if (self.arenaParam()) |pname| Value{ .param = pname } else Value{ .imm = .null };
        return try self.emit(.{ .ptr = try boxType(self.allocator, .void) }, .{ .closure_env_make = .{ .fields = fields, .arena = arena } });
    }

    /// Name of the first `*Arena` parameter of the function being lowered (a
    /// caller-supplied region for an escaping closure's environment), or null.
    fn arenaParam(self: *FunctionLowerer) ?[]const u8 {
        for (self.params) |p| {
            if (p.is_type_param) continue;
            const ty = lowerAstTypeWithEnv(self.allocator, p.ty, self.types, self.symbols) catch continue;
            if (ty == .ptr and ty.ptr.* == .struct_type and std.mem.eql(u8, ty.ptr.struct_type, "Arena")) return p.name;
        }
        return null;
    }

    /// The IR types of this lambda body's captures, in env order.
    fn captureFieldTys(self: *FunctionLowerer) LowerError![]const IrType {
        const tys = try self.allocator.alloc(IrType, self.lambda_captures.len);
        for (self.lambda_captures, 0..) |c, i| {
            tys[i] = lowerSemaTypeWithEnv(self.allocator, c.ty, self.types, self.symbols) catch .unknown;
        }
        return tys;
    }

    /// A `constraint`/`macro` template function — registered for `$T: Name`
    /// resolution or macro expansion, never a callable runtime value. Such a name
    /// must NOT be wrapped as a closure (it breaks `require(T, Name)` composition).
    fn isTemplateFn(self: *FunctionLowerer, name: []const u8) bool {
        const id = resolveTopLevel(self.symbols, self.file_name, name) orelse return false;
        const sig = self.types.fn_sigs.get(id) orelse return false;
        return sig.is_template;
    }

    /// The fn-pointer (closure) IR type of an expression that names a function.
    /// Falls back to an opaque fn-pointer when sema didn't record one, so a
    /// `closure_make` always carries a `.fn_ptr` type (→ the backend closure struct).
    fn fnPtrTypeOf(self: *FunctionLowerer, expr: ast.Expr) IrType {
        const t = self.exprType(expr);
        if (t == .fn_ptr) return t;
        return .{ .fn_ptr = .{ .params = &.{}, .ret = boxType(self.allocator, .void) catch &voidType } };
    }

    fn exprType(self: FunctionLowerer, expr: ast.Expr) IrType {
        const ty = self.types.expr_types.get(expr.id) orelse {
            if (expr.kind == .ident) {
                const cur = self.local_alias.get(expr.kind.ident) orelse expr.kind.ident;
                if (self.local_types.get(cur)) |local_ty| return local_ty;
                for (self.params) |param| if (std.mem.eql(u8, param.name, expr.kind.ident)) {
                    // In a generic instantiation a param whose declared type mentions a
                    // type parameter (`v: $T`, `xs: []$T`, …) must resolve through the
                    // binding to the concrete type, not the type-param name — otherwise
                    // type-directed lowering misfires: `any(v)` hashes "T" and misses the
                    // dispatcher, and `a == b` on `$T = []const u8` falls through to a
                    // scalar compare on the fat slice (an LLVM/VM type error) instead of
                    // a content compare. `lowerTypeWithBindingAndSymbols` resolves the
                    // type param at any nesting depth.
                    if (self.type_binding.len != 0) {
                        const bound = lowerTypeWithBindingAndSymbols(self.allocator, param.ty, self.type_binding, self.types, self.symbols) catch IrType.unknown;
                        if (bound != .unknown) return bound;
                    }
                    if (param.ty == .named) {
                        for (self.type_binding) |binding_arg| {
                            if (std.mem.eql(u8, binding_arg.name, param.ty.named.name))
                                return lowerSemaTypeWithEnv(self.allocator, binding_arg.ty, self.types, self.symbols) catch .unknown;
                        }
                    }
                    return lowerAstTypeWithEnv(self.allocator, param.ty, self.types, self.symbols) catch .unknown;
                };
                // A bare function name used as a value is a fat closure — type it
                // `fn_ptr` (carrying the function's value-param + return types) so a
                // `f := dbl` local is sized/loaded as a closure, not a raw pointer.
                if (resolveTopLevel(self.symbols, self.file_name, expr.kind.ident)) |id| {
                    if (self.symbols.symbol(id).kind == .function) {
                        if (self.types.fn_sigs.get(id)) |sig| {
                            var ps = std.ArrayList(IrType).empty;
                            for (sig.params) |p| {
                                if (p.is_type_param) continue;
                                ps.append(self.allocator, lowerSemaTypeWithEnv(self.allocator, p.ty, self.types, self.symbols) catch .unknown) catch {};
                            }
                            const ret = lowerSemaTypeWithEnv(self.allocator, sig.return_ty, self.types, self.symbols) catch .void;
                            return .{ .fn_ptr = .{ .params = ps.toOwnedSlice(self.allocator) catch &.{}, .ret = boxType(self.allocator, ret) catch &voidType } };
                        }
                        return .{ .fn_ptr = .{ .params = &.{}, .ret = &voidType } };
                    }
                }
            }
            return .unknown;
        };
        const resolved = resolveTypeParamInTy(ty, self.type_binding);
        return lowerSemaTypeWithEnv(self.allocator, resolved, self.types, self.symbols) catch .unknown;
    }

    fn lowerInterfaceCoercion(self: *FunctionLowerer, expr: ast.Expr, interface_name: []const u8) LowerError!Value {
        const concrete_name = self.concretePointerExprName(expr) orelse {
            diag_mod.printIceAt(
                "cannot resolve concrete type for interface coercion",
                self.file_name,
                self.source,
                expr.span,
                @src(),
            );
            return error.LoweringFailed;
        };
        return self.emit(.{ .interface_value = interface_name }, .{ .interface_make = .{
            .data = try self.lowerExpr(expr),
            .vtable = try interfaceVTableName(self.allocator, concrete_name, interface_name),
        } });
    }

    fn concretePointerExprName(self: FunctionLowerer, expr: ast.Expr) ?[]const u8 {
        if (self.types.expr_types.get(expr.id)) |ty| {
            if (concretePointerName(ty, self.symbols)) |name| return name;
        }
        if (expr.kind == .ident) {
            for (self.params) |param| {
                if (!std.mem.eql(u8, param.name, expr.kind.ident)) continue;
                return switch (param.ty) {
                    .pointer, .many_pointer => |ptr| switch (ptr.inner.*) {
                        .named => |named| named.name,
                        else => null,
                    },
                    else => null,
                };
            }
        }
        return null;
    }

    fn interfaceMethodIndex(self: FunctionLowerer, interface_name: []const u8, method_name: []const u8) ?u32 {
        const id = self.symbols.resolve(self.symbols.root_scope, interface_name) orelse return null;
        const layout = self.types.layouts.get(id) orelse return null;
        const methods = switch (layout.kind) {
            .interface_type => |methods| methods,
            else => return null,
        };
        for (methods, 0..) |method, i| if (std.mem.eql(u8, method.name, method_name)) return @intCast(i);
        return null;
    }

    fn allocBlockId(self: *FunctionLowerer) BlockId {
        const id = self.next_block_id;
        self.next_block_id += 1;
        return id;
    }

    fn startBlock(self: *FunctionLowerer, id: BlockId, name: []const u8) void {
        self.current_id = id;
        self.current_name = name;
        self.current_instrs = .empty;
        self.current_terminated = false;
    }

    fn terminate(self: *FunctionLowerer, terminator: Terminator) LowerError!void {
        if (self.current_terminated) return;

        try self.blocks.append(self.allocator, .{
            .id = self.current_id,
            .name = self.current_name,
            .instrs = try self.current_instrs.toOwnedSlice(self.allocator),
            .terminator = terminator,
        });
        self.current_terminated = true;
    }

    fn terminatePanic(self: *FunctionLowerer, message: []const u8, span: Span) LowerError!void {
        try self.terminate(.{ .panic = .{
            .message = message,
            .location = self.sourceLocation(span),
        } });
    }

    fn sourceLocation(self: *const FunctionLowerer, span: Span) SourceLocation {
        const location = span.line_col(self.source);
        return .{
            .file = self.file_name,
            .line = location.line,
            .column = location.col,
        };
    }
};

/// Resolve a top-level name to its symbol for IR purposes: file-aware first (so a
/// collision-mangled name picks the right module), then global (names are already
/// sema-validated, and synthetic comptime functions may lack a file context).
fn resolveTopLevel(symbols: sema.SymbolTable, file: []const u8, name: []const u8) ?sema.SymbolId {
    return symbols.resolveVisible(file, name) orelse symbols.resolve(symbols.root_scope, name);
}

/// The linkage name for a top-level reference (bare unless collision-mangled).
fn linkNameFor(symbols: sema.SymbolTable, file: []const u8, name: []const u8) []const u8 {
    if (resolveTopLevel(symbols, file, name)) |id| return symbols.symbol(id).link_name;
    return name;
}

fn lowerType(allocator: std.mem.Allocator, ty: ast.TypeRef) !IrType {
    return switch (ty) {
        .type_param => .unknown,
        .generic_inst => |gi| .{ .struct_type = gi.name },
        .named => |named| lowerNamedType(named.name),
        .pointer => |ptr| .{ .ptr = try boxType(allocator, try lowerType(allocator, ptr.inner.*)) },
        .many_pointer => |ptr| .{ .ptr = try boxType(allocator, try lowerType(allocator, ptr.inner.*)) },
        .optional => |optional| .{ .optional = try boxType(allocator, try lowerType(allocator, optional.inner.*)) },
        .slice => |slice| .{ .slice = try boxType(allocator, try lowerType(allocator, slice.inner.*)) },
        .borrow => |borrow| try lowerType(allocator, borrow.inner.*),
        .array => |array| .{ .array = .{
            .elem = try boxType(allocator, try lowerType(allocator, array.inner.*)),
            .len = parseArrayLen(array.len.*),
        } },
        .atomic => |atomic| try lowerType(allocator, atomic.inner.*),
        .fn_type => |func| blk: {
            var params = std.ArrayList(IrType).empty;
            errdefer params.deinit(allocator);
            for (func.params) |param| try params.append(allocator, try lowerType(allocator, param));
            const ret_ty = try lowerType(allocator, func.ret.*);
            const final_ret: IrType = if (func.error_ty) |err| .{ .fallible = .{
                .ok = try boxType(allocator, ret_ty),
                .err = try boxType(allocator, try lowerErrorSpec(allocator, err)),
            } } else ret_ty;
            break :blk .{ .fn_ptr = .{
                .params = try params.toOwnedSlice(allocator),
                .ret = try boxType(allocator, final_ret),
                .thin = func.is_extern,
            } };
        },
        .inline_error_set => |set| try lowerInlineErrorSet(allocator, set),
        .opaque_type => .{ .opaque_type = "opaque" },
    };
}

/// Faithful copy of sema's `Checker.appendTyMangle` — symbol-name-aware so two
/// distinct named-type instantiations don't collapse onto one mangled name. Keep
/// in lockstep with sema so the IR instance name matches the materialized
/// `generic_struct_instances` key.
fn appendSemaTyMangle(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), ty: sema.Ty, symbols: sema.SymbolTable) !void {
    switch (ty) {
        .named => |id| try buf.appendSlice(allocator, symbols.symbol(id).name),
        .pointer => |inner| {
            try buf.appendSlice(allocator, "ptr_");
            try appendSemaTyMangle(allocator, buf, inner.*, symbols);
        },
        .const_ptr => |inner| {
            try buf.appendSlice(allocator, "cptr_");
            try appendSemaTyMangle(allocator, buf, inner.*, symbols);
        },
        .optional => |inner| {
            try buf.appendSlice(allocator, "opt_");
            try appendSemaTyMangle(allocator, buf, inner.*, symbols);
        },
        .slice => |inner| {
            try buf.appendSlice(allocator, "slice_");
            try appendSemaTyMangle(allocator, buf, inner.*, symbols);
        },
        else => try buf.appendSlice(allocator, sema.tyMangle(ty)),
    }
}

/// Mangle one generic type argument (an AST `TypeRef`) into `buf`, matching sema's
/// resolution order: a `binding` entry wins (inside a generic body, `T` → its
/// concrete type), then transparent aliases, then the bare name — which serves both
/// builtin scalars and user structs, exactly as sema's `appendTyMangle` produces.
fn appendGenericArgMangle(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    arg_ref: ast.TypeRef,
    binding: []const sema.TypeArg,
    types: sema.TypeEnv,
    symbols: sema.SymbolTable,
) error{ OutOfMemory, UnsupportedGenericArg }!void {
    switch (arg_ref) {
        .type_param => |t| {
            for (binding) |b| if (std.mem.eql(u8, b.name, t.name))
                return appendSemaTyMangle(allocator, buf, b.ty, symbols);
            return error.UnsupportedGenericArg;
        },
        .named => |n| {
            // A bare name may be a bound type param inside a generic body…
            for (binding) |b| if (std.mem.eql(u8, b.name, n.name))
                return appendSemaTyMangle(allocator, buf, b.ty, symbols);
            // …a transparent alias (mangle the underlying, as sema's typeFromRef does)…
            if (symbols.resolve(symbols.root_scope, n.name)) |id|
                if (types.alias_refs.get(id)) |aliased|
                    return appendGenericArgMangle(allocator, buf, aliased, binding, types, symbols);
            // …or a builtin scalar / user struct, both of which mangle to the name.
            try buf.appendSlice(allocator, n.name);
        },
        .pointer => |p| {
            try buf.appendSlice(allocator, if (p.is_const) "cptr_" else "ptr_");
            try appendGenericArgMangle(allocator, buf, p.inner.*, binding, types, symbols);
        },
        .many_pointer => |p| {
            try buf.appendSlice(allocator, if (p.is_const) "cptr_" else "ptr_");
            try appendGenericArgMangle(allocator, buf, p.inner.*, binding, types, symbols);
        },
        .optional => |o| {
            try buf.appendSlice(allocator, "opt_");
            try appendGenericArgMangle(allocator, buf, o.inner.*, binding, types, symbols);
        },
        .slice => |s| {
            try buf.appendSlice(allocator, "slice_");
            try appendGenericArgMangle(allocator, buf, s.inner.*, binding, types, symbols);
        },
        else => return error.UnsupportedGenericArg,
    }
}

/// The instance struct name for a `Name(Args…)` application, matching sema's
/// `instantiateConcrete` mangling so the IR type references the concrete instance
/// materialized from `generic_struct_instances` — NOT the bare template, whose
/// type-parameter fields are opaque (→ dropped field values / invalid LLVM). Works
/// in both a generic body (args resolved through `binding`) and a non-generic
/// context with explicit concrete args (`Pair(i32)` — `binding` empty). Returns
/// null if `gi` is not a known generic struct or an argument can't be mangled, in
/// which case the caller falls back to the bare template name.
fn mangleGenericInst(
    allocator: std.mem.Allocator,
    gi: ast.GenericInstType,
    binding: []const sema.TypeArg,
    types: sema.TypeEnv,
    symbols: sema.SymbolTable,
) !?[]const u8 {
    const tmpl = types.generic_struct_templates.get(gi.name) orelse return null;
    const tparams = switch (tmpl.kind) {
        .struct_type => |s| s.type_params,
        else => return null,
    };
    if (gi.args.len != tparams.len) return null;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, gi.name);
    for (tparams, gi.args) |pname, arg_ref| {
        try buf.appendSlice(allocator, "__");
        try buf.appendSlice(allocator, pname);
        try buf.append(allocator, '_');
        appendGenericArgMangle(allocator, &buf, arg_ref, binding, types, symbols) catch |e| switch (e) {
            error.UnsupportedGenericArg => {
                buf.deinit(allocator);
                return null;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    return try buf.toOwnedSlice(allocator);
}

fn lowerAstTypeWithEnv(allocator: std.mem.Allocator, ty: ast.TypeRef, types: sema.TypeEnv, symbols: sema.SymbolTable) !IrType {
    if (ty == .borrow) return lowerAstTypeWithEnv(allocator, ty.borrow.inner.*, types, symbols);
    const ptr_inner_ast: ?ast.TypeRef = switch (ty) {
        .pointer => |p| p.inner.*,
        .many_pointer => |p| p.inner.*,
        else => null,
    };
    if (ptr_inner_ast) |inner_ty| switch (inner_ty) {
        .named => |named| if (symbols.resolve(symbols.root_scope, named.name)) |id| {
            if (types.layouts.get(id)) |layout| if (layout.kind == .interface_type)
                return .{ .interface_value = named.name };
        },
        else => {},
    };
    // Distinct type: lower directly to the underlying type.
    if (ty == .named) {
        if (symbols.resolve(symbols.root_scope, ty.named.name)) |id| {
            if (types.distinct_types.get(id)) |underlying| {
                return lowerSemaTypeWithEnv(allocator, underlying, types, symbols);
            }
            // Transparent alias: lower the underlying type (transitively).
            if (types.alias_refs.get(id)) |aliased| {
                return lowerAstTypeWithEnv(allocator, aliased, types, symbols);
            }
        }
    }
    // Arrays here (vs the env-less `lowerType`) so a named-const size resolves
    // (`[N]T`): the bare `lowerType` can't see `const_ints`.
    if (ty == .array) {
        return .{ .array = .{
            .elem = try boxType(allocator, try lowerAstTypeWithEnv(allocator, ty.array.inner.*, types, symbols)),
            .len = sema.resolveArrayLen(ty.array.len.*, types.const_ints),
        } };
    }
    // A concrete instantiation in a NON-generic context (`p: Pair(i32)`, a field, a
    // param/return type) must resolve to the materialized instance struct
    // (`Pair__T_i32`), not the bare template `Pair` whose `T`-typed fields are opaque
    // — otherwise a compound literal lowers against the empty template and drops its
    // field values. There's no binding here (args are already concrete).
    if (ty == .generic_inst) {
        if (try mangleGenericInst(allocator, ty.generic_inst, &.{}, types, symbols)) |m|
            return .{ .struct_type = m };
    }
    return lowerType(allocator, ty);
}

fn lowerErrorSpec(allocator: std.mem.Allocator, spec: ast.ErrorSpec) !IrType {
    return switch (spec) {
        .inferred => .{ .variant_type = "<error>" },
        .named => |named| .{ .variant_type = named.name },
        .inline_set => |set| try lowerInlineErrorSet(allocator, set),
    };
}

fn lowerInlineErrorSet(allocator: std.mem.Allocator, set: ast.InlineErrorSet) !IrType {
    _ = allocator;
    _ = set;
    return .{ .variant_type = "<anonymous-error-set>" };
}

fn lowerNamedType(name: []const u8) IrType {
    // Sub-byte integers — LLVM supports arbitrary-width integers
    if (std.mem.eql(u8, name, "u1")) return .{ .u = 1 };
    if (std.mem.eql(u8, name, "u2")) return .{ .u = 2 };
    if (std.mem.eql(u8, name, "u3")) return .{ .u = 3 };
    if (std.mem.eql(u8, name, "u4")) return .{ .u = 4 };
    if (std.mem.eql(u8, name, "u5")) return .{ .u = 5 };
    if (std.mem.eql(u8, name, "u6")) return .{ .u = 6 };
    if (std.mem.eql(u8, name, "u7")) return .{ .u = 7 };
    if (std.mem.eql(u8, name, "i1")) return .{ .i = 1 };
    if (std.mem.eql(u8, name, "i2")) return .{ .i = 2 };
    if (std.mem.eql(u8, name, "i3")) return .{ .i = 3 };
    if (std.mem.eql(u8, name, "i4")) return .{ .i = 4 };
    if (std.mem.eql(u8, name, "i5")) return .{ .i = 5 };
    if (std.mem.eql(u8, name, "i6")) return .{ .i = 6 };
    if (std.mem.eql(u8, name, "i7")) return .{ .i = 7 };
    if (std.mem.eql(u8, name, "i8")) return .{ .i = 8 };
    if (std.mem.eql(u8, name, "i16")) return .{ .i = 16 };
    if (std.mem.eql(u8, name, "i32")) return .{ .i = 32 };
    if (std.mem.eql(u8, name, "i64")) return .{ .i = 64 };
    if (std.mem.eql(u8, name, "u8")) return .{ .u = 8 };
    if (std.mem.eql(u8, name, "u16")) return .{ .u = 16 };
    if (std.mem.eql(u8, name, "u32")) return .{ .u = 32 };
    if (std.mem.eql(u8, name, "u64")) return .{ .u = 64 };
    if (std.mem.eql(u8, name, "f32")) return .f32;
    if (std.mem.eql(u8, name, "f64")) return .f64;
    if (std.mem.eql(u8, name, "bool")) return .bool;
    if (std.mem.eql(u8, name, "void")) return .void;
    if (std.mem.eql(u8, name, "usize")) return .usize;
    if (std.mem.eql(u8, name, "isize")) return .isize;
    return .{ .struct_type = name };
}

fn resolveTypeParamInTy(ty: sema.Ty, binding: []const sema.TypeArg) sema.Ty {
    return switch (ty) {
        .type_param => |name| blk: {
            for (binding) |arg| {
                if (std.mem.eql(u8, arg.name, name)) break :blk arg.ty;
            }
            break :blk ty;
        },
        else => ty,
    };
}

fn lowerSemaType(allocator: std.mem.Allocator, ty: sema.Ty, symbols: sema.SymbolTable) !IrType {
    return switch (ty) {
        .i8 => .{ .i = 8 },
        .i16 => .{ .i = 16 },
        .i32 => .{ .i = 32 },
        .i64 => .{ .i = 64 },
        .u8, .byte => .{ .u = 8 },
        .u16 => .{ .u = 16 },
        .u32 => .{ .u = 32 },
        .u64 => .{ .u = 64 },
        .f32 => .f32,
        .f64 => .f64,
        .bool => .bool,
        .void => .void,
        .usize => .usize,
        .isize => .isize,
        .pointer, .const_ptr => |inner| .{ .ptr = try boxType(allocator, try lowerSemaType(allocator, inner.*, symbols)) },
        .optional => |inner| .{ .optional = try boxType(allocator, try lowerSemaType(allocator, inner.*, symbols)) },
        .slice => |inner| .{ .slice = try boxType(allocator, try lowerSemaType(allocator, inner.*, symbols)) },
        .borrow => |inner| try lowerSemaType(allocator, inner.*, symbols),
        .array => |array| .{ .array = .{
            .elem = try boxType(allocator, try lowerSemaType(allocator, array.elem.*, symbols)),
            .len = array.len,
        } },
        .named => |id| .{ .struct_type = symbols.symbol(id).name },
        .error_set => .{ .variant_type = "<anonymous-error-set>" },
        .fallible => |fallible| .{ .fallible = .{
            .ok = try boxType(allocator, try lowerSemaType(allocator, fallible.ok.*, symbols)),
            .err = try boxType(allocator, try lowerSemaType(allocator, fallible.err.*, symbols)),
        } },
        .int_lit => .{ .i = 32 },
        .float_lit => .f64,
        .null_ptr => .{ .ptr = try boxType(allocator, .void) },
        // A function value is a fat closure `{ fn, env }` — carry the value-param
        // and return types so calls through it type their arguments correctly.
        .fn_ptr => |fp| blk: {
            var ps = std.ArrayList(IrType).empty;
            for (fp.params) |p| try ps.append(allocator, try lowerSemaType(allocator, p, symbols));
            break :blk .{ .fn_ptr = .{
                .params = try ps.toOwnedSlice(allocator),
                .ret = try boxType(allocator, try lowerSemaType(allocator, fp.ret.*, symbols)),
                .thin = fp.thin,
            } };
        },
        .unknown, .error_ty => .unknown,
        else => .unknown,
    };
}

fn lowerSemaTypeWithEnv(allocator: std.mem.Allocator, ty: sema.Ty, types: sema.TypeEnv, symbols: sema.SymbolTable) !IrType {
    const ptr_inner: ?*const sema.Ty = switch (ty) {
        .pointer, .const_ptr => |inner| inner,
        else => null,
    };
    if (ptr_inner) |inner| {
        if (inner.* == .named) {
            const id = inner.named;
            if (types.layouts.get(id)) |layout| if (layout.kind == .interface_type)
                return .{ .interface_value = symbols.symbol(id).name };
        }
    }
    // Distinct type: substitute the underlying type so the IR uses the real representation.
    if (ty == .named) {
        const id = ty.named;
        if (types.distinct_types.get(id)) |underlying| {
            return lowerSemaTypeWithEnv(allocator, underlying, types, symbols);
        }
    }
    return lowerSemaType(allocator, ty, symbols);
}

fn concretePointerName(ty: sema.Ty, symbols: sema.SymbolTable) ?[]const u8 {
    return switch (ty) {
        .pointer, .const_ptr => |inner| switch (inner.*) {
            .named => |id| symbols.symbol(id).name,
            else => null,
        },
        else => null,
    };
}

fn boxType(allocator: std.mem.Allocator, ty: IrType) !*const IrType {
    const ptr = try allocator.create(IrType);
    ptr.* = ty;
    return ptr;
}

/// A static `void` IrType — an OOM-proof fallback for `*const IrType` slots.
const voidType: IrType = .void;

/// A static `[]byte` IrType (the shape of `[]const u8`/`[]u8`/string literals),
/// used when spilling a folded string constant into a typed local.
const byteElemType: IrType = .byte;
const byteSliceType: IrType = .{ .slice = &byteElemType };

/// True for the IR shape of a string: a slice of bytes (`[]const u8`, `[]u8`)
/// or a folded string constant (`text`). Drives content `==`/`!=` lowering.
/// A payload comparable by a plain `eq` (so reading it for the wrong variant is
/// harmless). Aggregates (struct/array/slice/…) are excluded.
fn isScalarPayload(ty: IrType) bool {
    return switch (ty) {
        .i, .u, .f32, .f64, .bool, .byte, .usize, .isize, .addr, .rune, .ptr => true,
        else => false,
    };
}

/// A bare enum-variant operand `.a` parses to an ident whose text keeps the
/// leading dot (`".a"`). Returns the variant name without the dot, else null.
fn bareEnumVariant(e: ast.Expr) ?[]const u8 {
    return if (e.kind == .ident and e.kind.ident.len > 1 and e.kind.ident[0] == '.')
        e.kind.ident[1..]
    else
        null;
}

fn isByteSliceTy(ty: IrType) bool {
    return switch (ty) {
        .slice => |elem| switch (elem.*) {
            .byte => true,
            .u => |w| w == 8,
            else => false,
        },
        .text => true,
        else => false,
    };
}

fn assignBinOp(op: ast.AssignOp) ?BinOp {
    return switch (op) {
        .assign => null,
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .rem => .rem,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .shl => .shl,
        .shr => .shr,
    };
}

fn lowerBinOp(op: ast.BinaryOp) BinOp {
    return switch (op) {
        .or_or => .or_op,
        .and_and => .and_op,
        .equal => .eq,
        .not_equal => .ne,
        .less => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .shl => .shl,
        .shr => .shr,
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .rem => .rem,
        .wrap_add => .wrap_add,
        .wrap_sub => .wrap_sub,
        .wrap_mul => .wrap_mul,
    };
}

/// Extract the constraint string from an asm operand expression.
/// `"D"(fd)` → "D",  `"=a"(T)` → "=a"
fn extractAsmConstraint(expr: ast.Expr) ?[]const u8 {
    if (expr.kind == .call) {
        return switch (expr.kind.call.callee.kind) {
            .string => |s| trimQuotes(s),
            else => null,
        };
    }
    return null;
}

/// Names injected by the metaprogramming/compiler preludes — hidden from the
/// `compiler_decls()` view so a hook sees only the user's (and generated) decls.
pub fn isPreludeDeclName(name: []const u8) bool {
    const eq = std.mem.eql;
    return eq(u8, name, "Decl") or eq(u8, name, "CField") or eq(u8, name, "CodeBuf") or
        eq(u8, name, "gen_buf") or eq(u8, name, "emit") or eq(u8, name, "rendered") or
        std.mem.startsWith(u8, name, "Ast");
}

/// Render an AST type reference to its source-ish name for `compiler_decls()`
/// (`Decl.fields[i].type_name`, `Decl.ret`). Recurses `[]T`/`*T`/`?T`; falls back
/// to "?" for shapes without a simple spelling (fn types, generics, …).
fn astTypeName(a: std.mem.Allocator, ty: ast.TypeRef) []const u8 {
    return switch (ty) {
        .named => |n| n.name,
        .type_param => |n| n.name,
        .slice => |s| (if (s.is_const)
            std.fmt.allocPrint(a, "[]const {s}", .{astTypeName(a, s.inner.*)})
        else
            std.fmt.allocPrint(a, "[]{s}", .{astTypeName(a, s.inner.*)})) catch "?",
        .pointer => |p| (if (p.is_const)
            std.fmt.allocPrint(a, "*const {s}", .{astTypeName(a, p.inner.*)})
        else
            std.fmt.allocPrint(a, "*{s}", .{astTypeName(a, p.inner.*)})) catch "?",
        .many_pointer => |p| (std.fmt.allocPrint(a, "[*]{s}", .{astTypeName(a, p.inner.*)})) catch "?",
        .optional => |o| (std.fmt.allocPrint(a, "?{s}", .{astTypeName(a, o.inner.*)})) catch "?",
        else => "?",
    };
}

/// The `Decl.kind` string for a top-level item (see ast_prelude `compiler_source`).
fn declKindName(item: ast.Item) []const u8 {
    return switch (item) {
        .function => "fn",
        .const_decl => "const",
        .type_decl => |t| switch (t.kind) {
            .struct_type => "struct",
            .enum_type => "enum",
            .errors => "errors",
            .interface_type => "interface",
            .distinct => "distinct",
            .alias => "alias",
            .opaque_type => "opaque",
        },
        else => "other",
    };
}

/// `Decl.body` — the decl's source text. For a function, the body block
/// (`{ … }`) sliced from its own source; "" for a body-less extern fn or any
/// non-function decl. Lets a hook read what a declaration contains, not just its
/// signature.
fn declBodyText(item: ast.Item) []const u8 {
    return switch (item) {
        .function => |fnd| if (fnd.body) |b|
            (if (b.span.end <= fnd.source.len and b.span.start <= b.span.end)
                fnd.source[b.span.start..b.span.end]
            else
                "")
        else
            "",
        else => "",
    };
}

/// `Decl.derives` — the space-separated names requested by `#derive(...)` on the
/// declaration. A user `#compiler` hook reads this to generate impls for its own
/// derive name (e.g. `if d.derives == "Show"`). Built-in derive names appear here
/// too (the parser also generates their impls).
fn declDerives(allocator: std.mem.Allocator, item: ast.Item) ![]const u8 {
    const attrs: []const ast.Attribute = switch (item) {
        .type_decl => |t| t.attrs,
        .function => |f| f.attrs,
        .const_decl => |c| c.attrs,
        else => return "",
    };
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (attrs) |a| {
        if (!std.mem.eql(u8, a.name, "derive")) continue;
        for (a.args) |arg| switch (arg.kind) {
            .ident => |n| {
                if (buf.items.len > 0) try buf.append(allocator, ' ');
                try buf.appendSlice(allocator, n);
            },
            else => {},
        };
    }
    return buf.toOwnedSlice(allocator);
}

/// `core::<member>` — the reserved compiler-builtin namespace (mirrors sema's
/// `isCoreNamespace`). `core` is not a real module; its members route to the
/// builtin lowering by member name.
fn isCoreNs(sa: ast.ScopeAccess) bool {
    return sa.base.kind == .ident and std.mem.eql(u8, sa.base.kind.ident, "core");
}

/// Derive a module name from a file path for `core::module`: the basename with a
/// trailing `.k2` stripped (e.g. `lib/std/heap.k2` → `heap`).
fn moduleNameOf(file: []const u8) []const u8 {
    var base = file;
    if (std.mem.lastIndexOfAny(u8, base, "/\\")) |i| base = base[i + 1 ..];
    if (std.mem.endsWith(u8, base, ".sk")) base = base[0 .. base.len - 3];
    return base;
}

/// Map a `core::` member to the internal builtin name: `panic`→`@panic` (reuses
/// the runtime-symbol + VM-trap path) and the tidied renames (`type_id`→
/// `typeid_of`, `narrow`→`truncate_to`, `slice_raw`→`slice_from_raw_parts`).
fn coreCanonical(member: []const u8) []const u8 {
    const eq = std.mem.eql;
    if (eq(u8, member, "panic")) return "@panic";
    if (eq(u8, member, "type_id")) return "typeid_of";
    if (eq(u8, member, "narrow")) return "truncate_to";
    if (eq(u8, member, "slice_raw")) return "slice_from_raw_parts";
    return member;
}

fn isBuiltinName(name: []const u8) bool {
    inline for (.{
        "truncate_to",
        "ptr_from_int",
        "slice_from_raw_parts",
        "volatile_store",
        "sizeof",
        "type_info",
        "type_name",
        "unaligned_read",
        "asm",
        "atomic_load",
        "atomic_store",
        "atomic_add",
        "atomic_sub",
        "atomic_and",
        "atomic_or",
        "atomic_xor",
        "atomic_exchange",
        "atomic_cas",
        "atomic_fence",
        "atomic_max",
        "atomic_min",
        "atomic_nand",
        "compound_literal",
        "slice",
        "__str_cat",
        "compiler_error",
        "compiler_remove",
        // std.build host intrinsics (comptime-only; lowered to host_call in the VM).
        "__build_artifact",
        "__build_opt",
        "__build_link",
        "__build_libpath",
        "__build_output",
        "__build_define",
        "__build_default",
        "__build_run",
        "__build_test",
        "__build_require",
        "__build_depend",
        "__build_subsystem",
        "__build_entry",
        "__build_stack",
        "__build_linkflag",
        "__build_outdir",
        "__build_version",
        "__build_desc",
        "__build_workspace",
        "__build_outroot",
        "__build_install",
        "__build_optionflag",
        "__build_optionstr",
        "__build_summary",
        "__build_linkmode",
        "__build_runtimefile",
        "__build_nodefaultlibs",
        "__build_linklibc",
    }) |builtin| {
        if (std.mem.eql(u8, name, builtin)) return true;
    }
    return isCoreOnlyBuiltin(name);
}

/// Newer `core::` builtin families (math/bit/memory). Separated because their
/// names overlap plausible user functions (`min`, `max`, `abs`, `round`, …), so
/// the IR routes them to a builtin ONLY when called as `core::<name>`.
fn isCoreOnlyBuiltin(name: []const u8) bool {
    inline for (.{
        // bit
        "count_ones",    "count_zeros",   "leading_zeros", "trailing_zeros",
        "swap_bytes",    "reverse_bits",  "rotate_left",   "rotate_right",
        // math
        "min", "max", "abs", "clamp", "sqrt", "floor", "ceil", "round",
        "trunc", "sin", "cos", "pow", "fma",
        // memory / control
        "memcpy", "memset", "trap", "unreachable", "cycle_count", "prefetch",
    }) |builtin| {
        if (std.mem.eql(u8, name, builtin)) return true;
    }
    return false;
}

/// VM-backed comptime evaluator — the sole comptime engine. Lazily lowers the
/// whole module to bytecode (memoized) and runs `#run` expressions on the VM.
/// Every entry point is best-effort: it returns null when an expression cannot
/// be folded to a constant, letting the caller lower the operand for runtime
/// instead (there is no AST tree-walker fallback).
pub const ComptimeVm = struct {
    /// General-purpose allocator for the VM's transient per-call frames.
    gpa: std.mem.Allocator,
    /// Owns every cache/eval allocation (IR, bytecode, synthetic functions);
    /// freed wholesale on `deinit`, so nothing leaks regardless of the caller.
    arena: std.heap.ArenaAllocator,
    front_end: pipeline.FrontEnd,
    cache: ?Cache = null,
    cache_failed: bool = false,
    /// The file a `#run`/`#insert` expression lives in, so synthetic eval
    /// functions resolve namespace (`ns::member`) access in the right module.
    current_file: []const u8 = "",
    /// Set when a `#compiler` hook called `compiler_error("...")` — the diagnostic
    /// to report (instead of a generic failure).
    hook_error: ?[]const u8 = null,
    /// Names a `#compiler` hook asked to drop via `compiler_remove("...")`,
    /// accumulated across hook evaluations (each eval uses a fresh `Vm`, so the
    /// names are drained here). Allocated on `arena`.
    removals: std.ArrayList([]const u8) = .empty,

    const Cache = struct {
        ir_module: IrModule,
        bc: vm_instructions.BytecodeModule,
        func_map: std.StringHashMap(u32),
    };

    pub fn init(allocator: std.mem.Allocator, front_end: pipeline.FrontEnd) ComptimeVm {
        return .{
            .gpa = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .front_end = front_end,
        };
    }

    pub fn deinit(self: *ComptimeVm) void {
        self.arena.deinit();
    }

    fn ensureCache(self: *ComptimeVm) ?*Cache {
        if (self.cache != null) return &self.cache.?;
        if (self.cache_failed) return null;
        self.cache = self.buildCache() catch {
            self.cache_failed = true;
            return null;
        };
        return &self.cache.?;
    }

    fn buildCache(self: *ComptimeVm) !Cache {
        const a = self.arena.allocator();
        // Lower the module with NO evaluator (cvm = null) so that any nested
        // `#run` encountered while building this cache lowers its operand
        // directly instead of recursing back into the VM — the recursion guard.
        const irm = try lowerModuleInner(a, self.front_end, null);
        const bc = try vm_compiler.compileModule(a, irm);
        var fm = std.StringHashMap(u32).init(a);
        for (irm.functions, 0..) |f, i| try fm.put(f.name, @intCast(i));
        return .{ .ir_module = irm, .bc = bc, .func_map = fm };
    }

    fn evalRaw(self: *ComptimeVm, expr: ast.Expr) ?vm_value.Value {
        const _ct = ctNow();
        defer ctAdd(_ct);
        const c = self.ensureCache() orelse return null;
        const a = self.arena.allocator();
        const irfn = lowerExprToFunction(a, self.front_end, expr, self.current_file) catch return null;
        const bc_fn = vm_compiler.compileFunction(a, irfn, &c.func_map, c.ir_module) catch return null;
        var vm = vm_engine.Vm.initModule(self.gpa, &c.bc);
        defer vm.deinit();
        // `execute` enters the implicit root zone so aggregate `#run` exprs
        // (struct/enum/optional construction) have an arena to allocate in.
        const result = vm.execute(bc_fn) catch |err| {
            // A comptime `@panic("…")` records its message via `halt_msg`; capture
            // it (dup before the VM is torn down) so the `#run` error shows it
            // instead of a generic "could not evaluate" message.
            if (err == error.Trap) {
                if (vm.compiler_error_msg) |m| self.hook_error = self.arena.allocator().dupe(u8, m) catch null;
            }
            return null;
        };
        return result;
    }

    fn evalToValue(self: *ComptimeVm, expr: ast.Expr) ?Value {
        const imm = (self.evalRaw(expr) orelse return null).toImm() orelse return null;
        return Value{ .imm = imm };
    }

    fn evalToImm(self: *ComptimeVm, expr: ast.Expr) ?Imm {
        return (self.evalRaw(expr) orelse return null).toImm();
    }

    /// Evaluate `expr` on the VM and reify the resulting `AstBlock` value into
    /// front-end AST (allocated on `out_alloc`). The VM's zones are kept alive
    /// across reification (`executeKeepZones`) so the cells can be read.
    fn evalToAstBlock(
        self: *ComptimeVm,
        expr: ast.Expr,
        out_alloc: std.mem.Allocator,
        span: Span,
        next_id: *ast.NodeId,
    ) ?ast.Block {
        const _ct = ctNow();
        defer ctAdd(_ct);
        const c = self.ensureCache() orelse return null;
        const a = self.arena.allocator();
        const irfn = lowerExprToFunction(a, self.front_end, expr, self.current_file) catch return null;
        const bc_fn = vm_compiler.compileFunction(a, irfn, &c.func_map, c.ir_module) catch return null;
        var vm = vm_engine.Vm.initModule(self.gpa, &c.bc);
        defer vm.deinit();
        const result = vm.executeKeepZones(bc_fn) catch return null;
        var r = Reifier{ .allocator = out_alloc, .vm = &vm, .module = c.ir_module, .next_id = next_id, .span = span };
        return r.reifyBlock(result) catch null;
    }

    /// Evaluate `expr` on the VM and return its string result, duped onto
    /// `out_alloc` (the value may live in a zone freed at `deinit`). For `#parse`.
    fn evalToString(self: *ComptimeVm, expr: ast.Expr, out_alloc: std.mem.Allocator) ?[]const u8 {
        const _ct = ctNow();
        defer ctAdd(_ct);
        const c = self.ensureCache() orelse return null;
        const a = self.arena.allocator();
        const irfn = lowerExprToFunction(a, self.front_end, expr, self.current_file) catch return null;
        const bc_fn = vm_compiler.compileFunction(a, irfn, &c.func_map, c.ir_module) catch return null;
        var vm = vm_engine.Vm.initModule(self.gpa, &c.bc);
        defer vm.deinit();
        const result = vm.executeKeepZones(bc_fn) catch {
            // A `compiler_error("...")` halt — carry the diagnostic out.
            if (vm.compiler_error_msg) |m| self.hook_error = out_alloc.dupe(u8, m) catch null;
            return null;
        };
        // Drain any `compiler_remove("...")` requests into the cvm (the `Vm` is
        // per-eval and about to be deinit'd) so the driver can apply them.
        const aa = self.arena.allocator();
        for (vm.compiler_removals.items) |nm| {
            self.removals.append(aa, aa.dupe(u8, nm) catch return null) catch return null;
        }
        return switch (result) {
            .string => |s| out_alloc.dupe(u8, s) catch null,
            // A hook may RETURN a built `[]u8`/`[]const u8` (e.g. via the compiler
            // prelude's `CodeBuf`) instead of a string literal — read its bytes out
            // of the VM zone (kept alive by `executeKeepZones`).
            .slice => |s| blk: {
                const bytes = out_alloc.alloc(u8, s.len) catch return null;
                var i: usize = 0;
                while (i < s.len) : (i += 1) {
                    const cell = vm.zone_stack.getCell(s.zone, s.offset + @as(u32, @intCast(i))) catch return null;
                    bytes[i] = switch (cell) {
                        .int => |v| @intCast(@mod(v, 256)),
                        .uint => |v| @intCast(v % 256),
                        else => return null,
                    };
                }
                break :blk bytes;
            },
            // A `[]u8` over real host memory (e.g. `StringBuilder.str()` now that
            // std.heap runs at comptime) — copy the bytes straight out.
            .host_buf => |hb| blk: {
                if (hb.addr == 0) break :blk null;
                const bytes = out_alloc.alloc(u8, hb.len) catch return null;
                const p: [*]const u8 = @ptrFromInt(hb.addr);
                @memcpy(bytes, p[0..hb.len]);
                break :blk bytes;
            },
            else => null,
        };
    }

    /// Evaluate a `where { … }` predicate for one instantiation (with `type_args`
    /// bound). Returns the rejection message ("" = accept), or null if the VM
    /// couldn't run it (treated as accept, so a malformed predicate doesn't block).
    pub fn evalWhere(self: *ComptimeVm, where_block: ast.Block, type_args: []const sema.TypeArg, output_params: []const []const u8, inst_expr_types: @TypeOf(@as(sema.TypeEnv, undefined).expr_types), out_alloc: std.mem.Allocator) ?[]const u8 {
        const _ct = ctNow();
        defer ctAdd(_ct);
        const c = self.ensureCache() orelse return null;
        const a = self.arena.allocator();
        // The where block was sema-typed in the per-instantiation pass, so its
        // expr types live in `inst_expr_types`, not the global env.
        var inst_fe = self.front_end;
        inst_fe.types.expr_types = inst_expr_types;
        const irfn = lowerWhereToFunction(a, inst_fe, where_block, type_args, output_params, self.current_file) catch return null;
        const bc_fn = vm_compiler.compileFunction(a, irfn, &c.func_map, c.ir_module) catch return null;
        var vm = vm_engine.Vm.initModule(self.gpa, &c.bc);
        defer vm.deinit();
        const result = vm.executeKeepZones(bc_fn) catch return null;
        return switch (result) {
            .string => |s| out_alloc.dupe(u8, s) catch null,
            else => null,
        };
    }

    /// Run a `where` block to compute the output type param `Acc`: returns the
    /// node id of the selected `Acc = <type>` right-hand side (0 = not assigned),
    /// which sema resolves back to a concrete type for this instantiation.
    pub fn evalWhereType(self: *ComptimeVm, where_block: ast.Block, type_args: []const sema.TypeArg, output_params: []const []const u8, inst_expr_types: @TypeOf(@as(sema.TypeEnv, undefined).expr_types)) ?u64 {
        const _ct = ctNow();
        defer ctAdd(_ct);
        const c = self.ensureCache() orelse return null;
        const a = self.arena.allocator();
        var inst_fe = self.front_end;
        inst_fe.types.expr_types = inst_expr_types;
        const irfn = lowerWhereTypeToFunction(a, inst_fe, where_block, type_args, output_params, self.current_file) catch return null;
        const bc_fn = vm_compiler.compileFunction(a, irfn, &c.func_map, c.ir_module) catch return null;
        var vm = vm_engine.Vm.initModule(self.gpa, &c.bc);
        defer vm.deinit();
        const result = vm.executeKeepZones(bc_fn) catch return null;
        return switch (result) {
            .uint => |u| @intCast(u),
            .int => |i| if (i >= 0) @intCast(i) else null,
            else => null,
        };
    }
};

// ── Reifier: VM value → front-end AST ────────────────────────────────────────
// The inverse of `materializeBlock`/`materializeExpr`: walks the zone-cell
// representation of an `AstBlock` value the VM built and reconstructs real
// `ast.*` nodes. Variant tags index the declaration order in `ast_prelude.zig`;
// struct field offsets match the prelude's field order. The compiler stamps
// fresh NodeIds (from a reserved range) and the `#insert` site's span.

/// Reified nodes get ids from this base — distinct from user nodes (small ids)
/// and the prelude (900_000+).
const reified_id_base: ast.NodeId = 800_000;

const Reifier = struct {
    allocator: std.mem.Allocator,
    vm: *vm_engine.Vm,
    module: IrModule,
    next_id: *ast.NodeId,
    span: Span,

    const Error = error{ ReifyFailed, OutOfMemory };

    fn ptrOf(v: vm_value.Value) Error!vm_value.Value.Ptr {
        return switch (v) {
            .ptr => |p| p,
            .struct_ref => |r| .{ .zone = r.zone, .offset = r.offset },
            else => error.ReifyFailed,
        };
    }

    fn cellAt(self: *Reifier, p: vm_value.Value.Ptr, off: u32) Error!vm_value.Value {
        return self.vm.zone_stack.getCell(p.zone, p.offset + off) catch error.ReifyFailed;
    }

    /// The variant NAME for `type_name`'s tag, looked up from the lowered module
    /// — so the reifier is robust to prelude variant reordering/growth.
    fn variantName(self: *Reifier, type_name: []const u8, p: vm_value.Value.Ptr) Error![]const u8 {
        const tag = (try self.cellAt(p, 0)).asI128() orelse return error.ReifyFailed;
        const t: usize = std.math.cast(usize, tag) orelse return error.ReifyFailed;
        for (self.module.variants) |vd| {
            if (!std.mem.eql(u8, vd.name, type_name)) continue;
            if (t >= vd.variants.len) return error.ReifyFailed;
            return vd.variants[t].name;
        }
        return error.ReifyFailed;
    }

    fn freshId(self: *Reifier) ast.NodeId {
        const id = self.next_id.*;
        self.next_id.* += 1;
        return id;
    }

    fn dupeString(self: *Reifier, v: vm_value.Value) Error![]const u8 {
        return switch (v) {
            .string => |s| try self.allocator.dupe(u8, s),
            else => error.ReifyFailed,
        };
    }

    /// Reify a cell that holds an `AstExpr` value into a heap `*ast.Expr`.
    fn reifyExprPtr(self: *Reifier, cell: vm_value.Value) Error!*const ast.Expr {
        const e = try self.allocator.create(ast.Expr);
        e.* = try self.reifyExpr(cell);
        return e;
    }

    fn reifyBlock(self: *Reifier, v: vm_value.Value) Error!ast.Block {
        // AstBlock = struct { stmts: []AstStmt } — one cell holding the slice.
        const p = try ptrOf(v);
        const sl = switch (try self.cellAt(p, 0)) {
            .slice => |s| s,
            else => return error.ReifyFailed,
        };
        const stmts = try self.allocator.alloc(ast.Stmt, sl.len);
        for (stmts, 0..) |*out, i| {
            const elem = self.vm.zone_stack.getCell(sl.zone, sl.offset + @as(u32, @intCast(i))) catch return error.ReifyFailed;
            out.* = try self.reifyStmt(elem);
        }
        return .{ .statements = stmts, .span = self.span };
    }

    fn reifyStmt(self: *Reifier, v: vm_value.Value) Error!ast.Stmt {
        const p = try ptrOf(v);
        const name = try self.variantName("AstStmt", p);
        const payload = try self.cellAt(p, 1); // .void for payload-less variants
        const eq = std.mem.eql;

        if (eq(u8, name, "local")) {
            const pl = try ptrOf(payload); // AstLocal { name, value }
            return .{ .local_infer = .{
                .name = try self.dupeString(try self.cellAt(pl, 0)),
                .value = try self.reifyExpr(try self.cellAt(pl, 1)),
                .span = self.span,
            } };
        } else if (eq(u8, name, "assign")) {
            const pl = try ptrOf(payload); // AstAssign { target, value }
            return .{
                .assign = .{
                    .target = try self.reifyExpr(try self.cellAt(pl, 0)),
                    .op = .assign, // compound ops were desugared at materialize time
                    .value = try self.reifyExpr(try self.cellAt(pl, 1)),
                    .span = self.span,
                },
            };
        } else if (eq(u8, name, "ret")) {
            return .{ .return_stmt = .{ .value = null, .span = self.span } };
        } else if (eq(u8, name, "ret_expr")) {
            return .{ .return_stmt = .{ .value = try self.reifyExpr(payload), .span = self.span } };
        } else if (eq(u8, name, "cond")) {
            const pl = try ptrOf(payload); // AstIf { cond, then_block, else_block }
            const else_block = try self.reifyBlock(try self.cellAt(pl, 2));
            return .{
                .if_stmt = .{
                    .binding = null,
                    .payload_binding = null,
                    .condition = try self.reifyExpr(try self.cellAt(pl, 0)),
                    .then_block = try self.reifyBlock(try self.cellAt(pl, 1)),
                    // An empty else-block means there was no `else`.
                    .else_block = if (else_block.statements.len == 0) null else else_block,
                    .span = self.span,
                },
            };
        } else if (eq(u8, name, "loop")) {
            const pl = try ptrOf(payload); // AstWhile { cond, body }
            return .{ .while_stmt = .{
                .condition = try self.reifyExpr(try self.cellAt(pl, 0)),
                .payload_binding = null,
                .body = try self.reifyBlock(try self.cellAt(pl, 1)),
                .span = self.span,
            } };
        } else if (eq(u8, name, "local_typed")) {
            const pl = try ptrOf(payload); // AstLocalTyped { name, ty, value }
            return .{ .local_typed = .{
                .name = try self.dupeString(try self.cellAt(pl, 0)),
                .ty = try self.reifyType(try self.cellAt(pl, 1)),
                .value = try self.reifyExpr(try self.cellAt(pl, 2)),
                .span = self.span,
            } };
        } else if (eq(u8, name, "for_range")) {
            const pl = try ptrOf(payload); // AstForRange { binding, start, end, inclusive, body }
            return .{ .for_range = .{
                .binding = try self.dupeString(try self.cellAt(pl, 0)),
                .start = try self.reifyExpr(try self.cellAt(pl, 1)),
                .end = try self.reifyExpr(try self.cellAt(pl, 2)),
                .inclusive = try self.boolAt(pl, 3),
                .body = try self.reifyBlock(try self.cellAt(pl, 4)),
                .span = self.span,
            } };
        } else if (eq(u8, name, "for_slice")) {
            const pl = try ptrOf(payload); // AstForSlice { binding, index_binding, by_ref, iter, body }
            return .{ .for_slice = .{
                .binding = try self.dupeString(try self.cellAt(pl, 0)),
                .index_binding = try self.optStr(try self.cellAt(pl, 1)),
                .by_ref = try self.boolAt(pl, 2),
                .iter = try self.reifyExpr(try self.cellAt(pl, 3)),
                .body = try self.reifyBlock(try self.cellAt(pl, 4)),
                .span = self.span,
            } };
        } else if (eq(u8, name, "match_s")) {
            const pl = try ptrOf(payload); // AstMatch { subject, arms }
            const subject = try self.reifyExpr(try self.cellAt(pl, 0));
            const sl = switch (try self.cellAt(pl, 1)) {
                .slice => |s| s,
                else => return error.ReifyFailed,
            };
            const stride: u32 = @intCast(self.structStride("AstMatchArm"));
            const arms = try self.allocator.alloc(ast.MatchArm, sl.len);
            for (arms, 0..) |*out, i| {
                const cell = self.vm.zone_stack.getCell(sl.zone, sl.offset + @as(u32, @intCast(i)) * stride) catch return error.ReifyFailed;
                out.* = try self.reifyMatchArm(cell);
            }
            return .{ .match_stmt = .{ .subject = subject, .arms = arms, .span = self.span } };
        } else if (eq(u8, name, "zone_s")) {
            const pl = try ptrOf(payload); // AstZone { name, kind, body }
            return .{ .zone_block = .{
                .name = try self.dupeString(try self.cellAt(pl, 0)),
                .kind = try self.dupeString(try self.cellAt(pl, 1)),
                .body = try self.reifyBlock(try self.cellAt(pl, 2)),
                .span = self.span,
            } };
        } else if (eq(u8, name, "defer_s")) {
            const pl = try ptrOf(payload); // AstDefer { mode, body }
            const mode_name = try self.variantName("AstDeferMode", try ptrOf(try self.cellAt(pl, 0)));
            const mode: ast.DeferMode = if (eq(u8, mode_name, "ok_only"))
                .ok
            else if (eq(u8, mode_name, "err_only"))
                .err
            else
                .always;
            return .{ .defer_stmt = .{
                .mode = mode,
                .body = try self.reifyBlock(try self.cellAt(pl, 1)),
                .span = self.span,
            } };
        } else if (eq(u8, name, "fail_s")) {
            const pl = try ptrOf(payload); // AstFail { variant, payload }
            const variant = try self.dupeString(try self.cellAt(pl, 0));
            const sl = switch (try self.cellAt(pl, 1)) {
                .slice => |s| s,
                else => return error.ReifyFailed,
            };
            const payloads = try self.allocator.alloc(ast.Expr, sl.len);
            for (payloads, 0..) |*out, i| {
                const cell = self.vm.zone_stack.getCell(sl.zone, sl.offset + @as(u32, @intCast(i))) catch return error.ReifyFailed;
                out.* = try self.reifyExpr(cell);
            }
            return .{ .fail_stmt = .{ .variant = variant, .payload = payloads, .span = self.span } };
        } else if (eq(u8, name, "unsafe_blk")) {
            return .{ .unsafe_block = try self.reifyBlock(payload) };
        } else if (eq(u8, name, "brk")) {
            return .{ .break_stmt = self.span };
        } else if (eq(u8, name, "cont")) {
            return .{ .continue_stmt = self.span };
        } else if (eq(u8, name, "expr")) {
            return .{ .expr = try self.reifyExpr(payload) };
        }
        return error.ReifyFailed;
    }

    fn reifyExpr(self: *Reifier, v: vm_value.Value) Error!ast.Expr {
        const p = try ptrOf(v);
        const name = try self.variantName("AstExpr", p);
        const payload = try self.cellAt(p, 1);
        const eq = std.mem.eql;

        const kind: ast.ExprKind = if (eq(u8, name, "int")) blk: {
            const n = payload.asI128() orelse return error.ReifyFailed;
            if (n < 0) {
                // Defensive: literal text is unsigned, so emit -(literal).
                const inner = try self.allocator.create(ast.Expr);
                inner.* = .{ .id = self.freshId(), .kind = .{ .int = try std.fmt.allocPrint(self.allocator, "{d}", .{-n}) }, .span = self.span };
                break :blk .{ .unary = .{ .op = .neg, .expr = inner } };
            }
            break :blk .{ .int = try std.fmt.allocPrint(self.allocator, "{d}", .{n}) };
        } else if (eq(u8, name, "float")) blk: {
            const f = switch (payload) {
                .float => |x| x,
                else => return error.ReifyFailed,
            };
            break :blk .{ .float = try std.fmt.allocPrint(self.allocator, "{d}", .{f}) };
        } else if (eq(u8, name, "str")) blk: {
            break :blk .{ .string = try self.dupeString(payload) }; // raw, still-quoted text
        } else if (eq(u8, name, "boolean")) blk: {
            break :blk .{ .bool = switch (payload) {
                .bool => |b| b,
                else => return error.ReifyFailed,
            } };
        } else if (eq(u8, name, "nothing")) blk: {
            break :blk .null;
        } else if (eq(u8, name, "ident")) blk: {
            break :blk .{ .ident = try self.dupeString(payload) };
        } else if (eq(u8, name, "unary")) blk: {
            const pu = try ptrOf(payload); // AstUnary { op, operand }
            const op = astUnOpFromName(try self.variantName("AstUnOp", try ptrOf(try self.cellAt(pu, 0)))) orelse return error.ReifyFailed;
            break :blk .{ .unary = .{ .op = op, .expr = try self.reifyExprPtr(try self.cellAt(pu, 1)) } };
        } else if (eq(u8, name, "binary")) blk: {
            const pb = try ptrOf(payload); // AstBinary { op, left, right }
            const op = astBinOpFromName(try self.variantName("AstBinOp", try ptrOf(try self.cellAt(pb, 0)))) orelse return error.ReifyFailed;
            break :blk .{ .binary = .{
                .op = op,
                .left = try self.reifyExprPtr(try self.cellAt(pb, 1)),
                .right = try self.reifyExprPtr(try self.cellAt(pb, 2)),
            } };
        } else if (eq(u8, name, "call")) blk: {
            const pc = try ptrOf(payload); // AstCall { callee, args:[]AstArg }
            const callee = try self.reifyExprPtr(try self.cellAt(pc, 0));
            const sl = switch (try self.cellAt(pc, 1)) {
                .slice => |s| s,
                else => return error.ReifyFailed,
            };
            const stride: u32 = @intCast(self.structStride("AstArg"));
            const args = try self.allocator.alloc(ast.CallArg, sl.len);
            for (args, 0..) |*out, i| {
                const arg_cell = self.vm.zone_stack.getCell(sl.zone, sl.offset + @as(u32, @intCast(i)) * stride) catch return error.ReifyFailed;
                const pa = try ptrOf(arg_cell); // AstArg { name, value }
                const arg_name = try self.optStr(try self.cellAt(pa, 0));
                const value = try self.reifyExpr(try self.cellAt(pa, 1));
                out.* = if (arg_name) |nm|
                    .{ .named = .{ .name = nm, .value = value } }
                else
                    .{ .positional = value };
            }
            break :blk .{ .call = .{ .callee = callee, .args = args } };
        } else if (eq(u8, name, "field")) blk: {
            const pf = try ptrOf(payload); // AstField { base, name }
            break :blk .{ .field = .{
                .base = try self.reifyExprPtr(try self.cellAt(pf, 0)),
                .name = try self.dupeString(try self.cellAt(pf, 1)),
            } };
        } else if (eq(u8, name, "index")) blk: {
            const pi = try ptrOf(payload); // AstIndex { base, idx }
            break :blk .{ .index = .{
                .base = try self.reifyExprPtr(try self.cellAt(pi, 0)),
                .index = try self.reifyExprPtr(try self.cellAt(pi, 1)),
            } };
        } else if (eq(u8, name, "slice")) blk: {
            const ps = try ptrOf(payload); // AstSliceE { base, start, end }
            break :blk .{ .slice = .{
                .base = try self.reifyExprPtr(try self.cellAt(ps, 0)),
                .start = try self.reifyOptExprPtr(try self.cellAt(ps, 1)),
                .end = try self.reifyOptExprPtr(try self.cellAt(ps, 2)),
            } };
        } else if (eq(u8, name, "cast")) blk: {
            const pc = try ptrOf(payload); // AstCastE { value, to }
            break :blk .{ .as_cast = .{
                .value = try self.reifyExprPtr(try self.cellAt(pc, 0)),
                .to = try self.reifyType(try self.cellAt(pc, 1)),
            } };
        } else if (eq(u8, name, "unwrap")) blk: {
            break :blk .{ .force_unwrap = try self.reifyExprPtr(payload) };
        } else if (eq(u8, name, "coalesce")) blk: {
            const pc = try ptrOf(payload); // AstCoalesce { value, default }
            break :blk .{ .nil_coalesce = .{
                .value = try self.reifyExprPtr(try self.cellAt(pc, 0)),
                .default = try self.reifyExprPtr(try self.cellAt(pc, 1)),
            } };
        } else if (eq(u8, name, "try_q")) blk: {
            break :blk .{ .try_expr = .{ .value = try self.reifyExprPtr(payload) } };
        } else if (eq(u8, name, "catch_b")) blk: {
            const pc = try ptrOf(payload); // AstCatchE { value, err_name, handler }
            break :blk .{ .catch_expr = .{
                .value = try self.reifyExprPtr(try self.cellAt(pc, 0)),
                .err_name = try self.dupeString(try self.cellAt(pc, 1)),
                .handler = try self.reifyBlock(try self.cellAt(pc, 2)),
            } };
        } else if (eq(u8, name, "compound")) blk: {
            const sl = switch (payload) {
                .slice => |s| s,
                else => return error.ReifyFailed,
            };
            const elems = try self.allocator.alloc(ast.Expr, sl.len);
            for (elems, 0..) |*out, i| {
                const cell = self.vm.zone_stack.getCell(sl.zone, sl.offset + @as(u32, @intCast(i))) catch return error.ReifyFailed;
                out.* = try self.reifyExpr(cell);
            }
            break :blk .{ .compound_literal = elems };
        } else if (eq(u8, name, "unsafe_e")) blk: {
            break :blk .{ .unsafe_expr = try self.reifyExprPtr(payload) };
        } else return error.ReifyFailed;

        return .{ .id = self.freshId(), .kind = kind, .span = self.span };
    }

    // ── Type references, optionals, match arms ───────────────────────────────

    fn boolAt(self: *Reifier, p: vm_value.Value.Ptr, off: u32) Error!bool {
        return switch (try self.cellAt(p, off)) {
            .bool => |b| b,
            else => error.ReifyFailed,
        };
    }

    /// Empty string → null (the "absent optional string" convention).
    fn optStr(self: *Reifier, v: vm_value.Value) Error!?[]const u8 {
        const s = try self.dupeString(v);
        return if (s.len == 0) null else s;
    }

    /// A `*AstExpr` that may be the `nothing` sentinel → `?*const ast.Expr`.
    fn reifyOptExprPtr(self: *Reifier, cell: vm_value.Value) Error!?*const ast.Expr {
        const e = try self.reifyExpr(cell);
        if (e.kind == .null) return null;
        const p = try self.allocator.create(ast.Expr);
        p.* = e;
        return p;
    }

    /// Cell count (stride) of a struct element in a materialized slice.
    fn structStride(self: *Reifier, name: []const u8) usize {
        for (self.module.structs) |sd| {
            if (std.mem.eql(u8, sd.name, name)) return sd.fields.len;
        }
        return 1;
    }

    fn reifyTypePtr(self: *Reifier, cell: vm_value.Value) Error!*const ast.TypeRef {
        const t = try self.allocator.create(ast.TypeRef);
        t.* = try self.reifyType(cell);
        return t;
    }

    fn reifyType(self: *Reifier, v: vm_value.Value) Error!ast.TypeRef {
        const p = try ptrOf(v);
        const name = try self.variantName("AstType", p);
        const payload = try self.cellAt(p, 1);
        const eq = std.mem.eql;
        if (eq(u8, name, "named")) {
            return .{ .named = .{ .name = try self.dupeString(payload), .span = self.span } };
        } else if (eq(u8, name, "ptr")) {
            return .{ .pointer = .{ .is_const = false, .is_volatile = false, .inner = try self.reifyTypePtr(payload), .span = self.span } };
        } else if (eq(u8, name, "slice_of")) {
            return .{ .slice = .{ .is_const = false, .inner = try self.reifyTypePtr(payload), .span = self.span } };
        } else if (eq(u8, name, "optional_of")) {
            return .{ .optional = .{ .inner = try self.reifyTypePtr(payload), .span = self.span } };
        } else if (eq(u8, name, "array_of")) {
            const pa = try ptrOf(payload); // AstArrayTy { len, elem }
            const len = try self.allocator.create(ast.Expr);
            len.* = try self.reifyExpr(try self.cellAt(pa, 0));
            return .{ .array = .{ .len = len, .inner = try self.reifyTypePtr(try self.cellAt(pa, 1)), .span = self.span } };
        }
        return error.ReifyFailed;
    }

    fn reifyPattern(self: *Reifier, v: vm_value.Value) Error!ast.MatchPattern {
        const p = try ptrOf(v);
        const name = try self.variantName("AstPattern", p);
        const payload = try self.cellAt(p, 1);
        const eq = std.mem.eql;
        if (eq(u8, name, "variant")) {
            return .{ .enum_variant = try self.dupeString(payload) };
        } else if (eq(u8, name, "ints")) {
            const sl = switch (payload) {
                .slice => |s| s,
                else => return error.ReifyFailed,
            };
            const vals = try self.allocator.alloc(ast.Expr, sl.len);
            for (vals, 0..) |*out, i| {
                const cell = self.vm.zone_stack.getCell(sl.zone, sl.offset + @as(u32, @intCast(i))) catch return error.ReifyFailed;
                out.* = try self.reifyExpr(cell);
            }
            return .{ .int_values = vals };
        } else if (eq(u8, name, "anything")) {
            return .else_arm;
        }
        return error.ReifyFailed;
    }

    fn reifyMatchArm(self: *Reifier, v: vm_value.Value) Error!ast.MatchArm {
        const p = try ptrOf(v); // AstMatchArm { pattern, binding, body }
        return .{
            .pattern = try self.reifyPattern(try self.cellAt(p, 0)),
            .binding = try self.optStr(try self.cellAt(p, 1)),
            .body = try self.reifyBlock(try self.cellAt(p, 2)),
            .span = self.span,
        };
    }
};

// ── Two-pass `#insert`: evaluate computed operands, splice, re-check ─────────
// `#insert <computed>` (e.g. `#insert #run gen()`) needs the VM (post-sema) to
// produce the code, but the code must be spliced pre-sema to be type-checked.
// Pass 1: sema the module, run each computed operand on the VM, reify the
// resulting AstBlock into front-end AST, and rewrite the operand to a literal
// `#quote { ... }`. Pass 2 (in pipeline.zig): re-run sema on the result, where
// the existing literal-quote path splices and checks it like hand-written code.

pub const InsertExpandError = error{ SemanticFailed, OutOfMemory };

/// True if the module has any `#compiler` hook — a function the compiler runs at
/// compile time to generate/inspect the program (the Phase-3 message loop).
pub fn hasCompilerHook(module: ast.Module) bool {
    for (module.items) |item| switch (item) {
        .function => |f| if (hasAttr(f.attrs, "compiler")) return true,
        else => {},
    };
    return false;
}

/// A `#compiler(final)` hook runs in the FINAL phase — after generation +
/// mutation, over the fully-augmented program (so it sees generated decls).
/// A bare `#compiler` runs in the default GENERATE phase. The phase is the first
/// argument to the `compiler` attribute (an ident `final`).
fn compilerHookIsFinal(attrs: []const ast.Attribute) bool {
    for (attrs) |attr| {
        if (!std.mem.eql(u8, attr.name, "compiler")) continue;
        if (attr.args.len > 0 and attr.args[0].kind == .ident)
            return std.mem.eql(u8, attr.args[0].kind.ident, "final");
    }
    return false;
}

/// Whether the module has any `#compiler(final)` hook (so the driver knows to
/// run the second, post-generation phase).
pub fn hasFinalHook(module: ast.Module) bool {
    for (module.items) |item| switch (item) {
        .function => |f| if (hasAttr(f.attrs, "compiler") and compilerHookIsFinal(f.attrs)) return true,
        else => {},
    };
    return false;
}

/// Synthetic-expr id base for `#compiler` hook calls (distinct from user ids,
/// the reifier's 800_000, and the prelude's 900_000).
const compiler_hook_id_base: ast.NodeId = 500_000;

/// Run every `#compiler` hook on the VM. Each hook is a `fn() -> []const u8`
/// returning K2 source for top-level declarations; the concatenation of all
/// their outputs is returned (or null if there are no hooks). The pipeline then
/// parses that source and adds the declarations to the module — this is how
/// compile-time code GENERATES new top-level declarations (which `#insert`, a
/// statement splice, cannot).
/// What the `#compiler` hook pass produced: generated source to splice in (if
/// any) plus the names of declarations the hooks asked to drop via
/// `compiler_remove(...)`. Both are owned by the caller's allocator.
pub const HookOutput = struct {
    source: ?[]const u8 = null,
    removed: []const []const u8 = &.{},
};

pub fn runCompilerHooks(allocator: std.mem.Allocator, front_end: pipeline.FrontEnd, final_phase: bool) InsertExpandError!HookOutput {
    if (!hasCompilerHook(front_end.module)) return .{};

    var cvm = ComptimeVm.init(allocator, front_end);
    defer cvm.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var produced = false;
    var id: ast.NodeId = compiler_hook_id_base;

    for (front_end.module.items) |item| switch (item) {
        .function => |f| {
            if (!hasAttr(f.attrs, "compiler")) continue;
            // Only run hooks for the phase being processed: bare `#compiler` in
            // the generate phase, `#compiler(final)` in the final phase.
            if (compilerHookIsFinal(f.attrs) != final_phase) continue;
            // Build a synthetic `f()` call and evaluate it to a string.
            const callee = allocator.create(ast.Expr) catch return error.OutOfMemory;
            callee.* = .{ .id = id, .kind = .{ .ident = f.name }, .span = f.span };
            const call_expr = ast.Expr{ .id = id + 1, .kind = .{ .call = .{ .callee = callee, .args = &.{} } }, .span = f.span };
            id += 2;
            cvm.current_file = f.file_name;
            const src = cvm.evalToString(call_expr, allocator) orelse {
                // A `compiler_error("...")` halt prints the hook's diagnostic.
                if (cvm.hook_error) |m| std.debug.print("error: {s}\n", .{m});
                return error.SemanticFailed;
            };
            try out.appendSlice(allocator, src);
            try out.append(allocator, '\n');
            produced = true;
        },
        else => {},
    };

    // Copy any `compiler_remove(...)` names out of the cvm arena (freed on deinit).
    const removed = try allocator.alloc([]const u8, cvm.removals.items.len);
    for (cvm.removals.items, 0..) |nm, i| removed[i] = try allocator.dupe(u8, nm);

    return .{
        .source = if (produced) try out.toOwnedSlice(allocator) else null,
        .removed = removed,
    };
}

/// Run a `build.k2`'s `build :: fn(b: Build)` entry on the comptime VM, with
/// `host` installed so its `std.build` `__build_*` intrinsics record into the
/// driver's BuildPlan. Constructs the `Build` handle (a 1-cell `{ id: i32 } = {0}`)
/// and passes it in. The build system's entry point (the Phase-3 message loop in
/// imperative form).
pub fn runBuildHook(allocator: std.mem.Allocator, front_end: pipeline.FrontEnd, host: vm_engine.BuildHost) InsertExpandError!void {
    var cvm = ComptimeVm.init(allocator, front_end);
    defer cvm.deinit();
    const c = cvm.ensureCache() orelse return error.SemanticFailed;
    var vm = vm_engine.Vm.initModule(cvm.gpa, &c.bc);
    vm.host = host;
    defer vm.deinit();

    // The `Build` argument: a single zone cell holding `id = 0`, addressed as a
    // struct_ref. (`build` ignores it; only artifact handles carry real ids.)
    _ = vm.zone_stack.push("__build") catch return error.OutOfMemory;
    const cell = vm.zone_stack.alloc(1) catch return error.OutOfMemory;
    vm.zone_stack.setCell(cell.ptr.zone, cell.ptr.offset, .{ .int = 0 }) catch return error.SemanticFailed;
    const build_arg = vm_value.Value{ .struct_ref = .{ .zone = cell.ptr.zone, .offset = cell.ptr.offset } };

    _ = vm.call("build", &.{build_arg}) catch return error.SemanticFailed;
}

// ── Comptime test lane ──────────────────────────────────────────────────────────

pub const TestFailure = struct {
    name: []const u8,
    message: []const u8,
};

pub const TestReport = struct {
    passed: u32,
    failed: u32,
    failures: []const TestFailure,
};

fn isTestFn(f: ast.FunctionDecl) bool {
    if (f.is_macro or f.is_constraint or f.body == null) return false;
    for (f.attrs) |a| if (std.mem.eql(u8, a.name, "test")) return true;
    return false;
}

/// True if the module declares any `#test` function. Drives `Test`-prelude
/// injection (pipeline) and lets the driver skip the whole lane for ordinary
/// programs (so a build with no tests pays nothing).
pub fn hasTestDecl(module: ast.Module) bool {
    for (module.items) |item| switch (item) {
        .function => |f| if (isTestFn(f)) return true,
        else => {},
    };
    return false;
}

/// Run every `#test` function on the comptime VM. A test *passes* when its call
/// completes; it *fails* when an assertion calls `core::compiler_error(...)` (the
/// VM traps and stashes the diagnostic) or when the VM otherwise can't run it.
/// Each test gets a fresh VM over the shared bytecode module, so one failure
/// can't corrupt the next. Report strings are duped onto the front end's arena.
pub fn runComptimeTests(allocator: std.mem.Allocator, front_end: pipeline.FrontEnd) InsertExpandError!TestReport {
    const out = front_end.arena.allocator();
    var cvm = ComptimeVm.init(allocator, front_end);
    defer cvm.deinit();
    const c = cvm.ensureCache() orelse return error.SemanticFailed;

    var failures = std.ArrayList(TestFailure).empty;
    var passed: u32 = 0;
    for (front_end.module.items) |item| {
        const f = switch (item) {
            .function => |fd| fd,
            else => continue,
        };
        if (!isTestFn(f)) continue;
        // Only invocable tests for now: a single `*Test` parameter, no generics.
        if (f.type_params.len != 0 or f.params.len != 1) {
            try failures.append(out, .{ .name = out.dupe(u8, f.name) catch f.name, .message = "a #test function must take exactly one parameter `t: *Test`" });
            continue;
        }

        var vm = vm_engine.Vm.initModule(cvm.gpa, &c.bc);
        defer vm.deinit();
        // The `t: *Test` argument: a one-field struct cell the test carries but
        // never meaningfully reads — assertions report through `compiler_error`.
        _ = vm.zone_stack.push("__test") catch return error.OutOfMemory;
        const cell = vm.zone_stack.alloc(1) catch return error.OutOfMemory;
        vm.zone_stack.setCell(cell.ptr.zone, cell.ptr.offset, .{ .int = 0 }) catch return error.SemanticFailed;
        const t_arg = vm_value.Value{ .struct_ref = .{ .zone = cell.ptr.zone, .offset = cell.ptr.offset } };

        if (vm.call(f.name, &.{t_arg})) |_| {
            passed += 1;
        } else |err| {
            const msg = if (vm.compiler_error_msg) |m|
                out.dupe(u8, m) catch "assertion failed"
            else
                out.dupe(u8, @errorName(err)) catch "comptime evaluation error";
            try failures.append(out, .{ .name = out.dupe(u8, f.name) catch f.name, .message = msg });
        }
    }

    return .{ .passed = passed, .failed = @intCast(failures.items.len), .failures = try failures.toOwnedSlice(out) };
}

/// Drop every `#test` function from the module so the runtime backend never sees
/// it: the comptime lane already ran them, and they'd otherwise be dead code
/// referencing the no-op `compiler_error` builtin. Returns the module unchanged
/// when there are no tests.
pub fn pruneTestDecls(allocator: std.mem.Allocator, module: ast.Module) !ast.Module {
    var items = std.ArrayList(ast.Item).empty;
    var dropped = false;
    for (module.items) |item| {
        switch (item) {
            .function => |f| if (isTestFn(f)) {
                dropped = true;
                continue;
            },
            else => {},
        }
        try items.append(allocator, item);
    }
    if (!dropped) return module;
    return ast.Module{ .file_name = module.file_name, .items = try items.toOwnedSlice(allocator) };
}

/// Returns the rewritten module if it contained computed inserts, else null.
pub fn expandComputedInserts(allocator: std.mem.Allocator, front_end: pipeline.FrontEnd) InsertExpandError!?ast.Module {
    var any = false;
    for (front_end.module.items) |item| switch (item) {
        .function => |f| {
            if (f.body) |b| if (blockHasComputedInsert(b)) {
                any = true;
            };
        },
        .interface_impl => |impl| for (impl.methods) |m| {
            if (m.body) |b| if (blockHasComputedInsert(b)) {
                any = true;
            };
        },
        else => {},
    };
    if (!any) return null;

    var cvm = ComptimeVm.init(allocator, front_end);
    defer cvm.deinit();
    var ctx = InsertExpander{ .allocator = allocator, .cvm = &cvm, .next_id = reified_id_base, .file_name = front_end.module.file_name };

    var items = std.ArrayList(ast.Item).empty;
    errdefer items.deinit(allocator);
    for (front_end.module.items) |item| switch (item) {
        .function => |f| {
            var nf = f;
            if (f.body) |b| nf.body = try ctx.rewriteBlock(b);
            try items.append(allocator, .{ .function = nf });
        },
        .interface_impl => |impl| {
            var methods = std.ArrayList(ast.FunctionDecl).empty;
            errdefer methods.deinit(allocator);
            for (impl.methods) |m| {
                var nm = m;
                if (m.body) |b| nm.body = try ctx.rewriteBlock(b);
                try methods.append(allocator, nm);
            }
            var ni = impl;
            ni.methods = try methods.toOwnedSlice(allocator);
            try items.append(allocator, .{ .interface_impl = ni });
        },
        else => try items.append(allocator, item),
    };
    return ast.Module{
        .file_name = front_end.module.file_name,
        .items = try items.toOwnedSlice(allocator),
    };
}

/// True if any function/impl body contains a computed `#insert` (operand is not
/// a literal `#quote`), so the pipeline knows to run the tolerant two-pass path.
pub fn hasComputedInsert(module: ast.Module) bool {
    for (module.items) |item| switch (item) {
        .function => |f| if (f.body) |b| {
            if (blockHasComputedInsert(b)) return true;
        },
        .interface_impl => |impl| for (impl.methods) |m| if (m.body) |b| {
            if (blockHasComputedInsert(b)) return true;
        },
        else => {},
    };
    return false;
}

fn blockHasComputedInsert(block: ast.Block) bool {
    for (block.statements) |s| if (stmtHasComputedInsert(s)) return true;
    return false;
}

fn stmtHasComputedInsert(stmt: ast.Stmt) bool {
    return switch (stmt) {
        .insert_stmt => |ins| ins.operand.kind != .quote,
        .if_stmt => |s| blockHasComputedInsert(s.then_block) or
            (if (s.else_block) |e| blockHasComputedInsert(e) else false),
        .while_stmt => |s| blockHasComputedInsert(s.body),
        .for_range => |s| blockHasComputedInsert(s.body),
        .for_slice => |s| blockHasComputedInsert(s.body),
        .match_stmt => |s| blk: {
            for (s.arms) |a| if (blockHasComputedInsert(a.body)) break :blk true;
            break :blk false;
        },
        .zone_block => |s| blockHasComputedInsert(s.body),
        .defer_stmt => |s| blockHasComputedInsert(s.body),
        .unsafe_block, .comptime_run => |b| blockHasComputedInsert(b),
        .comptime_if => |s| blockHasComputedInsert(s.then_block) or
            (if (s.else_block) |e| blockHasComputedInsert(e) else false),
        else => false,
    };
}

const InsertExpander = struct {
    allocator: std.mem.Allocator,
    cvm: *ComptimeVm,
    next_id: ast.NodeId,
    file_name: []const u8,

    fn rewriteBlock(self: *InsertExpander, block: ast.Block) InsertExpandError!ast.Block {
        var out = std.ArrayList(ast.Stmt).empty;
        errdefer out.deinit(self.allocator);
        for (block.statements) |stmt| try out.append(self.allocator, try self.rewriteStmt(stmt));
        return .{ .statements = try out.toOwnedSlice(self.allocator), .span = block.span };
    }

    fn rewriteStmt(self: *InsertExpander, stmt: ast.Stmt) InsertExpandError!ast.Stmt {
        switch (stmt) {
            .insert_stmt => |ins| {
                if (ins.operand.kind == .quote) return stmt;
                // `#parse(expr)`: evaluate the string and parse it into a block.
                if (ins.operand.kind == .parse_expr) {
                    const str = self.cvm.evalToString(ins.operand.kind.parse_expr.*, self.allocator) orelse {
                        std.debug.print("error: `#parse` operand did not evaluate to a string at compile time\n", .{});
                        return error.SemanticFailed;
                    };
                    const result = parser.parseBlockSource(self.allocator, self.file_name, str, self.next_id) catch {
                        std.debug.print("error: `#parse` could not parse the generated source\n", .{});
                        return error.SemanticFailed;
                    };
                    self.next_id = result.next_id;
                    return .{ .insert_stmt = .{
                        .operand = .{ .id = ins.operand.id, .kind = .{ .quote = result.block }, .span = ins.operand.span },
                        .span = ins.span,
                    } };
                }
                // `#run gen()` (or any other computed operand): evaluate and reify.
                const inner = if (ins.operand.kind == .run_expr) ins.operand.kind.run_expr.* else ins.operand;
                const block = self.cvm.evalToAstBlock(inner, self.allocator, ins.span, &self.next_id) orelse {
                    std.debug.print("error: `#insert` operand did not evaluate to an `AstBlock` at compile time\n", .{});
                    return error.SemanticFailed;
                };
                return .{ .insert_stmt = .{
                    .operand = .{ .id = ins.operand.id, .kind = .{ .quote = block }, .span = ins.operand.span },
                    .span = ins.span,
                } };
            },
            .if_stmt => |s| {
                var n = s;
                n.then_block = try self.rewriteBlock(s.then_block);
                if (s.else_block) |e| n.else_block = try self.rewriteBlock(e);
                return .{ .if_stmt = n };
            },
            .while_stmt => |s| {
                var n = s;
                n.body = try self.rewriteBlock(s.body);
                return .{ .while_stmt = n };
            },
            .for_range => |s| {
                var n = s;
                n.body = try self.rewriteBlock(s.body);
                return .{ .for_range = n };
            },
            .for_slice => |s| {
                var n = s;
                n.body = try self.rewriteBlock(s.body);
                return .{ .for_slice = n };
            },
            .match_stmt => |s| {
                var arms = std.ArrayList(ast.MatchArm).empty;
                errdefer arms.deinit(self.allocator);
                for (s.arms) |arm| {
                    var na = arm;
                    na.body = try self.rewriteBlock(arm.body);
                    try arms.append(self.allocator, na);
                }
                var n = s;
                n.arms = try arms.toOwnedSlice(self.allocator);
                return .{ .match_stmt = n };
            },
            .zone_block => |s| {
                var n = s;
                n.body = try self.rewriteBlock(s.body);
                return .{ .zone_block = n };
            },
            .defer_stmt => |s| {
                var n = s;
                n.body = try self.rewriteBlock(s.body);
                return .{ .defer_stmt = n };
            },
            .unsafe_block => |b| return .{ .unsafe_block = try self.rewriteBlock(b) },
            .comptime_run => |b| return .{ .comptime_run = try self.rewriteBlock(b) },
            .comptime_if => |s| {
                var n = s;
                n.then_block = try self.rewriteBlock(s.then_block);
                if (s.else_block) |e| n.else_block = try self.rewriteBlock(e);
                return .{ .comptime_if = n };
            },
            else => return stmt,
        }
    }
};

// ── VM comptime corpus ──────────────────────────────────────────────────────
// Evaluates every top-level `X :: #run <expr>` in a module with the VM. This
// began life as a differential gate against the old AST tree-walker; now that
// the VM is the sole engine it is a pure regression test — every case in the
// corpus must fold to a constant (`failed` must stay 0).

pub const CorpusStats = struct {
    total: usize = 0,
    evaluated: usize = 0,
    failed: usize = 0,
};

/// Evaluate every top-level `X :: #run <expr>` in the module on the VM.
pub fn evalCorpus(allocator: std.mem.Allocator, front_end: pipeline.FrontEnd) CorpusStats {
    var cvm = ComptimeVm.init(allocator, front_end);
    defer cvm.deinit();

    var stats = CorpusStats{};
    for (front_end.module.items) |item| {
        const decl = switch (item) {
            .const_decl => |d| d,
            else => continue,
        };
        const inner = switch (decl.value.kind) {
            .run_expr => |e| e.*,
            else => continue,
        };
        stats.total += 1;

        if (cvm.evalToImm(inner) != null) {
            stats.evaluated += 1;
        } else {
            stats.failed += 1;
            std.debug.print("[VM-FAIL] {s}\n", .{decl.name});
        }
    }
    return stats;
}

/// Lower a standalone `#run` expression into a one-block IR function that
/// returns it, reusing the normal lowering machinery.
fn lowerExprToFunction(allocator: std.mem.Allocator, front_end: pipeline.FrontEnd, expr: ast.Expr, file: []const u8) !IrFunction {
    const dummy = ast.FunctionDecl{
        .attrs = &.{},
        .name = "__run",
        .file_name = file,
        .source = "",
        .type_params = &.{},
        .params = &.{},
        .return_ty = .opaque_type,
        .error_ty = null,
        .body = null,
        .span = expr.span,
    };
    var lowerer = FunctionLowerer.init(allocator, front_end.types, front_end.symbols, dummy);
    lowerer.module = front_end.module;
    lowerer.current_return_ty = lowerer.exprType(expr);
    var stmts = [_]ast.Stmt{.{ .return_stmt = .{ .value = expr, .span = expr.span } }};
    const blocks = try lowerer.lowerBody(.{ .statements = &stmts, .span = expr.span });
    return .{
        .name = "__run",
        .params = &.{},
        .return_ty = lowerer.current_return_ty,
        .error_ty = null,
        .blocks = blocks,
        .extern_name = null,
        .inline_hint = false,
        .no_inline = false,
        .no_return = false,
        .entry = false,
        .naked = false,
        .export_sym = null,
    };
}

/// Lower a `where { … }` predicate to a comptime function returning `[]const u8`:
/// the rejection message, or "" to accept. `reject(msg)` lowers to `return msg`;
/// falling off the end returns "". `type_args` binds the generic params so
/// `type_info(T)` folds for this instantiation.
fn nameInList(name: []const u8, list: []const []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn whereDummyDecl(file: []const u8, span: Span) ast.FunctionDecl {
    return .{
        .attrs = &.{},
        .name = "__where",
        .file_name = file,
        .source = "",
        .type_params = &.{},
        .params = &.{},
        .return_ty = .opaque_type,
        .error_ty = null,
        .body = null,
        .span = span,
    };
}

fn lowerWhereToFunction(allocator: std.mem.Allocator, front_end: pipeline.FrontEnd, where_block: ast.Block, type_args: []const sema.TypeArg, output_params: []const []const u8, file: []const u8) !IrFunction {
    var lowerer = FunctionLowerer.init(allocator, front_end.types, front_end.symbols, whereDummyDecl(file, where_block.span));
    lowerer.module = front_end.module;
    lowerer.type_binding = type_args;
    lowerer.in_where = true;
    lowerer.where_output_params = output_params;
    lowerer.current_return_ty = .text;
    // Fall-through (no `reject` hit) accepts: `return ""`.
    try lowerer.lowerBlock(where_block.statements, .{ .return_value = .{ .imm = .{ .text = "" } } });
    const blocks = try lowerer.blocks.toOwnedSlice(allocator);
    return .{
        .name = "__where",
        .params = &.{},
        .return_ty = .text,
        .error_ty = null,
        .blocks = blocks,
        .extern_name = null,
        .inline_hint = false,
        .no_inline = false,
        .no_return = false,
        .entry = false,
        .naked = false,
        .export_sym = null,
    };
}

/// Lower a `where` block to *compute an output type param*: an `Acc = <type>`
/// assignment returns the node id of `<type>` (sema maps it back to a concrete
/// type for this instantiation). Falling off the end returns 0 ("not assigned").
fn lowerWhereTypeToFunction(allocator: std.mem.Allocator, front_end: pipeline.FrontEnd, where_block: ast.Block, type_args: []const sema.TypeArg, output_params: []const []const u8, file: []const u8) !IrFunction {
    var lowerer = FunctionLowerer.init(allocator, front_end.types, front_end.symbols, whereDummyDecl(file, where_block.span));
    lowerer.module = front_end.module;
    lowerer.type_binding = type_args;
    lowerer.in_where = true;
    lowerer.in_where_type = true;
    lowerer.where_output_params = output_params;
    lowerer.current_return_ty = .{ .u = 64 };
    try lowerer.lowerBlock(where_block.statements, .{ .return_value = .{ .imm = .{ .uint = 0 } } });
    const blocks = try lowerer.blocks.toOwnedSlice(allocator);
    return .{
        .name = "__where_type",
        .params = &.{},
        .return_ty = .{ .u = 64 },
        .error_ty = null,
        .blocks = blocks,
        .extern_name = null,
        .inline_hint = false,
        .no_inline = false,
        .no_return = false,
        .entry = false,
        .naked = false,
        .export_sym = null,
    };
}

/// Does `expr` contain a `#run` anywhere? A top-level const whose initializer
/// merely embeds a `#run` (e.g. `10 + #run f()`) must be folded by the comptime
/// VM as a whole — not treated as a plain literal expression, which would drop
/// the `#run` and fold to garbage.
fn exprHasRun(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .run_expr => true,
        .binary => |b| exprHasRun(b.left.*) or exprHasRun(b.right.*),
        .unary => |u| exprHasRun(u.expr.*),
        .as_cast => |c| exprHasRun(c.value.*),
        .force_unwrap, .unsafe_expr => |inner| exprHasRun(inner.*),
        .nil_coalesce => |nc| exprHasRun(nc.value.*) or exprHasRun(nc.default.*),
        .field => |f| exprHasRun(f.base.*),
        .index => |i| exprHasRun(i.base.*) or exprHasRun(i.index.*),
        .call => |c| blk: {
            if (exprHasRun(c.callee.*)) break :blk true;
            for (c.args) |a| switch (a) {
                .positional => |x| if (exprHasRun(x)) break :blk true,
                .named => |n| if (exprHasRun(n.value)) break :blk true,
            };
            break :blk false;
        },
        else => false,
    };
}

fn effectiveConstImm(expr: ast.Expr, cvm: ?*ComptimeVm, file: []const u8, source: []const u8) LowerError!Imm {
    // A plain literal expression takes the fast path. Anything containing a
    // `#run` — whether the whole RHS (`X :: #run f()`) or nested inside a bigger
    // expression (`X :: 10 + #run f()`) — must fold on the comptime VM, since
    // there is no runtime to compute a top-level const later.
    if (expr.kind != .run_expr and !exprHasRun(expr)) return lowerImm(expr);
    const inner = switch (expr.kind) {
        .run_expr => |e| e.*,
        else => expr,
    };

    // If the VM can't fold it, fail loudly rather than silently substituting a
    // best-effort (usually wrong) literal.
    const c = cvm orelse return lowerImm(inner);
    c.hook_error = null;
    const v = c.evalRaw(inner) orelse {
        // A comptime `@panic("…")` recorded its message — show it verbatim.
        if (c.hook_error) |msg| {
            diag_mod.printErrorAt(msg, file, source, expr.span);
            return error.LoweringFailed;
        }
        diag_mod.printErrorAt(
            "`#run` expression could not be evaluated at compile time " ++
                "(the comptime VM cannot execute it — e.g. an unsupported construct or a call into runtime-only code)",
            file,
            source,
            expr.span,
        );
        return error.LoweringFailed;
    };
    return v.toImm() orelse {
        diag_mod.printErrorAt(
            "a `#run` constant must evaluate to a scalar value; " ++
                "aggregate (struct/slice/enum) results are not yet supported as top-level constants",
            file,
            source,
            expr.span,
        );
        return error.LoweringFailed;
    };
}

/// Map an AST binary operator to its `AstBinOp` variant name, and back. These
/// two tables MUST stay in sync (materialize ↔ reify).
fn astBinOpName(op: ast.BinaryOp) ?[]const u8 {
    return switch (op) {
        .add => "add",
        .sub => "sub",
        .mul => "mul",
        .div => "div",
        .rem => "rem",
        .equal => "eq",
        .not_equal => "ne",
        .less => "lt",
        .le => "le",
        .gt => "gt",
        .ge => "ge",
        .and_and => "logic_and",
        .or_or => "logic_or",
        .bit_and => "bit_and",
        .bit_or => "bit_or",
        .bit_xor => "bit_xor",
        .shl => "shl",
        .shr => "shr",
        .wrap_add => "wrap_add",
        .wrap_sub => "wrap_sub",
        .wrap_mul => "wrap_mul",
    };
}

fn astBinOpFromName(name: []const u8) ?ast.BinaryOp {
    const map = .{
        .{ "add", ast.BinaryOp.add },           .{ "sub", ast.BinaryOp.sub },
        .{ "mul", ast.BinaryOp.mul },           .{ "div", ast.BinaryOp.div },
        .{ "rem", ast.BinaryOp.rem },           .{ "eq", ast.BinaryOp.equal },
        .{ "ne", ast.BinaryOp.not_equal },      .{ "lt", ast.BinaryOp.less },
        .{ "le", ast.BinaryOp.le },             .{ "gt", ast.BinaryOp.gt },
        .{ "ge", ast.BinaryOp.ge },             .{ "logic_and", ast.BinaryOp.and_and },
        .{ "logic_or", ast.BinaryOp.or_or },    .{ "bit_and", ast.BinaryOp.bit_and },
        .{ "bit_or", ast.BinaryOp.bit_or },     .{ "bit_xor", ast.BinaryOp.bit_xor },
        .{ "shl", ast.BinaryOp.shl },           .{ "shr", ast.BinaryOp.shr },
        .{ "wrap_add", ast.BinaryOp.wrap_add }, .{ "wrap_sub", ast.BinaryOp.wrap_sub },
        .{ "wrap_mul", ast.BinaryOp.wrap_mul },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

fn astUnOpName(op: ast.UnaryOp) ?[]const u8 {
    return switch (op) {
        .neg => "neg",
        .not => "logic_not",
        .bit_not => "bit_not",
        .deref => "deref",
        .address_of => "addr",
    };
}

fn astUnOpFromName(name: []const u8) ?ast.UnaryOp {
    const map = .{
        .{ "neg", ast.UnaryOp.neg },         .{ "logic_not", ast.UnaryOp.not },
        .{ "bit_not", ast.UnaryOp.bit_not }, .{ "deref", ast.UnaryOp.deref },
        .{ "addr", ast.UnaryOp.address_of },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

/// A compound assignment operator (`+=`, `*=`, …) → its `AstBinOp` name, so it
/// can be desugared to `x = x <op> y`. Plain `=` returns null.
fn assignOpToBinOpName(op: ast.AssignOp) ?[]const u8 {
    return switch (op) {
        .assign => null,
        .add => "add",
        .sub => "sub",
        .mul => "mul",
        .div => "div",
        .rem => "rem",
        .bit_and => "bit_and",
        .bit_or => "bit_or",
        .bit_xor => "bit_xor",
        .shl => "shl",
        .shr => "shr",
    };
}

// ── Comptime-only function detection ─────────────────────────────────────────
// A function whose signature mentions the ast.* prelude types, or whose body
// builds quote values, is a metaprogramming helper: it runs only on the VM and
// is excluded from the final (runtime) module.

const ast_prelude_type_names = [_][]const u8{
    "AstBlock", "AstStmt",     "AstExpr",      "AstBinary",     "AstBinOp",    "AstUnary",
    "AstUnOp",  "AstCall",     "AstField",     "AstIndex",      "AstLocal",    "AstAssign",
    "AstIf",    "AstWhile",    "AstDeferMode", "AstArrayTy",    "AstType",     "AstSliceE",
    "AstCastE", "AstCoalesce", "AstCatchE",    "AstLocalTyped", "AstForRange", "AstForSlice",
    "AstZone",  "AstDefer",    "AstFail",      "AstPattern",    "AstMatchArm", "AstMatch",
    "AstArg",
};

fn isAstPreludeTypeName(name: []const u8) bool {
    for (ast_prelude_type_names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn typeRefUsesAstTypes(ty: ast.TypeRef) bool {
    return switch (ty) {
        .named, .type_param => |n| isAstPreludeTypeName(n.name),
        .pointer, .many_pointer => |p| typeRefUsesAstTypes(p.inner.*),
        .optional => |o| typeRefUsesAstTypes(o.inner.*),
        .slice => |s| typeRefUsesAstTypes(s.inner.*),
        .array => |a| typeRefUsesAstTypes(a.inner.*),
        .atomic => |a| typeRefUsesAstTypes(a.inner.*),
        .borrow => |b| typeRefUsesAstTypes(b.inner.*),
        .fn_type => |f| blk: {
            for (f.params) |pt| if (typeRefUsesAstTypes(pt)) break :blk true;
            break :blk typeRefUsesAstTypes(f.ret.*);
        },
        .generic_inst => |g| blk: {
            for (g.args) |at| if (typeRefUsesAstTypes(at)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn fnIsComptimeOnly(decl: ast.FunctionDecl) bool {
    if (typeRefUsesAstTypes(decl.return_ty)) return true;
    for (decl.params) |p| if (typeRefUsesAstTypes(p.ty)) return true;
    if (decl.body) |b| if (blockHasQuoteValue(b)) return true;
    return false;
}

fn blockHasQuoteValue(block: ast.Block) bool {
    for (block.statements) |s| if (stmtHasQuoteValue(s)) return true;
    return false;
}

fn stmtHasQuoteValue(stmt: ast.Stmt) bool {
    return switch (stmt) {
        // An `#insert` operand is spliced, never a runtime value.
        .insert_stmt => false,
        .local_infer => |l| exprHasQuote(l.value),
        .local_typed => |l| exprHasQuote(l.value),
        .assign => |a| exprHasQuote(a.target) or exprHasQuote(a.value),
        .return_stmt => |r| if (r.value) |v| exprHasQuote(v) else false,
        .fail_stmt => |f| blk: {
            for (f.payload) |p| if (exprHasQuote(p)) break :blk true;
            break :blk false;
        },
        .if_stmt => |s| exprHasQuote(s.condition) or blockHasQuoteValue(s.then_block) or
            (if (s.else_block) |e| blockHasQuoteValue(e) else false),
        .while_stmt => |s| exprHasQuote(s.condition) or blockHasQuoteValue(s.body),
        .for_range => |s| exprHasQuote(s.start) or exprHasQuote(s.end) or blockHasQuoteValue(s.body),
        .for_slice => |s| exprHasQuote(s.iter) or blockHasQuoteValue(s.body),
        .match_stmt => |s| blk: {
            if (exprHasQuote(s.subject)) break :blk true;
            for (s.arms) |a| if (blockHasQuoteValue(a.body)) break :blk true;
            break :blk false;
        },
        .zone_block => |s| blockHasQuoteValue(s.body),
        .defer_stmt => |s| blockHasQuoteValue(s.body),
        .unsafe_block, .comptime_run => |b| blockHasQuoteValue(b),
        .comptime_if => |s| blockHasQuoteValue(s.then_block) or
            (if (s.else_block) |e| blockHasQuoteValue(e) else false),
        .comptime_for => |s| blockHasQuoteValue(s.body),
        .expr => |e| exprHasQuote(e),
        else => false,
    };
}

fn exprHasQuote(e: ast.Expr) bool {
    return switch (e.kind) {
        .quote, .quote_expr => true,
        .binary => |b| exprHasQuote(b.left.*) or exprHasQuote(b.right.*),
        .unary => |u| exprHasQuote(u.expr.*),
        .call => |c| blk: {
            // NOTE: `type_info(T)` is NOT comptime-only — `materializeTypeInfo`
            // lowers it to a real runtime `TypeInfo` value (the same machinery as
            // `ast.*`), so `match type_info(T)` works at runtime (and folds when the
            // type is constant). Only true `ast.*` builders (#quote) are comptime-only.
            if (exprHasQuote(c.callee.*)) break :blk true;
            for (c.args) |a| switch (a) {
                .positional => |x| if (exprHasQuote(x)) break :blk true,
                .named => |n| if (exprHasQuote(n.value)) break :blk true,
            };
            break :blk false;
        },
        .field => |f| exprHasQuote(f.base.*),
        .index => |i| exprHasQuote(i.base.*) or exprHasQuote(i.index.*),
        .slice => |s| exprHasQuote(s.base.*) or
            (if (s.start) |x| exprHasQuote(x.*) else false) or
            (if (s.end) |x| exprHasQuote(x.*) else false),
        .force_unwrap, .unsafe_expr, .run_expr, .splice => |inner| exprHasQuote(inner.*),
        .as_cast => |c| exprHasQuote(c.value.*),
        .nil_coalesce => |nc| exprHasQuote(nc.value.*) or exprHasQuote(nc.default.*),
        .try_expr => |t| exprHasQuote(t.value.*),
        .catch_expr => |c| exprHasQuote(c.value.*) or blockHasQuoteValue(c.handler),
        .compound_literal => |vals| blk: {
            for (vals) |v| if (exprHasQuote(v)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// `[]const u8` — the type of a `NAME :: "..."` string constant. A string is a
/// fat-pointer slice, so the global must be typed as one (not the bare `.text`
/// placeholder, which lowers to a plain `ptr` and both mismatches its slice
/// initializer and hides the slice from `.len`/index lowering).
const string_elem_ty: IrType = .byte;
const string_slice_ty: IrType = .{ .slice = &string_elem_ty };

fn inferConstType(expr: ast.Expr) IrType {
    return switch (expr.kind) {
        .int => |text| intLiteralIrType(text),
        .float => |text| if (std.mem.endsWith(u8, text, "f32")) .f32 else .f64,
        .unary => |u| if (u.op == .neg) inferConstType(u.expr.*) else .unknown,
        .bool => .bool,
        .string => string_slice_ty,
        .null => .unknown,
        else => .unknown,
    };
}

/// Map an integer literal's type suffix to its IrType so a `const` global is
/// sized to match its declared width — e.g. `X :: 32usize` must be an i64
/// global, not i32. Without this, a load wider than the global reads adjacent
/// memory into the high bits (corrupting addresses through `ptr_from_int` /
/// `slice_from_raw_parts`). An unsuffixed literal keeps the i32 default.
fn intLiteralIrType(text: []const u8) IrType {
    if (std.mem.endsWith(u8, text, "usize")) return .usize;
    if (std.mem.endsWith(u8, text, "isize")) return .isize;
    if (std.mem.endsWith(u8, text, "u64")) return .{ .u = 64 };
    if (std.mem.endsWith(u8, text, "u32")) return .{ .u = 32 };
    if (std.mem.endsWith(u8, text, "u16")) return .{ .u = 16 };
    if (std.mem.endsWith(u8, text, "u8")) return .{ .u = 8 };
    if (std.mem.endsWith(u8, text, "i64")) return .{ .i = 64 };
    if (std.mem.endsWith(u8, text, "i32")) return .{ .i = 32 };
    if (std.mem.endsWith(u8, text, "i16")) return .{ .i = 16 };
    if (std.mem.endsWith(u8, text, "i8")) return .{ .i = 8 };
    if (std.mem.endsWith(u8, text, "byte")) return .byte;
    return .{ .i = 32 };
}

fn lowerImm(expr: ast.Expr) Imm {
    return switch (expr.kind) {
        .int => |text| .{ .int = parseIntLiteral(text) },
        .float => |text| .{ .float = parseFloatLiteral(text) },
        .unary => |u| switch (u.op) {
            .neg => switch (u.expr.kind) {
                .int => |text| .{ .int = -parseIntLiteral(text) },
                else => .null,
            },
            else => .null,
        },
        .bool => |value| .{ .bool = value },
        .string => |text| .{ .text = trimQuotes(text) },
        .null => .null,
        else => .null,
    };
}

fn parseArrayLen(expr: ast.Expr) u64 {
    return switch (expr.kind) {
        .int => |text| @intCast(@max(parseIntLiteral(text), 0)),
        else => 0,
    };
}

fn parseIntLiteral(text: []const u8) i128 {
    var value: i128 = 0;
    var negative = false;
    var start: usize = 0;
    if (text.len > 0 and text[0] == '-') {
        negative = true;
        start = 1;
    }

    const radix: i128 = if (text.len >= start + 2 and text[start] == '0' and (text[start + 1] == 'x' or text[start + 1] == 'X')) blk: {
        start += 2;
        break :blk 16;
    } else if (text.len >= start + 2 and text[start] == '0' and (text[start + 1] == 'b' or text[start + 1] == 'B')) blk: {
        start += 2;
        break :blk 2;
    } else 10;

    for (text[start..]) |ch| {
        if (ch == '_') continue;
        const digit: i128 = if (ch >= '0' and ch <= '9')
            ch - '0'
        else if (ch >= 'a' and ch <= 'f')
            10 + ch - 'a'
        else if (ch >= 'A' and ch <= 'F')
            10 + ch - 'A'
        else
            break;
        if (digit >= radix) break;
        value = value * radix + digit;
    }

    return if (negative) -value else value;
}

fn parseFloatLiteral(text: []const u8) f64 {
    // Strip the `f32`/`f64` type suffix. (Stripping trailing *alphabetic* chars
    // is wrong: the suffix ends in digits — `3.9f64` would keep `3.9f64` and fail
    // to parse → 0.0. Match the whole suffix instead.)
    var num = text;
    if (std.mem.endsWith(u8, num, "f32") or std.mem.endsWith(u8, num, "f64"))
        num = num[0 .. num.len - 3];
    if (num.len == 0) return 0.0;
    return std.fmt.parseFloat(f64, num) catch 0.0;
}

fn hasAttr(attrs: []const ast.Attribute, name: []const u8) bool {
    for (attrs) |attr| {
        if (std.mem.eql(u8, attr.name, name)) return true;
    }
    return false;
}

fn alignAttr(attrs: []const ast.Attribute) u32 {
    for (attrs) |attr| {
        if (!std.mem.eql(u8, attr.name, "align")) continue;
        if (attr.args.len == 0) continue;
        return switch (attr.args[0].kind) {
            .int => |text| @intCast(@max(parseIntLiteral(text), 0)),
            else => 0,
        };
    }
    return 0;
}

fn externName(attrs: []const ast.Attribute) ?[]const u8 {
    for (attrs) |attr| {
        if ((!std.mem.eql(u8, attr.name, "extern") and !std.mem.eql(u8, attr.name, "foreign")) or attr.args.len < 2) continue;
        return switch (attr.args[1].kind) {
            .string => |value| trimQuotes(value),
            else => null,
        };
    }
    return null;
}

/// The library name from `#extern("lib", "symbol")` (or its `#foreign` alias)
/// — the first argument. This tells the linker which import library to pull
/// the symbol from (e.g. `#extern("raylib", "InitWindow")` / `#foreign("raylib",
/// "InitWindow")` requires linking `raylib.lib`).
fn externLibName(attrs: []const ast.Attribute) ?[]const u8 {
    for (attrs) |attr| {
        if ((!std.mem.eql(u8, attr.name, "extern") and !std.mem.eql(u8, attr.name, "foreign")) or attr.args.len < 2) continue;
        return switch (attr.args[0].kind) {
            .string => |value| trimQuotes(value),
            else => null,
        };
    }
    return null;
}

/// Adds `lib` to `extern_libs` if not already present, skipping `kernel32`
/// (always linked by the Windows backend regardless). Used to collect import
/// library dependencies from both `#extern`/`#foreign` decls and standalone
/// `#system_library("name");` declarations.
fn addExternLib(allocator: std.mem.Allocator, extern_libs: *std.ArrayList([]const u8), lib: []const u8) !void {
    if (std.mem.eql(u8, lib, "kernel32")) return;
    for (extern_libs.items) |existing| {
        if (std.mem.eql(u8, existing, lib)) return;
    }
    try extern_libs.append(allocator, lib);
}

fn trimQuotes(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
        return text[1 .. text.len - 1];
    }
    return text;
}
