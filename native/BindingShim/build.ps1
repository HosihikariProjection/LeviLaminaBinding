param(
    [string]$LeviLaminaRoot = "",
    [string]$GeneratorRoot = "",
    [string]$LlvmRoot = "$env:LOCALAPPDATA\Temp\hosihikari-llvm\clang+llvm-23.1.0-x86_64-pc-windows-msvc",
    [string]$FmtLib = "",
    [string]$Output = "artifacts/native"
)
if ([string]::IsNullOrWhiteSpace($LeviLaminaRoot)) {
    $LeviLaminaRoot = Join-Path $PSScriptRoot "..\..\..\Third\LeviLamina"
}

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if ([string]::IsNullOrWhiteSpace($GeneratorRoot)) {
    $GeneratorRoot = (Resolve-Path (Join-Path $RepoRoot "..\Binding.Generator")).Path
} else {
    $GeneratorRoot = (Resolve-Path $GeneratorRoot).Path
}
$LeviLaminaRoot = (Resolve-Path $LeviLaminaRoot).Path
$Output = if ([System.IO.Path]::IsPathRooted($Output)) { $Output } else { Join-Path $RepoRoot $Output }
New-Item -ItemType Directory -Force -Path $Output | Out-Null

$ShimDirectory = Join-Path $PSScriptRoot "generated\win-x64-server\levilamina"
if (-not (Test-Path (Join-Path $ShimDirectory "binding_table.cpp"))) {
    throw "Generated BindingShim sources are missing under $ShimDirectory."
}

$CarrierImportLibrary = Join-Path $LeviLaminaRoot "build\windows\x64\release\LeviLamina.lib"
if (-not (Test-Path $CarrierImportLibrary)) {
    throw "LeviLamina.lib was not found at $CarrierImportLibrary."
}

if ([string]::IsNullOrWhiteSpace($FmtLib)) {
    # The carrier pins the fmt version; match that pin instead of taking whichever package
    # the directory walk reaches first.
    $CarrierLuaForFmt = Join-Path $LeviLaminaRoot "xmake.lua"
    if (-not (Test-Path $CarrierLuaForFmt)) {
        throw "$CarrierLuaForFmt was not found, so the pinned fmt version is unknown; pass -FmtLib explicitly."
    }
    $FmtPinMatch = Select-String -Path $CarrierLuaForFmt -Pattern 'add_requires\("fmt\s+([0-9][^\s"]*)"\)' | Select-Object -First 1
    if (-not $FmtPinMatch) {
        throw "$CarrierLuaForFmt does not pin fmt; pass -FmtLib explicitly."
    }
    $FmtVersion = $FmtPinMatch.Matches[0].Groups[1].Value
    # Filter the candidates the same way as the runtime data, so a package directory carrying
    # a "+sha" suffix still matches; a pin that itself names build metadata settles on its base.
    $FmtBaseVersion = ($FmtVersion -split '\+')[0]
    $FmtPinnedPattern = [regex]::Escape($FmtBaseVersion) + '(?:[+]|' + [regex]::Escape([string][IO.Path]::DirectorySeparatorChar) + ')'
    $Fmt = Get-ChildItem "$env:LOCALAPPDATA\.xmake\packages\f\fmt" -Recurse -Filter fmt.lib -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match $FmtPinnedPattern } |
        Select-Object -First 1
    if (-not $Fmt) {
        throw "fmt $FmtVersion is pinned by the carrier but fmt.lib is not installed; pass -FmtLib explicitly."
    }

    $FmtLib = $Fmt.FullName
} else {
    $FmtLib = (Resolve-Path $FmtLib).Path
}

& (Join-Path $GeneratorRoot "frontend\build-carrier-shim.ps1") `
    -ShimDirectory $ShimDirectory `
    -OutputDll (Join-Path $Output "Hosihikari.Binding.LeviLamina.Shim.dll") `
    -LlvmRoot $LlvmRoot `
    -LeviLaminaRoot $LeviLaminaRoot `
    -CarrierImportLibrary $CarrierImportLibrary `
    -FmtLib $FmtLib
