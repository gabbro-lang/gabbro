# Distribution, packaging, install

Small core, optional components dropped in next to the binary. The core is one
relocatable folder: `gabbro.exe`, `LLVM-C.dll`, `gabbrolld.dll`, `lib/std`.

## Core dependencies

| Dependency | For | In core |
| --- | --- | --- |
| `LLVM-C.dll` | codegen | yes (~69 MB) |
| `gabbrolld.dll` | in-process COFF linker (Windows) | yes (~65 MB) |
| `lib/std` | standard library (Gabbro source) | yes |
| `lld-link.exe` | spawned COFF linker | no — superseded by `gabbrolld.dll` |
| `ld.lld.exe` | ELF linker (Linux target) | no — cross component |
| `libclang.dll` | `gabbro bindgen` | no — bindgen component |

libclang is 81 MB and exactly one subcommand touches it. Linking it would put it
in every `gabbro.exe` import table, paid at process start — Windows resolves imports
at load. So it's not linked.

## libclang, loaded on demand

`gabbro.exe`'s import table is `KERNEL32`, `LLVM-C.dll`, the CRT shims, `ntdll`. No
libclang. `gabbro bindgen` does a runtime `LoadLibraryW` on first use.

`src/clang_c.zig`:

- clang-c header is `@cImport`ed for types/enums only.
- The ~48 functions are a fn-pointer table; each field is typed
  `*const @TypeOf(c.clang_…)`, so signatures track the header — no manual prototypes
  to drift.
- `load(path)` resolves symbols by field name. `bindgen.zig` calls through it.

Resolution order for the DLL:

1. `$GABBRO_LIBCLANG` (file or dir)
2. next to `gabbro.exe`, then `<exe>/bindgen/`
3. `$GABBRO_LLVM/bin`
4. build-time LLVM dir
5. bare name — OS loader search

Miss → `gabbro bindgen` prints that list.

## In-process linking

Object, then a linker for the exe. The LLD COFF driver is compiled into
`gabbrolld.dll` (`-Din-process-lld`, `src/backend/llvm/lld_shim.cpp`) and called
in-process; `lld-link.exe` is never spawned. Spawn path stays as a fallback.

## gabld — the native linker

`gabld.dll` is a PE/COFF linker written in Gabbro (`linker/gabld.gab`). Default
for programs it can handle, LLD for the rest.

Why it's fast: no `.lib` import-archive parsing, which is LLD's dominant cost. The
compiler emits a `.skimp` section mapping every `#extern("dll","sym")` import to
its DLL. gabld reads that and writes one PE import descriptor per DLL.

Single-object COFF. Reads AMD64, merges sections by class (`.text`, `.rdata`,
`.data`, `.pdata`, `.bss`) at their required alignment — the 32/64-byte SIMD
constant pools at -O2 are the reason that matters. Builds the import tables,
applies REL32 / ADDR64 / ADDR32NB, keeps `.pdata`/`.xdata` and the exception
directory, writes a PE32+ with the subsystem, entry, and stack from the build.
Emits DLLs too (`.edata` from a `.skexp` map) — which is how `gabld.dll` links
itself.

Hands off to LLD on multi-object links, raw linker flags, or a static-CRT
`/DEFAULTLIB` pull-in.

### Dev: DLL. Release: embedded.

- `zig build` → `gabbro.exe` + `gabld.dll`, loaded on demand.
- `zig build -Dembed-linker` → two-stage. `gabld.gab` compiles to a freestanding
  object, links into `gabbro.exe`, which exports `gabbro_link_mem`. One binary that
  is its own linker.

`link.zig` is one path either way: `GetProcAddress` on the running module (embed),
else `LoadLibrary("gabld.dll")` (dev). The embedded object is built from source
at release time — no committed blob.

## Optional components

Folders dropped into `bin/`. Resolved by location, no env vars, no LLVM install.

`gabbro-bindgen-<ver>-<target>.zip`:

```
bindgen/
  libclang.dll
  clang-headers/        # stddef.h, stdint.h, …
  README.txt
```

`gabbro-linux-cross-<ver>-<target>.zip`:

```
ld.lld.exe
README.txt
```

## Packaging — `scripts/package.ps1`

ReleaseSafe build, `-Din-process-lld`, into `dist/`:

- `gabbro-<ver>-<target>.zip` — core: `bin/` (gabbro.exe, LLVM-C, gabbrolld.dll),
  `lib/std`, licenses, `VERSION.txt`, installer. stdlib resolves relative to
  `gabbro.exe`.
- `gabbro-bindgen-<ver>-<target>.zip`
- `gabbro-linux-cross-<ver>-<target>.zip`

Reported version is the source of truth; the asset filename drops the `+<sha>`.

## Install scripts

Per-archive installer, idempotent. Copies the tree to a prefix, wires `PATH` and
`GABBRO_HOME`.

- `install.ps1` → `%LOCALAPPDATA%\gabbro`
- `install.sh` → `~/.gab`

Both take a custom prefix and a no-PATH mode.

## Size (Windows core, compressed)

| | |
| --- | --- |
| libclang + both LLD exes in core | 110 MB |
| libclang → bindgen component | 78 MB |
| in-process `gabbrolld.dll` + cross split | 50 MB |
