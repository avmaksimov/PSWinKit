#Requires -Version 5.1
# PSWinKit updater: check the latest GitHub commit, download a source ZIP and run install.ps1.
# File comparison, installation and removal of obsolete files belong to install.ps1.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common\Common.ps1')
$utility = Start-Utility -ScriptPath $PSCommandPath
if ($null -eq $utility) { return }
$m = $utility.Messages

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
    Write-Host ($m.Destination -f $target)
    $manifest = Join-Path $target 'install.psd1'
    $state = $null
    $installedVersion = $m.FirstInstallation
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        try {
            $state = Import-PowerShellDataFile -LiteralPath $manifest -ErrorAction Stop
            if ($state -is [hashtable] -and $state.ContainsKey('install-info')) {
                $installedVersion = $m.UnknownVersion
                $info = $state['install-info']
                if ($info -is [hashtable]) {
                    $formatted = Format-CommitVersion -Commit ([string]$info['Commit']) -CommitDate ([string]$info['CommitDate'])
                    if ($formatted) { $installedVersion = $formatted }
                }
            }
        } catch {
            $installedVersion = $m.FirstInstallation
        }
    }
    Write-Host ($m.InstalledVersion -f $installedVersion)
    Write-Host ''
    Write-Host $m.CheckingGitHub
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $url = $branchUrl
    try {
        $remote = Invoke-RestMethod -Uri $apiUrl -Headers $apiHeaders -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        $candidateSha = [string]$remote.sha
        $candidateDate = [string]$remote.commit.committer.date
        $formatted = Format-CommitVersion -Commit $candidateSha -CommitDate $candidateDate
        if (-not $formatted) { throw $m.InvalidCommitMetadata }
        $metadataSha = $candidateSha.ToLowerInvariant()
        Write-Host ($m.LatestVersion -f $formatted)
        if ($installedVersion -ne $m.FirstInstallation -and $installedVersion -ne $m.UnknownVersion -and
            $state -is [hashtable] -and
            $state.ContainsKey('install-info') -and $state['install-info'] -is [hashtable] -and
            $state.ContainsKey('installed-files') -and $state['installed-files'] -is [array] -and
            $state['installed-files'].Count -gt 0 -and
            ([string]$state['install-info']['Commit']) -ieq $metadataSha) {
            Write-Host $m.AlreadyLatest -ForegroundColor Green
            return
        }
        Write-Host $m.NewVersion -ForegroundColor Cyan
        Write-Host ''
        $url = "https://github.com/$owner/$repository/archive/$metadataSha.zip"
    }
    catch {
        $metadataSha = ''
        Write-Host ($m.ApiCheckFailed -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host $m.FallbackZip -ForegroundColor Yellow
    }

    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    Write-Host ($m.Source -f $url)
    Write-Host $m.Downloading
    $downloadUrl = $url + '?cacheBust=' + [guid]::NewGuid().ToString('N')
    Invoke-WebRequest -Uri $downloadUrl -Headers $noCacheHeaders -OutFile $zip -UseBasicParsing -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw $m.ZipMissing }
    Write-Host $m.Extracting
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force -ErrorAction Stop
    $roots = @(Get-ChildItem -LiteralPath $extract -Directory)
    if ($roots.Count -ne 1) { throw $m.InvalidZipRoot }
    $sourceRoot = $roots[0].FullName.TrimEnd('\')
    foreach ($required in @('install.ps1', 'Common\Common.ps1', 'Common\Languages\en.psd1', 'README.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $required) -PathType Leaf)) {
            throw ($m.ZipFileMissing -f $required)
        }
    }
    $installerStarted = $true
    Write-Host ''
    & (Join-Path $sourceRoot 'install.ps1') -Commit $metadataSha
}
catch {
    Write-Host ''
    Write-Host ($m.UpdateError -f $_.Exception.Message) -ForegroundColor Red
    throw
}
finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    # The fresh installer owns the final keypress when launched from Explorer.
    if ($installerStarted) { $utility.PauseOnExit = $false }
    Stop-Utility -Utility $utility
}
