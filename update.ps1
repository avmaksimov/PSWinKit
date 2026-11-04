#Requires -Version 5.1
# PSWinKit bootstrap: check the latest commit, download source ZIP, run install.ps1.
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
$apiUrl = "https://api.github.com/repos/$owner/$repository/commits/$branch"
$branchUrl = "https://github.com/$owner/$repository/archive/refs/heads/$branch.zip"
$noCacheHeaders = @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' }
$apiHeaders = @{ 'User-Agent' = 'PSWinKit-Updater'; 'Accept' = 'application/vnd.github+json' }
$metadataSha = ''

function Format-CommitVersion {
    param([string]$Commit, [string]$CommitDate)
    if ($Commit -notmatch '^[0-9a-fA-F]{40}$') { return $null }
    $date = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse($CommitDate, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$date)) { return $null }
    return ('{0} ({1})' -f $date.ToLocalTime().ToString('G', [Globalization.CultureInfo]::CurrentCulture), $Commit.Substring(0, 8))
}
$tempDir = Join-Path $env:TEMP ('PSWinKit-Update-' + [guid]::NewGuid().ToString('N'))
$zip = Join-Path $tempDir 'source.zip'
$extract = Join-Path $tempDir 'unpacked'
$installerStarted = $false

try {
    Write-Host '=== PSWinKit ===' -ForegroundColor Cyan
    Write-Host "Destination: $target"
    $manifest = Join-Path $target 'install.psd1'
    $state = $null
    $installedVersion = 'First installation'
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        try {
            $state = Import-PowerShellDataFile -LiteralPath $manifest -ErrorAction Stop
            if ($state -is [hashtable] -and $state.ContainsKey('install-info')) {
                $installedVersion = 'Unknown'
                $info = $state['install-info']
                if ($info -is [hashtable]) {
                    $formatted = Format-CommitVersion -Commit ([string]$info['Commit']) -CommitDate ([string]$info['CommitDate'])
                    if ($formatted) { $installedVersion = $formatted }
                }
            }
        } catch {
            $installedVersion = 'First installation'
        }
    }
    Write-Host "Installed version: $installedVersion"
    Write-Host 'Checking the latest commit on GitHub...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $url = $branchUrl
    try {
        $remote = Invoke-RestMethod -Uri $apiUrl -Headers $apiHeaders -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        $candidateSha = [string]$remote.sha
        $candidateDate = [string]$remote.commit.committer.date
        $formatted = Format-CommitVersion -Commit $candidateSha -CommitDate $candidateDate
        if (-not $formatted) { throw 'Invalid commit metadata returned by GitHub.' }
        $metadataSha = $candidateSha.ToLowerInvariant()
        Write-Host "Latest version: $formatted"
        if ($installedVersion -ne 'First installation' -and $installedVersion -ne 'Unknown' -and
            $state -is [hashtable] -and
            $state.ContainsKey('install-info') -and $state['install-info'] -is [hashtable] -and
            $state.ContainsKey('installed-files') -and $state['installed-files'] -is [array] -and
            $state['installed-files'].Count -gt 0 -and
            ([string]$state['install-info']['Commit']) -ieq $metadataSha) {
            Write-Host 'The latest version is already installed. No update required.' -ForegroundColor Green
            return
        }
        Write-Host 'A newer or unverified version is available.' -ForegroundColor Cyan
        $url = "https://github.com/$owner/$repository/archive/$metadataSha.zip"
    }
    catch {
        $metadataSha = ''
        Write-Host ('Could not check the latest commit: ' + $_.Exception.Message) -ForegroundColor Yellow
        Write-Host 'Trying the main branch ZIP; the installed version will be recorded as unknown.' -ForegroundColor Yellow
    }

    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    Write-Host "Source: $url"
    Write-Host 'Downloading repository ZIP with Invoke-WebRequest...'
    $downloadUrl = $url + '?cacheBust=' + [guid]::NewGuid().ToString('N')
    Invoke-WebRequest -Uri $downloadUrl -Headers $noCacheHeaders -OutFile $zip -UseBasicParsing -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw 'Downloaded ZIP not found.' }
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force -ErrorAction Stop
    $roots = @(Get-ChildItem -LiteralPath $extract -Directory)
    if ($roots.Count -ne 1) { throw 'Unexpected ZIP root structure.' }
    $sourceRoot = $roots[0].FullName.TrimEnd('\')
    foreach ($required in @('install.ps1', 'Common\Common.ps1', 'Common\Languages\en.psd1', 'README.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $required) -PathType Leaf)) {
            throw "Invalid PSWinKit ZIP: missing $required"
        }
    }
    $installerStarted = $true
    & (Join-Path $sourceRoot 'install.ps1') -Commit $metadataSha
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
