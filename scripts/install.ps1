# install.ps1 — install skarn from an extracted release archive (Windows).
#
# Run from inside the extracted archive (this script sits next to bin/ and lib/):
#   .\install.ps1                      # → %LOCALAPPDATA%\skarn, adds bin to PATH
#   .\install.ps1 -Prefix D:\tools\skarn  # custom location
#   .\install.ps1 -NoPath              # copy only, don't touch PATH
#
# skarn finds its standard library + linker relative to skarn.exe, so the whole install
# is just `bin/` + `lib/` kept together. We also set SKARN_HOME as a robust fallback.
[CmdletBinding()]
param(
    [string] $Prefix = (Join-Path $env:LOCALAPPDATA "skarn"),
    [switch] $NoPath
)
$ErrorActionPreference = "Stop"
$src = $PSScriptRoot

if (-not (Test-Path (Join-Path $src "bin/skarn.exe"))) {
    throw "run this from inside the extracted skarn archive (no bin/skarn.exe next to install.ps1)"
}

# 1. Copy the layout to $Prefix (replacing any prior install).
Write-Host "Installing skarn -> $Prefix"
foreach ($d in @("bin", "lib")) {
    $dst = Join-Path $Prefix $d
    if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
}
New-Item -ItemType Directory -Force $Prefix | Out-Null
Copy-Item -Recurse -Force (Join-Path $src "bin") (Join-Path $Prefix "bin")
Copy-Item -Recurse -Force (Join-Path $src "lib") (Join-Path $Prefix "lib")
foreach ($m in @("LICENSE-APACHE-2.0.txt", "LICENSE-GPLv3.txt", "NOTICE", "README.md", "VERSION.txt")) {
    if (Test-Path (Join-Path $src $m)) { Copy-Item -Force (Join-Path $src $m) $Prefix }
}

# 2. PATH + SKARN_HOME (user scope; idempotent).
$bin = Join-Path $Prefix "bin"
if (-not $NoPath) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (($userPath -split ';') -notcontains $bin) {
        [Environment]::SetEnvironmentVariable("Path", "$bin;$userPath", "User")
        Write-Host "Added $bin to your user PATH."
    } else {
        Write-Host "$bin already on PATH."
    }
    [Environment]::SetEnvironmentVariable("SKARN_HOME", $Prefix, "User")
}

$ver = if (Test-Path (Join-Path $Prefix "VERSION.txt")) { (Get-Content (Join-Path $Prefix "VERSION.txt") -First 1) } else { "" }
Write-Host ""
Write-Host "skarn $ver installed. Open a NEW terminal, then:  skarn version"
