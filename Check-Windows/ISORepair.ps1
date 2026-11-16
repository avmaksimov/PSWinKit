#requires -Version 5.1
# Check-Windows ISO history, mounted sources and split SWM repair.
# Requires ../Common/ImageCatalog.ps1 and ../Common/InstallationSources.ps1.

$script:RepairISOOrigin = $null
$script:RepairCatalogTouched = $false

function Get-RepairHistoryCandidates {
    param($OsProfile)
    if ($null -eq $OsProfile) { return @() }
    $records = @(Get-PSWinKitImageCatalogEntries)
    $build = 0
    try { $build = ([version]$OsProfile.Version).Build } catch { return @() }
    $matches = New-Object 'System.Collections.Generic.List[object]'
    foreach ($record in $records) {
        if ($record.host -and [string]$record.host -ine $env:COMPUTERNAME) { continue }
        $path = [string]$record.path
        try {
            $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($file.PSIsContainer -or [int64]$file.Length -ne [int64]$record.fileSize -or
                $file.LastWriteTimeUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture) -cne
                [string]$record.lastWriteUtc) { continue }
        } catch { continue }
        $compatible = @($record.indexes | Where-Object {
            [string]$_.editionId -ieq [string]$OsProfile.Edition -and
            [string]$_.architecture -ieq [string]$OsProfile.Architecture -and
            [int]$_.build -eq $build
        })
        if ($compatible.Count -ne 0) { $matches.Add($record) }
    }
    return @($matches.ToArray() | Sort-Object path)
}

function Get-RepairImageFromCatalog {
    param($OsProfile)
    $saved = @(Get-RepairHistoryCandidates -OsProfile $OsProfile)
    if ($saved.Count -eq 0) { return $null }
    Write-Host ''
    Write-Host $script:RepairMessages.ISOHistoryTitle -ForegroundColor Cyan
    for ($i = 0; $i -lt $saved.Count; $i++) {
        Write-Host (' {0}. {1}' -f ($i + 1), $saved[$i].path)
    }
    $idx = 0
    if ($saved.Count -eq 1) {
        $idx = 1
    } else {
        while ($true) {
            $answer = (Read-Host $script:RepairMessages.ISOHistoryChoose).Trim()
            if (-not $answer) { return $null }
            if ([int]::TryParse($answer, [ref]$idx) -and $idx -ge 1 -and
                $idx -le $saved.Count) { break }
            Write-Host $script:RepairMessages.InvalidNumber -ForegroundColor Yellow
        }
    }
    $path = [string]$saved[$idx - 1].path
    try {
        $selected = Mount-PSWinKitInstallationISO -Path $path -Messages $utility.CommonMessages
        $script:RepairISOOrigin = [string]$selected.ISOPath
        Write-Host ($script:RepairMessages.ISOHistoryUsing -f $path) -ForegroundColor Green
        return [string]$selected.Source
    } catch {
        Write-Host ($script:RepairMessages.ISOHistoryUnavailable -f $path, $_.Exception.Message) -ForegroundColor Yellow
        return $null
    }
}

function Get-RepairISOOrigin {
    param([string]$ImagePath)
    if ($script:RepairISOOrigin -and [IO.File]::Exists([string]$script:RepairISOOrigin)) {
        return (Resolve-PSWinKitPreferredISOPath ([string]$script:RepairISOOrigin))
    }
    if ($ImagePath -match '^([A-Za-z]):\\') {
        $source = Get-PSWinKitMountedISOOrigin $Matches[1]
        if ($source) { return (Resolve-PSWinKitPreferredISOPath $source) }
    }
    return $null
}

function Save-RepairISOHistory {
    param([string]$ImagePath, [int]$ImageIndex, $Details)
    if ($null -eq $Details -or $ImageIndex -lt 1) { return }
    $source = Get-RepairISOOrigin -ImagePath $ImagePath
    if (-not $source -or -not [IO.File]::Exists($source)) { return }
    $build = 0
    try { $build = ([version]$Details.Version).Build } catch { return }
    if ($build -le 0 -or -not $Details.Edition -or -not $Details.Architecture) { return }
    $metadata = [pscustomobject]@{
        index = $ImageIndex; name = [string]$Details.Name
        editionId = [string]$Details.Edition; build = [int]$build
        architecture = [string]$Details.Architecture
        installationType = [string]$Details.Installation
        language = [string]$Details.Language
    }
    Write-Host ($script:RepairMessages.ISOOrigin -f $source) -ForegroundColor Gray
    try {
        Add-PSWinKitImageCatalogISO $source @($metadata)
        $script:RepairCatalogTouched = $true
        Write-Host ($script:RepairMessages.ISOHistorySaved -f
            (Join-Path (Get-PSWinKitImageCatalogDirectory) 'images.json')) -ForegroundColor DarkGray
    } catch {
        Write-Host ($script:RepairMessages.ISOHistorySaveFailed -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Invoke-RepairFromSplitWim {
    param([string]$ImagePath, [int]$ImageIndex, $OriginalDetails)
    $pattern = Get-PSWinKitSplitWimPattern -Source $ImagePath -Messages $utility.CommonMessages
    $disk = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($env:ProgramData))
    if ([int64]$disk.AvailableFreeSpace -lt 9GB) {
        Write-Host $script:RepairMessages.SWMNoSpace -ForegroundColor Yellow
        return 112
    }
    $parent = Join-Path $env:ProgramData 'PSWinKit\Check-Windows'
    $stage = Join-Path $parent ('Stage-' + [guid]::NewGuid().ToString('N'))
    $wim = Join-Path $stage 'Install-Selected.wim'
    [void](New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop)
    [void](New-Item -ItemType Directory -Path $stage -ErrorAction Stop)
    try {
        # Do not allow inherited Everyone/Users permissions on an exported OS image.
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [Security.AccessControl.InheritanceFlags]::ObjectInherit
        foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {
            $identity = [System.Security.Principal.SecurityIdentifier]::new($sid)
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $identity, [System.Security.AccessControl.FileSystemRights]::FullControl,
                $inherit, [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)
            $acl.AddAccessRule($rule)
        }
        [IO.Directory]::SetAccessControl($stage, $acl)
        Write-Host ($script:RepairMessages.SWMExporting -f $ImageIndex, $wim) -ForegroundColor Cyan
        $exportArguments = '/English /Export-Image /SourceImageFile:"{0}" /SourceIndex:{1} /SWMFile:"{2}" /DestinationImageFile:"{3}" /CheckIntegrity' -f
            $ImagePath, $ImageIndex, $pattern, $wim
        $code = Invoke-RepairExecutable -Executable $script:DismExe -Arguments $exportArguments
        if ($code -ne 0 -or -not [IO.File]::Exists($wim)) {
            Write-Host ($script:RepairMessages.SWMExportFailed -f (Format-ExitCode $code)) -ForegroundColor Red
            return $code
        }
        $actual = Get-ImageDetails -ImagePath $wim -ImageIndex 1
        if ($null -eq $actual -or $null -eq $OriginalDetails -or
            $actual.Edition -ine $OriginalDetails.Edition -or
            $actual.Architecture -ine $OriginalDetails.Architecture -or
            $actual.Installation -ine $OriginalDetails.Installation) {
            throw $script:RepairMessages.SWMExportMismatch
        }
        Write-Host $script:RepairMessages.SWMExportReady -ForegroundColor Green
        return (Run-Dism -ImagePath $wim -ImageIndex 1)
    } catch [System.Management.Automation.PipelineStoppedException] {
        throw
    } catch {
        Write-Host ($script:RepairMessages.SWMExportFailed -f $_.Exception.Message) -ForegroundColor Red
        return 1
    } finally {
        try {
            # This directory is newly created by this invocation, never a user folder.
            $stageItem = Get-Item -LiteralPath $stage -Force -ErrorAction Stop
            if (($stageItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Unexpected reparse point at staging root.'
            }
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Host ($script:RepairMessages.SWMCleanupFailed -f $stage, $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}
