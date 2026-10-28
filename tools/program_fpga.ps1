param(
    [string]$QuartusBin,
    [string]$Cable = 'USB-Blaster',
    [int]$DeviceIndex = 1
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"
$programmer = Resolve-QuartusTool -Name quartus_pgm -Bin $QuartusBin
$projectRoot = Split-Path -Parent $PSScriptRoot
$image = Join-Path $projectRoot 'output_files/de0cv_chess.sof'
if (-not (Test-Path -LiteralPath $image)) { throw 'Build the FPGA image first.' }
if ($DeviceIndex -lt 1) { throw 'DeviceIndex must be positive.' }
& $programmer -m jtag -c $Cable -o "p;$image@$DeviceIndex"
if ($LASTEXITCODE -ne 0) { throw 'Programming failed. Check the DE0-CV cable and selected JTAG device.' }
Write-Host 'DE0-CV configured in volatile SRAM. Reload the SOF after power cycling.'
