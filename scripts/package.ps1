# scripts/package.ps1 - build + bundle a relocatable gabbro release archive.
#
# Produces  dist/gabbro-<version>-x86_64-windows.zip  laid out as:
#   gabbro-<version>-x86_64-windows/
#     bin/   gabbro.exe, LLVM-C.dll, gabbrolld.dll (in-process linker)
#     lib/   std/...
#     LICENSE-*.txt, NOTICE, README.md, VERSION.txt
# which the relocatable runtime (Phase 0) finds with no flags: std via ../lib,
# the linker beside gabbro.exe, the DLLs via the OS loader.
#
# Usage:  pwsh scripts/package.ps1 -LlvmPath <llvm-dir> [-Version 0.1.0-beta.1] [-Optimize ReleaseSafe]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $LlvmPath,   # LLVM dir (with bin/, lib/, include/)
    [string] $Version = "",                              # override; else build.zig.zon (+git sha)
    [string] $OutDir = "dist",
    [string] $Optimize = "ReleaseSafe"
)
$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
# Resolve a relative output dir against the repo, not the caller's cwd — so the
# script works run from anywhere (e.g. C:\Windows\System32), not only repo root.
if (-not [System.IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $repo $OutDir }

# 1. Build the compiler (release), injecting the version when given.
# -Din-process-lld builds gabbrolld.dll (the LLD fallback) so the release never spawns
# a 69 MB lld-link.exe. -Dembed-linker bakes the self-hosted gabld INTO gabbro.exe, so
# the common link path needs no separate gabld.dll (single-binary linker).
$buildArgs = @("build", "-Dllvm-path=$LlvmPath", "-Doptimize=$Optimize", "-Din-process-lld", "-Dembed-linker")
if ($Version) { $buildArgs += "-Dversion=$Version" }
Write-Host "==> zig $($buildArgs -join ' ')"
Push-Location $repo
try { & zig @buildArgs; if ($LASTEXITCODE -ne 0) { throw "zig build failed ($LASTEXITCODE)" } }
finally { Pop-Location }
# gabld is embedded in gabbro.exe by -Dembed-linker above — no separate gabld.dll.

# 2. The version is whatever the binary reports - the single source of truth.
# (`gabbro version` prints to stderr; route through cmd so PowerShell doesn't treat
# native stderr as a terminating error under ErrorActionPreference=Stop.)
$gabbroexe = Join-Path $repo "zig-out/bin/gabbro.exe"
$reported = (& cmd /c "`"$gabbroexe`" version 2>&1") | Select-Object -First 1
$ver = ($reported -replace '^gabbro\s+', '').Trim()
if (-not $ver) { throw "could not read version from gabbro.exe" }
# The archive filename drops SemVer build metadata (`+sha`) - the tag/version
# already identifies it, and `+` is awkward in URLs. `gabbro version` keeps the sha.
$fileVer = ($ver -replace '\+.*$', '')
$name = "gabbro-$fileVer-x86_64-windows"
Write-Host "==> version: $ver  (archive: $name)"

# 3. Assemble the install layout.
$stage = Join-Path $OutDir $name
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force (Join-Path $stage "bin") | Out-Null

Copy-Item (Join-Path $repo "zig-out/bin/gabbro.exe") (Join-Path $stage "bin")

# In-process linker: gabbrolld.dll (built above) replaces a spawned 69 MB lld-link.exe.
# gabbro LoadLibrary's it at link time; no standalone linker exe in the core.
$gabbrolld = Join-Path $repo "zig-out/bin/gabbrolld.dll"
if (-not (Test-Path $gabbrolld)) { throw "gabbrolld.dll missing - build must use -Din-process-lld" }
Copy-Item $gabbrolld (Join-Path $stage "bin")
# (gabld is baked into gabbro.exe via -Dembed-linker — nothing to copy.)

# LLVM-C.dll (codegen) is the only LLVM DLL the core needs. libclang (bindgen)
# and ld.lld.exe (Linux cross-link) are separate opt-in components below.
$llvmc = Join-Path $LlvmPath "bin/LLVM-C.dll"
if (-not (Test-Path $llvmc)) { throw "required dependency not found: $llvmc" }
Copy-Item $llvmc (Join-Path $stage "bin")

Copy-Item -Recurse (Join-Path $repo "lib") (Join-Path $stage "lib")
foreach ($m in @("LICENSE-APACHE-2.0.txt", "LICENSE-GPLv3.txt", "NOTICE", "README.md")) {
    if (Test-Path (Join-Path $repo $m)) { Copy-Item (Join-Path $repo $m) $stage }
}
# The platform installer (adds bin/ to PATH, sets GABBRO_HOME). Each OS's archive
# carries its own: install.ps1 here; install.sh ships with the Linux/macOS archive.
Copy-Item (Join-Path $repo "scripts/install.ps1") $stage
$ver | Out-File -Encoding ascii (Join-Path $stage "VERSION.txt")

# 4. Zip.
$zip = Join-Path $OutDir "$name.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $stage -DestinationPath $zip
$size = "{0:N1} MB" -f ((Get-Item $zip).Length / 1MB)
Write-Host "==> packaged: $zip  ($size)"

# 5. Optional bindgen component - libclang + the clang resource headers, as a
# `bindgen/` folder you drop next to gabbro.exe (in bin/) to enable `gabbro bindgen`.
# Kept out of the core archive so the 81 MB libclang only ships if you want it.
$bgZip = ""
$libclang = Join-Path $LlvmPath "bin/libclang.dll"
if (Test-Path $libclang) {
    $bgRoot = Join-Path $OutDir "bindgen-stage"
    $bgDir = Join-Path $bgRoot "bindgen"
    if (Test-Path $bgRoot) { Remove-Item -Recurse -Force $bgRoot }
    New-Item -ItemType Directory -Force $bgDir | Out-Null
    Copy-Item $libclang $bgDir
    # clang resource headers: <llvm>/lib/clang/<highest>/include -> bindgen/clang-headers
    $res = Get-ChildItem (Join-Path $LlvmPath "lib/clang") -Directory -ErrorAction SilentlyContinue |
        Sort-Object { [int]($_.Name) } -Descending | Select-Object -First 1
    if ($res) { Copy-Item -Recurse (Join-Path $res.FullName "include") (Join-Path $bgDir "clang-headers") }
    @"
gabbro bindgen component (libclang $ver).

Extract the 'bindgen' folder into the directory that contains gabbro.exe (gabbro's bin/).
Then C-header binding generation is available:

    gabbro bindgen <header.h> [-o out.gab]

gabbro finds libclang here on demand; the core compiler never loads it.
"@ | Out-File -Encoding ascii (Join-Path $bgDir "README.txt")
    $bgZip = Join-Path $OutDir "gabbro-bindgen-$fileVer-x86_64-windows.zip"
    if (Test-Path $bgZip) { Remove-Item -Force $bgZip }
    Compress-Archive -Path $bgDir -DestinationPath $bgZip
    $bgSize = "{0:N1} MB" -f ((Get-Item $bgZip).Length / 1MB)
    Write-Host "==> bindgen component: $bgZip  ($bgSize)"
} else {
    Write-Host "  (no libclang.dll in $LlvmPath/bin - skipping bindgen component)"
}

# 5b. Optional linux cross-compile component - ld.lld (the ELF linker for
# `gabbro build --target linux`). Windows linking is in-process (gabbrolld.dll); only
# cross-compiling to Linux needs this, so it ships separately. Drop ld.lld.exe
# into bin/ next to gabbro.exe; the runtime resolves it there (LLVM-C.dll marker).
$xZip = ""
$ldlld = Join-Path $LlvmPath "bin/ld.lld.exe"
if (Test-Path $ldlld) {
    $xRoot = Join-Path $OutDir "linux-cross-stage"
    if (Test-Path $xRoot) { Remove-Item -Recurse -Force $xRoot }
    New-Item -ItemType Directory -Force $xRoot | Out-Null
    Copy-Item $ldlld $xRoot
    @"
gabbro linux cross-compile component (ld.lld).

Put ld.lld.exe into gabbro's bin/ (next to gabbro.exe). Then you can cross-compile to
Linux from Windows:

    gabbro build <file.gab> --target linux              # static, no-libc ELF
    gabbro build <file.gab> --target linux-gnu --sysroot <dir>   # glibc ELF
"@ | Out-File -Encoding ascii (Join-Path $xRoot "README.txt")
    $xZip = Join-Path $OutDir "gabbro-linux-cross-$fileVer-x86_64-windows.zip"
    if (Test-Path $xZip) { Remove-Item -Force $xZip }
    Compress-Archive -Path (Join-Path $xRoot "*") -DestinationPath $xZip
    Write-Host ("==> linux-cross component: $xZip  ({0:N1} MB)" -f ((Get-Item $xZip).Length / 1MB))
}

# 6. Emit outputs for CI.
if ($env:GITHUB_OUTPUT) {
    "archive=$zip"     | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    "archive_name=$name.zip" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    "version=$ver"     | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    "file_version=$fileVer" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    if ($bgZip) {
        "bindgen_archive=$bgZip" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
        "bindgen_archive_name=gabbro-bindgen-$fileVer-x86_64-windows.zip" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    }
    if ($xZip) {
        "linux_cross_archive=$xZip" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
        "linux_cross_archive_name=gabbro-linux-cross-$fileVer-x86_64-windows.zip" | Out-File -Append -Encoding ascii $env:GITHUB_OUTPUT
    }
}
