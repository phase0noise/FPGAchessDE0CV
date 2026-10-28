function Resolve-ProjectPython {
    param([string]$Python)
    if ($Python) { return $Python }
    if ($env:PYTHON) { return $env:PYTHON }
    foreach ($name in @('py','python3','python')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    throw 'Python 3.10 or newer was not found. Install Python or pass -Python.'
}

function Resolve-QuartusTool {
    param([string]$Name, [string]$Bin)
    if ($Bin) {
        $candidate = Join-Path $Bin ($Name + '.exe')
        if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
        throw "Quartus tool not found: $candidate"
    }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($installRoot in @($env:QUARTUS_ROOTDIR_OVERRIDE, $env:QUARTUS_ROOTDIR)) {
        if (-not $installRoot) { continue }
        foreach ($directory in @('bin64','bin')) {
            $candidate = Join-Path (Join-Path $installRoot $directory) ($Name + '.exe')
            if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
        }
    }
    throw "Quartus tool $Name was not found. Add its bin directory to PATH or set QUARTUS_ROOTDIR."
}
