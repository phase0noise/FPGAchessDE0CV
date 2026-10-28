param(
    [string]$Python,
    [string]$Node,
    [string]$Ghdl,
    [int]$Positions = 128,
    [switch]$SkipSearch,
    [switch]$Strength,
    [switch]$Browser
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/common.ps1"
$Python = Resolve-ProjectPython $Python
if (-not $Node) {
    $command = Get-Command node -ErrorAction SilentlyContinue
    if ($command) { $Node = $command.Source }
    elseif ($env:ProgramFiles -and (Test-Path (Join-Path $env:ProgramFiles 'Microsoft VS Code/Code.exe'))) {
        $Node = Join-Path $env:ProgramFiles 'Microsoft VS Code/Code.exe'
        $env:ELECTRON_RUN_AS_NODE = '1'
    } else { throw 'Node.js not found. Pass -Node.' }
}
if (-not $Ghdl) {
    $command = Get-Command ghdl -ErrorAction SilentlyContinue
    if ($command) { $Ghdl = $command.Source }
    else { $Ghdl = Join-Path $projectRoot '.cache/tools/ghdl/bin/ghdl.exe' }
}
if (-not (Test-Path -LiteralPath $Ghdl)) { throw 'GHDL not found. Run tools/setup_test_tools.ps1 or pass -Ghdl.' }
Push-Location $projectRoot
try {
    New-Item -ItemType Directory -Path .cache/ghdl -Force | Out-Null
    & $Python python/run.py check
    if ($LASTEXITCODE -ne 0) { throw 'Standalone project check failed.' }
    & $Python python/run.py test
    if ($LASTEXITCODE -ne 0) { throw 'Pi SPI/server checks failed.' }
    & $Python python/run.py fixtures --count $Positions
    if ($LASTEXITCODE -ne 0) { throw 'Independent fixtures failed. Install python-chess.' }
    & $Node tests/rules.test.cjs .cache/rules.json | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Browser rule comparison failed.' }
    & $Node tests/fpga.test.cjs | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Browser protocol/verification checks failed.' }
    $sources = @('rtl/chess_pkg.vhd','rtl/chess_cell_memory.vhd','rtl/chess_spatial.vhd',
        'rtl/chess_search_memory.vhd','rtl/chess_see.vhd','rtl/chess_engine.vhd',
        'rtl/spi_target.vhd','rtl/chess_spi_bridge.vhd','rtl/de0cv_chess.vhd',
        'sim/tb_spi_target.vhd','sim/tb_de0cv_chess.vhd','sim/tb_chess_engine.vhd',
        'sim/tb_chess_arithmetic.vhd','sim/tb_chess_search_memory.vhd','sim/tb_chess_see.vhd')
    & $Ghdl -a --std=08 --workdir=.cache/ghdl @sources
    if ($LASTEXITCODE -ne 0) { throw 'VHDL analysis failed.' }
    foreach ($bench in @('tb_chess_arithmetic','tb_chess_search_memory','tb_chess_see','tb_spi_target')) {
        & $Ghdl -r --std=08 --workdir=.cache/ghdl $bench --assert-level=error --stop-time=1ms
        if ($LASTEXITCODE -ne 0) { throw "VHDL check failed: $bench" }
    }
    foreach ($halfPeriod in @(100,500)) {
        & $Ghdl -r --std=08 --workdir=.cache/ghdl tb_de0cv_chess "-gSPI_HALF_NS=$halfPeriod" --assert-level=error
        if ($LASTEXITCODE -ne 0) { throw 'Pin-level SPI/engine integration failed.' }
    }
    & $Ghdl -r --std=08 --workdir=.cache/ghdl tb_chess_engine '-gVECTOR_FILE=.cache/chess_vectors.txt' -gCLOCK_DIVIDE=4 -gPAWN_LANES=1 --assert-level=error
    if ($LASTEXITCODE -ne 0) { throw 'Production VHDL legal-set comparison failed.' }
    if (-not $SkipSearch) { & "$PSScriptRoot/verify_search.ps1" -Python $Python -Ghdl $Ghdl -Strength:$Strength }
    if ($Browser) {
        & $Node tests/browser_smoke.cjs | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Desktop/mobile browser checks failed.' }
    }
    Write-Host 'PASS: advanced DE0-CV / Raspberry Pi SPI port verification.'
} finally { Pop-Location }
