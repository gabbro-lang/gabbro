# Skarn

**A systems language where metaprogramming is a first-class, typed, and sandboxable layer — not a string-pasting afterthought.**

Skarn is an experimental, explicit systems programming language with manual memory
management, no hidden allocations, and no garbage collector. Its distinguishing
feature is a compile-time **bytecode VM that executes the compiler's own IR**:
your compile-time code runs with exactly the same semantics as your runtime code,
can build and inspect the program's own syntax tree as ordinary typed data, and
generate new code that is type-checked like anything you wrote by hand.

> **Status: experimental.** Skarn is not production-ready. The frontend, type system,
> LLVM backend, and the comptime/metaprogramming engine all work and are covered
> by a 200+ test suite, but the language is still moving and some accepted
> constructs have incomplete backend semantics. See [Project status](#project-status).

```skarn
// Compute a lookup table at compile time and bake it into the binary.
fib :: fn(n: i32) -> i32 { if n < 2 { return n; } return fib(n-1) + fib(n-2); }
FIB_10 :: #run fib(10);          // = 55, computed by the comptime VM

// Generate code at compile time and splice it in — type-checked like hand-written code.
unroll_sum :: fn() -> AstBlock {
    return #quote {
        total = total + 1;
        total = total + 2;
        total = total + 3;
    };
}

main :: fn() -> i32 {
    total := 0;
    #insert #run unroll_sum();   // the three statements are generated, then compiled
    return total;                // → 6
}
```

---

## Why Skarn

- **Compile-time ≡ runtime.** One IR, one VM. Code you run at compile time behaves
  exactly like code you ship — no separate, subtly-different comptime dialect.
- **The AST is just data.** `ast.Expr` / `ast.Stmt` / `ast.Block` are ordinary Skarn
  tagged unions. You build them with `#quote`, take them apart with `match`, and
  splice them with `#insert`. No string concatenation, no separate macro language.
- **Hygienic by default.** Names introduced inside a quotation are fresh; the only
  bridge to the surrounding scope is an explicit `$` splice. Macros don't
  accidentally capture your variables.
- **No hidden costs.** No hidden allocations, no implicit copies, dynamic dispatch
  only through explicit `*Interface` values, monomorphized generics.
- **Zones instead of a GC.** Lexical `Arena` zones give deterministic, leak-free
  allocation with compiler-enforced non-escape — and the same model runs at
  compile time, so heavy code generation has a bounded, microscopic memory
  footprint.
- **Errors are values.** Fallible functions (`-> T ! E`) with `fail`, `?`
  propagation, and `catch` — a real error ABI, not exceptions.
- **Open source.** The whole compiler is here, in Zig, readable and hackable.

---

## Metaprogramming

This is Skarn's reason to exist. Everything below runs on the comptime VM today.

### Run anything at compile time — `#run`, `#if`

```skarn
PI       :: #run compute_pi();           // expensive constant, computed once at build time
TABLE    :: #run generate_srgb_table();  // bake data into the binary
#if TARGET.debug { log("debug build"); } // conditional compilation
```

`#run` evaluates any expression — recursion, loops, structs, slices, enums,
optionals, errors, interface dispatch — and folds it to a constant. `#if` compiles
only the live branch.

### Quote and splice — `#quote`, `#insert`

`#quote { … }` captures code as a typed AST value; `#insert` splices it back in and
re-runs the type checker on the result:

```skarn
#insert #quote {
    logged := now();
    work();
    log(now() - logged);
};
```

### Hygienic macros — `macro` + `$`

A `macro` is a compile-time template over typed AST. Arguments are spliced with
`$`; the macro's own locals are renamed so they can never clash with yours:

```skarn
twice :: macro(body: Code) -> Code {
    return #quote { $body; $body; };
}

main :: fn() -> i32 {
    n := 0;
    #insert twice(#quote { n = n + 1; });   // expands to n=n+1; n=n+1;
    return n;                                // → 2
}
```

### Compile-time loops — `#for`

`#for` unrolls at compile time, baking the index into the generated code — the
classic "generate N statements" pattern, with no runtime loop:

```skarn
init :: fn() -> [4]i32 {
    arr: [4]i32 = .{ 0, 0, 0, 0 };
    #for i in 0..4 {
        arr[$(i)] = $(i) * $(i);   // emits arr[0]=0; arr[1]=1; arr[2]=4; arr[3]=9
    }
    return arr;
}
```

### Generative code — build AST with real logic, then splice it

The AST is first-class data, so a normal compile-time function can *construct* code
using arbitrary control flow and return it. `#insert #run` runs it on the VM,
reifies the result back into the syntax tree, and type-checks the spliced code:

```skarn
// Choose what to generate based on a compile-time condition.
codegen :: fn(fast: bool) -> AstBlock {
    if fast {
        return #quote { result = result * 2; };
    }
    return #quote { result = slow_compute(result); };
}

main :: fn() -> i32 {
    result := 21;
    #insert #run codegen(true);   // generated at build time, compiled into the binary
    return result;                // → 42
}
```

And because the AST is a tagged union, metaprograms can *inspect* code too:

```skarn
describe :: fn(e: AstExpr) -> i64 {
    match e {
        .int |v|    => return v;
        .ident |n|  => return 0;
        .binary |b| => return 1;
        else        => return -1;
    }
}
```

> Code-generating helpers (anything that builds `ast.*` values) run **only** at
> compile time and are excluded from the final binary — so metaprogramming never
> bloats your shipped code.

---

## How Skarn compares

Skarn's niche is **typed, hygienic, sandboxable comptime metaprogramming inside an
explicit, GC-free systems language.** Here's where it sits relative to its
neighbors. (These are deliberately fair: Jai, Zig, and Rust all have more mature
ecosystems and more complete feature sets today.)

| | **Skarn** | **Jai** | **Odin** | **Zig** | **Rust** |
| --- | --- | --- | --- | --- | --- |
| Arbitrary compile-time execution | yes (IR VM) | yes (bytecode) | no | yes (interpreter) | limited (`const fn`) |
| Comptime ≡ runtime semantics | yes (shared IR) | yes | — | mostly | partial |
| Code generation model | **typed AST** (`#quote`) | strings (`#insert`) | — | comptime types/values | token streams (proc macros) |
| Inspect program AST as data | yes (`match` on `ast.*`) | yes (AST API) | no | no | yes (token/`syn`) |
| Macro hygiene | yes, by default | no (textual) | n/a | n/a | yes (declarative) |
| Memory model | lexical zones, no GC | manual + temp allocator | manual + context allocator | manual + allocators | ownership/borrow |
| Zero-leak comptime memory | yes (zones free on exit) | partial | — | grows during build | grows during build |
| Metaprogramming runs as… | **sandboxable VM** (designed) | host bytecode | — | host interpreter | **host code** (proc macro / `build.rs`) |
| Open source | yes | no | yes | yes | yes |

**Versus Jai** — the closest in spirit. Skarn's quotations are *typed AST*, not
strings, and *hygienic* by default. Jai's metaprogramming is more complete today
(message loop, full AST mutation), but it's closed-source and string-based, and
its `#insert` can silently capture surrounding names.

**Versus Zig** — Zig's comptime is excellent for types-as-values and generic
programming, but it has no notion of the *syntax tree as data*: you can't quote,
inspect, or splice statements. Skarn adds that AST-quotation/injection layer on top
of a comparable comptime engine, and frees comptime memory as zones exit.

**Versus Odin** — Odin deliberately keeps metaprogramming minimal (`when`,
`#load`, parametric polymorphism) with no arbitrary compile-time execution. Skarn
goes the other direction: a full comptime VM and AST metaprogramming.

**Versus Rust** — Rust's proc macros are powerful but run as *opaque host code* at
build time over token streams (the same trust surface as `build.rs`). Skarn's
metaprogramming runs in a VM that is designed to be **capability-sandboxed**, so a
dependency's compile-time code can be denied access to your filesystem and OS — a
structural answer to the supply-chain problem. (The sandbox is on the roadmap; the
VM it builds on is here today.)

---

## The rest of the language

### Memory: zones, not a garbage collector

```skarn
work :: fn() {
    zone scratch: Arena {
        buf := scratch.new_slice(u8, 64);   // zero-initialized
        fill(buf);
        // the whole arena is freed here — deterministically
    }
}
```

Zone-owned values cannot outlive their zone (the compiler enforces it). `borrow`
parameters may temporarily receive zone-owned values but cannot store, return, or
forward them. `defer`, `return`, `fail`, `break`, and `continue` all trigger
cleanup. The same zone model runs at compile time, which is what makes
code-generation memory bounded.

### Errors as fallible functions

```skarn
read_config :: fn(path: []const u8) -> Config ! IoError {
    file := open(path)?;            // ? propagates the error to the caller
    if file.empty() { fail .empty; }
    return parse(file);
}

cfg := read_config("skarn.toml") catch e {
    return default_config();        // recover from any error
};
```

### Interfaces — explicit dynamic dispatch

```skarn
Writer :: interface {
    write :: fn(*Self, []const u8) -> usize ! IoError;
}

FileHandle :: struct { fd: i32 }
FileHandle as Writer {
    write :: fn(self: *FileHandle, data: []const u8) -> usize ! IoError {
        return sys_write(self.fd, data);
    }
}

w: *Writer = &file;   // conformance checked at compile time; dispatch via vtable
```

Plus monomorphized generics, distinct/newtype and opaque types, packed structs
with sub-byte fields, integer types `i8`–`i128` / `u1`–`u128`, `f32`/`f64`, and
debug-mode traps for overflow, division by zero, bad shifts, out-of-bounds
indexing, null dereference, and invalid optional unwraps.

---

## Building

The frontend builds and tests **without** LLVM:

```powershell
zig build
zig build test
```

LLVM code generation (object files and Windows executables) needs an LLVM
installation:

```powershell
zig build -Dllvm-path=/path/to/llvm
zig build test -Dllvm-path=/path/to/llvm
```

The standard-library root defaults to the in-tree `lib/` directory (which contains
`std/`); override with `-Dstdlib-root=/path/to/dir-containing-std`.

Compiler commands:

```text
skarn check  <file>    Parse and type-check
skarn ir     <file>    Print Skarn IR
skarn object <file>    Emit an object file
skarn build  <file>    Build an executable (Windows)
```

A larger real-world example lives in [`skarnson/`](skarnson/) — a JSON serializer written
in Skarn itself, using interfaces, fallible functions, zones, and several stdlib
modules.

---

## Standard library

The stdlib lives in the in-tree [`lib/std/`](lib/std/) directory.

| Module | Provides |
| --- | --- |
| `std.io` | `Writer`/`Reader` interfaces; `Stdout`, `Stderr`, `FixedBuf`; numeric formatters; `print`/`println`. |
| `std.fmt` | Width-justified output, padding, integer columns, joined slices. |
| `std.mem` | Typed-slice helpers: `eql`, `copy`, `fill`, `index_of`, `contains`; byte search. |
| `std.strings` | Arena-backed growable `StringBuilder` + byte utilities. |
| `std.slice` | Higher-order helpers: `map`, `filter`, `any`, `all`, `find`/`rfind`. |
| `std.vec` | Growable `Vec(T)` and `VecUnmanaged(T)` (region-bound). |
| `std.map` | `AutoHashMap` (byte-hash any key) and `StrMap` (content-keyed). |
| `std.list` | Linked-list container. |
| `std.heap` | Bump-allocating `Arena` (the backing for `zone … : Arena`). |
| `std.math` | `Vec2`/`Vec3`/`Rect` and scalar math (no libm dependency). |
| `std.rand` | Pseudo-random number generation. |
| `std.color` | Color types and conversions. |
| `std.bits` | Bit-twiddling for u32/u64: popcount, clz/ctz, rotate, power-of-two test. |
| `std.ptr` | Pointer/address conversions and alignment arithmetic. |
| `std.path` | Path manipulation. |
| `std.time` | Clocks and timestamps (kernel32). |
| `std.crypto` | `crc32`, FNV, SHA-256. |
| `std.serde` | Reflection-driven JSON serialize/deserialize — no per-type code. |
| `std.net` | TCP + UDP over Winsock, layered (`os`/`socket`/`tcp`/`udp`). |
| `std.atomics` | Atomic load/store/swap/`compare_exchange`/fetch-ops; `Atomic(T)` cell. |
| `std.thread` | OS thread `spawn`/`join`. |
| `std.fs` | `File` implementing `Reader` + `Writer`; `open`, `create`, `append`, `delete`, `exists` (Windows). |
| `std.process` | PID, command line, env vars, child spawn/wait/kill (Windows). |
| `std.c` | C ABI types for `#extern` FFI. |
| `std.build` | The `build.sk` API (executables, libraries, steps) — runs in the comptime VM. |

---

## Project status

Skarn works end-to-end on Windows (parse → check → IR → LLVM → executable) and the
frontend is platform-independent. What's solid, partial, and missing:

| Area | Status |
| --- | --- |
| Lexer, parser, AST, diagnostics | Implemented |
| Semantic analysis + typed IR (const-fold, branch, DCE) | Implemented |
| LLVM object/executable generation | Implemented (Windows end-to-end; Linux/macOS incomplete) |
| Structs, packed structs, enums (with payloads + `match`) | Implemented |
| Integers `i8`–`i128`/`u1`–`u128`, floats `f32`/`f64` | Implemented |
| Pointers, arrays, slices, optionals (with debug checks) | Implemented |
| Casts, distinct/newtype, opaque types | Implemented |
| Functions, monomorphized generics, control flow, `match` | Implemented |
| Errors / fallible functions (`T!E`, `fail`, `?`, `catch`) | Implemented |
| Zones (`Arena`, non-escape checking, deterministic cleanup) | Implemented |
| **Comptime VM** (`#run`, `#if`, reflection, full data types) | Implemented |
| **Metaprogramming** (`#quote`, `#insert`, `macro`, `#for`, generative `#insert #run`) | Implemented (node-kind coverage still growing) |
| Modules, imports, `::` namespacing, visibility, UFCS extension methods | Implemented (per-module name mangling; no external packages yet) |
| Generics: monomorphization, `$T:` constraints, `where {}` predicates, named constraints | Implemented |
| Reflection (`type_info`, `typeid`, `Any`) + reflection-driven serde | Implemented |
| C interop (`#extern`, by-value struct ABI, `skarn bindgen` from libclang) | Implemented |
| Build system (`build.sk` run in the comptime VM → real exes/DLLs) | Implemented |
| Interfaces | Implemented — dynamic + interface-through-interface dispatch; conformance bounds via `$T: Iface` or a `where T: Iface` clause (enforced), with the interface's methods callable directly on the bound/implementing type |
| Standard library | Implemented — 25 modules incl. `io`, `fmt`, `mem`, `strings`, `vec`, `map`, `heap`, `serde` (JSON), `net` (TCP/UDP), `atomics`, `thread`, `crypto`, `time`, `fs`, `process`, `build` |
| Atomics + concurrency | Implemented — load/store/swap/`compare_exchange`/fetch-ops, `Atomic(T)`, `std.thread` |
| Testing | Implemented — `#test` comptime lane (a failed assertion fails the build); runtime lane planned |
| Tooling | Implemented — `check`/`ir`/`object`/`build`, `skarn lsp` (language server), tree-sitter grammar + Zed extension, `skarn bindgen`. No formatter, doc generator, REPL, or package manager yet |
| Platform support | Windows x86-64 only (the frontend is platform-independent; Linux/ELF backend is designed but not implemented) |

See [ROADMAP.md](ROADMAP.md) for what's planned and the known blocking bugs, and
[`docs/`](docs/) for the language reference (syntax, types, memory zones,
interfaces, the metaprogramming design).

---

## Contributing

Skarn is early and the design is still open — issues, experiments, and discussion are
all welcome. New features should come with parser, semantic, IR, and (where
applicable) LLVM tests; safety work should include executable tests that verify the
expected debug trap fires. The compiler is written in Zig; start with
[`docs/00_overview.md`](docs/00_overview.md) and the `src/` tree.

## License

Skarn is dual-licensed by component:

- **The compiler** (`src/`) — [GNU GPL v3](LICENSE-GPLv3.txt).
- **The runtime, standard library, compiler-injected preludes, and code the
  compiler generates into your program** (`lib/`, `src/runtime/`, `#derive`/serde/
  test output) — [Apache License 2.0](LICENSE-APACHE-2.0.txt).

**Programs you compile with Skarn are not GPL-encumbered** — they contain only your
own code plus the Apache-2.0 runtime and standard library, so you may license and
ship them however you wish. See [LICENSING.md](LICENSING.md) for the full rationale
and the file-by-file boundary (also recorded in `SPDX-License-Identifier` headers).
