param([string]$Quartus)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"
if (-not $Quartus) { $Quartus = Resolve-QuartusTool -Name quartus_sh }
else { $Quartus = (Get-Command $Quartus -ErrorAction Stop).Source }
$projectRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $projectRoot ('.cache/fpga-build-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $buildRoot,(Join-Path $buildRoot 'rtl'),(Join-Path $buildRoot 'tools'),(Join-Path $buildRoot '.cache') -Force | Out-Null
$inputs = @('de0cv_chess.qpf','de0cv_chess.qsf','de0cv_chess.sdc','tools/check_timing.tcl')
$inputs += Get-ChildItem -LiteralPath (Join-Path $projectRoot 'rtl') -File | ForEach-Object { 'rtl/' + $_.Name }
foreach ($name in $inputs) { Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination (Join-Path $buildRoot $name) }
Set-Content -LiteralPath (Join-Path $projectRoot '.cache/fpga-last-build.txt') -Value $buildRoot
Write-Host "Isolated FPGA candidate: $buildRoot"
$mappedDrive = $null
$pushed = $false
try {
    # Same workaround as the scope example for Quartus below Documents.
    foreach ($letter in @('Q','R','S','T','U','V','W','X','Y','Z')) {
        $candidate = "${letter}:"
        if (-not (Test-Path "${candidate}\\")) {
            & subst.exe $candidate $buildRoot
            if ($LASTEXITCODE -eq 0) { $mappedDrive = $candidate; break }
        }
    }
    if (-not $mappedDrive) { throw 'No free drive letter for the Quartus build.' }
    Push-Location "${mappedDrive}\\"
    $pushed = $true
    & $Quartus --flow compile de0cv_chess
    if ($LASTEXITCODE -ne 0) { throw 'Quartus compilation failed.' }
    # Fail a release if any operating-condition setup/hold/recovery/removal
    # path misses timing; the Tcl script also rejects missing clock coverage.
    & (Join-Path (Split-Path $Quartus) 'quartus_sta.exe') -t tools/check_timing.tcl
    if ($LASTEXITCODE -ne 0) { throw 'Timing acceptance failed. Do not program this build.' }
    $report = Get-Content output_files/de0cv_chess.sta.rpt -Raw
    $coverage = [regex]::Matches($report, ';\s*(Illegal Clocks|Unconstrained Clocks|Unconstrained Input Ports|Unconstrained Output Ports)\s*;\s*(\d+)\s*;\s*(\d+)\s*;')
    if ($coverage.Count -ne 4) { throw 'Timing coverage summary is missing.' }
    foreach ($row in $coverage) {
        if ([int]$row.Groups[2].Value -ne 0 -or [int]$row.Groups[3].Value -ne 0) {
            throw "Incomplete timing coverage: $($row.Groups[1].Value)"
        }
    }
    # Publish only a qualified candidate made from the still-current inputs.
    foreach ($name in $inputs) {
        if ((Get-FileHash -LiteralPath (Join-Path $projectRoot $name)).Hash -ne (Get-FileHash -LiteralPath (Join-Path $buildRoot $name)).Hash) {
            throw "Build input changed during compilation: $name. Candidate retained; rebuild before publishing."
        }
    }
    New-Item -ItemType Directory -Path (Join-Path $projectRoot 'output_files') -Force | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $buildRoot 'output_files') -File | Copy-Item -Destination (Join-Path $projectRoot 'output_files')
    Get-ChildItem -LiteralPath (Join-Path $buildRoot '.cache') -Filter 'critical-*.rpt' | Copy-Item -Destination (Join-Path $projectRoot '.cache')
    Write-Host "FPGA image: $projectRoot/output_files/de0cv_chess.sof"
} finally {
    if ($pushed) { Pop-Location }
    if ($mappedDrive) { & subst.exe $mappedDrive /d | Out-Null }
}
