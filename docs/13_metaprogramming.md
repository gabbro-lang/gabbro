# Metaprogramming: Macros, Quote/Insert, and Code Generation

Two ways to generate code at compile time.

Template macros are a syntactic, hygienic substitution engine — stamp out a shape
with the holes filled in. Programmatic generation runs real Skarn in the comptime
VM, builds an AST as a first-class value, and splices it; reach for it when the
code's structure depends on logic (loops over fields, branching on types). Macros
first, the programmatic path at the end.

## 1. Quote and insert

`#quote { ... }` captures a block of code as a typed AST value rather than
running it. `#insert <code>;` splices an AST value back into the program at that
point, where it is then type-checked normally.

```skarn
#entry
main :: fn() -> i32 {
    #insert #quote { x := 40; };  // splices `x := 40;` here
    return x + 2;                 // 42
}
```

A bare `#insert #quote { ... }` is **not** hygienic — the locals it introduces
(`x` above) leak into the surrounding scope on purpose, so you can use them. (A
*macro*'s locals do not leak; see [Hygiene](#4-hygiene).)

`#quote(expr)` is the expression form: it captures a single expression as an
`AstExpr` value.

## 2. Macros

A macro is a compile-time template. It is declared like a function but with the
`macro` keyword, and its body must be a single `return #quote { ... };`:

```skarn
swap :: macro(a: Expr, b: Expr) {
    return #quote {
        t := $a;
        $a = $b;
        $b = t;
    };
}

#entry
main :: fn() -> i32 {
    x: i32 = 7; y: i32 = 49;
    #insert swap(x, y);   // now x = 49, y = 7
    return x - y;         // 49 - 7 = 42
}
```

Inside the template, **`$name` is a *splice hole*** that is replaced by the
argument bound to the macro parameter `name`. A macro is expanded at each
`#insert` site *before* type-checking, so the result is checked as if you had
written it by hand.

### Parameter types

A macro parameter's type constrains what kind of argument it accepts:

| Parameter type | Accepts | Use |
|---|---|---|
| `Expr` / `AstExpr` | an expression (not a `#quote` block) | `$p` in expression or type position |
| `Block` / `AstBlock` | a `#quote { ... }` block | `$p;` to inline the block's statements |
| `Code` (or untyped) | anything | flexible |

A mismatched argument is rejected with a clear error (e.g. *"parameter `body`
expects a `#quote { ... }` block"*).

### Block splice

A `Block`/`AstBlock` parameter is spliced as a **statement** with `$body;`, which
inlines that block's statements verbatim:

```skarn
twice :: macro(body: Block) {
    return #quote { $body; $body; };
}

#entry
main :: fn() -> i32 {
    n: i32 = 0;
    #insert twice(#quote { n = n + 21; });  // runs the block twice
    return n;                                 // 42
}
```

### Splices work everywhere

Splice holes are substituted through **all** statement and expression forms,
including inside `match` arms, runtime `for`/`while` bodies, compound literals,
`defer`, `zone`, `unsafe`, `catch`, slices — and in **type position**:

```skarn
Pair :: struct { a: i32, b: i32 }

build :: macro(out: Expr, ty: Expr, sel: Expr, lo: Expr, hi: Expr) {
    return #quote {
        p: Pair = .{ $lo, $hi };               // splice inside `.{ }`
        acc: $ty = 0;                          // type-position splice
        for k in p.a..p.b { acc = acc + k; }   // runtime for body
        match $sel {                           // splice as the match subject
            1 => { $out = acc + p.a; }
            else => { $out = acc; }
        }
    };
}
```

## 3. `#for` — compile-time unrolling

`#for i in a..b { ... }` inside a template is **unrolled** at expansion time: the
body is emitted once per index, with the loop variable available as a *comptime
value* spliced with `$(i)`:

```skarn
sum_first :: macro(out: Expr) {
    return #quote {
        #for i in 0..4 { $out = $out + $(i); }  // → out = out+0; out+1; out+2; out+3;
    };
}
```

Note the distinction:

- A **runtime** loop `for k in 0..n { ... k ... }` keeps `k` as an ordinary
  runtime variable, referenced bare (`k`).
- A **comptime** `#for i in 0..4 { ... $(i) ... }` is unrolled; `i` is a comptime
  literal, spliced with `$(i)`. The bounds must be integer literals (or macro
  parameters bound to literals).

## 4. Hygiene

A macro's own locals are **renamed to fresh, collision-free names** so they can
never capture — or be captured by — names in the caller. This includes locals,
`for`/`while` loop variables, and `match`/`if` capture bindings:

```skarn
accumulate :: macro(out: Expr, n: Expr) {
    return #quote {
        tmp := 0;
        for k in 0..$n { tmp = tmp + k; }
        $out = tmp;
    };
}

#entry
main :: fn() -> i32 {
    tmp: i32 = 100;   // untouched — the macro's `tmp` is a different variable
    k: i32 = 7;       // untouched — the macro's `k` is a different variable
    r: i32 = 0;
    #insert accumulate(r, 9);          // 0+1+…+8 = 36 → r
    return r + (tmp - 100) + (k - 7);  // 36 (proves no capture)
}
```

To deliberately produce a binding the caller can name, write to a variable the
caller passes in (an `Expr` parameter, like `$out` above), or use a bare
`#insert #quote { ... }`, whose locals are *not* hygienic.

## 5. `#parse` — the string escape hatch

`#parse(string_expr)` evaluates a string at compile time, parses it as code, and
(as an `#insert` operand) splices it. This is the untyped escape hatch out of
quotations — useful when the code is assembled as text:

```skarn
#insert #parse("answer := 42;");
```

Prefer typed `#quote`/macros where possible; reach for `#parse` only when you
genuinely have code as a string.

## 6. Errors and gotchas

- A `$name` splice **only** means something inside a macro template's
  `return #quote { ... }`, and `name` must be one of the macro's parameters.
  A stray `$` elsewhere is an error.
- The macro body must be exactly one `return #quote { ... };` — a macro is a
  *template*, not a place to run logic. For logic-driven generation, use the
  programmatic path below.
- A `Block` argument cannot be spliced in expression position (`$b` where an
  expression is expected) — splice it as a statement (`$b;`) instead.

## 7. Programmatic generation (when templates aren't enough)

When the *shape* of the generated code depends on compile-time logic — iterating
over a type's fields, branching on `type_info(T)`, accumulating a list of
statements — build the AST as a first-class value and splice the result:

```skarn
gen :: fn() -> AstBlock { /* build statements with ast.* constructors */ }

#entry
main :: fn() -> i32 {
    #insert #run gen();   // runs gen() in the comptime VM, splices its AST
    return answer;
}
```

The comptime VM exposes the AST as matchable `ast.*` values (see
[09](09_comptime_vm_roadmap.md)). This path can construct *any* form (full
control flow, compound literals, declarations) and underpins reflection-driven
code generation and `#compiler` hooks. Reflection helpers that pair well with it
(`type_info`, `typeid_of`, `Any`, field navigation) are documented in
[12](12_reflection_and_constraints.md).

## 8. `#derive` — generated impls from a type's shape

Tag a struct with `#derive(...)` and the compiler writes the mechanical, field-by-
field implementation for you — no per-type boilerplate:

```skarn
#derive(Eq)
Vec3 :: struct { x: i32, y: i32, z: i32 }

a: Vec3 = .{ 1, 2, 3 };
b: Vec3 = .{ 1, 2, 3 };
if a.eq(&b) { ... }     // `eq` was generated; called via UFCS
```

Each generator synthesizes an in-struct method (or associated function) from the
struct's fields. Built-in generators:

| Derive | Generates | Call |
|---|---|---|
| `Eq` | `eq(self, other) -> bool` — field-by-field `&&` | `a.eq(&b)` |
| `Ord` | `cmp(self, other) -> i32` — lexicographic `-1/0/1` | `a.cmp(&b)` |
| `Hash` | `hash(self) -> u64` — FNV-1a-style mix of the fields | `a.hash()` |
| `Default` | `default() -> Self` — `.{}` (associated fn) | `T::default()` |
| `Clone` | `clone(self) -> Self` — structural copy | `a.clone()` |
| `Add`/`Sub`/`Mul` | `add`/`sub`/`mul(self, other) -> Self` — field-wise | `a.add(&b)` |
| `Neg` | `neg(self) -> Self` — field-wise negation | `a.neg()` |
| `Min`/`Max` | field-wise via `core::min`/`core::max` | `a.min(&b)` |
| `Clamp` | field-wise `core::clamp(self.f, lo.f, hi.f)` | `a.clamp(&lo, &hi)` |
| `Scale` | `scale(self, s) -> Self` — multiply each field by scalar `s` | `a.scale(2)` |
| `Lerp` | `lerp(self, other, t) -> Self` — field-wise interpolation | `a.lerp(&b, t)` |
| `format` | `format(self, sb)` → `"Vec2 { x: 3, y: 4 }"` into a `StringBuilder` | `a.format(&sb)` |

List several at once: `#derive(Eq, Ord, Hash, Add, Lerp, format)`. They work on
multi-field, **generic** (`Box($T)` — a method per instantiation), and empty structs.
The generated bodies use the struct's own fields (`==`, `<`, `+`, …), so a field whose
type doesn't support the operation is a clear compile error. The arithmetic/vector
derives (`Add`/`Sub`/`Mul`/`Neg`/`Min`/`Max`/`Clamp`/`Scale`/`Lerp`) are how you do
vector math given skarn has no operator overloading — ideal for `std.math`'s
`Vec2`/`Vec3`/`Color`. `format` requires the struct's file to bring `StringBuilder`
into scope (`#import std.strings.{StringBuilder};`) and dispatches per field type
(`append_i64`/`append_u64`/`append_f64`/`append_bool`, recursing into a nested type's
own `format`). Recursing into nested fields for the other derives is a planned
enhancement.

### Writing your own derive

The built-ins above are not special — `#derive` is **open**. A `#derive(Name)` the
compiler doesn't recognize is *not an error*: it's left on the declaration for a
`#compiler` hook to handle. `compiler_decls()` exposes each declaration's requested
derives as `Decl.derives` (the space-separated `#derive(...)` names), so a hook
filters to the structs that opted in and generates their impl:

```skarn
#compiler
derive_sum :: fn() -> []const u8 {
    a := heap::make();
    sb := str::builder(&a);
    for d in core::compiler_decls() {
        match d.derives {                       // (string `==` isn't supported — use `match`)
            "Sum" => {
                sb.append("sum_"); sb.append(d.name);
                sb.append(" :: fn(p: "); sb.append(d.name); sb.append(") -> i32 { return 0");
                for f in d.fields { sb.append(" + p."); sb.append(f.name); }
                sb.append("; } ");
            }
            else => {}
        }
    }
    return sb.str();
}

#derive(Sum)
Point :: struct { x: i32, y: i32 }              // → `sum_Point` is generated
```

Built-in (parser-side) and user (hook-side) derives coexist on the same struct. For a
struct with several derives `Decl.derives` is `"A B C"`, so match the exact string for
a single derive or substring-check for membership.

Unlike Rust's `#[derive]` (proc-macros with full ambient power — the `build.rs`
supply-chain surface), a skarn derive is a compiler-side generator driven by the type's
structure; the roadmap (R2, [09](09_comptime_vm_roadmap.md)) scopes user-written
generators to a pure `AstTransform` capability so a third-party derive **cannot**
touch the filesystem, network, or FFI. *Derive without the build.rs risk.*

> Built-in derives: `Eq`, `Ord`, `Hash`, `Default`, `Clone`, `Add`, `Sub`, `Mul`,
> `Neg`, `Min`, `Max`, `Clamp`, `Scale`, `Lerp`, `format`. `json`, `Builder`, and
> `bytes` follow the same shape — they slot into the derive registry in
> `src/parser.zig:synthDerive`.
