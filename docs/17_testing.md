# Testing — `#test` and the comptime lane

> Status: the **comptime lane is implemented** — a `#test` function runs on the
> comptime VM *during compilation*, and a failed assertion is a compile error.
> The runtime lane, property testing, snapshots, and reflection-driven diffs are
> designed here as the next iterations (§5).

skarn's testing story is built on two facilities the compiler already has, which let
it do something most languages can't:

- **The comptime VM models real host memory.** A pure test can run while the
  program compiles, so a failing assertion fails the build exactly like a type
  error — no test binary, no runner process, hermetic.
- **Reflection is total** (`type_info`, `Any`, the serde layer). The richer
  machinery — structural diffs, input generators, snapshots — derives from a
  type's shape with no per-type boilerplate (§5).

## 1. Writing a test

A test is a function marked `#test` that takes a test context `t: *Test`:

```skarn
#test
add_associates :: fn(t: *Test) {
    t.eq(2 + 2, 4);
    t.ne(2 + 2, 5);
    t.expect((1 + 2) + 3 == 1 + (2 + 3));
}
```

You import nothing — the `Test` type is injected automatically whenever a module
declares a `#test`. Discovery is by attribute: there is no registry to maintain.

## 2. The comptime lane

A `#test` runs **on the comptime VM as part of compiling the module**. Each test
is invoked with a fresh VM over the program's bytecode, so one failure can't
affect the next. When an assertion fails it calls `core::compiler_error(...)`,
the VM halts that run, and the driver turns it into a real diagnostic:

```
$ skarn build app.sk -o app.exe
comptime test 'arithmetic_is_broken' failed: t.eq: values are not equal

1 passed, 1 failed (comptime)
skarn: CompileFailed
```

No executable is produced and `skarn` exits non-zero. A program whose tests all pass
builds normally; the test functions are **pruned before code generation**, so
they add nothing to the binary. A program with no `#test` declarations pays
nothing — the lane is skipped entirely.

This is the headline difference from Go/Rust/Zig test runners: a broken invariant
stops the build the same way a type mismatch does.

## 3. The `Test` context

| Method | Passes when | On failure |
| --- | --- | --- |
| `t.eq(a, b)` | `a == b` | `compiler_error("t.eq: values are not equal")` |
| `t.ne(a, b)` | `a != b` | `compiler_error("t.ne: values are unexpectedly equal")` |
| `t.expect(cond)` | `cond` is true | `compiler_error("t.expect: condition was false")` |
| `t.fatal(msg)` | — (always fails) | `compiler_error(msg)` |

`eq`/`ne` are generic (`fn(self: *Self, a: $V, b: $V)`), so they take any two
values of the same type.

### What the comptime lane compares

`==`/`!=` run on the VM and now cover the aggregates too:

- **scalars** — ints, floats, bools, simple enums;
- **`[]const u8`** and other slices — content comparison (`t.eq("a", "a")`); and
- **structs and arrays** — field-by-field / element-by-element (recursing into
  nested structs and string fields), so `t.eq(point_a, point_b)` works at comptime.

Two payload-enum values compare too, as long as the payloads are scalar
(`E.c(1) == E.c(1)`); a variant carrying a struct/string/array payload is the one
case that errors (use `match`). The richer reflection-driven structural *diff*
(§5) — which prints which field differs on failure — is still the post-0.1.0
upgrade; today a failed `t.eq` reports a generic message.

> Generic string compare used to miscompile everywhere, not just in tests: inside
> a generic function `a == b` on `$V = []const u8` fell through to a scalar
> compare on the fat slice because the lowerer didn't resolve the param's type
> through the instantiation binding. Fixed in `exprType`
> ([src/ir.zig](../src/ir.zig)) so type-directed lowering sees the concrete type.

## 4. How it works

```
parse → preludes → sema (Test injected if a #test exists)
                          │
   driver: hasTestDecl? ──┤ no → straight to codegen
                          │ yes
                          ▼
        runComptimeTests:  for each #test fn,
          fresh Vm.initModule over the bytecode,
          vm.call(name, &.{*Test}) — a compiler_error trap = failure
                          │
              any failure → print diagnostics, fail the build
              all pass    → pruneTestDecls, continue to codegen
```

- `Test` and its methods are an injected prelude
  ([src/ast_prelude.zig](../src/ast_prelude.zig), `testing_source`), prepended in
  [src/pipeline.zig](../src/pipeline.zig) (`prependTestingPrelude`) when
  `ir.hasTestDecl` is true. The assertion methods call `core::compiler_error`,
  which the VM surfaces as `compiler_error_msg` on a trap.
- The lane itself is [src/ir.zig](../src/ir.zig): `hasTestDecl`,
  `runComptimeTests` (reuses the `runBuildHook` VM-call pattern), and
  `pruneTestDecls`.
- The driver ([src/driver.zig](../src/driver.zig), `runComptimeTestLane`) runs it
  between the diagnostics check and the LLVM backend in both
  `compileWithLlvm` and `compileFileWithLlvm`.

## 5. Roadmap

The comptime lane is the spine. The remaining pieces (designed in
[docs/15 §4](15_tooling.md)) build on it and on skarn's reflection:

- **Runtime lane** — `#test` functions that touch the OS run as a built
  executable, each in its own `zone`/arena with leak accounting. This also lifts
  the scalar-only restriction on `t.eq` (the LLVM backend runs the real
  string/struct comparison). `skarn test` discovers, builds, and reports (pretty
  TTY + TAP/JSON for CI).
- **Reflection-powered assertions** — on a failed `t.eq`, walk `type_info(V)` and
  print a field-by-field structural diff for any struct/enum/slice, no `#derive`
  required.
- **Property testing** — a `#test(prop)` function declares its generated inputs as
  extra typed parameters; the runner derives a generator from `type_info` for
  each, runs N seeded cases, and **shrinks** to a minimal counterexample. (Inputs
  go through parameters rather than an inline closure because skarn lambdas don't
  capture.)
- **Snapshots** — `t.snapshot(value, "name")` serializes any value through serde
  and diffs against a stored snapshot; `skarn test --update` rewrites it.

The throughline: discovery is by attribute, assertions and generators come from
reflection, and the comptime lane makes a failing test a failing build.
