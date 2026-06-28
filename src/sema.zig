const std = @import("std");
const ast = @import("ast.zig");
const freevars = @import("freevars.zig");
const NodeId = ast.NodeId;
const diag_mod = @import("diagnostic.zig");
const Diagnostic = diag_mod.Diagnostic;
const DiagKind = diag_mod.DiagKind;
const Span = @import("lexer/span.zig").Span;

pub const ScopeId = usize;
pub const SymbolId = usize;

pub const SemanticError = error{
    SemanticFailed,
    OutOfMemory,
};

pub const SymbolTable = struct {
    scopes: std.ArrayList(Scope) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    visible_names: std.StringHashMap(std.StringHashMap(SymbolId)) = undefined,
    /// Per-file namespace aliases: file → (alias → target module file). Populated
    /// for `#import a.b;` / `#import a.b as c;`. Drives `alias::member` resolution.
    namespaces: std.StringHashMap(std.StringHashMap([]const u8)) = undefined,
    root_scope: ScopeId = 0,

    pub fn init(allocator: std.mem.Allocator) !SymbolTable {
        var table: SymbolTable = .{
            .visible_names = std.StringHashMap(std.StringHashMap(SymbolId)).init(allocator),
            .namespaces = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
        };
        errdefer table.deinit(allocator);

        try table.scopes.append(allocator, Scope.init(allocator, 0, null));
        return table;
    }

    pub fn deinit(self: *SymbolTable, allocator: std.mem.Allocator) void {
        for (self.scopes.items) |*scope_item| {
            scope_item.deinit(allocator);
        }
        self.scopes.deinit(allocator);
        self.symbols.deinit(allocator);
        var visible_it = self.visible_names.valueIterator();
        while (visible_it.next()) |names| names.deinit();
        self.visible_names.deinit();
        var ns_it = self.namespaces.valueIterator();
        while (ns_it.next()) |aliases| aliases.deinit();
        self.namespaces.deinit();
    }

    pub fn addScope(self: *SymbolTable, allocator: std.mem.Allocator, parent: ?ScopeId) !ScopeId {
        const id = self.scopes.items.len;
        try self.scopes.append(allocator, Scope.init(allocator, id, parent));
        return id;
    }

    pub fn symbol(self: SymbolTable, id: SymbolId) Symbol {
        return self.symbols.items[id];
    }

    pub fn scope(self: SymbolTable, id: ScopeId) Scope {
        return self.scopes.items[id];
    }

    pub fn resolve(self: SymbolTable, start_scope: ScopeId, name: []const u8) ?SymbolId {
        var scope_id = start_scope;

        while (true) {
            const current = self.scopes.items[scope_id];
            if (current.names.get(name)) |id| {
                return id;
            }

            if (current.parent) |parent| {
                scope_id = parent;
            } else {
                return null;
            }
        }
    }

    pub fn resolveVisible(self: SymbolTable, file_name: []const u8, name: []const u8) ?SymbolId {
        // Compiler-generated `<runtime>` code (the heap/reflection preludes, the
        // generated `__fld_<S>` field navigators) sees every top-level symbol: it's
        // trusted and is generated *for* the user's types, which live in other files.
        const from_runtime = std.mem.eql(u8, file_name, "<runtime>");
        if (self.resolve(self.root_scope, name)) |id| {
            // Found by its bare name in the root scope (i.e. not collision-mangled).
            const symbol_value = self.symbol(id);
            if (from_runtime or std.mem.eql(u8, symbol_value.file_name, "<runtime>")) return id;
            const visible = self.visible_names.get(file_name) orelse return null;
            return visible.get(name);
        }
        // Not in the root scope under its bare name → a collision-mangled symbol;
        // resolve it through this file's visibility map (own decls + imports).
        const visible = self.visible_names.get(file_name) orelse return null;
        return visible.get(name);
    }

    /// Resolve `alias::member` from `file_name`: look up the namespace alias to
    /// find its target module file, then a public `member` declared there.
    pub fn resolveScoped(self: SymbolTable, file_name: []const u8, alias: []const u8, member: []const u8) ?SymbolId {
        const aliases = self.namespaces.get(file_name) orelse return null;
        const target_file = aliases.get(alias) orelse return null;
        for (self.symbols.items) |sym| {
            if (sym.is_public and std.mem.eql(u8, sym.file_name, target_file) and std.mem.eql(u8, sym.name, member))
                return sym.id;
        }
        return null;
    }

    pub fn insert(
        self: *SymbolTable,
        allocator: std.mem.Allocator,
        scope_id: ScopeId,
        name: []const u8,
        kind: SymbolKind,
        span: Span,
        file_name: []const u8,
        is_public: bool,
    ) !SymbolId {
        return self.insertLinked(allocator, scope_id, name, name, kind, span, file_name, is_public);
    }

    /// Like `insert`, but the scope is keyed by `link_name` (the globally-unique
    /// linkage name) while the symbol keeps its bare `name`. Top-level symbols use
    /// this so collision-mangled names stay distinct in the root scope.
    pub fn insertLinked(
        self: *SymbolTable,
        allocator: std.mem.Allocator,
        scope_id: ScopeId,
        name: []const u8,
        link_name: []const u8,
        kind: SymbolKind,
        span: Span,
        file_name: []const u8,
        is_public: bool,
    ) !SymbolId {
        if (self.scopes.items[scope_id].names.get(link_name)) |existing| {
            return existing;
        }

        const id = self.symbols.items.len;
        try self.symbols.append(allocator, .{
            .id = id,
            .name = name,
            .link_name = link_name,
            .kind = kind,
            .span = span,
            .scope_id = scope_id,
            .owner = null,
            .file_name = file_name,
            .is_public = is_public,
        });
        try self.scopes.items[scope_id].names.put(link_name, id);
        try self.scopes.items[scope_id].symbols.append(allocator, id);
        return id;
    }
};

pub const Scope = struct {
    id: ScopeId,
    parent: ?ScopeId,
    symbols: std.ArrayList(SymbolId) = .empty,
    names: std.StringHashMap(SymbolId) = undefined,

    pub fn init(allocator: std.mem.Allocator, id: ScopeId, parent: ?ScopeId) Scope {
        return .{
            .id = id,
            .parent = parent,
            .names = std.StringHashMap(SymbolId).init(allocator),
        };
    }

    pub fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        self.symbols.deinit(allocator);
        self.names.deinit();
    }
};

pub const Symbol = struct {
    id: SymbolId,
    name: []const u8,
    /// Globally-unique linkage name used by IR/LLVM/VM. Equals `name` for the
    /// common case; module-qualified (`<module>$name`) only when the same bare
    /// name is declared as a normal decl in more than one module (collision).
    link_name: []const u8,
    kind: SymbolKind,
    span: Span,
    scope_id: ScopeId,
    owner: ?SymbolId,
    file_name: []const u8,
    is_public: bool,
};

pub const SymbolKind = enum {
    import,
    type,
    field,
    variant,
    function,
    const_symbol,
    param,
    zone_param,
    local_val,
    local_var,
    local_const,
    zone,
    for_binding,
    case_binding,
    try_error,
    global_var,

    pub fn label(self: SymbolKind) []const u8 {
        return switch (self) {
            .import => "import",
            .type => "type",
            .field => "field",
            .variant => "variant",
            .function => "function",
            .const_symbol => "constant",
            .param => "parameter",
            .zone_param => "zone parameter",
            .local_val => "value",
            .local_var => "variable",
            .local_const => "local constant",
            .zone => "zone",
            .for_binding => "loop binding",
            .case_binding => "case binding",
            .try_error => "error binding",
            .global_var => "global variable",
        };
    }
};

pub const Ty = union(enum) {
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
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
    system,
    file_sys,
    net,
    clock,
    gpu,
    writer,
    reader,
    conn,
    text_buf,
    args,
    thread_pool,
    zone,
    pointer: *const Ty, // *T  — mutable pointer
    const_ptr: *const Ty, // *const T — read-only pointer
    optional: *const Ty,
    slice: *const Ty,
    borrow: *const Ty,
    array: ArrayTy,
    range: *const Ty,
    named: SymbolId,
    /// A generic struct applied to type arguments that are not yet fully
    /// concrete, e.g. `List(T)` inside a generic function signature. Once every
    /// argument is bound to a concrete type, `substituteTy` collapses this to a
    /// concrete `.named` instance.
    generic_app: GenericApp,
    list: *const Ty,
    map: *const Ty,
    null_ptr,
    zone_handle,
    type_param: []const u8,
    error_set: []const ErrorVariantInfo,
    fallible: FallibleTy,
    fn_ptr: FnPtrTy,
    int_lit,
    float_lit,
    unknown,
    error_ty,

    pub fn isInteger(self: Ty) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .byte, .usize, .isize, .addr, .int_lit, .type_param => true,
            else => false,
        };
    }

    pub fn isFloat(self: Ty) bool {
        return switch (self) {
            .f32, .f64, .float_lit => true,
            else => false,
        };
    }

    pub fn isNumeric(self: Ty) bool {
        return self.isInteger() or self.isFloat();
    }

    pub fn isBool(self: Ty) bool {
        return self == .bool;
    }
};

/// `Template(args...)` where at least one arg is still a type variable.
pub const GenericApp = struct {
    /// Symbol id of the generic struct template (e.g. `List`).
    template: SymbolId,
    /// Resolved argument types, in template type-param order. May contain
    /// `.type_param` entries until fully substituted.
    args: []const Ty,
};

const ZoneOwner = struct {
    name: []const u8,
    scope_depth: usize,
    kind: enum { zone, borrow } = .zone,
};

const ActiveZone = struct {
    name: []const u8,
    scope_depth: usize,
};

pub const ArrayTy = struct {
    elem: *const Ty,
    len: u64,
};

pub const FallibleTy = struct {
    ok: *const Ty,
    err: *const Ty,
};

pub const FnPtrTy = struct {
    params: []const Ty,
    ret: *const Ty,
    /// `extern fn(...)` — a thin C-ABI function pointer (a bare address), directly
    /// callable, as opposed to skarn's fat `{fn, env}` closure. See ast.FnType.
    thin: bool = false,
};

pub const TypeLayout = struct {
    kind: TypeKind,
    is_packed: bool,
};

pub const TypeKind = union(enum) {
    struct_type: []const FieldInfo,
    variant_type: []const VariantInfo,
    error_set: []const ErrorVariantInfo,
    interface_type: []const InterfaceMethodInfo,
};

pub const InterfaceMethodInfo = struct {
    name: []const u8,
    params: []const ParamSig,
    return_ty: Ty,
    error_ty: ?Ty,
};

pub const FieldInfo = struct {
    name: []const u8,
    ty: Ty,
    /// `name: T = expr` default, carried from the field decl so a literal that
    /// omits this field (named `.{…}`, short positional, or `.{}`) can fill it.
    default: ?ast.Expr = null,
};

pub const VariantInfo = struct {
    name: []const u8,
    payload: ?Ty,
    index: u32, // discriminant value
};

pub const ErrorVariantInfo = struct {
    name: []const u8,
    payload: ?Ty,
};

pub const VariantValueInfo = struct {
    parent_ty: SymbolId,
    payload: ?Ty,
};

/// A bare enum-literal argument (`.variant`) resolved against an expected enum
/// type, recorded by NodeId so IR can lower it as the right `variant_lit`.
pub const EnumLit = struct {
    type_name: []const u8,
    variant: []const u8,
};

pub const FnSig = struct {
    params: []const ParamSig,
    return_ty: Ty,
    error_ty: ?Ty,
    extern_name: ?[]const u8,
    inline_hint: bool,
    no_inline: bool,
    no_return: bool,
    entry: bool,
    naked: bool,
    export_sym: ?[]const u8, // #export / #export("name")
    deprecated: ?[]const u8, // #deprecated / #deprecated("msg")
    type_params: []const []const u8,
    type_constraints: []const ast.TypeConstraint = &.{},
    type_binding: ?[]const u8,
    /// `where { … }` clause + output type params (`-> $Acc`) — needed to compute
    /// output types at the call site during generic resolution.
    where_clause: ?ast.Block = null,
    output_type_params: []const []const u8 = &.{},
    /// A `constraint`/`macro` template, not a callable runtime value — IR must
    /// not wrap a reference to it as a closure.
    is_template: bool = false,
};

pub const ParamSig = struct {
    name: []const u8,
    ty: Ty,
    is_type_param: bool = false,
};

/// A variable a lambda captures from its enclosing scope (by value).
pub const Capture = struct {
    name: []const u8,
    ty: Ty,
};

/// An `x.method()` call that resolved to an interface method the receiver's
/// concrete type implements. IR turns it into a direct call to the
/// `{type}.{interface}.{method}` function.
pub const ImplMethodCall = struct {
    type_name: []const u8,
    interface_name: []const u8,
    method_name: []const u8,
};

pub const TypeEnv = struct {
    symbol_types: std.AutoHashMap(SymbolId, Ty),
    layouts: std.AutoHashMap(SymbolId, TypeLayout),
    fn_sigs: std.AutoHashMap(SymbolId, FnSig),
    variant_values: std.AutoHashMap(SymbolId, VariantValueInfo),
    // Keeps a list of distinct types and their underlying type for later referencing, e.g. when casting
    distinct_types: std.AutoHashMap(SymbolId, Ty),
    /// Transparent type aliases: alias SymbolId → the aliased TypeRef. Resolved
    /// on demand in `typeFromRef` so the alias name is fully interchangeable.
    alias_refs: std.AutoHashMap(SymbolId, ast.TypeRef),
    expr_types: std.AutoHashMap(ast.NodeId, Ty),
    expr_symbols: std.AutoHashMap(ast.NodeId, SymbolId),
    expr_scopes: std.AutoHashMap(ast.NodeId, ScopeId),
    /// Field-callee NodeId -> visible top-level function used as an extension method.
    extension_calls: std.AutoHashMap(ast.NodeId, SymbolId),
    /// Field-callee NodeId -> the interface-impl method it resolves to, when the
    /// receiver's concrete type *implements* an interface that declares the method
    /// (`g.val()` where `Good as Show { val … }`). IR lowers a direct call to the
    /// `{type}.{interface}.{method}` function the vtable lowering already emits.
    impl_method_calls: std.AutoHashMap(ast.NodeId, ImplMethodCall),
    /// `for x in it` where `it` is an iterator (not a slice/array): the iter
    /// expr's NodeId -> the `next(self: *Self) -> ?T` method's symbol. IR lowers
    /// these as a `while it.next() |x|` loop.
    iterator_fors: std.AutoHashMap(ast.NodeId, SymbolId),
    /// Method-call (field-callee) NodeIds whose value receiver must be implicitly
    /// address-of'd because the method takes a `*Self`/`*const Self` (UFCS auto-ref).
    /// IR lowers these receivers via `lowerLValueAddress`.
    receiver_auto_addr: std.AutoHashMap(ast.NodeId, void),
    /// Bare enum-literal (`.variant`) NodeIds resolved against an expected enum
    /// type (in argument/assignment/typed-local position). IR lowers as variant_lit.
    enum_lits: std.AutoHashMap(ast.NodeId, EnumLit),
    generic_instantiations: std.ArrayList(GenericInstantiation) = .empty,
    /// Callee expression NodeId → mangled name for generic function calls.
    generic_call_insts: std.AutoHashMap(ast.NodeId, []const u8) = undefined,
    /// Generic struct templates: struct name → TypeDecl (with type_params).
    generic_struct_templates: std.StringHashMap(ast.TypeDecl) = undefined,
    /// Mangled name → SymbolId for already-instantiated generic structs.
    generic_struct_instances: std.StringHashMap(SymbolId) = undefined,
    /// Reverse of the above: instance SymbolId → its template + concrete type
    /// args. Lets generic-argument inference recover `T` from an argument typed
    /// `*Atomic(u32)` when the parameter is `*Atomic(T)` (see inferGenericCallImpl).
    generic_struct_instance_args: std.AutoHashMap(SymbolId, GenericApp) = undefined,
    interface_impls: std.StringHashMap(ast.InterfaceImpl) = undefined,
    /// Integer-valued top-level constants by name — so a `[N]T` array size can
    /// resolve a named const (`N :: 29`) or simple arithmetic over them.
    const_ints: std.StringHashMap(u64) = undefined,
    /// Lifted-lambda link name → the free-variable names in its body (candidates
    /// for capture). Populated at registration; resolved to actual captures at
    /// each definition site (see `lambda_captures`).
    lambda_free: std.StringHashMap([]const []const u8) = undefined,
    /// Lifted-lambda link name → the variables it captures from the enclosing
    /// scope (the free vars that resolved to enclosing locals), with their types.
    /// Resolved at the definition site; read by the lambda body check and by IR.
    lambda_captures: std.StringHashMap([]const Capture) = undefined,
    diagnostics: std.ArrayList(Diagnostic) = .empty,

    pub fn init(allocator: std.mem.Allocator) TypeEnv {
        return .{
            .symbol_types = std.AutoHashMap(SymbolId, Ty).init(allocator),
            .layouts = std.AutoHashMap(SymbolId, TypeLayout).init(allocator),
            .fn_sigs = std.AutoHashMap(SymbolId, FnSig).init(allocator),
            .variant_values = std.AutoHashMap(SymbolId, VariantValueInfo).init(allocator),
            .distinct_types = std.AutoHashMap(SymbolId, Ty).init(allocator),
            .alias_refs = std.AutoHashMap(SymbolId, ast.TypeRef).init(allocator),
            .expr_types = std.AutoHashMap(ast.NodeId, Ty).init(allocator),
            .expr_symbols = std.AutoHashMap(ast.NodeId, SymbolId).init(allocator),
            .expr_scopes = std.AutoHashMap(ast.NodeId, ScopeId).init(allocator),
            .extension_calls = std.AutoHashMap(ast.NodeId, SymbolId).init(allocator),
            .impl_method_calls = std.AutoHashMap(ast.NodeId, ImplMethodCall).init(allocator),
            .iterator_fors = std.AutoHashMap(ast.NodeId, SymbolId).init(allocator),
            .receiver_auto_addr = std.AutoHashMap(ast.NodeId, void).init(allocator),
            .enum_lits = std.AutoHashMap(ast.NodeId, EnumLit).init(allocator),
            .generic_call_insts = std.AutoHashMap(ast.NodeId, []const u8).init(allocator),
            .generic_struct_templates = std.StringHashMap(ast.TypeDecl).init(allocator),
            .generic_struct_instances = std.StringHashMap(SymbolId).init(allocator),
            .generic_struct_instance_args = std.AutoHashMap(SymbolId, GenericApp).init(allocator),
            .interface_impls = std.StringHashMap(ast.InterfaceImpl).init(allocator),
            .const_ints = std.StringHashMap(u64).init(allocator),
            .lambda_free = std.StringHashMap([]const []const u8).init(allocator),
            .lambda_captures = std.StringHashMap([]const Capture).init(allocator),
        };
    }

    pub fn deinit(self: *TypeEnv, allocator: std.mem.Allocator) void {
        self.symbol_types.deinit();
        self.layouts.deinit();
        self.fn_sigs.deinit();
        self.variant_values.deinit();
        self.distinct_types.deinit();
        self.alias_refs.deinit();
        self.expr_types.deinit();
        self.expr_symbols.deinit();
        self.expr_scopes.deinit();
        self.extension_calls.deinit();
        self.impl_method_calls.deinit();
        self.iterator_fors.deinit();
        self.receiver_auto_addr.deinit();
        self.enum_lits.deinit();
        self.const_ints.deinit();
        self.generic_call_insts.deinit();
        for (self.generic_instantiations.items) |*gi| {
            gi.expr_types.deinit();
            gi.call_insts.deinit();
        }
        self.generic_instantiations.deinit(allocator);
        self.generic_struct_templates.deinit();
        self.generic_struct_instances.deinit();
        self.generic_struct_instance_args.deinit();
        self.interface_impls.deinit();
        var lf = self.lambda_free.valueIterator();
        while (lf.next()) |v| allocator.free(v.*);
        self.lambda_free.deinit();
        var lc = self.lambda_captures.valueIterator();
        while (lc.next()) |v| allocator.free(v.*);
        self.lambda_captures.deinit();
        self.diagnostics.deinit(allocator);
    }

    pub fn set(self: *TypeEnv, id: SymbolId, ty: Ty) !void {
        try self.symbol_types.put(id, ty);
    }

    pub fn get(self: TypeEnv, id: SymbolId) ?Ty {
        return self.symbol_types.get(id);
    }
};

pub const TypeArg = struct {
    name: []const u8,
    ty: Ty,
};

pub const GenericInstantiation = struct {
    sym_id: SymbolId,
    fn_name: []const u8,
    mangled_name: []const u8,
    type_args: []const TypeArg,
    /// Per-instantiation expression types filled during checkGenericInstantiation.
    expr_types: std.AutoHashMap(NodeId, Ty),
    /// Per-instantiation generic-callee mangled names. The SAME call node in a
    /// generic body (`bget(T, …)`) resolves to a different concrete instantiation
    /// in each parent instantiation (`bget__T_i32` vs `bget__T_f64`), so this must
    /// not share the global map — the last writer would clobber the others.
    call_insts: std.AutoHashMap(NodeId, []const u8),
    /// The call site that first requested this instantiation — used to point a
    /// `where` rejection at the call, not the function declaration.
    origin_span: Span = Span.new(0, 0),
};

/// A resolution-time `where`-predicate evaluator. Opaque to sema (the context is
/// the resolution `ComptimeVm`, owned by pipeline) so sema never imports ir.
/// Returns the rejection message ("" = accept), or null if it couldn't run.
pub const WhereEvalFn = *const fn (
    ctx: *anyopaque,
    file: []const u8,
    wc: ast.Block,
    type_args: []const TypeArg,
    output_params: []const []const u8,
    expr_types: std.AutoHashMap(NodeId, Ty),
    out_alloc: std.mem.Allocator,
) ?[]const u8;

/// A resolution-time evaluator for an output type param (`-> $Acc`): runs the
/// `where` block and returns the node id of the selected `Acc = <type>` RHS
/// (0 = not assigned), which sema resolves back to a concrete type.
pub const WhereTypeEvalFn = *const fn (
    ctx: *anyopaque,
    file: []const u8,
    wc: ast.Block,
    type_args: []const TypeArg,
    output_params: []const []const u8,
    expr_types: std.AutoHashMap(NodeId, Ty),
) ?u64;

fn callArgExpr(arg: ast.CallArg) ast.Expr {
    return switch (arg) {
        .positional => |e| e,
        .named => |n| n.value,
    };
}

/// If `stmt` is a top-level `require(...)` expression statement, return its call.
fn requireCall(stmt: ast.Stmt) ?ast.CallExpr {
    const e = switch (stmt) {
        .expr => |x| x,
        else => return null,
    };
    const call = switch (e.kind) {
        .call => |c| c,
        else => return null,
    };
    const callee = switch (call.callee.kind) {
        .ident => |n| n,
        // `core::require(T, Other)` — the reserved-namespace spelling.
        .scope_access => |sa| if (isCoreNamespace(sa)) sa.member else return null,
        else => return null,
    };
    return if (std.mem.eql(u8, callee, "require")) call else null;
}

/// Find the `where` assignment `pname = <rhs>` whose RHS has node id `node_id`,
/// descending through control flow. Returns the RHS type expression.
fn findOutputAssign(stmts: []const ast.Stmt, pname: []const u8, node_id: u64) ?ast.Expr {
    for (stmts) |s| {
        switch (s) {
            .assign => |a| {
                if (a.target.kind == .ident and
                    std.mem.eql(u8, a.target.kind.ident, pname) and
                    @as(u64, a.value.id) == node_id) return a.value;
            },
            .if_stmt => |i| {
                if (findOutputAssign(i.then_block.statements, pname, node_id)) |e| return e;
                if (i.else_block) |eb| if (findOutputAssign(eb.statements, pname, node_id)) |e| return e;
            },
            .match_stmt => |m| {
                for (m.arms) |arm| if (findOutputAssign(arm.body.statements, pname, node_id)) |e| return e;
            },
            .comptime_if => |i| {
                if (findOutputAssign(i.then_block.statements, pname, node_id)) |e| return e;
                if (i.else_block) |eb| if (findOutputAssign(eb.statements, pname, node_id)) |e| return e;
            },
            .while_stmt => |w| if (findOutputAssign(w.body.statements, pname, node_id)) |e| return e,
            .for_range => |f| if (findOutputAssign(f.body.statements, pname, node_id)) |e| return e,
            .for_slice => |f| if (findOutputAssign(f.body.statements, pname, node_id)) |e| return e,
            .unsafe_block, .comptime_run => |b| if (findOutputAssign(b.statements, pname, node_id)) |e| return e,
            else => {},
        }
    }
    return null;
}

pub fn fromBuiltinName(name: []const u8) ?Ty {
    // Sub-byte integers — stored as u8/i8 in sema; IR uses correct bit width
    if (std.mem.eql(u8, name, "u1")) return .u8;
    if (std.mem.eql(u8, name, "u2")) return .u8;
    if (std.mem.eql(u8, name, "u3")) return .u8;
    if (std.mem.eql(u8, name, "u4")) return .u8;
    if (std.mem.eql(u8, name, "u5")) return .u8;
    if (std.mem.eql(u8, name, "u6")) return .u8;
    if (std.mem.eql(u8, name, "u7")) return .u8;
    if (std.mem.eql(u8, name, "i1")) return .i8;
    if (std.mem.eql(u8, name, "i2")) return .i8;
    if (std.mem.eql(u8, name, "i3")) return .i8;
    if (std.mem.eql(u8, name, "i4")) return .i8;
    if (std.mem.eql(u8, name, "i5")) return .i8;
    if (std.mem.eql(u8, name, "i6")) return .i8;
    if (std.mem.eql(u8, name, "i7")) return .i8;
    if (std.mem.eql(u8, name, "i8")) return .i8;
    if (std.mem.eql(u8, name, "i16")) return .i16;
    if (std.mem.eql(u8, name, "i32")) return .i32;
    if (std.mem.eql(u8, name, "i64")) return .i64;
    if (std.mem.eql(u8, name, "u8")) return .u8;
    if (std.mem.eql(u8, name, "u16")) return .u16;
    if (std.mem.eql(u8, name, "u32")) return .u32;
    if (std.mem.eql(u8, name, "u64")) return .u64;
    if (std.mem.eql(u8, name, "f32")) return .f32;
    if (std.mem.eql(u8, name, "f64")) return .f64;
    if (std.mem.eql(u8, name, "bool")) return .bool;
    if (std.mem.eql(u8, name, "byte")) return .byte;
    if (std.mem.eql(u8, name, "usize")) return .usize;
    if (std.mem.eql(u8, name, "isize")) return .isize;
    if (std.mem.eql(u8, name, "addr")) return .addr;
    if (std.mem.eql(u8, name, "void")) return .void;
    if (std.mem.eql(u8, name, "Text")) return .text;
    if (std.mem.eql(u8, name, "Rune")) return .rune;
    if (std.mem.eql(u8, name, "System")) return .system;
    if (std.mem.eql(u8, name, "FileSys")) return .file_sys;
    if (std.mem.eql(u8, name, "Net")) return .net;
    if (std.mem.eql(u8, name, "Clock")) return .clock;
    if (std.mem.eql(u8, name, "Gpu")) return .gpu;
    if (std.mem.eql(u8, name, "Writer")) return .writer;
    if (std.mem.eql(u8, name, "Reader")) return .reader;
    if (std.mem.eql(u8, name, "Conn")) return .conn;
    if (std.mem.eql(u8, name, "TextBuf")) return .text_buf;
    if (std.mem.eql(u8, name, "Args")) return .args;
    if (std.mem.eql(u8, name, "ThreadPool")) return .thread_pool;
    if (std.mem.eql(u8, name, "Zone")) return .zone_handle;
    return null;
}

/// The spellable built-in type names, used to offer a "did you mean" when an
/// unknown type is referenced. (Not exhaustive — just the ones a user types.)
const builtin_type_names = [_][]const u8{
    "i8",   "i16",  "i32",  "i64",  "isize",
    "u8",   "u16",  "u32",  "u64",  "usize",
    "f32",  "f64",  "bool", "byte", "void",
    "addr", "Text", "Rune", "Writer", "Reader",
};

/// If `name` is an integer-type spelling (`u<N>` / `i<N>`), return its width.
/// Used to give a tailored message for unsupported widths like `u128`.
fn intWidthName(name: []const u8) ?struct { signed: bool, bits: u32 } {
    if (name.len < 2) return null;
    const signed = switch (name[0]) {
        'i' => true,
        'u' => false,
        else => return null,
    };
    var bits: u32 = 0;
    for (name[1..]) |ch| {
        if (ch < '0' or ch > '9') return null;
        bits = bits * 10 + (ch - '0');
        if (bits > 100000) return null; // absurd width — stop accumulating
    }
    return .{ .signed = signed, .bits = bits };
}

/// Classic Levenshtein edit distance, capped to short identifiers (anything
/// longer than the scratch rows is treated as "far"). Drives type suggestions.
fn levenshtein(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    if (b.len + 1 > 64) return @max(a.len, b.len);
    var prev: [64]usize = undefined;
    var curr: [64]usize = undefined;
    var j: usize = 0;
    while (j <= b.len) : (j += 1) prev[j] = j;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        curr[0] = i + 1;
        var k: usize = 0;
        while (k < b.len) : (k += 1) {
            const cost: usize = if (a[i] == b[k]) 0 else 1;
            curr[k + 1] = @min(@min(curr[k] + 1, prev[k + 1] + 1), prev[k] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
    }
    return prev[b.len];
}

pub fn collectSymbols(allocator: std.mem.Allocator, module: ast.Module) SemanticError!SymbolTable {
    var table = try SymbolTable.init(allocator);
    errdefer table.deinit(allocator);

    // Pre-pass: find bare names declared as a *mangleable* decl (a plain
    // function/const, not extern/export/entry/runtime) in more than one module.
    // Those collide, so each gets a module-qualified linkage name; everything
    // else keeps its bare name (so non-colliding output is unchanged).
    var first_file = std.StringHashMap([]const u8).init(allocator);
    defer first_file.deinit();
    var colliding = std.StringHashMap(void).init(allocator);
    defer colliding.deinit();
    // C symbols claimed by a *renamed* extern (its skarn name differs from the C
    // symbol). A plain skarn decl that happens to share that bare name (e.g. a
    // `connect` wrapper over a `sys_connect :: #extern(.., "connect")` binding)
    // must take a module-qualified link name too — otherwise its internal body
    // and the external decl would emit the same LLVM symbol and clash.
    var extern_syms = std.StringHashMap(void).init(allocator);
    defer extern_syms.deinit();
    for (module.items) |item| {
        if (!isMangleable(item)) {
            switch (item) {
                .function => |f| if (externName(f.attrs)) |c_sym| {
                    if (!std.mem.eql(u8, c_sym, f.name)) try extern_syms.put(c_sym, {});
                },
                else => {},
            }
            continue;
        }
        const nm = item.name() orelse continue;
        const gop = try first_file.getOrPut(nm);
        if (!gop.found_existing) {
            gop.value_ptr.* = item.fileName();
        } else if (!std.mem.eql(u8, gop.value_ptr.*, item.fileName())) {
            try colliding.put(nm, {});
        }
    }

    for (module.items) |item| {
        const name = item.name() orelse continue;
        const link = if (isMangleable(item) and (colliding.contains(name) or extern_syms.contains(name)))
            try std.fmt.allocPrint(allocator, "{s}${s}", .{ moduleSlug(allocator, item.fileName()) catch name, name })
        else
            name;
        if (table.scopes.items[table.root_scope].names.get(link) != null) {
            std.debug.print("{s}: error: duplicate top-level declaration `{s}`\n", .{ item.fileName(), name });
            return error.SemanticFailed;
        }
        const kind: SymbolKind = switch (item) {
            .import => unreachable,
            .const_decl => |d| if (d.is_mutable) .global_var else .const_symbol,
            .type_decl => .type,
            .function => .function,
            .interface_impl => unreachable,
            .system_library => unreachable,
        };
        const id = try table.insertLinked(allocator, table.root_scope, name, link, kind, item.span(), item.fileName(), item.isPublic());
        // An extern function links against its C symbol (the `#extern` 2nd arg),
        // not its skarn declaration name. The root-scope key stays the bare/collision
        // name (so resolution is unchanged and two externs may share one C symbol
        // across modules without colliding), but the *linkage* name — emitted for
        // the LLVM declaration and every call site via `linkNameFor` — becomes the
        // C symbol. When the skarn name already equals the C name this is a no-op.
        switch (item) {
            .function => |f| if (externName(f.attrs)) |c_sym| {
                table.symbols.items[id].link_name = c_sym;
            },
            else => {},
        }
        const visible = try visibleNamesFor(&table, allocator, item.fileName());
        try visible.put(name, id);
    }

    for (module.items) |item| {
        const imp = switch (item) {
            .import => |value| value,
            else => continue,
        };
        // `core::` is the reserved compiler-builtin namespace — a module may not
        // claim it (as an alias or a trailing path segment). Checked before import
        // resolution so it fires even on the in-memory `compile()` path.
        if (imp.namespace()) |ns| {
            if (std.mem.eql(u8, ns, "core")) {
                std.debug.print("{s}: error: `core` is a reserved namespace (compiler builtins) — use a different alias\n", .{imp.file_name});
                return error.SemanticFailed;
            }
        }
        // `compile()` parses one in-memory source and intentionally does not
        // resolve imports. Multi-file and filesystem compilation always set it.
        const target_file = imp.resolved_file orelse continue;
        const visible = try visibleNamesFor(&table, allocator, imp.file_name);

        if (imp.namespace()) |ns| {
            // `#import a.b;` / `#import a.b as c;` — bind a namespace alias; the
            // module's names are reached via `ns::member`, not brought in scope.
            const aliases = try namespacesFor(&table, allocator, imp.file_name);
            try aliases.put(ns, target_file);
        } else if (imp.names) |names| {
            // Selective: bring just the listed names in unqualified.
            for (names) |name| {
                const id = findSymbolInFile(table, target_file, name) orelse {
                    std.debug.print("{s}: error: module `{s}` has no declaration named `{s}`\n", .{ imp.file_name, target_file, name });
                    return error.SemanticFailed;
                };
                const imported = table.symbol(id);
                if (!imported.is_public) {
                    std.debug.print("{s}: error: `{s}` is private to module `{s}`\n", .{ imp.file_name, name, target_file });
                    return error.SemanticFailed;
                }
                try addVisibleName(visible, imp.file_name, name, id);
            }
        } else {
            // Glob (`#import a.b.*;`): bring every public name in unqualified.
            for (table.symbols.items) |imported| {
                if (!std.mem.eql(u8, imported.file_name, target_file) or !imported.is_public) continue;
                try addVisibleName(visible, imp.file_name, imported.name, imported.id);
            }
        }
    }

    return table;
}

fn visibleNamesFor(
    table: *SymbolTable,
    allocator: std.mem.Allocator,
    file_name: []const u8,
) !*std.StringHashMap(SymbolId) {
    const entry = try table.visible_names.getOrPut(file_name);
    if (!entry.found_existing) entry.value_ptr.* = std.StringHashMap(SymbolId).init(allocator);
    return entry.value_ptr;
}

/// Whether a top-level item may be collision-mangled: a plain function or const
/// that is not extern/export, not the entry point, and not a runtime symbol.
/// (Types, externs, exports, and `main` keep their bare names — their names are
/// ABI- or tooling-significant, or referenced by the materializer.)
fn isMangleable(item: ast.Item) bool {
    if (std.mem.eql(u8, item.fileName(), "<runtime>")) return false;
    return switch (item) {
        .function => |f| !hasAttr(f.attrs, "extern") and !hasAttr(f.attrs, "foreign") and
            !hasAttr(f.attrs, "export") and !hasAttr(f.attrs, "entry") and
            !std.mem.eql(u8, f.name, "main"),
        .const_decl => true,
        else => false,
    };
}

/// A linkage-safe slug for a module's file name (non-alphanumerics → `_`).
fn moduleSlug(allocator: std.mem.Allocator, file_name: []const u8) ![]const u8 {
    const buf = try allocator.alloc(u8, file_name.len);
    for (file_name, 0..) |c, i| buf[i] = if (std.ascii.isAlphanumeric(c)) c else '_';
    return buf;
}

fn namespacesFor(
    table: *SymbolTable,
    allocator: std.mem.Allocator,
    file_name: []const u8,
) !*std.StringHashMap([]const u8) {
    const entry = try table.namespaces.getOrPut(file_name);
    if (!entry.found_existing) entry.value_ptr.* = std.StringHashMap([]const u8).init(allocator);
    return entry.value_ptr;
}

fn findSymbolInFile(table: SymbolTable, file_name: []const u8, name: []const u8) ?SymbolId {
    for (table.symbols.items) |symbol_value| {
        if (std.mem.eql(u8, symbol_value.file_name, file_name) and std.mem.eql(u8, symbol_value.name, name))
            return symbol_value.id;
    }
    return null;
}

fn addVisibleName(visible: *std.StringHashMap(SymbolId), file_name: []const u8, name: []const u8, id: SymbolId) SemanticError!void {
    if (visible.get(name)) |existing| {
        if (existing != id) {
            std.debug.print("{s}: error: import makes `{s}` ambiguous\n", .{ file_name, name });
            return error.SemanticFailed;
        }
        return;
    }
    try visible.put(name, id);
}

pub fn resolveNames(
    allocator: std.mem.Allocator,
    module: ast.Module,
    symbols: SymbolTable,
) SemanticError!void {
    _ = allocator;
    _ = module;
    _ = symbols;
}

pub fn checkZones(
    allocator: std.mem.Allocator,
    module: ast.Module,
    symbols: SymbolTable,
) SemanticError!void {
    _ = allocator;
    _ = module;
    _ = symbols;
}

pub fn checkTypes(
    allocator: std.mem.Allocator,
    module: ast.Module,
    symbols: SymbolTable,
) SemanticError!TypeEnv {
    var symbols_mut = symbols;
    return checkTypesWithContext(allocator, module, &symbols_mut, "", "");
}

/// Print any diagnostics accumulated in `diags` to stderr, using `source` for
/// the given `file` and the embedded runtime source for "<runtime>".
fn flushDiagnostics(
    allocator: std.mem.Allocator,
    diags: []const Diagnostic,
    source: []const u8,
    file: []const u8,
) void {
    for (diags) |d| {
        const src: []const u8 = if (std.mem.eql(u8, d.file, file)) source else "";
        const rendered = diag_mod.renderDiagnostic(allocator, d.file, src, d) catch continue;
        defer allocator.free(rendered);
        std.debug.print("{s}\n", .{rendered});
    }
}

/// Best-effort type check that returns the (partial) TypeEnv even when checking
/// reports errors, and suppresses those diagnostics. Used by pass 1 of the
/// two-pass `#insert` pipeline: code after a computed `#insert #run gen()` may
/// reference names the generator will declare, so pass 1 cannot fully succeed.
/// Pass 2 re-runs the strict `checkTypesWithContext` and is authoritative.
pub fn checkTypesTolerant(
    allocator: std.mem.Allocator,
    module: ast.Module,
    symbols: *SymbolTable,
    source: []const u8,
    file: []const u8,
) error{OutOfMemory}!TypeEnv {
    var checker = Checker.init(allocator, symbols.*);
    checker.source = source;
    checker.file = file;
    checker.tolerant = true;
    defer checker.deinit();
    defer symbols.* = checker.symbols;
    checker.checkModule(module) catch |err| switch (err) {
        error.SemanticFailed => {}, // tolerated — pass 2 is authoritative
        error.OutOfMemory => return error.OutOfMemory,
    };
    return checker.finish();
}

pub fn checkTypesWithContext(
    allocator: std.mem.Allocator,
    module: ast.Module,
    symbols: *SymbolTable,
    source: []const u8,
    file: []const u8,
) SemanticError!TypeEnv {
    return checkTypesWithResolution(allocator, module, symbols, source, file, null, null, null);
}

/// Strict type-check with an optional resolution-time `where`-predicate evaluator
/// (the two-pass rail). The callbacks are non-null only for pass-2 of a module
/// that has `where` clauses.
pub fn checkTypesWithResolution(
    allocator: std.mem.Allocator,
    module: ast.Module,
    symbols: *SymbolTable,
    source: []const u8,
    file: []const u8,
    where_ctx: ?*anyopaque,
    where_fn: ?WhereEvalFn,
    where_type_fn: ?WhereTypeEvalFn,
) SemanticError!TypeEnv {
    var checker = Checker.init(allocator, symbols.*);
    checker.source = source;
    checker.file = file;
    checker.where_eval_ctx = where_ctx;
    checker.where_eval_fn = where_fn;
    checker.where_type_eval_fn = where_type_fn;
    defer checker.deinit();
    // Generic struct/function instantiation appends new symbols to the table.
    // Propagate the grown table back to the caller so later stages (IR lowering)
    // can resolve the instantiated symbols. `checker.deinit` does not free the
    // symbol table, so transferring it here is safe.
    defer symbols.* = checker.symbols;

    checker.checkModule(module) catch |err| switch (err) {
        error.SemanticFailed => {
            // Diagnostics are still alive here (defer runs after return).
            if (checker.diagnostics.items.len == 0)
                std.debug.print("{s}: error: semantic error (no further details)\n", .{file});
            flushDiagnostics(allocator, checker.diagnostics.items, source, file);
            return error.SemanticFailed;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    // Check each generic instantiation discovered during the main pass.
    // New instantiations may be discovered while checking (e.g. generic calls inside
    // generic bodies), so iterate until stable.
    var checked: usize = 0;
    while (checked < checker.env.generic_instantiations.items.len) {
        checker.checkGenericInstantiation(module, checked) catch |err| switch (err) {
            error.SemanticFailed => {
                if (checker.diagnostics.items.len == 0)
                    std.debug.print("{s}: error: semantic error (no further details)\n", .{file});
                flushDiagnostics(allocator, checker.diagnostics.items, source, file);
                return error.SemanticFailed;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        checked += 1;
    }

    return checker.finish();
}

pub fn mangleGeneric(
    allocator: std.mem.Allocator,
    name: []const u8,
    type_args: []const ast.TypeRef,
) ![]u8 {
    _ = type_args;
    return allocator.dupe(u8, name);
}

const Checker = struct {
    allocator: std.mem.Allocator,
    symbols: SymbolTable,
    env: TypeEnv,
    scope_stack: std.ArrayList(std.StringHashMap(Ty)),
    zone_owner_scopes: std.ArrayList(std.StringHashMap(ZoneOwner)) = .empty,
    active_zones: std.ArrayList(ActiveZone) = .empty,
    current_return_ty: Ty = .void,
    current_error_ty: ?Ty = null,
    loop_depth: usize = 0,
    current_type_params: []const []const u8 = &.{},
    current_type_binding: []const TypeArg = &.{},
    current_self_ty: ?Ty = null,
    unsafe_depth: usize = 0,
    /// Recursion guard for resolving (possibly cyclic) type aliases.
    alias_depth: u32 = 0,
    // Diagnostics — collected instead of failing immediately where possible.
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    source: []const u8 = "",
    file: []const u8 = "",
    /// Functions declared `#must_use` — discarding a call's result is an error.
    /// Populated at the start of `checkModule`.
    must_use_fns: std.StringHashMap(void) = undefined,
    /// Locals in the function being checked that hold a CAPTURING closure (by
    /// direct assignment or aliasing). Cleared per function. Used to reject
    /// returning such a closure (its environment lives in this function).
    capturing_locals: std.StringHashMap(void) = undefined,
    /// True when the function being checked has an `*Arena` parameter — then a
    /// capturing closure's environment is allocated in that caller-owned region,
    /// so returning the closure is allowed (region passing).
    current_has_arena_param: bool = false,
    /// Resolution-time `where`-predicate evaluator (the two-pass rail). Set only
    /// for the strict pass-2 of a module that has `where` clauses: an opaque
    /// context (the resolution `ComptimeVm`) and a thunk that runs the predicate.
    /// Kept as an opaque callback so sema never imports ir (would be circular).
    where_eval_ctx: ?*anyopaque = null,
    where_eval_fn: ?WhereEvalFn = null,
    /// Companion to `where_eval_fn` for computing output type params (`-> $Acc`).
    where_type_eval_fn: ?WhereTypeEvalFn = null,
    /// The call site that requested the instantiation currently being checked,
    /// so a `where` rejection points at the call, not the function decl.
    current_inst_span: ?Span = null,
    /// Output type param names (`-> $Acc`) of the function currently being
    /// checked — assignments to these inside the `where` block are type-valued.
    current_output_params: []const []const u8 = &.{},
    /// Named `constraint Name($T) { … }` predicates, by name. Used to enforce
    /// `$T: Name` at resolution by running the body on the resolution VM.
    constraint_decls: std.StringHashMap(ast.FunctionDecl) = undefined,
    constraint_decls_init: bool = false,
    /// Tolerant mode (the `#compiler` hook pre-pass): keep checking the rest of
    /// the module after a per-declaration failure, so error-free declarations
    /// (e.g. imported std) are still fully typed for comptime lowering.
    tolerant: bool = false,
    /// `match` statements proven exhaustive during checking (covers every enum
    /// variant, or has an `else`), keyed by `match.span.start`. Return-flow
    /// analysis consults this so a total enum match counts as returning on all
    /// paths without a redundant `else`.
    exhaustive_matches: std.AutoHashMap(usize, void) = undefined,
    exhaustive_matches_init: bool = false,

    fn init(allocator: std.mem.Allocator, symbols: SymbolTable) Checker {
        return .{
            .allocator = allocator,
            .symbols = symbols,
            .env = TypeEnv.init(allocator),
            .scope_stack = .empty,
            .constraint_decls = std.StringHashMap(ast.FunctionDecl).init(allocator),
            .constraint_decls_init = true,
            .exhaustive_matches = std.AutoHashMap(usize, void).init(allocator),
            .exhaustive_matches_init = true,
        };
    }

    fn deinit(self: *Checker) void {
        for (self.scope_stack.items) |*s| s.deinit();
        self.scope_stack.deinit(self.allocator);
        for (self.zone_owner_scopes.items) |*s| s.deinit();
        self.zone_owner_scopes.deinit(self.allocator);
        self.active_zones.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        if (self.constraint_decls_init) self.constraint_decls.deinit();
        if (self.exhaustive_matches_init) self.exhaustive_matches.deinit();
    }

    // ── Diagnostics ──────────────────────────────────────────────────────────

    fn emitWarning(self: *Checker, span: Span, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.diagnostics.append(self.allocator, .{
            .kind = .warning,
            .message = msg,
            .span = span,
            .file = self.file,
        }) catch {};
    }

    fn emitError(self: *Checker, span: Span, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.diagnostics.append(self.allocator, Diagnostic.err(msg, span, self.file)) catch {};
    }

    /// Format a Ty as a human-readable string (caller owns result).
    fn formatTy(self: *Checker, ty: Ty) []const u8 {
        return switch (ty) {
            .i8 => "i8",
            .i16 => "i16",
            .i32 => "i32",
            .i64 => "i64",
            .u8 => "u8",
            .u16 => "u16",
            .u32 => "u32",
            .u64 => "u64",
            .bool => "bool",
            .void => "void",
            .usize => "usize",
            .isize => "isize",
            .f32 => "f32",
            .f64 => "f64",
            .int_lit => "integer literal",
            .float_lit => "float literal",
            .null_ptr => "null",
            .zone_handle => "Zone",
            .error_ty => "error",
            .unknown => "unknown",
            .optional => |inner| std.fmt.allocPrint(self.allocator, "?{s}", .{self.formatTy(inner.*)}) catch "?T",
            .pointer => |inner| std.fmt.allocPrint(self.allocator, "*{s}", .{self.formatTy(inner.*)}) catch "*T",
            .const_ptr => |inner| std.fmt.allocPrint(self.allocator, "*const {s}", .{self.formatTy(inner.*)}) catch "*const T",
            .slice => |inner| std.fmt.allocPrint(self.allocator, "[]{s}", .{self.formatTy(inner.*)}) catch "[]T",
            .borrow => |inner| std.fmt.allocPrint(self.allocator, "borrow {s}", .{self.formatTy(inner.*)}) catch "borrow T",
            .named => |id| self.symbols.symbol(id).name,
            .type_param => |n| n,
            .fallible => |f| std.fmt.allocPrint(self.allocator, "{s} ! error", .{self.formatTy(f.ok.*)}) catch "T!E",
            else => "T",
        };
    }

    fn finish(self: *Checker) TypeEnv {
        var env = self.env;
        // Transfer diagnostics into the TypeEnv so callers can inspect them.
        env.diagnostics = self.diagnostics;
        self.diagnostics = .empty;
        self.env = TypeEnv.init(self.allocator);
        return env;
    }

    fn pushScope(self: *Checker) !void {
        try self.scope_stack.append(self.allocator, std.StringHashMap(Ty).init(self.allocator));
        try self.zone_owner_scopes.append(self.allocator, std.StringHashMap(ZoneOwner).init(self.allocator));
    }

    fn popScope(self: *Checker) void {
        var s = self.scope_stack.pop() orelse return;
        s.deinit();
        var owners = self.zone_owner_scopes.pop().?;
        owners.deinit();
    }

    fn declareLocal(self: *Checker, name: []const u8, ty: Ty) !void {
        const top = &self.scope_stack.items[self.scope_stack.items.len - 1];
        try top.put(name, ty);
    }

    fn lookupLocal(self: Checker, name: []const u8) ?Ty {
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scope_stack.items[i].get(name)) |ty| return ty;
        }
        return null;
    }

    fn resolveSymbol(self: Checker, name: []const u8) ?SymbolId {
        return self.symbols.resolveVisible(self.file, name);
    }

    /// Resolve a (possibly namespace-qualified) type name to its symbol. A
    /// qualified `ns::Name` is reached through the import alias (`#import a.b;`
    /// brings the module in as `b::Name`); an unqualified name resolves the
    /// usual visible way. Used for both plain `ns::Name` types and the template
    /// of a `ns::Name(args)` generic instantiation.
    fn resolveTypeSymbol(self: Checker, namespace: ?[]const u8, name: []const u8) ?SymbolId {
        if (namespace) |ns| return self.symbols.resolveScoped(self.file, ns, name);
        return self.resolveSymbol(name);
    }

    /// Resolve `alias::member` (single-level namespace access). The base must be a
    /// namespace alias bound by `#import a.b;` / `#import a.b as alias;`.
    fn resolveScopeAccessSymbol(self: Checker, sa: ast.ScopeAccess) ?SymbolId {
        const alias = switch (sa.base.kind) {
            .ident => |n| n,
            else => return null,
        };
        if (self.symbols.resolveScoped(self.file, alias, sa.member)) |id| return id;
        // `Type::method` — an associated (no-receiver) function declared inside the
        // struct body, hoisted to a top-level `"<Type>.<member>"`.
        if (self.resolveSymbol(alias)) |tid| {
            if (self.symbols.symbol(tid).kind == .type)
                return self.assocFnInFile(alias, sa.member, self.symbols.symbol(tid).file_name);
        }
        return null;
    }

    /// Find a hoisted in-struct function `"<base>.<member>"` in `file`, visible from
    /// the current file (public, or same file).
    fn assocFnInFile(self: Checker, base: []const u8, member: []const u8, file: []const u8) ?SymbolId {
        var buf: [256]u8 = undefined;
        const dotted = std.fmt.bufPrint(&buf, "{s}.{s}", .{ base, member }) catch return null;
        for (self.symbols.symbols.items) |sym| {
            if (sym.kind == .function and std.mem.eql(u8, sym.file_name, file) and
                std.mem.eql(u8, sym.name, dotted) and
                (sym.is_public or std.mem.eql(u8, sym.file_name, self.file)))
                return sym.id;
        }
        return null;
    }

    fn localScopeIndex(self: Checker, name: []const u8) ?usize {
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scope_stack.items[i].contains(name)) return i;
        }
        return null;
    }

    fn setLocalZoneOwner(self: *Checker, name: []const u8, owner: ?ZoneOwner) !void {
        const scope_index = self.localScopeIndex(name) orelse return;
        if (owner) |value|
            try self.zone_owner_scopes.items[scope_index].put(name, value)
        else
            _ = self.zone_owner_scopes.items[scope_index].remove(name);
    }

    fn lookupZoneOwner(self: Checker, name: []const u8) ?ZoneOwner {
        var i = self.zone_owner_scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.zone_owner_scopes.items[i].get(name)) |owner| return owner;
        }
        return null;
    }

    /// The `std.heap.Arena` struct type — the type of a `zone X: Arena {}` handle.
    /// The pipeline guarantees `Arena` is in scope wherever a zone block appears
    /// (the embedded heap prelude is injected, or std.heap is imported). Falls
    /// back to the opaque `zone_handle` if it somehow isn't resolvable.
    fn arenaTy(self: *Checker) Ty {
        const id = self.resolveSymbol("Arena") orelse return .zone_handle;
        if (self.symbols.symbol(id).kind != .type) return .zone_handle;
        return .{ .named = id };
    }

    /// True when `name` is a live `zone X: Arena {}` handle (vs. a manually
    /// managed `Arena` local, which has no escape restrictions).
    fn isActiveZone(self: Checker, name: []const u8) bool {
        for (self.active_zones.items) |zone| {
            if (std.mem.eql(u8, zone.name, name)) return true;
        }
        return false;
    }

    fn validateBorrowParam(self: *Checker, ty: Ty, span: Span) SemanticError!void {
        if (ty != .borrow) {
            if (containsBorrow(ty)) {
                self.emitError(span, "`borrow` must be the outer qualifier of a function parameter", .{});
                return error.SemanticFailed;
            }
            return;
        }
        if (containsBorrow(ty.borrow.*)) {
            self.emitError(span, "nested `borrow` qualifiers are not allowed", .{});
            return error.SemanticFailed;
        }
        switch (ty.borrow.*) {
            .pointer, .const_ptr, .slice => {},
            else => {
                self.emitError(span, "`borrow` parameters must be pointers or slices", .{});
                return error.SemanticFailed;
            },
        }
    }

    fn rejectBorrowOutsideParam(self: *Checker, ty: Ty, span: Span) SemanticError!void {
        if (!containsBorrow(ty)) return;
        self.emitError(span, "`borrow` is only valid as the outer qualifier of a function parameter", .{});
        return error.SemanticFailed;
    }

    fn rejectBorrowTypeRefOutsideParam(self: *Checker, ty: ast.TypeRef) SemanticError!void {
        if (!typeRefContainsBorrow(ty)) return;
        self.emitError(ty.span(), "`borrow` is only valid as the outer qualifier of a function parameter", .{});
        return error.SemanticFailed;
    }

    fn checkNonEscapingArgument(self: *Checker, expr: ast.Expr, expected: ?Ty) SemanticError!void {
        const owner = self.exprZoneOwner(expr) orelse return;
        if (expected) |ty| if (ty == .borrow) return;
        const source = if (owner.kind == .borrow) "borrowed value" else "zone-owned value";
        self.emitError(expr.span, "{s} from `{s}` can only be passed to a `borrow` parameter", .{ source, owner.name });
        return error.SemanticFailed;
    }

    /// If `expr` is a direct call to a `#must_use` function, return its name.
    fn mustUseCallee(self: *Checker, expr: ast.Expr) ?[]const u8 {
        if (expr.kind != .call) return null;
        const name = switch (expr.kind.call.callee.kind) {
            .ident => |n| n,
            .scope_access => |sa| sa.member,
            else => return null,
        };
        return if (self.must_use_fns.contains(name)) name else null;
    }

    fn checkModule(self: *Checker, module: ast.Module) SemanticError!void {
        // Pre-fold integer-valued top-level constants FIRST (before collecting
        // struct layouts), so a `[N]T` array field/local resolves its named-const
        // size (`N :: 29`) or simple arithmetic over them. A few passes let a const
        // reference an earlier one (`GW :: 2*W + 1`).
        {
            var pass: usize = 0;
            while (pass < 4) : (pass += 1) {
                var changed = false;
                for (module.items) |item| switch (item) {
                    .const_decl => |decl| {
                        if (self.env.const_ints.contains(decl.name)) continue;
                        const v = resolveArrayLen(decl.value, self.env.const_ints);
                        if (v != 0 or decl.value.kind == .int) {
                            self.env.const_ints.put(decl.name, v) catch {};
                            changed = true;
                        }
                    },
                    else => {},
                };
                if (!changed) break;
            }
        }

        try self.collectTopLevelTypes(module);

        // Record `#must_use` functions so a discarded call to one is rejected.
        self.must_use_fns = std.StringHashMap(void).init(self.allocator);
        self.capturing_locals = std.StringHashMap(void).init(self.allocator);
        for (module.items) |item| switch (item) {
            .function => |f| {
                if (hasAttr(f.attrs, "must_use")) try self.must_use_fns.put(f.name, {});
                // Pre-register every `constraint Name($T) { … }` so a `$T: Name`
                // use (in a fn signature OR a `struct($T: Name)`) resolves
                // regardless of source order — a struct may be instantiated while
                // checking a body declared before the constraint itself.
                if (f.is_constraint) try self.constraint_decls.put(f.name, f);
            },
            else => {},
        };

        for (module.items) |item| {
            self.file = item.fileName();
            // Tolerant mode (the `#compiler` hook pre-pass): a failure in one
            // declaration (e.g. `main` referencing a not-yet-generated symbol)
            // must not abort the whole module — the rest still needs typing so
            // imported std functions lower cleanly into the comptime VM cache.
            self.checkItem(item) catch |err| switch (err) {
                error.SemanticFailed => if (self.tolerant) continue else return err,
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
    }

    fn checkItem(self: *Checker, item: ast.Item) SemanticError!void {
        switch (item) {
            .import => {},
            .const_decl => |decl| _ = try self.inferExpr(decl.value),
            .type_decl => |decl| try self.checkTypeDecl(decl),
            .function => |decl| {
                // A `constraint` is a generic predicate template — registered for
                // `$T: Name` resolution, never checked/lowered as a fn.
                if (decl.is_constraint)
                    try self.constraint_decls.put(decl.name, decl);
                try self.checkFunction(decl);
            },
            .interface_impl => |impl| try self.checkInterfaceImpl(impl),
            .system_library => {},
        }
    }

    fn collectTopLevelTypes(self: *Checker, module: ast.Module) SemanticError!void {
        // Pre-pass: register every type alias first, so the layout/fn-sig pass
        // below can resolve aliases regardless of declaration order.
        for (module.items) |item| {
            const decl = switch (item) {
                .type_decl => |d| d,
                else => continue,
            };
            const aliased = switch (decl.kind) {
                .alias => |ty| ty,
                else => continue,
            };
            const id = self.symbols.resolveVisible(decl.file_name, decl.name) orelse continue;
            try self.env.alias_refs.put(id, aliased);
        }

        for (module.items) |item| {
            self.file = item.fileName();
            if (item == .interface_impl) {
                const impl = item.interface_impl;
                const key = try interfaceImplKey(self.allocator, impl.type_name, impl.interface_name);
                if (self.env.interface_impls.contains(key)) {
                    self.emitError(impl.span, "duplicate `{s} as {s}` implementation", .{ impl.type_name, impl.interface_name });
                    return error.SemanticFailed;
                }
                try self.env.interface_impls.put(key, impl);
                continue;
            }
            const name = item.name() orelse continue;
            // File-aware so collision-mangled top-level names resolve to their own
            // symbol (a bare root-scope lookup would miss them).
            const id = self.symbols.resolveVisible(item.fileName(), name) orelse continue;
            switch (item) {
                // A mutable global carries an explicit type; an immutable constant
                // takes the type of its (comptime) initializer.
                .const_decl => |decl| try self.env.set(id, if (decl.ty) |t| try self.typeFromRef(t) else try self.inferExpr(decl.value)),
                .type_decl => |decl| {
                    try self.env.set(id, .{ .named = id });
                    switch (decl.kind) {
                        // Aliases are registered in the pre-pass and resolved on
                        // demand by typeFromRef — no layout of their own.
                        .alias => {},
                        .struct_type => |strukt| {
                            if (strukt.type_params.len > 0) {
                                // Generic struct — store as template, don't process fields yet.
                                try self.env.generic_struct_templates.put(decl.name, decl);
                                // Register the type name but leave layout empty for now.
                            } else {
                                var fields = std.ArrayList(FieldInfo).empty;
                                errdefer fields.deinit(self.allocator);
                                for (strukt.fields) |field| {
                                    try fields.append(self.allocator, .{
                                        .name = field.name,
                                        .ty = try self.typeFromRef(field.ty),
                                        .default = field.default,
                                    });
                                }
                                try self.env.layouts.put(id, .{
                                    .kind = .{ .struct_type = try fields.toOwnedSlice(self.allocator) },
                                    .is_packed = hasAttr(decl.attrs, "packed"),
                                });
                            }
                        },
                        .errors => |errors_decl| {
                            try self.env.layouts.put(id, .{
                                .kind = .{ .error_set = try self.errorVariantsFromDecl(errors_decl.variants) },
                                .is_packed = false,
                            });
                        },
                        .enum_type => |enum_decl| {
                            var variants = std.ArrayList(VariantInfo).empty;
                            errdefer variants.deinit(self.allocator);
                            for (enum_decl.variants, 0..) |v, idx| {
                                try variants.append(self.allocator, .{
                                    .name = v.name,
                                    .payload = if (v.payload) |p| try self.typeFromRef(p) else null,
                                    .index = @intCast(idx),
                                });
                            }
                            try self.env.layouts.put(id, .{
                                .kind = .{ .variant_type = try variants.toOwnedSlice(self.allocator) },
                                .is_packed = false,
                            });
                        },
                        .interface_type => |interface_decl| {
                            self.current_self_ty = .{ .named = id };
                            defer self.current_self_ty = null;
                            var methods = std.ArrayList(InterfaceMethodInfo).empty;
                            errdefer methods.deinit(self.allocator);
                            for (interface_decl.methods) |method| {
                                var params = std.ArrayList(ParamSig).empty;
                                errdefer params.deinit(self.allocator);
                                for (method.params) |param| {
                                    const param_ty = try self.typeFromRef(param.ty);
                                    try self.validateBorrowParam(param_ty, param.span);
                                    try params.append(self.allocator, .{
                                        .name = param.name,
                                        .ty = param_ty,
                                    });
                                }
                                const return_ty = try self.typeFromRef(method.return_ty);
                                try self.rejectBorrowOutsideParam(return_ty, method.return_ty.span());
                                try methods.append(self.allocator, .{
                                    .name = method.name,
                                    .params = try params.toOwnedSlice(self.allocator),
                                    .return_ty = return_ty,
                                    .error_ty = if (method.error_ty) |err| try self.typeFromErrorSpec(err) else null,
                                });
                                const first = methods.items[methods.items.len - 1].params;
                                const self_ty = if (first.len > 0 and first[0].ty == .borrow) first[0].ty.borrow.* else if (first.len > 0) first[0].ty else .unknown;
                                const self_inner = switch (self_ty) {
                                    .pointer, .const_ptr => |inner| inner,
                                    else => null,
                                };
                                if (first.len == 0 or self_inner == null or
                                    self_inner.?.* != .named or self_inner.?.named != id)
                                {
                                    self.emitError(method.span, "interface method `{s}` must begin with `self: *Self` or `self: borrow *Self`", .{method.name});
                                    return error.SemanticFailed;
                                }
                            }
                            try self.env.layouts.put(id, .{
                                .kind = .{ .interface_type = try methods.toOwnedSlice(self.allocator) },
                                .is_packed = false,
                            });
                        },
                        else => {},
                    }
                },
                .function => |decl| {
                    // Set type param context so typeFromRef can resolve $T as Ty.type_param
                    self.current_type_params = decl.type_params;
                    defer self.current_type_params = &.{};

                    var params = std.ArrayList(ParamSig).empty;
                    errdefer params.deinit(self.allocator);
                    for (decl.params) |param| {
                        const param_ty = try self.typeFromRef(param.ty);
                        if (!param.is_type_param) try self.validateBorrowParam(param_ty, param.span);
                        try params.append(self.allocator, .{
                            .name = param.name,
                            .ty = param_ty,
                            .is_type_param = param.is_type_param,
                        });
                    }
                    const ret = try self.typeFromRef(decl.return_ty);
                    try self.rejectBorrowOutsideParam(ret, decl.return_ty.span());
                    const err_ty = if (decl.error_ty) |err| try self.typeFromErrorSpec(err) else null;
                    try self.env.fn_sigs.put(id, .{
                        .params = try params.toOwnedSlice(self.allocator),
                        .return_ty = ret,
                        .error_ty = err_ty,
                        .extern_name = externName(decl.attrs),
                        .inline_hint = hasAttr(decl.attrs, "inline"),
                        .no_inline = hasAttr(decl.attrs, "noinline"),
                        .no_return = hasAttr(decl.attrs, "noreturn"),
                        .entry = std.mem.eql(u8, decl.name, "main") or hasAttr(decl.attrs, "entry"),
                        .naked = hasAttr(decl.attrs, "naked"),
                        .export_sym = exportSym(decl.attrs),
                        .deprecated = deprecatedMsg(decl.attrs),
                        .type_params = decl.type_params,
                        .type_constraints = decl.type_constraints,
                        .type_binding = null,
                        .where_clause = decl.where_clause,
                        .output_type_params = decl.output_type_params,
                        .is_template = decl.is_constraint or decl.is_macro,
                    });
                    // The function's value type is a fn-pointer carrying its
                    // VALUE parameter types (skip `$T` type params) — so
                    // `f := some_fn; f(x)` types the call's arguments correctly.
                    var fnptr_params = std.ArrayList(Ty).empty;
                    errdefer fnptr_params.deinit(self.allocator);
                    for (decl.params) |param| {
                        if (param.is_type_param) continue;
                        try fnptr_params.append(self.allocator, try self.typeFromRef(param.ty));
                    }
                    try self.env.set(id, .{ .fn_ptr = .{
                        .params = try fnptr_params.toOwnedSlice(self.allocator),
                        .ret = try self.boxTy(if (err_ty) |err| .{ .fallible = .{ .ok = try self.boxTy(ret), .err = try self.boxTy(err) } } else ret),
                    } });
                    // A lifted lambda: record its free variables (capture candidates),
                    // keyed by linkage name so the def site can resolve them.
                    if (std.mem.startsWith(u8, decl.name, "__lambda_")) {
                        if (decl.body) |body| {
                            const free = freevars.analyze(self.allocator, decl.params, body) catch &.{};
                            self.env.lambda_free.put(self.symbols.symbol(id).link_name, free) catch {};
                        }
                    }
                },
                .import => {},
                .interface_impl => unreachable,
                .system_library => {},
            }
        }
    }

    fn checkTypeDecl(self: *Checker, decl: ast.TypeDecl) SemanticError!void {
        switch (decl.kind) {
            // Validate the alias resolves (catches unknown/cyclic underlying types).
            .alias => |ty| {
                try self.rejectBorrowTypeRefOutsideParam(ty);
                _ = try self.typeFromRef(ty);
            },
            .distinct => |ty| {
                try self.rejectBorrowTypeRefOutsideParam(ty);
                const underlying = try self.typeFromRef(ty);
                if (self.resolveSymbol(decl.name)) |id| {
                    try self.env.distinct_types.put(id, underlying);
                }
            },
            .opaque_type => {},
            .struct_type => |strukt| {
                for (strukt.fields) |field| try self.rejectBorrowTypeRefOutsideParam(field.ty);
                if (strukt.type_params.len > 0) return; // generic — checked on instantiation
                for (strukt.fields) |field| {
                    const field_ty = try self.typeFromRef(field.ty);
                    try self.rejectBorrowOutsideParam(field_ty, field.span);
                }
            },
            .errors => |errors_decl| {
                for (errors_decl.variants) |variant| {
                    if (variant.payload) |payload| {
                        try self.rejectBorrowTypeRefOutsideParam(payload);
                        try self.checkType(payload);
                    }
                }
            },
            .enum_type => |enum_decl| {
                for (enum_decl.variants) |variant| {
                    if (variant.payload) |payload| {
                        try self.rejectBorrowTypeRefOutsideParam(payload);
                        try self.checkType(payload);
                    }
                }
            },
            .interface_type => |interface_decl| {
                const id = self.symbols.resolve(self.symbols.root_scope, decl.name) orelse {
                    diag_mod.printIce("interface symbol missing from table after registration", @src());
                    return error.SemanticFailed;
                };
                self.current_self_ty = .{ .named = id };
                defer self.current_self_ty = null;
                for (interface_decl.methods) |method| {
                    for (method.params) |param| try self.checkType(param.ty);
                    try self.checkType(method.return_ty);
                }
            },
        }
    }

    fn checkInterfaceImpl(self: *Checker, impl: ast.InterfaceImpl) SemanticError!void {
        const concrete_id = self.resolveSymbol(impl.type_name) orelse {
            self.emitError(impl.span, "unknown type `{s}` in interface implementation", .{impl.type_name});
            return error.SemanticFailed;
        };
        const interface_id = self.resolveSymbol(impl.interface_name) orelse {
            self.emitError(impl.span, "unknown interface `{s}` in interface implementation", .{impl.interface_name});
            return error.SemanticFailed;
        };
        const layout = self.env.layouts.get(interface_id) orelse {
            self.emitError(impl.span, "`{s}` has no defined type layout", .{impl.interface_name});
            return error.SemanticFailed;
        };
        const required = switch (layout.kind) {
            .interface_type => |methods| methods,
            else => {
                self.emitError(impl.span, "`{s}` is not an interface", .{impl.interface_name});
                return error.SemanticFailed;
            },
        };
        self.current_self_ty = .{ .named = concrete_id };
        defer self.current_self_ty = null;

        for (required) |required_method| {
            const method = for (impl.methods) |candidate| {
                if (std.mem.eql(u8, candidate.name, required_method.name)) break candidate;
            } else {
                self.emitError(impl.span, "missing interface method `{s}`", .{required_method.name});
                return error.SemanticFailed;
            };
            if (method.params.len != required_method.params.len) {
                self.emitError(method.span, "interface method `{s}`: expected {d} parameter(s), found {d}", .{
                    method.name, required_method.params.len, method.params.len,
                });
                return error.SemanticFailed;
            }
            for (method.params, required_method.params) |actual, expected| {
                const actual_ty = try self.typeFromRef(actual.ty);
                const expected_ty = try substituteInterfaceSelf(self, expected.ty, interface_id, concrete_id);
                if (!sameTy(actual_ty, expected_ty)) {
                    self.emitError(actual.span, "signature mismatch for interface method `{s}`", .{method.name});
                    return error.SemanticFailed;
                }
            }
            const actual_ret = try self.typeFromRef(method.return_ty);
            const expected_ret = try substituteInterfaceSelf(self, required_method.return_ty, interface_id, concrete_id);
            if (!sameTy(actual_ret, expected_ret)) {
                self.emitError(method.span, "interface method `{s}`: return type mismatch: expected `{s}`, found `{s}`", .{
                    method.name, self.formatTy(expected_ret), self.formatTy(actual_ret),
                });
                return error.SemanticFailed;
            }
            try self.checkFunction(method);
        }
        for (impl.methods) |method| {
            var found = false;
            for (required) |req| if (std.mem.eql(u8, method.name, req.name)) {
                found = true;
                break;
            };
            if (!found) {
                self.emitError(method.span, "method `{s}` is not declared by interface `{s}`", .{ method.name, impl.interface_name });
                return error.SemanticFailed;
            }
        }
    }

    /// Compute output type params (`-> $Acc`) at a generic call site by running
    /// the `where` block on the resolution VM. The VM returns the node id of the
    /// selected `Acc = <type>` right-hand side; we resolve that type expression
    /// (with the value params already bound) and add it to `binding`, so the
    /// call's return type and the instantiation's body both see the result.
    /// Best-effort: silently no-ops when the resolution VM isn't wired (pass-1)
    /// or the predicate couldn't run, leaving the output param unbound.
    fn computeOutputParamsAtCall(self: *Checker, sig: FnSig, binding: *std.StringHashMap(Ty)) SemanticError!void {
        const wc = sig.where_clause orelse return;
        if (sig.output_type_params.len == 0) return;
        const teval = self.where_type_eval_fn orelse return;
        const ctx = self.where_eval_ctx orelse return;

        // A TypeArg view of the value-inferred params (e.g. T), for resolving the
        // where block and its `type_info(T)`.
        var bargs: std.ArrayList(TypeArg) = .empty;
        defer bargs.deinit(self.allocator);
        for (sig.type_params) |tp| {
            if (binding.get(tp)) |ty| try bargs.append(self.allocator, .{ .name = tp, .ty = ty });
        }

        const saved_tp = self.current_type_params;
        const saved_op = self.current_output_params;
        const saved_bind = self.current_type_binding;
        defer {
            self.current_type_params = saved_tp;
            self.current_output_params = saved_op;
            self.current_type_binding = saved_bind;
        }
        self.current_type_params = sig.type_params;
        self.current_output_params = sig.output_type_params;
        self.current_type_binding = bargs.items;

        // Type the where block (so `type_info(T)` etc. resolve for this binding),
        // then ask the VM which `Acc = <type>` branch was selected.
        try self.pushScope();
        self.checkBlock(wc) catch {
            self.popScope();
            return;
        };
        self.popScope();

        for (sig.output_type_params) |pname| {
            const node_id = teval(ctx, self.file, wc, bargs.items, sig.output_type_params, self.env.expr_types) orelse 0;
            if (node_id != 0) {
                if (findOutputAssign(wc.statements, pname, node_id)) |rhs| {
                    if (self.resolveExprAsType(rhs)) |ty| try binding.put(pname, ty);
                }
            }
        }
    }

    /// Enforce a user `constraint Name($T) { … }` against `ty`. Returns the reject
    /// message ("" = satisfied), or null if `name` isn't a user constraint (so the
    /// caller falls through to interface conformance). Runs the body on the
    /// resolution VM, exactly like a `where` predicate; in pass-1 (no VM) it
    /// accepts so the tolerant pass doesn't reject prematurely.
    fn runConstraintPredicate(self: *Checker, name: []const u8, ty: Ty) ?[]const u8 {
        var visiting = std.StringHashMap(void).init(self.allocator);
        defer visiting.deinit();
        return self.runConstraintPredicateRec(name, ty, &visiting);
    }

    fn runConstraintPredicateRec(self: *Checker, name: []const u8, ty: Ty, visiting: *std.StringHashMap(void)) ?[]const u8 {
        const decl = self.constraint_decls.get(name) orelse return null;
        const body = decl.body orelse return ""; // declared but empty → vacuously ok
        if (decl.type_params.len == 0) return "";
        if (visiting.contains(name)) return ""; // cycle in `require` graph → stop
        visiting.put(name, {}) catch return "";
        defer _ = visiting.remove(name);
        const eval = self.where_eval_fn orelse return ""; // pass-1: tolerant accept
        const ctx = self.where_eval_ctx orelse return "";

        var bargs = [_]TypeArg{.{ .name = decl.type_params[0], .ty = ty }};

        const saved_tp = self.current_type_params;
        const saved_op = self.current_output_params;
        const saved_bind = self.current_type_binding;
        defer {
            self.current_type_params = saved_tp;
            self.current_output_params = saved_op;
            self.current_type_binding = saved_bind;
        }
        self.current_type_params = decl.type_params;
        self.current_output_params = &.{};
        self.current_type_binding = &bargs;

        // Type the body (so `type_info(T)` and `require` args resolve), then check
        // composition guards before running this constraint's own predicate.
        self.pushScope() catch return "";
        self.checkBlock(body) catch {
            self.popScope();
            return "";
        };
        self.popScope();

        // `require(T, Other)` top-level guards: each required constraint must hold.
        for (body.statements) |stmt| {
            const call = requireCall(stmt) orelse continue;
            if (call.args.len < 2) continue;
            const other = switch (callArgExpr(call.args[1]).kind) {
                .ident => |n| n,
                else => continue,
            };
            const req_ty = self.resolveExprAsType(callArgExpr(call.args[0])) orelse ty;
            if (self.runConstraintPredicateRec(other, req_ty, visiting)) |m| {
                if (m.len > 0) return m;
            }
        }

        return eval(ctx, decl.file_name, body, &bargs, &.{}, self.env.expr_types, self.allocator);
    }

    /// Resolve a `where` output-type RHS expression (`i32`, `T`, a named type) to
    /// a concrete `Ty`, using the value params already bound. Null if it isn't a
    /// plain type name (the only form supported as an output-type RHS).
    fn resolveExprAsType(self: *Checker, e: ast.Expr) ?Ty {
        switch (e.kind) {
            // A bare builtin type (`i32`, `u8`, …) parses to `.type_ref`.
            .type_ref => |tr| return self.typeFromRef(tr) catch null,
            // A user/param type name (`T`, `Foo`) parses to `.ident`.
            .ident => |name| {
                for (self.current_type_binding) |arg| if (std.mem.eql(u8, arg.name, name)) return arg.ty;
                if (fromBuiltinName(name)) |t| return t;
                if (self.resolveSymbol(name)) |id| {
                    if (self.symbols.symbol(id).kind == .type) return .{ .named = id };
                }
                return null;
            },
            else => return null,
        }
    }

    /// Whether `ty` is `*Arena` (a region a closure environment can be allocated
    /// in by the caller).
    fn isArenaPtr(self: *Checker, ty: Ty) bool {
        return switch (ty) {
            .pointer, .const_ptr => |inner| switch (inner.*) {
                .named => |id| std.mem.eql(u8, self.symbols.symbol(id).name, "Arena"),
                else => false,
            },
            else => false,
        };
    }

    /// Whether `expr` evaluates to a capturing closure — a capturing lambda
    /// written inline, or a local that holds one (tracked in `capturing_locals`).
    fn valueIsCapturingClosure(self: *Checker, expr: ast.Expr) bool {
        if (self.capturingClosureLink(expr) != null) return true;
        return expr.kind == .ident and self.capturing_locals.contains(expr.kind.ident);
    }

    /// If `expr` is a reference to a lifted lambda that captures variables,
    /// returns its link name; else null. A capturing closure's environment lives
    /// in the function that created it, so returning one would dangle.
    fn capturingClosureLink(self: *Checker, expr: ast.Expr) ?[]const u8 {
        if (expr.kind != .ident) return null;
        const id = self.resolveSymbol(expr.kind.ident) orelse return null;
        const link = self.symbols.symbol(id).link_name;
        if (self.env.lambda_captures.get(link)) |caps| if (caps.len > 0) return link;
        return null;
    }

    /// At a lifted lambda's definition site, resolve which of its free variables
    /// are enclosing locals — those become its captures (recorded by-value with
    /// their types). Resolved once per lambda.
    fn resolveLambdaCaptures(self: *Checker, link: []const u8) SemanticError!void {
        const frees = self.env.lambda_free.get(link) orelse return;
        if (self.env.lambda_captures.contains(link)) return;
        var caps = std.ArrayList(Capture).empty;
        errdefer caps.deinit(self.allocator);
        for (frees) |fname| {
            if (self.lookupLocal(fname)) |fty| {
                try caps.append(self.allocator, .{ .name = fname, .ty = fty });
            }
        }
        try self.env.lambda_captures.put(link, try caps.toOwnedSlice(self.allocator));
    }

    fn checkFunction(self: *Checker, decl: ast.FunctionDecl) SemanticError!void {
        const previous_file = self.file;
        self.file = decl.file_name;
        defer self.file = previous_file;

        // Generic functions with unbound type params are checked per-instantiation, not here.
        if (decl.type_params.len > 0 and self.current_type_binding.len == 0) return;

        self.current_type_params = decl.type_params;
        defer self.current_type_params = &.{};
        self.current_output_params = decl.output_type_params;
        defer self.current_output_params = &.{};
        // Output type params (`-> $Acc`) are computed by the `where` block below,
        // so defer resolving the return type until after the binding is extended.
        const saved_binding = self.current_type_binding;
        defer self.current_type_binding = saved_binding;

        self.current_error_ty = if (decl.error_ty) |err| try self.typeFromErrorSpec(err) else null;
        self.capturing_locals.clearRetainingCapacity();
        self.current_has_arena_param = false;
        try self.pushScope();
        defer self.popScope();

        for (decl.params) |param| {
            if (param.is_type_param) continue; // type-only params aren't values in scope
            const param_ty = try self.typeFromRef(param.ty);
            if (self.isArenaPtr(param_ty)) self.current_has_arena_param = true;
            try self.validateBorrowParam(param_ty, param.span);
            if (param_ty == .borrow) {
                if (decl.body == null) {
                    self.emitError(param.span, "`borrow` parameters require a checked function body", .{});
                    return error.SemanticFailed;
                }
                try self.declareLocal(param.name, param_ty.borrow.*);
                try self.setLocalZoneOwner(param.name, .{
                    .name = param.name,
                    .scope_depth = 0,
                    .kind = .borrow,
                });
            } else {
                try self.declareLocal(param.name, param_ty);
            }
        }

        // A lifted lambda sees its captured variables as locals (by value), so its
        // body type-checks. Captures are resolved at the definition site; if that
        // hasn't run yet (e.g. a nested lambda) there are simply none.
        if (std.mem.startsWith(u8, decl.name, "__lambda_")) {
            if (self.resolveSymbol(decl.name)) |id| {
                if (self.env.lambda_captures.get(self.symbols.symbol(id).link_name)) |caps| {
                    for (caps) |c| try self.declareLocal(c.name, c.ty);
                }
            }
        }

        // A `where { … }` clause is comptime code (inspects `type_info(T)`, may
        // `reject`, and may compute output type params). Checked with the type
        // params in scope, per instantiation.
        if (decl.where_clause) |wc| {
            try self.checkBlock(wc);
            // Two-pass resolution: if a resolution VM is wired (strict pass-2),
            // run the predicate now — *before* the body — so a rejection is a
            // resolution error at the call site and suppresses spurious body
            // errors for a type the function never accepts.
            if (self.where_eval_fn) |eval| if (self.where_eval_ctx) |ctx| {
                if (self.current_type_binding.len > 0) {
                    if (eval(ctx, decl.file_name, wc, self.current_type_binding, decl.output_type_params, self.env.expr_types, self.allocator)) |msg| {
                        if (msg.len > 0) {
                            const span = self.current_inst_span orelse decl.span;
                            self.emitError(span, "`{s}` rejected for this type: {s}", .{ decl.name, msg });
                            return error.SemanticFailed;
                        }
                    }
                }
            };
            // Output type params (`-> $Acc`) were already computed at the call
            // site (`computeOutputParamsAtCall`) and stored in `inst.type_args`,
            // so the binding here already includes them — nothing to do.
        }

        self.current_return_ty = try self.typeFromRef(decl.return_ty);
        try self.rejectBorrowOutsideParam(self.current_return_ty, decl.return_ty.span());

        if (decl.body) |body| {
            try self.checkBlock(body);
            // #noreturn functions are allowed to not have explicit returns.
            const is_noreturn = hasAttr(decl.attrs, "noreturn");
            if (!is_noreturn and
                (self.current_return_ty != .void or self.current_error_ty != null) and
                !blockDefinitelyReturns(self, body))
            {
                self.emitError(decl.span, "function `{s}` may not return a value on all code paths", .{decl.name});
                return error.SemanticFailed;
            }
        }
    }

    fn checkBlock(self: *Checker, block: ast.Block) SemanticError!void {
        try self.pushScope();
        defer self.popScope();
        for (block.statements) |stmt| try self.checkStmt(stmt);
    }

    fn checkStmt(self: *Checker, stmt: ast.Stmt) SemanticError!void {
        switch (stmt) {
            .local_infer => |local| {
                const local_ty = try self.inferExpr(local.value);
                try self.declareLocal(local.name, local_ty);
                try self.setLocalZoneOwner(local.name, self.exprZoneOwner(local.value));
                if (self.valueIsCapturingClosure(local.value)) try self.capturing_locals.put(local.name, {});
            },
            .local_typed => |local| {
                const declared_ty = try self.typeFromRef(local.ty);
                try self.rejectBorrowOutsideParam(declared_ty, local.ty.span());
                if (try self.coerceEnumLiteral(local.value, declared_ty)) {
                    try self.declareLocal(local.name, declared_ty);
                    return;
                }
                const value_ty = try self.inferExprExpecting(local.value, declared_ty);
                if (!try self.compatible(value_ty, declared_ty)) {
                    self.emitError(local.value.span, "type mismatch: expected `{s}`, found `{s}`", .{
                        self.formatTy(declared_ty), self.formatTy(value_ty),
                    });
                    return error.SemanticFailed;
                }
                try self.declareLocal(local.name, declared_ty);
                try self.setLocalZoneOwner(local.name, self.exprZoneOwner(local.value));
                if (self.valueIsCapturingClosure(local.value)) try self.capturing_locals.put(local.name, {});
            },
            .assign => |assign| {
                // `Acc = <type>` inside a `where` block: an output-type assignment.
                // The RHS is a type expression, not a value — validate it resolves
                // and skip the normal value-assignment check.
                if (assign.target.kind == .ident) {
                    for (self.current_output_params) |p| {
                        if (std.mem.eql(u8, p, assign.target.kind.ident)) {
                            if (self.resolveExprAsType(assign.value) == null) {
                                self.emitError(assign.value.span, "output type param `{s}` must be assigned a type", .{p});
                                return error.SemanticFailed;
                            }
                            return;
                        }
                    }
                }
                try self.checkAssignTarget(assign.target);
                const target_ty = try self.inferExpr(assign.target);
                if (try self.coerceEnumLiteral(assign.value, target_ty)) return;
                const value_ty = try self.inferExpr(assign.value);
                if (!try self.compatible(value_ty, target_ty)) {
                    self.emitError(assign.value.span, "type mismatch in assignment: expected `{s}`, found `{s}`", .{
                        self.formatTy(target_ty), self.formatTy(value_ty),
                    });
                    return error.SemanticFailed;
                }
                if (self.exprZoneOwner(assign.value)) |owner| {
                    // Borrowed values still may not be retained inside an
                    // aggregate or through a pointer — that would outlive the
                    // borrow. (Plain `name = borrowed` is handled below.)
                    if (assign.target.kind != .ident and owner.kind == .borrow) {
                        self.emitError(assign.span, "borrowed value from `{s}` cannot be stored into an aggregate or pointer", .{owner.name});
                        return error.SemanticFailed;
                    }
                    // Find the variable the store ultimately mutates. Storing a
                    // zone-owned value into `list.data` makes `list` transitively
                    // hold zone memory, so `list` must not outlive that zone.
                    const root_name = rootVarName(assign.target) orelse {
                        const source = if (owner.kind == .borrow) "borrowed value" else "zone-owned value";
                        self.emitError(assign.span, "{s} from `{s}` cannot be stored through this target", .{ source, owner.name });
                        return error.SemanticFailed;
                    };
                    const target_scope = self.localScopeIndex(root_name) orelse 0;
                    if (target_scope < owner.scope_depth) {
                        self.emitError(assign.span, "zone-owned value from `{s}` cannot escape its zone", .{owner.name});
                        return error.SemanticFailed;
                    }
                    // Propagate ownership so later escape checks on `root_name`
                    // (return, outward assignment, non-borrow argument) catch any
                    // attempt to let the aggregate outlive the zone. For a plain
                    // `name = value` this replaces the owner; for an aggregate
                    // store, only escalate an as-yet-unowned variable.
                    if (assign.target.kind == .ident or self.lookupZoneOwner(root_name) == null) {
                        try self.setLocalZoneOwner(root_name, owner);
                    }
                } else if (assign.target.kind == .ident) {
                    try self.setLocalZoneOwner(assign.target.kind.ident, null);
                }
            },
            .return_stmt => |ret| {
                const actual_ty: Ty = if (ret.value) |value| try self.inferExprExpecting(value, self.current_return_ty) else .void;
                if (ret.value) |value| if (self.exprZoneOwner(value)) |owner| {
                    const source = if (owner.kind == .borrow) "borrowed value" else "zone-owned value";
                    self.emitError(ret.span, "{s} from `{s}` cannot be returned", .{ source, owner.name });
                    return error.SemanticFailed;
                };
                // A capturing closure's environment lives in this function, so
                // returning it would leave the captured values dangling — unless
                // the function passes an `*Arena` region the env can outlive on.
                if (ret.value) |value| if (self.valueIsCapturingClosure(value) and !self.current_has_arena_param) {
                    self.emitError(value.span, "a capturing closure cannot be returned: its captured environment lives in this function and would be left dangling (take an `*Arena` parameter so the closure's environment is allocated in the caller's region)", .{});
                    return error.SemanticFailed;
                };
                // Fallible tail-forward: `return inner();` where the function and the
                // returned value are BOTH fallible with compatible ok/err types —
                // pass the whole `{ok,err}` value through, no `?` needed.
                if (self.current_error_ty != null and actual_ty == .fallible) {
                    const f = actual_ty.fallible;
                    if (try self.compatible(f.ok.*, self.current_return_ty) and
                        try self.compatible(f.err.*, self.current_error_ty.?))
                    {
                        return; // accepted; IR forwards the fallible value directly
                    }
                }
                if (!try self.compatible(actual_ty, self.current_return_ty)) {
                    self.emitError(ret.span, "return type mismatch: expected `{s}`, found `{s}`", .{ self.formatTy(self.current_return_ty), self.formatTy(actual_ty) });
                    return error.SemanticFailed;
                }
            },
            .fail_stmt => |fail| try self.checkFail(fail),
            .if_stmt => |iff| {
                if (iff.binding) |binding| {
                    const bound_ty = try self.inferExpr(binding.value);
                    if (bound_ty != .optional) {
                        self.emitError(binding.value.span, "`if {s} :=` requires an optional type, found `{s}`", .{ binding.name, self.formatTy(bound_ty) });
                        return error.SemanticFailed;
                    }
                    const inner_ty = bound_ty.optional.*;
                    try self.pushScope();
                    defer self.popScope();
                    try self.declareLocal(binding.name, inner_ty);
                    const owner = self.exprZoneOwner(binding.value);
                    try self.setLocalZoneOwner(binding.name, owner);
                    if (iff.payload_binding) |payload_name| {
                        try self.declareLocal(payload_name, inner_ty);
                        try self.setLocalZoneOwner(payload_name, owner);
                    }
                    try self.checkBlock(iff.then_block);
                } else {
                    const cond_ty = try self.inferExpr(iff.condition);
                    const payload_ty: ?Ty = switch (cond_ty) {
                        .optional => |inner| inner.*,
                        else => null,
                    };
                    if (!cond_ty.isBool() and payload_ty == null) {
                        self.emitError(iff.condition.span, "`if` condition must be `bool` or optional, found `{s}`", .{self.formatTy(cond_ty)});
                        return error.SemanticFailed;
                    }
                    try self.pushScope();
                    defer self.popScope();
                    if (iff.payload_binding) |payload_name| {
                        try self.declareLocal(payload_name, payload_ty orelse .unknown);
                        try self.setLocalZoneOwner(payload_name, self.exprZoneOwner(iff.condition));
                    }
                    try self.checkBlock(iff.then_block);
                }
                if (iff.else_block) |else_block| try self.checkBlock(else_block);
            },
            .while_stmt => |while_stmt| {
                const cond_ty = try self.inferExpr(while_stmt.condition);
                const payload_ty: ?Ty = switch (cond_ty) {
                    .optional => |inner| inner.*,
                    else => null,
                };
                if (!cond_ty.isBool() and payload_ty == null) {
                    self.emitError(while_stmt.condition.span, "`while` condition must be `bool` or optional, found `{s}`", .{self.formatTy(cond_ty)});
                    return error.SemanticFailed;
                }
                if (while_stmt.payload_binding != null and payload_ty == null) {
                    self.emitError(while_stmt.condition.span, "`while … |x|` requires an optional condition, found `{s}`", .{self.formatTy(cond_ty)});
                    return error.SemanticFailed;
                }
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.pushScope();
                defer self.popScope();
                if (while_stmt.payload_binding) |payload_name| {
                    try self.declareLocal(payload_name, payload_ty orelse .unknown);
                    try self.setLocalZoneOwner(payload_name, self.exprZoneOwner(while_stmt.condition));
                }
                try self.checkBlock(while_stmt.body);
            },
            .for_range => |for_stmt| {
                const start_ty = try self.inferExpr(for_stmt.start);
                const end_ty = try self.inferExpr(for_stmt.end);
                if (!start_ty.isInteger() or !end_ty.isInteger() or
                    !try self.compatible(end_ty, start_ty))
                {
                    self.emitError(for_stmt.span, "range bounds must have compatible integer types", .{});
                    return error.SemanticFailed;
                }
                try self.pushScope();
                defer self.popScope();
                try self.declareLocal(for_stmt.binding, start_ty);
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.checkBlock(for_stmt.body);
            },
            .for_slice => |for_stmt| {
                const iter_ty = try self.inferExpr(for_stmt.iter);
                const elem_ty = switch (iter_ty) {
                    .slice => |elem| elem.*,
                    .array => |array| array.elem.*,
                    else => blk: {
                        // Iterator protocol: a `next(self: *Self) -> ?T` method.
                        // `for x in it` then loops as `while it.next() |x|`.
                        if (self.resolveExtensionMethod("next", iter_ty)) |m| {
                            if (m.sig.return_ty == .optional and m.sig.params.len >= 1 and
                                (m.sig.params[0].ty == .pointer))
                            {
                                if (for_stmt.by_ref) {
                                    self.emitError(for_stmt.iter.span, "`for &x in …` is not supported over an iterator (next returns a value)", .{});
                                    return error.SemanticFailed;
                                }
                                try self.env.iterator_fors.put(for_stmt.iter.id, m.id);
                                break :blk m.sig.return_ty.optional.*;
                            }
                        }
                        self.emitError(for_stmt.iter.span, "for loop requires a slice, an array, or a type with a `next(self: *Self) -> ?T` method", .{});
                        return error.SemanticFailed;
                    },
                };
                try self.pushScope();
                defer self.popScope();
                try self.declareLocal(for_stmt.binding, if (for_stmt.by_ref) try self.ptrTo(elem_ty) else elem_ty);
                if (for_stmt.by_ref) try self.setLocalZoneOwner(for_stmt.binding, self.exprZoneOwner(for_stmt.iter));
                if (for_stmt.index_binding) |name| try self.declareLocal(name, .usize);
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.checkBlock(for_stmt.body);
            },
            .unsafe_block => |unsafe_block| {
                self.unsafe_depth += 1;
                defer self.unsafe_depth -= 1;
                try self.checkBlock(unsafe_block);
            },
            .break_stmt => |span| if (self.loop_depth == 0) {
                self.emitError(span, "`break` outside of a loop", .{});
                return error.SemanticFailed;
            },
            .continue_stmt => |span| if (self.loop_depth == 0) {
                self.emitError(span, "`continue` outside of a loop", .{});
                return error.SemanticFailed;
            },
            .zone_block => |zb| {
                if (!std.mem.eql(u8, zb.kind, "Arena")) {
                    self.emitError(zb.span, "unsupported zone kind `{s}`; only `Arena` is currently defined", .{zb.kind});
                    return error.SemanticFailed;
                }
                for (self.active_zones.items) |zone| {
                    if (std.mem.eql(u8, zone.name, zb.name)) {
                        self.emitError(zb.span, "nested zone name `{s}` shadows an active zone", .{zb.name});
                        return error.SemanticFailed;
                    }
                }
                try self.pushScope();
                defer self.popScope();
                // The handle is a real `std.heap.Arena`, so every Arena method
                // (alloc/alloc_bytes/dupe/new/…) resolves by ordinary UFCS; the
                // escape checker still keys ownership off the zone name.
                try self.declareLocal(zb.name, self.arenaTy());
                try self.active_zones.append(self.allocator, .{
                    .name = zb.name,
                    .scope_depth = self.scope_stack.items.len - 1,
                });
                defer _ = self.active_zones.pop();
                try self.checkBlock(zb.body);
            },
            .defer_stmt => |ds| try self.checkBlock(ds.body),
            .match_stmt => |m| try self.checkMatch(m),
            .comptime_if => |ci| try self.checkComptimeIf(ci),
            .comptime_run => |block| {
                // Type-check the block for correctness even if we don't execute it yet.
                try self.checkBlock(block);
            },
            .insert_stmt => |ins| try self.checkInsert(ins),
            // Expanded away by the macroexpand pass; reaching sema means the
            // bounds were not compile-time evaluable.
            .comptime_for => |cf| {
                self.emitError(cf.span, "`#for` bounds must be compile-time integer constants", .{});
                return error.SemanticFailed;
            },
            .expr => |expr| {
                // `#must_use`: a bare call statement discards the result — error.
                // (Use `x := f()` or `_ := f()` to consume it.)
                if (self.mustUseCallee(expr)) |fname| {
                    self.emitError(expr.span, "the result of `{s}` must be used (`#must_use`) — assign it or use `_ := …`", .{fname});
                    return error.SemanticFailed;
                }
                try self.checkExpr(expr);
            },
        }
    }

    /// `#insert <operand>;` — a literal `#quote` block has its statements
    /// spliced into the CURRENT scope (so their locals are visible to following
    /// statements) and re-checked here. A computed operand must evaluate to an
    /// `AstBlock`: the two-pass pipeline runs it on the VM, reifies the result,
    /// and re-checks the spliced code in pass 2.
    fn checkInsert(self: *Checker, ins: ast.InsertStmt) SemanticError!void {
        switch (ins.operand.kind) {
            .quote => |block| {
                for (block.statements) |stmt| try self.checkStmt(stmt);
            },
            else => {
                const ty = try self.inferExpr(ins.operand);
                const ok = switch (ty) {
                    .named => |id| std.mem.eql(u8, self.symbols.symbol(id).name, "AstBlock"),
                    .unknown => true,
                    else => false,
                };
                if (!ok) {
                    self.emitError(ins.span, "#insert operand must be a `#quote {{ ... }}` block or evaluate to an `AstBlock`", .{});
                    return error.SemanticFailed;
                }
            },
        }
    }

    fn checkExpr(self: *Checker, expr: ast.Expr) SemanticError!void {
        _ = try self.inferExpr(expr);
    }

    fn inferExpr(self: *Checker, expr: ast.Expr) SemanticError!Ty {
        const ty: Ty = switch (expr.kind) {
            .ident => |name| {
                // Compile-time pseudo-modules return unknown so field access works.
                if (std.mem.eql(u8, name, "TARGET")) return .unknown;
                if (isBuiltinValue(name)) return .void;
                if (std.mem.startsWith(u8, name, ".")) return .error_ty;
                if (self.lookupLocal(name)) |local_ty| return local_ty;
                if (self.resolveTypeParam(name)) |type_param_ty| return type_param_ty;
                if (self.resolveSymbol(name)) |id| {
                    try self.env.expr_symbols.put(expr.id, id);
                    // Record the resolved type for this reference. The `.ident`
                    // arm returns early (bypassing the central `expr_types.put`
                    // below), so without this a reference to a top-level const
                    // carries no recorded type — IR lowering then falls back to
                    // `.unknown`, which becomes a pointer (e.g. `to := SA` for a
                    // `usize` const mistyped `to` as a pointer → `add ptr` ICE).
                    const sym_ty = self.env.get(id) orelse Ty{ .named = id };
                    try self.env.expr_types.put(expr.id, sym_ty);
                    // A reference to a lifted lambda is its definition site:
                    // resolve which of its free vars are enclosing locals (the
                    // captures) against THIS scope, for the body check + IR env.
                    try self.resolveLambdaCaptures(self.symbols.symbol(id).link_name);
                    return sym_ty;
                }
                if (fromBuiltinName(name)) |builtin_ty| return builtin_ty;
                self.emitError(expr.span, "unknown name `{s}`", .{name});
                return error.SemanticFailed;
            },
            .unsafe_expr => |inner| blk: {
                self.unsafe_depth += 1;
                defer self.unsafe_depth -= 1;
                break :blk try self.inferExpr(inner.*);
            },
            .run_expr => |inner| try self.inferRunExpr(inner.*),
            // A `#quote { ... }` block in value position materializes to an
            // `AstBlock` value. (As an `#insert` operand it takes a different
            // path — checkInsert — and its statements are checked there.)
            .quote => blk: {
                const id = self.resolveSymbol("AstBlock") orelse {
                    self.emitError(expr.span, "`#quote {{ ... }}` requires the ast.* metaprogramming types", .{});
                    return error.SemanticFailed;
                };
                try self.env.expr_symbols.put(expr.id, id);
                break :blk self.env.get(id) orelse .{ .named = id };
            },
            // `#quote(expr)` in value position materializes to an `AstExpr`
            // value (its inner expression is quoted DATA, not type-checked).
            .quote_expr => blk: {
                const id = self.resolveSymbol("AstExpr") orelse {
                    self.emitError(expr.span, "`#quote(...)` requires the ast.* metaprogramming types", .{});
                    return error.SemanticFailed;
                };
                try self.env.expr_symbols.put(expr.id, id);
                break :blk self.env.get(id) orelse .{ .named = id };
            },
            // A `$`-splice that survives macro expansion is a misuse: splices only
            // mean something inside a `macro`'s `return #quote {{ ... }}` template,
            // where `$name` names one of the macro's parameters.
            .splice => {
                self.emitError(expr.span, "`$name` splice only works inside a `macro` template (its `return #quote {{ ... }}`), and must name a macro parameter", .{});
                return error.SemanticFailed;
            },
            // `#parse(expr)` yields code (an `AstBlock`); only useful as an
            // `#insert` operand. The inner expression must produce a string,
            // which is evaluated and parsed by the two-pass pipeline.
            .parse_expr => |inner| blk: {
                _ = try self.inferExpr(inner.*);
                const id = self.resolveSymbol("AstBlock") orelse {
                    self.emitError(expr.span, "`#parse` requires the ast.* metaprogramming types", .{});
                    return error.SemanticFailed;
                };
                break :blk self.env.get(id) orelse .{ .named = id };
            },
            .force_unwrap => |inner| blk: {
                const ty = try self.inferExpr(inner.*);
                break :blk switch (ty) {
                    .optional => |p| p.*,
                    .fallible => |f| f.ok.*,
                    else => {
                        self.emitError(expr.span, "`!!` requires an optional or fallible type, found `{s}`", .{self.formatTy(ty)});
                        return error.SemanticFailed;
                    },
                };
            },
            .nil_coalesce => |nc| blk: {
                const lhs_ty = try self.inferExpr(nc.value.*);
                const inner_ty: Ty = switch (lhs_ty) {
                    .optional => |p| p.*,
                    .fallible => |f| f.ok.*,
                    else => {
                        self.emitError(nc.value.span, "`??` requires an optional or fallible left-hand side, found `{s}`", .{self.formatTy(lhs_ty)});
                        return error.SemanticFailed;
                    },
                };
                const default_ty = try self.inferExpr(nc.default.*);
                if (!try self.compatible(default_ty, inner_ty)) {
                    self.emitError(nc.default.span, "`??` default type `{s}` incompatible with `{s}`", .{ self.formatTy(default_ty), self.formatTy(inner_ty) });
                    return error.SemanticFailed;
                }
                break :blk inner_ty;
            },
            .as_cast => |cast| blk: {
                const from_ty = try self.inferExpr(cast.value.*);
                const to_ty = try self.typeFromRef(cast.to);
                if (try self.interfaceCoercion(from_ty, to_ty)) break :blk to_ty;
                const pointer_cast = isPointerTy(from_ty) or isPointerTy(to_ty);
                // Allow casting between a `distinct` type and its recorded underlying type,
                // in either direction (e.g. `UserId :: distinct i32;` <-> `i32`).
                var distinct_cast = false;
                switch (from_ty) {
                    .named => |sym| {
                        if (self.env.distinct_types.get(sym)) |underlying| {
                            if (sameTy(underlying, to_ty)) distinct_cast = true;
                        }
                    },
                    else => {},
                }
                if (!distinct_cast) {
                    switch (to_ty) {
                        .named => |sym| {
                            if (self.env.distinct_types.get(sym)) |underlying| {
                                if (sameTy(underlying, from_ty)) distinct_cast = true;
                            }
                        },
                        else => {},
                    }
                }
                // A function pointer is a pointer-sized value: allow reinterpreting
                // it as another fn-pointer signature, a data pointer, or an integer
                // address (and back). Needed for thin C callbacks / thread entries
                // where the OS signature is fixed (`fn(*void) -> u32`).
                const fn_ptr_cast = from_ty == .fn_ptr or to_ty == .fn_ptr;
                const reinterpretable = struct {
                    fn ok(t: Ty) bool {
                        return t == .fn_ptr or isPointerTy(t) or t.isInteger();
                    }
                };
                const valid = distinct_cast or
                    (from_ty.isNumeric() and to_ty.isNumeric()) or
                    (from_ty.isInteger() and to_ty == .bool) or
                    (from_ty == .bool and to_ty.isInteger()) or
                    (pointer_cast and (isPointerTy(from_ty) or from_ty.isInteger()) and
                        (isPointerTy(to_ty) or to_ty.isInteger())) or
                    (fn_ptr_cast and reinterpretable.ok(from_ty) and reinterpretable.ok(to_ty));
                if (!valid) {
                    self.emitError(expr.span, "cannot cast `{s}` to `{s}`", .{
                        self.formatTy(from_ty), self.formatTy(to_ty),
                    });
                    return error.SemanticFailed;
                }
                if (pointer_cast or fn_ptr_cast) try self.requireUnsafe(expr.span, "pointer cast");
                break :blk to_ty;
            },
            .type_ref => |type_ref| try self.typeFromRef(type_ref),
            .int => |text| blk: {
                // A suffix-shaped trailing segment that isn't a real width is a
                // mistake (`0u128`, `0u9`), not a polymorphic literal — flag it
                // rather than silently dropping the suffix.
                const suffix = intLiteralSuffix(text);
                if (suffix.len != 0 and !isValidIntSuffix(suffix))
                    self.reportUnknownType(suffix, expr.span);
                break :blk intLiteralType(text);
            },
            .float => |text| blk: {
                const suffix = floatLiteralSuffix(text);
                if (suffix.len != 0 and !std.mem.eql(u8, suffix, "f32") and !std.mem.eql(u8, suffix, "f64"))
                    self.emitError(expr.span, "unsupported float width `{s}`: skarn floats are `f32` or `f64`", .{suffix});
                break :blk floatLiteralType(text);
            },
            .string => try self.sliceOf(.u8),
            .bool => .bool,
            .null => .null_ptr,
            .compound_literal => |values| blk: {
                for (values) |value| _ = try self.inferExpr(value);
                break :blk .unknown;
            },
            .struct_literal => |fields| blk: {
                for (fields) |f| _ = try self.inferExpr(f.value);
                break :blk .unknown;
            },
            .unary => |unary| switch (unary.op) {
                .address_of => try self.ptrTo(try self.inferExpr(unary.expr.*)),
                .deref => blk: {
                    const inner = try self.inferExpr(unary.expr.*);
                    break :blk switch (inner) {
                        .pointer, .const_ptr => |p| p.*,
                        .slice => |p| p.*,
                        else => {
                            self.emitError(expr.span, "cannot dereference value of type `{s}`", .{self.formatTy(inner)});
                            return error.SemanticFailed;
                        },
                    };
                },
                .neg => try self.inferExpr(unary.expr.*),
                .not => blk: {
                    const inner = try self.inferExpr(unary.expr.*);
                    if (!inner.isBool()) {
                        self.emitError(expr.span, "`!` requires a `bool` operand, found `{s}`", .{self.formatTy(inner)});
                        return error.SemanticFailed;
                    }
                    break :blk .bool;
                },
                .bit_not => blk: {
                    const inner = try self.inferExpr(unary.expr.*);
                    if (!inner.isInteger()) {
                        self.emitError(expr.span, "`~` requires an integer operand, found `{s}`", .{self.formatTy(inner)});
                        return error.SemanticFailed;
                    }
                    break :blk inner;
                },
            },
            .binary => |binary| blk: {
                const left = try self.inferExpr(binary.left.*);
                const right = try self.inferExpr(binary.right.*);
                const op_sym: []const u8 = switch (binary.op) {
                    .equal => "==",
                    .not_equal => "!=",
                    .less => "<",
                    .le => "<=",
                    .gt => ">",
                    .ge => ">=",
                    .and_and => "&&",
                    .or_or => "||",
                    .bit_and => "&",
                    .bit_or => "|",
                    .bit_xor => "^",
                    .shl => "<<",
                    .shr => ">>",
                    .add => "+",
                    .sub => "-",
                    .mul => "*",
                    .div => "/",
                    .rem => "%",
                    .wrap_add => "+%",
                    .wrap_sub => "-%",
                    .wrap_mul => "*%",
                };
                const result: Ty = switch (binary.op) {
                    .equal, .not_equal => if ((left.isNumeric() and right.isNumeric()) or left == .error_ty or right == .error_ty or try self.compatible(left, right) or try self.compatible(right, left)) .bool else {
                        self.emitError(expr.span, "operator `{s}` cannot be applied to types `{s}` and `{s}`", .{ op_sym, self.formatTy(left), self.formatTy(right) });
                        return error.SemanticFailed;
                    },
                    .less, .le, .gt, .ge => if (left.isNumeric() and right.isNumeric()) .bool else {
                        self.emitError(expr.span, "operator `{s}` requires numeric operands, found `{s}` and `{s}`", .{ op_sym, self.formatTy(left), self.formatTy(right) });
                        return error.SemanticFailed;
                    },
                    .and_and, .or_or => if (left.isBool() and right.isBool()) .bool else {
                        self.emitError(expr.span, "operator `{s}` requires `bool` operands, found `{s}` and `{s}`", .{ op_sym, self.formatTy(left), self.formatTy(right) });
                        return error.SemanticFailed;
                    },
                    .bit_and, .bit_or, .bit_xor, .shl, .shr => if (left.isInteger() and right.isInteger()) left else {
                        self.emitError(expr.span, "operator `{s}` requires integer operands, found `{s}` and `{s}`", .{ op_sym, self.formatTy(left), self.formatTy(right) });
                        return error.SemanticFailed;
                    },
                    .add, .sub, .mul, .div, .rem => if (left.isNumeric() and right.isNumeric()) left else {
                        self.emitError(expr.span, "operator `{s}` requires numeric operands, found `{s}` and `{s}`", .{ op_sym, self.formatTy(left), self.formatTy(right) });
                        return error.SemanticFailed;
                    },
                    // Wrapping arithmetic is integer-only (two's-complement).
                    .wrap_add, .wrap_sub, .wrap_mul => if (left.isInteger() and right.isInteger()) left else {
                        self.emitError(expr.span, "operator `{s}` requires integer operands, found `{s}` and `{s}`", .{ op_sym, self.formatTy(left), self.formatTy(right) });
                        return error.SemanticFailed;
                    },
                };
                break :blk result;
            },
            .try_expr => |try_expr| blk: {
                const value_ty = try self.inferExpr(try_expr.value.*);
                if (self.current_error_ty == null) {
                    self.emitError(expr.span, "`?` used in a function without a `!` error return type", .{});
                    return error.SemanticFailed;
                }
                break :blk switch (value_ty) {
                    .fallible => |fallible| blskarn: {
                        if (!try self.compatible(fallible.err.*, self.current_error_ty.?)) {
                            self.emitError(expr.span, "`?` error type `{s}` is not compatible with function error type `{s}`", .{
                                self.formatTy(fallible.err.*), self.formatTy(self.current_error_ty.?),
                            });
                            return error.SemanticFailed;
                        }
                        break :blskarn fallible.ok.*;
                    },
                    else => {
                        self.emitError(try_expr.value.span, "`?` requires a fallible expression, found `{s}`", .{self.formatTy(value_ty)});
                        return error.SemanticFailed;
                    },
                };
            },
            .catch_expr => |catch_expr| blk: {
                const value_ty = try self.inferExpr(catch_expr.value.*);
                const fallible = switch (value_ty) {
                    .fallible => |f| f,
                    else => {
                        self.emitError(catch_expr.value.span, "`catch` requires a fallible expression, found `{s}`", .{self.formatTy(value_ty)});
                        return error.SemanticFailed;
                    },
                };
                try self.pushScope();
                defer self.popScope();
                try self.declareLocal(catch_expr.err_name, fallible.err.*);
                try self.checkBlock(catch_expr.handler);
                break :blk fallible.ok.*;
            },
            .call => |call| blk: {
                const call_ty = try self.inferCall(call);
                // `inferCall` already infers value arguments. Re-infer only those
                // not yet typed, and skip any the callee consumed as a *type*
                // argument (e.g. `arena.new(List(i32))`, `truncate_to(u32, x)`),
                // which `inferTypeArg` records — re-inferring those as values
                // would wrongly treat a type name as a function call.
                for (call.args) |arg| switch (arg) {
                    .positional => |value| if (!self.env.expr_types.contains(value.id)) {
                        _ = try self.inferExpr(value);
                    },
                    .named => |named| if (!self.env.expr_types.contains(named.value.id)) {
                        _ = try self.inferExpr(named.value);
                    },
                };
                break :blk call_ty;
            },
            .field => |field| blk: {
                const base_ty = try self.inferExpr(field.base.*);
                // `.len`/`.ptr` are slice/array builtins — but a real struct field
                // of that name takes precedence (so a struct CAN have `len`/`ptr`).
                if (std.mem.eql(u8, field.name, "len") and !self.structHasField(base_ty, "len")) break :blk .usize;
                if (std.mem.eql(u8, field.name, "ptr") and !self.structHasField(base_ty, "ptr")) break :blk switch (base_ty) {
                    .slice => |inner| try self.ptrTo(inner.*),
                    .array => |array| try self.ptrTo(array.elem.*),
                    else => {
                        self.emitError(expr.span, "`.ptr` is only valid on slices and arrays, found `{s}`", .{self.formatTy(base_ty)});
                        return error.SemanticFailed;
                    },
                };
                if (base_ty == .fallible) {
                    if (std.mem.eql(u8, field.name, "ok")) break :blk base_ty.fallible.ok.*;
                    if (std.mem.eql(u8, field.name, "err")) break :blk base_ty.fallible.err.*;
                }
                break :blk try self.fieldType(base_ty, field.name, expr.span);
            },
            .scope_access => |sa| blk: {
                // `core::<location constant>` (value position, no parens): `line`/
                // `column` are `i32`; `file`/`func`/`module` are `[]const u8`.
                if (isCoreNamespace(sa)) {
                    const m = sa.member;
                    if (std.mem.eql(u8, m, "line") or std.mem.eql(u8, m, "column")) break :blk .i32;
                    if (std.mem.eql(u8, m, "file") or std.mem.eql(u8, m, "func") or std.mem.eql(u8, m, "module") or
                        std.mem.eql(u8, m, "os") or std.mem.eql(u8, m, "arch"))
                        break :blk try self.sliceOf(.u8);
                    self.emitError(expr.span, "unknown core builtin `{s}`", .{m});
                    return error.SemanticFailed;
                }
                const id = self.resolveScopeAccessSymbol(sa) orelse {
                    self.emitError(expr.span, "no namespace member `{s}` is visible here", .{sa.member});
                    return error.SemanticFailed;
                };
                try self.env.expr_symbols.put(expr.id, id);
                break :blk self.env.get(id) orelse .{ .named = id };
            },
            .index => |index| blk: {
                const base_ty = try self.inferExpr(index.base.*);
                _ = try self.inferExpr(index.index.*);
                break :blk switch (base_ty) {
                    .array => |array| array.elem.*,
                    .slice => |inner| inner.*,
                    .pointer, .const_ptr => |inner| inner.*,
                    .unknown => .unknown,
                    else => {
                        self.emitError(index.base.span, "cannot index into value of type `{s}`", .{self.formatTy(base_ty)});
                        return error.SemanticFailed;
                    },
                };
            },
            .slice => |slice| blk: {
                const base_ty = try self.inferExpr(slice.base.*);
                if (slice.start) |start| _ = try self.inferExpr(start.*);
                if (slice.end) |end| _ = try self.inferExpr(end.*);
                break :blk switch (base_ty) {
                    .array => |array| .{ .slice = array.elem },
                    .slice => base_ty,
                    else => {
                        self.emitError(slice.base.span, "cannot slice value of type `{s}`", .{self.formatTy(base_ty)});
                        return error.SemanticFailed;
                    },
                };
            },
            .match_expr => |me| try self.inferMatchExpr(me, null),
            .if_expr => |ie| try self.inferIfExpr(ie, null),
        };
        try self.env.expr_types.put(expr.id, ty);
        return ty;
    }

    /// `match subject { pattern => value, ... }` as a value: each arm yields a
    /// value, all arms must unify to one type, and the match must be exhaustive
    /// (it produces a value on every path). Mirrors `checkMatch`'s pattern rules.
    fn inferMatchExpr(self: *Checker, me: *const ast.MatchExpr, expected: ?Ty) SemanticError!Ty {
        if (me.arms.len == 0) {
            self.emitError(me.span, "match expression needs at least one arm", .{});
            return error.SemanticFailed;
        }
        const subject_ty = try self.inferExpr(me.subject.*);
        const cls = self.classifyMatchSubject(subject_ty);
        if (cls.kind == .invalid) return self.invalidMatchSubject(me.subject.span);

        const covered = try self.allocator.alloc(bool, cls.variants.len);
        defer self.allocator.free(covered);
        @memset(covered, false);
        var catchall = false;
        // The result type — seeded from the expected context so untyped arm
        // values (`.{ … }`, bare `.variant`) get a target; otherwise the first
        // arm establishes it.
        var result_ty: ?Ty = expected;

        for (me.arms) |arm| {
            const bind = try self.checkMatchPattern(cls, subject_ty, arm, covered, &catchall);
            try self.pushScope();
            defer self.popScope();
            if (bind) |b| try self.declareLocal(b.name, b.ty);
            try self.checkMatchGuard(arm.guard);

            const arm_ty: Ty = if (result_ty) |rt| blk: {
                // A bare `.variant` literal resolves against the known result type.
                if (try self.coerceEnumLiteral(arm.value, rt)) break :blk rt;
                const t = try self.inferExpr(arm.value);
                if (!try self.compatible(t, rt)) {
                    self.emitError(arm.value.span, "match arms have incompatible types: `{s}` vs `{s}`", .{ self.formatTy(rt), self.formatTy(t) });
                    return error.SemanticFailed;
                }
                break :blk t;
            } else try self.inferExpr(arm.value);

            if (result_ty == null) result_ty = arm_ty;
        }

        try self.recordMatchExhaustiveness(me.span, cls, covered, catchall, true);
        return result_ty orelse .void;
    }

    /// Infer an expression in a context with a known expected type, threading it
    /// into a `match` expression so untyped arm values type-check (bidirectional).
    fn inferExprExpecting(self: *Checker, expr: ast.Expr, expected: Ty) SemanticError!Ty {
        if (expr.kind == .match_expr) {
            const ty = try self.inferMatchExpr(expr.kind.match_expr, expected);
            try self.env.expr_types.put(expr.id, ty);
            return ty;
        }
        if (expr.kind == .if_expr) {
            const ty = try self.inferIfExpr(expr.kind.if_expr, expected);
            try self.env.expr_types.put(expr.id, ty);
            return ty;
        }
        return self.inferExpr(expr);
    }

    /// `if cond { a } else { b }` as a value: the condition is `bool` and the two
    /// branches must unify. `expected` seeds the branch types so untyped branch
    /// values (`.{…}`, bare `.variant`) get a target (bidirectional, like match).
    fn inferIfExpr(self: *Checker, ie: *const ast.IfExpr, expected: ?Ty) SemanticError!Ty {
        const cond_ty = try self.inferExpr(ie.cond);
        if (!cond_ty.isBool()) {
            self.emitError(ie.cond.span, "if-expression condition must be `bool`, found `{s}`", .{self.formatTy(cond_ty)});
            return error.SemanticFailed;
        }
        const then_ty: Ty = if (expected) |rt| blk: {
            if (try self.coerceEnumLiteral(ie.then_value, rt)) break :blk rt;
            const t = try self.inferExprExpecting(ie.then_value, rt);
            if (!try self.compatible(t, rt)) break :blk rt;
            break :blk t;
        } else try self.inferExpr(ie.then_value);
        // The else branch must be compatible with the then branch's type.
        if (try self.coerceEnumLiteral(ie.else_value, then_ty)) return then_ty;
        const else_ty = try self.inferExprExpecting(ie.else_value, then_ty);
        if (!try self.compatible(else_ty, then_ty) and !try self.compatible(then_ty, else_ty)) {
            self.emitError(ie.else_value.span, "if-expression branches have incompatible types: `{s}` vs `{s}`", .{ self.formatTy(then_ty), self.formatTy(else_ty) });
            return error.SemanticFailed;
        }
        return then_ty;
    }

    fn inferCall(self: *Checker, call: ast.CallExpr) SemanticError!Ty {
        // Namespace function call: `io::print(...)`. The reserved `core::` namespace
        // (compiler builtins) is NOT a real module — it falls through to the builtin
        // dispatch below, keyed on the member name (`core::sizeof` → `sizeof`).
        if (call.callee.kind == .scope_access and !isCoreNamespace(call.callee.kind.scope_access)) {
            const sa = call.callee.kind.scope_access;
            const id = self.resolveScopeAccessSymbol(sa) orelse {
                self.emitError(call.callee.span, "no namespace member `{s}` is visible here", .{sa.member});
                return error.SemanticFailed;
            };
            if (self.symbols.symbol(id).kind != .function) {
                self.emitError(call.callee.span, "`{s}` is not callable", .{sa.member});
                return error.SemanticFailed;
            }
            const sig = self.env.fn_sigs.get(id) orelse return error.SemanticFailed;
            try self.env.expr_symbols.put(call.callee.id, id);
            if (sig.type_params.len > 0) return try self.inferGenericCall(id, sa.member, sig, call);
            return try self.inferDirectCall(id, sa.member, sig, call);
        }

        if (call.callee.kind == .field) {
            const fld = call.callee.kind.field;

            // `EnumType.variant(payload)` constructs an enum value. Checked before
            // `inferExpr(fld.base)`, which would reject a bare type name as a value.
            if (try self.inferVariantConstruct(call)) |ty| return ty;

            const base_ty = try self.inferExpr(fld.base.*);

            // `b.f(args)` where `f` is a fn-pointer struct field → an indirect
            // (thin) call through the stored function pointer.
            if (self.fieldTypeOpt(base_ty, fld.name)) |field_ty| {
                if (field_ty == .fn_ptr) {
                    const fp = field_ty.fn_ptr;
                    for (call.args, 0..) |arg, i| {
                        const arg_expr = switch (arg) {
                            .positional => |e| e,
                            .named => |n| n.value,
                        };
                        const arg_ty = try self.inferExpr(arg_expr);
                        if (i < fp.params.len and !try self.compatible(arg_ty, fp.params[i])) {
                            self.emitError(arg_expr.span, "argument {d}: expected `{s}`, found `{s}`", .{ i + 1, self.formatTy(fp.params[i]), self.formatTy(arg_ty) });
                            return error.SemanticFailed;
                        }
                    }
                    try self.env.expr_types.put(call.callee.id, field_ty);
                    return fp.ret.*;
                }
            }

            // `zone_handle.free(ptr)` — a bump arena frees in bulk on zone exit,
            // so this is a validated no-op: it only checks `ptr` is owned by this
            // zone (and not a borrow). Every *other* Arena method falls through to
            // ordinary UFCS resolution below. (A manually managed Arena local has
            // no `free` and no escape restrictions; it isn't an active zone.)
            if (std.mem.eql(u8, fld.name, "free") and
                fld.base.kind == .ident and self.isActiveZone(fld.base.kind.ident))
            {
                const zone_name = fld.base.kind.ident;
                if (call.args.len > 0) {
                    const ptr_expr = switch (call.args[0]) {
                        .positional => |value| value,
                        .named => |named| named.value,
                    };
                    const owner = self.exprZoneOwner(ptr_expr) orelse {
                        self.emitError(ptr_expr.span, "`{s}.free` requires a value owned by that arena", .{zone_name});
                        return error.SemanticFailed;
                    };
                    if (owner.kind == .borrow) {
                        self.emitError(ptr_expr.span, "borrowed value from `{s}` cannot be explicitly freed", .{owner.name});
                        return error.SemanticFailed;
                    }
                    if (!std.mem.eql(u8, owner.name, zone_name)) {
                        self.emitError(ptr_expr.span, "value is owned by zone `{s}`, not `{s}`", .{ owner.name, zone_name });
                        return error.SemanticFailed;
                    }
                }
                try self.env.expr_types.put(call.callee.id, .zone_handle);
                return .void;
            }
            if (self.interfaceFromPointer(base_ty)) |interface_id| {
                if (self.findInterfaceMethod(interface_id, fld.name)) |method| {
                    if (method.params.len == 0 or call.args.len != method.params.len - 1) {
                        const expected_count = if (method.params.len > 0) method.params.len - 1 else 0;
                        self.emitError(call.callee.span, "`{s}` expects {d} argument(s)", .{ fld.name, expected_count });
                        return error.SemanticFailed;
                    }
                    try self.checkNonEscapingArgument(fld.base.*, method.params[0].ty);
                    for (call.args, 0..) |arg, i| {
                        const arg_expr = switch (arg) {
                            .positional => |value| value,
                            .named => |named| named.value,
                        };
                        try self.checkNonEscapingArgument(arg_expr, method.params[i + 1].ty);
                        const arg_ty = try self.inferExpr(arg_expr);
                        if (!try self.compatible(arg_ty, method.params[i + 1].ty)) {
                            self.emitError(arg_expr.span, "argument {d} of `{s}`: expected `{s}`, found `{s}`", .{
                                i + 1,                                  fld.name,
                                self.formatTy(method.params[i + 1].ty), self.formatTy(arg_ty),
                            });
                            return error.SemanticFailed;
                        }
                    }
                    try self.env.expr_types.put(call.callee.id, .{ .fn_ptr = .{
                        .params = &.{},
                        .ret = try self.boxTy(method.return_ty),
                    } });
                    if (method.error_ty) |err_ty| {
                        return .{ .fallible = .{ .ok = try self.boxTy(method.return_ty), .err = try self.boxTy(err_ty) } };
                    }
                    return method.return_ty;
                }
            }
            if (self.resolveExtensionMethod(fld.name, base_ty)) |extension| {
                try self.env.extension_calls.put(call.callee.id, extension.id);
                const extension_call = try self.extensionCall(call, fld.base.*, extension.sig);
                if (extension.sig.type_params.len > 0) {
                    // Mangle the generic instantiation off the method's STRUCT-
                    // qualified name (`Vec.push`), not the bare member (`push`):
                    // two generic structs sharing a method name + type arg would
                    // otherwise collide on one symbol (`push__T_i32`) and emit
                    // calls with mismatched arity.
                    const qualified = self.symbols.symbol(extension.id).name;
                    return try self.inferGenericCallImpl(extension.id, qualified, extension.sig, extension_call, true);
                }
                return try self.inferDirectCallImpl(extension.id, fld.name, extension.sig, extension_call, true);
            }
            // `g.val()` where `g`'s concrete type *implements* an interface that
            // declares `val` — call the impl method directly (interface methods are
            // otherwise reachable only through a `*Interface` value). Also covers a
            // `$T: Iface`-bound generic at instantiation, where `T` is concrete.
            if (try self.resolveImplMethodCall(call, fld, base_ty)) |ret| return ret;
            if (!extensionLookupDeferred(base_ty)) {
                self.emitError(call.callee.span, "no visible method or extension function `{s}`", .{fld.name});
                return error.SemanticFailed;
            }
        }

        // A `core::<member>` callee reaches here (non-core namespaces returned
        // above); treat the member as the builtin name. `is_core` makes an unknown
        // member a hard error instead of falling through to user-symbol resolution.
        const is_core = call.callee.kind == .scope_access;
        const name = switch (call.callee.kind) {
            .ident => |n| n,
            .scope_access => |sa| coreRename(sa.member),
            else => return .unknown,
        };

        // Builtins live under `core::` — a bare call is an error pointing the user
        // at the namespaced form. (The `@panic` family + `__`-internals are exempt.)
        if (!is_core and call.callee.kind == .ident and isMigratedBuiltin(name)) {
            self.emitError(call.callee.span, "`{s}` is a compiler builtin — call it as `core::{s}`", .{ name, name });
            return error.SemanticFailed;
        }

        // ── Builtins ────────────────────────────────────────────────────
        // `core::panic(msg)` — the no-return panic intrinsic (maps to `@panic` in
        // IR). Other no-return forms (`@panic`, `exit`, `abort`) keep their handling.
        if (is_core and std.mem.eql(u8, name, "panic")) {
            for (call.args) |arg| {
                const v = switch (arg) { .positional => |p| p, .named => |n| n.value };
                _ = try self.inferExpr(v);
            }
            return .void;
        }
        // core::fn_ptr(f) — the raw thin function pointer of a top-level function,
        // typed `*void` so it can be handed to a C callback / thread entry (skarn's
        // ordinary fn value is a fat `{fn, env}` closure a C ABI cannot call). The
        // argument must be a plain function reference; it is resolved in IR.
        if (is_core and std.mem.eql(u8, name, "fn_ptr")) {
            if (call.args.len != 1) {
                self.emitError(call.callee.span, "`core::fn_ptr` takes exactly one function argument", .{});
                return error.SemanticFailed;
            }
            return try self.ptrTo(.void);
        }
        // core:: math/bit/memory families (Phase 2). Gated on `is_core` so a bare
        // user `min`/`max`/`abs` function is unaffected.
        if (is_core) {
            if (isCoreScalarBuiltin(name)) {
                var first_ty: Ty = .unknown;
                for (call.args, 0..) |arg, i| {
                    const v = switch (arg) { .positional => |p| p, .named => |n| n.value };
                    const t = try self.inferExpr(v);
                    if (i == 0) first_ty = t;
                }
                return first_ty;
            }
            if (std.mem.eql(u8, name, "cycle_count")) return .u64;
            if (std.mem.eql(u8, name, "memcpy") or std.mem.eql(u8, name, "memset") or
                std.mem.eql(u8, name, "prefetch") or std.mem.eql(u8, name, "trap") or
                std.mem.eql(u8, name, "unreachable"))
            {
                for (call.args) |arg| {
                    const v = switch (arg) { .positional => |p| p, .named => |n| n.value };
                    _ = try self.inferExpr(v);
                }
                return .void;
            }
        }
        // `require(T, Other)` — constraint composition. Its args are a type and a
        // constraint name, not values, so return before the argument checks.
        if (std.mem.eql(u8, name, "require")) return .void;
        // `typeid_of(T)` — a stable runtime type id (usize). Its arg is a type,
        // so return before the value-argument checks (like `type_info`).
        if (std.mem.eql(u8, name, "typeid_of")) return .usize;
        // `__str_cat(a, b)` — VM-native comptime string concat (no-import codegen
        // helper backing `CodeBuf`; the full `std.strings.StringBuilder` ALSO runs
        // at comptime now via host memory, but needs an explicit import).
        if (std.mem.eql(u8, name, "__str_cat")) {
            for (call.args) |arg| {
                const v = switch (arg) { .positional => |p| p, .named => |n| n.value };
                _ = try self.inferExpr(v);
            }
            return try self.sliceOf(.u8);
        }
        // `compiler_error(msg)` — a `#compiler` hook halts the build with a custom
        // diagnostic (whole-program validation). `compiler_remove(name)` — a hook
        // drops an existing top-level declaration (mutation; does not halt).
        if (std.mem.eql(u8, name, "compiler_error") or std.mem.eql(u8, name, "compiler_remove")) {
            for (call.args) |arg| {
                const v = switch (arg) { .positional => |p| p, .named => |n| n.value };
                _ = try self.inferExpr(v);
            }
            return .void;
        }
        if (isBuiltinValue(name)) for (call.args) |arg| {
            const value = switch (arg) {
                .positional => |positional| positional,
                .named => |named| named.value,
            };
            try self.checkNonEscapingArgument(value, null);
        };
        if (std.mem.eql(u8, name, "truncate_to")) return self.firstTypeArg(call) orelse error.SemanticFailed;
        if (std.mem.eql(u8, name, "sizeof")) return .usize;
        // Value-returning atomics (`load` + read-modify-write + compare-exchange)
        // yield the pointee type of the first (pointer) argument.
        if (std.mem.eql(u8, name, "atomic_load") or std.mem.eql(u8, name, "atomic_add") or
            std.mem.eql(u8, name, "atomic_sub") or std.mem.eql(u8, name, "atomic_and") or
            std.mem.eql(u8, name, "atomic_or") or std.mem.eql(u8, name, "atomic_xor") or
            std.mem.eql(u8, name, "atomic_max") or std.mem.eql(u8, name, "atomic_min") or
            std.mem.eql(u8, name, "atomic_nand") or
            std.mem.eql(u8, name, "atomic_exchange") or std.mem.eql(u8, name, "atomic_cas"))
        {
            if (call.args.len == 0) return .u32;
            const a0 = switch (call.args[0]) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            return switch (try self.inferExpr(a0)) {
                .pointer, .const_ptr => |inner| inner.*,
                else => .u32,
            };
        }
        if (std.mem.eql(u8, name, "atomic_store") or std.mem.eql(u8, name, "atomic_fence")) return .void;
        // Reflection builtins: only meaningful inside compile-time contexts
        // (#run / #if), where the comptime interpreter produces a concrete
        // value. Their static type is deferred, like the TARGET pseudo-module.
        if (std.mem.eql(u8, name, "type_name")) return try self.sliceOf(.u8);
        // `reject("msg")` — used in a `where` block to reject the instantiation.
        if (std.mem.eql(u8, name, "reject")) return .void;
        // `any(x)` wraps any value into a type-erased `Any` (the prelude struct).
        if (std.mem.eql(u8, name, "any")) {
            if (self.resolveSymbol("Any")) |id| {
                if (self.symbols.symbol(id).kind == .type) return .{ .named = id };
            }
            return .unknown;
        }
        // `type_info(T)` yields a matchable `TypeInfo` value (from the injected
        // reflection prelude), so `match`/field access type-check normally.
        if (std.mem.eql(u8, name, "type_info")) {
            if (self.resolveSymbol("TypeInfo")) |id| {
                if (self.symbols.symbol(id).kind == .type) return .{ .named = id };
            }
            return .unknown;
        }
        // `compiler_decls()` → `[]Decl`, the program's top-level declarations
        // (Phase 3). `Decl` comes from the injected compiler prelude.
        if (std.mem.eql(u8, name, "compiler_decls")) {
            const id = self.resolveSymbol("Decl") orelse return error.SemanticFailed;
            return try self.sliceOf(.{ .named = id });
        }
        // std.build intrinsics: artifact/require/option_flag return an id/flag
        // (i32), option_str returns `[]const u8`, the rest are side-effecting void.
        if (std.mem.eql(u8, name, "__build_artifact") or
            std.mem.eql(u8, name, "__build_require") or
            std.mem.eql(u8, name, "__build_optionflag"))
        {
            return .i32;
        }
        if (std.mem.eql(u8, name, "__build_optionstr")) {
            return try self.sliceOf(.u8);
        }
        if (std.mem.startsWith(u8, name, "__build_")) {
            return .void;
        }
        // Unsafe builtins — must be called from within an `unsafe` block.
        if (std.mem.eql(u8, name, "ptr_from_int")) {
            try self.requireUnsafe(call.callee.span, name);
            return self.firstTypeArg(call) orelse error.SemanticFailed;
        }
        // slice_from_raw_parts(T, ptr: *T, len: usize) -> []T — build a slice
        // value from a raw pointer and length. The fundamental allocator
        // primitive (std.heap.Arena). Unsafe: the caller guarantees `ptr`
        // addresses at least `len` valid, correctly-aligned `T` elements.
        if (std.mem.eql(u8, name, "slice_from_raw_parts")) {
            try self.requireUnsafe(call.callee.span, name);
            const elem = self.firstTypeArg(call) orelse return error.SemanticFailed;
            return try self.sliceOf(elem);
        }
        if (std.mem.eql(u8, name, "volatile_store")) {
            try self.requireUnsafe(call.callee.span, name);
            return .void;
        }
        if (std.mem.eql(u8, name, "unaligned_read")) {
            try self.requireUnsafe(call.callee.span, name);
            return self.firstTypeArg(call) orelse error.SemanticFailed;
        }
        if (std.mem.eql(u8, name, "asm")) {
            try self.requireUnsafe(call.callee.span, name);
            // Infer return type from first output constraint, e.g. outputs: { "=a"(isize) }
            for (call.args) |arg| {
                const n = switch (arg) {
                    .named => |n| n,
                    else => continue,
                };
                if (!std.mem.eql(u8, n.name, "outputs")) continue;
                const items = switch (n.value.kind) {
                    .compound_literal => |c| c,
                    else => continue,
                };
                if (items.len == 0) break;
                const first = items[0];
                if (first.kind != .call) break;
                const c_args = first.kind.call.args;
                if (c_args.len == 0) break;
                const ty_expr = switch (c_args[0]) {
                    .positional => |e| e,
                    .named => |nn| nn.value,
                };
                return try self.inferTypeArg(ty_expr);
            }
            return .void;
        }

        // A `core::<member>` whose member matched no builtin above is a hard error
        // (don't fall through to user-symbol / fn-ptr resolution).
        if (is_core) {
            self.emitError(call.callee.span, "unknown core builtin `{s}`", .{name});
            return error.SemanticFailed;
        }

        const id = self.resolveSymbol(name) orelse {
            // Maybe it's a local function-pointer variable.
            if (self.lookupLocal(name)) |local_ty| switch (local_ty) {
                .fn_ptr => |fp| {
                    for (call.args, 0..) |arg, i| {
                        const arg_expr = switch (arg) {
                            .positional => |e| e,
                            .named => |n| n.value,
                        };
                        const expected = if (i < fp.params.len) fp.params[i] else null;
                        try self.checkNonEscapingArgument(arg_expr, expected);
                        const arg_ty = try self.inferExpr(arg_expr);
                        if (i < fp.params.len and !try self.compatible(arg_ty, fp.params[i])) {
                            self.emitError(arg_expr.span, "argument {d}: expected `{s}`, found `{s}`", .{
                                i + 1, self.formatTy(fp.params[i]), self.formatTy(arg_ty),
                            });
                            return error.SemanticFailed;
                        }
                    }
                    // Record the callee's fn-pointer type so IR types the
                    // (indirect) call's arguments from it.
                    try self.env.expr_types.put(call.callee.id, local_ty);
                    return fp.ret.*;
                },
                else => {},
            };
            // `@`-prefixed names are compiler/runtime builtins (`@panic`, …). The
            // runtime supplies the real declaration; when it isn't linked into
            // this compile (e.g. type-checking std.heap in isolation, or the
            // inline `compile(source)` path), accept the call as `void` so the
            // dependent code still checks. Args are still type-checked.
            if (name.len > 0 and name[0] == '@') {
                for (call.args) |arg| {
                    const arg_expr = switch (arg) {
                        .positional => |e| e,
                        .named => |n| n.value,
                    };
                    _ = try self.inferExpr(arg_expr);
                }
                return .void;
            }
            self.emitError(call.callee.span, "unknown function `{s}`", .{name});
            return error.SemanticFailed;
        };
        if (self.symbols.symbol(id).kind != .function) {
            self.emitError(call.callee.span, "`{s}` is not a function", .{name});
            return error.SemanticFailed;
        }
        const sig = self.env.fn_sigs.get(id) orelse {
            diag_mod.printIce("function symbol has no signature record", @src());
            return error.SemanticFailed;
        };

        // Generic call: infer type binding and record instantiation
        if (sig.type_params.len > 0) {
            return try self.inferGenericCall(id, name, sig, call);
        }

        return try self.inferDirectCall(id, name, sig, call);
    }

    const ExtensionMethod = struct {
        id: SymbolId,
        sig: FnSig,
    };

    fn resolveExtensionMethod(self: *Checker, name: []const u8, base_ty: Ty) ?ExtensionMethod {
        // An in-struct method (`Type.method`) defined on the receiver's own type
        // wins first — so a type's own `load` shadows a free `load` of the same
        // name. Then a visible (own/imported-unqualified) free function; then a
        // `self`-first method defined in the receiver type's own module (cross-
        // module UFCS).
        const id = self.assocMethodSymbol(name, base_ty) orelse
            self.resolveSymbol(name) orelse
            self.methodFromTypeModule(name, base_ty) orelse return null;
        if (self.symbols.symbol(id).kind != .function) return null;
        const sig = self.env.fn_sigs.get(id) orelse return null;
        for (sig.params) |param| {
            if (param.is_type_param) continue;
            if (!std.mem.eql(u8, param.name, "self")) return null;
            return .{ .id = id, .sig = sig };
        }
        return null;
    }

    /// The concrete named type behind a receiver (`Good`, `*Good`, `*const Good`),
    /// or null if the receiver isn't a concrete named type (e.g. a `*T` type param).
    fn concreteReceiverTypeName(self: *Checker, ty: Ty) ?[]const u8 {
        return switch (ty) {
            .named => |id| self.symbols.symbol(id).name,
            .pointer, .const_ptr, .borrow => |inner| self.concreteReceiverTypeName(inner.*),
            else => null,
        };
    }

    /// Resolve `recv.method(args)` to an interface method that `recv`'s concrete
    /// type implements (`Good as Show { val … }` → `g.val()`). Type-checks the
    /// call against the interface method's signature and records it in
    /// `impl_method_calls` so IR emits a direct call to the impl. Returns the
    /// call's result type, or null when no implemented interface declares it.
    fn resolveImplMethodCall(self: *Checker, call: ast.CallExpr, fld: ast.FieldExpr, base_ty: Ty) SemanticError!?Ty {
        const type_name = self.concreteReceiverTypeName(base_ty) orelse return null;
        var it = self.env.interface_impls.valueIterator();
        while (it.next()) |impl| {
            if (!std.mem.eql(u8, impl.type_name, type_name)) continue;
            const interface_id = self.resolveSymbol(impl.interface_name) orelse continue;
            const method = self.findInterfaceMethod(interface_id, fld.name) orelse continue;
            const want_args = if (method.params.len > 0) method.params.len - 1 else 0;
            if (call.args.len != want_args) {
                self.emitError(call.callee.span, "`{s}` expects {d} argument(s)", .{ fld.name, want_args });
                return error.SemanticFailed;
            }
            for (call.args, 0..) |arg, i| {
                const arg_expr = switch (arg) {
                    .positional => |v| v,
                    .named => |n| n.value,
                };
                const arg_ty = try self.inferExpr(arg_expr);
                if (!try self.compatible(arg_ty, method.params[i + 1].ty)) {
                    self.emitError(arg_expr.span, "argument {d} of `{s}`: expected `{s}`, found `{s}`", .{ i + 1, fld.name, self.formatTy(method.params[i + 1].ty), self.formatTy(arg_ty) });
                    return error.SemanticFailed;
                }
            }
            try self.env.impl_method_calls.put(call.callee.id, .{
                .type_name = type_name,
                .interface_name = impl.interface_name,
                .method_name = fld.name,
            });
            // A value receiver (`g.val()`, not `gp.val()`) is implicitly `&`-d.
            switch (base_ty) {
                .pointer, .const_ptr => {},
                else => try self.env.receiver_auto_addr.put(call.callee.id, {}),
            }
            if (method.error_ty) |err_ty| {
                return .{ .fallible = .{ .ok = try self.boxTy(method.return_ty), .err = try self.boxTy(err_ty) } };
            }
            return method.return_ty;
        }
        return null;
    }

    /// The struct's *base* name: the template name for a generic instance
    /// (`Atomic__T_u32` → `Atomic`), otherwise the symbol's own name.
    fn typeBaseName(self: *Checker, type_id: SymbolId) []const u8 {
        if (self.env.generic_struct_instance_args.get(type_id)) |app|
            return self.symbols.symbol(app.template).name;
        return self.symbols.symbol(type_id).name;
    }

    /// Resolve an in-struct method `Type.method` for the receiver type, if one was
    /// hoisted from a `struct { … method :: fn … }` body. The hoisted function is
    /// a top-level function named `"<BaseName>.<method>"` in the struct's file.
    fn assocMethodSymbol(self: *Checker, name: []const u8, base_ty: Ty) ?SymbolId {
        const type_id = typeSymbolOf(base_ty) orelse return null;
        const base = self.typeBaseName(type_id);
        const file = self.symbols.symbol(type_id).file_name;
        var buf: [256]u8 = undefined;
        const dotted = std.fmt.bufPrint(&buf, "{s}.{s}", .{ base, name }) catch return null;
        for (self.symbols.symbols.items) |sym| {
            if (sym.kind == .function and std.mem.eql(u8, sym.file_name, file) and
                std.mem.eql(u8, sym.name, dotted) and
                (sym.is_public or std.mem.eql(u8, sym.file_name, self.file)))
                return sym.id;
        }
        return null;
    }

    /// A public `self`-first function named `name` defined in the same module as
    /// the receiver's type, or null. Enables cross-module UFCS (methods follow
    /// their type's module).
    fn methodFromTypeModule(self: *Checker, name: []const u8, base_ty: Ty) ?SymbolId {
        const type_id = typeSymbolOf(base_ty) orelse return null;
        const file = self.symbols.symbol(type_id).file_name;
        for (self.symbols.symbols.items) |sym| {
            if (sym.kind == .function and sym.is_public and
                std.mem.eql(u8, sym.file_name, file) and std.mem.eql(u8, sym.name, name))
                return sym.id;
        }
        return null;
    }

    fn extensionLookupDeferred(ty: Ty) bool {
        return switch (ty) {
            .unknown, .type_param => true,
            .pointer, .const_ptr, .borrow => |inner| extensionLookupDeferred(inner.*),
            else => false,
        };
    }

    fn extensionCall(self: *Checker, call: ast.CallExpr, receiver: ast.Expr, sig: FnSig) SemanticError!ast.CallExpr {
        var args = std.ArrayList(ast.CallArg).empty;
        errdefer args.deinit(self.allocator);

        var source_index: usize = 0;
        var inserted_receiver = false;
        for (sig.params) |param| {
            if (param.is_type_param) {
                const constrained = for (sig.type_constraints) |constraint| {
                    if (std.mem.eql(u8, constraint.param, param.name)) break true;
                } else false;
                if (constrained) continue;
            } else if (!inserted_receiver) {
                try args.append(self.allocator, .{ .positional = receiver });
                inserted_receiver = true;
                continue;
            }

            if (source_index >= call.args.len) break;
            try args.append(self.allocator, call.args[source_index]);
            source_index += 1;
        }
        while (source_index < call.args.len) : (source_index += 1) {
            try args.append(self.allocator, call.args[source_index]);
        }

        return .{
            .callee = call.callee,
            .args = try args.toOwnedSlice(self.allocator),
        };
    }

    fn inferDirectCall(self: *Checker, id: SymbolId, name: []const u8, sig: FnSig, call: ast.CallExpr) SemanticError!Ty {
        return self.inferDirectCallImpl(id, name, sig, call, false);
    }

    /// `is_method` is true when `call` came from UFCS (`recv.method(args)`), where
    /// `call.args[0]` is the receiver. Such a receiver is implicitly address-of'd
    /// when the method takes a `*Self`/`*const Self` and the receiver is a value
    /// lvalue (recorded in `receiver_auto_addr` for IR to lower as `&recv`).
    fn inferDirectCallImpl(self: *Checker, id: SymbolId, name: []const u8, sig: FnSig, call: ast.CallExpr, is_method: bool) SemanticError!Ty {
        _ = id;
        // Count only value params for arg matching
        var value_param_count: usize = 0;
        for (sig.params) |p| {
            if (!p.is_type_param) value_param_count += 1;
        }
        if (call.args.len != value_param_count) {
            self.emitError(call.callee.span, "`{s}` expects {d} argument(s), but {d} were provided", .{ name, value_param_count, call.args.len });
            return error.SemanticFailed;
        }

        var arg_i: usize = 0;
        for (sig.params) |param| {
            if (param.is_type_param) continue;
            const arg_expr = switch (call.args[arg_i]) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            try self.checkNonEscapingArgument(arg_expr, param.ty);
            // Bare enum literal `.variant` inferred against the expected enum param.
            if (try self.coerceEnumLiteral(arg_expr, param.ty)) {
                arg_i += 1;
                continue;
            }
            const arg_ty = try self.inferExpr(arg_expr);
            // UFCS auto-ref: a value receiver passed to a `*Self` method.
            if (is_method and arg_i == 0 and self.receiverNeedsAddress(arg_ty, param.ty, arg_expr)) {
                try self.env.receiver_auto_addr.put(call.callee.id, {});
                arg_i += 1;
                continue;
            }
            if (!try self.compatible(arg_ty, param.ty)) {
                self.emitError(arg_expr.span, "argument {d} of `{s}`: expected `{s}`, found `{s}`", .{ arg_i + 1, name, self.formatTy(param.ty), self.formatTy(arg_ty) });
                return error.SemanticFailed;
            }
            arg_i += 1;
        }
        // Emit a warning when calling a deprecated function.
        if (sig.deprecated) |msg| {
            if (msg.len > 0) {
                self.emitWarning(call.callee.span, "`{s}` is deprecated: {s}", .{ name, msg });
            } else {
                self.emitWarning(call.callee.span, "`{s}` is deprecated", .{name});
            }
        }

        if (sig.error_ty) |err_ty| {
            return .{ .fallible = .{ .ok = try self.boxTy(sig.return_ty), .err = try self.boxTy(err_ty) } };
        }
        return sig.return_ty;
    }

    /// If `expr` is a bare enum literal `.variant` and `expected` is an enum type
    /// that has that variant, type the expr as the enum and record it for IR
    /// (returns true). Otherwise returns false and leaves checking to the caller.
    fn coerceEnumLiteral(self: *Checker, expr: ast.Expr, expected: Ty) SemanticError!bool {
        const lit = switch (expr.kind) {
            .ident => |n| n,
            else => return false,
        };
        if (lit.len < 2 or lit[0] != '.') return false;
        const type_id = switch (expected) {
            .named => |id| id,
            else => return false,
        };
        const layout = self.env.layouts.get(type_id) orelse return false;
        const variants = switch (layout.kind) {
            .variant_type => |v| v,
            else => return false,
        };
        const variant_name = lit[1..];
        for (variants) |v| {
            if (!std.mem.eql(u8, v.name, variant_name)) continue;
            try self.env.expr_types.put(expr.id, .{ .named = type_id });
            try self.env.enum_lits.put(expr.id, .{
                .type_name = self.symbols.symbol(type_id).name,
                .variant = variant_name,
            });
            return true;
        }
        return false;
    }

    /// `EnumType.variant(payload)` — construct an enum value carrying a payload
    /// (the inverse of a `match … |v|` arm). Type-checks the payload against the
    /// variant's declared type and records the construction (keyed on the callee
    /// id) for IR to lower as a `variant_lit`. Returns the enum type, or null when
    /// `call` is not an enum-variant construction.
    fn inferVariantConstruct(self: *Checker, call: ast.CallExpr) SemanticError!?Ty {
        if (call.callee.kind != .field) return null;
        const fld = call.callee.kind.field;
        if (fld.base.kind != .ident) return null;
        const type_id = self.resolveSymbol(fld.base.kind.ident) orelse return null;
        if (self.symbols.symbol(type_id).kind != .type) return null;
        const layout = self.env.layouts.get(type_id) orelse return null;
        const variants = switch (layout.kind) {
            .variant_type => |v| v,
            else => return null,
        };
        var payload_ty: ?Ty = null;
        const found = for (variants) |v| {
            if (std.mem.eql(u8, v.name, fld.name)) {
                payload_ty = v.payload;
                break true;
            }
        } else false;
        if (!found) return null;

        if (payload_ty) |pty| {
            if (call.args.len != 1) {
                self.emitError(call.callee.span, "variant `.{s}` takes one payload argument", .{fld.name});
                return error.SemanticFailed;
            }
            const arg_expr = switch (call.args[0]) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            if (!try self.coerceEnumLiteral(arg_expr, pty)) {
                const arg_ty = try self.inferExpr(arg_expr);
                if (!try self.compatible(arg_ty, pty)) {
                    self.emitError(arg_expr.span, "variant `.{s}` payload: expected `{s}`, found `{s}`", .{ fld.name, self.formatTy(pty), self.formatTy(arg_ty) });
                    return error.SemanticFailed;
                }
            }
        } else if (call.args.len != 0) {
            self.emitError(call.callee.span, "variant `.{s}` has no payload; write `{s}.{s}`", .{ fld.name, fld.base.kind.ident, fld.name });
            return error.SemanticFailed;
        }

        try self.env.enum_lits.put(call.callee.id, .{
            .type_name = self.symbols.symbol(type_id).name,
            .variant = fld.name,
        });
        return Ty{ .named = type_id };
    }

    /// True when a value receiver should be implicitly address-of'd to satisfy a
    /// `*Self`/`*const Self` method param: the param is a pointer, the receiver is
    /// not already a pointer, it is an addressable lvalue, and its type matches the
    /// pointee.
    fn receiverNeedsAddress(self: *Checker, recv_ty: Ty, param_ty: Ty, recv_expr: ast.Expr) bool {
        const pointee = switch (param_ty) {
            .pointer => |p| p.*,
            .const_ptr => |p| p.*,
            else => return false,
        };
        switch (recv_ty) {
            .pointer, .const_ptr => return false,
            else => {},
        }
        // A non-addressable receiver (a temporary, e.g. `mk().method()` or
        // `ns::any().method()`) is auto-ref'd too: IR spills it to a stack slot and
        // points at that. Read-only methods are the common case; a mutation through
        // a discarded temporary is harmless. Addressable receivers point in place.
        _ = recv_expr;
        return self.compatible(recv_ty, pointee) catch false;
    }

    fn checkComptimeIf(self: *Checker, ci: ast.ComptimeIfStmt) SemanticError!void {
        // Evaluate the condition at compile time.
        // Type-check both branches regardless of condition — eliminates the need
        // for a fully working comptime evaluator just to check #if blocks.
        // The evaluator will be used to select the live branch at IR lowering time.
        _ = try self.inferExpr(ci.condition);
        try self.checkBlock(ci.then_block);
        if (ci.else_block) |eb| try self.checkBlock(eb);
    }

    fn inferRunExpr(self: *Checker, inner: ast.Expr) SemanticError!Ty {
        // Type-check the inner expression normally — the type IS the comptime result type.
        return try self.inferExpr(inner);
    }

    const MatchKind = enum { integer, string, enum_, invalid };
    const MatchClass = struct { kind: MatchKind, variants: []const VariantInfo = &.{} };
    const ArmBind = struct { name: []const u8, ty: Ty };

    fn matchSubjectIsString(ty: Ty) bool {
        return switch (ty) {
            .slice => |elem| elem.* == .u8 or elem.* == .byte,
            else => false,
        };
    }

    /// Classify a match subject: integer, string (`[]u8`), enum (with variants),
    /// or invalid.
    fn classifyMatchSubject(self: *Checker, ty: Ty) MatchClass {
        if (ty.isInteger()) return .{ .kind = .integer };
        if (matchSubjectIsString(ty)) return .{ .kind = .string };
        switch (ty) {
            .named => |id| if (self.env.layouts.get(id)) |layout| switch (layout.kind) {
                .variant_type => |v| return .{ .kind = .enum_, .variants = v },
                else => {},
            },
            else => {},
        }
        return .{ .kind = .invalid };
    }

    /// Validate one arm's pattern against the subject; record enum coverage and
    /// set `catchall` for an UNGUARDED `else`/name pattern; return the local the
    /// arm binds (an enum payload, or a `name` pattern's subject), or null.
    /// `arm` is a `MatchArm` or `MatchExprArm` (same pattern/binding/guard/span).
    fn checkMatchPattern(self: *Checker, cls: MatchClass, subject_ty: Ty, arm: anytype, covered: []bool, catchall: *bool) SemanticError!?ArmBind {
        const guarded = arm.guard != null;
        switch (arm.pattern) {
            .else_arm => {
                if (arm.binding != null) {
                    self.emitError(arm.span, "`else` arm cannot bind a value", .{});
                    return error.SemanticFailed;
                }
                if (!guarded) catchall.* = true;
                return null;
            },
            .binding => |name| {
                if (arm.binding != null) {
                    self.emitError(arm.span, "a name pattern already binds the subject; remove the `|...|`", .{});
                    return error.SemanticFailed;
                }
                if (!guarded) catchall.* = true;
                return .{ .name = name, .ty = subject_ty };
            },
            .enum_variant => |vname| {
                if (cls.kind != .enum_) {
                    self.emitError(arm.span, "enum variant pattern cannot be used with this match subject", .{});
                    return error.SemanticFailed;
                }
                var found: ?VariantInfo = null;
                for (cls.variants, 0..) |v, i| {
                    if (std.mem.eql(u8, v.name, vname)) {
                        found = v;
                        if (covered[i] and !guarded) {
                            self.emitError(arm.span, "duplicate match arm for variant `.{s}`", .{vname});
                            return error.SemanticFailed;
                        }
                        if (!guarded) covered[i] = true;
                        break;
                    }
                }
                const variant = found orelse {
                    self.emitError(arm.span, "unknown variant `.{s}` in match", .{vname});
                    return error.SemanticFailed;
                };
                if (arm.binding) |b| return .{ .name = b, .ty = variant.payload orelse .void };
                return null;
            },
            .int_values => |values| {
                if (cls.kind != .integer) {
                    self.emitError(arm.span, "integer pattern cannot be used with this match subject", .{});
                    return error.SemanticFailed;
                }
                if (arm.binding != null) {
                    self.emitError(arm.span, "integer match patterns cannot bind a payload", .{});
                    return error.SemanticFailed;
                }
                for (values) |value| {
                    const vt = try self.inferExpr(value);
                    if (!try self.compatible(vt, subject_ty)) {
                        self.emitError(value.span, "integer match pattern is incompatible with subject type `{s}`", .{self.formatTy(subject_ty)});
                        return error.SemanticFailed;
                    }
                }
                return null;
            },
            .range => |r| {
                if (cls.kind != .integer) {
                    self.emitError(arm.span, "range pattern requires an integer match subject", .{});
                    return error.SemanticFailed;
                }
                if (arm.binding != null) {
                    self.emitError(arm.span, "range match patterns cannot bind a payload", .{});
                    return error.SemanticFailed;
                }
                const lo_ty = try self.inferExpr(r.lo);
                const hi_ty = try self.inferExpr(r.hi);
                if (!try self.compatible(lo_ty, subject_ty) or !try self.compatible(hi_ty, subject_ty)) {
                    self.emitError(arm.span, "range bounds are incompatible with subject type `{s}`", .{self.formatTy(subject_ty)});
                    return error.SemanticFailed;
                }
                return null;
            },
            .strings => {
                if (cls.kind != .string) {
                    self.emitError(arm.span, "string pattern requires a string (`[]const u8`) match subject", .{});
                    return error.SemanticFailed;
                }
                if (arm.binding != null) {
                    self.emitError(arm.span, "string match patterns cannot bind a payload", .{});
                    return error.SemanticFailed;
                }
                return null;
            },
        }
    }

    fn checkMatchGuard(self: *Checker, guard: ?ast.Expr) SemanticError!void {
        if (guard) |g| {
            const gt = try self.inferExpr(g);
            if (gt != .bool) {
                self.emitError(g.span, "match guard must be a `bool`, found `{s}`", .{self.formatTy(gt)});
                return error.SemanticFailed;
            }
        }
    }

    /// Record exhaustiveness for return-flow analysis, or error when required.
    /// `require` is set for match *expressions* (must yield a value on every
    /// path); statement matches still hard-error on a non-exhaustive *enum*.
    fn recordMatchExhaustiveness(self: *Checker, span: Span, cls: MatchClass, covered: []const bool, catchall: bool, require: bool) SemanticError!void {
        if (catchall) {
            try self.exhaustive_matches.put(span.start, {});
            return;
        }
        if (cls.kind == .enum_) {
            for (cls.variants, 0..) |v, i| {
                if (!covered[i]) {
                    self.emitError(span, "non-exhaustive match: variant `.{s}` is not handled (add it, or an `else` arm)", .{v.name});
                    return error.SemanticFailed;
                }
            }
            try self.exhaustive_matches.put(span.start, {});
            return;
        }
        // integer / string: only exhaustive via a catch-all.
        if (require) {
            self.emitError(span, "non-exhaustive match expression: add an `else` arm (it must yield a value on every path)", .{});
            return error.SemanticFailed;
        }
    }

    fn checkMatch(self: *Checker, m: ast.MatchStmt) SemanticError!void {
        const subject_ty = try self.inferExpr(m.subject);
        const cls = self.classifyMatchSubject(subject_ty);
        if (cls.kind == .invalid) return self.invalidMatchSubject(m.subject.span);

        const covered = try self.allocator.alloc(bool, cls.variants.len);
        defer self.allocator.free(covered);
        @memset(covered, false);
        var catchall = false;

        for (m.arms) |arm| {
            const bind = try self.checkMatchPattern(cls, subject_ty, arm, covered, &catchall);
            try self.pushScope();
            defer self.popScope();
            if (bind) |b| try self.declareLocal(b.name, b.ty);
            try self.checkMatchGuard(arm.guard);
            try self.checkBlock(arm.body);
        }

        try self.recordMatchExhaustiveness(m.span, cls, covered, catchall, false);
    }

    fn invalidMatchSubject(self: *Checker, span: Span) SemanticError {
        self.emitError(span, "match subject must be an enum or integer type", .{});
        return error.SemanticFailed;
    }

    fn requireUnsafe(self: *Checker, span: Span, builtin_name: []const u8) SemanticError!void {
        if (self.unsafe_depth == 0) {
            self.emitError(span, "`{s}` is an unsafe operation and must be called inside an `unsafe` block", .{builtin_name});
            return error.SemanticFailed;
        }
    }

    fn inferZoneMethod(self: *Checker, span: Span, method: []const u8, args: []const ast.CallArg) SemanticError!Ty {
        if (std.mem.eql(u8, method, "new")) {
            if (args.len != 1) {
                self.emitError(span, "`Arena.new` expects a single type argument, e.g. `arena.new(T)`", .{});
                return error.SemanticFailed;
            }
            const ty_expr = switch (args[0]) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            const alloc_ty = try self.inferTypeArg(ty_expr);
            return try self.ptrTo(alloc_ty);
        }
        if (std.mem.eql(u8, method, "new_slice")) {
            if (args.len != 2) {
                self.emitError(span, "`Arena.new_slice` expects a type and a count, e.g. `arena.new_slice(T, n)`", .{});
                return error.SemanticFailed;
            }
            const ty_expr = switch (args[0]) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            const count_expr = switch (args[1]) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            const count_ty = try self.inferExpr(count_expr);
            if (!count_ty.isInteger()) {
                self.emitError(count_expr.span, "`Arena.new_slice` count must be an integer, found `{s}`", .{self.formatTy(count_ty)});
                return error.SemanticFailed;
            }
            const elem_ty = try self.inferTypeArg(ty_expr);
            return try self.sliceOf(elem_ty);
        }
        if (std.mem.eql(u8, method, "free")) {
            if (args.len > 0) {
                const ptr_expr = switch (args[0]) {
                    .positional => |e| e,
                    .named => |n| n.value,
                };
                _ = try self.inferExpr(ptr_expr);
            }
            return .void;
        }
        self.emitError(span, "unknown arena method `{s}` (expected `new`, `new_slice`, or `free`)", .{method});
        return error.SemanticFailed;
    }

    fn exprZoneOwner(self: Checker, expr: ast.Expr) ?ZoneOwner {
        if (self.env.expr_types.get(expr.id)) |ty| {
            if (!tyCanCarryZoneOwner(ty)) return null;
        }
        return switch (expr.kind) {
            .ident => |name| self.lookupZoneOwner(name),
            .unsafe_expr, .run_expr, .force_unwrap => |inner| self.exprZoneOwner(inner.*),
            .as_cast => |cast| self.exprZoneOwner(cast.value.*),
            .nil_coalesce => |coalesce| self.exprZoneOwner(coalesce.value.*) orelse self.exprZoneOwner(coalesce.default.*),
            .unary => |unary| self.exprZoneOwner(unary.expr.*),
            .binary => |binary| self.exprZoneOwner(binary.left.*) orelse self.exprZoneOwner(binary.right.*),
            .field => |field| if (std.mem.eql(u8, field.name, "len")) null else self.exprZoneOwner(field.base.*),
            .index => |index| self.exprZoneOwner(index.base.*),
            .slice => |slice| self.exprZoneOwner(slice.base.*),
            .try_expr => |try_expr| self.exprZoneOwner(try_expr.value.*),
            .catch_expr => |catch_expr| self.exprZoneOwner(catch_expr.value.*),
            .compound_literal => |values| blk: {
                for (values) |value| if (self.exprZoneOwner(value)) |owner| break :blk owner;
                break :blk null;
            },
            .call => |call| blk: {
                if (call.callee.kind == .field) {
                    const field = call.callee.kind.field;
                    if (field.base.kind == .ident and isArenaAllocMethod(field.name)) {
                        const zone_name = field.base.kind.ident;
                        for (self.active_zones.items) |zone| {
                            if (std.mem.eql(u8, zone.name, zone_name)) break :blk .{
                                .name = zone.name,
                                .scope_depth = zone.scope_depth,
                            };
                        }
                    }
                }
                break :blk null;
            },
            else => null,
        };
    }

    fn inferTypeArg(self: *Checker, expr: ast.Expr) SemanticError!Ty {
        // Record the resolved type under this expression's id so the argument
        // re-inference pass in `inferExpr` (`.call`) skips it instead of trying
        // to evaluate a type name as a value.
        const ty = try self.inferTypeArgImpl(expr);
        try self.env.expr_types.put(expr.id, ty);
        return ty;
    }

    fn inferTypeArgImpl(self: *Checker, expr: ast.Expr) SemanticError!Ty {
        return switch (expr.kind) {
            .type_ref => |ty| try self.typeFromRef(ty),
            .ident => |name| {
                if (self.resolveTypeParam(name)) |t| return t;
                if (fromBuiltinName(name)) |t| return t;
                const id = self.resolveSymbol(name) orelse {
                    self.emitError(expr.span, "unknown type `{s}`", .{name});
                    return error.SemanticFailed;
                };
                if (self.symbols.symbol(id).kind != .type) {
                    self.emitError(expr.span, "`{s}` is not a type", .{name});
                    return error.SemanticFailed;
                }
                return .{ .named = id };
            },
            // Generic struct instantiation used as a type argument, e.g.
            // `arena.new(List(i32))`. In expression position `List(i32)` parses
            // as a call, so bridge it to the type-level instantiation path.
            .call => |call| {
                if (call.callee.kind == .ident) {
                    const gname = call.callee.kind.ident;
                    if (self.env.generic_struct_templates.contains(gname)) {
                        var targs: std.ArrayList(ast.TypeRef) = .empty;
                        defer targs.deinit(self.allocator);
                        for (call.args) |ca| {
                            const ae = switch (ca) {
                                .positional => |e| e,
                                .named => |n| n.value,
                            };
                            try targs.append(self.allocator, self.exprToTypeRef(ae) orelse {
                                self.emitError(ae.span, "expected a type argument to `{s}`", .{gname});
                                return error.SemanticFailed;
                            });
                        }
                        return try self.instantiateGenericStruct(.{
                            .name = gname,
                            .args = targs.items,
                            .span = expr.span,
                        });
                    }
                }
                self.emitError(expr.span, "expected a type, found a call expression", .{});
                return error.SemanticFailed;
            },
            else => {
                self.emitError(expr.span, "expected a type argument", .{});
                return error.SemanticFailed;
            },
        };
    }

    /// Convert an expression appearing in type-argument position into a TypeRef.
    /// Handles type names (`i32`, `MyStruct`), explicit type refs (`[]const u8`,
    /// `*T`), and nested generic instantiations (`List(i32)`). Returns null for
    /// anything that is not a type.
    fn exprToTypeRef(self: *Checker, expr: ast.Expr) ?ast.TypeRef {
        return switch (expr.kind) {
            .type_ref => |t| t,
            .ident => |name| .{ .named = .{ .name = name, .span = expr.span } },
            .call => |call| blk: {
                if (call.callee.kind != .ident) break :blk null;
                var targs: std.ArrayList(ast.TypeRef) = .empty;
                for (call.args) |ca| {
                    const ae = switch (ca) {
                        .positional => |e| e,
                        .named => |n| n.value,
                    };
                    const tr = self.exprToTypeRef(ae) orelse {
                        targs.deinit(self.allocator);
                        break :blk null;
                    };
                    targs.append(self.allocator, tr) catch {
                        targs.deinit(self.allocator);
                        break :blk null;
                    };
                }
                break :blk .{ .generic_inst = .{
                    .name = call.callee.kind.ident,
                    .args = targs.toOwnedSlice(self.allocator) catch break :blk null,
                    .span = expr.span,
                } };
            },
            else => null,
        };
    }

    fn inferGenericCall(self: *Checker, sym_id: SymbolId, fn_name: []const u8, sig: FnSig, call: ast.CallExpr) SemanticError!Ty {
        return self.inferGenericCallImpl(sym_id, fn_name, sig, call, false);
    }

    /// `is_method`: the call came from UFCS (`recv.method(...)`), so the first
    /// *value* param is the receiver and may be auto-`&`d when the method takes a
    /// `*Self` (mirrors `inferDirectCallImpl`, but for generic methods like the
    /// Arena allocators whose receiver follows a leading `$T: type`).
    fn inferGenericCallImpl(self: *Checker, sym_id: SymbolId, fn_name: []const u8, sig: FnSig, call: ast.CallExpr, is_method: bool) SemanticError!Ty {
        // Constrained type params ($T: Interface) are implicit — inferred from value args.
        // Unconstrained type params ($T: type) are explicit — the caller passes the type.
        // So we count: value params + unconstrained type params = expected arg count.
        var expected_arg_count: usize = 0;
        for (sig.params) |p| {
            if (!p.is_type_param) {
                expected_arg_count += 1;
                continue;
            }
            // Is this type param constrained?
            const is_constrained = for (sig.type_constraints) |c| {
                if (std.mem.eql(u8, c.param, p.name)) break true;
            } else false;
            if (!is_constrained) expected_arg_count += 1; // explicit $T: type
        }
        if (call.args.len != expected_arg_count) {
            self.emitError(call.callee.span, "`{s}` expects {d} argument(s), but {d} were provided", .{
                fn_name, expected_arg_count, call.args.len,
            });
            return error.SemanticFailed;
        }

        // Infer type args by matching call args to value params.
        // Type-only params ($T: type / $T: Interface) are inferred from the value args.
        var binding = std.StringHashMap(Ty).init(self.allocator);
        defer binding.deinit();

        var arg_tys = std.ArrayList(Ty).empty;
        defer arg_tys.deinit(self.allocator);

        var arg_i: usize = 0;
        for (sig.params) |param| {
            if (param.is_type_param) {
                // Constrained ($T: Interface) → implicit, skip for arg matching.
                // Unconstrained ($T: type) → explicit, falls through to arg handling below.
                const constrained = for (sig.type_constraints) |c| {
                    if (std.mem.eql(u8, c.param, param.name)) break true;
                } else false;
                if (constrained) continue;
            }
            if (arg_i >= call.args.len) break;
            const arg_expr = switch (call.args[arg_i]) {
                .positional => |value| value,
                .named => |named| named.value,
            };
            arg_i += 1;
            try self.checkNonEscapingArgument(arg_expr, param.ty);
            // An explicit `$T: type` argument is a TYPE expression (`i32`,
            // `List(i32)`), not a value — resolve it as a type so generic-struct
            // instantiations (which parse as a call) bind correctly. Constrained
            // `$T: Interface` params were already `continue`d above, so every type
            // param reaching here is explicit.
            const arg_ty = if (param.is_type_param)
                try self.inferTypeArg(arg_expr)
            else
                try self.inferExpr(arg_expr);
            try arg_tys.append(self.allocator, arg_ty);
            // Bind type variables: if param type is $T, bind T to the arg type.
            if (param.ty == .type_param) {
                const tp = param.ty.type_param;
                if (!binding.contains(tp)) {
                    const concrete = switch (arg_ty) {
                        .int_lit => Ty.i32,
                        .float_lit => Ty.f64,
                        else => arg_ty,
                    };
                    try binding.put(tp, concrete);
                }
            }
            // If param type contains a type variable (e.g. *$T), extract the binding.
            if (param.ty == .pointer or param.ty == .const_ptr) {
                const inner = switch (param.ty) {
                    .pointer, .const_ptr => |i| i,
                    else => unreachable,
                };
                if (inner.* == .type_param) {
                    const tp = inner.type_param;
                    if (!binding.contains(tp)) {
                        // arg_ty should be *SomeType — extract the inner
                        const concrete: Ty = switch (arg_ty) {
                            .pointer, .const_ptr => |inner_ty| inner_ty.*,
                            else => arg_ty,
                        };
                        try binding.put(tp, concrete);
                    }
                }
            }
            // `[]$T` / `?$T` param — bind `$T` from the slice/optional element type.
            if (param.ty == .slice and param.ty.slice.* == .type_param) {
                const tp = param.ty.slice.type_param;
                if (!binding.contains(tp)) {
                    const concrete: Ty = switch (arg_ty) {
                        .slice => |e| e.*,
                        .array => |a| a.elem.*,
                        else => arg_ty,
                    };
                    try binding.put(tp, concrete);
                }
            }
            if (param.ty == .optional and param.ty.optional.* == .type_param) {
                const tp = param.ty.optional.type_param;
                if (!binding.contains(tp)) {
                    const concrete: Ty = switch (arg_ty) {
                        .optional => |e| e.*,
                        else => arg_ty,
                    };
                    try binding.put(tp, concrete);
                }
            }
            // `*Atomic(T)` / `Atomic(T)` param — bind `$T` from a concrete instance
            // argument (`*Atomic(u32)` / `Atomic(u32)`). This is what lets a
            // receiver-only generic method (`get(self: *Atomic(T))`) infer `T` from
            // its receiver, since `T` appears only nested inside the struct.
            {
                const param_app: ?GenericApp = switch (param.ty) {
                    .generic_app => |g| g,
                    .pointer, .const_ptr => |i| if (i.* == .generic_app) i.*.generic_app else null,
                    else => null,
                };
                if (param_app) |papp| {
                    // Unwrap the argument past one pointer, then recover its
                    // template + concrete args (either a collapsed `.named`
                    // instance via the reverse map, or a still-`.generic_app`).
                    const arg_inner: Ty = switch (arg_ty) {
                        .pointer, .const_ptr => |i| i.*,
                        else => arg_ty,
                    };
                    const arg_app: ?GenericApp = switch (arg_inner) {
                        .generic_app => |g| g,
                        .named => |id| self.env.generic_struct_instance_args.get(id),
                        else => null,
                    };
                    if (arg_app) |aapp| {
                        if (aapp.template == papp.template and aapp.args.len == papp.args.len) {
                            for (papp.args, aapp.args) |pa, aa| {
                                if (pa == .type_param and !binding.contains(pa.type_param))
                                    try binding.put(pa.type_param, aa);
                            }
                        }
                    }
                }
            }
        }

        // Verify all value args are compatible with substituted param types.
        var check_i: usize = 0;
        var receiver_seen = false;
        for (sig.params) |param| {
            if (param.is_type_param) {
                const constrained = for (sig.type_constraints) |c| {
                    if (std.mem.eql(u8, c.param, param.name)) break true;
                } else false;
                if (constrained) continue;
            }
            if (check_i >= arg_tys.items.len) break;
            const arg_ty = arg_tys.items[check_i];
            check_i += 1;
            const expected = self.substituteTy(param.ty, &binding);
            const arg_expr = switch (call.args[check_i - 1]) {
                .positional => |e| e,
                .named => |n| n.value,
            };
            // UFCS auto-ref: the receiver (first value param) passed by value to a
            // `*Self` method is lowered as `&recv`.
            if (is_method and !param.is_type_param and !receiver_seen) {
                receiver_seen = true;
                if (self.receiverNeedsAddress(arg_ty, expected, arg_expr)) {
                    try self.env.receiver_auto_addr.put(call.callee.id, {});
                    continue;
                }
            }
            if (!try self.compatible(arg_ty, expected)) {
                self.emitError(arg_expr.span, "argument {d} of `{s}`: expected `{s}`, found `{s}`", .{
                    check_i, fn_name, self.formatTy(expected), self.formatTy(arg_ty),
                });
                return error.SemanticFailed;
            }
        }

        // Check static constraints: `$T: Numeric` (built-in predicate) or
        // `$T: Interface` (conformance). Built-ins are checked by type kind here,
        // with a clear message; everything else falls through to the impl check.
        for (sig.type_constraints) |constraint| {
            const bound_ty = binding.get(constraint.param) orelse continue;
            switch (checkBuiltinConstraint(self, constraint.interface, bound_ty)) {
                .ok => continue,
                .fail => |desc| {
                    self.emitError(constraint.span, "type `{s}` does not satisfy `{s}`: expected {s}", .{ self.formatTy(bound_ty), constraint.interface, desc });
                    return error.SemanticFailed;
                },
                .not_builtin => {},
            }
            // A user-defined `constraint Name($T) { … }` — run its predicate.
            if (self.runConstraintPredicate(constraint.interface, bound_ty)) |msg| {
                if (msg.len > 0) {
                    self.emitError(constraint.span, "type `{s}` does not satisfy `{s}`: {s}", .{ self.formatTy(bound_ty), constraint.interface, msg });
                    return error.SemanticFailed;
                }
                continue; // satisfied
            }
            // Unwrap pointer to get the concrete named type.
            const concrete_id: SymbolId = switch (bound_ty) {
                .named => |id| id,
                .pointer, .const_ptr => |inner| switch (inner.*) {
                    .named => |id| id,
                    else => {
                        self.emitError(constraint.span, "type parameter `{s}` must be a named struct, found `{s}`", .{ constraint.param, self.formatTy(bound_ty) });
                        return error.SemanticFailed;
                    },
                },
                else => {
                    self.emitError(constraint.span, "type parameter `{s}` must be a named struct, found `{s}`", .{ constraint.param, self.formatTy(bound_ty) });
                    return error.SemanticFailed;
                },
            };
            const concrete_name = self.symbols.symbol(concrete_id).name;
            const key = try interfaceImplKey(self.allocator, concrete_name, constraint.interface);
            if (!self.env.interface_impls.contains(key)) {
                self.emitError(constraint.span, "`{s}` does not implement `{s}`", .{ concrete_name, constraint.interface });
                return error.SemanticFailed;
            }
        }

        // Output type params (`-> $Acc`): run the `where` to compute them now, so
        // the call's return type and the recorded instantiation both see them.
        try self.computeOutputParamsAtCall(sig, &binding);

        // Build ordered type_args list
        var type_args = std.ArrayList(TypeArg).empty;
        errdefer type_args.deinit(self.allocator);
        for (sig.type_params) |tp_name| {
            const concrete = binding.get(tp_name) orelse .unknown;
            try type_args.append(self.allocator, .{ .name = tp_name, .ty = concrete });
        }

        // Compute mangled name
        const mangled = try self.mangleInstantiation(fn_name, type_args.items);

        // Record if not already seen
        var already = false;
        for (self.env.generic_instantiations.items) |*gi| {
            if (std.mem.eql(u8, gi.mangled_name, mangled)) {
                already = true;
                break;
            }
        }
        if (!already) {
            try self.env.generic_instantiations.append(self.allocator, .{
                .sym_id = sym_id,
                .fn_name = fn_name,
                .mangled_name = mangled,
                .type_args = try type_args.toOwnedSlice(self.allocator),
                .expr_types = std.AutoHashMap(NodeId, Ty).init(self.allocator),
                .call_insts = std.AutoHashMap(NodeId, []const u8).init(self.allocator),
                .origin_span = call.callee.span,
            });
        } else type_args.deinit(self.allocator);

        // Remember the mangled name so the IR lowerer can emit the right callee.
        // (Writes to whichever `generic_call_insts` is active — the global map for
        // top-level calls, or the current instantiation's map when checking a
        // generic body, so the SAME call node can map to different callees.)
        try self.env.generic_call_insts.put(call.callee.id, mangled);

        // Return substituted return type
        const ret = self.substituteTy(sig.return_ty, &binding);
        if (sig.error_ty) |err| {
            const err_sub = self.substituteTy(err, &binding);
            return .{ .fallible = .{ .ok = try self.boxTy(ret), .err = try self.boxTy(err_sub) } };
        }
        return ret;
    }

    fn substituteTy(self: *Checker, ty: Ty, binding: *const std.StringHashMap(Ty)) Ty {
        return switch (ty) {
            .type_param => |name| binding.get(name) orelse ty,
            .generic_app => |app| blk: {
                // Substitute each argument; once all are concrete, collapse to
                // the concrete instance so it can match a concrete `.named`.
                const new_args = self.allocator.alloc(Ty, app.args.len) catch break :blk ty;
                var all_concrete = true;
                for (app.args, 0..) |arg, i| {
                    new_args[i] = self.substituteTy(arg, binding);
                    if (tyContainsTypeParam(new_args[i])) all_concrete = false;
                }
                if (all_concrete) {
                    break :blk self.instantiateConcrete(app.template, new_args) catch
                        Ty{ .generic_app = .{ .template = app.template, .args = new_args } };
                }
                break :blk .{ .generic_app = .{ .template = app.template, .args = new_args } };
            },
            .pointer => |inner| blk: {
                const sub = self.allocator.create(Ty) catch return ty;
                sub.* = self.substituteTy(inner.*, binding);
                break :blk .{ .pointer = sub };
            },
            .const_ptr => |inner| blk: {
                const sub = self.allocator.create(Ty) catch return ty;
                sub.* = self.substituteTy(inner.*, binding);
                break :blk .{ .const_ptr = sub };
            },
            .optional => |inner| blk: {
                const sub = self.allocator.create(Ty) catch return ty;
                sub.* = self.substituteTy(inner.*, binding);
                break :blk .{ .optional = sub };
            },
            .slice => |inner| blk: {
                const sub = self.allocator.create(Ty) catch return ty;
                sub.* = self.substituteTy(inner.*, binding);
                break :blk .{ .slice = sub };
            },
            .borrow => |inner| blk: {
                const sub = self.allocator.create(Ty) catch return ty;
                sub.* = self.substituteTy(inner.*, binding);
                break :blk .{ .borrow = sub };
            },
            else => ty,
        };
    }

    fn mangleInstantiation(self: *Checker, fn_name: []const u8, type_args: []const TypeArg) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, fn_name);
        for (type_args) |arg| {
            try buf.appendSlice(self.allocator, "__");
            try buf.appendSlice(self.allocator, arg.name);
            try buf.append(self.allocator, '_');
            try self.appendTyMangle(&buf, arg.ty);
        }
        return buf.toOwnedSlice(self.allocator);
    }

    /// Mangle a type for an instantiation key. Unlike the bare `tyMangle`, this
    /// resolves *named* types (structs/enums) to their distinct symbol name —
    /// otherwise `f(Point)` and `f(Player)` both mangle to `f__T_named` and
    /// collapse into a single instantiation (sharing one type's body).
    fn appendTyMangle(self: *Checker, buf: *std.ArrayList(u8), ty: Ty) error{OutOfMemory}!void {
        switch (ty) {
            .named => |id| try buf.appendSlice(self.allocator, self.symbols.symbol(id).name),
            .pointer => |inner| {
                try buf.appendSlice(self.allocator, "ptr_");
                try self.appendTyMangle(buf, inner.*);
            },
            .const_ptr => |inner| {
                try buf.appendSlice(self.allocator, "cptr_");
                try self.appendTyMangle(buf, inner.*);
            },
            .optional => |inner| {
                try buf.appendSlice(self.allocator, "opt_");
                try self.appendTyMangle(buf, inner.*);
            },
            .slice => |inner| {
                try buf.appendSlice(self.allocator, "slice_");
                try self.appendTyMangle(buf, inner.*);
            },
            else => try buf.appendSlice(self.allocator, tyMangle(ty)),
        }
    }

    /// Type-check a previously recorded generic instantiation, filling its per-instance expr_types.
    fn checkGenericInstantiation(self: *Checker, module: ast.Module, inst_idx: usize) SemanticError!void {
        const inst = &self.env.generic_instantiations.items[inst_idx];
        // Find the generic function decl
        for (module.items) |item| {
            switch (item) {
                .function => |decl| {
                    if (decl.type_params.len == 0) continue;
                    const sym_id = self.symbols.resolveVisible(decl.file_name, decl.name) orelse continue;
                    if (sym_id != inst.sym_id) continue;

                    // Swap in a fresh expr_types for this instantiation.
                    // NOTE: `checkFunction` may discover further instantiations (generic
                    // calls in the body) and append them to `generic_instantiations`,
                    // reallocating it and dangling the `inst` pointer. So write the
                    // grown map back by INDEX, not through `inst`.
                    const saved = self.env.expr_types;
                    const saved_calls = self.env.generic_call_insts;
                    self.env.expr_types = inst.expr_types;
                    self.env.generic_call_insts = inst.call_insts;
                    self.current_type_binding = inst.type_args;
                    self.current_inst_span = inst.origin_span;
                    defer {
                        self.env.generic_instantiations.items[inst_idx].expr_types = self.env.expr_types;
                        self.env.generic_instantiations.items[inst_idx].call_insts = self.env.generic_call_insts;
                        self.env.expr_types = saved;
                        self.env.generic_call_insts = saved_calls;
                        self.current_type_binding = &.{};
                        self.current_inst_span = null;
                    }

                    try self.checkFunction(decl);
                    return;
                },
                else => {},
            }
        }
    }

    fn checkCallable(self: *Checker, expr: ast.Expr) SemanticError!void {
        switch (expr.kind) {
            .ident => |name| {
                if (isBuiltinValue(name)) return;
                const id = self.resolveSymbol(name) orelse return error.SemanticFailed;
                if (self.symbols.symbol(id).kind != .function) return error.SemanticFailed;
            },
            .field => try self.checkExpr(expr),
            else => try self.checkExpr(expr),
        }
    }

    fn checkType(self: *Checker, ty: ast.TypeRef) SemanticError!void {
        _ = try self.typeFromRef(ty);
    }

    fn instantiateGenericStruct(self: *Checker, gi: ast.GenericInstType) SemanticError!Ty {
        // `ns::Name(args)` reaches the template through the import alias; the
        // template registry and mangling stay keyed on the bare member name.
        _ = self.resolveTypeSymbol(gi.namespace, gi.name) orelse {
            self.emitError(gi.span, "unknown generic type `{s}`", .{gi.name});
            return error.SemanticFailed;
        };
        // Look up the template.
        const tmpl = self.env.generic_struct_templates.get(gi.name) orelse {
            self.emitError(gi.span, "unknown generic type `{s}`", .{gi.name});
            return error.SemanticFailed;
        };
        const strukt = switch (tmpl.kind) {
            .struct_type => |s| s,
            else => return error.SemanticFailed,
        };
        if (gi.args.len != strukt.type_params.len) {
            self.emitError(gi.span, "`{s}` expects {d} type argument(s), got {d}", .{ gi.name, strukt.type_params.len, gi.args.len });
            return error.SemanticFailed;
        }

        // Build type binding: T → resolved arg type.
        const saved_binding = self.current_type_binding;
        const saved_params = self.current_type_params;
        defer {
            self.current_type_binding = saved_binding;
            self.current_type_params = saved_params;
        }
        var binding = std.ArrayList(TypeArg).empty;
        defer binding.deinit(self.allocator);
        var any_type_var = false;
        for (strukt.type_params, gi.args) |tp_name, arg_ref| {
            const arg_ty = try self.typeFromRef(arg_ref);
            if (tyContainsTypeParam(arg_ty)) any_type_var = true;
            try binding.append(self.allocator, .{ .name = tp_name, .ty = arg_ty });
        }
        // If any argument is still a type variable, we're inside a generic
        // definition (e.g. a param typed `List(T)`). Preserve the application
        // so `substituteTy` can later produce the concrete instance once `T` is
        // bound, instead of collapsing to the bare template (which loses `T`).
        if (any_type_var) {
            const tmpl_id = self.resolveTypeSymbol(gi.namespace, gi.name) orelse return .unknown;
            const arg_tys = self.allocator.alloc(Ty, binding.items.len) catch return .unknown;
            for (binding.items, 0..) |arg, i| arg_tys[i] = arg.ty;
            return .{ .generic_app = .{ .template = tmpl_id, .args = arg_tys } };
        }
        // Enforce `struct($T: Constraint)` at the concrete use site (mirrors the
        // `fn($T: Name)` check). Only meaningful once every arg is concrete, which
        // is the path taken here.
        try self.enforceStructConstraints(strukt.type_constraints, binding.items, gi.span);

        const tmpl_id = self.resolveTypeSymbol(gi.namespace, gi.name).?;
        const arg_tys = try self.allocator.alloc(Ty, binding.items.len);
        for (binding.items, 0..) |arg, i| arg_tys[i] = arg.ty;
        return try self.instantiateConcrete(tmpl_id, arg_tys);
    }

    /// Enforce a generic struct's `$T: Constraint` contracts on a concrete
    /// instantiation, emitting the reject message at `span` (the use site).
    /// Mirrors the function `$T: Name` check (built-in predicate, then a user
    /// `constraint` decl run on the resolution VM). A constraint whose param isn't
    /// bound, or whose name isn't a built-in or registered `constraint` (e.g. the
    /// resolution VM isn't wired in this pass), is left to the method call site.
    fn enforceStructConstraints(
        self: *Checker,
        constraints: []const ast.TypeConstraint,
        binding: []const TypeArg,
        span: Span,
    ) SemanticError!void {
        for (constraints) |c| {
            var bound_ty: ?Ty = null;
            for (binding) |b| {
                if (std.mem.eql(u8, b.name, c.param)) {
                    bound_ty = b.ty;
                    break;
                }
            }
            const bt = bound_ty orelse continue;
            switch (checkBuiltinConstraint(self, c.interface, bt)) {
                .ok => continue,
                .fail => |desc| {
                    self.emitError(span, "type `{s}` does not satisfy `{s}`: expected {s}", .{ self.formatTy(bt), c.interface, desc });
                    return error.SemanticFailed;
                },
                .not_builtin => {},
            }
            // A user-defined `constraint Name($T) { … }` — run its predicate. A
            // non-empty result is the reject message; "" is satisfied; null means
            // the name isn't a registered constraint, so defer to the call site.
            if (self.runConstraintPredicate(c.interface, bt)) |msg| {
                if (msg.len > 0) {
                    self.emitError(span, "type `{s}` does not satisfy `{s}`: {s}", .{ self.formatTy(bt), c.interface, msg });
                    return error.SemanticFailed;
                }
            }
        }
    }

    /// Instantiate a generic struct from a template symbol and concrete argument
    /// types (no `.type_param` entries). Registers the instance symbol + layout
    /// on first use and returns the concrete `.named` type. Shared by
    /// `instantiateGenericStruct` and `substituteTy`.
    fn instantiateConcrete(self: *Checker, template_id: SymbolId, arg_tys: []const Ty) SemanticError!Ty {
        const name = self.symbols.symbol(template_id).name;
        const tmpl = self.env.generic_struct_templates.get(name) orelse return error.SemanticFailed;
        const strukt = switch (tmpl.kind) {
            .struct_type => |s| s,
            else => return error.SemanticFailed,
        };
        if (arg_tys.len != strukt.type_params.len) return error.SemanticFailed;

        const saved_binding = self.current_type_binding;
        const saved_params = self.current_type_params;
        // Field type names (e.g. `arena: *Arena`) must resolve in the TEMPLATE's file
        // context, not the call site's. A caller that imports the field's type under a
        // namespace alias (`heap::Arena`) — or not at all — has no bare `Arena` in scope,
        // so resolving against the call site would spuriously fail and leave the return
        // type an uncollapsed `generic_app`.
        const saved_file = self.file;
        defer {
            self.current_type_binding = saved_binding;
            self.current_type_params = saved_params;
            self.file = saved_file;
        }
        self.file = self.symbols.symbol(template_id).file_name;
        var binding = std.ArrayList(TypeArg).empty;
        defer binding.deinit(self.allocator);
        for (strukt.type_params, arg_tys) |tp_name, arg_ty| {
            try binding.append(self.allocator, .{ .name = tp_name, .ty = arg_ty });
        }
        self.current_type_binding = binding.items;
        self.current_type_params = strukt.type_params;

        // Build a mangled name.
        var mangled_buf: std.ArrayList(u8) = .empty;
        defer mangled_buf.deinit(self.allocator);
        try mangled_buf.appendSlice(self.allocator, name);
        for (binding.items) |arg| {
            try mangled_buf.appendSlice(self.allocator, "__");
            try mangled_buf.appendSlice(self.allocator, arg.name);
            try mangled_buf.append(self.allocator, '_');
            try self.appendTyMangle(&mangled_buf, arg.ty);
        }
        const mangled = try mangled_buf.toOwnedSlice(self.allocator);

        // Return existing instantiation if already done.
        if (self.env.generic_struct_instances.get(mangled)) |inst_id|
            return .{ .named = inst_id };

        // Register a new symbol for the instantiated struct.
        const inst_id = self.symbols.symbols.items.len;
        try self.symbols.symbols.append(self.allocator, .{
            .id = inst_id,
            .name = mangled,
            .link_name = mangled,
            .kind = .type,
            .span = self.symbols.symbol(template_id).span,
            .scope_id = self.symbols.root_scope,
            .owner = null,
            .file_name = self.file,
            .is_public = false,
        });
        try self.symbols.scopes.items[self.symbols.root_scope].names.put(mangled, inst_id);
        try self.symbols.scopes.items[self.symbols.root_scope].symbols.append(self.allocator, inst_id);

        try self.env.symbol_types.put(inst_id, .{ .named = inst_id });
        try self.env.generic_struct_instances.put(mangled, inst_id);
        // Record the reverse mapping so inference can recover `T` from an
        // `*Atomic(u32)` argument matched against an `*Atomic(T)` parameter.
        try self.env.generic_struct_instance_args.put(inst_id, .{
            .template = template_id,
            .args = try self.allocator.dupe(Ty, arg_tys),
        });

        // Build the instantiated struct layout (substitute type params in fields).
        var fields = std.ArrayList(FieldInfo).empty;
        errdefer fields.deinit(self.allocator);
        for (strukt.fields) |field| {
            try fields.append(self.allocator, .{
                .name = field.name,
                .ty = try self.typeFromRef(field.ty), // uses current_type_binding
                .default = field.default,
            });
        }
        try self.env.layouts.put(inst_id, .{
            .kind = .{ .struct_type = try fields.toOwnedSlice(self.allocator) },
            .is_packed = hasAttr(tmpl.attrs, "packed"),
        });

        return .{ .named = inst_id };
    }

    fn resolveTypeParam(self: *Checker, name: []const u8) ?Ty {
        // Check concrete binding first (during instantiation)
        for (self.current_type_binding) |arg| {
            if (std.mem.eql(u8, arg.name, name)) return arg.ty;
        }
        // Then check if it's a declared type param (unbound — stays as type_param)
        for (self.current_type_params) |tp| {
            if (std.mem.eql(u8, tp, name)) return .{ .type_param = name };
        }
        return null;
    }

    /// The closest known type name to `name` (a built-in or a user-declared
    /// type), within a small edit distance — for "did you mean `X`?" hints.
    /// Returns null when nothing is close enough to be a likely typo.
    fn suggestTypeName(self: *Checker, name: []const u8) ?[]const u8 {
        var best: ?[]const u8 = null;
        var best_dist: usize = 3; // only suggest within 2 edits
        const consider = struct {
            fn f(cand: []const u8, target: []const u8, b: *?[]const u8, bd: *usize) void {
                const d = levenshtein(target, cand);
                if (d < bd.*) {
                    bd.* = d;
                    b.* = cand;
                }
            }
        }.f;
        for (builtin_type_names) |cand| consider(cand, name, &best, &best_dist);
        for (self.symbols.symbols.items) |sym| {
            if (sym.kind == .type) consider(sym.name, name, &best, &best_dist);
        }
        // Reject suggestions that are a large fraction of the name (avoids
        // nonsense like suggesting `u8` for a 3-letter typo).
        if (best) |b| if (best_dist * 2 > @max(name.len, b.len)) return null;
        return best;
    }

    /// Diagnose a type name that resolved to nothing: a tailored message for an
    /// unsupported integer width (`u128`), otherwise "unknown type" + a hint.
    fn reportUnknownType(self: *Checker, name: []const u8, span: Span) void {
        if (intWidthName(name)) |w| {
            const p: []const u8 = if (w.signed) "i" else "u";
            if (w.bits > 64) {
                self.emitError(span, "unsupported integer width `{s}`: skarn integers are at most 64-bit — use `{s}64` or `{s}size`", .{ name, p, p });
            } else {
                self.emitError(span, "unsupported integer width `{s}`: skarn has `{s}8`, `{s}16`, `{s}32`, `{s}64` (and `{s}size`), plus sub-byte `{s}1`–`{s}7`", .{ name, p, p, p, p, p, p, p });
            }
            return;
        }
        if (self.suggestTypeName(name)) |hint| {
            self.emitError(span, "unknown type `{s}`; did you mean `{s}`?", .{ name, hint });
        } else {
            self.emitError(span, "unknown type `{s}`", .{name});
        }
    }

    fn typeFromRef(self: *Checker, ty: ast.TypeRef) SemanticError!Ty {
        switch (ty) {
            .type_param => |tp| {
                return self.resolveTypeParam(tp.name) orelse .{ .type_param = tp.name };
            },
            .named => |named| {
                // A qualifier (`ns::Name`) names a real type in another module —
                // never a type param, `Self`, or a built-in scalar.
                if (named.namespace == null) {
                    if (self.resolveTypeParam(named.name)) |tp_ty| return tp_ty;
                    if (std.mem.eql(u8, named.name, "Self")) return self.current_self_ty orelse {
                        self.emitError(named.span, "`Self` is only valid inside a method or a type body", .{});
                        return error.SemanticFailed;
                    };
                }
                if (self.resolveTypeSymbol(named.namespace, named.name)) |id| {
                    if (self.symbols.symbol(id).kind != .type) {
                        self.emitError(named.span, "`{s}` is not a type (it is a {s})", .{ named.name, self.symbols.symbol(id).kind.label() });
                        return error.SemanticFailed;
                    }
                    // Transparent alias: resolve to the underlying type (transitively).
                    if (self.env.alias_refs.get(id)) |aliased| {
                        if (self.alias_depth > 32) {
                            self.emitError(named.span, "type alias `{s}` is cyclic", .{named.name});
                            return error.SemanticFailed;
                        }
                        self.alias_depth += 1;
                        defer self.alias_depth -= 1;
                        return try self.typeFromRef(aliased);
                    }
                    return .{ .named = id };
                }
                if (named.namespace) |ns| {
                    self.emitError(named.span, "unknown type `{s}::{s}`", .{ ns, named.name });
                    return error.SemanticFailed;
                }
                return fromBuiltinName(named.name) orelse {
                    self.reportUnknownType(named.name, named.span);
                    return error.SemanticFailed;
                };
            },
            .pointer => |ptr| {
                const inner = try self.typeFromRef(ptr.inner.*);
                return if (ptr.is_const) try self.constPtrTo(inner) else try self.ptrTo(inner);
            },
            .many_pointer => |ptr| {
                const inner = try self.typeFromRef(ptr.inner.*);
                return if (ptr.is_const) try self.constPtrTo(inner) else try self.ptrTo(inner);
            },
            .optional => |optional| return try self.optionalOf(try self.typeFromRef(optional.inner.*)),
            .slice => |slice| return try self.sliceOf(try self.typeFromRef(slice.inner.*)),
            .array => |array| {
                _ = try self.inferExpr(array.len.*);
                return .{ .array = .{
                    .elem = try self.boxTy(try self.typeFromRef(array.inner.*)),
                    .len = resolveArrayLen(array.len.*, self.env.const_ints),
                } };
            },
            .atomic => |atomic| return try self.typeFromRef(atomic.inner.*),
            .borrow => |borrow| return .{ .borrow = try self.boxTy(try self.typeFromRef(borrow.inner.*)) },
            .fn_type => |func| {
                var params = std.ArrayList(Ty).empty;
                errdefer params.deinit(self.allocator);
                for (func.params) |param| try params.append(self.allocator, try self.typeFromRef(param));
                const ret = try self.typeFromRef(func.ret.*);
                const err = if (func.error_ty) |error_spec| try self.typeFromErrorSpec(error_spec) else null;
                return .{ .fn_ptr = .{
                    .params = try params.toOwnedSlice(self.allocator),
                    .ret = try self.boxTy(if (err) |error_ty_value| .{ .fallible = .{ .ok = try self.boxTy(ret), .err = try self.boxTy(error_ty_value) } } else ret),
                    .thin = func.is_extern,
                } };
            },
            .inline_error_set => |set| return .{ .error_set = try self.errorVariantsFromDecl(set.variants) },
            .generic_inst => |gi| return try self.instantiateGenericStruct(gi),
            .opaque_type => return .void,
        }
    }

    fn typeFromErrorSpec(self: *Checker, spec: ast.ErrorSpec) SemanticError!Ty {
        return switch (spec) {
            .inferred => .error_ty,
            .named => |named| blk: {
                if (std.mem.eql(u8, named.name, "void")) break :blk .error_ty;
                const id = self.resolveTypeSymbol(named.namespace, named.name) orelse {
                    if (named.namespace) |ns| {
                        self.emitError(named.span, "unknown error type `{s}::{s}`", .{ ns, named.name });
                    } else if (self.suggestTypeName(named.name)) |hint| {
                        self.emitError(named.span, "unknown error type `{s}`; did you mean `{s}`?", .{ named.name, hint });
                    } else {
                        self.emitError(named.span, "unknown error type `{s}`", .{named.name});
                    }
                    return error.SemanticFailed;
                };
                if (self.symbols.symbol(id).kind != .type) {
                    self.emitError(named.span, "`{s}` is not an error type (it is a {s})", .{ named.name, self.symbols.symbol(id).kind.label() });
                    return error.SemanticFailed;
                }
                const layout = self.env.layouts.get(id) orelse {
                    self.emitError(named.span, "`{s}` is not an error type", .{named.name});
                    return error.SemanticFailed;
                };
                if (layout.kind != .error_set) {
                    self.emitError(named.span, "`{s}` is not an error type (declare it with `errors {{ ... }}`)", .{named.name});
                    return error.SemanticFailed;
                }
                break :blk .{ .named = id };
            },
            .inline_set => |set| .{ .error_set = try self.errorVariantsFromDecl(set.variants) },
        };
    }

    fn errorVariantsFromDecl(self: *Checker, variants: []const ast.ErrorVariantDecl) SemanticError![]const ErrorVariantInfo {
        var infos = std.ArrayList(ErrorVariantInfo).empty;
        errdefer infos.deinit(self.allocator);

        for (variants) |variant| {
            try infos.append(self.allocator, .{
                .name = variant.name,
                .payload = if (variant.payload) |payload| try self.typeFromRef(payload) else null,
            });
        }

        return infos.toOwnedSlice(self.allocator);
    }

    fn checkFail(self: *Checker, fail: ast.FailStmt) SemanticError!void {
        const err_ty = self.current_error_ty orelse {
            self.emitError(fail.span, "`fail` used in a function without a `!` error return type", .{});
            return error.SemanticFailed;
        };
        const variant = self.findErrorVariant(err_ty, fail.variant) catch {
            self.emitError(fail.span, "unknown error variant `.{s}`", .{fail.variant});
            return error.SemanticFailed;
        };
        if (variant.payload) |payload_ty| {
            if (fail.payload.len != 1) {
                self.emitError(fail.span, "error variant `.{s}` has a payload; provide exactly one value", .{fail.variant});
                return error.SemanticFailed;
            }
            const actual = try self.inferExpr(fail.payload[0]);
            if (!try self.compatible(actual, payload_ty)) {
                self.emitError(fail.payload[0].span, "error payload type mismatch: expected `{s}`, found `{s}`", .{
                    self.formatTy(payload_ty), self.formatTy(actual),
                });
                return error.SemanticFailed;
            }
        } else if (fail.payload.len != 0) {
            self.emitError(fail.span, "error variant `.{s}` does not have a payload", .{fail.variant});
            return error.SemanticFailed;
        }
    }

    fn findErrorVariant(self: *Checker, ty: Ty, name: []const u8) SemanticError!ErrorVariantInfo {
        switch (ty) {
            .error_ty => return .{ .name = name, .payload = null },
            .error_set => |variants| {
                for (variants) |variant| {
                    if (std.mem.eql(u8, variant.name, name)) return variant;
                }
                return error.SemanticFailed;
            },
            .named => |id| {
                const layout = self.env.layouts.get(id) orelse return error.SemanticFailed;
                return switch (layout.kind) {
                    .error_set => |variants| blk: {
                        for (variants) |variant| {
                            if (std.mem.eql(u8, variant.name, name)) break :blk variant;
                        }
                        return error.SemanticFailed;
                    },
                    else => error.SemanticFailed,
                };
            },
            else => return error.SemanticFailed,
        }
    }

    /// True when `ty` (or `*ty`) is a struct that declares a field named `name`.
    fn structHasField(self: *Checker, ty: Ty, name: []const u8) bool {
        const id = typeSymbolOf(ty) orelse return false;
        const layout = self.env.layouts.get(id) orelse return false;
        return switch (layout.kind) {
            .struct_type => |fields| {
                for (fields) |f| if (std.mem.eql(u8, f.name, name)) return true;
                return false;
            },
            else => false,
        };
    }

    /// Field type by name, or null if `base_ty` is not a struct (or has no such
    /// field). Unlike `fieldType`, never emits an error — for speculative checks.
    fn fieldTypeOpt(self: *Checker, base_ty: Ty, name: []const u8) ?Ty {
        const type_id = switch (base_ty) {
            .named => |id| id,
            .pointer, .const_ptr => |inner| switch (inner.*) {
                .named => |id| id,
                else => return null,
            },
            else => return null,
        };
        const layout = self.env.layouts.get(type_id) orelse return null;
        switch (layout.kind) {
            .struct_type => |fields| {
                for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.ty;
                return null;
            },
            else => return null,
        }
    }

    fn fieldType(self: *Checker, base_ty: Ty, name: []const u8, span: Span) SemanticError!Ty {
        // Unknown base (e.g., TARGET pseudo-module) — field access returns unknown.
        if (base_ty == .unknown) return .unknown;
        if (base_ty == .fallible) {
            if (std.mem.eql(u8, name, "ok")) return base_ty.fallible.ok.*;
            if (std.mem.eql(u8, name, "err")) return base_ty.fallible.err.*;
        }
        const type_id = switch (base_ty) {
            .named => |id| id,
            .pointer, .const_ptr => |inner| switch (inner.*) {
                .named => |id| id,
                else => {
                    self.emitError(span, "field access on `{s}` is not supported", .{self.formatTy(base_ty)});
                    return error.SemanticFailed;
                },
            },
            else => {
                self.emitError(span, "field access on `{s}` is not supported", .{self.formatTy(base_ty)});
                return error.SemanticFailed;
            },
        };
        const layout = self.env.layouts.get(type_id) orelse {
            self.emitError(span, "type has no accessible fields", .{});
            return error.SemanticFailed;
        };
        return switch (layout.kind) {
            .struct_type => |fields| blk: {
                for (fields) |field| {
                    if (std.mem.eql(u8, field.name, name)) break :blk field.ty;
                }
                self.emitError(span, "no field `{s}` on this type", .{name});
                return error.SemanticFailed;
            },
            // `Direction.north` — enum variant access returns the enum type itself.
            .variant_type => |variants| blk: {
                for (variants) |v| {
                    if (std.mem.eql(u8, v.name, name)) break :blk .{ .named = type_id };
                }
                self.emitError(span, "unknown variant `.{s}`", .{name});
                return error.SemanticFailed;
            },
            .interface_type => |methods| blk: {
                for (methods) |method| {
                    if (std.mem.eql(u8, method.name, name)) break :blk .{ .fn_ptr = .{
                        .params = &.{},
                        .ret = try self.boxTy(method.return_ty),
                    } };
                }
                self.emitError(span, "no method `{s}` on this interface", .{name});
                return error.SemanticFailed;
            },
            else => {
                self.emitError(span, "field access on `{s}` is not supported", .{self.formatTy(base_ty)});
                return error.SemanticFailed;
            },
        };
    }

    fn firstTypeArg(self: *Checker, call: ast.CallExpr) ?Ty {
        if (call.args.len == 0) return null;
        return switch (call.args[0]) {
            .positional => |expr| switch (expr.kind) {
                .type_ref => |ty| self.typeFromRef(ty) catch null,
                .ident => |name| blk: {
                    if (fromBuiltinName(name)) |builtin_ty| break :blk builtin_ty;
                    // A generic type parameter (e.g. `slice_from_raw_parts(T,…)`
                    // inside a generic) — resolve it before the symbol table,
                    // which has no entry for type params.
                    if (self.resolveTypeParam(name)) |tp_ty| break :blk tp_ty;
                    const id = self.resolveSymbol(name) orelse break :blk null;
                    if (self.symbols.symbol(id).kind != .type) break :blk null;
                    break :blk .{ .named = id };
                },
                else => null,
            },
            .named => null,
        };
    }

    fn ptrTo(self: *Checker, ty: Ty) !Ty {
        return .{ .pointer = try self.boxTy(ty) };
    }

    fn constPtrTo(self: *Checker, ty: Ty) !Ty {
        return .{ .const_ptr = try self.boxTy(ty) };
    }

    /// Walk a field/index/deref chain to the variable it ultimately mutates,
    /// e.g. `list.data` -> `list`, `buf[i]` -> `buf`, `(*p).x` -> `p`. Returns
    /// null when the target is not rooted in a plain variable.
    fn rootVarName(target: ast.Expr) ?[]const u8 {
        return switch (target.kind) {
            .ident => |name| name,
            .field => |f| rootVarName(f.base.*),
            .index => |i| rootVarName(i.base.*),
            .slice => |s| rootVarName(s.base.*),
            .unary => |u| if (u.op == .deref) rootVarName(u.expr.*) else null,
            else => null,
        };
    }

    /// Reject assignments whose target is a dereference of a *const pointer.
    fn checkAssignTarget(self: *Checker, target: ast.Expr) SemanticError!void {
        switch (target.kind) {
            .unary => |u| {
                if (u.op != .deref) return;
                const ptr_ty = try self.inferExpr(u.expr.*);
                if (ptr_ty == .const_ptr) {
                    self.emitError(target.span, "cannot assign through `*const` pointer", .{});
                    return error.SemanticFailed;
                }
            },
            .field => |f| {
                // Writing through ptr.field — check the base pointer.
                const base_ty = try self.inferExpr(f.base.*);
                if (base_ty == .const_ptr) {
                    self.emitError(target.span, "cannot assign to field through `*const` pointer", .{});
                    return error.SemanticFailed;
                }
            },
            else => {},
        }
    }

    fn sliceOf(self: *Checker, ty: Ty) !Ty {
        return .{ .slice = try self.boxTy(ty) };
    }

    fn optionalOf(self: *Checker, ty: Ty) !Ty {
        return .{ .optional = try self.boxTy(ty) };
    }

    fn boxTy(self: *Checker, ty: Ty) !*const Ty {
        const ptr = try self.allocator.create(Ty);
        ptr.* = ty;
        return ptr;
    }

    fn isErrorType(self: *const Checker, ty: Ty) bool {
        return switch (ty) {
            .error_ty, .error_set => true,
            .named => |id| blk: {
                const layout = self.env.layouts.get(id) orelse break :blk false;
                break :blk layout.kind == .error_set;
            },
            else => false,
        };
    }

    fn isAnyTy(self: *Checker, ty: Ty) bool {
        return switch (ty) {
            .named => |id| std.mem.eql(u8, self.symbols.symbol(id).name, "Any"),
            else => false,
        };
    }

    fn compatible(self: *Checker, actual: Ty, expected: Ty) !bool {
        if (expected == .borrow) return self.compatible(actual, expected.borrow.*);
        if (actual == .borrow) return self.compatible(actual.borrow.*, expected);
        if (sameTy(actual, expected)) return true;
        // Any value auto-wraps into an `Any` (the compiler inserts `any(x)`).
        if (self.isAnyTy(expected) and !self.isAnyTy(actual)) return true;
        if (try self.interfaceCoercion(actual, expected)) return true;
        if (expected == .optional) {
            if (actual == .null_ptr) return true;
            return try self.compatible(actual, expected.optional.*);
        }
        if (actual == .int_lit and expected.isInteger()) return true;
        if (expected == .int_lit and actual.isInteger()) return true;
        if (actual == .float_lit and expected.isFloat()) return true;
        if (expected == .float_lit and actual.isFloat()) return true;
        // *T is implicitly usable as *const T (const promotion).
        if (actual == .pointer and expected == .const_ptr)
            return sameTy(actual.pointer.*, expected.const_ptr.*);
        if (actual == .null_ptr) return switch (expected) {
            .pointer, .const_ptr, .slice, .named, .optional => true,
            else => false,
        };
        if (actual == .error_ty and self.isErrorType(expected)) return true;
        if (expected == .error_ty and self.isErrorType(actual)) return true;
        if (expected == .unknown or actual == .unknown) return true;
        return false;
    }

    fn interfaceFromPointer(self: *Checker, ty: Ty) ?SymbolId {
        const id = switch (ty) {
            .pointer, .const_ptr => |inner| switch (inner.*) {
                .named => |id| id,
                else => return null,
            },
            else => return null,
        };
        const layout = self.env.layouts.get(id) orelse return null;
        return if (layout.kind == .interface_type) id else null;
    }

    fn findInterfaceMethod(self: *Checker, interface_id: SymbolId, name: []const u8) ?InterfaceMethodInfo {
        const layout = self.env.layouts.get(interface_id) orelse return null;
        const methods = switch (layout.kind) {
            .interface_type => |methods| methods,
            else => return null,
        };
        for (methods) |method| if (std.mem.eql(u8, method.name, name)) return method;
        return null;
    }

    fn interfaceCoercion(self: *Checker, actual: Ty, expected: Ty) !bool {
        const interface_id = self.interfaceFromPointer(expected) orelse return false;
        const concrete_id = switch (actual) {
            .pointer, .const_ptr => |inner| switch (inner.*) {
                .named => |id| id,
                else => return false,
            },
            else => return false,
        };
        const key = try interfaceImplKey(
            self.allocator,
            self.symbols.symbol(concrete_id).name,
            self.symbols.symbol(interface_id).name,
        );
        return self.env.interface_impls.contains(key);
    }
};

fn interfaceImplKey(allocator: std.mem.Allocator, type_name: []const u8, interface_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} as {s}", .{ type_name, interface_name });
}

fn substituteInterfaceSelf(checker: *Checker, ty: Ty, interface_id: SymbolId, concrete_id: SymbolId) !Ty {
    return switch (ty) {
        .named => |id| if (id == interface_id) .{ .named = concrete_id } else ty,
        .pointer => |inner| .{ .pointer = try checker.boxTy(try substituteInterfaceSelf(checker, inner.*, interface_id, concrete_id)) },
        .const_ptr => |inner| .{ .const_ptr = try checker.boxTy(try substituteInterfaceSelf(checker, inner.*, interface_id, concrete_id)) },
        .optional => |inner| .{ .optional = try checker.boxTy(try substituteInterfaceSelf(checker, inner.*, interface_id, concrete_id)) },
        .slice => |inner| .{ .slice = try checker.boxTy(try substituteInterfaceSelf(checker, inner.*, interface_id, concrete_id)) },
        .borrow => |inner| .{ .borrow = try checker.boxTy(try substituteInterfaceSelf(checker, inner.*, interface_id, concrete_id)) },
        else => ty,
    };
}

fn isPointerTy(ty: Ty) bool {
    return ty == .pointer or ty == .const_ptr;
}

fn blockDefinitelyReturns(self: *Checker, block: ast.Block) bool {
    for (block.statements) |stmt| {
        if (stmtDefinitelyReturns(self, stmt)) return true;
    }
    return false;
}

fn stmtDefinitelyReturns(self: *Checker, stmt: ast.Stmt) bool {
    return switch (stmt) {
        .return_stmt, .fail_stmt => true,
        .expr => |e| switch (e.kind) {
            // `expr!!` panics on null/error — counts as exit on that path.
            .force_unwrap => true,
            // A call to a named function whose name starts with `@panic` or is `@panic`
            // always terminates — treat it as definitely returning so CFG accepts it.
            .call => |call| switch (call.callee.kind) {
                .ident => |name| isRuntimeNoReturnName(name),
                // `core::panic` / `core::exit` / `core::abort` also never return.
                .scope_access => |sa| isCoreNamespace(sa) and
                    (std.mem.eql(u8, sa.member, "panic") or std.mem.eql(u8, sa.member, "exit") or std.mem.eql(u8, sa.member, "abort")),
                else => false,
            },
            else => false,
        },
        .break_stmt, .continue_stmt => true,
        .if_stmt => |iff| iff.else_block != null and
            blockDefinitelyReturns(self, iff.then_block) and
            blockDefinitelyReturns(self, iff.else_block.?),
        .unsafe_block => |block| blockDefinitelyReturns(self, block),
        .zone_block => |zb| blockDefinitelyReturns(self, zb.body),
        .defer_stmt => false,
        .comptime_run => |b| blockDefinitelyReturns(self, b),
        .comptime_if => |ci| ci.else_block != null and
            blockDefinitelyReturns(self, ci.then_block) and
            blockDefinitelyReturns(self, ci.else_block.?),
        // A match returns on all paths when it is exhaustive (proven during
        // checking — full enum coverage or an `else`) and every arm returns.
        .match_stmt => |m| blk: {
            if (!self.exhaustive_matches.contains(m.span.start)) break :blk false;
            for (m.arms) |arm| {
                if (!blockDefinitelyReturns(self, arm.body)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

/// Arena methods that hand back memory owned by the arena — their result, when
/// the receiver is a `zone` handle, is zone-owned and subject to escape checks.
/// (`mark`/`restore`/`reset`/`deinit` don't yield arena-interior pointers.)
fn isArenaAllocMethod(name: []const u8) bool {
    const allocs = [_][]const u8{
        "new", "new_slice", "alloc", "alloc_one", "alloc_bytes", "dupe",
        "try_alloc", "try_alloc_bytes",
    };
    for (allocs) |a| if (std.mem.eql(u8, name, a)) return true;
    return false;
}

/// Built-in generic constraints (`$T: Numeric`, `$T: Struct`, …) — composable
/// type predicates checked at instantiation, distinct from interface conformance.
const BuiltinConstraint = union(enum) {
    ok,
    not_builtin,
    /// A human-readable description of what was expected (e.g. "a numeric type").
    fail: []const u8,
};

fn checkBuiltinConstraint(self: *Checker, name: []const u8, ty: Ty) BuiltinConstraint {
    const eq = std.mem.eql;
    const ok = BuiltinConstraint{ .ok = {} };
    if (eq(u8, name, "Numeric")) return if (ty.isNumeric()) ok else .{ .fail = "a numeric type" };
    if (eq(u8, name, "Int") or eq(u8, name, "Integer")) return if (ty.isInteger()) ok else .{ .fail = "an integer type" };
    if (eq(u8, name, "Float")) return if (ty.isFloat()) ok else .{ .fail = "a float type" };
    if (eq(u8, name, "Bool")) return if (ty.isBool()) ok else .{ .fail = "`bool`" };
    if (eq(u8, name, "Signed")) return if (isSignedIntTy(ty)) ok else .{ .fail = "a signed integer" };
    if (eq(u8, name, "Unsigned")) return if (isUnsignedIntTy(ty)) ok else .{ .fail = "an unsigned integer" };
    if (eq(u8, name, "Struct")) return if (tyLayoutIs(self, ty, .struct_type)) ok else .{ .fail = "a struct type" };
    if (eq(u8, name, "Enum")) return if (tyLayoutIs(self, ty, .variant_type)) ok else .{ .fail = "an enum type" };
    if (eq(u8, name, "Ptr") or eq(u8, name, "Pointer")) return switch (ty) {
        .pointer, .const_ptr => ok,
        else => .{ .fail = "a pointer type" },
    };
    return .not_builtin;
}

/// True when `ty` is a named type whose layout has the given kind tag.
fn tyLayoutIs(self: *Checker, ty: Ty, comptime tag: std.meta.Tag(TypeKind)) bool {
    const id = switch (ty) {
        .named => |i| i,
        else => return false,
    };
    const layout = self.env.layouts.get(id) orelse return false;
    return std.meta.activeTag(layout.kind) == tag;
}

fn isSignedIntTy(ty: Ty) bool {
    return switch (ty) {
        .i8, .i16, .i32, .i64, .isize, .int_lit => true,
        else => false,
    };
}

fn isUnsignedIntTy(ty: Ty) bool {
    return switch (ty) {
        .u8, .u16, .u32, .u64, .byte, .usize, .addr => true,
        else => false,
    };
}

fn isRuntimeNoReturnName(name: []const u8) bool {
    return std.mem.eql(u8, name, "@panic") or
        std.mem.eql(u8, name, "exit") or
        std.mem.eql(u8, name, "abort");
}

pub fn tyMangle(ty: Ty) []const u8 {
    return switch (ty) {
        .i8 => "i8",
        .i16 => "i16",
        .i32 => "i32",
        .i64 => "i64",
        .u8 => "u8",
        .u16 => "u16",
        .u32 => "u32",
        .u64 => "u64",
        .f32 => "f32",
        .f64 => "f64",
        .byte => "byte",
        .rune => "rune",
        .bool => "bool",
        .void => "void",
        .usize => "usize",
        .isize => "isize",
        .pointer => "ptr",
        .const_ptr => "cptr",
        .optional => "opt",
        .slice => "slice",
        .borrow => "borrow",
        .named => "named",
        .type_param => |n| n,
        else => "unknown",
    };
}

/// True if `ty` still contains an unbound type variable (directly or nested),
/// i.e. it is not yet a fully concrete type.
fn tyContainsTypeParam(ty: Ty) bool {
    return switch (ty) {
        .type_param => true,
        .pointer, .const_ptr, .optional, .slice, .borrow, .list, .map, .range => |inner| tyContainsTypeParam(inner.*),
        .array => |arr| tyContainsTypeParam(arr.elem.*),
        .generic_app => |app| {
            for (app.args) |arg| if (tyContainsTypeParam(arg)) return true;
            return false;
        },
        .fallible => |f| tyContainsTypeParam(f.ok.*) or tyContainsTypeParam(f.err.*),
        else => false,
    };
}

fn sameTy(a: Ty, b: Ty) bool {
    if (@as(std.meta.Tag(Ty), a) != @as(std.meta.Tag(Ty), b)) return false;
    return switch (a) {
        .pointer => |pa| sameTy(pa.*, b.pointer.*),
        .const_ptr => |pa| sameTy(pa.*, b.const_ptr.*),
        .optional => |oa| sameTy(oa.*, b.optional.*),
        .slice => |sa| sameTy(sa.*, b.slice.*),
        .borrow => |ba| sameTy(ba.*, b.borrow.*),
        .array => |aa| sameTy(aa.elem.*, b.array.elem.*) and aa.len == b.array.len,
        .named => |id| id == b.named,
        .error_set => |variants| sameErrorVariants(variants, b.error_set),
        .fallible => |fa| sameTy(fa.ok.*, b.fallible.ok.*) and sameTy(fa.err.*, b.fallible.err.*),
        else => true,
    };
}

fn tyCanCarryZoneOwner(ty: Ty) bool {
    return switch (ty) {
        .pointer, .const_ptr, .slice, .borrow, .optional, .fallible, .named, .unknown => true,
        else => false,
    };
}

fn containsBorrow(ty: Ty) bool {
    return switch (ty) {
        .borrow => true,
        .pointer, .const_ptr, .optional, .slice => |inner| containsBorrow(inner.*),
        .array => |array| containsBorrow(array.elem.*),
        .fallible => |fallible| containsBorrow(fallible.ok.*) or containsBorrow(fallible.err.*),
        else => false,
    };
}

fn typeRefContainsBorrow(ty: ast.TypeRef) bool {
    return switch (ty) {
        .borrow => true,
        .pointer => |pointer| typeRefContainsBorrow(pointer.inner.*),
        .many_pointer => |pointer| typeRefContainsBorrow(pointer.inner.*),
        .optional => |optional| typeRefContainsBorrow(optional.inner.*),
        .slice => |slice| typeRefContainsBorrow(slice.inner.*),
        .array => |array| typeRefContainsBorrow(array.inner.*),
        .atomic => |atomic| typeRefContainsBorrow(atomic.inner.*),
        .fn_type => |function| blk: {
            for (function.params) |param| if (typeRefContainsBorrow(param)) break :blk true;
            break :blk typeRefContainsBorrow(function.ret.*);
        },
        .generic_inst => |generic| blk: {
            for (generic.args) |arg| if (typeRefContainsBorrow(arg)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn sameErrorVariants(a: []const ErrorVariantInfo, b: []const ErrorVariantInfo) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name)) return false;
        if (left.payload == null and right.payload == null) continue;
        if (left.payload == null or right.payload == null) return false;
        if (!sameTy(left.payload.?, right.payload.?)) return false;
    }
    return true;
}

fn intLiteralType(text: []const u8) Ty {
    // An explicit suffix fixes the literal's type; without one it stays a
    // polymorphic `int_lit` that coerces to its context (defaulting to i32).
    // Every width must be covered here — a missed suffix (e.g. `0i64`) silently
    // collapses to i32, undersizing the value's storage and truncating it.
    if (std.mem.endsWith(u8, text, "usize")) return .usize;
    if (std.mem.endsWith(u8, text, "isize")) return .isize;
    if (std.mem.endsWith(u8, text, "u64")) return .u64;
    if (std.mem.endsWith(u8, text, "u32")) return .u32;
    if (std.mem.endsWith(u8, text, "u16")) return .u16;
    if (std.mem.endsWith(u8, text, "u8")) return .u8;
    if (std.mem.endsWith(u8, text, "i64")) return .i64;
    if (std.mem.endsWith(u8, text, "i32")) return .i32;
    if (std.mem.endsWith(u8, text, "i16")) return .i16;
    if (std.mem.endsWith(u8, text, "i8")) return .i8;
    if (std.mem.endsWith(u8, text, "byte")) return .byte;
    return .int_lit;
}

fn floatLiteralType(text: []const u8) Ty {
    if (std.mem.endsWith(u8, text, "f32")) return .f32;
    if (std.mem.endsWith(u8, text, "f64")) return .f64;
    return .float_lit;
}

/// The integer-literal suffixes skarn accepts (mirrors `intLiteralType`).
const int_literal_suffixes = [_][]const u8{
    "usize", "isize", "u64", "u32", "u16", "u8",
    "i64",   "i32",   "i16", "i8",  "byte",
};

/// Split off an integer literal's trailing type-suffix (possibly empty) by
/// consuming the numeric body in its own radix, mirroring the lexer's number
/// scan. Splitting on the radix is what tells a real suffix from hex digits, so
/// `0xABC` yields no suffix while `0xFFu32` / `0u128` yield `u32` / `u128`.
fn intLiteralSuffix(text: []const u8) []const u8 {
    var i: usize = 0;
    var radix: u8 = 10;
    if (text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        i = 2;
        radix = 16;
    } else if (text.len >= 2 and text[0] == '0' and (text[1] == 'b' or text[1] == 'B')) {
        i = 2;
        radix = 2;
    }
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '_') continue;
        const is_digit = switch (radix) {
            16 => std.ascii.isHex(ch),
            2 => ch == '0' or ch == '1',
            else => std.ascii.isDigit(ch),
        };
        if (!is_digit) break;
    }
    return text[i..];
}

fn isValidIntSuffix(suffix: []const u8) bool {
    for (int_literal_suffixes) |valid| if (std.mem.eql(u8, suffix, valid)) return true;
    return false;
}

/// Split off a float literal's trailing type-suffix (possibly empty). skarn float
/// literals are `<digits>.<digits>` so the suffix is whatever follows the
/// fractional digits — only `f32`/`f64` are valid.
fn floatLiteralSuffix(text: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return "";
    var i: usize = dot + 1;
    while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == '_')) : (i += 1) {}
    return text[i..];
}

fn parseArrayLen(expr: ast.Expr) u64 {
    return switch (expr.kind) {
        .int => |text| @intCast(@max(parseIntLiteral(text), 0)),
        else => 0,
    };
}

/// Evaluate an array-size expression to a length: an integer literal, a named
/// integer constant (`N :: 29`), or simple arithmetic over those (`2*W + 1`).
/// Falls back to 0 for anything it can't fold at this stage.
pub fn resolveArrayLen(expr: ast.Expr, const_ints: std.StringHashMap(u64)) u64 {
    return switch (expr.kind) {
        .int => |text| @intCast(@max(parseIntLiteral(text), 0)),
        .ident => |name| const_ints.get(name) orelse 0,
        .binary => |b| blk: {
            const l = resolveArrayLen(b.left.*, const_ints);
            const r = resolveArrayLen(b.right.*, const_ints);
            break :blk switch (b.op) {
                .add => l +% r,
                .sub => if (l >= r) l - r else 0,
                .mul => l *% r,
                .div => if (r != 0) l / r else 0,
                .rem => if (r != 0) l % r else 0,
                else => 0,
            };
        },
        else => 0,
    };
}

fn parseIntLiteral(text: []const u8) i128 {
    var value: i128 = 0;
    var start: usize = 0;
    var radix: i128 = 10;
    if (text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        start = 2;
        radix = 16;
    } else if (text.len >= 2 and text[0] == '0' and (text[1] == 'b' or text[1] == 'B')) {
        start = 2;
        radix = 2;
    }
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
    return value;
}

fn hasAttr(attrs: []const ast.Attribute, name: []const u8) bool {
    for (attrs) |attr| if (std.mem.eql(u8, attr.name, name)) return true;
    return false;
}

/// Returns the export symbol name from `#export` or `#export("name")`.
/// `#export` with no args → null (keep function's own name, just set external linkage).
/// `#export("sym")` → "sym".
pub fn exportSym(attrs: []const ast.Attribute) ?[]const u8 {
    for (attrs) |attr| {
        if (!std.mem.eql(u8, attr.name, "export")) continue;
        if (attr.args.len > 0) {
            return switch (attr.args[0].kind) {
                .string => |s| trimQuotes(s),
                else => "",
            };
        }
        return ""; // #export with no args — empty string signals "use own name"
    }
    return null;
}

/// Returns the deprecation message from `#deprecated` or `#deprecated("msg")`.
fn deprecatedMsg(attrs: []const ast.Attribute) ?[]const u8 {
    for (attrs) |attr| {
        if (!std.mem.eql(u8, attr.name, "deprecated")) continue;
        if (attr.args.len > 0) {
            return switch (attr.args[0].kind) {
                .string => |s| trimQuotes(s),
                else => "",
            };
        }
        return "";
    }
    return null;
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

fn trimQuotes(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') return text[1 .. text.len - 1];
    return text;
}

/// The defining type symbol of `ty` (unwrapping a single pointer level), or null.
fn typeSymbolOf(ty: Ty) ?SymbolId {
    return switch (ty) {
        .named => |id| id,
        .pointer => |inner| switch (inner.*) {
            .named => |id| id,
            else => null,
        },
        .const_ptr => |inner| switch (inner.*) {
            .named => |id| id,
            else => null,
        },
        else => null,
    };
}

/// Whether an expression denotes an addressable lvalue (so `&expr` is meaningful):
/// a name, a field/element of one, or a dereference.
fn isAddressable(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .ident => true,
        .field => |f| isAddressable(f.base.*),
        .index => |ix| isAddressable(ix.base.*),
        .unary => |u| u.op == .deref,
        else => false,
    };
}

/// `core::<member>` — the reserved compiler-builtin namespace. Recognized at the
/// `::` callee/value sites and routed to the builtin dispatch (keyed on member).
fn isCoreNamespace(sa: ast.ScopeAccess) bool {
    return sa.base.kind == .ident and std.mem.eql(u8, sa.base.kind.ident, "core");
}

/// Map a `core::` member's friendly spelling to the internal builtin name the
/// dispatch keys on (the names were tidied when builtins moved under `core::`).
/// `core::panic` is handled separately (it maps to `@panic` in IR).
fn coreRename(member: []const u8) []const u8 {
    if (std.mem.eql(u8, member, "type_id")) return "typeid_of";
    if (std.mem.eql(u8, member, "narrow")) return "truncate_to";
    if (std.mem.eql(u8, member, "slice_raw")) return "slice_from_raw_parts";
    return member;
}

/// A `core::` math/bit builtin that returns its FIRST argument's type
/// (`core::min(a,b)→type of a`, `core::count_ones(x)→type of x`, …).
fn isCoreScalarBuiltin(name: []const u8) bool {
    inline for (.{
        "count_ones",    "count_zeros",   "leading_zeros", "trailing_zeros",
        "swap_bytes",    "reverse_bits",  "rotate_left",   "rotate_right",
        "min", "max", "abs", "clamp", "sqrt", "floor", "ceil", "round",
        "trunc", "sin", "cos", "pow", "fma",
    }) |b| if (std.mem.eql(u8, name, b)) return true;
    return false;
}

/// A builtin that now lives ONLY under `core::` — calling it by its bare name is
/// an error (the user must write `core::<name>`). Excludes the `@panic`/`exit`/
/// `abort` runtime intrinsics and the compiler-internal `__str_cat`/`__build_*`.
fn isMigratedBuiltin(name: []const u8) bool {
    inline for (.{
        "sizeof",        "type_info",      "type_name",     "typeid_of", "type_id",
        "truncate_to",   "narrow",         "slice_raw",     "any",
        "slice_from_raw_parts", "ptr_from_int", "unaligned_read", "volatile_store",
        "atomic_load",   "atomic_store",   "asm",           "reject",    "require",
        "atomic_add",    "atomic_sub",     "atomic_and",    "atomic_or", "atomic_xor",
        "atomic_exchange", "atomic_cas",   "atomic_fence",  "atomic_max", "atomic_min",
        "atomic_nand",     "fn_ptr",
        "compiler_decls", "compiler_error", "compiler_remove",
    }) |b| if (std.mem.eql(u8, name, b)) return true;
    return false;
}

fn isBuiltinValue(name: []const u8) bool {
    inline for (.{
        "truncate_to", "ptr_from_int",   "volatile_store",
        "slice_from_raw_parts",
        "sizeof",      "unaligned_read", "asm",
        "atomic_load", "atomic_store",   "volatile",
        "atomic_add",  "atomic_sub",     "atomic_and",  "atomic_or", "atomic_xor",
        "atomic_exchange", "atomic_cas", "atomic_fence", "atomic_max", "atomic_min",
        "atomic_nand",     "fn_ptr",
        ".acquire",
        // Compile-time reflection builtins
           "type_info",      "type_name",      "reject",          "require",
           "typeid_of",      "any",
        // Compile-time program introspection (Phase 3 message loop)
        "compiler_decls", "__str_cat", "compiler_error", "compiler_remove",
        // std.build host intrinsics (the build system, comptime-only)
        "__build_artifact", "__build_opt",     "__build_link",
        "__build_libpath",  "__build_output",  "__build_define",
        "__build_default",  "__build_run",     "__build_test",
        "__build_require",  "__build_depend",  "__build_subsystem",
        "__build_entry",    "__build_stack",   "__build_linkflag",
        "__build_outdir",   "__build_version", "__build_desc",
        "__build_workspace", "__build_outroot", "__build_install",
        "__build_optionflag", "__build_optionstr", "__build_summary",
        "__build_linkmode", "__build_runtimefile", "__build_nodefaultlibs", "__build_linklibc",
        // Compile-time pseudo-modules
        "TARGET",
    }) |builtin| {
        if (std.mem.eql(u8, name, builtin)) return true;
    }
    return false;
}
