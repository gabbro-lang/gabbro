// Compiler-provided `ast.*` type surface for metaprogramming (Phase 2,
// generative Flavor A). These are ordinary Skarn types — a faithful subset of the
// compiler's own AST in `src/ast.zig` — so user code can construct them (via
// `#quote`), `match` on them, and return them from a comptime function. The
// materializer (`materializeExpr`/`materializeStmt`) and reifier (`Reifier`) in
// `ir.zig` map between these aggregates and real `ast.zig` nodes.
//
// Skarn has a flat type namespace (no `ast.Block` qualified form yet), so these use
// an `Ast` prefix. Identity fields (NodeId/Span) are intentionally omitted — the
// compiler stamps those when reifying at the splice site. Recursive references
// inside expression payloads use `*AstExpr` / `*AstType` to keep types finite.
//
// Conventions: an optional sub-expression (slice bounds) uses the `nothing`
// AstExpr as "absent"; an optional string (binding names) uses "" as "absent".
//
// IMPORTANT: variant ORDER is not load-bearing — the reifier looks variant names
// up by tag from the lowered module, so this can be reordered/grown freely.
// Struct FIELD order IS mirrored by hardcoded offsets in the reifier; keep
// fields in the order the reifier expects (documented there).
pub const source =
    \\AstBinOp :: enum {
    \\    add, sub, mul, div, rem,
    \\    eq, ne, lt, le, gt, ge,
    \\    logic_and, logic_or,
    \\    bit_and, bit_or, bit_xor, shl, shr,
    \\    wrap_add, wrap_sub, wrap_mul,
    \\}
    \\AstUnOp :: enum { neg, logic_not, bit_not, deref, addr }
    \\AstDeferMode :: enum { always, ok_only, err_only }
    \\
    \\AstArrayTy :: struct { len: *AstExpr, elem: *AstType }
    \\AstType :: enum {
    \\    named:       []const u8,
    \\    ptr:         *AstType,
    \\    slice_of:    *AstType,
    \\    optional_of: *AstType,
    \\    array_of:    AstArrayTy,
    \\}
    \\
    \\AstArg      :: struct { name: []const u8, value: AstExpr }
    \\AstBinary   :: struct { op: AstBinOp, left: *AstExpr, right: *AstExpr }
    \\AstUnary    :: struct { op: AstUnOp, operand: *AstExpr }
    \\AstCall     :: struct { callee: *AstExpr, args: []AstArg }
    \\AstField    :: struct { base: *AstExpr, name: []const u8 }
    \\AstIndex    :: struct { base: *AstExpr, idx: *AstExpr }
    \\AstSliceE   :: struct { base: *AstExpr, start: *AstExpr, end: *AstExpr }
    \\AstCastE    :: struct { value: *AstExpr, to: AstType }
    \\AstCoalesce :: struct { value: *AstExpr, default: *AstExpr }
    \\AstCatchE   :: struct { value: *AstExpr, err_name: []const u8, handler: AstBlock }
    \\
    \\AstExpr :: enum {
    \\    int:     i64,
    \\    float:   f64,
    \\    str:     []const u8,
    \\    boolean: bool,
    \\    nothing,
    \\    ident:   []const u8,
    \\    unary:   AstUnary,
    \\    binary:  AstBinary,
    \\    call:    AstCall,
    \\    field:   AstField,
    \\    index:   AstIndex,
    \\    slice:    AstSliceE,
    \\    cast:     AstCastE,
    \\    unwrap:   *AstExpr,
    \\    coalesce: AstCoalesce,
    \\    try_q:    *AstExpr,
    \\    catch_b:  AstCatchE,
    \\    compound: []AstExpr,
    \\    unsafe_e: *AstExpr,
    \\}
    \\
    \\AstLocal      :: struct { name: []const u8, value: AstExpr }
    \\AstLocalTyped :: struct { name: []const u8, ty: AstType, value: AstExpr }
    \\AstAssign     :: struct { target: AstExpr, value: AstExpr }
    \\AstIf         :: struct { cond: AstExpr, then_block: AstBlock, else_block: AstBlock }
    \\AstWhile      :: struct { cond: AstExpr, body: AstBlock }
    \\AstForRange   :: struct { binding: []const u8, start: AstExpr, end: AstExpr, inclusive: bool, body: AstBlock }
    \\AstForSlice   :: struct { binding: []const u8, index_binding: []const u8, by_ref: bool, iter: AstExpr, body: AstBlock }
    \\AstZone       :: struct { name: []const u8, kind: []const u8, body: AstBlock }
    \\AstDefer      :: struct { mode: AstDeferMode, body: AstBlock }
    \\AstFail       :: struct { variant: []const u8, payload: []AstExpr }
    \\AstPattern    :: enum { variant: []const u8, ints: []AstExpr, anything }
    \\AstMatchArm   :: struct { pattern: AstPattern, binding: []const u8, body: AstBlock }
    \\AstMatch      :: struct { subject: AstExpr, arms: []AstMatchArm }
    \\
    \\AstStmt :: enum {
    \\    local:       AstLocal,
    \\    local_typed: AstLocalTyped,
    \\    assign:      AstAssign,
    \\    ret,
    \\    ret_expr:    AstExpr,
    \\    cond:        AstIf,
    \\    loop:        AstWhile,
    \\    for_range:   AstForRange,
    \\    for_slice:   AstForSlice,
    \\    match_s:     AstMatch,
    \\    zone_s:      AstZone,
    \\    defer_s:     AstDefer,
    \\    fail_s:      AstFail,
    \\    unsafe_blk:  AstBlock,
    \\    brk,
    \\    cont,
    \\    expr:        AstExpr,
    \\}
    \\
    \\AstBlock :: struct { stmts: []AstStmt }
;

/// `std.compiler` surface for `#compiler` hooks (Phase 3 message loop). Injected
/// whenever a module declares a `#compiler` hook, so the hook can call the
/// `core::compiler_decls()` introspection builtin and `for`-iterate the program's
/// top-level declarations WITH structure. `Decl.kind` is one of: "fn", "struct",
/// "enum", "errors", "interface", "distinct", "opaque", "const".
///
/// `Decl.fields` is overloaded by kind: a `struct`'s fields, an `enum`'s variants
/// (`type_name` = the payload type, or "" if the variant has none), or a `fn`'s
/// parameters. `Decl.ret` is a `fn`'s return type name ("" otherwise). This lets
/// a hook generate code driven by a type's real shape (serializers, builders, …).
pub const compiler_source =
    \\CField :: struct { name: []const u8, type_name: []const u8 }
    \\Decl :: struct { name: []const u8, kind: []const u8, fields: []CField, ret: []const u8, body: []const u8, derives: []const u8 }
    \\
    \\CodeBuf :: struct { s: []const u8 }
    \\gen_buf :: fn() -> CodeBuf { r: CodeBuf = .{ "" }; return r; }
    \\emit :: fn(self: *CodeBuf, piece: []const u8) { self.s = __str_cat(self.s, piece); }
    \\rendered :: fn(self: *CodeBuf) -> []const u8 { return self.s; }
;

/// `TypeInfo` reflection surface — injected whenever a module uses `type_info`.
/// A matchable tagged enum (not a cast hierarchy): `match core::type_info(T) { .int |i| … }`.
/// The materializer in `ir.zig` (`materializeTypeInfo`) builds these values from a
/// type's layout; field/payload types are `*TypeInfo` so the tree is finite, and
/// recursive types are broken with the `other` leaf (carrying the type name).
///
/// Variant ORDER is not load-bearing (looked up by name); keep names in sync with
/// `materializeTypeInfo`. `void_`/`boolean` avoid the `void`/`bool` keywords.
/// `Any` — a type-erased value: a borrowed pointer to the data plus the data's
/// `typeid`. The wrap (`core::any(x)`) is compiler-driven (it spills `x` and records
/// `core::type_id(T)`); the rest is ordinary generic Skarn, so downcasting is safe.
pub const any_source =
    \\Any :: struct { data: *const u8, id: usize, name: []const u8 }
    \\
    \\any_id :: fn(v: Any) -> usize { return v.id; }
    \\
    \\any_name :: fn(v: Any) -> []const u8 { return v.name; }
    \\
    \\any_at :: fn(ptr: *const u8, $T: type) -> Any { r: Any = .{ ptr, core::type_id(T), core::type_name(T) }; return r; }
    \\
    \\any_field_count :: fn(v: Any) -> usize {
    \\    n: usize = 0;
    \\    cont: bool = true;
    \\    while cont {
    \\        if any_field_at(v, n) |f| { n = n + 1usize; } else { cont = false; }
    \\    }
    \\    return n;
    \\}
    \\
    \\any_is :: fn(v: Any, $T: type) -> bool { return v.id == core::type_id(T); }
    \\
    \\any_as :: fn(v: Any, $T: type) -> ?T {
    \\    if v.id == core::type_id(T) {
    \\        unsafe {
    \\            tp := v.data as *T;
    \\            return *tp;
    \\        }
    \\    }
    \\    return null;
    \\}
;

pub const reflection_source =
    \\TiInt     :: struct { bits: u16, signed: bool }
    \\TiFloat   :: struct { bits: u16 }
    \\TiPtr     :: struct { elem: *TypeInfo, is_const: bool }
    \\TiArray   :: struct { len: usize, elem: *TypeInfo }
    \\TiField   :: struct { name: []const u8, ty: *TypeInfo }
    \\TiStruct  :: struct { name: []const u8, fields: []TiField, id: usize }
    \\TiVariant :: struct { name: []const u8, has_payload: bool }
    \\TiEnum    :: struct { name: []const u8, variants: []TiVariant }
    \\TypeInfo :: enum {
    \\    void_,
    \\    boolean,
    \\    int:      TiInt,
    \\    float:    TiFloat,
    \\    pointer:  TiPtr,
    \\    slice:    *TypeInfo,
    \\    array:    TiArray,
    \\    optional: *TypeInfo,
    \\    struct_:  TiStruct,
    \\    enum_:    TiEnum,
    \\    other:    []const u8,
    \\}
;

/// `Test` — the context handle a `#test` function receives (`fn(t: *Test)`).
/// Injected whenever a module declares a `#test` decl, so a test can assert
/// without importing anything. The assertion methods call `core::compiler_error`
/// on failure: in the comptime lane the test runs on the VM during compilation,
/// so a failed assertion halts that run and the driver turns it into a real
/// compile diagnostic (the build goes red, exactly like a type error).
///
/// `eq`/`ne` compare with `==`/`!=`, which the comptime VM evaluates for scalars
/// (ints, floats, bools, simple enums) and `[]const u8` (content compare — the
/// byte-loop lowering folds on the VM). Struct/aggregate equality is not yet
/// supported anywhere (`==` on a struct is an aggregate compare the backend can't
/// emit); that arrives with the reflection-driven structural diff. Use
/// `t.expect(...)` on fields for a struct check today.
pub const testing_source =
    \\Test :: struct {
    \\    failures: u32,
    \\
    \\    pub fatal :: fn(self: *Self, msg: []const u8) {
    \\        core::compiler_error(msg);
    \\    }
    \\
    \\    pub expect :: fn(self: *Self, cond: bool) {
    \\        if cond == false {
    \\            core::compiler_error("t.expect: condition was false");
    \\        }
    \\    }
    \\
    \\    pub eq :: fn(self: *Self, a: $V, b: $V) {
    \\        if a != b {
    \\            core::compiler_error("t.eq: values are not equal");
    \\        }
    \\    }
    \\
    \\    pub ne :: fn(self: *Self, a: $V, b: $V) {
    \\        if a == b {
    \\            core::compiler_error("t.ne: values are unexpectedly equal");
    \\        }
    \\    }
    \\}
;
