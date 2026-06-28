# Modules, Interfaces, and Generics

## Modules

In Skarn, a module corresponds exactly to a file. 

### Imports

Use the `#import` directive to bring another module's public symbols into scope.
Paths are dot-separated relative to the current file, or start with `std.` for the
standard library. There are four forms:

```skarn
// 1. Namespace import — bind the module under its last path segment.
//    Members are reached with `::`; the module's names are NOT pulled into scope.
#import std.io;
... io::println("hi");   io::Writer ...

// 2. Aliased namespace — choose the namespace name yourself.
#import std.io as term;
... term::println("hi");

// 3. Selective — bring just the listed names in unqualified.
#import std.io.{ Writer, println };
... println("hi");

// 4. Glob — bring every public name in unqualified.
#import std.io.*;
... println("hi");

// Local modules work the same (sibling file math.sk):
#import math;            math::add(1, 2);
#import math.{ add };    add(1, 2);
```

**`::` vs `.`** — `::` accesses a *module namespace* member (`io::println`), while
`.` accesses a *value's* field or method (`point.x`, `writer.flush()`). Keeping
them distinct means a local variable named `io` never shadows the `io` namespace.

> **Collisions are fine.** Two different modules may each declare the same name
> (e.g. both define a `greet` or a `parse`); the compiler mangles colliding names
> per module internally, so they link cleanly. You reach each through its
> namespace (`a::greet`, `b::greet`) or a selective/glob import. A name is only
> mangled when it actually collides — unique names keep their bare linkage.

### Visibility

By default, all declarations (`fn`, `struct`, `const`, etc.) are private to the module.
Use the `pub` keyword to make them accessible from other modules.

```skarn
// Only usable in this file
helper :: fn() { ... }

// Usable by anyone who imports this file
pub connect :: fn() { ... }

// Public struct definition
pub User :: struct {
    id: u64,
    name: []const u8,
}
```

## Interfaces

Interfaces in Skarn define a set of methods that a type must implement. They enable
dynamic dispatch via `*InterfaceType` pointers.

### Declaration

```skarn
#import std.io.{ IoError };

pub Writer :: interface {
    write :: fn(*Self, []const u8) -> usize ! IoError;
    flush :: fn(*Self) -> void ! IoError;
}
```
Notice the `*Self` parameter. Every interface method must take `*Self` (or `borrow *Self`) as its first parameter.

### Implementation

You implement an interface for a concrete type using the `as` keyword outside of the struct definition:

```skarn
File :: struct { handle: usize }

// Implementing Writer for File
File as Writer {
    write :: fn(self: *Self, data: []const u8) -> usize ! IoError {
        // Implementation here...
        return data.len;
    }
    
    flush :: fn(self: *Self) -> void ! IoError {
        // Implementation here...
    }
}
```

### Dynamic Dispatch

You can implicitly coerce a pointer to a concrete type into an interface pointer.
Calls through an interface pointer use a vtable for dynamic dispatch.

```skarn
process :: fn(w: *Writer) -> !void {
    w.write("Hello")?;
}

main :: fn() {
    f := File { handle = 1 };
    
    // Implicit coercion from *File to *Writer
    process(&f) catch { return; };
}
```

### Extension Methods

Any function whose first parameter is named `self` acts as an extension method
and can be called using dot-syntax:

```skarn
pub write_all :: fn(self: *Writer, data: []const u8) -> usize ! IoError {
    // ...
}

// Can be called as:
// w.write_all(data)?
```

A type's *own* methods can instead be declared **inside the struct body** (where
`Self` and the struct's type parameters are implicit) — see
[Methods](02_types.md#methods). Use in-struct declarations for a type's own API and
free `self`-first functions to extend a type you don't own; an in-struct method
shadows a free function of the same name when called on that type.

## Generics

Skarn provides static polymorphism via monomorphized generics. 
Each unique combination of type arguments generates a separate, specialized copy of the function or struct.

### Generic Functions

Generic type parameters are prefixed with `$`:

```skarn
// $T is an unconstrained type parameter
identity :: fn(value: $T) -> T {
    return value;
}

// $T is inferred from the argument
main :: fn() {
    a := identity(42i32);  // T becomes i32
    b := identity(true);   // T becomes bool
}
```

You can also pass types explicitly as arguments:

```skarn
max :: fn($T: type, a: T, b: T) -> T {
    if a > b { return a; }
    return b;
}

// Call with explicit type
result := max(i32, 10, 20);
```

### Constrained Generics

You can constrain a type parameter to types that implement a specific interface:

```skarn
// $W must be a type that implements the Writer interface
print_to :: fn($W: Writer, writer: *W, data: []const u8) -> usize ! IoError {
    // Statically dispatched call! No vtable lookup overhead.
    return writer.write(data)?;
}
```

### Generic Structs

```skarn
Pair :: struct($T: type, $U: type) {
    first: T,
    second: U,
}

p: Pair(i32, bool) = .{ 42, true };
```
