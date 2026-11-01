#Requires -Version 5.1
# PSWinKit bootstrap: download the current source ZIP, then run install.ps1.
# File comparison, installation and cleanup of obsolete files are owned by install.ps1.
# No command-line parameters, no Common dependency.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-ExplorerLaunch {
    try {
        if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { return $false }
        $process = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $PID) -ErrorAction Stop
        if (-not $process -or $process.CommandLine -notmatch '(?i)(?:^|\s)-(?:file|command)\b') { return $false }
        $parent = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $process.ParentProcessId) -ErrorAction Stop
        return ($null -ne $parent -and $parent.Name -ieq 'explorer.exe')
    } catch {
        return $false
    }
}

function Wait-ForExitKey {
    if (-not $script:PauseAtExit) { return }
    try {
        Write-Host ''
        Write-Host 'Press any key to finish...' -ForegroundColor DarkGray
        [void][Console]::ReadKey($true)
    } catch { }
}

$script:PauseAtExit = Test-ExplorerLaunch
$owner = 'avmaksimov'
$repository = 'PSWinKit'
$branch = 'main'
$target = (Get-Location).ProviderPath
$url = "https://github.com/$owner/$repository/archive/refs/heads/$branch.zip"
$downloadUrl = $url + '?cacheBust=' + [guid]::NewGuid().ToString('N')
$noCacheHeaders = @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' }
$tempDir = Join-Path $env:TEMP ('PSWinKit-Update-' + [guid]::NewGuid().ToString('N'))
$zip = Join-Path $tempDir 'source.zip'
$extract = Join-Path $tempDir 'unpacked'
$installerStarted = $false

try {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    Write-Host "Source: $url"
    Write-Host "Destination: $target"
    Write-Host 'Downloading repository ZIP with Invoke-WebRequest...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $downloadUrl -Headers $noCacheHeaders -OutFile $zip -UseBasicParsing -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw 'Downloaded ZIP not found.' }
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force -ErrorAction Stop
    $roots = @(Get-ChildItem -LiteralPath $extract -Directory)
    if ($roots.Count -ne 1) { throw 'Unexpected ZIP root structure.' }
    $sourceRoot = $roots[0].FullName.TrimEnd('\')
    foreach ($required in @('install.ps1', 'Common\Common.ps1', 'Languages\en.psd1', 'README.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $required) -PathType Leaf)) {
            throw "Invalid PSWinKit ZIP: missing $required"
        }
    }
    $installerStarted = $true
    & (Join-Path $sourceRoot 'install.ps1')
}
catch {
    Write-Host ''
    Write-Host ('UPDATE ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    if (-not $installerStarted) { Wait-ForExitKey }
    throw
}
finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
