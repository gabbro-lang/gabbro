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

Comptime code can call host DLLs, given the capability (below): `src/vm/ffi.zig` does
`LoadLibraryA`/`GetProcAddress` and marshals `Value` against the C ABI. `gabbro build`
is the same machinery — `build.gab` runs in the VM, lowering builder calls to
`__build_*` intrinsics that produce the build plan. See
[10_build_system.md](10_build_system.md).

## Capabilities

Host FFI needs the `ffi` capability. A bare `#run` has none — it's pure, and a call
into a host function halts the build:

    comptime FFI to `MulDiv` (in `kernel32`) is not allowed here: this ran as a
    pure `#run`, which has no `ffi` capability.

`build.gab` runs with `ffi` granted; it's the script you wrote, the trusted root. The
two primitives the comptime heap reserves pages through, `VirtualAlloc` and
`VirtualFree`, stay open to everyone — they hand back memory and nothing else.

The point is the supply chain. A dependency's compile-time code — a `#run`, a
`#compiler` hook — can't reach the host unless it was handed the capability to. That
shuts the `build.rs` hole: pulling in a package can't read your keys or spawn a
process while you compile. `unsafe` is the next effect to gate; granular caps
(`fs`, `net`) arrive with the package manager that gives them something to guard.
Code: `Vm.caps` in `src/vm/engine.zig`, checked at the FFI opcode.

## Caching

Purity pays off here. A pure `#run` is a deterministic function of its bytecode, so
its result is content-addressable: hash the thunk plus its call closure, name a file
by that hash, skip the run when the file already exists. `GABBRO_CACHE=1` turns it on
(opt-in while it's young).

    grind(5_000_000) at comptime:  ~600 ms cold  →  ~6 ms warm

The key covers the thunk's bytecode, every function it transitively calls, their
constant pools, and a format/host salt. Change any of it — the input, a helper three
calls down, a single literal — and the key moves and the value recomputes. A stale
read isn't possible, because whatever changed is part of the key.

When the closure can't be pinned from bytecode alone — it reaches FFI, a global, an
indirect call, a print — there's no key and the `#run` just runs. Slice 1 stores
scalar results; aggregates (tables, structs) wait on `Value` serialization. Entries
live under `.gabbro-cache/`. Code: `src/vm/run_cache.zig`.

## Limits

`#quote` reflects range/string/guard/binding match patterns as the catch-all
`anything`. Quoting still works; reflecting on those specific patterns is lossy.
