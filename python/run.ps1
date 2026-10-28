$ErrorActionPreference = 'Stop'
$prefixArguments = @()
if ($env:PYTHON) {
    $interpreter = $env:PYTHON
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    $interpreter = 'py'
    $prefixArguments = @('-3')
} elseif (Get-Command python3 -ErrorAction SilentlyContinue) {
    $interpreter = 'python3'
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $interpreter = 'python'
} else {
    throw 'Install Python 3.10 or newer, or set PYTHON to your interpreter.'
}
& $interpreter @prefixArguments (Join-Path $PSScriptRoot 'run.py') @args
exit $LASTEXITCODE
