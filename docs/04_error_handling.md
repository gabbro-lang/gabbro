# Error Handling

Skarn uses an explicit error-handling model inspired by Zig and Rust. Functions
that can fail declare it in their signature, and callers must always handle
the possibility of failure — there are no hidden exceptions.

## Error Types

Error types are declared with the `errors` keyword. Each variant is a named
error condition, optionally carrying a payload:

```skarn
IoError :: errors {
    not_found,
    permission_denied,
    timeout,
}

ParseError :: errors {
    invalid_input,
    overflow: i64,         // error with payload
    buffer_full,
}
```

Error variants are referenced with a dot prefix: `.not_found`, `.overflow`, etc.

## Fallible Functions

A function that can fail annotates its return type with `!` followed by the
error type:

```skarn
// Named error type
read_file :: fn(path: []const u8) -> []u8 ! IoError {
    // ...
    if path.len == 0 { fail .not_found; }
    // ...
}

// Inline error set (declared right in the signature)
parse :: fn(s: []const u8) -> i32 ! { invalid, overflow } {
    // ...
}

// Inferred error type (bare `!`)
combine :: fn() -> i32 ! {
    // ...
}
```

The return type of a fallible function is internally a *fallible type*
`T ! E` — a tagged union of the success value (`T`) and the error (`E`).

## The `fail` Statement

Use `fail` to return an error from a fallible function:

```skarn
validate :: fn(input: []const u8) -> bool ! ParseError {
    if input.len == 0 {
        fail .invalid_input;
    }
    if input.len > 1000 {
        fail .overflow { input.len as i64 };  // with payload
    }
    return true;
}
```

`fail .variant` is only allowed inside functions with a `!` error return type.
The variant must exist in the function's declared error type, and any payload
must match the variant's declared payload type.

## Error Propagation with `?`

The `?` operator propagates errors upward to the caller, similar to Rust's `?`
or Zig's `try`:

```skarn
outer :: fn() -> i32 ! IoError {
    data := read_file("config.txt")?;   // on error, immediately returns the error
    return process(data)?;
}
```

`?` is only valid inside a function whose error type is compatible with the
expression's error type. If the expression succeeds, `?` unwraps and yields
the success value.

### Chaining `?`

```skarn
pub writer_append :: fn(self: *Byte_Writer, values: []const u8) -> usize ! String_Error {
    i := 0usize;
    while i < values.len {
        self.writer_put(values[i])?;   // propagate on error
        i += 1usize;
    }
    return values.len;
}
```

### Tail-forwarding a fallible result

When a function's whole job is to delegate to another fallible function with a
compatible error type, `return inner();` forwards the entire `{ok, err}` result —
no `?` needed. On success it returns the ok value; on failure the error flows out
unchanged:

```skarn
connect :: fn(sa: SocketAddr) -> TcpStream ! NetError {
    return tcp::connect(sa);     // forwards ok or error, both
}
```

This is the value-returning twin of `?`: `?` *unwraps* (yielding the ok value to
the current function), while a tail-`return` *passes the result through*.

### Qualified error types

A `!` error type may be qualified with the module it comes from, just like any
other type:

```skarn
#import std.heap as heap;
build :: fn(into: *heap::Arena, n: usize) -> []u8 ! heap::MemError {
    return into.try_alloc_bytes(n);
}
```

## Catching Errors with `catch`

Use `catch` to handle an error locally instead of propagating it:

```skarn
result := parse("42") catch err {
    // `err` is bound to the error value
    println("parse failed");
    return -1;
};
// `result` holds the success value
```

The `catch` block receives the error value bound to the name you provide.
The block must either return a value compatible with the success type, or
diverge (e.g., `return`, `fail`, `break`).

### Inspecting the error variant

```skarn
result := parse_json_string(input, output) catch err {
    if err == .buffer_full { return 30; }
    if err == .unexpected_end { return 31; }
    if err == .invalid_escape { return 32; }
    if err == .invalid_unicode { return 33; }
    return 35;
};
```

## Force Unwrap with `!!`

The `!!` operator unwraps a fallible (or optional) value, panicking at runtime
if it contains an error (or null):

```skarn
// Panics with a runtime error if parse() fails
value := parse("42")!!;

// Panics if the optional is null
ptr := maybe_ptr!!;
```

Use `!!` sparingly — it is a convenience for cases where failure is truly
unexpected and should abort the program.

## Nil Coalesce with `??`

The `??` operator provides a default value when the left side is an error or
null:

```skarn
// Returns 0 if parse fails
value := parse("?") ?? 0;

// Returns a default for optionals too
name := get_name() ?? "unknown";
```

## Defer Modes

Skarn supports conditional defers that run only on success or failure:

```skarn
process :: fn() -> void ! IoError {
    handle := open_file("data.txt")?;

    // Always runs (success or failure)
    defer close(handle);

    // Only on successful return
    defer.ok {
        commit();
    }

    // Only on error path (fail or ?)
    defer.err {
        rollback();
    }

    write(handle, data)?;
}
```

| Defer Mode | Syntax | When it runs |
|------------|--------|--------------|
| Always | `defer { ... }` | On any scope exit |
| Success only | `defer.ok { ... }` | Only on normal return |
| Error only | `defer.err { ... }` | Only on `fail` or `?` propagation |

Multiple defers execute in reverse order (LIFO), just like Go and Zig.

## Pattern: Fallible Function with Cleanup

A common pattern in Skarn combines `defer`, `fail`, and `?`:

```skarn
process_file :: fn(path: []const u8) -> usize ! IoError {
    file := open(path)?;
    defer close(file);

    buf: [1024]u8 = .{};
    n := file.read(buf[:])?;
    return n;
}

main :: fn() -> i32 {
    result := process_file("data.txt") catch err {
        if err == .not_found {
            eprintln("file not found");
        }
        return 1;
    };
    print_u64(result as u64);
    return 0;
}
```

## Fallible Entry Points

`main` can itself be a fallible function:

```skarn
main :: fn() -> i32 ! IoError {
    println("hello")?;
    return 0;
}
```

The runtime handles top-level error propagation by aborting with the error
message.

## Summary Table

| Syntax | Meaning |
|--------|---------|
| `-> T ! E` | Function returns `T` on success, `E` on error |
| `fail .variant` | Return an error |
| `fail .variant { payload }` | Return an error with payload |
| `expr?` | Propagate error, unwrap success |
| `expr catch err { ... }` | Handle error locally |
| `expr!!` | Force unwrap (panic on error) |
| `expr ?? default` | Use default on error |
| `defer { ... }` | Always-run cleanup |
| `defer.ok { ... }` | Cleanup on success only |
| `defer.err { ... }` | Cleanup on error only |
