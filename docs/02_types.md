# Type System

Skarn is statically typed with full inference. It's strict where that catches bugs — distinct types, optionals, no implicit narrowing — and stays out of your way otherwise, through inference and compound literals.

## Primitive Types

### Integer Types

Skarn provides fixed-width signed and unsigned integer types:

| Signed | Unsigned | Size |
|--------|----------|------|
| `i8` | `u8` | 8-bit |
| `i16` | `u16` | 16-bit |
| `i32` | `u32` | 32-bit |
| `i64` | `u64` | 64-bit |
| `isize` | `usize` | pointer-width |

`isize` and `usize` are pointer-sized integers — 64 bits on 64-bit platforms. Use `usize` for array indices and lengths; use `isize` when you need a signed offset.

#### Integer Literals

Integer literals can carry a type suffix to specify their type explicitly:

```skarn
a := 42i32;       // i32
b := 255u8;        // u8
c := 1000u64;      // u64
d := 0usize;       // usize
```

Without a suffix, an integer literal's type is inferred from context. If no context constrains it, the literal defaults to `i32`.

A suffix is authoritative: it fixes the literal's width even through inference. `x := 0i64` gives `x` a 64-bit slot — the `i64` is not narrowed back to the `i32` default. This matters for values that exceed 32 bits (e.g. addresses built with `usize`/`i64`), where a narrowed slot would silently truncate the value.

Only the widths in the table above are valid suffixes (`i8`/`i16`/`i32`/`i64`/`isize`, their `u` twins, and `byte`). An unsupported or malformed width is a compile error rather than a silently-dropped suffix:

```skarn
x := 0u128;   // error: unsupported integer width `u128`: skarn integers are at most 64-bit — use `u64` or `usize`
y := 0u9;     // error: unsupported integer width `u9`: ...
z := 3.0f16;  // error: unsupported float width `f16`: skarn floats are `f32` or `f64`
```

A hex literal that legitimately ends in letters (`0xABC`, `0xFF`) is *not* a bad suffix — the suffix is split off only after the radix's digits, so hex digits are never mistaken for a width. Float literals accept only `f32`/`f64`.

#### Overflow policy

Skarn's policy for plain `+`, `-`, `*` is fixed and never undefined behavior:

| Build | Plain `+` `-` `*` on overflow |
| --- | --- |
| Debug (`-O0`) | **traps** — aborts at the operation, catching the bug at its source |
| Release (`-O1`+) | **wraps** (two's complement) |

So overflow is a loud crash while you develop and well-defined wraparound when you
ship — there is no overflow UB to exploit. When you specifically *want* wraparound
in every build (hashing, PRNGs, checksums, fixed-width counters), use the explicit
wrapping operators `+%`, `-%`, `*%`, which never trap:

```skarn
a := 250u8 +% 10u8;   // 4   — wraps at 256, never traps
h := h *% 16777619u32; // FNV-style hash step

fnv1a :: fn(s: []const u8) -> u32 {
    h := 2166136261u32;
    i := 0usize;
    while i < s.len { h = (h ^ (s[i] as u32)) *% 16777619u32; i = i + 1usize; }
    return h;
}
```

Wrapping operators are integer-only and behave identically at compile time, so a hash
like the above can be evaluated in a `#run` constant and matches its runtime value.

#### Sub-Byte Integer Types

Within packed structs, Skarn supports sub-byte integer types from `u1` through `u7`. These types cannot be used outside of packed struct fields:

```skarn
#packed
StatusBits :: struct {
    enabled: u1,
    priority: u3,
    mode: u4,
}
```

> [!NOTE]
> Sub-byte types are only valid as fields inside `#packed` structs. They cannot appear in function signatures, local variables, or non-packed struct fields.

### Float Types

| Type  | Size   | Precision        |
|-------|--------|------------------|
| `f32` | 32-bit | IEEE 754 single  |
| `f64` | 64-bit | IEEE 754 double  |

Float arithmetic and comparisons lower to the correct LLVM floating-point instructions.

```skarn
pi := 3.14159f64;
half := 0.5f32;
result := pi * 2.0;
```

### Boolean

`bool` holds one of two values: `true` or `false`.

```skarn
flag := true;
done: bool = false;
```

Booleans are used in conditions, logical expressions, and as flags. Skarn does not implicitly convert integers or pointers to `bool`.

### Void

`void` is the unit type. It carries no data and is used as the return type for functions that produce no value:

```skarn
log :: fn(msg: []const u8) -> void {
    // ...
}
```

You never construct a `void` value directly. A function with a `void` return simply ends without a return expression, or uses a bare `return;`.

## Composite Types

### Structs

Structs are the primary way to group related data into a single type:

```skarn
Point :: struct {
    x: i32,
    y: i32,
}
```

#### Construction

```skarn
// Named-field literal — order doesn't matter
p: Point = .{ .x = 10, .y = 20 };

// Positional compound literal (fields filled in declaration order)
p2: Point = .{ 10, 20 };

// Zero-initialized (all fields set to their zero value)
p3: Point = .{};
```

A named literal must name a real field of the struct, and every field without a
default must be supplied — otherwise it's a compile error (`no field …` /
`missing field …`).

#### Default field values

A field may declare a default with `= expr`. A named literal that omits the
field, or a positional/`.{}` literal that stops short of it, fills it from the
default. Defaults work like trailing default arguments — put defaulted fields
last so a positional literal can reach them:

```skarn
Config :: struct {
    name: []const u8,
    retries: i32 = 3,
    verbose: bool = false,
}

a: Config = .{ .name = "build" };               // retries = 3, verbose = false
b: Config = .{ .name = "ci", .verbose = true }; // retries = 3
c: Config = .{ "deploy", 5 };                   // verbose = false (default)
```

#### Field Access

```skarn
val := p.x;
p.y = 30;
```

> [!TIP]
> Use `.{}` zero initialization to ensure all fields start at known values. This is especially useful for large structs where you only need to override a few fields afterward.

### Packed Structs

The `#packed` attribute creates a struct with no padding between fields. This is essential for hardware registers, binary protocols, and memory-mapped I/O:

```skarn
#packed
Flags :: struct {
    readable: bool,
    writable: bool,
    executable: bool,
}
```

Packed structs support sub-byte field types (`u1` through `u7`), allowing precise bit-level layout:

```skarn
#packed
PixelFormat :: struct {
    red: u5,
    green: u6,
    blue: u5,
}
```

> [!IMPORTANT]
> Taking the address of a packed struct field is not allowed, because the field may not be byte-aligned. Access packed fields by value only.

### Generic Structs

Structs can be parameterized by types (and compile-time values) using `$`-prefixed parameters:

```skarn
Pair :: struct($T: type, $U: type) {
    first: T,
    second: U,
}

p: Pair(i32, bool) = .{ 42, true };
```

Generic structs are **monomorphized** — each unique combination of type arguments produces a distinct, specialized type at compile time. `Pair(i32, bool)` and `Pair(f64, f64)` are completely separate types.

```skarn
// A dynamically-growable array parameterized by element type
ArrayList :: struct($T: type) {
    items: []T,
    capacity: usize,
}

list: ArrayList(u8) = .{};
```

### Methods

Functions can be declared **inside** a struct body. Within the body, `Self` is the
struct type and the struct's type parameters are in scope, so methods on a generic
struct never re-spell `$T`:

```skarn
Vec2 :: struct {
    x: i32, y: i32

    // Associated function (no receiver) — called `Vec2::new(...)`:
    new :: fn(a: i32, b: i32) -> Self { return .{ a, b }; }

    // Methods (receiver `self: *Self`) — called `v.method(...)` via UFCS:
    dot  :: fn(self: *Self, o: *Self) -> i32 { return self.x * o.x + self.y * o.y; }
    len2 :: fn(self: *Self) -> i32 { return self.dot(self); }
}

p := Vec2::new(3, 4);   // associated function: `::`, no receiver
n := p.len2();          // method: `.`, receiver auto-passed (25)
```

```skarn
Box :: struct($T: type) {
    value: T
    make :: fn(v: T) -> Self { return .{ v }; }       // T inferred from the arg
    get  :: fn(self: *Self) -> T { return self.value; } // T inferred from the receiver
}

b := Box::make(10);     // Box(i32)
v := b.get();           // 10
```

Two call forms, matching Skarn's `::` / `.` split:

- **`Type::name(...)`** for an *associated* function — one with no `self` (a
  constructor, factory, or type-level helper). Mirrors module member access.
- **`value.name(...)`** for a *method* — one whose first parameter is `self: *Self`
  (or `Self`). Uses the same UFCS machinery as free-function extension methods.

A method declared inside a type **shadows** a free function of the same name when
called on that type, so a type can own a `load`/`add`/… without colliding with an
unrelated free function. Conversely, you can still add methods to a type you don't
own by writing a free `self`-first function (see *Extension Methods* in the modules
chapter) — in-struct declarations are for a type's own API, free functions for
extension.

> In-struct methods are sugar: each is lowered to a top-level function named
> `<Struct>.<method>` with `Self` resolved and the struct's type parameters
> inherited, so they cost nothing the existing generic/UFCS machinery doesn't
> already pay. To constrain an inherited type parameter (e.g. "integers only"),
> give the method a `where { … }` clause.

### Enums

Enums define a type that holds one of a fixed set of variants:

```skarn
Direction :: enum {
    north,
    south,
    east,
    west,
}

d := Direction.north;
```

#### Dot Shorthand

When the expected type is known from context, you can use the dot shorthand:

```skarn
d2: Direction = .north;

move :: fn(dir: Direction) -> void { /* ... */ }
move(.east);
```

#### Enums with Payloads

Enum variants can carry associated data:

```skarn
Shape :: enum {
    circle: f64,             // radius
    rectangle: struct {      // inline struct payload
        width: f64,
        height: f64,
    },
    none,                    // no payload
}

s := Shape.circle(3.14);     // construct a variant with its payload
```

Construct a payload-carrying variant by calling the variant as `EnumType.variant(payload)`
(payload-less variants are just `EnumType.variant`). Recover the payload by pattern
matching:

```skarn
area :: fn(s: Shape) -> f64 {
    match s {
        .circle |r|    => return 3.14159 * r * r;
        .rectangle |b| => return b.width * b.height;
        else           => return 0.0;
    }
}
```

Enums with payloads are Skarn's approach to tagged unions. Construction and matching
both work at compile time too, so comptime code can build and inspect them — the
basis for constructing `ast.*` values programmatically in metaprogramming.

### Error Types

Error types are declared with the `errors` keyword. They look similar to enums but are specifically designed for use with Skarn's fallible function system:

```skarn
IoError :: errors {
    not_found,
    permission_denied,
    timeout,
}

ParseError :: errors {
    invalid_input,
    overflow: i64,    // error variant with a payload
}
```

Error types integrate with the `!` operator in function return types to indicate fallible operations:

```skarn
read_file :: fn(path: []const u8) -> []u8 ! IoError {
    // ...
}
```

> [!NOTE]
> See the [Error Handling](05_error_handling.md) chapter for full details on `try`, `catch`, and error propagation.

## Pointer Types

Skarn provides several pointer kinds for different use cases.

### Single Pointers

A single pointer points to exactly one value:

| Syntax          | Description                          |
|-----------------|--------------------------------------|
| `*T`            | Mutable pointer to `T`              |
| `*const T`      | Immutable (const) pointer to `T`    |
| `*volatile T`   | Volatile pointer to `T`             |

```skarn
x := 42;
ptr: *i32 = &x;       // take address of x
val := *ptr;           // dereference: read the value (42)
*ptr = 100;            // dereference: write a new value
```

- `*const T` prevents modification through the pointer. The underlying data may still be mutable through another path.
- `*volatile T` ensures every read and write goes to memory, preventing the compiler from optimizing accesses away. Use this for memory-mapped hardware registers.

### Many Pointers

A many-pointer points to an array of values whose length is not tracked:

| Syntax          | Description                              |
|-----------------|------------------------------------------|
| `[*]T`          | Mutable many-pointer to `T`             |
| `[*]const T`    | Const many-pointer to `T`               |

```skarn
buffer: [*]u8 = get_raw_buffer();
first := buffer[0];
buffer[3] = 0xFF;
```

> [!WARNING]
> Many pointers perform **no bounds checking**. Indexing past the actual allocation is undefined behavior. Prefer slices (`[]T`) whenever you know the length.

## Slice Types

Slices are a **pointer + length** pair, providing bounds-checked access to a contiguous sequence of elements:

| Syntax        | Description                    |
|---------------|--------------------------------|
| `[]T`         | Mutable slice of `T`          |
| `[]const T`   | Const slice of `T`            |

```skarn
arr: [4]i32 = .{ 1, 2, 3, 4 };

slice := arr[:];          // full slice of the array
sub := arr[1..3];         // elements at indices 1 and 2
first := slice[0];        // bounds-checked index access
len := slice.len;         // number of elements
raw := slice.ptr;         // underlying pointer ([*]T)
```

String literals in Skarn have the type `[]const u8`:

```skarn
greeting: []const u8 = "hello, world";
```

### Comparing strings

`==` and `!=` on `[]const u8` (and `[]u8`) compare **contents**, not slice
identity. The comparison checks the length first, then the bytes, so it never
reads past either slice:

```skarn
a: []const u8 = "abc";
b: []const u8 = "abc";

a == b        // true  — same contents
a == "abc"    // true  — either side may be a literal
a != "abd"    // true
"ab" == "abc" // false — different length
```

This is the same byte-wise lowering used by `match` string patterns, and it
runs in the compile-time VM too, so string comparisons fold at comptime (handy
in `#run` constants and `#compiler` hooks, e.g. `if d.derives == "Sum"`).

> [!NOTE]
> Other slice element types (e.g. `[]i32`) do not get content comparison —
> `==` is defined for byte slices (strings). Compare those element-by-element.

> [!TIP]
> Slices are the preferred way to pass sequences of data. They are lightweight (just two machine words) and safe (bounds-checked at runtime).

## Array Types

Arrays are fixed-size, stack-allocated sequences:

```skarn
[N]T    // array of N elements of type T
```

```skarn
data: [4]u8 = .{ 1u8, 2u8, 3u8, 4u8 };
zeros: [256]u8 = .{};                    // zero-initialized
len := data.len;                          // compile-time known: 4
```

Arrays differ from slices in that their length is part of the type. `[4]u8` and `[8]u8` are different types. To pass an array to a function expecting a slice, use the slice operator:

```skarn
process :: fn(items: []const u8) -> void { /* ... */ }

buf: [16]u8 = .{};
process(buf[:]);    // convert array to slice
```

## Optional Types

An optional wraps a value that may or may not be present:

```skarn
?T    // either a value of type T, or null
```

```skarn
maybe: ?i32 = 42;
none: ?i32 = null;
```

### Unwrapping Optionals

#### Force Unwrap (`!!`)

Extracts the value, **panicking at runtime** if the optional is `null`:

```skarn
val := maybe!!;    // 42 — or panic if null
```

#### Nil Coalesce (`??`)

Provides a default value when the optional is `null`:

```skarn
val := maybe ?? 0;    // 42, or 0 if maybe were null
```

#### Conditional Checks

```skarn
if maybe != null {
    // maybe is guaranteed non-null in this branch
}
```

> [!CAUTION]
> Avoid `!!` in production code paths unless you are certain the value cannot be `null`. Prefer `??` or explicit null checks to handle the `null` case gracefully.

## Function Types

Function types describe a function's signature as a first-class type:

```skarn
fn(i32, i32) -> i32                        // two i32 params, returns i32
fn(*Self, []const u8) -> usize ! IoError   // fallible method
fn() -> void                               // no params, no return value
```

Function types allow storing and passing functions as values:

```skarn
apply :: fn(f: fn(i32) -> i32, x: i32) -> i32 {
    return f(x);
}

double :: fn(n: i32) -> i32 { return n * 2; }

result := apply(double, 21);    // 42
```

## Distinct Types

Distinct types create **newtypes** — types that share the underlying representation but are treated as separate types by the compiler:

```skarn
UserId :: distinct u64;
Pixels :: distinct i32;
```

This prevents accidental mixing of semantically different values:

```skarn
user: UserId = 42u64 as UserId;
offset: Pixels = 100i32 as Pixels;

// ERROR: cannot pass Pixels where UserId is expected
// lookup(offset);
```

Convert between a distinct type and its underlying type with `as`:

```skarn
id: UserId = 42u64 as UserId;
raw := id as u64;              // back to plain u64
```

> [!TIP]
> Distinct types are zero-cost. At runtime, `UserId` and `u64` have identical representation. The distinction exists only at compile time for type safety.

## Type Aliases

A type alias gives an existing type a second name. Unlike `distinct`, an alias is
**transparent** — the alias and its underlying type are fully interchangeable:

```skarn
MyInt :: i32;
Bytes :: []u8;
Trio  :: [3]i32;
CStr  :: [*]const u8;

add :: fn(a: MyInt, b: MyInt) -> i32 { return a + b; }  // MyInt == i32
```

An alias is recognized when the right-hand side **begins with a type** — a
primitive type keyword (`i32`, `bool`, …) or a type constructor (`[`, `*`, `[*`,
`?`, `borrow`, `atomic`). A bare-identifier right-hand side stays a value
constant, so `Foo :: Bar` is a constant, not an alias (alias-to-named-type is not
supported yet).

The standard library uses aliases for C ABI types — see [`std.c`](07_stdlib.md):

```skarn
#import std.c.{ c_int, c_size_t };
#extern("msvcrt", "strlen")
strlen :: fn(s: [*]const c_char) -> c_size_t;
```

## Opaque Types

Opaque types declare a type with no visible definition. They can only be used behind a pointer:

```skarn
Foo :: opaque;
```

```skarn
// Only *Foo is usable — you cannot create or inspect a Foo value directly
get_handle :: fn() -> *Foo { /* ... */ }
use_handle :: fn(h: *Foo) -> void { /* ... */ }
```

Opaque types are useful for:
- **FFI boundaries** — wrapping C `void*` handles with a named type.
- **Abstraction** — exposing a handle to callers without revealing the implementation.

## Atomic Types

The `atomic` qualifier is applied to struct fields to enable atomic memory operations:

```skarn
Counter :: struct {
    value: atomic u32,
}
```

Atomic fields must be accessed through the `atomic_load` and `atomic_store` builtins rather than through regular field access:

```skarn
c := Counter { value = 0 };
current := core::atomic_load(&c.value);
atomic_store(&c.value, current + 1);
```

> [!NOTE]
> The `atomic` qualifier is only valid on struct fields. See the [Builtins](08_builtins.md) chapter for the full set of atomic operations available.

## Borrow Types

The `borrow` qualifier creates a temporary, non-owning reference to zone-allocated data:

```skarn
borrow *T       // borrowed pointer
borrow []T      // borrowed slice
```

Borrowed references allow you to pass zone-owned values to functions without transferring ownership:

```skarn
print_name :: fn(name: borrow []const u8) -> void {
    // Can read `name` but cannot store it or return it
}
```

### Borrow Rules

| Allowed | Not Allowed |
|---------|-------------|
| Read through the reference | Store in a struct field |
| Pass to another `borrow` parameter | Return from a function |
| Use in expressions | Forward to a non-`borrow` parameter |

> [!IMPORTANT]
> Borrowed references are a compile-time safety mechanism. They guarantee that zone-owned data is not accidentally captured beyond its intended scope. See the [Memory Management](06_memory.md) chapter for details on zones and ownership.

## Type Casting

The `as` operator performs explicit type conversions:

```skarn
x := 42i32;
y := x as i64;          // integer widening (lossless)
z := x as u32;          // signed to unsigned
f := x as f64;          // integer to float
i := 3.14 as i32;       // float to integer (truncates toward zero)
d := id as u64;         // distinct type to underlying type
```

All casts in Skarn are explicit and visible in the source code. The compiler will reject `as` casts that are nonsensical (e.g., casting a struct to an integer).

### Cast Summary

| From | To | Behavior |
|------|----|----------|
| Small int | Larger int | Zero/sign extension |
| Large int | Smaller int | Truncation |
| Signed int | Unsigned int | Bit reinterpretation |
| Integer | Float | Nearest representable value |
| Float | Integer | Truncation toward zero |
| Distinct type | Underlying type | Identity (no-op at runtime) |
| Underlying type | Distinct type | Identity (no-op at runtime) |

## Type Coercion Rules

Skarn performs a small, well-defined set of **implicit coercions**. These are the only cases where a value of one type is silently accepted as another:

| Source | Target | Description |
|--------|--------|-------------|
| Integer literal | Any integer type | Only if the literal's value fits in the target type |
| Array (`[N]T`) | Slice (`[]T`) | Via the `[:]` slice operator |
| Concrete type | `*Interface` pointer | When the type implements the interface (checked at compile time) |
| Non-null value | Optional (`?T`) | A value of type `T` is accepted where `?T` is expected |

All other conversions require an explicit `as` cast. Skarn intentionally keeps implicit coercions to a minimum to prevent subtle type errors.

> [!NOTE]
> Integer literals are special: the literal `42` can become `u8`, `i64`, `usize`, or any integer type — as long as the value fits. Once bound to a variable with a concrete type, no further implicit conversion occurs.
