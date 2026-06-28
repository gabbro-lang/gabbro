# Memory & Zones

Skarn does not have a Garbage Collector (GC), nor does it rely on hidden allocations.
Instead, it uses a concept called **Zones** for safe, lexically-scoped memory
management, and **Borrowing** to pass memory around without violating ownership rules.

## Zone Blocks

A zone block defines a lexical scope and creates an allocation arena tied to that scope.

```skarn
zone scratch: Arena {
    // `scratch` is now a zone handle available in this block
    
    // Allocate a single value
    ptr := scratch.new(i32);
    *ptr = 42;
    
    // Allocate a slice
    buf := scratch.new_slice(u8, 1024);
    
    // Explicitly free an allocation (optional, arena clears automatically)
    scratch.free(ptr);
    
    // At the end of this block, the entire `scratch` arena is freed
}
```

- Currently, `Arena` is the only supported zone kind.
- You cannot nest zones with the same name.
- Memory allocated in a zone lives exactly as long as the zone's block.

### The handle is a real `std.heap.Arena`

A zone handle **is** a [`std.heap.Arena`](07_stdlib.md) — the same chunked bump
allocator you can construct manually with `std.heap.make()`. Entering the zone is
`handle := make()`; every exit path (normal, `return`, `break`, `continue`,
`fail`) runs `deinit()` automatically, so the arena is always drained on the way
out. You never write `make`/`deinit` yourself, and the module does not need to
`#import std.heap` — the compiler injects it whenever a zone block is present.

Because the handle is a full `Arena`, the entire library API is available on it,
not just `new`/`new_slice`:

```skarn
zone z: Arena {
    p   := z.new(i32);              // alias for alloc_one(i32)
    xs  := z.new_slice(u8, 64);     // alias for alloc(u8, 64)
    ys  := z.alloc(i32, 16);        // typed allocation
    raw := z.alloc_bytes(128);      // raw []u8
    cp  := z.dupe(u8, xs);          // copy a slice into the arena

    m := z.mark();                  // save a watermark …
    tmp := z.alloc_bytes(4096);     // … scratch work …
    z.restore(m);                   // … then rewind it, keeping the memory
}
```

`new`/`new_slice` remain as the zone-flavored spellings of `alloc_one`/`alloc`.
`free` is a compile-time-checked no-op: a bump arena reclaims everything at once
on zone exit, so freeing a single allocation only verifies ownership.

## Ownership and Escape Analysis

When you allocate memory in a zone, the resulting pointer (or slice) is "owned"
by that zone. Skarn performs strict escape analysis at compile time to ensure
zone-allocated memory does not outlive its arena.

```skarn
escape_example :: fn() -> []u8 {
    zone local: Arena {
        buf := local.new_slice(u8, 100);
        
        // COMPILER ERROR: zone-owned value cannot be returned
        return buf; 
    }
}
```

**Ownership Rules:**
1. **Assignment propagation**: Storing a zone-owned value into a variable makes that variable zone-owned.
2. **No Escape**: Zone-owned values cannot escape to outer scopes or be returned from functions.
3. **Restricted Passing**: Zone-owned values can only be passed as arguments to function parameters explicitly marked with `borrow`.
4. **Valid Freeing**: You can only `free` a value using the zone handle that owns it.

## Borrow Parameters

If you want to pass zone-allocated memory to a function, the function must declare
that it is borrowing the memory using the `borrow` keyword.

```skarn
// The `borrow` keyword tells the compiler this slice is temporary
// and will not be stored or escape.
process_data :: fn(data: borrow []u8) {
    data[0] = 255u8;
}

main :: fn() {
    zone scratch: Arena {
        buf := scratch.new_slice(u8, 1024);
        
        // Allowed: passing zone memory to a borrow parameter
        process_data(buf);
    }
}
```

**Borrowing Rules:**
1. `borrow` is only valid as the **outermost** qualifier of a function parameter (e.g., `borrow *T` or `borrow []T`).
2. You cannot nest `borrow` qualifiers (e.g., `borrow borrow *T` is invalid).
3. `borrow` is **not valid** on return types, local variables, struct fields, or const declarations.
4. Borrowed values **cannot be stored** into aggregates (structs/arrays) or through pointers.
5. Borrowed values cannot be explicitly freed.
6. A borrowed value is transparent to type-checking inside the function — you interact with it just like a normal pointer or slice.

## Example: Building a Temporary String

Zones are highly effective for temporary processing where you'd normally use a GC or manually manage malloc/free:

```skarn
#import std.io.{ println };

format_and_print :: fn() {
    zone temp: Arena {
        // Allocate buffer for a string
        buf := temp.new_slice(u8, 128);
        
        // Fill it with data (assuming a hypothetical format_into function)
        // length := format_into(borrow buf, "Hello {}!", 42);
        
        // Process the result
        // println(buf[0..length]);
    } // Buffer is instantly freed here
}
```
