#Requires -Version 5.1
# PSWinKit installer. Run from a downloaded source tree or a local clone.
# Installs into Get-Location; Common and translations come from this source tree.
# Preserves the original SHA-256 / .new / move workflow; no backup copies.

[CmdletBinding()]
param(
    [string]$Commit = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$target = (Get-Location).ProviderPath
# Executed from the freshly extracted PSWinKit source tree.
# Destination is the caller's current working directory.
. (Join-Path $PSScriptRoot 'Common\Common.ps1')
$fromUpdater = $PSBoundParameters.ContainsKey('Commit')
$utility = $null
if ($fromUpdater) {
    $languageFolder = Join-Path $PSScriptRoot 'Common\Languages'
    $selectedFile = Find-PSWinKitLanguageFile -Folder $languageFolder
    $m = Import-PSWinKitTranslations -Folder $languageFolder -SelectedFile $selectedFile -Section 'install'
}
else {
    $utility = Start-Utility -ScriptPath $PSCommandPath
    if ($null -eq $utility) { return }
    $m = $utility.Messages
}
$versionDateUtc = ''
$versionLabel = $m.UnknownVersion

# An explicit empty -Commit means the updater could not verify the ZIP.
# Without any parameters, resolve the current main commit for direct installation.
if ($Commit -ne '' -and $Commit -notmatch '^[0-9a-fA-F]{40}$') {
    throw $m.InvalidVersion
}
if (-not ($fromUpdater -and $Commit -eq '')) {
    $ref = if ($Commit -ne '') { $Commit } else { 'main' }
    $apiUrl = "https://api.github.com/repos/avmaksimov/PSWinKit/commits/$ref"
    $apiHeaders = @{ 'User-Agent' = 'PSWinKit-Installer'; 'Accept' = 'application/vnd.github+json' }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $remote = Invoke-RestMethod -Uri $apiUrl -Headers $apiHeaders -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        $resolvedCommit = [string]$remote.sha
        $resolvedDate = [string]$remote.commit.committer.date
        if ($resolvedCommit -notmatch '^[0-9a-fA-F]{40}$' -or
            ($Commit -ne '' -and $resolvedCommit -ine $Commit)) {
            throw $m.InvalidVersion
        }
        $parsedDate = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse($resolvedDate, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsedDate)) {
            throw $m.InvalidVersion
        }
        $Commit = $resolvedCommit.ToLowerInvariant()
        $versionDateUtc = $parsedDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
        $versionLabel = '{0} ({1})' -f $parsedDate.ToLocalTime().ToString('G', [Globalization.CultureInfo]::CurrentCulture), $Commit.Substring(0, 8)
    }
    catch {
        # Never write a failed lookup as a verified installed version.
        $Commit = ''
        $versionDateUtc = ''
        Write-Warning ('{0}: {1}' -f $m.UnknownVersion, $_.Exception.Message)
    }
}
$stagedFiles = New-Object 'System.Collections.Generic.List[string]'
$manifest = Join-Path $target 'install.psd1'
$manifestStage = $manifest + '.new'
$failed = $false
$replacementStarted = $false
$manifestStageCreated = $false

# Validate paths recorded in an old state file before they are considered for removal.
function Test-RelativeFileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or [IO.Path]::IsPathRooted($Name)) { return $false }
    if ($Name -match '[:*?"<>|\x00-\x1f]' -or $Name -match '(?:^|[\\/])\.{1,2}(?:[\\/]|$)') { return $false }
    if ($Name -match '(?:^|[\\/])\.' -or $Name -match '[\\/]$') { return $false }
    if ($Name -match '(?:^|[\\/])[^\\/]*[. ](?:[\\/]|$)') { return $false }
    return $true
}

# A reparse point is not necessarily a link: NTFS Data Deduplication uses
# IO_REPARSE_TAG_DEDUP (0x80000013). Read its tag via the built-in fsutil tool.
# This avoids compiling platform-specific C# from PowerShell 5.1.
function Get-PSWinKitReparseTag {
    param([Parameter(Mandatory = $true)][string]$Path)

    $output = @(& fsutil.exe reparsepoint query $Path 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw ('fsutil reparsepoint query failed (exit code {0}): {1}' -f
            $exitCode, ($output -join ' '))
    }
    # The first eight-digit hexadecimal tag in fsutil's output is the reparse tag;
    # the surrounding description may be localized, but the tag never is.
    $match = [regex]::Match(($output -join "`n"), '(?i)\b0x[0-9a-f]{8}\b')
    if (-not $match.Success) { throw 'Reparse tag not found in fsutil output.' }
    return [Convert]::ToUInt32($match.Value.Substring(2), 16)
}

# Reject reparse directories and all reparse files except Windows Data Deduplication.
# Fail closed if the tag cannot be read.
function Assert-PSWinKitSafeFilePathComponent {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$ErrorMessage)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { return }
    if ($item.PSIsContainer) { throw ($ErrorMessage -f $Path) }
    try {
        $tag = Get-PSWinKitReparseTag -Path $Path
    }
    catch {
        throw ('{0} (reparse tag read failed: {1})' -f ($ErrorMessage -f $Path), $_.Exception.Message)
    }
    if ($tag -ne [Convert]::ToUInt32('80000013', 16)) {
        throw ('{0} (reparse tag 0x{1:X8})' -f ($ErrorMessage -f $Path), [uint32]$tag)
    }
}

function Get-TargetFile {
    param([string]$Name)
    if (-not (Test-RelativeFileName -Name $Name)) { throw ($m.InvalidPath -f $Name) }
    $destination = [IO.Path]::GetFullPath((Join-Path $target $Name))
    $root = [IO.Path]::GetFullPath($target).TrimEnd('\') + '\'
    if (-not $destination.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw ($m.InvalidPath -f $Name)
    }
    # Disallow replacing or deleting files through junctions / symbolic links.
    $relative = $destination.Substring($root.Length)
    $current = $root
    foreach ($part in ($relative -split '\\')) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            Assert-PSWinKitSafeFilePathComponent -Path $current -ErrorMessage $m.LinkPath
        }
    }
    return $destination
}

try {
    $targetRoot = Get-Item -LiteralPath $target -Force -ErrorAction Stop
    if (($targetRoot.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw ($m.LinkPath -f $target)
    }
    $sourceRoot = $PSScriptRoot.TrimEnd('\')
    Write-Host $m.ComparingFiles
    # Find all repository files, including nested folders; omit dot-prefixed
    # items, this installer and the locally generated install.psd1.
    $sourceFiles = @(
        Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force -ErrorAction Stop |
            Where-Object {
                $relative = $_.FullName.Substring($sourceRoot.Length).TrimStart('\')
                $relative -notmatch '(?:^|[\\/])\.' -and $relative -ine 'install.ps1' -and $relative -ine 'install.psd1'
            } |
            Sort-Object { $_.FullName.Substring($sourceRoot.Length).TrimStart('\') }
    )
    if ($sourceFiles.Count -eq 0) { throw $m.NoSourceFiles }

    $entries = @()
    $changes = @()
    $newNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($sourceFile in $sourceFiles) {
        if (($sourceFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Assert-PSWinKitSafeFilePathComponent -Path $sourceFile.FullName -ErrorMessage $m.SourceLink
        }
        $name = $sourceFile.FullName.Substring($sourceRoot.Length).TrimStart('\')
        if (-not (Test-RelativeFileName -Name $name)) { throw ($m.InvalidPath -f $name) }
        if (-not $newNames.Add($name)) { throw ($m.DuplicatePath -f $name) }
        $from = $sourceFile.FullName
        $to = Get-TargetFile -Name $name
        if (Test-Path -LiteralPath $to -PathType Container) {
            throw ($m.TargetIsDirectory -f $to)
        }
        $newHash = (Get-FileHash -LiteralPath $from -Algorithm SHA256).Hash
        $state = if (-not (Test-Path -LiteralPath $to -PathType Leaf)) {
            'INSTALL'
        } elseif ((Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash -ine $newHash) {
            'REPLACE'
        } else {
            'UNCHANGED'
        }
        $entry = [pscustomobject]@{ Name=$name; Source=$from; Target=$to; Hash=$newHash; State=$state }
        $entries += $entry
        if ($state -ne 'UNCHANGED') { $changes += $entry }
    }

    # Read the old list only to find obsolete files. Missing, empty, malformed
    # or unreadable state means no removals; it never prevents an update.
    $oldNames = @()
    $oldValid = $false
    $oldCommit = ''
    $oldCommitDate = ''
    $oldInfoExists = $false
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        try {
            $data = Import-PowerShellDataFile -LiteralPath $manifest -ErrorAction Stop
            if ($data -is [hashtable] -and $data.ContainsKey('install-info')) {
                $oldInfoExists = $true
                $oldInfo = $data['install-info']
                if ($oldInfo -is [hashtable]) {
                    $oldCommit = [string]$oldInfo['Commit']
                    $oldCommitDate = [string]$oldInfo['CommitDate']
                }
            }
            $value = $data['installed-files']
            if ($value -is [array] -and $value.Count -gt 0) {
                $oldSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                foreach ($oldName in $value) {
                    if (-not ($oldName -is [string]) -or -not (Test-RelativeFileName -Name $oldName) -or
                        $oldName -ieq 'install.psd1' -or $oldName -ieq 'install.ps1' -or -not $oldSet.Add($oldName)) {
                        throw $m.InvalidManifestEntry
                    }
                }
                $oldNames = @($value)
                $oldValid = $true
            }
        }
        catch {
            Write-Host ($m.InvalidManifest -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    $removals = @()
    if ($oldValid) {
        try {
            foreach ($oldName in $oldNames) {
                if ($newNames.Contains($oldName)) { continue }
                $oldPath = Get-TargetFile -Name $oldName
                if (Test-Path -LiteralPath $oldPath -PathType Container) {
                    throw ($m.TargetIsDirectory -f $oldPath)
                }
                if (Test-Path -LiteralPath $oldPath -PathType Leaf) {
                    $removals += [pscustomobject]@{ Name=$oldName; Target=$oldPath; State='REMOVE' }
                }
            }
        }
        catch {
            Write-Host ($m.InvalidManifest -f $_.Exception.Message) -ForegroundColor Yellow
            $removals = @()
            $oldValid = $false
            $oldNames = @()
        }
    }

    # The state file is rewritten when missing or when its inventory changed.
    $manifestChanged = -not $oldValid -or $oldNames.Count -ne $newNames.Count
    # Update metadata even if the file list is identical. Empty values explicitly
    # mean that the ZIP was installed without verified GitHub commit metadata.
    if (-not $oldInfoExists -or $oldCommit -ine $Commit -or $oldCommitDate -cne $versionDateUtc) {
        $manifestChanged = $true
    }
    if (-not $manifestChanged) {
        foreach ($entry in $entries) {
            if (-not $oldSet.Contains($entry.Name)) { $manifestChanged = $true; break }
        }
    }
    if (Test-Path -LiteralPath $manifestStage) { throw ($m.StageExists -f $manifestStage) }
    $metadataOnly = $changes.Count -eq 0 -and $removals.Count -eq 0
    Write-Host ''
    if ($metadataOnly -and -not $manifestChanged) {
        Write-Host $m.UpToDate -ForegroundColor Green
        return
    }

    if (-not $metadataOnly) {
        $installCount = @($changes | Where-Object { $_.State -eq 'INSTALL' }).Count
        $replaceCount = @($changes | Where-Object { $_.State -eq 'REPLACE' }).Count
        $unchangedCount = $entries.Count - $changes.Count
        Write-Host $m.SummaryTitle -ForegroundColor Cyan
        Write-Host ($m.Destination -f $target) -ForegroundColor Gray
        Write-Host ($m.Version -f $versionLabel) -ForegroundColor Gray
        Write-Host ''
        Write-Host ($m.ChangeCounts -f $installCount, $replaceCount, $removals.Count, $unchangedCount) -ForegroundColor Gray
        Write-Host ''
        Write-Host $m.StateLegend -ForegroundColor DarkGray
        Write-Host ''
        foreach ($item in @($entries) + @($removals)) {
            $stateColor = switch ($item.State) {
                'INSTALL' { 'Green' }
                'REPLACE' { 'Yellow' }
                'REMOVE' { 'Red' }
                default { 'DarkGray' }
            }
            Write-Host ("  {0,-11}" -f $item.State) -ForegroundColor $stateColor -NoNewline
            $nameColor = if ($item.State -eq 'UNCHANGED') { 'DarkGray' } else { 'White' }
            Write-Host $item.Name -ForegroundColor $nameColor
        }
        Write-Host ''
        Write-Host $m.ChangeNotice -ForegroundColor Gray
        Write-Host $m.NoBackups -ForegroundColor Gray
        Write-Host ''
        $choice = (Read-Host $m.Confirm).Trim().ToUpperInvariant()
        if ($choice -cne 'Y') {
            Write-Host $m.Canceled
            return
        }

        # Stage every changed file beside its destination; then replace via move.
        # Nothing is removed before every staged SHA-256 has been verified.
        foreach ($item in $changes) {
            $parentDir = Split-Path -Path $item.Target -Parent
            if (-not (Test-Path -LiteralPath $parentDir -PathType Container)) {
                New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction Stop | Out-Null
            }
            $staged = $item.Target + '.new'
            if (Test-Path -LiteralPath $staged) { throw ($m.StageExists -f $staged) }
            $stagedFiles.Add($staged)
            Copy-Item -LiteralPath $item.Source -Destination $staged -ErrorAction Stop
            if ((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash -ine $item.Hash) {
                throw ($m.HashMismatch -f $staged)
            }
        }
        # Replace the updater last; its running code is already loaded in memory.
        foreach ($item in @($changes | Where-Object { $_.Name -ine 'update.ps1' }) +
                         @($changes | Where-Object { $_.Name -ieq 'update.ps1' })) {
            $staged = $item.Target + '.new'
            $replacementStarted = $true
            Move-Item -LiteralPath $staged -Destination $item.Target -Force -ErrorAction Stop
            $verb = if ($item.State -eq 'INSTALL') { $m.Installed } else { $m.Replaced }
            Write-Host ("${verb}: $($item.Name)") -ForegroundColor Green
        }
        foreach ($item in $removals) {
            $replacementStarted = $true
            Remove-Item -LiteralPath $item.Target -Force -ErrorAction Stop
            Write-Host ($m.Removed -f $item.Name) -ForegroundColor Green
        }

    }

    # A machine-written PSD1 inventory: no SHA-256, and no inventory of its own.
    # The state file is committed last; failure leaves the previous state intact.
    $stateLines = @('@{', "    'installed-files' = @(")
    foreach ($entry in ($entries | Sort-Object Name)) {
        $quoted = $entry.Name.Replace("'", "''")
        $stateLines += "        '$quoted'"
    }
    $stateLines += '    )'
    $stateLines += "    'install-info' = @{"
    $stateLines += "        Commit = '$Commit'"
    $stateLines += "        CommitDate = '$versionDateUtc'"
    $stateLines += '    }'
    $stateLines += '}'
    if (Test-Path -LiteralPath $manifestStage) { throw ($m.StageExists -f $manifestStage) }
    $manifestStageCreated = $true
    [IO.File]::WriteAllText($manifestStage, (($stateLines -join "`r`n") + "`r`n"), ([Text.UTF8Encoding]::new($true)))
    $replacementStarted = $true
    Move-Item -LiteralPath $manifestStage -Destination $manifest -Force -ErrorAction Stop
    Write-Host ''
    if ($metadataOnly) {
        Write-Host $m.UpToDate -ForegroundColor Green
    }
    else {
        Write-Host $m.Completed -ForegroundColor Green
    }
}
catch {
    $failed = $true
    Write-Host ''
    Write-Host ($m.UpdateError -f $_.Exception.Message) -ForegroundColor Red
    if ($replacementStarted) { Write-Host $m.PartialWarning -ForegroundColor Yellow }
}
finally {
    foreach ($path in $stagedFiles) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
    if ($manifestStageCreated -and (Test-Path -LiteralPath $manifestStage -PathType Leaf)) {
        Remove-Item -LiteralPath $manifestStage -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $utility) { Stop-Utility -Utility $utility }
}
if ($failed) { throw $m.Failed }
