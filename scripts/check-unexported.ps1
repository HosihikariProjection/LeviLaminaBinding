param(
    # Not needed to relink; the runtime libraries come from the build output.
    [string]$ServerRoot = "",
    [string]$LlvmRoot = "$env:LOCALAPPDATA\Temp\hosihikari-llvm\clang+llvm-23.1.0-x86_64-pc-windows-msvc",
    [string]$LeviLaminaRoot = "",
    [switch]$Update,
    [switch]$AllowStale
)
if ([string]::IsNullOrWhiteSpace($LeviLaminaRoot)) {
    $LeviLaminaRoot = Join-Path $PSScriptRoot "..\..\..\Third\LeviLamina"
}

$ErrorActionPreference = "Stop"

# The export list only means something against the carrier it was taken from. A stale list
# does not fail loudly on its own: entries that no longer appear just cost unnecessary stubs,
# and a member the new carrier stopped exporting reproduces the link failure the list exists
# to prevent. This re-derives the truth from a real link and reports both directions.

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$LeviLaminaRoot = (Resolve-Path $LeviLaminaRoot).Path
$ListPath = Join-Path $RepoRoot "..\Binding.Generator\src\Hosihikari.Binding.Generator\unexported-levilamina.txt"
$ListPath = [System.IO.Path]::GetFullPath($ListPath)

$ShimDirectory = Join-Path $RepoRoot "native\BindingShim\generated\win-x64-server\levilamina"
$Object = Join-Path $RepoRoot "artifacts\native\Hosihikari.Binding.LeviLamina.Shim.obj"

$CarrierLibrary = Join-Path $LeviLaminaRoot "build\windows\x64\release\LeviLamina.lib"
if (-not (Test-Path $CarrierLibrary)) {
    throw "LeviLamina.lib was not found at $CarrierLibrary."
}

# The prelink output is what the real link resolves against; without it the runtime half of
# the carrier is missing and every game symbol looks undefined.
$RuntimeLibrary = Join-Path $RepoRoot "artifacts\native\prelink\lib\bedrock_runtime_api.lib"
if (-not (Test-Path $RuntimeLibrary)) {
    throw "bedrock_runtime_api.lib is missing; run native/BindingShim/build.ps1 first."
}

$ClangCl = Join-Path $LlvmRoot "bin\clang-cl.exe"

# build.ps1 deletes the object once it has linked, so the check compiles its own. It has to be
# the same translation unit the build compiles; a stale one would check a different surface.
if (-not (Test-Path $Object) -or (Get-Item $Object).LastWriteTime -lt (Get-Item (Join-Path $ShimDirectory "binding_table.cpp")).LastWriteTime) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Object) | Out-Null
    Push-Location (Join-Path $RepoRoot "native\BindingShim")
    try {
        & (Join-Path $RepoRoot "..\Binding.Generator\frontend\build-shim.ps1") `
            -ShimDirectory $ShimDirectory `
            -OutputDll $Object `
            -LlvmRoot $LlvmRoot `
            -LeviLaminaRoot $LeviLaminaRoot `
            -CompileOnly
        if ($LASTEXITCODE -ne 0) { throw "clang-cl exited with $LASTEXITCODE." }
    } finally {
        Pop-Location
    }
}

$Log = Join-Path $RepoRoot "artifacts\native\unexported-check.log"
$FmtLib = Get-ChildItem "$env:LOCALAPPDATA\.xmake\packages\f\fmt" -Recurse -Filter fmt.lib -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $FmtLib) {
    throw "fmt.lib was not found; pass a carrier that pins fmt, or build first."
}

$PreviousPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& $ClangCl /LD /MD $Object $CarrierLibrary $FmtLib.FullName $RuntimeLibrary /Fe:(Join-Path $RepoRoot "artifacts\native\unexported-check.dll") /link /DELAYLOAD:bedrock_runtime.dll delayimp.lib "/ERRORLIMIT:0" 2>&1 |
    Out-File -FilePath $Log -Encoding utf8
# A failed link is the normal case here — that is what the check looks for.
$ErrorActionPreference = $PreviousPreference

$Undefined = Select-String -Path $Log -Pattern 'undefined symbol: (.+)$' |
    ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() } |
    Sort-Object -Unique

# Only the classes this list covers; the carrier-free fixture and third-party libraries have
# their own reasons for missing symbols.
$Covered = '^(public|private|protected)?:?.*\b(Actor|Player|ServerPlayer|ExpressionNode|CommonResourceDefinitionMap|AnimationScriptsDescription|ActorAnimationControllerPtr|ActorSkeletalAnimationPtr)::'

$OnSurface = $Undefined | Where-Object { $_ -match $Covered }
$InList = @{}
foreach ($line in Get-Content $ListPath) {
    $columns = $line -split "`t"
    if ($columns.Count -lt 2) { continue }
    $InList[$columns[1]] = $columns[0]
}

$Missing = $OnSurface | Where-Object { -not $InList.ContainsKey($_) }
$Gone = $InList.Keys | Where-Object { $OnSurface -notcontains $_ }

Write-Output "undefined on the covered classes: $($OnSurface.Count)"
Write-Output "in the list: $($InList.Count)"

if ($Missing.Count -eq 0 -and $Gone.Count -eq 0) {
    Write-Output "The export list matches the link."
    exit 0
}

# A listed member produces no reference at all — it is refused — so it can never show up as
# undefined. `Gone` therefore only means "nothing references this any more", which is normal
# for entries whose class left the surface. Only `Missing` is a hard signal: it is a member
# that reaches the link and has no entry, so the list is behind and the build would fail.
if ($Missing.Count -eq 0) {
    Write-Output "Nothing undefined outside the list; the list has $($Gone.Count) entries with no current reference."
    exit 0
}

if ($Missing.Count -gt 0) {
    Write-Output ""
    Write-Output "Not in the list ($($Missing.Count)) - the link would fail:"
    $Missing | ForEach-Object { Write-Output "  $_" }
}
if ($Gone.Count -gt 0) {
    Write-Output ""
    Write-Output "In the list but no longer undefined ($($Gone.Count)):"
    $Gone | ForEach-Object { Write-Output "  $_" }
}

if (-not $Update) {
    Write-Output ""
    Write-Output "Re-run with -Update to fold these in."
    if (-not $AllowStale) { exit 1 }
    exit 0
}

$Header = Get-Content $ListPath | Where-Object { $_ -match '^#' -or $_ -eq "" }
# Everything already listed stays listed. A listed member is refused, so it never reaches the
# link again — dropping the entries that are not undefined right now would empty the list on
# the first clean run.
$Body = @{}
foreach ($pair in $InList.GetEnumerator()) { $Body[$pair.Key] = $pair.Value }
# A member that is new here has no recorded kind. Default it to absent, which refuses; the
# spelling/signature split needs the classification pass to be re-run.
foreach ($symbol in $Missing) {
    if (-not $Body.ContainsKey($symbol)) { $Body[$symbol] = "absent" }
}

$Body.GetEnumerator() |
    Sort-Object { $_.Value }, { $_.Key } |
    ForEach-Object { "$($_.Value)`t$($_.Key)" } |
    Set-Content -Path $ListPath -Encoding utf8
$Header | Set-Content -Path $ListPath -Encoding utf8
Get-Content $ListPath | Out-Null

$Sorted = @($Header) + @($Body.GetEnumerator() | Sort-Object { $_.Value }, { $_.Key } | ForEach-Object { "$($_.Value)`t$($_.Key)" })
[System.IO.File]::WriteAllLines($ListPath, $Sorted, (New-Object System.Text.UTF8Encoding($false)))

# The generator picks the list up through a CopyToOutputDirectory rule that compares
# timestamps. Writing in place can land an older one — a `cp` that preserves mtime does it
# every time — and the next emit then reconciles against the previous copy without saying so.
(Get-Item $ListPath).LastWriteTime = Get-Date

Write-Output ""
Write-Output "Rewrote $ListPath"
Write-Output "Re-run the regenerate after this: the surface still matches the old list."
