# Skarn Roadmap

Where the language and compiler are headed. For the design of the comptime VM and
metaprogramming layer specifically, see
[`docs/09_comptime_vm_roadmap.md`](docs/09_comptime_vm_roadmap.md); for the
component-by-component status, see the table in [README.md](README.md#project-status).

The near-term goal is the **v0.1.0 release** — the first tagged, announced, public
build. Its tracking checklist lives in the GitHub issues.

---

## Landed

The language is substantial and end-to-end on Windows (parse → check → IR → LLVM →
executable), covered by a 200+ test suite.

**Core language** — structs/packed structs (named-field literals `.{ .x = 1 }`
and default field values), enums with payloads + `match` (exhaustive, ranges,
string/guard patterns, value-producing `match` and `if` expressions), integers
`i8`–`i128`/`u1`–`u128` + floats, pointers/arrays/slices/optionals with debug
checks, casts, distinct/opaque types, monomorphized generics, functions, control
flow, UFCS extension methods (including on temporaries), in-struct methods,
lambdas + iterators. Arithmetic overflow **traps in debug, wraps in release**
(never UB); `+%`/`-%`/`*%` always wrap. Operator precedence is fixed and
locked by tests.

**Errors & memory** — fallible functions (`T ! E`, `fail`, `?`, `catch`, `!!`,
`??`, success/error `defer` modes, tail-forwarding, qualified error types) and
`Arena` zones with compiler-enforced non-escape and deterministic cleanup.

**Comptime & metaprogramming** — a register-based bytecode VM that executes the
compiler's own IR (one lowering for comptime and runtime); `#run`/`#if`;
`#quote`/`#insert` with re-checking and hygiene; template `macro`s with `$`-splice;
`#for` unrolling; `#parse`; the `ast.*` value surface you can `match` on;
`#compiler` hooks + `compiler_decls()` introspection (a Jai-style message loop);
`#derive`.

**Reflection** — `sizeof`, `type_name`, matchable `type_info(T)`, `typeid`, and
`Any`, driving `std.serde` (JSON ser/deser with no per-type code).

**Generics & constraints** — `$T:` constraints, `where { … }` predicates run on
the resolution VM, named `constraint($T){}`, and output type params (`-> $Acc`).

**Modules** — file-as-module, `#import a.b` → `b::member`, `as`/`.*`/`.{x}`,
visibility, per-module name mangling.

**C interop** — `#extern`, the Win64 by-value aggregate ABI, thin C function
pointers, and `skarn bindgen` (libclang → Skarn declarations; full `raylib.h`).

**Backend & build** — the LLVM backend, in-process LLD plus a from-scratch Skarn
linker (`skarnld`), and `skarn build` running `build.sk` entirely in the comptime VM to
produce real executables and DLLs.

**Standard library** — 25 modules: `io`, `fmt`, `mem`, `strings`, `slice`, `vec`,
`map`, `list`, `heap`, `math`, `rand`, `color`, `bits`, `ptr`, `path`, `time`,
`crypto`, `serde`, `net` (TCP/UDP), `atomics`, `thread`, `fs`, `process`, `c`,
`build`.

**Tooling** — `skarn lsp` (diagnostics, completion, hover, go-to-definition, document
symbols), a tree-sitter grammar with highlight queries, a Zed extension, and the
`#test` comptime test lane (a failed assertion fails the build like a type error).

---

## Toward v0.1.0

Release-blocking work and the polish needed for a first public build.

- **Release mechanics** — settle the version number (the repo has stray local
  `v0.1.x` tags and `build.zig.zon` still says `0.0.0`), write a CHANGELOG / release
  notes, and cut a tagged GitHub release with prebuilt Windows binaries.
- **Documentation consistency** — keep the README status, this file, `docs/15`
  (tooling), and `docs/17` (testing) in sync with what actually ships; complete the
  `docs/00` "where to go next" index.
- **Known correctness gaps** — decide fix-or-document for each (see below).
- **Getting started** — a clean build-from-source path (Zig + LLVM), the
  Windows-only caveat stated up front, and a working examples sweep.

## After v0.1.0

- **Testing** — the runtime lane (`skarn test`, per-test zones + leak checks, TTY/TAP/
  JSON reporters), reflection-driven structural diffs on assertion failure (which
  also unlocks struct equality), property testing, and snapshots (`docs/17` §5).
- **More tooling** — `skarn fmt` (canonical formatter), `skarn doc` (reflection-driven
  docs), `skarn repl`, and LSP v2/v3 (rename, semantic tokens, code actions).
- **Linux/ELF backend** — the second target (ELF + SysV ABI), designed in
  `docs/14`; today Skarn is Windows-only.
- **Packages** — the capability-bounded, content-hashed package manager designed in
  `docs/16` — the structural answer to the `build.rs` / supply-chain problem: a
  dependency's build hook receives only the capabilities it was granted.
- **Wider metaprogramming** — more `ast.*` node kinds, building `ast.*` values
  without `#quote`, bare-call macros, typed macro parameters, an auto-generated
  `std.ast`.
- **Language reach** — static interface conformance constraints, interface
  composition / owned dynamic objects / downcasting, SIMD, and contracts
  (`#require`/`#ensure`).
- **Attributes needing infrastructure** — `#when(cond)`, `#bench`,
  `#on_start`/`#on_exit` (see the open attributes issue).

---

- **`==` on non-scalar enum payloads** — comparing two enum values whose variant
  carries a struct/string/array payload is a clear error (use `match`). Scalar
  payloads, `.variant` comparison, and every other `==` (scalars, strings,
  structs, arrays, slices, simple enums) work.
- **Returning a capturing closure** needs an `*Arena` parameter (the captured
  environment must outlive the function) — lambdas otherwise capture freely.
- **Single target** — Windows x86-64 only; no Linux/macOS codegen yet.
- **No external packages** — projects are single-tree until the package manager
  lands.

---

## Open language decisions

| Decision | Question |
| --- | --- |
| Debug safety | Which checks are mandatory vs. disabled inside `unsafe`? |
| Error ABI across FFI | How do fallible returns cross the C boundary? |
| Borrow scope | Should `borrow` expand to fields, returns, or extern contracts? |
| Interface coherence | Conformance/coherence rules for static interface constraints. |
| Mutability | How do `const`, receiver mutability, pointers, and interface coercions interact? |
| Package identity | How are packages named, versioned, and represented in symbols? |
