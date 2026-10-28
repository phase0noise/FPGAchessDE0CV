param([string]$Python, [switch]$SkipGhdl)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/common.ps1"
$Python = Resolve-ProjectPython $Python
Push-Location $projectRoot
try {
    New-Item -ItemType Directory -Path .cache/tools -Force | Out-Null
    & $Python python/run.py setup --dev
    if ($LASTEXITCODE -ne 0) { throw 'Installing Python test dependencies failed.' }
    if (-not $SkipGhdl -and -not (Test-Path .cache/tools/ghdl/bin/ghdl.exe)) {
        $ProgressPreference = 'SilentlyContinue'
        $release = Invoke-RestMethod 'https://api.github.com/repos/ghdl/ghdl/releases/tags/v6.0.0'
        $asset = $release.assets | Where-Object { $_.name -eq 'ghdl-mcode-6.0.0-mingw64.zip' } | Select-Object -First 1
        if (-not $asset) { throw 'Portable GHDL asset not found.' }
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile .cache/tools/ghdl.zip -UseBasicParsing
        Expand-Archive -LiteralPath .cache/tools/ghdl.zip -DestinationPath .cache/tools/ghdl -Force
    }
    Write-Host 'Python dependencies are ready in python/.venv/; GHDL is in .cache/tools/.'
} finally { Pop-Location }
