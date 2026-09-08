# Changelog

Notable changes, newest first. Versions follow [SemVer](https://semver.org/): while
the major version is `0`, any minor bump may break source compatibility.

## 0.1.0 — 2026-09-08

First tagged release. Gabbro compiles end-to-end on two targets, ships a standard
library and its own linker, and installs by unzipping.

**The project was previously called Skarn.** The language, the toolchain and the file
extension were all renamed in this release: `skarn` → `gabbro`, `skarnld` → `gabld`,
`.sk` → `.gab`, and the `SKARN_*` environment variables to `GABBRO_*`. The old
repository, `skarn-lang/skarn`, is superseded by `gabbro-lang/gabbro`.

### Language

- Structs, packed structs with sub-byte fields, enums with payloads, and exhaustive
  `match` with range, string and guard patterns.
- Integers `i8`–`i128` and `u1`–`u128`, `f32`/`f64`, pointers, arrays, slices and
  optionals. Arithmetic overflow traps in debug and wraps in release; `+%`/`-%`/`*%`
  always wrap.
- Errors as values: `T ! E`, `?` to propagate, `catch` to handle, `fail` to raise. An
  error is a small integer tag, not a stack unwind.
- Lexical `Arena` zones with compiler-enforced non-escape and deterministic cleanup.
  `borrow` parameters may take a zone-owned value but cannot store or forward it.
- Monomorphized generics with `$T:` constraints, `where {}` predicates and named
  constraints. Interfaces with explicit dynamic dispatch.
- Distinct/newtype and opaque types, UFCS extension methods, lambdas and iterators.
- Debug traps for overflow, divide-by-zero, bad shifts, out-of-bounds indexing, null
  deref and invalid optional unwraps.

### Compile-time execution

- `#run` on a register bytecode VM that executes the same IR the native backend
  lowers, so comptime and runtime cannot drift.
- `#quote`/`#insert` with re-checking and hygiene, template `macro`s with `$`-splices,
  `#for` unrolling, `#parse`, and first-class `ast.*` values you can `match` on.
- `#compiler` hooks with `compiler_decls()` introspection, and `#derive`.
- Reflection: `sizeof`, `type_name`, `type_info(T)`, `typeid` and `Any`, driving
  `std.serde` with no per-type code.
- A bare `#run` is capability-pure: it cannot call host DLLs at compile time. Only
  `build.gab` is granted the `ffi` capability. This closes the comptime side of the
  `build.rs` supply-chain surface.
- Content-addressed caching for pure `#run` results, behind `GABBRO_CACHE`.

### Toolchain

- `gabld`, a single-object PE/COFF linker written in Gabbro that links itself and is
  baked into the release binary. It skips LLD's largest cost by never parsing `.lib`
  import archives: the compiler already knows every import and emits a `.skimp`
  section for the linker to read. LLD remains the fallback for multi-object links,
  raw linker flags and static-CRT pull-in.
- The build system is Gabbro. `build.gab` runs inside the comptime VM; there is no
  second language and no Makefile.
- `gabbro bindgen` generates FFI declarations from a C header via libclang.

### Targets

- `x86_64-windows-msvc` — the original host target, full standard library.
- `x86_64-linux-none` (static) — cross-compiles from Windows, no libc, no crt1.o.
  Full standard library parity with Windows.
- `x86_64-linux-gnu` — behind `--target linux-gnu` with a `--sysroot`.
- No macOS backend.

### Standard library

25 modules: `io`, `fmt`, `mem`, `strings`, `slice`, `vec`, `map`, `list`, `heap`,
`math`, `rand`, `color`, `bits`, `ptr`, `path`, `time`, `crypto`, `serde`, `net`,
`atomics`, `thread`, `fs`, `process`, `c`, `build`.

### Tooling

- `gabbro lsp` with diagnostics, completion, hover, go-to-definition and document
  symbols.
- A tree-sitter grammar with highlight queries, and a Zed extension.
- The `#test` comptime lane: a failed assertion fails the build like a type error.

### Known limitations

Gabbro is experimental. Some accepted constructs still have incomplete backend
semantics. The full list, with file references, is in
[ROADMAP.md](ROADMAP.md#known-gaps); the headlines:

- No runtime test lane, formatter, doc generator, REPL or package manager.
- No external packages; projects are single-tree.
- `==` on enum payloads that are not scalars is rejected; use `match`.
- Struct and aggregate equality is not lowered.
- A `#run` producing a struct, slice or enum cannot become a top-level constant.
- Returning a capturing closure needs an `*Arena` parameter.
- `#quote` reflects range, string, guard and binding match patterns as the catch-all
  `anything`.
