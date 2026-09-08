# Roadmap

Where Gabbro is headed. For component-by-component status see the table in
[README.md](README.md#project-status); for the design of any single subsystem see the
chapter it links to in [`docs/`](docs/).

This file tracks what is *not* done. Everything else is in the docs.

---

## Where it stands

Gabbro compiles end-to-end on two targets. Windows x86-64 is the original host: parse →
check → IR → LLVM → object → executable, linked by `gabld` without spawning LLD.
`x86_64-linux-none` (static) cross-compiles from Windows and has a complete standard
library — all 25 modules, backed by 103 runtime functions in
[`src/runtime/linux.gab`](src/runtime/linux.gab) covering file I/O, time, process
control, sockets and threads. `x86_64-linux-gnu` is implemented behind
`--target linux-gnu` + `--sysroot`.

The comptime VM runs the same IR the native backend lowers, and a bare `#run` is now
capability-pure: it cannot reach host DLLs unless granted. `build.gab` is the
privileged root.

---

## Toward v0.1.0

The first tagged, announced, public build. None of this is language work.

| Item | State |
| --- | --- |
| Version number | `0.1.0` in `build.zig.zon` |
| Git tags | none exist |
| `CHANGELOG.md` | written |
| Tagged GitHub release + prebuilt Windows binaries | blocked: `release.yml` needs the repo variable `LLVM_AVAILABLE=true` and the secret `LLVM_URL`, neither of which is set. Packaging locally needs a full LLVM install with the LLVM-C headers; the usual Windows LLVM builds ship only `Remarks.h` and `lto.h`. |
| Repository description + topics | the repo is public but has neither |
| Build-from-source path | Zig + LLVM, needs a clean pass and an examples sweep |

---

## After v0.1.0

### Capabilities and packages

The single thread with the most leverage, because everything else in this section is
ordinary toolchain work and this is not.

Slice 1 closed the comptime side of the `build.rs` supply-chain hole: a dependency's
compile-time code physically cannot reach the host unless the capability was granted.
What remains is the rest of the system.

- The `*Caps` sandbox surface in `build.gab`, so a build script declares what it needs.
- The VM capability table — capabilities beyond `ffi` (filesystem, network, environment,
  process spawn), each gated at its call site.
- The capability-bounded, content-hashed package manager designed in
  [`docs/16`](docs/16_packages.md). A dependency's build hook receives only what it was
  granted. This is the payoff the first two slices exist for.

### Tooling

None of these exist as subcommands today; `gabbro help` lists what does.

- `gabbro test` — the runtime test lane. Per-test zones with leak checks, TTY/TAP/JSON
  reporters. The `#test` comptime lane already fails the build on a failed assertion;
  this is the other half. See [`docs/17`](docs/17_testing.md) §5.
- Reflection-driven structural diffs on assertion failure, which also unlocks struct
  equality.
- Property testing and snapshots.
- `gabbro fmt` — canonical formatter.
- `gabbro doc` — reflection-driven documentation generation.
- `gabbro repl`.
- LSP v2/v3 — rename, semantic tokens, code actions. v1 (diagnostics, completion, hover,
  go-to-definition, document symbols) ships behind `gabbro lsp`.

### Build system

From the table in [`docs/10`](docs/10_build_system.md). Layer 1 and the plan executor
are done.

- Dependency/step DAG with topological order and parallel execution.
- Content hashing, incremental builds, `--watch`.
- `add_quote` typed codegen, `#provided`, `define` injection — extends `#quote`/`#insert`.
- Layer 2 (`workspace`/`Options`) and Layer 3 (intercept) surfaces.
- Cross-compile target selection from `build.gab`.

### Targets

Current tiers are in [`docs/18`](docs/18_targets_and_tiers.md).

| Target | Now | Needs |
| --- | --- | --- |
| `aarch64-linux` | 3 | aarch64 runtime arm + ABI; the clearest next target |
| `riscv64-linux` | 3 | LLVM-ready; runtime/seam unwritten |
| `wasm32-wasi` | 3 | LLVM-ready; runtime/seam unwritten |
| `*-macos` | 3 | Mach-O + Apple ABI; the large one |

An ELF `gabld` is explicitly a much later item. LLD stays the correctness path on Linux.

### Language reach

- Static interface conformance constraints.
- Interface composition, owned dynamic objects, downcasting.
- SIMD.
- Contracts — `#require` / `#ensure`.
- Attributes that need infrastructure first: `#when(cond)`, `#bench`, `#on_start` /
  `#on_exit`.

### Metaprogramming

- More `ast.*` node kinds.
- Building `ast.*` values without `#quote`.
- Bare-call macros and typed macro parameters.
- An auto-generated `std.ast`.
- Scoping user-written generators to a pure subset, so a `#compiler` hook is not a
  proc-macro with ambient power ([`docs/13`](docs/13_metaprogramming.md)).
- Recursing into nested fields for the derives other than `format`.

---

## Known gaps

Accepted constructs whose backend semantics are incomplete, or shapes the compiler
rejects on purpose. Each needs a fix-or-document decision before v0.1.0.

- **`==` on non-scalar enum payloads** — comparing two enum values whose variant carries
  a struct, string or array payload is a clear error; use `match`. Scalar payloads,
  `.variant` comparison, and every other `==` work.
- **Struct/aggregate equality** is not lowered ([`src/ast_prelude.zig`](src/ast_prelude.zig)).
  Reflection-driven structural diffs would unlock it.
- **Aggregate top-level constants** — a `#run` producing a struct, slice or enum cannot
  become a top-level constant ([`src/ir.zig`](src/ir.zig)).
- **Returning a capturing closure** needs an `*Arena` parameter, because the captured
  environment must outlive the function. Lambdas otherwise capture freely.
- **`#quote` pattern fidelity** — range, string, guard and binding match patterns reflect
  as the catch-all `anything`. Quoting works; reflecting on those patterns is lossy.
  This is the only `TODO` in the compiler ([`src/ir.zig`](src/ir.zig)).
- **Overload resolution** — a rejected instantiation is not yet an error
  ([`docs/12`](docs/12_reflection_and_constraints.md)).
- **`bindgen` v1** maps the common scalar/pointer/struct/enum/array shapes; the rest is
  unhandled ([`src/bindgen.zig`](src/bindgen.zig)).
- **No external packages** — projects are single-tree until the package manager lands.

---

## Open decisions

Neither has been answered. Both affect the language surface, so they should be settled
before v0.1.0 rather than after.

| Decision | Question |
| --- | --- |
| Debug safety | Which checks are mandatory, and which may `unsafe` disable? |
| Error ABI across FFI | How does a fallible return cross the C boundary? |
