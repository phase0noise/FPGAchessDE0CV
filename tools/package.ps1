param([string]$Python)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot/common.ps1"
$Python = Resolve-ProjectPython $Python
Push-Location $projectRoot
try {
    & $Python python/run.py check
    if ($LASTEXITCODE -ne 0) { throw 'Consolidated-project validation failed.' }
    $image='output_files/de0cv_chess.sof'
    if (-not (Test-Path -LiteralPath $image)) { throw 'Build the FPGA image first.' }
    $files=@('README.md','.gitignore','.gitattributes','de0cv_chess.qpf','de0cv_chess.qsf','de0cv_chess.sdc',$image)
    foreach ($folder in @('rtl','python','rpi','web','tools','sim','tests','docs')) {
        $files+=Get-ChildItem -LiteralPath $folder -Recurse -File |
            Where-Object { $_.FullName -notmatch '[\\/](?:__pycache__|\.venv)[\\/]|\.pyc$' } |
            ForEach-Object { $_.FullName.Substring($projectRoot.Length+1).Replace('\','/') }
    }
    $hashes=[ordered]@{}
    foreach ($name in ($files | Sort-Object -Unique)) {
        $hashes[$name]=(Get-FileHash -Algorithm SHA256 -LiteralPath $name).Hash.ToLowerInvariant()
    }
    [ordered]@{
        target='DE0-CV / 5CEBA4F23C7'
        project='de0cv_chess.qpf'
        bridge='Raspberry Pi / SPI0 CE0 / mode 0 / default 1 MHz'
        mailboxVersion=3
        engineProtocol=5
        engineClockHz=50000000
        pawnFileLanes=1
        ssid='DE0CV-Chess'
        url='http://10.42.0.1:8080'
        physicalBoardAcceptance='Not performed; see docs/VALIDATION.md'
        sha256=$hashes
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath output_files/build_manifest.json -Encoding UTF8
    $files+='output_files/build_manifest.json'
    $stage=Join-Path $projectRoot ('.cache/release-'+[Guid]::NewGuid().ToString('N')+'/DE0CVChessAdvanced')
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($name in ($files | Sort-Object -Unique)) {
        $destination=Join-Path $stage $name
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $destination
    }
    & $Python python/run.py check $stage --manifest
    if ($LASTEXITCODE -ne 0) { throw 'Standalone release validation failed.' }
    Compress-Archive -LiteralPath $stage -DestinationPath output_files/DE0CVChessAdvanced.zip -Force
    Write-Host "Portable project: $projectRoot/output_files/DE0CVChessAdvanced.zip"
} finally { Pop-Location }
