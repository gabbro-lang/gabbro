# Linux / ELF / SysV backend

Gabbro cross-compiles from Windows to a static, freestanding Linux x86-64 ELF — no
libc — and runs it. Compute and CLI programs work today: I/O, the heap allocator,
`Vec`, strings, formatting. Filesystem, time, process, net, and threads still call
Win32; they aren't ported yet.

The design sections below (§2 on) are the original plan. The implementation went
freestanding with direct syscalls, not glibc/crt1.o — the notes flag where it
diverges.

## 0. What works today

Use `--target linux` to cross-compile from a Windows host:

```
gabbro build hello.gab -o hello --target linux --llvm-path Y:/SDK/LLVM
# → a static, non-PIE ELF; runs under Linux/WSL with no shared-library deps

gabbro build app.gab -o app --target linux --libc --sysroot <dir-with-libc.so.6> --llvm-path Y:/SDK/LLVM
# → a normal dynamically-linked glibc ELF (ldd → libc.so.6); _start hands off to
#   __libc_start_main, which initializes glibc. `#extern("c", …)` now resolves
#   against libc.so.6 (verified: getpid, and puts via glibc stdio). The whole gabbro
#   stdlib still works under either ABI (it uses syscalls either way).
#   `--target linux-gnu` is sugar for `--target linux --libc`.
```

`--libc` (or build.gab `app.link_libc()`) is the **portable "I need libc" switch**:
the Windows CRT on Windows, glibc on Linux. The entire `std` library (io, heap,
time, fs, process — incl. `set_env`, net, thread) runs on Linux — **full parity
with Windows**. Both the static (`linux`, default) and glibc (`linux --libc`)
ABIs are implemented and verified.

What works end-to-end (verified under WSL):

| Area | Status | How |
| --- | --- | --- |
| Codegen / object | ✅ | `emit.initTarget(.linux, …)` builds an `x86_64-unknown-linux-musl` `TargetMachine` (static reloc) and emits an ELF `.o` |
| Linking | ✅ | `link.linkLinux` invokes `ld.lld -static -e _start` (cross-links from Windows; **no libc, no crt1.o**) |
| Entry point | ✅ | a `#naked #entry _start` in the runtime: clears `%rbp`, aligns `%rsp`, `call main`, then the `exit` syscall — no `mainCRTStartup` |
| Syscalls | ✅ | inline asm with explicit register constraints (`{rax}`,`{rdi}`,…; `r10` for the 4th arg); `write`, `exit`, `mmap`, `mprotect`, `munmap` |
| I/O (`std.io`) | ✅ | `write_stdout`/`write_stderr` route through the `write` syscall (already portable) |
| Allocator (`std.heap`) | ✅ | `Arena` reserve/commit/release go through runtime `os_reserve`/`os_commit`/`os_alloc`/`os_release`; Linux backs them with `mmap`(PROT_NONE)/`mprotect`/`mmap`(RW)/`munmap` |
| `Vec`, strings, fmt | ✅ | fall out of the allocator + I/O above |
| `__chkstk`, `_fltused`, Windows entry | ✅ gated off | `context.applyTargetStubs` and `llvm.lower` emit them only when `target_os == .windows` |

Not yet ported (still Win32-only): `std.fs`, `std.time`, `std.process`,
`std.net`, `std.thread`. These need the corresponding Linux syscalls behind the
same kind of runtime/stdlib seam the allocator now uses.

Key implementation notes / gotchas:

- **Freestanding, not glibc.** The original plan (§4) linked glibc's `crt1.o`
  and let its `_start` call `main`. The implementation instead ships its own
  `#naked _start` and talks to the kernel directly — so the output is a single
  static ELF with **zero** dynamic dependencies (`ldd` → "not a dynamic
  executable"). This matches gabbro's no-libc Windows story.
- **`_start` must be a GLOBAL symbol.** `ld.lld -e _start` resolves the entry
  against global symbols; `#keep` (external linkage) was not enough on its own,
  so `_start` uses `#entry` (which also keeps it out of internalization, like
  `main`). A local `_start` links "successfully" with entry `0x0` → segfault.
- **Inline-asm template quirks.** gabbro's asm template does not process `\n`
  escapes, so multi-instruction asm uses `;` separators (a valid x86 GAS
  statement separator). A literal `$` in an LLVM asm string is an operand
  reference, so AT&T immediates are escaped as `$$-16` / `$$60`. Integer asm
  args are coerced to `i64` to match the asm function type.
- **The platform allocator is a runtime seam, not `#if`.** gabbro has no conditional
  compilation, so `std.heap` stays OS-agnostic and the *runtime* (selected per
  target) provides `os_*`. The runtime-free `compile` path injects a host shim
  so the prelude still type-checks (`pipeline.prependHeapPrelude`).

## 1. What is already portable

A surprising amount. The front-end (lexer/parser/sema), the IR, and LLVM IR
generation are OS-agnostic — they describe computation, not a platform. Two
facts make the port tractable:

- **Object emission already follows the host.** `TargetMachine.initNative`
  ([src/backend/llvm/emit.zig](../src/backend/llvm/emit.zig)) builds the machine
  from `LLVMGetDefaultTargetTriple()` and stamps the matching data layout onto
  the module. Built on Linux, LLVM emits a correct **ELF** `.o` with the SysV
  data layout — no changes needed to emit the object itself.
- **The ABI boundary is already abstracted.** All by-value-aggregate handling
  goes through `Class` / `ParamAbi` / `FnAbi` and a single `classify`
  ([src/backend/llvm/abi.zig](../src/backend/llvm/abi.zig)). SysV slots in as a
  second `classify`, not a rewrite of the call/return lowering.

So the port is **not** "make codegen portable" — it's a finite list of
platform-specific seams. Everything else falls out of LLVM + the host triple.

## 2. The platform-specific surface (the actual work)

| Seam | Windows today | Linux target | Where |
| --- | --- | --- | --- |
| **Aggregate ABI** | Win64 (1/2/4/8 → int reg; else indirect) | SysV eightbyte INTEGER/SSE/MEMORY classification | `backend/llvm/abi.zig` |
| **Object format** | COFF (via host triple) | ELF (via host triple — *free*) | `emit.zig` (no change) |
| **Linker** | `lld-link` COFF, `/ENTRY:mainCRTStartup`, `kernel32.lib` | `cc`/`ld`/`ld.lld` ELF, crt1.o + libc, `_start`→`main` | `backend/llvm/link.zig`, `driver.zig` |
| **Entry point** | `mainCRTStartup` calls our `main` | glibc `_start` (from `crt1.o`) calls `main` | `link.zig`, `main.zig` |
| **Stack probe** | `__chkstk` stub for large frames | not needed (Linux auto-grows the stack) | `context.zig` module-asm — gate off |
| **Comptime FFI** | `LoadLibrary`/`GetProcAddress` | `dlopen`/`dlsym` (`-ldl`) | `vm/ffi.zig` |
| **stdlib OS layer** | `kernel32`/`ws2_32`/`ucrt` `#extern`s | glibc / raw syscalls | `lib/std/*` (see §6) |
| **CLI niceties** | `SetConsoleOutputCP` etc. | no-ops | `main.zig` |

## 3. The core abstraction: a `Target`

Introduce one enum, computed once and threaded where the platform branches:

```zig
pub const Target = enum { windows_x64, linux_x64 };
```

- **Default**: the host (`builtin.os.tag`), so Windows behavior is unchanged.
- **Override**: a `--target=linux-x64` CLI flag (and `-Dtarget=` for the build),
  laying groundwork for cross-compilation later.
- **Threaded into**: `abi.zig` (which `classify`), `link.zig` (which linker +
  args), `driver.compileWithLlvm` (which `link*Mem`), and the `#extern` /
  stdlib-injection decisions.

This keeps the Windows path a literal `switch (target)` arm — no behavior change
on Windows, and every Linux branch is visible and reviewable.

## 4. An ELF executable that runs (`exit 42`)

Goal: `main :: fn() -> i32 { return 42; }` builds to a running ELF binary on
Linux. No aggregates, no FFI, no stdlib OS calls yet.

1. `Target` enum + host detection + `--target` flag (no-op on Windows).
2. **Linker**: add `LinuxLinkOptions` + `buildArgsLinux` beside the Windows ones
   in `link.zig`. Easiest correct path is to invoke the system **`cc`** (gcc or
   clang) as the link driver — it supplies `crt1.o`/`crti.o`/`crtn.o`, the
   dynamic loader, and libc, and resolves `_start`→`main` for free:
   `cc out.o -o out -no-pie` (or PIE; see §7). Fall back to `ld.lld` with
   explicit crt objects when no `cc` is present.
3. **Entry**: drop `/ENTRY:mainCRTStartup`. With `cc`/crt1.o, the program entry
   is glibc's `_start`, which calls our `main(argc, argv)`. gabbro's `#entry main`
   already lowers to a C-callable `main` returning `i32` — that's exactly what
   `_start` expects, so the exit code flows through.
4. Gate the `__chkstk` module-asm ([context.zig](../src/backend/llvm/context.zig))
   behind `target == .windows_x64`.

Test: a Linux CI job runs the existing exe fixtures that need no OS calls
(arithmetic, generics, strings, containers) and checks exit codes. The
`exe_integration.zig` harness already shells out to the produced binary — it just
needs the non-Windows branch enabled instead of `SkipZigTest`.

## 5. The System V AMD64 ABI

This is the one genuinely intricate piece. SysV classifies an aggregate into
**eightbytes** (8-byte chunks), each independently INTEGER, SSE, or MEMORY:

- Size > 16 bytes, or any unaligned field straddle → **MEMORY** (passed
  indirectly: `byval` pointer arg / `sret` return — same as Win64's indirect).
- Otherwise 1–2 eightbytes, each classified by the fields that land in it:
  all-float → **SSE** (passed in an XMM register), anything integer/pointer →
  **INTEGER** (a GP register). Two eightbytes coerce to a `{T0, T1}` pair, e.g.
  `{ double, double }` (a `Vector2`!) → two XMMs, **not** an `i64` as on Win64.

Concretely, extend the `Class` union in `abi.zig`:

```zig
pub const Class = union(enum) {
    direct,
    coerce: u16,                       // Win64: one iN
    coerce_pair: struct { lo: EightbyteKind, hi: EightbyteKind },  // SysV: {lo, hi}
    indirect,
};
pub const EightbyteKind = enum { integer, sse };  // → i64 or double
```

`classifySysV(cg, ty)` walks the struct's fields, bins each into eightbyte 0/1 by
offset, folds (INTEGER beats SSE in a shared eightbyte), and returns
`coerce`/`coerce_pair`/`indirect`. The call/return lowering then builds the
coerced LLVM type (`i64`, `double`, or a 2-element struct) and `bitcast`s the
aggregate through memory exactly as the Win64 path already does — only the
*chosen* type differs. The float-in-register difference is the whole reason
raylib's `Vector2`/`Color` need this and can't reuse Win64's "coerce to iN".

Win64's `__chkstk`-avoiding entry-block allocas and the existing
`sret`/`byval` attribute plumbing ([abi.zig:159](../src/backend/llvm/abi.zig))
are already target-neutral and carry straight over.

Test: the C-ABI corpus (`tests/compiler/new_types_attrs.zig`) re-run against a
small Linux C object that takes/returns `Color`/`Vector2`/`Rectangle` by value,
asserting round-tripped field values (the Win64 suite already does this shape).

## 6. The stdlib OS layer

The pure-logic modules (`math`, `rand`, `color`, `bits`, `mem`, `serde`,
`strings`, `vec`, `map`, `fmt`, `crypto`, `path`) are already portable. The
OS-touching modules each need a Linux backing:

| Module | Windows | Linux |
| --- | --- | --- |
| `std.heap` | `VirtualAlloc`/`VirtualFree` | `mmap`/`munmap` (`MAP_ANON`) |
| `std.time` | `kernel32` clocks | `clock_gettime(CLOCK_*)` |
| `std.process` | `GetCommandLine`, `ExitProcess` | `__libc_start_main` argv, `exit` |
| `std.fs` | Win32 file API | `open`/`read`/`write`/`close`/`stat` |
| `std.thread` | `CreateThread` | `pthread_create`/`pthread_join` (`-lpthread`) |
| `std.net` | Winsock2 (`ws2_32`) | BSD sockets (`socket`/`bind`/…, no `WSAStartup`) |

The pattern: split each into a thin **os shim** the way `std.net` already layers
`std.net.os`. Select the shim per target. Two mechanisms, in preference order:

1. **`#extern` against libc** — `mmap`, `clock_gettime`, `socket`, `pthread_*`
   are all libc symbols; bind them like the Win32 ones. This reuses the entire
   existing FFI path.
2. **Raw syscalls** — for a libc-free build, a `core::syscall(n, …)` builtin
   (an LLVM inline-asm `syscall`) lets `std.os.linux` issue syscalls directly.
   Heavier; defer past first boot.

`std.net` is the nicest payoff: the layered `os/socket/tcp/udp` split means only
`net/os.gab` changes — `socket.gab`/`tcp.gab`/`udp.gab` are already written against
the shim and need no edits. (BSD sockets even drop `WSAStartup`/`WSACleanup`, so
`net::init` becomes a no-op on Linux.)

Build-time selection: pick the shim file by target. Simplest is a
`std.os` facade that `#import`s the right submodule per the build's target —
or, shorter-term, conditional injection in the pipeline keyed on `Target`.

## 7. Comptime FFI, then loose ends

- **Comptime FFI** ([vm/ffi.zig](../src/backend/llvm/../vm/ffi.zig)) is gated
  `os.tag != .windows → error`. Add a `dlopen`/`dlsym` path (link the compiler
  itself with `-ldl`) so `#run`/`#compiler` hooks can call into shared objects on
  Linux, matching the `LoadLibrary` path.
- **PIE**: modern Linux toolchains default to position-independent executables.
  Either build `-no-pie` (simplest; `RelocDefault` already suits it) or switch
  the `TargetMachine` reloc model to `PIC` for Linux and link a PIE. Start with
  `-no-pie`, revisit for hardening.
- **`gabld`**: the self-hosted linker is COFF-only and is purely an optimization
  (LLD is always the correctness path). An ELF `gabld` is a *much* later,
  optional flourish — out of scope here.

## 8. Suggested order

1. `Target` enum + `--target` flag (no-op on Windows). _Small, unblocks the rest._
2. ELF link path via `cc` + entry/`__chkstk` gating → **`exit 42` runs on Linux**.
3. Linux CI running the OS-free exe fixtures.
4. SysV ABI `classify` → the C-ABI corpus passes.
5. `std.heap` on `mmap` → arenas, then everything built on them (`vec`/`map`/
   `strings`) works → most fixtures green.
6. `std.time`/`std.fs`/`std.process`, then `std.thread`, then `std.net`.
7. Comptime FFI via `dlopen`; PIE hardening.

Each step is independently shippable and testable; the Windows target is never
regressed because every branch is a `switch (target)` arm with the existing
behavior preserved on the `windows_x64` side.
