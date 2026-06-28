# Reflection, Any, and constraints


Reflection in Skarn is comptime and runtime, and it threads through generics.

At comptime, `type_info(T)` is a matchable value — you `match` on a type's structure
(struct fields, enum variants, scalar kind). Constraints build on it: built-in
predicates (`$T: Numeric`/`Int`/`Float`/`Struct`/`Enum`/`Ptr`/…), named
`constraint Name($T) { … }` declarations, and `where { … }` blocks that inspect
`type_info(T)` and can `reject("msg")`. The predicate runs during generic resolution,
so a bad type fails at the call site before the body is checked. A `where` can also
compute an output type param (`-> $Acc`).

At runtime, `typeid_of(T)` is a stable type identity — a content hash, comparable
across compilation units. `type_name(T)` and `sizeof(T)` fold to real runtime values.
`Any` is a type-erased value: `any(x)` wraps it, `any_as(v, T) -> ?T` is a safe
downcast. The metadata travels inline with the value, baked as a tree-shaken string
literal, so reflection you don't use costs nothing. A generic walker recurses through
struct fields, slice elements, and pointers — enough for reflection-driven
serialization with no per-type code.

## Design thesis

Jai exposes reflection and metaprogramming through many special-purpose pieces
that don't compose: `#modify` (a code block bolted onto a signature), the
`Type_Info` / `Type_Info_Integer` / `Type_Info_Struct` cast hierarchy,
`get_type_table`, `for_expansion`, `#insert -> string`. Each does its job; together
they're a grab-bag.

Skarn already has a structural advantage Jai lacks: **the comptime VM executes the
same IR as the runtime backend**, so comptime and runtime behave identically (an
`#run` FNV-1a hash equals its runtime value bit-for-bit). We lean on that to make
*one* reflection surface serve both phases.

Five orthogonal primitives, each type-safe, each composing with the rest:

1. **`TypeInfo`** — a matchable tagged enum describing a type. Same value at
   comptime and runtime.
2. **`typeid`** — a cheap, stable runtime identity for a type (an index, not a
   pointer).
3. **`Any`** — a `(pointer, typeid)` pair with *safe* navigation and downcasting.
4. **`constraint`** — a comptime predicate over `TypeInfo`; `$T: C` and interface
   conformance are the same mechanism.
5. **`where`** — either a per-instantiation block that can inspect, *rewrite*, and
   *reject* the type bindings (with overload fallback), **or** interface bounds:
   `fn($T, x: *T) where T: Show` is equivalent to the inline `fn($T: Show, …)`
   (comma-separate several, `where T: A, U: B`). A bound type is checked for
   conformance, and the interface's methods are callable on it directly
   (`x.val()`), not only via a `*Iface` value.

Reflection-driven serialization, custom iteration, and code generation all fall
out of these — no new directives.

## 1. `TypeInfo` — reflection as a matchable value

Today Skarn has `type_info(T)` with ad-hoc field access (`.kind`, `.fields[i].name`,
`.bits`). We replace that with a real tagged enum — the same shape as the `ast.*`
metaprogramming surface, injected as a prelude when reflection is used.

```skarn
TypeInfo :: enum {
    void,
    bool,
    int:      IntInfo,        // { bits: u16, signed: bool }
    float:    FloatInfo,      // { bits: u16 }
    pointer:  PtrInfo,        // { elem: *TypeInfo, is_const: bool }
    slice:    *TypeInfo,
    array:    ArrayInfo,      // { len: usize, elem: *TypeInfo }
    optional: *TypeInfo,
    fn_:      FnInfo,         // { params: []*TypeInfo, ret: *TypeInfo, is_extern: bool }
    struct_:  StructInfo,     // { name, fields: []FieldInfo, size, align }
    enum_:    EnumInfo,       // { name, variants: []VariantInfo, tag_bits }
    iface:    IfaceInfo,      // { name, methods: []MethodInfo }
    distinct: DistinctInfo,   // { name, underlying: *TypeInfo }
}

FieldInfo   :: struct { name: []const u8, ty: *TypeInfo, offset: usize, is_const: bool }
VariantInfo :: struct { name: []const u8, payload: ?*TypeInfo, tag: u32 }
```

`type_info(T) -> TypeInfo` folds at comptime *and* is available at runtime (see
§4). Because it's a tagged enum, you inspect it by `match`, not by casting:

```skarn
describe :: fn(info: TypeInfo) -> []const u8 {
    match info {
        .int |i|     => return if i.signed { "signed integer" } else { "unsigned integer" };
        .struct_ |s| => return s.name;
        .slice |elem| => return "slice";
        else         => return "other";
    }
}
```

> **✦ Beyond Jai.** Jai forces `if t.type == .INTEGER { info := cast(*Type_Info_Integer) t; … }`
> — a tag check followed by an unchecked pointer cast. Skarn's `match info { .int |i| => … }`
> is exhaustive, payload-bound, and impossible to mis-cast. The compiler also
> checks you handled (or `else`'d) every kind.

## 2. `typeid` — cheap runtime identity

> **Implemented today:** `typeid_of(T) -> usize` — a stable runtime id for a type.
> It folds at IR lowering to an **FNV-1a content hash** of the type's canonical
> spelling, so identical types always share an id, distinct types (incl. `*i32`
> vs `i32`, `[]i32` vs `i32`, two structurally-identical structs) differ, and the
> id is **stable across compilation units** (no global numbering). In a generic,
> `typeid_of(T)` folds per instantiation. Identity tests are a single `usize`
> compare. `info_of(id)` (the dynamic table lookup) is still design (needs §4).

```skarn
typeid_of(T) -> usize        // a stable id (content hash); IMPLEMENTED
typeid_of(any_value) -> usize   // value form — design (needs Any)
info_of(id) -> *TypeInfo        // table lookup — design (§4)
```

Two identical types always share one id, so identity tests are a single integer
compare:

```skarn
if typeid_of(x) == typeid_of(Vector3) { … }
```

> **✦ Beyond Jai.** Jai compares `*Type_Info` pointers and bakes the whole table
> unconditionally. A `typeid` is cheaper to compare, stable across compilation
> units, and (with §4's tree-shaking) only costs a table slot when actually used.

## 3. `Any` — safe dynamic values

`Any` is the runtime-reflection workhorse: a fat value carrying a pointer to data
and the data's type metadata.

> **Implemented today.** `Any :: struct { data: *const u8, id: usize, name:
> []const u8 }` (an injected prelude). `any(x)` wraps any value — it spills `x` to
> a temporary, points at it, and records `typeid_of(T)` and the type's name. The
> rest is ordinary generic Skarn (so it's all type-safe):
> `any_as(v, T) -> ?T` (safe downcast, null on mismatch), `any_is(v, T) -> bool`,
> `any_id(v)`, `any_name(v)`. A value passed to an `Any` parameter and recovered by
> its real type works end to end; the type *name* is available at runtime on the
> erased value. **Skarn's twist on the type table:** metadata travels *inline* with
> the value (no central `info_of(id)` table to bake/manage), and it's tree-shaken
> automatically — only `any()`'d types' names reach the binary. (Auto-wrap of a
> bare value into an `Any` parameter, and `.field`/`.elem`/`.deref` navigation,
> are the next steps.)

```skarn
Any :: struct { data: *const u8, id: usize, name: []const u8 }   // injected; `any(x)` builds it
```

Assigning any value to an `Any` parameter wraps it automatically (the compiler
spills a temporary and records its `typeid`):

```skarn
log :: fn(label: []const u8, v: Any) { … }
log("count", 42);            // wraps i32
log("pos", Vector3.{1,2,3}); // wraps Vector3
```

Navigation and downcasting are **safe** — they return optionals, never UB:

```skarn
v.info() -> TypeInfo                 // the type, as a matchable value
v.as(T) -> ?T                        // downcast; null if the id doesn't match
v.field("name") -> ?Any              // a struct field by name, as an Any
v.elem(i: usize) -> ?Any             // a slice/array element
v.deref() -> ?Any                    // follow a pointer/optional
```

```skarn
sum_field :: fn(v: Any) -> i32 {
    if v.field("count").as(i32) |c| { return c; }   // safe: present + right type
    return 0;
}
```

> **✦ Beyond Jai.** Jai's `Any` is `{ value_pointer, type }` and you cast it
> yourself (unchecked). Skarn's `.as(T)` is an `?T`, `.field`/`.elem` are bounds- and
> name-checked, and you pattern-match `.info()`. You cannot read an `Any` as the
> wrong type without the compiler handing you a `null` to deal with.

## 4. The type table — opt-in, tree-shaken

Runtime reflection needs `TypeInfo` baked into the binary's data segment. Jai
bakes **everything** (then offers `runtime_storageless_type_info` to turn it off).
Skarn inverts the default: a type's info reaches the binary **only if it can be
reached at runtime** — i.e. some runtime code calls `type_info(T)`, takes
`typeid(T)`, or wraps a `T` into an `Any`. The compiler already tracks the
comptime/runtime split (the VM vs the LLVM backend), so this is a reachability
pass over those roots.

```skarn
type_table() -> []TypeInfo     // every type that was baked (debuggers, tooling)
```

Result: a hello-world binary bakes **zero** type info; a program that serializes
three structs bakes exactly those three (plus their transitive field types).

> **✦ Beyond Jai.** Smaller binaries by default, with no global switch to
> remember. Reflection you don't use costs nothing — the opposite of Jai's
> bake-all-then-strip model. A capability (§7) can additionally gate *who* may read
> the table, so a sandboxed plugin can't enumerate the host's types.

## 5. Serialization — one source, two speeds

Because the same `type_info` walk runs at comptime and runtime, you write a
serializer **once** and choose where it executes:

```skarn
to_json :: fn(v: Any, w: *StringBuilder) {
    match v.info() {
        .bool        => w.str(if v.as(bool)!! { "true" } else { "false" }),
        .int  |i|    => w.write_i64(v.read_int()),       // read_int widens any int
        .float |f|   => w.write_f64(v.read_float()),
        .slice |e|   => {
            w.byte('[');
            for i in 0..v.len() { if i > 0 { w.byte(','); } to_json(v.elem(i)!!, w); }
            w.byte(']');
        }
        .struct_ |s| => {
            w.byte('{');
            for f, i in s.fields {
                if i > 0 { w.byte(','); }
                w.quote(f.name); w.byte(':');
                to_json(v.field(f.name)!!, w);
            }
            w.byte('}');
        }
        else => w.str("null"),
    }
}
```

- **Runtime, dynamic:** call `to_json(some_any, w)` — walks `TypeInfo` at runtime.
  Handles values whose type isn't known until runtime.
- **Comptime, specialized:** the *same* function under `#run`/`#for` monomorphizes
  to straight-line field stores with **no runtime reflection cost** — the VM folds
  the `match` and the `for` because `type_info(T)` is constant.

```skarn
// zero-reflection, fully specialized serializer for a known type:
to_json_of :: fn($T: type, v: T, w: *StringBuilder) {
    #for f in type_info(T).struct_.fields {     // unrolled at comptime
        w.quote(f.name); w.byte(':');
        to_json_of(field_type(T, f.name), field(v, f.name), w);
    }
}
```

> **✦ Beyond Jai.** Jai makes you pick *up front*: write a string-codegen
> serializer (`#insert -> string` + `String_Builder`, see its `for_each_member`),
> **or** walk `Type_Info` at runtime. They're different code. Skarn's single
> `match`-on-`TypeInfo` function *is* both — comptime folds it to specialized code,
> runtime executes it dynamically, guaranteed identical by the shared IR.

## 6. `constraint` and `where` — resolve-time generics

This replaces Jai's `#modify`. Two layers: **named constraints** (the common,
composable case) and a **`where` block** (the escape hatch that can rewrite and
reject).

### 6.1 Named constraints

> **Implemented today:** both **built-in** constraints (`$T: Numeric`, `Int`,
> `Float`, `Signed`, `Unsigned`, `Bool`, `Struct`, `Enum`, `Ptr` — checked by type
> kind) **and user-defined `constraint Name($T) { … }` declarations**. A
> non-satisfying type is rejected with a clear message at the `$T: Name` site
> (`type `P` does not satisfy `MyNum`: expected a numeric type`). A user
> `constraint` is a named, reusable comptime predicate (a where-style block over
> `type_info(T)` that may `reject`); it runs on the resolution VM at each `$T: Name`
> use, via the same two-pass rail. Built-ins take precedence over a same-named
> user constraint. **`require(T, Other)` composition works**: a top-level `require`
> guard recursively enforces another constraint (with cycle detection),
> propagating its rejection message; the constraint's own checks run after the
> guards. (Generic inference also binds `$T` from `[]$T`/`?$T`, not just `*$T`.)
> **Still design:** the `&` combinator below; `require` is a *top-level* guard
> (not evaluated inside conditional control flow).

A `constraint` is a comptime predicate over a type — first-class, named, and
composable. Interface conformance becomes *one kind* of constraint.

```skarn
Numeric :: constraint($T) {
    match type_info(T) { .int, .float => accept; else => reject("expected a numeric type"); }
}

Ordered :: constraint($T) { require(T, Numeric); }   // constraints can require others

sum :: fn($T: Numeric, xs: []T) -> T {        // `$T: Numeric` is checked at the call
    total: T = 0;
    for x in xs { total = total +% x; }
    return total;
}
```

Constraints compose with `&`, and `$T: Writer` (an interface) and `$T: Numeric`
(a predicate) use the *same* `$T: C` syntax:

```skarn
serialize :: fn($T: Struct & HasField("id"), v: T) { … }   // composed
```

> **✦ Beyond Jai.** Jai's `#modify` is an anonymous code block (or a proc returning
> `bool`) glued to one signature — not nameable, not composable, and orthogonal to
> interface constraints. Skarn makes the predicate a named, reusable, composable
> value, and *unifies* interface conformance with arbitrary predicates. One
> concept (`$T: C`) instead of two (`#modify` + interface `/Type`).

### 6.2 The `where` block — inspect, rewrite, reject

> **Implemented today (inspect + reject + output types).** A `where { … }` block
> after a generic function signature is an arbitrary comptime predicate. It runs
> **once per instantiation, during resolution**, on a resolution `ComptimeVm`,
> with the type parameters bound. It may `reject("msg")` to fail the instantiation
> with a custom message, and it may compute **output type params** (`-> $Acc`).
> Both work end to end:
>
> ```skarn
> // inspect + reject:
> dbl :: fn(x: $T) -> T
> where { match type_info(T) { .int => {} .float => {} else => reject("dbl needs a numeric type"); } }
> { return x +% x; }
>
> // output type param computed by the where:
> acc_of :: fn(x: $T) -> $Acc
> where { match type_info(T) { .int |i| => if i.bits < 32 { Acc = i32; } else { Acc = T; }  else => Acc = T; } }
> { total: Acc = x as Acc; return total; }
> ```
>
> A satisfying type compiles; a rejected one fails at the call site with
> `` `dbl` rejected for this type: dbl needs a numeric type``. The *binding
> rewrite* (`T = u32`) and *overload fallback* parts remain design (see `§6.3`).

When you need to *change* the bindings (Jai's `T = s64`) or compute an output
type, attach a `where` block. It runs once per instantiation, after type matching,
with the type parameters as mutable comptime values.

```skarn
// Sum into a wider accumulator so u8 arrays don't overflow:
sum :: fn($T: type, xs: []T) -> $Acc
where {
    match type_info(T) {
        .int |i| => Acc = if i.bits < 32 { (if i.signed { i32 } else { u32 }) } else { T };
        .float   => Acc = T;
        else     => reject("sum: {type_name(T)} is not a numeric type");
    }
} {
    total: Acc = 0;
    for x in xs { total = total +% (x as Acc); }
    return total;
}
```

- `$Acc` is an **output type parameter** — declared in the return position,
  *computed* by `where`. (Jai bolts this on with a separate `$R` and assigns it
  inside `#modify`; here it reads as "the return type is whatever `where` decided.")
- `reject("…")` takes an interpolated message and, crucially, participates in
  **overload resolution**: a rejected instantiation is *not yet* an error — the
  compiler tries the next overload. Only when every candidate rejects does it
  report, listing each reason.

```skarn
// Two overloads; `where` disambiguates instead of erroring on ambiguity:
push :: fn($T: type, xs: *List(T), v: T)        where { … }   { … }
push :: fn($T: type, xs: *List(T), vs: []T)     where { … }   { … }
```

> **✦ Beyond Jai.** Three improvements: (1) `reject` with a real interpolated
> message and **overload fallback** instead of a hard error (Jai's `#modify`
> returning false is fatal); (2) output types are *declared where they belong*
> (`-> $Acc`) and computed in `where`, instead of a magic `$R` mutated in a side
> block; (3) the `where` body uses matchable `TypeInfo`, not `cast(*Type_Info_*)`.

### 6.3 How `where` is wired — the two-pass resolution rail

The predicate runs **during generic resolution**, not after. This dissolves the
"run comptime code during resolution, but the VM only exists post-sema"
chicken-and-egg by reusing the same two-pass pipeline Skarn already has for computed
`#insert #run` (`pipeline.zig`'s `strictPass`):

1. **Tolerant pass-1 sema** type-checks everything (the `where` blocks included)
   and yields a complete-enough `FrontEnd`.
2. A **resolution `ComptimeVm`** is built from that `FrontEnd`.
3. **Strict pass-2 sema** re-checks with the VM wired into the `Checker` (via an
   opaque ctx + function-pointer callback, so sema never imports `ir` — see
   `WhereEvalFn` / `WhereTypeEvalFn`). At each generic call/instantiation the
   predicate runs on the VM with the type params bound.

**Reject** (`§6.2`): in `checkFunction`, right after the `where` block is checked
and *before* the body, the callback runs `ComptimeVm.evalWhere` — the block lowers
to `__where() -> []const u8` (`reject(msg)` → `return msg`, fall-through → `""`).
A non-empty result is a resolution error at the **call site** (`origin_span` on the
instantiation) that suppresses the spurious body errors a post-body check couldn't.

**Output type params** `-> $Acc`: parsed as an output type param
(`output_type_params`), computed at the call site in `inferGenericCallImpl` via
`computeOutputParamsAtCall` → `ComptimeVm.evalWhereType`. The `where` lowers so
each `Acc = <type>` returns the **node id** of its right-hand type expression; sema
resolves that expression (`resolveExprAsType`, with `T` bound) and binds `Acc`, so
the call's return type *and* the instantiation body both see the computed type.
(Types flow back as node ids rather than first-class `type_val`s — the latter is a
heavier `Any`/Phase-4 concern; node ids need zero new VM value machinery.)

**Still design:** **binding rewrite** (`T = u32`) and **overload fallback** (try
the next candidate on reject). Fallback is moot until Skarn grows same-name
overloading; rewrite is a small extension of the same `evalWhereType` mechanism.

## 7. Where it all pays off (broad feature parity, Skarn-style)

The same five primitives subsume the rest of Jai's metaprogramming toolkit —
without new directives:

| Jai feature | Skarn realization | Improvement |
|---|---|---|
| `for_expansion` (custom iterators) | An `Iter` **interface**: `Iter :: interface { next :: fn(self: *Self) -> ?Elem; }`. `for x in c` desugars to `next()`. | Works at runtime *and* comptime; composes with dynamic dispatch; not a macro you reimplement per container. A `#for_expansion` macro stays available for zero-cost unrolling when you want it. |
| `#insert -> string` building **struct fields** (SOA, `Matrix(N)`) | `#for f in type_info(T).fields { #emit_field … }` inside a struct body — typed field emission, not string concatenation. | Generated fields are type-checked at the generation site; no `.added_strings.jai` to eyeball. |
| `#caller_code` (call-site AST) | `#caller` builtin yielding a typed `ast.Call` you `match` on. | Typed AST, not `cast(*Code_Procedure_Call)`. |
| `compiler_get_nodes` / `compiler_get_code` (arbitrary code AST round-trip) | Typed macro params: a macro takes `body: ast.Block` (matchable) instead of opaque `Code`; rebuild and `#insert`. | Type-safe AST surgery — match on `ast.*`, never cast `Code_Node*`. |
| `get_type_table` | `type_table()` — but tree-shaken and capability-gated. | Smaller binaries; sandboxable. |
| `#compile_time` | `#phase` builtin (`.comptime` / `.runtime`), foldable in `#if`. | — |
| (none) | **Capability-sandboxed reflection + FFI** | The structural supply-chain fix: a plugin gets `Reflect`/`FileSys` capabilities or it physically can't reach the host. Jai has no equivalent. |

The unifying idea: **reflection is a value, constraints are predicates over it,
`Any` is reflection plus a pointer, iteration is an interface, and code generation
is a `#for` over reflected fields.** Five composable pieces instead of a dozen
special forms — all type-checked, all phase-unified, all sandboxable.
