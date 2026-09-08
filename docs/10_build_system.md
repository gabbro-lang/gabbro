# The Gabbro Build System (`build.gab`)

Your build is a Gabbro program that runs inside the compiler. No Makefiles, no CMake,
no second language. The two pieces are already there: the comptime VM that executes
the compiler's IR, and the `#compiler` message loop that inspects and generates the
program. The build system sits on top.

Planned on the same base: capability-sandboxed dependency builds (the structural fix
for the `build.rs` problem), a content-hashed parallel build graph, typed-AST codegen,
targets as values, and `--watch` on the `gabld` linker.

This is the design. The VM/metaprogramming foundation is in
[09_comptime.md](09_comptime.md).

## 1. The file and the execution model

A project has a **`build.gab`** at its root. It defines a `build` procedure:

```gabbro
#import std.build;

build :: fn(b: *Build) {
    exe := b.executable("hello", "src/main.gab");
    b.default(exe);
}
```

`gabbro build` (no file argument) finds `./build.gab` and **runs `build(&b)` inside the
comptime VM** — the same engine behind `#run` and `#compiler`. There is no
separate "build binary": the build script never touches the disk to compile
itself; it executes as compile-time Gabbro. After it returns, the compiler reads the
populated `Build` value back out of VM memory and executes the plan.

This is Jai's model (`#run build()`), minus the boilerplate. For Jai familiarity
`#run build();` is also accepted, but bare `gabbro build` is the idiom.

**Three layers:**

| Layer | Audience | Surface |
| --- | --- | --- |
| **0 — default** | `gabbro build main.gab` | No `build.gab`; CLI flags → options. (Exists today.) |
| **1 — declarative builder** | 90% of projects | `Build`/`Artifact`/`Step` + methods. Pure data. |
| **2 — workspaces & options** | power users | Jai-parity `Workspace`, full `Options` struct, `add_file`/`add_source`/`add_quote`. |
| **3 — compiler intercept** | tooling, codegen | the message loop: `wait_message`, typed `Message`, `set_status`. |

## 2. Layer 1 — the declarative builder

The everyday API. Methods on `*Build` and `*Artifact` (UFCS), which only populate
data — the compiler performs the effects. The build is deterministic and sandboxable
because of that split.

```gabbro
#import std.build;

build :: fn(b: *Build) {
    // the game
    game := b.executable("game", "src/main.gab");
    game.release();                      // or .optimize(.release_fast)
    game.link("raylib");                 // raylib.lib
    game.link("user32");
    game.lib_path("vendor/raylib/lib");
    game.output("bin/game.exe");
    game.define("MAX_ENTITIES", "4096"); // comptime const injected into this build

    // a build-time dependency, sandboxed by default
    rl := b.require_path("raylib", "vendor/raylib");
    game.depend(rl);

    // a codegen step that feeds a second artifact
    bind := b.codegen("bindings", gen_raylib_bindings);  // fn(*Gen)
    tool := b.executable("packer", "tools/packer.gab");
    tool.needs(bind);                    // ordering + declared inputs

    // run / test steps
    b.run_step("run", game);             // `gabbro build run [-- args]`
    b.test_dir("test", "tests/");        // `gabbro build test`

    b.default(game);                     // what bare `gabbro build` produces
}
```

### Core types

```gabbro
pub Optimize   :: enum { debug, release_safe, release_fast, release_small }
pub OutputKind :: enum { executable, shared_library, static_library, object, none }
pub Backend    :: enum { llvm, native }   // native = gabbro's own backend (future)

pub Artifact :: struct {
    name:    []const u8,
    root:    []const u8,        // entry .gab source
    kind:    OutputKind,
    opt:     Optimize,
    backend: Backend,
    output:  []const u8,        // "" → derived from name
    // fixed-capacity pools (VM-readable; no growable lists needed at build time)
    libs:       [MAX_LIBS][]const u8,    n_libs: usize,
    lib_paths:  [MAX_PATHS][]const u8,   n_lib_paths: usize,
    defines:    [MAX_DEFS]Define,        n_defs: usize,
    deps:       [MAX_DEPS]u32,           n_deps: usize,   // indices into Build.deps
}
```

### Builder methods (selection)

| Method | Effect |
| --- | --- |
| `b.executable(name, root) -> *Artifact` | declare an exe |
| `b.shared(name, root)` / `b.static(name, root)` / `b.object(name, root)` | other output kinds |
| `e.release()` · `e.debug()` · `e.release_small()` | optimization shorthands |
| `e.optimize(Optimize.release_fast)` · `e.use_backend(Backend.llvm)` | full optimization / backend |
| `e.link(lib)` · `e.lib_path(dir)` | system libraries + search dirs |
| `e.output(path)` | explicit output path |
| `e.define(key, value)` | inject a comptime constant into that build |
| `e.depend(dep)` · `e.needs(step)` | edges in the build graph |
| `b.run_step(name, exe)` · `b.test_dir(name, dir)` | run/test steps |
| `b.codegen(name, fn)` · `b.custom(name, fn)` | codegen / arbitrary steps |
| `b.require_path(name, dir)` · `b.require_git(name, url, rev)` | dependencies |
| `b.default(artifact)` | the default target |
| `b.option(key, default) -> []const u8` | read a `-Dkey=value` CLI override |

## 3. Layer 2 — workspaces & build options (Jai parity)

A workspace is an isolated compilation environment, as in Jai. Layer 1 makes one
per artifact; in Layer 2 you drive them directly.

```gabbro
build :: fn(b: *Build) {
    w := b.workspace("Main program");
    o := w.options();
    o.kind        = .executable;
    o.output_name = "example";
    o.output_path = "./.build";
    o.backend     = .llvm;
    o.optimize    = .debug;
    o.bounds_check    = .on;
    o.null_check      = .on;
    o.dead_code_elim  = .all;
    o.emit_debug_info = true;
    w.set_options(o);

    w.add_file("main.gab");
    // add generated code as text …
    w.add_source("VERSION :: 3;");
    // … or as TYPED AST (validated at the generation site — better than a string)
    w.add_quote(#quote { build_id :: 0xC0FFEE; });
}
```

### `Options` — the full knob set (Jai's `Build_Options`, modernized)

```gabbro
pub Options :: struct {
    kind:            OutputKind,   // executable | shared_library | static_library | object | none
    output_name:     []const u8,
    output_path:     []const u8,
    backend:         Backend,      // llvm | native
    optimize:        Optimize,

    // safety checks (debug on; release off)  — values: off | on | always/fatal
    bounds_check:    Check,
    cast_check:      Check,
    null_check:      Check,
    overflow_check:  Check,        // Gabbro's overflow policy lives here

    // codegen / artifacts
    emit_debug_info: bool,         // .pdb / DWARF
    dead_code_elim:  DeadCode,     // none | used | all
    strip:           bool,
    llvm_opt_level:  u8,           // 0..3, overrides `optimize`'s LLVM level

    // inputs
    import_paths:    [MAX_PATHS][]const u8, n_import_paths: usize,

    // target (cross-compile)
    target:          Target,

    // hermetic / reproducible
    frozen:          bool,         // fail if the lockfile would change
    text_output:     bool,         // compiler chatter (Jai's text_output_flags)
}

pub Check    :: enum { off, on, always }
pub DeadCode :: enum { none, used, all }
```

`set_optimization(o, .release_fast)` is sugar that flips the whole safety/codegen
block at once, like Jai's `set_optimization`.

## 4. Layer 3 — the compiler intercept (message loop)

This is the Jai message loop, built on Gabbro's `#compiler` hook + `compiler_decls()`
(already implemented). Register interest in a workspace, then pull typed messages
as each phase finishes a unit — and **inspect or alter the program** before it
lowers.

```gabbro
build :: fn(b: *Build) {
    w := b.workspace("Main");
    w.add_file("main.gab");
    w.intercept();                       // begin

    had_error := false;
    while true {
        m := w.wait_message();
        match m.kind {
            .file_parsed => {}
            .typechecked => {
                // m carries the typed declaration: name, kind, type info,
                // and (Gabbro extension) the decl's AST for rewriting.
                if !check_decl(b, m) { had_error = true; }
            }
            .phase => {}
            .complete => break;
            else => {}
        }
    }

    w.end_intercept();
    if had_error { w.set_status(.failed); }
}
```

```gabbro
pub MessageKind :: enum { file_parsed, typechecked, phase, complete, error }

pub Message :: struct {
    kind:      MessageKind,
    workspace: u32,
    // typechecked payload (Jai gives you syntax trees + types here; Gabbro too):
    decl_name: []const u8,
    decl_kind: []const u8,   // "fn" | "struct" | ...  (from compiler_decls())
    // …typed AST handle + type_info handle (Layer-3 extensions)
}
```

Today `compiler_decls()` already gives a hook the program's declarations (name +
kind) at compile time; Layer 3 generalizes that into the streamed message form
and adds the typed-AST/type-info handles.

## 5. The distinctive parts

### 5.1 Capability-sandboxed dependency builds — the supply-chain fix
Jai's build is arbitrary code with full host access; so is `build.rs`. **Gabbro hands
every build hook a capability set.** A dependency's `build.gab` receives a
`*Caps` it cannot forge or widen:

```gabbro
// vendor/raylib/build.gab  — runs sandboxed
build :: fn(b: *Build, caps: *Caps) {
    lib := b.static("raylib", "src/raylib.gab");
    lib.optimize(.release_fast);

    caps.read_dir(".");          // ALLOWED — granted its own folder
    // caps.shell("curl ...");   // DENIED at the VM — no ambient OS authority
    b.default(lib);
}
```

The root build grants capabilities explicitly:
`b.require_path("raylib", "vendor/raylib").allow(.read_self)`. A dependency that
never received `shell`/`net`/`write` *physically cannot* reach them — it's
enforced by the VM's capability table, not policy. This is the structural answer
to the build-script supply-chain hole.

### 5.2 Content-hashed, parallel build graph
Steps and artifacts form a DAG. Each step declares inputs/outputs and is
**content-hashed**: unchanged steps are skipped, independent steps run in
parallel. Jai's build is largely linear; Gabbro's is incremental by construction.
`gabbro build --explain` prints the graph and why each step ran or was cached.

### 5.3 Typed-AST codegen + `#provided`
Generated code goes in as **typed AST** (`w.add_quote(#quote { … })`), validated
at the generation site — not a raw string that fails at splice time. The
`#provided NAME;` directive is Gabbro's typed `#placeholder`: it promises a symbol the
build will generate, and the type-checker trusts it until the build supplies it.

```gabbro
// main.gab
#provided GIT_REV: []const u8;       // build will define this
println(GIT_REV);
```

### 5.4 Targets as values → build matrices
`Target` is an ordinary value, so cross-compilation is a loop:

```gabbro
targets := [_]Target{ Target.win_x64, Target.linux_x64, Target.macos_arm64 };
for t in targets {
    e := b.executable("tool", "src/main.gab");
    e.target(t);
    e.output(out_for(t));
}
```

### 5.5 `--watch`, hermetic builds, asset pipelines
- **`gabbro build --watch`** re-runs only affected steps on file change; the
  microsecond-class `gabld` linker makes the loop feel instant.
- **Hermetic/reproducible:** pin the toolchain, record input hashes, `--frozen`
  fails on lockfile drift.
- **Asset/codegen steps** (shader compile, embed-file, bindings) are first-class
  graph nodes with declared inputs/outputs, so they cache and parallelize too.

### 5.6 Bindings generation, on typed AST
A `b.codegen` step can read C/C++ headers (or, natively, introspect Gabbro via
`compiler_decls()`/`type_info`) and emit **typed AST** bindings into a workspace —
the safer, faster cousin of Jai's `generate_bindings`.

## 6. CLI surface

```text
gabbro build                  run ./build.gab, build the default artifact
gabbro build <name>           build a named artifact or step
gabbro build run [-- args]    build the default exe, then run it
gabbro build test             build + run the test step
gabbro build --list           list artifacts and steps
gabbro build --release        shorthand override (debug → release_fast)
gabbro build -D key=value     set an option the script reads via b.option(...)
gabbro build --watch          rebuild affected steps on change
gabbro build --explain        print the build graph + cache decisions
gabbro build --frozen         fail if the lockfile would change
gabbro build <file.gab>        direct single-file build (back-compat, today's behavior)
```

Like Jai (`-- meta Build`) and the Default_Metaprogram, the no-`build.gab` path is
the built-in default metaprogram: it just turns flags into `Options`.

## 7. Location directives (Jai parity)

For asserts, logging, and codegen:

| Directive | Meaning |
| --- | --- |
| `#file` | full path of the current file |
| `#line` | current line number |
| `#filepath` | directory of the current file |
| `#location(x)` | `(file, line)` of a piece of code |
| `#caller_location` | default-arg form: caller's `(file, line)` |

Paths always use `/`, even on Windows.

## 8. Jai → Gabbro mapping (and the extensions)

| Jai | Gabbro |
| --- | --- |
| `build.jai` / `first.jai`, `#run build()` | `build.gab`, bare `gabbro build` (or `#run build()`) |
| module `Compiler`, `#compiler` proc | `std.build`, `#compiler` hook (built) |
| `compiler_create_workspace()` | `b.workspace(name)` |
| `get_build_options` / `set_build_options` | `w.options()` / `w.set_options(o)` |
| `set_optimization(*o, .OPTIMIZED)` | `set_optimization(o, .release_fast)` |
| `add_build_file` / `add_build_string` | `w.add_file` / `w.add_source` **+ `w.add_quote` (typed)** |
| `#placeholder` | `#provided` (typed) |
| `compiler_begin_intercept` / `wait_for_message` / `end_intercept` | `w.intercept()` / `w.wait_message()` / `w.end_intercept()` |
| `compiler_set_workspace_status(.FAILED)` | `w.set_status(.failed)` |
| `set_build_options_dc(.{do_output=false})` | implicit — the build script never self-compiles to an exe |
| Default_Metaprogram | `gabbro build` with no `build.gab` |
| `generate_bindings` | `b.codegen` step emitting typed AST |
| — | **capabilities/sandbox, content-hashed parallel graph, `--watch`, target matrix, hermetic/`--frozen`** |

## 9. Implementation plan

What the build system needs, against what already exists:

| Piece | Status |
| --- | --- |
| Comptime VM that runs IR | ✅ done |
| `#compiler` hook + `compiler_decls()` (program introspection) | ✅ done |
| Driver `compileFileWithLlvm` (exe/dll/obj) + `gabld` linker | ✅ done |
| **`gabbro build` dir-mode**: find `build.gab`, run `build(b)` in the VM | ✅ done |
| **Config capture**: `host_call` opcode → `__build_*` intrinsics → host `BuildPlan` | ✅ done |
| **Plan executor**: per-artifact `compileFileWithLlvm`, wired outputs/libs/opt | ✅ done |
| Layer 1 surface: `executable`/`shared`/`static`/`object`, `link`/`lib_path`/`output`/`optimize`/`define`, `require_*`/`depend`, `run_step`/`test_dir`/`default` | ✅ done |
| CLI: `gabbro build` / `run` / `<name>` / `--list` / `--release` / `-q` | ✅ done |
| `test_dir` step execution | ✅ done |
| Build graph: deps/steps DAG, topo order, parallel | later |
| Content hashing + incremental + `--watch` | later |
| Capabilities / `*Caps` sandbox + VM capability table | ⏳ slices 1–2 done — comptime FFI is gated in `src/vm/engine.zig`, and the grant is per-library with conservative narrowing; the `*Caps` surface in `build.gab` is open |
| `add_quote` typed codegen / `#provided` / `define` injection | later (extends `#quote`/`#insert`) |
| Layer 2 (`workspace`/`Options`) + Layer 3 (intercept) surface | later |
| Cross-compile targets | later (needs Linux/macOS codegen + entry) |

**Execution mechanism (as built):** instead of reading the `Build` struct back
out of VM memory, the builder methods call `__build_*` compiler intrinsics that
lower (in the VM) to a new `host_call` opcode. The VM's `Vm.host` bridge forwards
each call to the build driver, which records it into a `BuildPlan` (so config is
captured imperatively as the script runs — robust, no fragile offset math, and
the model Jai itself uses). `Build`/`Artifact` are tiny value handles carrying an
id; all state lives in the driver.

**Build order from here:** dependency/build graph + incremental → the rest of the
capability system → Layers 2–3 surface → cross-compile.

## 10. Minimal end-to-end (the target for v1)

```gabbro
// build.gab
#import std.build;

build :: fn(b: *Build) {
    app := b.executable("app", "src/main.gab");
    app.release();
    app.link("user32");
    b.run_step("run", app);
    b.default(app);
}
```

```text
$ gabbro build            # → bin/app.exe via gabld
$ gabbro build run        # → builds, then runs app.exe
$ gabbro build --release  # → release_fast override
```

## API reference (expanded)

The full `std.build` surface. `b` is the `Build` handle; `a` an `Artifact`.

**Declare artifacts** (on `Build`):
`b.executable(name, root)`, `b.shared(name, root)` (.dll),
`b.static(name, root)` (.lib), `b.object(name, root)` (.o) — all return an `Artifact`.

**Optimization** (on `Artifact`): `a.optimize(.debug|.release_safe|.release_fast|.release_small)`,
or the shorthands `a.debug()`, `a.release_safe()`, `a.release_fast()`, `a.release()`
(= release_fast), `a.release_small()`.

**Linking**: `a.link(lib)` (once per library), `a.system_library(name)` (alias),
`a.lib_path(dir)`, `a.link_flag(raw)` — a raw flag passed straight to the linker,
`a.link_libc()` — link the C runtime (for C libraries built against it),
`a.link_mode(.dynamic|.static)` / `a.dynamic()` / `a.static_link()` — choose how C
libraries link (`.static` also links the C runtime), and
`a.runtime_file(path)` — copy a runtime dependency (e.g. a `.dll`) next to the
output, and `a.no_default_libs()` — keep strict `/NODEFAULTLIB` instead of honoring
a static C library's own `/DEFAULTLIB` directives. **Usually you need none of
these:** the build inspects each linked `.lib` and auto-copies an import library's
DLL or auto-links the C runtime (and pulls in its system deps via its `/DEFAULTLIB`
directives) for a static archive. See [docs/11 → Linking](11_c_interop.md) for the
static-vs-dynamic workflow and cross-platform linking.

**Executable settings**: `a.subsystem(.console|.windows)`, `a.console()`,
`a.windowed()` (GUI — no console window), `a.entry(symbol)`, `a.stack_size(bytes)`.
These force the LLD path (the fast gabld linker can't apply them).

**Output**: `a.output(path)` (explicit), `a.out_dir(dir)` (a directory, name derived),
and the workspace-wide `b.out_root(dir)` (a per-artifact `out_dir` wins).

**Metadata**: `a.version(semver)`, `a.description(text)`, `a.install()`,
`a.define(key, val)` (a `#provided`-style comptime override — recorded).

**Dependencies**: `b.require_path(name, dir)` / `b.require_git(name, url)` → a dep id;
`a.depend(dep_id)`.

**Workspace & options**: `b.workspace(name)`, `b.summary()` (print a post-build
summary). Build options come from the command line: `b.option(name) -> bool`
(`gabbro build -Dname`) and `b.option_str(name, default) -> []const u8`
(`gabbro build -Dname=value`).

**Steps & default**: `b.run_step(name, artifact)`, `b.test_dir(name, dir)`,
`b.default(artifact)`.

See `examples/build_showcase/` for a build.gab exercising most of these.

## Test steps

`b.test_dir(name, dir)` declares a test step. Running it compiles and runs every
`*.gab` file directly under `dir` as a standalone program — each one **passes when
it exits 0**:

```sh
gabbro build test          # the step named "test"
```

```text
running tests in tests/
  ✓ parser_test.gab
  ✓ lexer_test.gab
  ✗ sema_test.gab

2 passed, 1 failed
```

A test is just a `.gab` with a `main :: fn() -> i32` that returns `0` on success
and non-zero on failure. The step itself fails (non-zero `gabbro build` exit) if any
test fails, so it drops cleanly into CI. Tests are compiled at `-O0` for speed.

## Inspecting the plan

`gabbro build --list` prints the resolved plan without building anything — every
artifact with its kind, optimization level, version, install flag, and linked
libraries, plus the declared steps and their targets:

```text
workspace: my-app
artifacts:
  game             executable     release-fast (default) v2.1.0 [install]  links: raylib user32
    the main game binary
  util             static_library debug
steps:
  run              run        game
  test             test_dir   tests
```
