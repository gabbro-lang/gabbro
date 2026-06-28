# Skarn Comptime VM & Metaprogramming — Status & Roadmap

> Status: **Phases 1–4 substantially IMPLEMENTED.** The bytecode VM is the sole
> comptime engine (the tree-walker is deleted), and the metaprogramming surface
> (`#run`/`#insert`/`#quote`/`#parse`/macros/reflection/`#compiler` hooks/comptime
> FFI/comptime zones/`skarn build`) works end-to-end. What remains is the **iterative
> message loop**, a **richer `std.compiler` surface**, and **Phase 5 capability
> sandboxing** — plus the Skarn-unique innovations at the end of this doc.

## Context

Skarn's compile-time execution runs on a **register bytecode VM** (`src/vm/`) that
executes the same **IR** (`src/ir.zig`) the native backend lowers, so **comptime ≡
runtime**: one lowering, identical semantics. The VM faithfully models Skarn's
signature **Zone/Arena** memory at compile time (host arenas that free as zones
exit), giving zero-leak comptime execution. The original tree-walker
(`src/comptime.zig`) has been **deleted**; `#run` routes only through the VM.

The north star is to match and then exceed Jai's metaprogramming, and to close the
`build.rs`/Jai **supply-chain hole** with capability-sandboxed comptime.

## What's implemented

### The VM (Phase 1 — done)
- `src/vm/value.zig` — tagged `Value` union (ints/floats/bool, zone-backed
  ptr/slice/struct/variant, strings, first-class `type` values, fn refs).
- `src/vm/zones.zig` — a `ZoneStack` of host-backed bump arenas; `zone_push/pop`
  allocate/free real memory; allocations carry their `ZoneId`; **unwinding frees
  every zone above a frame's watermark** on `ret`/`fail`. Comptime RAM stays
  bounded (frees as blocks exit) — unlike Zig/Jai, whose comptime memory grows
  until the build ends.
- `src/vm/engine.zig` — call stack, frames, locals/globals, **63 opcodes**
  (scalar core, calls, aggregates, slices, strings, variants, optionals, zones,
  `host_call`, FFI). `src/vm/compiler.zig` lowers `ir.IrFunction` → bytecode with a
  block→offset pass and a per-function constant pool.
- Wired as the sole comptime engine: `#run`, generic/`#if` evaluation, and the
  resolution rail for `where` constraints all execute here. **comptime ≡ runtime**
  is verified by the corpus tests.

### Metaprogramming surface (Phases 2 & 4 — done)
- **`#run expr`** — evaluate an expression at compile time, fold to a constant.
- **`#insert <code>`** — splice generated code at a site; the spliced subtree is
  re-resolved and type-checked like hand-written code (re-entrant sema).
- **`#quote { … }` / `#quote(expr)`** — **typed** AST quotations (an `ast.Block` /
  `ast.Expr` *value*, parsed once at the definition site — no re-lex per
  expansion), with `$`-splices.
- **`#parse(string)`** — the string escape hatch (parse comptime text → code).
- **Template macros** — `name :: macro(p) { return #quote { … }; }`, hygienic,
  substituting splices through **every** construct, with `#for` comptime
  unrolling. (See [13_metaprogramming.md](13_metaprogramming.md).)
- **First-class `ast.*` values** — programmatic AST construction (build a program
  in the VM, then `#insert #run gen()`).

### Reflection (done) — see [12_reflection_and_constraints.md](12_reflection_and_constraints.md)
- Comptime: matchable `type_info(T)`, `typeid_of`, `type_name`, `sizeof`.
- Resolve-time generics: built-in + user `constraint`/`where` with `reject`,
  output type params `-> $Acc`.
- Runtime: `Any` (type-erased value), safe downcast, recursive field/slice/pointer
  navigation, `info_of(id)`.

### Compiler API & build (Phase 3 — partially done)
- **`#compiler` hooks** — a function the compiler runs at comptime that can
  introspect the program via **`compiler_decls()`** and **generate new top-level
  declarations** (returns source, spliced + re-checked). `src/pipeline.zig:
  runCompilerHookPass`, `src/ir.zig:runCompilerHooks`. **Introspection is now
  *rich* (R1a):** each `Decl` carries its structure — a `struct`'s `fields`, an
  `enum`'s variants, a `fn`'s params (all `[]CField{name, type_name}`), and a fn's
  `ret` — so a hook can generate code driven by a type's real shape.
- **Comptime FFI** — `src/vm/ffi.zig` loads host DLLs (`LoadLibraryA`/
  `GetProcAddress`) and marshals `Value` ↔ C ABI, callable from `#run`.
- **`skarn build`** — `build.sk` runs entirely in the VM (`host_call` → `__build_*`
  intrinsics → `BuildPlan` → real exes/DLLs). See
  [10_build_system.md](10_build_system.md).

## What's partial or not yet built

| Area | State | Gap |
|---|---|---|
| **Message loop** | single-shot | `#compiler` hooks run **once** and can only *introspect + append*. No per-phase events (`File_Parsed`, `Typechecked`), no callback registration, **no modifying existing declarations** (changing a type, rewriting a body). |
| **`std.compiler` surface** | **R1b done** | `Decl` exposes `fields`/params/variants + `ret` + **`body`** (source text). Hooks can **mutate** (replace-by-name, `compiler_remove`), **validate** (`compiler_error`), and run in two **phases** (`#compiler` generate / `#compiler(final)` post-generation). Still future: a `Typechecked` event with *strict* types over the whole program (R6 builds on `#compiler(final)`), and direct AST-node mutation (vs source-text). |
| **Dynamic code generation in hooks** | **done (R1c)** | A hook builds generated source with the **real `std.strings.StringBuilder`** (`#import std.strings`) or the no-import prelude `CodeBuf`/`emit`, then returns it. `#derive`-style codegen works end-to-end. |
| **`std.heap`/byte-addressed memory at comptime** | **done** | The comptime VM now models **real host memory** (`host_ptr`/`host_buf` values; `ptr_from_int`/`slice_from_raw_parts` + host load/store/index do real `@ptrFromInt` access; `VirtualAlloc` via the existing FFI). So `std.heap.Arena` (and `StringBuilder`, …) **run at comptime exactly as at runtime** — comptime ≡ runtime for memory. (`compiler_decls()` is scoped to the user's own declarations so a hook that imports std for codegen doesn't see std's types.) |
| **`zone X: Arena {}` at `#run`** | **done** | A `zone` block folds via the VM (no runtime fallback). The blocker was `@panic`: `std.heap.alloc_bytes` `@panic`s on its OOM branch, and the VM couldn't lower a `@panic`/`exit`/`abort` call (a no-return runtime intrinsic — sometimes a direct call, sometimes an indirect call to a `.local` of that name). The VM compiler now lowers all three to a `trap` opcode — harmless unless the branch actually runs (then comptime correctly halts). Any function that merely *contains* `@panic` (i.e. almost all of std) now folds at compile time. |
| **Capability sandboxing (Phase 5)** | not started | Comptime FFI/`unsafe` are **unconditionally available** (`ffi.zig`: "for now it is unconditionally available"). A malicious dependency macro can reach the host — the `build.rs` hole is **not** yet closed. |
| **Host stdlib in the VM** | partial | `build.sk` uses `host_call` intrinsics; general `std.fs`/`std.io` at comptime behind capability interfaces is not generalized. |
| **`#quote` fidelity for new match patterns** | lossy | range/string/guard/binding patterns reflect as the catch-all `anything`. |

## Roadmap — and Skarn-unique innovations

The first two items finish the "match Jai" story; the rest are **genuinely novel**
and only sound *because* of Skarn's design (capability interfaces + zone purity +
typed AST + IR-shared comptime).

### R1. The iterative message loop (`std.compiler`)
- **R1a — rich introspection (DONE).** `compiler_decls()` returns `Decl{name,
  kind, fields:[]CField, ret, body}` — a hook reads a struct's fields, an enum's
  variants, a fn's params/return, AND a fn's **body source text** (`Decl.body`,
  R1b-A). (`src/ir.zig:lowerCompilerDecls`/`declBodyText`; `astTypeName`;
  `src/ast_prelude.zig:compiler_source`.) The load-bearing foundation for `#derive`
  (R4) and `#require` (R6).
- **R1b — affect compilation (DONE).** A `#compiler` hook can now reshape the
  program four ways:
  - **`compiler_error("msg")`** — halt the build with a custom diagnostic after
    introspecting the program (whole-program validation). Wiring: a `halt_msg` VM
    opcode records the message; `evalToString` surfaces it; `runCompilerHooks`
    reports it and fails.
  - **declaration bodies** — `Decl.body` is the decl's source text, so a hook can
    inspect what a fn *contains*, not just its signature (R1b-A).
  - **mutation** — a generated decl whose name matches an existing one **replaces**
    it (rewrite, not just add), and **`compiler_remove(name)`** drops a decl
    outright. (`record_remove` opcode → `Vm.compiler_removals` → drained to the
    `ComptimeVm` → `HookOutput.removed` → applied in `applyHookOutput`, which also
    does replace-by-name. Prelude decls are never touched.)
  - **per-phase events** — hooks are phase-tagged. Bare `#compiler` runs in the
    **generate** phase (pre-typecheck, emits/mutates). **`#compiler(final)`** runs
    in the **final** phase, *after* generation, over the fully-augmented program —
    so it sees generated decls — and validates (or mutates a second time). The two
    phases are two passes of the same hook machinery (`runCompilerHooks(.., final_phase)`
    + `hasFinalHook`); `#compiler(final)` is the direct basis for `#require` (R6).
- **R1c — dynamic code generation (DONE).** A hook builds generated source two
  ways: with the **real `std.strings.StringBuilder`** (`#import std.strings` — it
  runs at comptime now that the VM models host memory), or with the no-import
  compiler prelude `CodeBuf`: `cb := gen_buf(); emit(&cb, "..."); emit(&cb,
  d.name); … return rendered(&cb);`. `CodeBuf` is backed by **`__str_cat`**, a
  VM-native string-concat builtin (`str_concat` opcode), so it needs no imports —
  handy when the harness can't resolve `#import`. `evalToString` accepts the
  resulting `[]const u8` (string, zone slice, or host_buf). The `#derive(sum)` demo
  (emit a `sum_<T>` for every struct, summing its fields) works end-to-end with
  both. (Bonus robustness: the hook-pass sema is continue-on-error, and an
  unknown-typed slice lowering is graceful, not an ICE.) Minor known limit: Skarn
  string literals don't process `\n` escapes, so use a space separator between
  generated decls.

### R2. Capability-sandboxed metaprogramming — *the flagship*
**The structural fix to the `build.rs`/Jai supply-chain hole.** Skarn already has no
ambient authority: the only way to touch the OS is through a granted **interface**.
So a dependency's compile-time hook receives a `*Compiler` carrying only an
`AstTransform` capability — it can rewrite ASTs but **physically cannot** open a
file, call FFI, or run `unsafe`. The root `build.sk` workspace gets the privileged
capabilities; third-party macros are limited to **pure AST transforms**. Enforced
by the VM capability table + restricting FFI/`unsafe` opcodes to the root
workspace. *No other systems language can offer "install this dependency, its
macros cannot harm your machine" as a structural guarantee.*

### R3. Content-addressed comptime caching — *sound only in Skarn*
Because R2 makes third-party comptime **pure** (no hidden I/O — all effects flow
through capabilities the compiler can observe or deny), a `#run f(args)` result
can be **cached by the content hash of (function IR + argument values)**. Re-builds
hit the cache; heavy generators (serializers, parser tables) compute once and are
reused across builds and machines. Zig/Jai can't safely cache comptime because it
may perform arbitrary, unobservable I/O. Skarn *can*, because purity is enforced, not
hoped for. (We already have a stable content-hash primitive: `typeid_of`/FNV.)

### R4. `#derive` — reflective, capability-scoped generators
A first-class derive mechanism layered on R1+reflection: `#derive(Serialize, Eq)`
on a type invokes registered comptime plugins that walk `type_info(T)` and emit
impls. Plugins are **capability-scoped** (pure AST transforms, R2), so deriving
from an untrusted crate is safe. This is the practical killer app — automatic
serialization / equality / hashing / debug-printing with no per-type boilerplate
and no `build.rs` risk.

### R5. Zone-budgeted comptime
Use the comptime zone model (R-side already done): give each macro/hook a
**memory and step budget** drawn from its zone. A generator that blows its budget
(runaway recursion, pathological expansion) is killed with a diagnostic instead of
OOM-ing the compiler. Turns "zero-leak comptime" into "**bounded, fair** comptime"
— a denial-of-service guard for build-time code, again unique to the zone model.

### R6. Whole-program comptime invariants (`#require`)
After typecheck, a `#compiler` predicate runs over the **entire** typed program and
can assert global properties — "every `Component` struct is `#packed`", "no public
fn returns a zone-owned pointer", "this enum's variants form a closed protocol".
Program-wide, machine-checked design rules expressed in plain Skarn, enforced at build
time. Distinct from per-decl attributes: these are *cross-cutting* invariants.

### R7. Finish `#quote` reflection fidelity
Round-trip the new match patterns (range/string/guard/binding) through `AstPattern`
so quoted/reflected matches are faithful — needed before R4 derive plugins emit
matches.

## Critical files
- VM: `src/vm/{value,zones,engine,instructions,compiler,ffi}.zig`.
- Comptime ↔ pipeline: `src/ir.zig` (`run_expr`, `runCompilerHooks`,
  materialize/reify), `src/pipeline.zig` (`runCompilerHookPass`, prelude
  injection), `src/macroexpand.zig` (template macros).
- Surface: `src/ast_prelude.zig` (`std.compiler` `Decl`, `Any`, `TypeInfo`),
  `src/build.zig` (`skarn build`), `src/parser.zig`/`src/ast.zig` (`#quote`/`#insert`).

## Verification
- `zig build test` — VM opcode/e2e `#run`, zones (leak checks), reflection,
  macros, `#compiler` hooks, `skarn build`. comptime ≡ runtime is asserted by running
  the same programs at comptime and natively.
- Next (R1–R6): message-loop golden tests; a sandbox test proving a dependency
  hook is denied FFI/fs and that `unsafe`/`#extern` are rejected outside the root
  workspace; a cache hit/miss test; a `#derive(Serialize)` round-trip.
