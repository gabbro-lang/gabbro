# Skarn Language Overview

Skarn is an experimental systems programming language written in Zig. Key design principles:
- No hidden allocations
- Explicit dynamic dispatch through `*Interface` values
- Static polymorphism via monomorphized generics
- Allocation zones for lexical ownership without GC
- Debug builds trap undefined behavior close to its source

## Getting Started

Building:
```powershell
zig build
zig build test
```

With LLVM backend:
```powershell
zig build -Dllvm-path=Y:/SDK/LLVM
```

Compiler commands:
```text
skarn check <file>     Parse and type-check
skarn ir <file>        Print Skarn IR
skarn object <file>    Emit object file
skarn build <file>     Build executable (Windows)
```

## Hello World

```skarn
#import std.io.{ println };

main :: fn() -> i32 {
    println("hello from Skarn");
    return 0;
}
```

## Language at a Glance

```skarn
#import std.io.{ Writer, println, print_u64 };
#import std.mem.{ copy, eql_bytes };

// Constants use :: (compile-time binding)
MAX_SIZE :: 1024;

// Struct declaration
Greeting :: struct {
    name: []const u8,
    count: i32,
}

// Error type
AppError :: errors {
    not_found,
    overflow,
}

// Enum with payloads
Color :: enum {
    red,
    green,
    blue,
    custom: u32,
}

// Interface
Writer :: interface {
    write :: fn(*Self, []const u8) -> usize ! IoError;
    flush :: fn(*Self) -> void ! IoError;
}

// Interface implementation
Greeting as Writer {
    write :: fn(self: *Self, data: []const u8) -> usize ! IoError {
        return write_stdout(data);
    }
    flush :: fn(self: *Self) -> void ! IoError {}
}

// Function with generics
identity :: fn(value: $T) -> T {
    return value;
}

// Fallible function
parse :: fn(input: []const u8) -> i32 ! AppError {
    if input.len == 0 { fail .not_found; }
    return 42;
}

main :: fn() -> i32 {
    // Type-inferred locals
    x := 42;
    name := "Skarn";
    
    // Typed locals  
    count: i32 = 10;
    data: [4]u8 = .{ 1u8, 2u8, 3u8, 4u8 };
    
    // Pointers
    ptr := &count;
    *ptr = 20;
    
    // Slices
    slice := data[:];
    first := slice[0];
    sub := data[1..3];
    
    // Control flow
    if x > 0 {
        println("positive");
    } else {
        println("non-positive");
    }
    
    // While loop
    i := 0;
    while i < 10 {
        i += 1;
    }
    
    // For range
    for j in 0..10 {
        // j goes from 0 to 9
    }
    
    // For slice
    for val in slice {
        // iterate over elements
    }
    
    // Match
    color := Color.red;
    match color {
        .red => { println("red"); }
        .green => { println("green"); }
        .blue => { println("blue"); }
        .custom |value| => { print_u64(value as u64); }
    }
    
    // Error handling
    result := parse("hello") catch err {
        return 1;
    };
    
    // Zones (arena allocation)
    zone scratch: Arena {
        buf := scratch.new_slice(u8, 64);
        buf[0] = 42u8;
        // arena freed at end of zone
    }
    
    return 0;
}
```

## Design Philosophy

- **Systems language**: no GC, manual memory via zones
- **Everything explicit**: no hidden allocations, explicit dispatch
- **Safety by default**: debug builds catch UB at runtime
- **Simple module system**: file = module, pub for visibility
- **Growing incrementally**: complete semantics before more syntax

## Where to Go Next

- [01_syntax.md](01_syntax.md) - Syntax Reference
- [02_types.md](02_types.md) - Type System
- [03_functions_control_flow.md](03_functions_control_flow.md) - Functions & Control Flow
- [04_error_handling.md](04_error_handling.md) - Error Handling
- [05_memory_zones.md](05_memory_zones.md) - Memory Management & Zones
- [06_modules_interfaces.md](06_modules_interfaces.md) - Modules, Interfaces, and Generics
- [07_stdlib.md](07_stdlib.md) - Standard Library
- [08_attributes_builtins.md](08_attributes_builtins.md) - Attributes & Builtins
- [09_comptime_vm_roadmap.md](09_comptime_vm_roadmap.md) - Comptime VM
- [10_build_system.md](10_build_system.md) - Build System
- [11_c_interop.md](11_c_interop.md) - C Interop & `#extern`
- [12_reflection_and_constraints.md](12_reflection_and_constraints.md) - Reflection & Generic Constraints
- [13_metaprogramming.md](13_metaprogramming.md) - Metaprogramming (`#quote`/`#insert`/macros)
- [14_linux_elf_backend.md](14_linux_elf_backend.md) - Linux/ELF Backend (core implemented)
- [15_tooling.md](15_tooling.md) - Tooling & LSP
- [16_packages.md](16_packages.md) - Packages (design)
- [17_testing.md](17_testing.md) - Testing & `#test`
- [18_targets_and_tiers.md](18_targets_and_tiers.md) - Targets, ABIs & support tiers
