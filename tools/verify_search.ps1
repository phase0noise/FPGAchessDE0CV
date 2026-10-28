param(
    [string]$Python,
    [string]$Ghdl,
    [switch]$Strength
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/common.ps1"
$Python = Resolve-ProjectPython $Python
if (-not $Ghdl) {
    $command = Get-Command ghdl -ErrorAction SilentlyContinue
    if ($command) { $Ghdl = $command.Source }
    else { $Ghdl = Join-Path $projectRoot '.cache/tools/ghdl/bin/ghdl.exe' }
}
if (-not (Test-Path -LiteralPath $Ghdl)) { throw 'GHDL not found. Run tools/setup_test_tools.ps1 or pass -Ghdl.' }
Push-Location $projectRoot
try {
    New-Item -ItemType Directory .cache/ghdl-search -Force | Out-Null
    $resultRoot = Join-Path $projectRoot '.cache'
    if (-not (Test-Path python/.cache/chess_vectors.txt)) {
        & $Python python/run.py fixtures --count 128
        if ($LASTEXITCODE -ne 0) { throw 'Independent rule fixtures failed.' }
    }
    & $Python python/run.py search-fixtures
    if ($LASTEXITCODE -ne 0) { throw 'Tactical fixtures failed.' }
    $sources = @('rtl/chess_pkg.vhd','rtl/chess_cell_memory.vhd','rtl/chess_spatial.vhd',
        'sim/chess_spatial_fast.vhd','rtl/chess_search_memory.vhd','rtl/chess_see.vhd','rtl/chess_engine.vhd',
        'sim/tb_chess_engine.vhd','sim/tb_chess_spatial.vhd')
    & $Ghdl -a --std=08 --workdir=.cache/ghdl-search @sources
    if ($LASTEXITCODE -ne 0) { throw 'Search model analysis failed.' }
    # This model only accelerates simulation. Compare every source square with
    # the production wired attack fabric before using it for long searches.
    & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_spatial '-gVECTOR_FILE=python/.cache/chess_vectors.txt' --assert-level=error
    if ($LASTEXITCODE -ne 0) { throw 'Spatial model equivalence failed.' }
    & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_engine '-gVECTOR_FILE=python/.cache/search_vectors.txt' -gSEARCH_DEPTH=3 -gCLOCK_DIVIDE=4 --assert-level=error
    if ($LASTEXITCODE -ne 0) { throw 'Existing tactical regression failed.' }
    $tactics = Get-Content python/.cache/search_vectors.txt
    @($tactics[4], $tactics[8]) | Set-Content python/.cache/cache_vectors.txt
    foreach ($cache in @(1,0)) {
        $log = ".cache/cache-$cache.log"
        & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_engine '-gVECTOR_FILE=python/.cache/cache_vectors.txt' -gSEARCH_DEPTH=3 -gCLOCK_DIVIDE=4 -gDETERMINISTIC=true -gROOT_PVS=false -gROOT_ORDERING=false "-gCACHE_ENABLE=$cache" --assert-level=error *> $log
        if ($LASTEXITCODE -ne 0) { Get-Content $log -Tail 20; throw 'Cache regression failed.' }
    }
    & $Python python/run.py check-cache "$resultRoot/cache-1.log" "$resultRoot/cache-0.log"
    if ($LASTEXITCODE -ne 0) { throw 'Cache comparison failed.' }
    foreach ($fast in @('true','false')) {
        $log = ".cache/destinations-$fast.log"
        & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_engine '-gVECTOR_FILE=python/.cache/cache_vectors.txt' -gSEARCH_DEPTH=3 -gCLOCK_DIVIDE=4 -gDETERMINISTIC=true "-gFAST_DESTINATIONS=$fast" --assert-level=error *> $log
        if ($LASTEXITCODE -ne 0) { Get-Content $log -Tail 20; throw 'Destination scan regression failed.' }
    }
    & $Python python/run.py check-destinations "$resultRoot/destinations-true.log" "$resultRoot/destinations-false.log"
    if ($LASTEXITCODE -ne 0) { throw 'Destination scan comparison failed.' }
    foreach ($variant in @(@(1,'false',1),@(8,'false',1),@(8,'true',1),@(8,'true',2))) {
        $lanes=$variant[0];$sources=$variant[1];$pawns=$variant[2];$log=".cache/parallel-$lanes-$sources-$pawns.log"
        & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_engine '-gVECTOR_FILE=python/.cache/cache_vectors.txt' -gSEARCH_DEPTH=3 -gCLOCK_DIVIDE=4 -gDETERMINISTIC=true "-gSTACK_LANES=$lanes" "-gFAST_SOURCES=$sources" "-gPAWN_LANES=$pawns" --assert-level=error *> $log
        if ($LASTEXITCODE -ne 0) { Get-Content $log -Tail 20; throw 'Parallel datapath regression failed.' }
    }
    # Search the independent castling/en-passant/promotion/check fixtures as
    # well as merely generating their root moves. This repeatedly exercises
    # packed board restores after special moves inside the speculative tree.
    foreach ($reference in @('true','false')) {
        $lanes=8;$sources='true';$pawns=2
        if ($reference -eq 'true') { $lanes=1;$sources='false';$pawns=1 }
        $log=".cache/parallel-special-$reference.log"
        & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_engine '-gVECTOR_FILE=python/.cache/chess_vectors.txt' -gSEARCH_DEPTH=2 -gQUIESCENCE=0 -gPOSITION_COUNT=19 -gCLOCK_DIVIDE=4 -gDETERMINISTIC=true "-gSTACK_LANES=$lanes" "-gFAST_SOURCES=$sources" "-gPAWN_LANES=$pawns" --assert-level=error *> $log
        if ($LASTEXITCODE -ne 0) { Get-Content $log -Tail 20; throw 'Parallel special-move search regression failed.' }
    }
    & $Python python/run.py check-parallel "$resultRoot/parallel-8-true-2.log" "$resultRoot/parallel-1-false-1.log" --wide-only "$resultRoot/parallel-8-false-1.log" --source-mask "$resultRoot/parallel-8-true-1.log" --special-parallel "$resultRoot/parallel-special-false.log" --special-reference "$resultRoot/parallel-special-true.log"
    if ($LASTEXITCODE -ne 0) { throw 'Parallel datapath comparison failed.' }
    $tactics[8] | Set-Content python/.cache/budget_vectors.txt
    foreach ($budgetClock in @(10000,200000)) {
        & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_engine '-gVECTOR_FILE=python/.cache/budget_vectors.txt' -gSEARCH_DEPTH=8 -gCLOCK_DIVIDE=4 -gBUDGET_SECONDS=1 "-gTEST_CLOCK_HZ=$budgetClock" -gEXPECT_TIMEOUT=true --assert-level=error
        if ($LASTEXITCODE -ne 0) { throw 'Completed-iteration budget/commit regression failed.' }
    }
    & $Python python/run.py depth-fixtures
    if ($LASTEXITCODE -ne 0) { throw 'Depth boundary fixtures failed.' }
    & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_engine '-gVECTOR_FILE=python/.cache/depth_vectors.txt' -gSEARCH_DEPTH=8 -gCLOCK_DIVIDE=4 --assert-level=error
    if ($LASTEXITCODE -ne 0) { throw 'Depth-eight/insufficient-material regression failed.' }
    & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_engine '-gVECTOR_FILE=python/.cache/depth_live_vectors.txt' -gSEARCH_DEPTH=8 -gQUIESCENCE=0 -gEXPECT_MIN_PLY=8 -gDETERMINISTIC=true --assert-level=error *> .cache/depth-live.log
    if ($LASTEXITCODE -ne 0) { Get-Content .cache/depth-live.log -Tail 16; throw 'Live depth-eight stack regression failed.' }
    foreach ($variant in @(@('scalar',1,'false',1),@('lanes',4,'false',1),@('pvs',4,'true',1),@('queue',4,'true',4))) {
        $name=$variant[0];$evalLanes=$variant[1];$pvs=$variant[2];$queueLanes=$variant[3]
        & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_engine '-gVECTOR_FILE=python/.cache/cache_vectors.txt' -gSEARCH_DEPTH=3 -gDETERMINISTIC=true -gCHECK_TACTICS=false -gPOSITION_TERMS=false -gSEE_ORDERING=false "-gEVAL_LANES=$evalLanes" "-gROOT_PVS=$pvs" "-gROOT_ORDERING=$pvs" "-gQUEUE_LANES=$queueLanes" --assert-level=error *> ".cache/advance-$name.log"
        if ($LASTEXITCODE -ne 0) { Get-Content ".cache/advance-$name.log" -Tail 16; throw 'Advanced pipeline/search comparison failed.' }
    }
    foreach ($pvs in @('false','true')) {
        & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_engine '-gVECTOR_FILE=python/.cache/chess_vectors.txt' -gSEARCH_DEPTH=2 -gQUIESCENCE=0 -gPOSITION_COUNT=19 -gDETERMINISTIC=true -gCHECK_TACTICS=false "-gROOT_PVS=$pvs" "-gROOT_ORDERING=$pvs" --assert-level=error *> ".cache/advance-bounds-$pvs.log"
        if ($LASTEXITCODE -ne 0) { Get-Content ".cache/advance-bounds-$pvs.log" -Tail 16; throw 'Special-rule PVS bounds regression failed.' }
    }
    & $Python python/run.py check-advancement --scalar "$resultRoot/advance-scalar.log" --parallel "$resultRoot/advance-lanes.log" --pvs "$resultRoot/advance-pvs.log" --queue "$resultRoot/advance-queue.log" --special-reference "$resultRoot/advance-bounds-false.log" --special-pvs "$resultRoot/advance-bounds-true.log"
    if ($LASTEXITCODE -ne 0) { throw 'PVS value/bound/continuation verification failed.' }
    if ($Strength) {
        & $Python python/run.py strength-fixtures
        if ($LASTEXITCODE -ne 0) { throw 'Independent mate proofs failed.' }
        # Quiet KQ endings require five normal plies. Disable capture extensions
        # here so this benchmark specifically exercises deeper normal search.
        & $Ghdl -r --std=08 --workdir=.cache/ghdl-search tb_chess_engine '-gVECTOR_FILE=python/.cache/strength_vectors.txt' -gSEARCH_DEPTH=5 -gQUIESCENCE=0 -gCLOCK_DIVIDE=4 --assert-level=error *> .cache/strength-expanded.log
        if ($LASTEXITCODE -ne 0) { Get-Content .cache/strength-expanded.log -Tail 20; throw 'Five-ply strength regression failed.' }
        & $Python python/run.py check-strength "$resultRoot/strength-expanded.log"
        if ($LASTEXITCODE -ne 0) { throw 'Independent mate choice check failed.' }
    }
    Write-Host 'PASS: expanded search verification.'
} finally { Pop-Location }
