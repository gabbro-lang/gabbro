# Skarn

An experimental systems language. No GC, no hidden allocations, manual memory through
lexical arenas. It carries its own toolchain — including a PE/COFF linker written in
Skarn itself — so a release is a single `skarn.exe`.

Experimental, not production-ready. The frontend, type system, LLVM backend, comptime
VM, and metaprogramming all work and run under a ~380-test suite, but the language is
still moving, and some accepted constructs have incomplete backend semantics. The
mature options in this space are Zig, Jai, and Rust; Skarn is a younger, narrower take.

```skarn
#import std.io.{ println };

main :: fn() -> i32 {
    println("hello from Skarn");
    return 0;
}
```

## Memory: zones, not a GC

Allocation goes through lexical `Arena` zones. A zone frees when its block exits.
Deterministic, no collector, no per-object free.

```skarn
work :: fn() {
    zone scratch: Arena {
        buf := scratch.new_slice(u8, 64);   // zero-initialized
        fill(buf);
        // the whole arena is freed here
    }
}
```

Zone-owned values can't outlive their zone — the compiler enforces it. `borrow`
parameters may take a zone-owned value but can't store, return, or forward it.
`defer`/`return`/`fail`/`break`/`continue` all trigger cleanup. The same model runs at
compile time, which is what keeps code-generation memory bounded.

## Errors are values

A fallible function returns `T ! E`. `?` propagates, `catch` handles, `fail` raises.
An error is a small integer tag, not a stack unwind.

```skarn
read_config :: fn(path: []const u8) -> Config ! IoError {
    file := open(path)?;
    if file.empty() { fail .empty; }
    return parse(file);
}

cfg := read_config("skarn.toml") catch e { return default_config(); };
```

## The toolchain is its own

Most of the size of a systems toolchain is the linker and the build glue. Skarn owns
both.

**A native linker, written in Skarn.** `skarnld` (`linker/skarnld.sk`) is a full
single-object PE/COFF linker — section merge at the right alignment, REL32/ADDR64
relocations, multi-DLL import tables, `.pdata`/`.xdata` + the exception directory,
PE32+ output with the subsystem/entry/stack you asked for, and DLL output. It links
itself. The release bakes it into `skarn.exe`, so the compiler links without spawning
a 65 MB LLD. LLD is the fallback for the hard cases (multi-object, raw linker flags, a
static-CRT pull-in).

It's fast because it skips LLD's largest cost: it never parses `.lib` import archives.
The compiler already knows every `#extern("dll","sym")` import and emits a `.skimp`
section; skarnld reads that and writes the import descriptors directly.

**The build system is Skarn.** `build.sk` runs inside the compiler's comptime VM. No
Makefile, no second language. It populates a build plan; the compiler executes it.

```skarn
build :: fn(b: *Build) {
    exe := b.executable("hello", "src/main.sk");
    b.default(exe);
}
```

## Compile-time execution

`#run` evaluates an expression at compile time — recursion, loops, structs, slices,
enums, errors, interface dispatch — and folds it to a constant. It runs on a bytecode
VM over the same IR the native backend lowers, so comptime and runtime share semantics.

```skarn
FIB_10 :: #run fib(10);               // 55, computed at build time
TABLE  :: #run generate_srgb_table(); // baked into the binary
```

Metaprogramming sits on top. `#quote` captures code as a typed AST value, `#insert`
splices it back and re-type-checks the result, `macro` is a hygienic template, `#for`
unrolls. The AST is an ordinary tagged union, so a metaprogram can `match` on code as
data. No string pasting, no separate macro language.

```skarn
twice :: macro(body: Code) -> Code { return #quote { $body; $body; }; }

main :: fn() -> i32 {
    n := 0;
    #insert twice(#quote { n = n + 1; });
    return n;   // 2
}
```

Code-generating helpers run only at compile time; they're not in the shipped binary.

## Interfaces and generics

Dynamic dispatch is explicit, through `*Interface` values. Generics are monomorphized.
Conformance is checked at compile time.

```skarn
Writer :: interface { write :: fn(*Self, []const u8) -> usize ! IoError; }

FileHandle :: struct { fd: i32 }
FileHandle as Writer {
    write :: fn(self: *FileHandle, data: []const u8) -> usize ! IoError {
        return sys_write(self.fd, data);
    }
}

w: *Writer = &file;   // conformance checked at compile time; dispatch via vtable
```

Plus distinct/newtype and opaque types, packed structs with sub-byte fields, integers
`i8`–`i128` / `u1`–`u128`, `f32`/`f64`, and debug-mode traps for overflow,
divide-by-zero, bad shifts, out-of-bounds indexing, null deref, and invalid optional
unwraps.

## Building

The frontend builds and tests without LLVM:

```powershell
zig build
zig build test
```

Object files and Windows executables need an LLVM install:

```powershell
zig build -Dllvm-path=/path/to/llvm
zig build test -Dllvm-path=/path/to/llvm
```

The stdlib root defaults to the in-tree `lib/` (which holds `std/`); override with
`-Dstdlib-root=/path/to/dir-containing-std`.

```text
skarn check  <file>    parse and type-check
skarn ir     <file>    print Skarn IR
skarn object <file>    emit an object file
skarn build  <file>    build an executable (Windows)
```

Worked programs live in [`examples/`](examples/) — among them a Brainfuck interpreter,
an ECS game, and `diskscan`, a WinDirStat-style disk analyzer with a Win32 GUI and
threads.

## Standard library

In the in-tree [`lib/std/`](lib/std/) directory.

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
| `std.math` | `Vec2`/`Vec3`/`Rect` and scalar math (no libm). |
| `std.rand` | Pseudo-random number generation. |
| `std.color` | Color types and conversions. |
| `std.bits` | popcount, clz/ctz, rotate, power-of-two test (u32/u64). |
| `std.ptr` | Pointer/address conversions and alignment arithmetic. |
| `std.path` | Path manipulation. |
| `std.time` | Clocks and timestamps (kernel32). |
| `std.crypto` | `crc32`, FNV, SHA-256. |
| `std.serde` | Reflection-driven JSON serialize/deserialize — no per-type code. |
| `std.net` | TCP + UDP over Winsock, layered (`os`/`socket`/`tcp`/`udp`). |
| `std.atomics` | Atomic load/store/swap/`compare_exchange`/fetch-ops; `Atomic(T)` cell. |
| `std.thread` | OS thread `spawn`/`join`. |
| `std.fs` | `File` implementing `Reader` + `Writer`; `open`/`create`/`append`/`delete`/`exists`. |
| `std.process` | PID, command line, env vars, child spawn/wait/kill. |
| `std.c` | C ABI types for `#extern` FFI. |
| `std.build` | The `build.sk` API — runs in the comptime VM. |

## Project status

Skarn works end-to-end on Windows: parse → check → IR → LLVM → executable. The
frontend is platform-independent.

| Area | Status |
| --- | --- |
| Lexer, parser, AST, diagnostics | done |
| Semantic analysis + typed IR (const-fold, branch, DCE) | done |
| LLVM object/executable generation | Windows end-to-end; Linux/macOS incomplete |
| Structs, packed structs, enums (payloads + `match`) | done |
| Integers `i8`–`i128`/`u1`–`u128`, floats `f32`/`f64` | done |
| Pointers, arrays, slices, optionals (with debug checks) | done |
| Casts, distinct/newtype, opaque types | done |
| Functions, monomorphized generics, control flow, `match` | done |
| Errors / fallible functions (`T!E`, `fail`, `?`, `catch`) | done |
| Zones (`Arena`, non-escape checking, deterministic cleanup) | done |
| Comptime VM (`#run`, `#if`, reflection, full data types) | done |
| Metaprogramming (`#quote`, `#insert`, `macro`, `#for`, generative `#insert #run`) | done; node-kind coverage still growing |
| Modules, imports, `::` namespacing, visibility, UFCS | done; no external packages yet |
| Generics: `$T:` constraints, `where {}` predicates, named constraints | done |
| Reflection (`type_info`, `typeid`, `Any`) + reflection-driven serde | done |
| C interop (`#extern`, by-value struct ABI, `skarn bindgen`) | done |
| Build system (`build.sk` in the comptime VM → real exes/DLLs) | done |
| Native linker (`skarnld`, single-object PE/COFF, self-hosting) | done |
| Interfaces (dynamic + interface-through-interface dispatch, `$T: Iface` bounds) | done |
| Standard library (25 modules) | done |
| Atomics + concurrency | done |
| Testing | `#test` comptime lane (a failed assertion fails the build); runtime lane planned |
| Tooling | `check`/`ir`/`object`/`build`, `skarn lsp`, tree-sitter grammar + Zed extension, `skarn bindgen`. No formatter, doc gen, REPL, or package manager yet |
| Platform | Windows x86-64. A Linux x86-64 ELF backend cross-compiles and runs compute/CLI programs; some OS modules aren't ported yet |

See [`docs/`](docs/) for the language reference.

## Contributing

Skarn is early and the design is still open. New features should come with parser,
semantic, IR, and (where it applies) LLVM tests; safety work should include an
executable test that proves the debug trap fires. The compiler is Zig — start with
[`docs/00_overview.md`](docs/00_overview.md) and the `src/` tree.

## License

Dual-licensed by component:

- **The compiler** (`src/`) — [GNU GPL v3](LICENSE-GPLv3.txt).
- **The runtime, standard library, compiler-injected preludes, and code the compiler
  generates into your program** (`lib/`, `src/runtime/`, `#derive`/serde/test output) —
  [Apache 2.0](LICENSE-APACHE-2.0.txt).

Programs you compile with Skarn are not GPL-encumbered — they contain your own code
plus the Apache-2.0 runtime and standard library, so license and ship them as you wish.
See [LICENSING.md](LICENSING.md) for the file-by-file boundary (also in the
`SPDX-License-Identifier` headers).
