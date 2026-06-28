# Releasing skarn

skarn ships as a **slim, relocatable core archive**: `skarn.exe` plus `LLVM-C.dll`
(codegen) and `skarnlld.dll` (the in-process COFF linker — no spawned `lld-link.exe`),
and the standard library, laid out so the binary finds everything relative to
itself (see Phase 0 — the runtime resolves `std/` from the exe's directory).
Download, extract, run `bin/skarn`. No install step, and no separate LLVM needed to
*use* the compiler.

The core does **not** bundle `libclang` (81 MB) — `skarn bindgen` loads it on demand
and ships as a separate optional component (`skarn-bindgen-<ver>-<target>.zip`). See
[docs/19_distribution.md](docs/19_distribution.md) for the full model.

## One-time CI setup

The build needs an LLVM prebuilt that ships **LLVM-C + libclang + headers** (the
same one used locally). CI can't fetch that automatically, so configure:

| Kind | Name | Value |
| --- | --- | --- |
| Repo **secret** | `LLVM_URL` | A downloadable archive of your LLVM (`.7z`/`.zip`) |
| Repo **variable** | `LLVM_AVAILABLE` | `true` (gates the LLVM-dependent jobs on) |
| Repo **variable** | `LLVM_VERSION` | optional — bump to invalidate the LLVM cache |

Until `LLVM_AVAILABLE=true`, the LLVM jobs are skipped and the fast `check` lane
(build + the LLVM-independent suite, incl. the 74-case VM corpus) still gates
every PR. Adjust the extractor in the workflows if your archive isn't `.7z`.

## Workflows

- **`ci.yml`** — every push/PR. `check` (no LLVM, always) + `full` (LLVM codegen
  + exe-integration tests).
- **`nightly.yml`** — every push to `main`. Builds + refreshes a rolling
  `nightly` pre-release pointing at the latest commit.
- **`release.yml`** — on a `v*` tag. Builds + publishes a GitHub Release.

## Cutting a release

The **tag is the source of truth** for the version. Bump `.version` in
`build.zig.zon` to match, then tag:

```sh
git tag v0.1.0-beta.1 && git push origin v0.1.0-beta.1   # → pre-release
git tag v0.1.0        && git push origin v0.1.0           # → stable release
```

- A tag with a SemVer pre-release part (anything after `-`) publishes as a GitHub
  **pre-release**; a bare `vMAJOR.MINOR.PATCH` publishes as a full release.
- The reported version (and release name) carries `+<git-sha>` build metadata for
  pre-releases — e.g. `skarn 0.1.0-beta.1+ab6e587` — while the asset filename stays
  URL-friendly (`skarn-0.1.0-beta.1-x86_64-windows.zip`).
- `skarn version` always reflects the exact build (`build.zig.zon` + `+<git-sha>` for
  dev/pre-release builds; overridable with `-Dversion=…`).

## Packaging locally

```pwsh
pwsh scripts/package.ps1 -LlvmPath <your-llvm-dir> [-Version 0.1.0-beta.1]
# → dist/skarn-<version>-x86_64-windows.zip              (slim core, in-process LLD)
# → dist/skarn-bindgen-<version>-x86_64-windows.zip      (optional libclang component)
# → dist/skarn-linux-cross-<version>-x86_64-windows.zip  (optional ld.lld for --target linux)
```

The core archive carries `install.ps1` (Windows); the Linux/macOS archives carry
`install.sh`. Both copy the layout to a stable prefix and wire up `PATH` +
`SKARN_HOME`. The release/nightly workflows publish both the core and the bindgen
component as assets.

> Heads-up: an aggressive behavioral AV (e.g. G DATA DeepRay) may quarantine the
> freshly built `skarn.exe` or kill the packaging process — a compiler emitting fresh
> unsigned executables looks like a dropper. Add a build-folder / process
> exception, or code-sign the release binaries.

## Known gap

The released `skarn.exe` still uses a **build-baked Windows SDK lib path** (for the
`kernel32.lib` it hands to programs it links). On a machine without that exact SDK
version, linking *user programs* needs `-Dwindows-sdk-lib-path` at build time or a
matching SDK present. Making the SDK relocatable (bundle the import lib / resolve
beside the exe) is the next packaging step.
