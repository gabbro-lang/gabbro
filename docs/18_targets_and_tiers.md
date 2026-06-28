# Targets, ABIs & support tiers

How skarn decides *what machine* it compiles for, *what it links against*, and
*how much we guarantee* per target. This is the architecture for cross-compiling
beyond the original Windows-only backend.

## 1. The target model

A target is three orthogonal axes:

```
            arch         ×      os       ×       env (ABI / libc)
        ┌───────────┐        ┌────────┐        ┌──────────────────────┐
        │ x86_64    │        │ windows│        │ msvc   (Win runtime) │
        │ aarch64   │        │ linux  │        │ none   (freestanding)│
        │ riscv64   │        │ (macos)│        │ musl   (static libc) │
        │ (wasm32)  │        │ (wasi) │        │ gnu    (glibc, dyn)  │
        └───────────┘        └────────┘        └──────────────────────┘
```

Written as an LLVM-style triple: `x86_64-linux-gnu`, `aarch64-linux-none`,
`x86_64-windows-msvc`. The CLI accepts shorthands (`--target linux` =
`x86_64-linux-none`, the static/freestanding default; `--target linux-gnu` =
`x86_64-linux-gnu`).

**The front-end is target-independent.** Lexer, parser, sema, IR, the comptime
VM, and macros describe *computation*, not a platform — every language feature
works on every target. Tiers (below) are **not** about language features; they
are about codegen + runtime + stdlib completeness.

## 2. Where platform differences live — the runtime ABI seam

The architectural decision: **all OS-specific behaviour goes through a small,
fixed set of `os_*` primitives provided by the platform runtime**, and the
standard library is written against that seam, OS-agnostically. skarn has no
`#if os == …` — the runtime is *selected* per target, so the seam is the only
place the OS appears.

```
   std.io   std.heap   std.time   std.fs   std.net   …      (OS-agnostic)
      │         │          │         │        │
      └─────────┴────┬─────┴─────────┴────────┘
                     ▼
          os_* runtime primitives          ← the seam
      write/alloc/clock/open/socket/…
        ┌───────────┼───────────┐
        ▼           ▼           ▼
   windows.sk    linux.sk   (linux_gnu)     ← one impl per (os[,arch,env])
   kernel32     syscalls      libc
```

Seam primitives in place today:

| Surface | Seam | Windows | Linux (freestanding) |
| --- | --- | --- | --- |
| I/O | `write_stdout`/`write_stderr` | `WriteFile` | `write` syscall |
| Heap | `os_reserve`/`os_commit`/`os_alloc`/`os_release` | `VirtualAlloc`/`VirtualFree` | `mmap`/`mprotect`/`munmap` |
| Time | `os_wall_nanos`/`os_monotonic_nanos`/`os_sleep_nanos` | kernel32 (FILETIME/QPC/Sleep) | `clock_gettime`/`nanosleep` |
| Exit/panic | `exit`/`abort`/`@panic` | `ExitProcess` | `exit` syscall |

Porting a stdlib module to a new OS = implement its seam primitives in that OS's
runtime. The module itself does not change. `std.io`, `std.heap`, `std.time`
(and everything built on them — `Vec`, maps, strings, `fmt`) already run on
Linux this way.

> **Runtime-free path note.** The `compile()` entry (used by inline tests/tools)
> has no runtime. The heap prelude is auto-injected there, so it ships a tiny
> host shim for the heap seam (`pipeline.prependHeapPrelude`). File-imported
> modules (`std.time`, etc.) always go through the file path, which prepends the
> runtime, so they need no shim.

## 3. libc vs freestanding (the `env` axis)

Two ways to be a Linux binary; skarn supports both, and they differ **only** in the
entry point + link step — never in the stdlib:

| | `none` / `musl` (freestanding, **default**) | `gnu` (glibc) |
| --- | --- | --- |
| Entry | our `#naked #entry _start` → `main` | crt1.o `_start` → `__libc_start_main` → `main` |
| Link | `ld.lld -static -e _start` | `-dynamic-linker /lib64/ld-linux-x86-64.so.2`, crt objects, `-lc` |
| Output | static non-PIE ELF, **zero deps** (`ldd` → "not a dynamic executable") | dynamically linked against `libc.so.6` |
| Needs at link time | just `ld.lld` | a libc toolchain / **sysroot** (crt1.o, libc.so, the loader) |
| OS seam | raw syscalls | raw syscalls *(unchanged)* — libc is used only for its loader/CRT |

**Decision: freestanding is the default and recommended Linux target.** It is
self-contained and portable across distros (the static-musl/Go/Zig model), and
needs nothing but `ld.lld` — which is why it cross-compiles cleanly from a
Windows host today. `gnu` is the opt-in for interop with libc-only libraries or
"a normal dynamically-linked binary."

Because the seam stays on raw syscalls, **`gnu` is purely a link-mode + entry
change**: gate off our `_start`, switch the `ld.lld` argument set, and supply the
glibc objects. The compiler plumbing for that is small; the real dependency is
the **glibc files at link time** — which are not bundled. On a full Linux host
(or with `--sysroot pointing at one), the link just works; on a minimal box you
install `libc6-dev` (and use `cc` as the link driver) first.

## 4. Architectures

LLVM gives us the back ends for free; the finite per-arch work is the
**runtime** (syscall ABI + entry stub) and the **aggregate ABI classifier**
(`backend/llvm/abi.zig` — already abstracted; scalars are all LLVM's job, only
by-value aggregates at `#extern` boundaries need a classifier).

| Arch | LLVM | Syscall ABI (nr / args / insn) | Aggregate ABI | Status |
| --- | --- | --- | --- | --- |
| **x86_64** | ✅ | `rax` / `rdi rsi rdx r10 r8 r9` / `syscall` | SysV AMD64 (done) | **implemented** |
| **aarch64** | ✅ | `x8` / `x0…x5` / `svc #0` | AAPCS64 | Tier 2 target — needs runtime + classifier |
| **riscv64** | ✅ | `a7` / `a0…a5` / `ecall` | RV calling conv | Tier 3 — emerging |
| **wasm32** | ✅ | no syscalls — WASI imports | wasm ABI | Tier 3 — different seam (WASI), no `_start` asm |

Adding an arch is a checklist, not a rewrite:

1. Triple + data layout — pass the arch to `emit.initTarget`.
2. Per-arch syscall wrappers + `_start` stub in a runtime variant (the only asm).
3. An `abi.zig` `classify` arm for that arch's aggregate rules.
4. Register the arch in the `Target` and the runtime selector.

Everything above the seam (the entire stdlib) is already arch-independent.

aarch64-linux is the highest-value next arch (cloud ARM, Apple Silicon via
Linux VMs/containers, Raspberry Pi). aarch64/x86_64 **macOS** is a separate, larger
effort (Mach-O object format, different syscalls/ABI, code-signing) — tracked as
future Tier 3.

## 5. Support tiers

Borrowed from Rust's model, adapted to skarn's seam architecture.

- **Tier 1 — guaranteed.** A first-class target skarn commits to and gates releases
  on: language, codegen, and runtime build and run, and the test suite passes in
  CI. The stdlib is expected complete; any remaining gap is a **release blocker**,
  not a reason to demote the target. *Regressions block a release.*
- **Tier 2 — supported.** Builds and runs; stdlib complete or near-complete;
  smoke-tested (not every module in CI). *Best-effort fixes.*
- **Tier 3 — experimental.** Codegen exists and may build; runtime/stdlib partial
  or unverified; no guarantees. *Community / opportunistic.*

| Target | Tier | Notes |
| --- | --- | --- |
| `x86_64-windows-msvc` | **1** | original host target; full stdlib |
| `x86_64-linux-none` (static) | **1** | first-class target — cross-compiles from Windows; language + codegen + core stdlib (io/heap/time/Vec/strings) verified; completing fs/process/net/thread is a **Tier-1 release blocker**, not a demotion |
| `x86_64-linux-gnu` (glibc) | **2** | implemented — `--target linux-gnu` + `--sysroot`; our `_start` → `__libc_start_main`, links `libc.so.6` directly. Needs a sysroot with `libc.so.6` at link time |
| `aarch64-linux` | **3 → 2** | unblock by adding the aarch64 runtime + ABI arm |
| `riscv64-linux`, `wasm32-wasi` | **3** | LLVM-ready; runtime/seam not yet written |
| `*-macos` | **3** | Mach-O + Apple ABI; larger effort |

## 6. Stdlib porting status (Linux)

| Module | Status | Seam needed on Linux |
| --- | --- | --- |
| `std.io` | ✅ ported | `write` (done) |
| `std.heap` | ✅ ported | `mmap`/`mprotect`/`munmap` (done) |
| `std.time` | ✅ ported | `clock_gettime`/`nanosleep` (done) |
| `std.fs` | ✅ ported | `openat`/`read`/`write`/`close`/`lseek`/`newfstatat`/`unlink`/`getdents64` (done) |
| `std.process` (all, incl. `set_env`) | ✅ ported | `getpid` + `/proc/self/{cmdline,environ}` + `fork`/`execve`(`/bin/sh -c`)/`wait4`/`kill`; `set_env`/`unset_env` via a runtime env overlay (done) |
| `std.net` | ✅ ported | socket syscalls (41/42/43/44/45/48/49/50/51/54) + SOL_SOCKET option translation + `fcntl` (done) |
| `std.thread` | ✅ ported | `clone` (allocated child stack, asm child-entry) + `wait4` join + `sched_getaffinity`/`sched_yield` (done) |

**Every `std` module runs on Linux — full parity with Windows.** The static
`x86_64-linux-none` target has a complete stdlib: Tier 1 in full.

> **Note — mutable globals + the env overlay.** `command_line`/`get_env` read
> `/proc/self/{cmdline,environ}` (no captured `argv`/`envp` pointer needed).
> `set_env`/`unset_env` were initially blocked because skarn had no mutable
> top-level globals to anchor a process-wide environ — that language feature was
> since added (`name: T = init;`, see [01_syntax](01_syntax.md)), so the runtime
> now keeps an env overlay (`get_env` consults it first; `spawn` merges it into
> the child's environment). No remaining parity gap.
