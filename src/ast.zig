const Span = @import("lexer/span.zig").Span;

pub const NodeId = u32;

pub const Module = struct {
    file_name: []const u8,
    items: []const Item,

    pub fn empty(file_name: []const u8) Module {
        return .{ .file_name = file_name, .items = &.{} };
    }
};

pub const Item = union(enum) {
    import: ImportDecl,
    const_decl: ConstDecl,
    type_decl: TypeDecl,
    function: FunctionDecl,
    interface_impl: InterfaceImpl,
    system_library: SystemLibraryDecl,

    pub fn name(self: Item) ?[]const u8 {
        return switch (self) {
            .import => null,
            .const_decl => |decl| decl.name,
            .type_decl => |decl| decl.name,
            .function => |decl| decl.name,
            .interface_impl => null,
            .system_library => null,
        };
    }

    pub fn span(self: Item) Span {
        return switch (self) {
            .import => |decl| decl.span,
            .const_decl => |decl| decl.span,
            .type_decl => |decl| decl.span,
            .function => |decl| decl.span,
            .interface_impl => |decl| decl.span,
            .system_library => |decl| decl.span,
        };
    }

    pub fn fileName(self: Item) []const u8 {
        return switch (self) {
            .import => |decl| decl.file_name,
            .const_decl => |decl| decl.file_name,
            .type_decl => |decl| decl.file_name,
            .function => |decl| decl.file_name,
            .interface_impl => |decl| decl.file_name,
            .system_library => |decl| decl.file_name,
        };
    }

    pub fn isPublic(self: Item) bool {
        return switch (self) {
            .const_decl => |decl| decl.is_public,
            .type_decl => |decl| decl.is_public,
            .function => |decl| decl.is_public,
            else => false,
        };
    }
};

pub const ImportDecl = struct {
    path: []const []const u8,
    /// Selective import `#import a.b.{ x, y };` — brings `x`, `y` in unqualified.
    names: ?[]const []const u8 = null,
    /// Glob `#import a.b.*;` — brings every public name in unqualified.
    glob: bool = false,
    /// Namespace alias for `#import a.b as c;` (accessed `c::member`). When null
    /// and the import is neither selective nor glob, the namespace is the last
    /// path segment (`#import a.b;` → `b::member`).
    alias: ?[]const u8 = null,
    file_name: []const u8,
    resolved_file: ?[]const u8 = null,
    span: Span,

    /// The namespace name a bare/aliased import binds, or null for
    /// selective/glob imports (which introduce no namespace).
    pub fn namespace(self: ImportDecl) ?[]const u8 {
        if (self.names != null or self.glob) return null;
        if (self.alias) |a| return a;
        if (self.path.len == 0) return null;
        return self.path[self.path.len - 1];
    }
};

/// Jai-style `#system_library("name");` top-level declaration — declares a
/// dependency on a native/system library that the linker should pull in
/// (e.g. `#system_library("raylib");` becomes `raylib.lib` on Windows).
/// This is purely a linking directive; it introduces no symbols into scope.
pub const SystemLibraryDecl = struct {
    /// Library name without extension, e.g. "raylib".
    name: []const u8,
    file_name: []const u8,
    span: Span,
};

pub const Attribute = struct {
    name: []const u8,
    args: []const Expr,
    span: Span,
};

pub const ConstDecl = struct {
    attrs: []const Attribute,
    name: []const u8,
    file_name: []const u8,
    /// The file's source text, for diagnostics tied to this decl (e.g. a `#run`
    /// initializer the comptime VM can't evaluate). Defaults to empty for
    /// compiler-synthesized consts.
    source: []const u8 = "",
    is_public: bool = false,
    value: Expr,
    /// A mutable top-level global: `name: T = init;` (vs the immutable `name :: …`).
    /// The `=` marks it mutable, mirroring locals; `ty` is its explicit type.
    is_mutable: bool = false,
    ty: ?TypeRef = null,
    span: Span,
};

pub const TypeDecl = struct {
    attrs: []const Attribute,
    name: []const u8,
    file_name: []const u8,
    is_public: bool = false,
    kind: TypeDeclKind,
    span: Span,
};

pub const TypeDeclKind = union(enum) {
    distinct: TypeRef,
    /// `Name :: <type>;` — a transparent alias (interchangeable with the
    /// underlying type), unlike `distinct` which is a new nominal type.
    alias: TypeRef,
    opaque_type,
    struct_type: StructDecl,
    errors: ErrorDecl,
    enum_type: EnumDecl,
    interface_type: InterfaceDecl,
};

pub const InterfaceDecl = struct {
    methods: []const FunctionDecl,
};

pub const InterfaceImpl = struct {
    type_name: []const u8,
    interface_name: []const u8,
    file_name: []const u8,
    methods: []const FunctionDecl,
    span: Span,
};

/// An enum declaration: `Name :: enum { variant, variant: T, ... }`
pub const EnumDecl = struct {
    variants: []const EnumVariantDecl,
};

pub const EnumVariantDecl = struct {
    name: []const u8,
    payload: ?TypeRef, // null → no payload
    span: Span,
};

pub const StructDecl = struct {
    type_params: []const []const u8, // e.g. ["T"] for struct($T: type) { ... }
    /// Constraints on the type params (`struct($T: Native) { … }`), mirroring the
    /// `fn($T: Name)` form. Checked at concrete instantiation; also inherited by
    /// each in-struct method (see `methods`) so the method call site enforces them.
    type_constraints: []const TypeConstraint = &.{},
    fields: []const FieldDecl,
    /// Associated declarations written inside the struct body
    /// (`name :: fn(...) { ... }`). The parser also hoists each to a synthetic
    /// top-level function named `"<Struct>.<method>"` (with `Self` substituted and
    /// the struct's type params inherited) so the existing generic/UFCS machinery
    /// handles them; this list is kept for reference/introspection.
    methods: []const FunctionDecl = &.{},
};

pub const ErrorDecl = struct {
    variants: []const ErrorVariantDecl,
};

pub const ErrorVariantDecl = struct {
    name: []const u8,
    payload: ?TypeRef,
    span: Span,
};

pub const FieldDecl = struct {
    name: []const u8,
    ty: TypeRef,
    /// `name: T = expr` — the value used when a literal omits this field. Null
    /// when the field has no default (it must then be supplied explicitly).
    default: ?Expr = null,
    span: Span,
};

/// One `.name = value` entry in a named struct literal `.{ .x = 1, .y = 2 }`.
pub const FieldInit = struct {
    name: []const u8,
    value: Expr,
    span: Span,
};

/// A constraint on a generic type parameter: `$T: InterfaceName`.
pub const TypeConstraint = struct {
    param: []const u8, // type parameter name, e.g. "T"
    interface: []const u8, // required interface, e.g. "Writer"
    span: Span,
};

pub const FunctionDecl = struct {
    attrs: []const Attribute,
    name: []const u8,
    file_name: []const u8,
    source: []const u8,
    is_public: bool = false,
    /// `name :: macro(...) { ... }` — a compile-time AST template, expanded at
    /// its `#insert` call sites by the macroexpand pass and never lowered.
    is_macro: bool = false,
    /// `Name :: constraint($T) { ... }` — a named, reusable comptime type
    /// predicate. Structurally a generic function whose body inspects
    /// `type_info(T)` and may `reject(msg)`; never lowered, run at `$T: Name`
    /// resolution sites on the resolution VM.
    is_constraint: bool = false,
    type_params: []const []const u8,
    /// Names among `type_params` that are *output* type params (`-> $Acc`):
    /// not inferred from value args nor passed explicitly, but computed by the
    /// `where` clause during resolution.
    output_type_params: []const []const u8 = &.{},
    type_constraints: []const TypeConstraint = &.{}, // $T: Interface constraints
    params: []const Param,
    return_ty: TypeRef,
    error_ty: ?ErrorSpec,
    /// Optional `where { … }` clause: a comptime predicate run per generic
    /// instantiation that may `reject("msg")` the type binding. Null when absent.
    where_clause: ?Block = null,
    body: ?Block,
    span: Span,
};

pub const Param = struct {
    name: []const u8,
    ty: TypeRef,
    // When true, the param IS a type argument ($T: type) — its name is the type var.
    is_type_param: bool = false,
    span: Span,
};

pub const Block = struct {
    statements: []const Stmt,
    span: Span,
};

pub const Stmt = union(enum) {
    local_infer: LocalInfer,
    local_typed: LocalTyped,
    assign: AssignStmt,
    return_stmt: ReturnStmt,
    fail_stmt: FailStmt,
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
    for_range: ForRangeStmt,
    for_slice: ForSliceStmt,
    unsafe_block: Block,
    break_stmt: Span,
    continue_stmt: Span,
    zone_block: ZoneBlock,
    defer_stmt: DeferStmt,
    match_stmt: MatchStmt,
    comptime_if: ComptimeIfStmt,
    comptime_run: Block,
    insert_stmt: InsertStmt,
    comptime_for: ComptimeForStmt,
    expr: Expr,
};

/// `#insert <expr>;` — splice compile-time-generated code at this point.
/// In slice 1 the operand must be a literal `#quote { ... }`; the quoted
/// block's statements are spliced into the enclosing scope and re-checked.
pub const InsertStmt = struct {
    operand: Expr,
    span: Span,
};

/// `#for i in a..b { ... }` — a compile-time *unrolled* loop. The macroexpand
/// pass evaluates the (literal/comptime) bounds and emits the body once per
/// iteration, with `$(i)` splices replaced by that iteration's index literal.
/// Generative codegen (e.g. an identity matrix) without a runtime loop.
pub const ComptimeForStmt = struct {
    binding: []const u8,
    start: Expr,
    end: Expr,
    inclusive: bool,
    body: Block,
    span: Span,
};

pub const ComptimeIfStmt = struct {
    condition: Expr,
    then_block: Block,
    else_block: ?Block,
    span: Span,
};

pub const MatchStmt = struct {
    subject: Expr,
    arms: []const MatchArm,
    span: Span,
};

pub const MatchArm = struct {
    pattern: MatchPattern,
    binding: ?[]const u8, // |x| capture, null if none
    guard: ?Expr = null, // `if <cond>` — arm taken only when the guard holds
    body: Block,
    span: Span,
};

pub const MatchPattern = union(enum) {
    enum_variant: []const u8,
    int_values: []const Expr,
    /// `lo..hi` / `lo..=hi` — an integer range.
    range: RangePattern,
    /// `"a"` or grouped `"a", "b"` — string literal pattern(s).
    strings: []const []const u8,
    /// A bare identifier — binds the whole subject and matches anything
    /// (a named catch-all, mainly to give a `if`-guard something to test).
    binding: []const u8,
    else_arm,
};

pub const RangePattern = struct {
    lo: Expr,
    hi: Expr,
    inclusive: bool,
};

/// `match subject { pattern => value, ... }` in *expression* position — each arm
/// yields a value, the whole `match` is that value. Must be exhaustive.
pub const MatchExpr = struct {
    subject: *const Expr,
    arms: []const MatchExprArm,
    span: Span,
};

pub const MatchExprArm = struct {
    pattern: MatchPattern,
    binding: ?[]const u8, // |x| capture, null if none
    guard: ?Expr = null, // `if <cond>` — arm taken only when the guard holds
    value: Expr,
    span: Span,
};

pub const DeferStmt = struct {
    mode: DeferMode,
    body: Block,
    span: Span,
};

pub const DeferMode = enum {
    always,
    ok,
    err,
};

pub const ZoneBlock = struct {
    name: []const u8,
    kind: []const u8,
    body: Block,
    span: Span,
};

pub const LocalInfer = struct {
    name: []const u8,
    value: Expr,
    span: Span,
};

pub const LocalTyped = struct {
    name: []const u8,
    ty: TypeRef,
    value: Expr,
    span: Span,
};

pub const AssignStmt = struct {
    target: Expr,
    op: AssignOp,
    value: Expr,
    span: Span,
};

pub const AssignOp = enum {
    assign,
    add,
    sub,
    mul,
    div,
    rem,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
};

pub const ReturnStmt = struct {
    value: ?Expr,
    span: Span,
};

pub const FailStmt = struct {
    variant: []const u8,
    payload: []const Expr,
    span: Span,
};

pub const IfStmt = struct {
    binding: ?IfBinding,
    payload_binding: ?[]const u8,
    condition: Expr,
    then_block: Block,
    else_block: ?Block,
    span: Span,
};

pub const IfBinding = struct {
    name: []const u8,
    value: Expr,
};

pub const WhileStmt = struct {
    condition: Expr,
    /// `while opt |x| { … }` — loops while `condition` is a non-null optional,
    /// binding the unwrapped payload to `x` each iteration.
    payload_binding: ?[]const u8,
    body: Block,
    span: Span,
};

pub const ForRangeStmt = struct {
    binding: []const u8,
    start: Expr,
    end: Expr,
    inclusive: bool,
    body: Block,
    span: Span,
};

pub const ForSliceStmt = struct {
    binding: []const u8,
    index_binding: ?[]const u8,
    by_ref: bool,
    iter: Expr,
    body: Block,
    span: Span,
};

pub const TypeRef = union(enum) {
    named: NamedType,
    pointer: PointerType,
    many_pointer: PointerType,
    optional: OptionalType,
    slice: SliceType,
    array: ArrayType,
    atomic: AtomicType,
    borrow: BorrowType,
    fn_type: FnType,
    inline_error_set: InlineErrorSet,
    type_param: NamedType,
    /// Generic type instantiation: `ArrayList(i32)`, `HashMap([]const u8, u32)`, etc.
    generic_inst: GenericInstType,
    opaque_type,

    pub fn span(self: TypeRef) Span {
        return switch (self) {
            .named => |ty| ty.span,
            .pointer => |ty| ty.span,
            .many_pointer => |ty| ty.span,
            .optional => |ty| ty.span,
            .slice => |ty| ty.span,
            .array => |ty| ty.span,
            .atomic => |ty| ty.span,
            .borrow => |ty| ty.span,
            .fn_type => |ty| ty.span,
            .inline_error_set => |ty| ty.span,
            .type_param => |ty| ty.span,
            .generic_inst => |ty| ty.span,
            .opaque_type => Span.new(0, 0),
        };
    }
};

pub const ErrorSpec = union(enum) {
    inferred: Span,
    named: NamedType,
    inline_set: InlineErrorSet,

    pub fn span(self: ErrorSpec) Span {
        return switch (self) {
            .inferred => |span_value| span_value,
            .named => |ty| ty.span,
            .inline_set => |ty| ty.span,
        };
    }
};

pub const InlineErrorSet = struct {
    variants: []const ErrorVariantDecl,
    span: Span,
};

pub const NamedType = struct {
    name: []const u8,
    /// Namespace qualifier for `ns::Name` — the import alias the type is reached
    /// through (`#import a.b;` → `b`). Null for a bare, unqualified name.
    namespace: ?[]const u8 = null,
    span: Span,
};

pub const PointerType = struct {
    is_const: bool = false,
    is_volatile: bool = false,
    inner: *const TypeRef,
    span: Span,
};

pub const OptionalType = struct {
    inner: *const TypeRef,
    span: Span,
};

pub const SliceType = struct {
    is_const: bool = false,
    inner: *const TypeRef,
    span: Span,
};

pub const ArrayType = struct {
    len: *const Expr,
    inner: *const TypeRef,
    span: Span,
};

pub const AtomicType = struct {
    inner: *const TypeRef,
    span: Span,
};

pub const BorrowType = struct {
    inner: *const TypeRef,
    span: Span,
};

pub const GenericInstType = struct {
    name: []const u8,
    /// Namespace qualifier for `ns::Name(args)` — the import alias the generic
    /// template is reached through. Null for a bare, unqualified instantiation.
    namespace: ?[]const u8 = null,
    args: []const TypeRef,
    span: Span,
};

pub const FnType = struct {
    type_params: []const []const u8,
    params: []const TypeRef,
    ret: *const TypeRef,
    error_ty: ?ErrorSpec,
    /// `extern fn(...)` — a THIN, C-ABI function pointer (a bare address), as
    /// opposed to skarn's fat `{fn, env}` closure. Directly callable; what a
    /// dynamically-loaded symbol (`wglGetProcAddress`, a COM vtable slot) becomes
    /// when reinterpreted, and what a C callback parameter accepts.
    is_extern: bool = false,
    span: Span,
};

pub const Expr = struct {
    id: NodeId,
    kind: ExprKind,
    span: Span,
};

pub const ExprKind = union(enum) {
    ident: []const u8,
    type_ref: TypeRef,
    int: []const u8,
    float: []const u8,
    string: []const u8,
    bool: bool,
    null,
    /// `#quote { ... }` — a typed AST block value. In slice 1 it only appears
    /// as the operand of `#insert`; later it materializes an `ast.Block` value.
    quote: Block,
    /// `#quote(expr)` — the expression form of a quotation.
    quote_expr: *const Expr,
    /// `$name` / `$(expr)` — a splice hole inside a `#quote`. Only meaningful
    /// while expanding a macro template; the macroexpand pass replaces it with
    /// the bound argument's AST. A stray splice outside a macro is an error.
    splice: *const Expr,
    /// `#parse(expr)` — evaluate `expr` to a string at compile time, parse that
    /// string as code, and (as an `#insert` operand) splice it. The string
    /// escape hatch out of typed quotations.
    parse_expr: *const Expr,
    compound_literal: []const Expr,
    /// `.{ .x = 1, .y = 2 }` — a struct literal with named fields. Resolved against
    /// the expected struct type (reordered to declaration order, omitted fields
    /// take their declared default) and lowered like a positional literal.
    struct_literal: []const FieldInit,
    unary: UnaryExpr,
    binary: BinaryExpr,
    unsafe_expr: *const Expr,
    run_expr: *const Expr,
    force_unwrap: *const Expr, // expr!!  — unwrap or panic
    nil_coalesce: NilCoalesceExpr, // expr ?? default
    as_cast: CastExpr,
    try_expr: TryExpr,
    catch_expr: CatchExpr,
    call: CallExpr,
    field: FieldExpr,
    /// `namespace::member` — access a member of an imported module namespace.
    scope_access: ScopeAccess,
    index: IndexExpr,
    slice: SliceExpr,
    /// `match subject { pattern => value, ... }` as a value.
    match_expr: *const MatchExpr,
    /// `if cond { value } else { value }` as a value.
    if_expr: *const IfExpr,
};

pub const IfExpr = struct {
    cond: Expr,
    then_value: Expr,
    else_value: Expr,
    span: Span,
};

pub const ScopeAccess = struct {
    base: *const Expr,
    member: []const u8,
};

pub const CastExpr = struct {
    value: *const Expr,
    to: TypeRef,
};

pub const UnaryExpr = struct {
    op: UnaryOp,
    expr: *const Expr,
};

pub const UnaryOp = enum {
    address_of,
    deref,
    neg,
    not,
    bit_not,
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    left: *const Expr,
    right: *const Expr,
};

pub const TryExpr = struct {
    value: *const Expr,
};

pub const NilCoalesceExpr = struct {
    value: *const Expr, // lhs — optional or fallible
    default: *const Expr, // rhs — used when lhs is null/error
};

pub const CatchExpr = struct {
    value: *const Expr,
    err_name: []const u8,
    handler: Block,
};

pub const BinaryOp = enum {
    or_or,
    and_and,
    equal,
    not_equal,
    less,
    le,
    gt,
    ge,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    add,
    sub,
    mul,
    div,
    rem,
    // Explicit wrapping (two's-complement) arithmetic — never traps on overflow.
    wrap_add,
    wrap_sub,
    wrap_mul,
};

pub const CallExpr = struct {
    callee: *const Expr,
    args: []const CallArg,
};

pub const CallArg = union(enum) {
    positional: Expr,
    named: NamedArg,
};

pub const NamedArg = struct {
    name: []const u8,
    value: Expr,
};

pub const FieldExpr = struct {
    base: *const Expr,
    name: []const u8,
};

pub const IndexExpr = struct {
    base: *const Expr,
    index: *const Expr,
};

pub const SliceExpr = struct {
    base: *const Expr,
    start: ?*const Expr = null,
    end: ?*const Expr = null,
};
