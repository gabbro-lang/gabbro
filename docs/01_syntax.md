# Syntax Reference

Every lexical element of Skarn: comments, identifiers, literals, operators, and punctuation.

## Comments

Skarn supports **line comments only**. There are no block comments.

A line comment begins with `//` and extends to the end of the line:

```skarn
// This is a comment
x := 42; // inline comment
```

> [!NOTE]
> Block comments (`/* ... */`) are intentionally omitted from Skarn. Use multiple line comments instead.

## Identifiers

Identifiers name variables, functions, types, and other declarations.

**Rules:**
- Must start with a letter (`a`–`z`, `A`–`Z`) or underscore (`_`)
- May continue with letters, digits (`0`–`9`), or underscores
- Are **case-sensitive** — `foo`, `Foo`, and `FOO` are three distinct identifiers

```skarn
x := 1;
my_variable := 2;
_private := 3;
Point2D :: struct { x: f64, y: f64 };
```

### Escaped Identifiers

Prefix an identifier with `@` to use a keyword as a regular identifier, or to define special names (like the runtime's `@panic`) without clashing with user names:

```skarn
@if := 42;          // uses the keyword 'if' as a variable name
@panic("oh no");    // standard library panic function
```

## Keywords

The following table lists every keyword in Skarn, grouped by category.

### Declaration Keywords

| Keyword | Purpose |
|---------|---------|
| `fn` | Function declaration |
| `struct` | Struct type definition |
| `interface` | Interface (trait) type definition |
| `enum` | Enum type definition |
| `errors` | Error set type definition |
| `distinct` | Distinct (newtype) wrapper |
| `opaque` | Opaque type (forward declaration) |
| `pub` | Public visibility modifier |

### Qualifier Keywords

| Keyword | Purpose |
|---------|---------|
| `atomic` | Atomic type qualifier |
| `borrow` | Borrow qualifier for zone-owned values |
| `const` | Const qualifier |
| `volatile` | Volatile qualifier |

### Control Flow Keywords

| Keyword | Purpose |
|---------|---------|
| `if`, `else` | Conditional branching |
| `while` | While loop |
| `for`, `in` | For loops (range and slice iteration) |
| `match` | Pattern matching |
| `return` | Return from function |
| `break` | Break from loop |
| `continue` | Continue to next loop iteration |
| `defer` | Deferred execution (runs at scope exit) |

### Other Keywords

| Keyword | Purpose |
|---------|---------|
| `zone` | Memory allocation zone |
| `as` | Type cast / interface implementation |
| `unsafe` | Unsafe block or expression |
| `import` | Module import (used as `#import`) |
| `type` | Type keyword (used in generic parameters: `$T: type`) |
| `fail` | Fail with error |
| `catch` | Catch errors |

### Literal Keywords

| Keyword | Purpose |
|---------|---------|
| `null` | Null literal (for optionals) |
| `true` | Boolean true |
| `false` | Boolean false |

## Primitive Type Keywords

Skarn provides a fixed set of primitive types:

| Type | Description |
|------|-------------|
| `bool` | Boolean (`true` or `false`) |
| `void` | Void / unit type |
| `i8` | 8-bit signed integer |
| `i16` | 16-bit signed integer |
| `i32` | 32-bit signed integer |
| `i64` | 64-bit signed integer |
| `isize` | Pointer-sized signed integer |
| `u8` | 8-bit unsigned integer |
| `u16` | 16-bit unsigned integer |
| `u32` | 32-bit unsigned integer |
| `u64` | 64-bit unsigned integer |
| `usize` | Pointer-sized unsigned integer |
| `f32` | 32-bit IEEE 754 float |
| `f64` | 64-bit IEEE 754 float |

> [!NOTE]
> `f32` and `f64` are handled as identifiers (not keywords) at the lexer level, but are recognized as primitive types during semantic analysis.

## Literals

### Integer Literals

Integer literals can be written in decimal, hexadecimal, or binary. Underscores may be used anywhere within the digit sequence for readability.

```skarn
42            // decimal, type inferred
42i32         // explicit i32 suffix
255u8         // explicit u8 suffix
1000u64       // explicit u64 suffix
0xFF          // hexadecimal
0xff          // hex (case insensitive)
0b1010        // binary
1_000_000     // underscores for readability
0xDEAD_BEEF   // hex with underscores
```

**Base prefixes:**

| Prefix | Base | Digits |
|--------|------|--------|
| *(none)* | 10 (decimal) | `0`–`9` |
| `0x` / `0X` | 16 (hexadecimal) | `0`–`9`, `a`–`f`, `A`–`F` |
| `0b` / `0B` | 2 (binary) | `0`, `1` |

**Type suffixes:**
An integer literal may end with a type suffix to specify its exact type: `i8`, `i16`, `i32`, `i64`, `isize`, `u8`, `u16`, `u32`, `u64`, `usize`. Without a suffix, the type is inferred from context.

### Float Literals

Float literals always contain a decimal point. A fractional part is required.

```skarn
3.14      // f64 by default
1.0       // decimal with fractional part required
0.5       // leading zero
```

> [!NOTE]
> Bare integers like `1` are not implicitly treated as floats. You must write `1.0` when a floating-point value is intended.

### String Literals

String literals are enclosed in double quotes. The type of a string literal is `[]const u8`.

```skarn
"hello world"      // simple string
"line1\nline2"     // escape sequences
"tab\there"        // tab character
"quote\"inside"    // escaped double-quote
"backslash\\"      // escaped backslash
```

**Escape sequences:**

| Sequence | Meaning |
|----------|---------|
| `\\` | Backslash |
| `\"` | Double quote |
| `\n` | Newline (LF) |
| `\t` | Horizontal tab |
| `\r` | Carriage return |
| `\0` | Null byte |

### Character Literals

A character literal is written in single quotes and is **sugar for its integer
code point** — an untyped integer literal (like `65`) that coerces to `u8`,
`i32`, a `rune`, etc. from context. There is no dedicated `char` type.

```skarn
'A'        // 65
'.'        // 46
'\n'       // 10  — same escapes as strings
'\\'       // 92
'\''       // 39
'\x41'     // 65  — hex escape
```

Because it is just an integer literal, it works anywhere a number does:

```skarn
nl: u8 = '\n';
if name[i] == '.' { dots = dots + 1; }   // coerces to u8 in the comparison
```

A bare multi-byte UTF-8 character (e.g. `'é'`) decodes to its Unicode code point.

### Boolean Literals

```skarn
true
false
```

### Null Literal

The `null` literal is used with optional types:

```skarn
null  // for optionals
```

## Operators

### Arithmetic Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `+` | Addition | `a + b` |
| `-` | Subtraction | `a - b` |
| `-` | Unary negation (prefix) | `-x` |
| `*` | Multiplication | `a * b` |
| `/` | Division | `a / b` |
| `%` | Remainder (modulo) | `a % b` |

### Comparison Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `==` | Equal | `a == b` |
| `!=` | Not equal | `a != b` |
| `<` | Less than | `a < b` |
| `<=` | Less than or equal | `a <= b` |
| `>` | Greater than | `a > b` |
| `>=` | Greater than or equal | `a >= b` |

> [!NOTE]
> Comparison operators are non-chaining. An expression like `a < b < c` is a compile error. Use `a < b && b < c` instead.

### Logical Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `&&` | Logical AND (short-circuiting) | `a && b` |
| `\|\|` | Logical OR (short-circuiting) | `a \|\| b` |
| `!` | Logical NOT (prefix) | `!flag` |

### Bitwise Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `&` | Bitwise AND | `a & b` |
| `\|` | Bitwise OR | `a \| b` |
| `^` | Bitwise XOR | `a ^ b` |
| `~` | Bitwise NOT (prefix) | `~mask` |
| `<<` | Left shift | `a << 4` |
| `>>` | Right shift | `a >> 2` |

> [!NOTE]
> The `&` symbol doubles as the **address-of** operator when used as a prefix: `&my_var`.

### Assignment Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `=` | Assignment | `x = 10` |
| `+=` | Add and assign | `x += 1` |
| `-=` | Subtract and assign | `x -= 1` |
| `*=` | Multiply and assign | `x *= 2` |
| `/=` | Divide and assign | `x /= 2` |
| `%=` | Remainder and assign | `x %= 3` |
| `&=` | Bitwise AND and assign | `x &= mask` |
| `\|=` | Bitwise OR and assign | `x \|= bits` |
| `^=` | Bitwise XOR and assign | `x ^= bits` |
| `<<=` | Left shift and assign | `x <<= 1` |
| `>>=` | Right shift and assign | `x >>= 1` |

### Special Operators

| Operator | Kind | Description |
|----------|------|-------------|
| `?` | Postfix | Error propagation — returns early on error |
| `??` | Infix | Nil coalesce — provide a default for optional/error values |
| `!!` | Postfix | Force unwrap — panic on `null` or error |
| `as` | Infix | Type cast |
| `&` | Prefix | Address-of |
| `*` | Prefix | Pointer dereference |
| `.` | Infix | Field access / method call |
| `::` | Infix | Constant or declaration binding |
| `:=` | Infix | Variable binding (type-inferred) |
| `->` | — | Return type arrow (in function signatures) |
| `=>` | — | Match arm arrow |
| `..` | Infix | Exclusive range (e.g., `0..10`) |
| `..=` | Infix | Inclusive range (e.g., `0..=9`) |
| `$` | Prefix | Type parameter prefix (e.g., `$T`) |

### Operator Precedence

Operators are listed from **highest** to **lowest** precedence:

| Precedence | Operators | Associativity |
|:----------:|-----------|:-------------:|
| 1 (highest) | `!`, `~`, `&`, `*`, `-` (prefix) | Right-to-left |
| 2 | `*`, `/`, `%` | Left-to-right |
| 3 | `+`, `-` | Left-to-right |
| 4 | `<<`, `>>` | Left-to-right |
| 5 | `&` (bitwise) | Left-to-right |
| 6 | `^` | Left-to-right |
| 7 | `\|` | Left-to-right |
| 8 | `==`, `!=`, `<`, `<=`, `>`, `>=` | Left-to-right |
| 9 | `&&` | Left-to-right |
| 10 | `\|\|` | Left-to-right |
| 11 (lowest) | `?`, `!!`, `as`, `catch`, `??` (postfix/special) | Left-to-right |

> [!TIP]
> When in doubt, use parentheses to make precedence explicit. This improves readability and avoids subtle bugs.

## Declarations

### Constants (Compile-Time)

Constants are bound with `::` and must be computable at compile time. By convention, constant names use `UPPER_SNAKE_CASE`:

```skarn
MAX :: 100;
PI :: 3.14159;
GREETING :: "hello";
```

The initializer does not have to be a literal. Arithmetic over constants already
declared is folded to a value at build time, and constants compose to any depth:

```skarn
W      :: 800;
STRIDE :: W * 3;         // 2400, folded during the build
SIZE   :: STRIDE * 450;  // 1080000, folded through STRIDE
```

A constant must be declared before the constants that use it.

A string constant is a real `[]const u8` slice, so slice operations work on it
directly — `GREETING.len` is `5`, `GREETING[0]` is the first byte. (More generally,
field and index access work on any top-level constant, not just locals.)

Constants can also bind functions, types, and other compile-time constructs:

```skarn
add :: fn(a: i32, b: i32) -> i32 {
    return a + b;
};

Point :: struct {
    x: f64,
    y: f64,
};
```

### Mutable globals

A top-level binding written with `: T =` (instead of `::`) is a **mutable
global** — exactly the local-variable form, lifted to module scope. The operator
is the whole distinction: `::` is an immutable compile-time constant; `: T =`
(like a local's `=`) is a runtime-mutable variable. No `mut`/`var`/`static`
keyword.

```skarn
counter: i64 = 0;          // mutable global, explicit type required
flags:   u32 = 0u32;

bump :: fn() { counter += 1; }   // read + write from anywhere
```

The initializer must be a compile-time constant (it lives in static storage, like
a C `static`). A global's type is written explicitly; an immutable `::` constant
infers its type from the initializer. Reads load the current value; `=` and the
compound assignments (`+=`, …) store to it.

### Variables (Inferred Type)

Variables are declared with `:=`. The type is inferred from the right-hand side:

```skarn
x := 42;          // inferred as integer
name := "Skarn";     // inferred as []const u8
flag := true;     // inferred as bool
```

### Variables (Explicit Type)

When you need to specify the type explicitly, use `: Type =` syntax:

```skarn
count: i32 = 0;
data: [4]u8 = .{ 1u8, 2u8, 3u8, 4u8 };
buffer: [256]u8 = .{};
```

> [!TIP]
> Prefer `:=` with type inference when the type is obvious from context. Use explicit types when the inferred type would be ambiguous or when you need a specific numeric width.

## Punctuation Reference

| Symbol | Usage |
|--------|-------|
| `;` | Statement terminator — required after every statement |
| `,` | Separator in lists (parameters, fields, arguments) |
| `:` | Type annotation separator |
| `::` | Constant / declaration binding |
| `:=` | Variable binding (type inferred) |
| `( )` | Grouping, function parameters, call arguments |
| `{ }` | Blocks, struct bodies, enum bodies |
| `[ ]` | Array / slice indexing and type syntax |
| `.{ }` | Compound literal (struct, array, or enum initialization) |
| `#` | Directive prefix (`#import`, `#if`, `#run`, attributes) |
| `\|x\|` | Payload capture (in `match` arms, `catch` blocks, etc.) |

## Quick Example

Putting it all together — a small Skarn program demonstrating core syntax elements:

```skarn
std :: #import("std");

MAX_SIZE :: 1024;

Buffer :: struct {
    data: [MAX_SIZE]u8,
    len: usize,
};

make_buffer :: fn() -> Buffer {
    return .{
        .data = .{},
        .len = 0,
    };
};

append :: fn(buf: *Buffer, byte: u8) -> !void {
    if buf.len >= MAX_SIZE {
        fail error.Overflow;
    }
    buf.data[buf.len] = byte;
    buf.len += 1;
};

main :: fn() -> void {
    buf := make_buffer();

    // Fill the buffer with values
    for i in 0..10 {
        append(&buf, i as u8) catch |err| {
            std.debug.print("append failed: {}\n", .{err});
            return;
        };
    }

    std.debug.print("buffer has {} bytes\n", .{buf.len});
};
```
