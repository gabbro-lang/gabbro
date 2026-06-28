# Compile-time execution

`#run` and everything built on it execute on a register bytecode VM (`src/vm/`).
The VM runs the same IR (`src/ir.zig`) the native backend lowers. One lowering, so
comptime and runtime share semantics — they don't drift, because there's no second
implementation to drift from.

Memory is the zone/arena model, at compile time: host-backed bump arenas that free
as zones exit. A `zone` block's memory is gone when the block ends, so comptime RAM
stays bounded instead of growing until the build finishes.

## The surface

- `#run expr` — evaluate at compile time, fold to a constant.
- `#insert <code>` — splice generated code at a site. The subtree is re-resolved and
  type-checked like hand-written code.
- `#quote { … }` / `#quote(expr)` — typed AST quotations (an `ast.Block` / `ast.Expr`
  value, parsed once at the definition site), with `$`-splices.
- `#parse(string)` — parse comptime text into code. The escape hatch.
- Template macros — `name :: macro(p) { return #quote { … }; }`, hygienic, splicing
  through every construct, with `#for` unrolling. See
  [13_metaprogramming.md](13_metaprogramming.md).
- First-class `ast.*` values — build a program in the VM, then `#insert #run gen()`.

Reflection — `type_info(T)`, `typeid_of`, `type_name`, constraints, runtime `Any` —
lives in [12_reflection_and_constraints.md](12_reflection_and_constraints.md).

## #compiler hooks

A `#compiler` function runs at comptime. It reads the program through
`compiler_decls()` — each `Decl` carries its shape: a struct's fields, an enum's
variants, a fn's params and return, and the decl's body source. It returns new
top-level declarations as source, which get spliced and re-checked. A generated
decl whose name matches an existing one replaces it. `compiler_remove(name)` drops
one. `compiler_error("msg")` halts the build with a diagnostic. Bare `#compiler`
runs before typecheck; `#compiler(final)` runs after generation, over the augmented
program.

`#derive`-style codegen is built on this — walk `type_info(T)`, emit the impl.

## Comptime FFI and build

`#run` can call host DLLs: `src/vm/ffi.zig` does `LoadLibraryA`/`GetProcAddress` and
marshals `Value` against the C ABI. `skarn build` is the same machinery — `build.sk`
runs in the VM, lowering builder calls to `__build_*` intrinsics that produce the
build plan. See [10_build_system.md](10_build_system.md).

## Limits

Comptime FFI and `unsafe` are unconditionally available. A compile-time hook from a
dependency can reach the host — there's no capability sandbox on comptime code yet.
Treat build code like code you run, because that's what it is.

`#quote` reflects range/string/guard/binding match patterns as the catch-all
`anything`. Quoting still works; reflecting on those specific patterns is lossy.
