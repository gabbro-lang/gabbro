# Functions & Control Flow

## Function Declarations

Functions are declared with `::` and `fn`:

```skarn
// Named function
add :: fn(a: i32, b: i32) -> i32 {
    return a + b;
}

// Public function (exported from module)
pub multiply :: fn(a: i32, b: i32) -> i32 {
    return a * b;
}

// Function with no return value
greet :: fn() {
    println("hello");
}

// Function returning void explicitly
process :: fn(data: []const u8) -> void {
    // ...
}
```

> [!NOTE]
> Functions without an explicit return type implicitly return `void`. Writing `-> void` is optional but permitted for clarity.

## Parameters

```skarn
// Value parameters
add :: fn(a: i32, b: i32) -> i32 { ... }

// Pointer parameters (allows mutation)
increment :: fn(value: *i32) {
    *value += 1;
}

// Slice parameters
sum :: fn(values: []const i32) -> i32 { ... }

// Borrow parameters (for zone-owned values)
fill :: fn(data: borrow []u8) {
    data[0] = 42u8;
}

// Self parameter (enables dot-call syntax)
pub doubled :: fn(self: i32) -> i32 {
    return self * 2;
}
// Called as: x.doubled() or doubled(x)
```

| Parameter Style | Syntax            | Semantics                                      |
|-----------------|-------------------|-------------------------------------------------|
| Value           | `a: i32`          | Passed by value (copy)                          |
| Pointer         | `p: *i32`         | Mutable pointer to a value                      |
| Const pointer   | `p: *const i32`   | Read-only pointer to a value                    |
| Slice           | `s: []const u8`   | Read-only view into contiguous memory            |
| Borrow          | `b: borrow []u8`  | Zone-aware borrowed reference                   |
| Self            | `self: T`         | Enables dot-call syntax on type `T`             |

## Self and Methods

Any top-level function whose first parameter is named `self` can be called using **dot-call syntax**:

```skarn
// In module point.sk:
pub distance :: fn(self: *Point) -> f64 { ... }

// Calling:
p: Point = .{ 3, 4 };
d := p.distance();      // auto-referenced to `&p`; same as distance(&p)
```

A `*Self` method auto-references its receiver, so you call it with a plain value —
no explicit `&`. It works on a **temporary** too: the value is spilled to a stack slot and pointed
at. Methods chain on returned values:

```skarn
n := make_point(3, 4).distance();        // call on a temporary
q := origin().translate(1, 2).scaled(3); // chain method calls
```

> [!NOTE]
> A method on a temporary receiver sees a copy, so any mutation it makes is
> discarded with the temporary — chaining is for transforming/reading.

## Generic Functions

Skarn uses the `$` prefix to introduce type parameters. The first occurrence of `$T` binds the type; subsequent uses of `T` refer to the bound type.

```skarn
// Type parameter with $
identity :: fn(value: $T) -> T {
    return value;
}

// Multiple type params
swap :: fn(a: $T, b: $U) -> U { ... }

// Explicit type param
max :: fn($T: type, a: T, b: T) -> T {
    if a > b { return a; }
    return b;
}
// Called as: max(i32, 10, 20)

// Constrained type param (must implement interface)
print_to :: fn($W: Writer, writer: *W, data: []const u8) -> usize ! IoError {
    return writer.write(data)?;
}
```

> [!NOTE]
> Generics are **monomorphized** — each unique type argument produces a specialized version at compile time. There is no runtime dispatch overhead.

## Lambdas (Anonymous Functions)

An expression of the form `fn(params) -> Ret { body }` is a **lambda** — an
anonymous function you can pass directly to a higher-order function or store in
a variable. The return type is optional (defaults to `void`).

```skarn
// As an argument — no need to declare a named predicate.
n := slice::count_where(i32, xs, fn(x: i32) -> bool { return x < 0; });

// Stored in a local, then called.
twice := fn(x: i32) -> i32 { return x * 2; };
y := twice(21); // 42

// A bare function name is itself a value:
sq := square;   // square is a top-level fn
z := sq(8);
```

Functions are first-class values: a function name (or a lambda) has a
**function-pointer type** `fn(Params) -> Ret`, which you can name explicitly:

```skarn
op: fn(i32, i32) -> i32 = add;
r := op(2, 3);
```

### Capturing closures

A lambda may reference variables from the enclosing scope; they are **captured by
value** when the closure is created:

```skarn
mul :: fn(f: fn(i32) -> i32, v: i32) -> i32 { return f(v); }

main :: fn() -> i32 {
    factor: i32 = 10;
    scale := fn(x: i32) -> i32 { return x * factor; }; // captures `factor`
    return mul(scale, 4); // 40
}
```

A function value is a **fat closure** `{ fn, env }`: a function pointer plus a
pointer to its captured environment. A plain (non-capturing) function or lambda
has an empty environment, so it costs no more than a bare pointer; a capturing
lambda copies the captured values into a small environment when it is created.

**Where the environment lives** follows skarn's region model:

- Inside a `zone`, a capturing closure's environment is allocated on the **zone's
  Arena**, so the closure is valid for the whole zone — it can be stored and
  handed around freely within that scope:

  ```skarn
  zone scratch: Arena {
      base: i32 = 100;
      f := fn(x: i32) -> i32 { return base + x; }; // env on `scratch`
      r = call_it(f, 7);                            // safe anywhere in the zone
  }
  ```

- Given an `*Arena` parameter, the environment is allocated in that
  **caller-supplied region** — so a factory can *return* an escaping closure that
  stays valid for as long as the caller's arena (region passing):

  ```skarn
  make_adder :: fn(into: *Arena, n: i32) -> fn(i32) -> i32 {
      return fn(x: i32) -> i32 { return x + n; }; // env allocated in `into`
  }

  zone z: Arena {
      add5 := make_adder(&z, 5);
      r = add5(10); // 15 — `add5` outlives `make_adder`, valid for the zone
  }
  ```

- Otherwise, the environment lives on the **stack frame** that created it. Such a
  closure is safe to *call* and to *pass down* to a higher-order function (the
  common case), but cannot outlive that frame.

> [!IMPORTANT]
> **Returning a capturing closure requires an `*Arena` parameter** (so the
> environment lives in the caller's region). Without one it is a compile error —
> the environment belongs to a stack frame or a zone that ends with the function,
> so it would dangle:
> ```
> error: a capturing closure cannot be returned: its captured environment lives
> in this function and would be left dangling (take an `*Arena` parameter so the
> closure's environment is allocated in the caller's region)
> ```
> This applies whether you return the closure directly or via a local. Returning
> a *non*-capturing function value is always fine (it's just a pointer).

> [!NOTE]
> Lambdas are **lifted** to ordinary top-level functions at compile time. A
> non-capturing lambda is just a named function and a pointer.

> [!NOTE]
> Function values also work at **compile time**: a higher-order call evaluated in
> `#run` (or any comptime context) folds to a constant — both non-capturing and
> capturing closures. One edge: an inline lambda used *directly* as an argument in
> a top-level constant initializer isn't supported yet — bind it to a local first
> (`f := fn(x){ … }; K :: #run g(f);`) or use a named function.

## Fallible Functions

Functions that can fail use `!` after the return type to declare an error channel:

```skarn
// Named error type
read :: fn(buf: []u8) -> usize ! IoError { ... }

// Inline error set
parse :: fn(s: []const u8) -> i32 ! { invalid, overflow } { ... }

// Inferred error type
combine :: fn() -> i32 ! { ... }
```

> [!TIP]
> See the [Error Handling](05_error_handling.md) chapter for full details on error propagation, `try`, `catch`, and the `?` operator.

## External Functions

FFI declarations for calling C or system functions use the `#extern` attribute:

```skarn
#extern("kernel32", "GetStdHandle")
GetStdHandle :: fn(id: i32) -> usize;

#extern("kernel32", "WriteFile")
WriteFile :: fn(
    handle: usize,
    buf: *const u8,
    len: u32,
    written: *u32,
    overlapped: ?*void,
) -> bool;
```

> [!WARNING]
> External function calls are inherently unsafe. The compiler cannot verify the correctness of the foreign function's signature or behavior.

## Function Attributes

Attributes are placed before the function declaration to modify compilation behavior:

```skarn
#inline
pub fast_add :: fn(a: i32, b: i32) -> i32 { return a + b; }

#noinline
slow_path :: fn() { ... }

#noreturn
abort :: fn() { ... }

#naked
asm_entry :: fn() { ... }

#entry
custom_entry :: fn() { ... }

#export
exported_fn :: fn() { ... }
```

| Attribute    | Effect                                                        |
|--------------|---------------------------------------------------------------|
| `#inline`    | Hint to always inline the function at call sites              |
| `#noinline`  | Prevent the function from being inlined                       |
| `#noreturn`  | Declares the function never returns (e.g., `abort`, `exit`)   |
| `#naked`     | Omit the function prologue/epilogue (for raw assembly)        |
| `#entry`     | Mark as the program entry point                               |
| `#export`    | Export the symbol for external linkage                         |

## Control Flow

### If / Else

```skarn
if x > 0 {
    println("positive");
} else {
    println("non-positive");
}

// Without else
if flag {
    do_something();
}

// With binding (if-let style)
if result := try_parse(input) {
    // result is available here
}

// With error payload capture
if result := try_parse(input) |err| {
    // err is bound to the captured error payload
} else {
    // success path
}
```

`else if` chains are supported and desugar to a nested `if` inside the `else`:

```skarn
if x > 0 {
    // positive
} else if x == 0 {
    // zero
} else {
    // negative
}
```

#### If as an expression

In value position, `if` produces a value. Each branch is a single expression in
braces, and an `else` is mandatory (an expression must always yield something):

```skarn
sign := if n > 0 { 1 } else if n < 0 { -1 } else { 0 };

mode: u32 = if enabled { 1u32 } else { 0u32 };   // branch literal takes the type

return base + if hit { bonus } else { 0 };        // anywhere an expression fits
```

The two branches must have compatible types, and the expected type flows into the
branches — so an untyped branch value (`.{ … }`, a bare `.variant`) is typed from
context, exactly like a `match` expression. (Statement-position `if { … }` is
unchanged; the expression form only applies where a value is required.)

### While Loop

```skarn
i := 0;
while i < 10 {
    println("loop");
    i += 1;
}
```

An infinite loop uses `while true`:

```skarn
while true {
    // runs forever until break
    if should_stop() { break; }
}
```

**Optional-unwrap loop** — `while opt |x|` re-evaluates `opt` each iteration,
binds the unwrapped payload to `x`, and exits when it is null. This is the clean
way to walk a linked structure or drain an iterator:

```skarn
cur: ?*Node = head;
while cur |n| {
    visit(n.val);
    cur = n.next;
}
```

The condition may be any optional; the `|x|` binding is optional itself
(`while opt { … }` loops while `opt` is non-null without binding the payload).

### For Range Loop

```skarn
// Exclusive range: 0, 1, 2, ..., 9
for i in 0..10 {
    print_u64(i as u64);
}

// Inclusive range: 0, 1, 2, ..., 10
for i in 0..=10 {
    print_u64(i as u64);
}
```

| Syntax     | Range            | Example values        |
|------------|------------------|-----------------------|
| `0..10`    | Exclusive end    | 0, 1, 2, …, 9        |
| `0..=10`   | Inclusive end     | 0, 1, 2, …, 10       |

### For Slice Loop

```skarn
data: [4]i32 = .{ 10, 20, 30, 40 };

// By value
for val in data[:] {
    print_i64(val as i64);
}

// With index
for val, idx in data[:] {
    // val is the element, idx is the index
}

// By reference
for &val in data[:] {
    *val += 1; // modify in-place
}
```

> [!TIP]
> Use `data[:]` to create a slice from a fixed-size array. See the [Types & Values](02_types_values.md) chapter for more on slices and arrays.

### For Iterators

`for x in it` also works over any value whose type has a method
`next(self: *Self) -> ?T`. Each iteration calls `next`; the loop binds the
unwrapped payload and stops when `next` returns `null` — exactly like
`while it.next() |x| { … }`, but without exposing the loop plumbing.

```skarn
Range :: struct { cur: i32, end: i32 }

// The iterator protocol: advance and yield, or return null when exhausted.
next :: fn(self: *Range) -> ?i32 {
    if self.cur >= self.end { return null; }
    v := self.cur;
    self.cur = self.cur + 1;
    return v;
}

main :: fn() -> i32 {
    r: Range = .{ 1, 5 };
    sum: i32 = 0;
    for x in r { sum = sum + x; } // 1 + 2 + 3 + 4 = 10
    return sum;
}
```

The index form `for x, i in it` is available too — `i` counts iterations from
`0`. Iterating by reference (`for &x in it`) is not allowed: a `next` method
yields values, not addresses.

### Match

Pattern matching on enums and integers:

```skarn
// Enum matching
match direction {
    .north => { println("going north"); }
    .south => { println("going south"); }
    .east  => { println("going east"); }
    .west  => { println("going west"); }
}

// Enum with payload capture
match shape {
    .circle    |radius| => { /* use radius */ }
    .rectangle |corner| => { /* use corner */ }
    .none               => { /* nothing */ }
}

// Integer matching: single values, grouped values, and ranges
match code {
    0        => { println("ok"); }
    1, 2, 3  => { println("warning"); }  // grouped cases
    400..=499 => { println("client"); }  // inclusive range (use `..` for exclusive)
    else     => { println("error"); }
}

// String matching
match command {
    "start"        => { /* ... */ }
    "stop", "halt" => { /* grouped */ }
    else           => { /* ... */ }
}

// A bare name binds the subject (a catch-all); `if` adds a guard
match n {
    0          => { /* zero */ }
    k if k < 0 => { /* negative, bound as k */ }
    k          => { /* positive, bound as k */ }
}

// Single-statement arms (no braces needed)
match value {
    .a   => return 1,
    .b   => return 2,
    else => return 0,
}

// Match as an expression — each arm yields a value, the whole match is that value
sign := match n {
    .neg  => -1,
    .zero => 0,
    .pos  => 1,
};

// Works in any value position: return, call arguments, initializers, arithmetic
return match code { 0 => 200, 1, 2, 3 => 400, else => 500 };
```

> [!IMPORTANT]
> Match on an enum is **exhaustiveness-checked**: every variant must be handled,
> or an `else` arm must be present, otherwise the compiler errors
> (*"non-exhaustive match: variant `.west` is not handled"*). A **total** match
> (one that covers every variant) needs no `else`, and because it is provably
> exhaustive it also **counts as returning on all paths** — so a function whose
> body is just a total match over `return` arms type-checks without a trailing
> `return`. A **duplicate** arm for the same variant is rejected. Integer matches
> are unbounded, so they require an `else` to be exhaustive.

> [!IMPORTANT]
> **Match as an expression**: in value position each arm is `pattern => value`
> (an expression, comma-separated). All arms must unify to one type, and the
> match must be **exhaustive** (it produces a value on every path) — a
> non-exhaustive value-match is an error. Untyped arm values (`.{ … }`, bare
> `.variant` enum literals) take their type from context (`c: C = match …`, a
> `return`, a call argument).

> [!NOTE]
> **Patterns**: enum variants (`.name`, optionally with a `|payload|` capture),
> integer values (single or grouped `1, 2, 3`), integer **ranges** (`1..5`
> exclusive, `1..=5` inclusive), **string** literals (single or grouped), a bare
> **name** (binds the subject — a catch-all), and `else`. Any arm may carry a
> **guard** `if <bool>` (evaluated after the binding; a failing guard falls
> through to the next arm). A guarded arm does not count toward exhaustiveness.
> String compares are length-gated, so a shorter subject is never read out of
> bounds.

### Break and Continue

`break` exits the innermost loop. `continue` skips to the next iteration:

```skarn
while true {
    if done() { break; }
    if skip() { continue; }
    process();
}
```

### Defer

`defer` schedules code to execute when the current scope exits. This guarantees cleanup regardless of how the scope is exited (normal return, error, break, etc.):

```skarn
// Always defer
defer { cleanup(); }

// Single expression defer
defer close(handle);

// Defer only on success
defer.ok { commit(); }

// Defer only on error
defer.err { rollback(); }
```

> [!NOTE]
> Multiple defers execute in **reverse order** (LIFO). The last defer registered runs first.

```skarn
// Example: LIFO order
defer { println("first registered, last to run"); }
defer { println("second registered, first to run"); }
// Output on scope exit:
//   second registered, first to run
//   first registered, last to run
```

### Unsafe Blocks

`unsafe` blocks disable certain safety checks. They are required for raw pointer operations, inline assembly, and other low-level operations:

```skarn
unsafe {
    raw_ptr := 0x1000 as *u8;
    *raw_ptr = 0;
}

// Unsafe expression
val := unsafe core::unaligned_read(u64, &x);
```

> [!CAUTION]
> Unsafe code bypasses the compiler's safety guarantees. Use sparingly and audit carefully. Incorrect unsafe code can cause undefined behavior, memory corruption, or security vulnerabilities.

### Compile-time Directives

Skarn supports compile-time evaluation through special directives:

```skarn
// Compile-time if
#if core::sizeof(usize) == 8 {
    // 64-bit platform code
} else {
    // 32-bit platform code
}

// Compile-time execution
#run {
    // Code executed at compile time
}

// Compile-time expression
size := #run compute_size();
```

| Directive | Purpose                                                        |
|-----------|----------------------------------------------------------------|
| `#if`     | Conditional compilation based on compile-time constants        |
| `#run`    | Execute code or expressions at compile time                    |

### Zone Blocks

Zone blocks provide scoped memory management. See the [Memory & Zones](06_memory_zones.md) chapter for full details:

```skarn
zone scratch: Arena {
    buf := scratch.new_slice(u8, 64);
    // arena freed at end of zone
}
```
