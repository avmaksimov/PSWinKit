#Requires -Version 5.1
# Check-SystemPartitions execution module. Loaded by Check-SystemPartitions.ps1.
# This module NEVER runs any disk changes when dot-sourced.
# Supported execution scenario: GPT, C: NTFS, active WinRE Recovery directly after C:.

$script:CSExecMutated = $false
$script:CSExecLastSucceeded = $false
$script:CSExecErrorReportedMessage = $null
$script:CSExecStaging = $null
$script:CSExecMount = $null
$script:CSExecMountPart = $null
$script:CSExecMountAttached = $false
$script:CSExecCurrentVolumeSize = $null
$script:CSExecCurrentVolumeFree = $null

# Stage directories can remain after a crash or a failed destructive operation.
# Never delete an arbitrary path or a directory containing reparse points.
function Test-CSStagingTreeSafe([string]$path) {
    if (-not [IO.Directory]::Exists($path)) { return $false }
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push([IO.Path]::GetFullPath($path))
    while ($pending.Count -gt 0) {
        $dir = $pending.Pop()
        $d = [IO.DirectoryInfo]::new($dir)
        if (($d.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        foreach ($file in [IO.Directory]::GetFileSystemEntries($dir)) {
            $attributes = [IO.File]::GetAttributes($file)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Push($file) }
        }
    }
    return $true
}

function Get-CSStagingTreeSize([string]$path) {
    [int64]$bytes = 0
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($path)
    while ($stack.Count -gt 0) {
        foreach ($item in [IO.Directory]::GetFileSystemEntries($stack.Pop())) {
            $attrib = [IO.File]::GetAttributes($item)
            if (($attrib -band [IO.FileAttributes]::Directory) -ne 0) { $stack.Push($item) }
            else { $bytes += [int64]([IO.FileInfo]::new($item)).Length }
        }
    }
    return $bytes
}

function Invoke-CSOfferOldStagingCleanup([switch]$WinReEnabled) {
    $base = Join-Path $env:ProgramData 'PSWinKit\Check-SystemPartitions'
    if (-not [IO.Directory]::Exists($base)) { return }
    # The root must itself be an ordinary directory (not a junction).
    if (((Get-Item -LiteralPath $base -Force -ErrorAction Stop).Attributes -band
        [IO.FileAttributes]::ReparsePoint) -ne 0) { throw $m.CS27CleanupUnsafeRoot }
    $dirs = @(Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction Stop |
        Where-Object { $_.Name -match '^Stage-[a-fA-F0-9]{32}$' -and
            $_.LastWriteTime -lt (Get-Date).AddMinutes(-30) })
    if ($dirs.Count -eq 0) { return }
    Write-Host ''
    Write-Host $m.CS27OldStageTitle -ForegroundColor Yellow
    foreach ($dir in $dirs) {
        if (-not (Test-CSStagingTreeSafe $dir.FullName)) {
            Write-Host ($m.CS27OldStageUnsafe -f $dir.FullName) -ForegroundColor Red
            return
        }
        $size = Get-CSStagingTreeSize $dir.FullName
        Write-Host ($m.CS27OldStageRow -f $dir.Name, $dir.CreationTime,
            (Format-PartitionSize $size))
    }
    if (-not $WinReEnabled) {
        Write-Host $m.CS27OldStageKeep -ForegroundColor Yellow
        return
    }
    Write-Host $m.CS27OldStageWarning -ForegroundColor Yellow
    if (-not (Read-YesNo $m.CS27OldStageDeleteQuestion)) { return }
    foreach ($dir in $dirs) {
        if (-not (Test-CSStagingTreeSafe $dir.FullName)) {
            throw $m.CS27CleanupUnsafeRoot
        }
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
    }
    Write-Host ($m.CS27OldStageDeleted -f $dirs.Count) -ForegroundColor Green
}

function Assert-CSPendingRebootClear {
    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )) {
        if (Test-Path -LiteralPath $key) { throw $m.CSExecPendingReboot }
    }
}

function Assert-CSBitLockerOff {
    $cmd = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { throw $m.CSExecBitLockerUnknown }
    $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
    if ($null -eq $bl) { throw $m.CSExecBitLockerUnknown }
    if (([string]$bl.VolumeStatus -notin @('FullyDecrypted','0')) -or
        ([string]$bl.ProtectionStatus -notin @('Off','0'))) {
        throw $m.CSExecBitLockerBlocked
    }
}

function Assert-CSLayoutUnchanged($disk, $snapshot) {
    $freshDisk = Get-Disk -Number ([int]$disk.Number) -ErrorAction Stop
    if ([string]$freshDisk.UniqueId -ne [string]$disk.UniqueId -or
        [int64]$freshDisk.Size -ne [int64]$disk.Size -or
        [string]$freshDisk.PartitionStyle -ne [string]$disk.PartitionStyle) {
        throw $m.CSExecLayoutChanged
    }
    $current = @(Get-Partition -DiskNumber ([int]$disk.Number) -ErrorAction Stop | Sort-Object Offset)
    if ($current.Count -ne $snapshot.Count) { throw $m.CSExecLayoutChanged }
    for ($i = 0; $i -lt $current.Count; $i++) {
        $a = $current[$i]
        $b = $snapshot[$i]
        if ([int]$a.PartitionNumber -ne [int]$b.PartitionNumber -or
            [int64]$a.Offset -ne [int64]$b.Offset -or
            [int64]$a.Size -ne [int64]$b.Size -or
            [string]$a.GptType -ne [string]$b.GptType) {
            throw $m.CSExecLayoutChanged
        }
    }
}

function Assert-CSRecoveryContent($root) {
    # A conservative allow-list for the standard Windows RE tools partition.
    # Additional Windows RE settings can be vital for Quick Machine Recovery.
    # Every accepted file is staged and hash-verified before the final preflight.
    foreach ($entry in @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop)) {
        if ($entry.Name -notin @('Recovery','System Volume Information','$RECYCLE.BIN') -or
            -not $entry.PSIsContainer -or
            (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw ($m.CSExecRecoveryUnexpected -f $entry.Name)
        }
    }
    $recovery = Join-Path $root 'Recovery'
    if (-not (Test-Path -LiteralPath $recovery -PathType Container)) { throw $m.CSExecImageMissing }
    foreach ($entry in @(Get-ChildItem -LiteralPath $recovery -Force -ErrorAction Stop)) {
        if ($entry.Name -ne 'WindowsRE' -or -not $entry.PSIsContainer -or
            (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw ($m.CSExecRecoveryUnexpected -f (Join-Path 'Recovery' $entry.Name))
        }
    }
    $folder = Join-Path $recovery 'WindowsRE'
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw $m.CSExecImageMissing }
    # WinRE and Quick Machine Recovery can contain more than just Winre.wim.
    # Do not accept arbitrary OEM files or reparse points without review.
    $allowed = @('Winre.wim','ReAgent.xml','boot.sdi','SrSettings.ini',
        'WifiSettings.ini','ReCustomization.xml','ReAgent.old')
    foreach ($entry in @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction Stop)) {
        if ($entry.PSIsContainer -or ($entry.Name -notin $allowed) -or
            (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw ($m.CSExecRecoveryUnexpected -f (Join-Path 'Recovery\WindowsRE' $entry.Name))
        }
    }
    return $folder
}

function Open-CSRecoveryMount($diskNumber, $partNumber) {
    if ($script:CSExecMountAttached) { throw $m.CSExecMountFailure }
    $mount = Join-Path $env:windir ('Temp\PSWinKit-Recovery-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -Path $mount -ItemType Directory -ErrorAction Stop)
    $script:CSExecMount = $mount
    $script:CSExecMountPart = [int]$partNumber
    # Mark as possibly attached before the Storage call: it may partially succeed.
    $script:CSExecMountAttached = $true
    Add-PartitionAccessPath -DiskNumber ([int]$diskNumber) -PartitionNumber ([int]$partNumber) `
        -AccessPath $mount -ErrorAction Stop
    $dir = Get-Item -LiteralPath $mount -Force -ErrorAction Stop
    if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        throw $m.CSExecMountFailure
    }
    return $mount
}

function Close-CSRecoveryMount($diskNumber) {
    if (-not $script:CSExecMount) { return }
    $mount = $script:CSExecMount
    if ($script:CSExecMountAttached) {
        Remove-PartitionAccessPath -DiskNumber ([int]$diskNumber) `
            -PartitionNumber ([int]$script:CSExecMountPart) -AccessPath $mount -ErrorAction Stop
        $script:CSExecMountAttached = $false
    }
    if (Test-Path -LiteralPath $mount -PathType Container) {
        $dir = Get-Item -LiteralPath $mount -Force -ErrorAction Stop
        if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw $m.CSExecMountFailure
        }
        # No recursion on an NTFS volume mount point, ever.
        [IO.Directory]::Delete($mount, $false)
    }
    $script:CSExecMount = $null
    $script:CSExecMountPart = $null
}

function Protect-CSStagingDirectory([string]$path) {
    # Remove inherited access, grant only local Administrators and SYSTEM.
    # Backup may contain Quick Machine Recovery network credentials.
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                   [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($sidText in @('S-1-5-32-544','S-1-5-18')) {
        $sid = [System.Security.Principal.SecurityIdentifier]::new($sidText)
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid, [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance, [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    [System.IO.Directory]::SetAccessControl($path, $security)
    $effective = Get-Acl -LiteralPath $path -ErrorAction Stop
    if (-not $effective.AreAccessRulesProtected) { throw $m.CSExecStagingAclUnsafe }
}

function Get-CSFileSha256([string]$path) {
    # Stream the file directly: supports Hidden + System files on Windows PowerShell 5.1.
    # Never adjust the original file attributes.
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Assert-CSWim([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw $m.CSExecImageMissing }
    # Winre.wim is normally Hidden + System; Get-Item without -Force reports
    # 'Could not find item' under Windows PowerShell 5.1 even if it exists.
    $wimItem = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (($wimItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw $m.CSExecImageInvalid }
    if ([int64]$wimItem.Length -lt 100MB) { throw $m.CSExecImageInvalid }
    $detail = Get-WindowsImage -ImagePath $path -Index 1 -ErrorAction Stop
    if ($null -eq $detail) { throw $m.CSExecImageInvalid }
}

function Save-CSWim($disk, $recovery) {
    Write-Host $m.CSExecStagingWim -ForegroundColor Cyan
    $base = Join-Path $env:ProgramData 'PSWinKit\Check-SystemPartitions'
    [void](New-Item -Path $base -ItemType Directory -Force -ErrorAction Stop)
    $script:CSExecStaging = Join-Path $base ('Stage-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -Path $script:CSExecStaging -ItemType Directory -ErrorAction Stop)
    Protect-CSStagingDirectory $script:CSExecStaging
    $dest = Join-Path $script:CSExecStaging 'Winre.wim'
    $root = Open-CSRecoveryMount ([int]$disk.Number) ([int]$recovery.PartitionNumber)
    try {
        $folder = Assert-CSRecoveryContent $root
        try {
            $currentVolume = Get-Volume -Partition $recovery -ErrorAction Stop
            if ($null -ne $currentVolume -and $null -ne $currentVolume.SizeRemaining -and
                [int64]$currentVolume.Size -gt 0 -and [int64]$currentVolume.SizeRemaining -ge 0 -and
                [int64]$currentVolume.SizeRemaining -le [int64]$currentVolume.Size) {
                $script:CSExecCurrentVolumeSize = [int64]$currentVolume.Size
                $script:CSExecCurrentVolumeFree = [int64]$currentVolume.SizeRemaining
                Write-Host ($m.CSExecSizeCurrentFree -f
                    (Format-ExactMiB ([int64]$currentVolume.SizeRemaining))) -ForegroundColor DarkGray
            }
        } catch {
            # Some Windows versions do not expose free space for hidden Recovery volumes.
        }
        $source = Join-Path $folder 'Winre.wim'
        Write-Host $m.CSExecInspectSource -ForegroundColor DarkGray
        Assert-CSWim $source
        $length = [int64](Get-Item -LiteralPath $source -Force -ErrorAction Stop).Length
        $free = [int64](Get-Volume -DriveLetter C -ErrorAction Stop).SizeRemaining
        if ($free -lt $length + 1GB) { throw $m.CSExecStagingSpace }
        Write-Host $m.CSExecCopyImage -ForegroundColor DarkGray
        Copy-Item -LiteralPath $source -Destination $dest -Force -ErrorAction Stop
        Assert-CSWim $dest
        Write-Host $m.CSExecVerifyHash -ForegroundColor DarkGray
        $originalHash = (Get-CSFileSha256 $source)
        $copyHash = (Get-CSFileSha256 $dest)
        if ($originalHash -ne $copyHash) { throw $m.CSExecHashMismatch }
        $otherFiles = @(Get-ChildItem -LiteralPath $folder -File -Force -ErrorAction Stop |
            Where-Object { $_.Name -ine 'Winre.wim' })
        if ($otherFiles.Count -gt 0) {
            Write-Host $m.CSExecStagingExtras -ForegroundColor Cyan
            $extraDirectory = Join-Path $script:CSExecStaging 'RecoveryFiles'
            [void](New-Item -Path $extraDirectory -ItemType Directory -ErrorAction Stop)
            foreach ($item in $otherFiles) {
                $copyPath = Join-Path $extraDirectory $item.Name
                Copy-Item -LiteralPath $item.FullName -Destination $copyPath -Force -ErrorAction Stop
                if ((Get-CSFileSha256 $item.FullName) -ne
                    (Get-CSFileSha256 $copyPath)) {
                    throw $m.CSExecHashMismatch
                }
            }
            Write-Host ($m.CSExecExtraCount -f $otherFiles.Count) -ForegroundColor DarkGray
        }
        Write-Host ($m.CSExecStagedAt -f $dest) -ForegroundColor DarkGray
    } finally {
        Close-CSRecoveryMount ([int]$disk.Number)
    }
    return $dest
}

function Assert-CSExecutionPreflight($disk, $c, $parts, $recovery, $reInfo, $proposal, $geo) {
    if ([string]$disk.PartitionStyle -ne 'GPT') { throw $m.CSExecGptOnly }
    if ($disk.IsOffline -or $disk.IsReadOnly -or -not $disk.IsBoot) { throw $m.CSExecDiskUnsafe }
    if ($disk.PSObject.Properties['IsClustered'] -and $disk.IsClustered) { throw $m.CSExecDiskUnsafe }
    if ((Get-GptId $c) -ne 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7') {
        throw $m.CSExecLayoutUnsupported
    }

    if ($null -eq $recovery -or -not $reInfo.Enabled -or
        [int]$reInfo.DiskNumber -ne [int]$disk.Number -or
        [int]$reInfo.PartitionNumber -ne [int]$recovery.PartitionNumber) {
        throw $m.CSExecRecoveryUnknown
    }
    if ($recovery.IsSystem -or $recovery.IsBoot -or $recovery.IsActive) { throw $m.CSExecRecoveryUnsafe }
    $cVolume = Get-Volume -DriveLetter C -ErrorAction Stop
    if ([string]$cVolume.FileSystem -ne 'NTFS') { throw $m.CSExecNtfsOnly }
    if ([string]$cVolume.HealthStatus -notin @('Healthy','0')) { throw $m.CSExecDiskUnsafe }

    if ([int64]$c.Offset -lt 1MB -or ([int64]$c.Offset % 512) -ne 0) { throw $m.CSExecLayoutUnsupported }
    if ($null -eq $geo -or -not $geo.IsGeometryPossible) { throw $m.CSExecLayoutUnsupported }
    if (([int64]$geo.NewStart % 1MB) -ne 0 -or
        ([int64]$geo.NewSize % [int64]$disk.LogicalSectorSize) -ne 0) {
        throw $m.CSExecLayoutUnsupported
    }
    $cEnd = Get-PartitionEnd $c
    if ([int64]$recovery.Offset -lt $cEnd -or
        [int64]$recovery.Offset - $cEnd -ge 2MB) { throw $m.CSExecLayoutUnsupported }
    $afterC = @($parts | Where-Object { [int64]$_.Offset -ge $cEnd } | Sort-Object Offset)
    if ($afterC.Count -eq 0 -or [int]$afterC[0].PartitionNumber -ne [int]$recovery.PartitionNumber) {
        throw $m.CSExecLayoutUnsupported
    }
    # No overlaps with any other partition, including partitions after Recovery.
    $newREnd = [int64]$geo.NewStart + [int64]$geo.NewSize
    foreach ($p in $parts) {
        if ([int]$p.PartitionNumber -in @([int]$c.PartitionNumber,[int]$recovery.PartitionNumber)) { continue }
        if ([int64]$p.Offset -lt $newREnd -and (Get-PartitionEnd $p) -gt [int64]$geo.NewStart) {
            throw $m.CSExecLayoutUnsupported
        }
    }
    Assert-CSPendingRebootClear
    Assert-CSBitLockerOff
    $supported = Get-PartitionSupportedSize -DiskNumber ([int]$disk.Number) `
        -PartitionNumber ([int]$c.PartitionNumber) -ErrorAction Stop
    if ([int64]$proposal.ChangeBytes -lt 0 -and
        [int64]$proposal.TargetPartitionBytes -lt [int64]$supported.SizeMin) {
        throw $m.CSExecShrinkBlocked
    }
}

function Assert-CSAfterShrink($disk, $c, $oldRecovery, $targetBytes, $snapshot) {
    $current = @(Get-Partition -DiskNumber ([int]$disk.Number) -ErrorAction Stop | Sort-Object Offset)
    if ($current.Count -ne $snapshot.Count) { throw $m.CSExecLayoutChanged }
    for ($i = 0; $i -lt $current.Count; $i++) {
        $a = $current[$i]; $b = $snapshot[$i]
        $expectedSize = if ([int]$a.PartitionNumber -eq [int]$c.PartitionNumber) {
            [int64]$targetBytes
        } else { [int64]$b.Size }
        if ([int]$a.PartitionNumber -ne [int]$b.PartitionNumber -or
            [int64]$a.Offset -ne [int64]$b.Offset -or
            [int64]$a.Size -ne $expectedSize -or
            [string]$a.GptType -ne [string]$b.GptType) { throw $m.CSExecLayoutChanged }
    }
    if ($null -ne $oldRecovery) {
        $rec = Get-Partition -DiskNumber ([int]$disk.Number) `
            -PartitionNumber ([int]$oldRecovery.PartitionNumber) -ErrorAction Stop
        if ([int64]$rec.Offset -ne [int64]$oldRecovery.Offset -or
            [int64]$rec.Size -ne [int64]$oldRecovery.Size) { throw $m.CSExecLayoutChanged }
    }
}

function Invoke-CSDiskPart([string[]]$commands) {
    $f = Join-Path $script:CSExecStaging ([guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllLines($f, $commands, [Text.Encoding]::ASCII)
    try {
        & diskpart.exe /s $f
        if ($LASTEXITCODE -ne 0) { throw $m.CSExecDiskPartFailed }
    } finally {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }
}

function Set-CSRecoveryType($disk, $partNumber) {
    $guid = $script:RecoveryGuid
    Invoke-CSDiskPart @("select disk $($disk.Number)","select partition $partNumber",
        "set id=$guid override",'gpt attributes=0x8000000000000001')
    $p = Get-Partition -DiskNumber ([int]$disk.Number) `
        -PartitionNumber ([int]$partNumber) -ErrorAction Stop
    if (-not (Test-RecoveryPartition $p 'GPT')) { throw $m.CSExecRecoveryTypeFailed }
    $probe = Join-Path $script:CSExecStaging ([guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllLines($probe, @("select disk $($disk.Number)",
        "select partition $partNumber",'detail partition'), [Text.Encoding]::ASCII)
    try {
        $output = (& diskpart.exe /s $probe 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or $output -notmatch '(?i)0x8000000000000001') {
            throw $m.CSExecRecoveryTypeFailed
        }
    } finally {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-CSExternal([string]$file, [string[]]$arguments) {
    & $file @arguments
    if ($LASTEXITCODE -ne 0) { throw ($m.CSExecExternalFailed -f $file, $LASTEXITCODE) }
}

function Invoke-CSCRecoveryExecution {
    param($Disk, $C, $Parts, $ActiveRecovery, $ReInfo, $Proposal, $RebuildGeometry, [switch]$PreflightOnly)
    if (-not $PreflightOnly) {
        Write-Host $m.CS27ExecutionRisk -ForegroundColor Red
    }
    $script:CSExecMutated = $false
    $script:CSExecLastSucceeded = $false
    $script:CSExecStaging = $null
    $script:CSExecMount = $null
    $script:CSExecMountAttached = $false
    $script:CSExecCurrentVolumeSize = $null
    $script:CSExecCurrentVolumeFree = $null
    $stageWim = $null
    $completed = $false
    $snapshot = @($Parts | Sort-Object Offset | ForEach-Object {
        [pscustomobject]@{
            PartitionNumber = [int]$_.PartitionNumber
            Offset = [int64]$_.Offset; Size = [int64]$_.Size
            GptType = [string]$_.GptType
        }
    })
    try {
        Write-Host ''
        Write-Host ('=== ' + $m.CSExecPreflightTitle + ' ===') -ForegroundColor Cyan
        Write-Host $m.CSExecPreflightWarn -ForegroundColor Yellow
        Import-Module Dism -ErrorAction Stop
        Assert-CSExecutionPreflight $Disk $C $Parts $ActiveRecovery $ReInfo $Proposal $RebuildGeometry
        Assert-CSLayoutUnchanged $Disk $snapshot
        $stageWim = Save-CSWim $Disk $ActiveRecovery
        $stagedWimHash = Get-CSFileSha256 $stageWim
        # Copying the WIM to C: can change the shrink limit; verify again.
        Assert-CSExecutionPreflight $Disk $C $Parts $ActiveRecovery $ReInfo $Proposal $RebuildGeometry
        Assert-CSLayoutUnchanged $Disk $snapshot
        # The staged Winre.wim retains Hidden/System attributes after Copy-Item.
        # In Windows PowerShell 5.1, Get-Item without -Force fails for such files.
        $wimBytes = [int64](Get-Item -LiteralPath $stageWim -Force -ErrorAction Stop).Length
        # Count the additional files which will also occupy the new Recovery.
        $extraBytes = [int64]0
        $extraDirectory = Join-Path $script:CSExecStaging 'RecoveryFiles'
        if (Test-Path -LiteralPath $extraDirectory -PathType Container) {
            foreach ($item in @(Get-ChildItem -LiteralPath $extraDirectory -File -Force -ErrorAction Stop)) {
                $extraBytes += [int64]$item.Length
            }
        }
        # Rebuilding an existing NTFS Recovery: use actual measured occupancy.
        # Both the WinRE image and all configuration files are already included
        # in the filesystem's used-space figure. Do NOT add them twice.
        # A formatted replacement can have slightly different NTFS metadata,
        # so this is a forecast; the final free-space requirement must also
        # be verified after the files have been restored.
        if ($null -eq $script:CSExecCurrentVolumeSize -or
            $null -eq $script:CSExecCurrentVolumeFree) {
            throw $m.CSExecSizeCannotMeasure
        }
        $existingBytes = [int64]$ActiveRecovery.Size
        $currentCapacity = [int64]$script:CSExecCurrentVolumeSize
        $currentFree = [int64]$script:CSExecCurrentVolumeFree
        $usedBytes = $currentCapacity - $currentFree
        $volumeDifference = [math]::Max([double]0, [double]($existingBytes - $currentCapacity))
        $newCapacity = [int64]([double]$RebuildGeometry.NewSize - $volumeDifference)
        $fallbackSize = Align-DownMiB ([int64]$RebuildGeometry.NewSize)
        $fallbackCapacity = [int64]([double]$fallbackSize - $volumeDifference)
        $targetFree = [int64]($newCapacity - $usedBytes)
        $fallbackFree = [int64]($fallbackCapacity - $usedBytes)
        $requiredFree = [int64](250MB)
        $requiredRe = [int64]($usedBytes + $requiredFree + $volumeDifference)
        Write-Host $m.CSExecSizeHeader -ForegroundColor Cyan
        Write-Host ($m.CSExecSizeImage -f (Format-ExactMiB $wimBytes))
        Write-Host ($m.CSExecSizeExtras -f (Format-ExactMiB $extraBytes))
        Write-Host ($m.CSExecSizeMeasured -f (Format-ExactMiB $usedBytes),
            (Format-ExactMiB $currentFree))
        Write-Host ($m.CSExecReTarget -f (Format-ExactMiB ([int64]$RebuildGeometry.NewSize)),
            (Format-ExactMiB $fallbackSize))
        Write-Host ($m.CSExecSizeForecast -f (Format-ExactMiB $targetFree),
            (Format-ExactMiB $fallbackFree))
        Write-Host ($m.CSExecSizeRequiredFree -f (Format-ExactMiB $requiredFree))
        # The preview includes a conservative fallback to a MiB-aligned size.
        # Both choices must meet the minimum free-space requirement.
        if ($targetFree -lt $requiredFree -or $fallbackFree -lt $requiredFree) {
            $deficit = [int64]([math]::Max([double]($requiredFree - $targetFree),
                [double]($requiredFree - $fallbackFree)))
            Write-Host ($m.CSExecSizeShortfall -f (Format-ExactMiB $deficit)) -ForegroundColor Yellow
            throw $m.CSExecRecoveryTooSmall
        }
        Write-Host ($m.CSExecStagedAt -f $stageWim) -ForegroundColor DarkGray
        if ($PreflightOnly) {
            Write-Host $m.CSExecPreflightPassed -ForegroundColor Green
            return
        }
        # A freshly formatted NTFS volume may differ from the current one.
        # The 2 MiB surplus seen in the second test machine is not sufficient
        # to risk deletion without knowing the final filesystem overhead.
        $executionFloor = [int64](250MB + 16MB)
        if ($targetFree -lt $executionFloor -or $fallbackFree -lt $executionFloor) {
            Write-Host ($m.CS27SafetyMargin -f (Format-ExactMiB $executionFloor),
                (Format-ExactMiB ([int64][math]::Min($targetFree,$fallbackFree)))) -ForegroundColor Yellow
            throw $m.CSExecRecoveryTooSmall
        }
        Write-Host $m.CSExecNeedBackup -ForegroundColor Yellow
        if (-not (Read-YesNo $m.CSExecBackupConfirmed)) {
            Write-Host $m.CSExecCancelled -ForegroundColor Yellow
            return
        }
        if (-not (Read-YesNo $m.CSExecFinalConfirm)) {
            Write-Host $m.CSExecCancelled -ForegroundColor Yellow
            return
        }
        Write-Host ''
        Write-Host ('=== ' + $m.CSExecApplyingTitle + ' ===') -ForegroundColor Cyan
        Assert-CSLayoutUnchanged $Disk $snapshot
        Assert-CSBitLockerOff
        $afterStaging = Get-WinReSnapshot
        if (-not $afterStaging.Enabled -or [int]$afterStaging.DiskNumber -ne [int]$Disk.Number -or
            [int]$afterStaging.PartitionNumber -ne [int]$ActiveRecovery.PartitionNumber) {
            throw $m.CSExecRecoveryUnknown
        }
        Assert-CSWim $stageWim
        if ((Get-CSFileSha256 $stageWim) -ne $stagedWimHash) { throw $m.CSExecHashMismatch }
        Write-Host $m.CSExecDisableWinRE
        $script:CSExecMutated = $true
        Invoke-CSExternal 'reagentc.exe' @('/disable')
        if ((Get-WinReSnapshot).Enabled) { throw $m.CSExecWinRENotDisabled }
        if ([int64]$Proposal.ChangeBytes -lt 0) {
            Write-Host $m.CSExecShrinkC
            $sizes = Get-PartitionSupportedSize -DiskNumber ([int]$Disk.Number) `
                -PartitionNumber ([int]$C.PartitionNumber) -ErrorAction Stop
            if ([int64]$Proposal.TargetPartitionBytes -lt [int64]$sizes.SizeMin) { throw $m.CSExecShrinkBlocked }
            Resize-Partition -DiskNumber ([int]$Disk.Number) -PartitionNumber ([int]$C.PartitionNumber) `
                -Size ([uint64]$Proposal.TargetPartitionBytes) -ErrorAction Stop
            Assert-CSAfterShrink $Disk $C $ActiveRecovery $Proposal.TargetPartitionBytes $snapshot
        } else {
            Assert-CSLayoutUnchanged $Disk $snapshot
        }
        Write-Host $m.CSExecDeleteRecovery
        # Assert current Recovery identity immediately before destructive removal.
        $old = Get-Partition -DiskNumber ([int]$Disk.Number) `
            -PartitionNumber ([int]$ActiveRecovery.PartitionNumber) -ErrorAction Stop
        if ([int64]$old.Offset -ne [int64]$ActiveRecovery.Offset -or
            [int64]$old.Size -ne [int64]$ActiveRecovery.Size -or
            [int]$old.PartitionNumber -ne [int]$ActiveRecovery.PartitionNumber -or
            $old.IsBoot -or $old.IsSystem -or $old.IsActive -or
            $old.DriveLetter -or
            -not (Test-RecoveryPartition $old 'GPT')) { throw $m.CSExecLayoutChanged }
        # A GPT Recovery partition commonly has required/protected attributes.
        # DiskPart override is necessary; this is restricted to the VERIFIED
        # registered active Recovery number and disk.
        Invoke-CSDiskPart @("select disk $($Disk.Number)",
            "select partition $($ActiveRecovery.PartitionNumber)",
            'delete partition override')
        if (@(Get-Partition -DiskNumber ([int]$Disk.Number) -ErrorAction Stop |
              Where-Object { [int64]$_.Offset -eq [int64]$ActiveRecovery.Offset }).Count -gt 0) {
            throw $m.CSExecRecoveryDeleteFailed
        }
        if ([int64]$Proposal.ChangeBytes -gt 0) {
            Write-Host $m.CSExecGrowC
            $sizes = Get-PartitionSupportedSize -DiskNumber ([int]$Disk.Number) `
                -PartitionNumber ([int]$C.PartitionNumber) -ErrorAction Stop
            if ([int64]$Proposal.TargetPartitionBytes -gt [int64]$sizes.SizeMax) { throw $m.CSExecGrowBlocked }
            Resize-Partition -DiskNumber ([int]$Disk.Number) -PartitionNumber ([int]$C.PartitionNumber) `
                -Size ([uint64]$Proposal.TargetPartitionBytes) -ErrorAction Stop
        }
        $nowC = Get-Partition -DriveLetter C -ErrorAction Stop
        if ([int64]$nowC.Offset -ne [int64]$C.Offset -or
            [int64]$nowC.Size -ne [int64]$Proposal.TargetPartitionBytes) { throw $m.CSExecCMismatch }
        $newStart = Align-UpMiB (Get-PartitionEnd $nowC)
        if ([int64]$newStart -ne [int64]$RebuildGeometry.NewStart) { throw $m.CSExecLayoutChanged }
        Write-Host $m.CSExecCreateRecovery
        $basic = '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'
        $created = $null
        try {
            $created = New-Partition -DiskNumber ([int]$Disk.Number) -Offset ([uint64]$newStart) `
                -Size ([uint64]$RebuildGeometry.NewSize) -GptType $basic -ErrorAction Stop
        } catch {
            # No retry when the failed Storage call partially created a partition.
            $partAtOffset = @(Get-Partition -DiskNumber ([int]$Disk.Number) -ErrorAction Stop |
                Where-Object { [int64]$_.Offset -eq [int64]$newStart })
            if ($partAtOffset.Count -gt 0) { throw }
            # DiskPart alignment/rounding is not guaranteed to allow all 4 KiB/1 MiB.
            # Back off to an aligned end, without touching adjacent partitions.
            if ($fallbackSize -ge $requiredRe -and $fallbackSize -lt [int64]$RebuildGeometry.NewSize) {
                Write-Host $m.CSExecCreateFallback -ForegroundColor Yellow
                $created = New-Partition -DiskNumber ([int]$Disk.Number) -Offset ([uint64]$newStart) `
                    -Size ([uint64]$fallbackSize) -GptType $basic -ErrorAction Stop
            } else { throw }
        }
        $newNumber = [int]$created.PartitionNumber
        $newP = Get-Partition -DiskNumber ([int]$Disk.Number) -PartitionNumber $newNumber -ErrorAction Stop
        if ([int64]$newP.Offset -ne [int64]$newStart -or
            [int64]$newP.Size -lt $requiredRe -or
            [int64]$newP.Size -gt [int64]$RebuildGeometry.NewSize -or
            $newP.DriveLetter -or $newP.IsBoot -or $newP.IsSystem -or
            (Get-GptId $newP) -ne 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7') {
            throw $m.CSExecNewRecoveryMismatch
        }
        Format-Volume -Partition $newP -FileSystem NTFS -NewFileSystemLabel 'Windows RE tools' `
            -Force -Confirm:$false -ErrorAction Stop | Out-Null
        # Windows RE must be a Recovery GPT partition before reagentc /enable.
        # Set its type and GPT attributes BEFORE registering/enabling the image.
        # Temporarily mounting a typed Recovery partition is supported and
        # already used for the existing active Recovery in preflight.
        Set-CSRecoveryType $Disk $newNumber
        $root = Open-CSRecoveryMount ([int]$Disk.Number) $newNumber
        try {
            $folder = Join-Path $root 'Recovery\WindowsRE'
            [void](New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop)
            $dest = Join-Path $folder 'Winre.wim'
            Copy-Item -LiteralPath $stageWim -Destination $dest -ErrorAction Stop
            if ((Get-CSFileSha256 $dest) -ne $stagedWimHash) {
                throw $m.CSExecHashMismatch
            }
            # Restore Windows RE/QMR configuration. ReAgent.xml and ReAgent.old
            # describe the previous partition and must be regenerated by reagentc.
            # They remain preserved in staging if recovery is needed manually.
            $restored = 0
            $extras = Join-Path $script:CSExecStaging 'RecoveryFiles'
            if (Test-Path -LiteralPath $extras -PathType Container) {
                foreach ($cfg in @(Get-ChildItem -LiteralPath $extras -File -Force -ErrorAction Stop)) {
                    if ($cfg.Name -in @('ReAgent.xml','ReAgent.old')) { continue }
                    if ($cfg.Name -notin @('boot.sdi','SrSettings.ini','WifiSettings.ini','ReCustomization.xml')) {
                        throw ($m.CSExecRecoveryUnexpected -f $cfg.Name)
                    }
                    $configDest = Join-Path $folder $cfg.Name
                    Copy-Item -LiteralPath $cfg.FullName -Destination $configDest -Force -ErrorAction Stop
                    if ((Get-CSFileSha256 $configDest) -ne (Get-CSFileSha256 $cfg.FullName)) {
                        throw $m.CSExecHashMismatch
                    }
                    $restored++
                }
            }
            Write-Host ($m.CS27ConfigRestored -f $restored)
            $vol = Get-Volume -Partition $newP -ErrorAction Stop
            if ([int64]$vol.SizeRemaining -lt 250MB) { throw $m.CSExecRecoveryTooSmall }
            Write-Host $m.CSExecRegisterRecovery
            Invoke-CSExternal 'reagentc.exe' @('/setreimage','/path',$folder)
            Invoke-CSExternal 'reagentc.exe' @('/enable')
            $nowRE = Get-WinReSnapshot
            if (-not $nowRE.Enabled -or [int]$nowRE.DiskNumber -ne [int]$Disk.Number -or
                [int]$nowRE.PartitionNumber -ne $newNumber) { throw $m.CSExecWinRENotRegistered }
        } finally {
            Close-CSRecoveryMount ([int]$Disk.Number)
        }
        $final = Get-WinReSnapshot
        if (-not $final.Enabled -or [int]$final.DiskNumber -ne [int]$Disk.Number -or
            [int]$final.PartitionNumber -ne $newNumber) { throw $m.CSExecWinRENotRegistered }
        $finalRecovery = Get-Partition -DiskNumber ([int]$Disk.Number) -PartitionNumber $newNumber -ErrorAction Stop
        if (-not (Test-RecoveryPartition $finalRecovery 'GPT')) { throw $m.CSExecRecoveryTypeFailed }
        $finalVolume = Get-Volume -Partition $finalRecovery -ErrorAction Stop
        if ([int64]$finalVolume.SizeRemaining -lt 250MB) { throw $m.CSExecRecoveryTooSmall }
        $fs = Get-Volume -DriveLetter C -ErrorAction Stop
        if ([int64]$fs.Size -lt [int64]$Proposal.TargetExplorerGiB * 1GB) {
            Write-Host $m.CSExecExplorerNotExact -ForegroundColor Yellow
        }
        $completed = $true
        $script:CSExecLastSucceeded = $true
        Write-Host $m.CSExecComplete -ForegroundColor Green
        Write-Host ((& reagentc.exe /info) | Out-String)
    } catch {
        Write-Host ''
        Write-Host ($m.CSExecError -f $_.Exception.Message) -ForegroundColor Red
        $script:CSExecErrorReportedMessage = $_.Exception.Message
        if ($script:CSExecMutated) {
            Write-Host $m.CSExecManualRecovery -ForegroundColor Yellow
            Write-Host ($m.CSExecStagedAt -f $stageWim) -ForegroundColor Yellow
        }
        throw
    } finally {
        if ($script:CSExecMount) {
            try { Close-CSRecoveryMount ([int]$Disk.Number) }
            catch { Write-Warning $m.CSExecMountRetained }
        }
        if ($completed -or -not $script:CSExecMutated) {
            if ($script:CSExecStaging -and (Test-Path -LiteralPath $script:CSExecStaging -PathType Container)) {
                try { Remove-Item -LiteralPath $script:CSExecStaging -Recurse -Force -ErrorAction Stop }
                catch { Write-Warning $m.CSExecStagingRetained }
            }
        }
    }
}

# Missing-Recovery execution is intentionally separate from the existing
# registered-Recovery rebuild. Existing partitions are never deleted here.
function Assert-CSMissingRecoveryPreflight($disk, $c, $parts, $reInfo, $proposal, $geo) {
    if ([string]$disk.PartitionStyle -ne 'GPT') { throw $m.CSExecGptOnly }
    if ($disk.IsOffline -or $disk.IsReadOnly -or -not $disk.IsBoot) { throw $m.CSExecDiskUnsafe }
    if ($disk.PSObject.Properties['IsClustered'] -and $disk.IsClustered) { throw $m.CSExecDiskUnsafe }
    if ((Get-GptId $c) -ne 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7') {
        throw $m.CSExecLayoutUnsupported
    }
    if ($reInfo.Enabled -or $null -ne $reInfo.DiskNumber -or
        $null -ne $reInfo.PartitionNumber) { throw $m.CSNewWinREStateChanged }
    if (@($parts | Where-Object { Test-RecoveryPartition $_ 'GPT' }).Count -gt 0) {
        throw $m.CSNewExistingRecovery
    }
    $currentC = Get-Partition -DriveLetter C -ErrorAction Stop
    if ([int]$currentC.DiskNumber -ne [int]$disk.Number -or
        [int64]$currentC.Offset -ne [int64]$c.Offset -or
        [int64]$currentC.Size -ne [int64]$c.Size) { throw $m.CSExecLayoutChanged }
    $volume = Get-Volume -DriveLetter C -ErrorAction Stop
    if ([string]$volume.FileSystem -ne 'NTFS') { throw $m.CSExecNtfsOnly }
    if ([string]$volume.HealthStatus -notin @('Healthy','0')) { throw $m.CSExecDiskUnsafe }
    if ($null -eq $geo -or -not $geo.IsGeometryPossible -or
        [int64]$geo.NewSize -lt [int64]$proposal.MinimumRecoveryBytes) {
        throw $m.CSExecRecoveryTooSmall
    }
    $targetC = [int64]$proposal.TargetPartitionBytes
    if ($targetC -le 0 -or $targetC -gt [int64]$c.Size -or
        $targetC -ne ([int64]$c.Size + [int64]$proposal.ChangeBytes)) {
        throw $m.CSExecLayoutUnsupported
    }
    $cEnd = Get-PartitionEnd $c
    $newCEnd = [int64]$c.Offset + $targetC
    $newStart = Align-UpMiB $newCEnd
    $newEnd = [int64]$geo.NewStart + [int64]$geo.NewSize
    if ($newStart -ne [int64]$geo.NewStart -or $newStart -lt $newCEnd -or
        $newEnd -le $newStart -or ($newStart % 1MB) -ne 0 -or
        ([int64]$geo.NewSize % [int64]$disk.LogicalSectorSize) -ne 0) {
        throw $m.CSExecLayoutUnsupported
    }
    $next = @($parts | Where-Object {
        [int]$_.PartitionNumber -ne [int]$c.PartitionNumber -and
        [int64]$_.Offset -ge $cEnd
    } | Sort-Object Offset)
    $bounds = Get-UsableDiskBounds $disk $parts
    if ($null -eq $bounds) { throw $m.CSGptBoundsUnavailable }
    $rightEnd = if ($next.Count -gt 0) { [int64]$next[0].Offset }
                else { [int64]$bounds.End }
    if ([int64]$geo.RightEnd -ne $rightEnd -or
        $rightEnd -le $newCEnd -or $newEnd -gt $rightEnd -or
        $newEnd -gt [int64]$bounds.End) { throw $m.CSNewNextPartitionProtected }
    foreach ($p in $parts) {
        if ([int]$p.PartitionNumber -eq [int]$c.PartitionNumber) { continue }
        if ([int64]$p.Offset -lt $newEnd -and
            (Get-PartitionEnd $p) -gt $newStart) {
            throw $m.CSNewNextPartitionProtected
        }
    }
    Assert-CSPendingRebootClear
    Assert-CSBitLockerOff
    $sizes = Get-PartitionSupportedSize -DiskNumber ([int]$disk.Number) `
        -PartitionNumber ([int]$c.PartitionNumber) -ErrorAction Stop
    if ($targetC -lt [int64]$sizes.SizeMin -or
        $targetC -gt [int64]$sizes.SizeMax) { throw $m.CSExecShrinkBlocked }
}

function Save-CSLocalWinREImage {
    # The ISO image is prepared and verified during planning, so it is already
    # on C: before any shrink, and stays available until the operation ends.
    $source = if ($script:CSISOImagePath) { $script:CSISOImagePath }
              else { Join-Path $env:windir 'System32\Recovery\Winre.wim' }
    Write-Host $m.CSNewStagingLocal -ForegroundColor Cyan
    Assert-CSWim $source
    $length = [int64](Get-Item -LiteralPath $source -Force -ErrorAction Stop).Length
    $free = [int64](Get-Volume -DriveLetter C -ErrorAction Stop).SizeRemaining
    if ($free -lt ($length + 1GB)) { throw $m.CSExecStagingSpace }
    $base = Join-Path $env:ProgramData 'PSWinKit\Check-SystemPartitions'
    [void](New-Item -Path $base -ItemType Directory -Force -ErrorAction Stop)
    $script:CSExecStaging = Join-Path $base ('Stage-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -Path $script:CSExecStaging -ItemType Directory -ErrorAction Stop)
    Protect-CSStagingDirectory $script:CSExecStaging
    $dest = Join-Path $script:CSExecStaging 'Winre.wim'
    Copy-Item -LiteralPath $source -Destination $dest -Force -ErrorAction Stop
    Assert-CSWim $dest
    if ((Get-CSFileSha256 $source) -ne (Get-CSFileSha256 $dest)) {
        throw $m.CSExecHashMismatch
    }
    Write-Host ($m.CSExecStagedAt -f $dest) -ForegroundColor DarkGray
    return $dest
}

function Assert-CSOtherPartitionsPreserved($disk, $originalParts, $c) {
    $live = @(Get-Partition -DiskNumber ([int]$disk.Number) -ErrorAction Stop)
    foreach ($old in $originalParts) {
        if ([int]$old.PartitionNumber -eq [int]$c.PartitionNumber) { continue }
        $matches = @($live | Where-Object {
            [int64]$_.Offset -eq [int64]$old.Offset -and
            [int64]$_.Size -eq [int64]$old.Size -and
            (Get-GptId $_) -eq (Get-GptId $old) -and
            [string]$_.Guid -eq [string]$old.Guid -and
            [string]$_.DriveLetter -eq [string]$old.DriveLetter
        })
        if ($matches.Count -ne 1) { throw $m.CSNewNextPartitionProtected }
    }
}

function Invoke-CSCreateMissingRecovery {
    param($Disk, $C, $Parts, $ReInfo, $Proposal, $RebuildGeometry)
    $script:CSExecMutated = $false
    $script:CSExecLastSucceeded = $false
    $script:CSExecStaging = $null
    $script:CSExecMount = $null
    $script:CSExecMountAttached = $false
    $stageWim = $null
    $completed = $false
    $snapshot = @($Parts | Sort-Object Offset | ForEach-Object {
        [pscustomobject]@{
            PartitionNumber = [int]$_.PartitionNumber
            Offset = [int64]$_.Offset; Size = [int64]$_.Size
            GptType = [string]$_.GptType
        }
    })
    try {
        Write-Host ''
        Write-Host ('=== ' + $m.CSExecPreflightTitle + ' ===') -ForegroundColor Cyan
        Write-Host $m.CSNewPreflight -ForegroundColor Yellow
        Import-Module Dism -ErrorAction Stop
        Assert-CSMissingRecoveryPreflight $Disk $C $Parts $ReInfo $Proposal $RebuildGeometry
        Assert-CSLayoutUnchanged $Disk $snapshot
        $stageWim = Save-CSLocalWinREImage
        $stageHash = Get-CSFileSha256 $stageWim
        # Staging changes the file layout on C:; check shrinkability again.
        Assert-CSMissingRecoveryPreflight $Disk $C $Parts (Get-WinReSnapshot) $Proposal $RebuildGeometry
        Assert-CSLayoutUnchanged $Disk $snapshot
        Assert-CSWim $stageWim
        if ((Get-CSFileSha256 $stageWim) -ne $stageHash) { throw $m.CSExecHashMismatch }
        $wimBytes = [int64](Get-Item -LiteralPath $stageWim -Force -ErrorAction Stop).Length
        $required = [int64][math]::Max(
            [double]$Proposal.MinimumRecoveryBytes,
            [double]($wimBytes + 250MB + 64MB + 16MB))
        $fallbackSize = Align-DownMiB ([int64]$RebuildGeometry.NewSize)
        if ($fallbackSize -lt $required) { throw $m.CSExecRecoveryTooSmall }
        $reSizeText = Format-ExactMiB ([int64]$RebuildGeometry.NewSize)
        $wimSizeText = Format-ExactMiB $wimBytes
        Write-Host ($m.CSNewPreflightPassed -f $reSizeText, $wimSizeText) -ForegroundColor Green
        Write-Host $m.CSExecNeedBackup -ForegroundColor Yellow
        if (-not (Read-YesNo $m.CSExecBackupConfirmed)) {
            Write-Host $m.CSExecCancelled -ForegroundColor Yellow
            return
        }
        if (-not (Read-YesNo $m.CSNewFinalConfirm)) {
            Write-Host $m.CSExecCancelled -ForegroundColor Yellow
            return
        }
        Assert-CSLayoutUnchanged $Disk $snapshot
        Assert-CSMissingRecoveryPreflight $Disk $C $Parts (Get-WinReSnapshot) $Proposal $RebuildGeometry
        Write-Host ('=== ' + $m.CSNewApplyingTitle + ' ===') -ForegroundColor Cyan
        if ([int64]$Proposal.ChangeBytes -lt 0) {
            Write-Host $m.CSExecShrinkC
            $script:CSExecMutated = $true
            Resize-Partition -DiskNumber ([int]$Disk.Number) `
                -PartitionNumber ([int]$C.PartitionNumber) `
                -Size ([uint64]$Proposal.TargetPartitionBytes) -ErrorAction Stop
            Assert-CSAfterShrink $Disk $C $null $Proposal.TargetPartitionBytes $snapshot
        }
        $nowC = Get-Partition -DriveLetter C -ErrorAction Stop
        if ([int]$nowC.DiskNumber -ne [int]$Disk.Number -or
            [int64]$nowC.Offset -ne [int64]$C.Offset -or
            [int64]$nowC.Size -ne [int64]$Proposal.TargetPartitionBytes) {
            throw $m.CSExecCMismatch
        }
        $newStart = Align-UpMiB (Get-PartitionEnd $nowC)
        if ($newStart -ne [int64]$RebuildGeometry.NewStart) { throw $m.CSExecLayoutChanged }
        Assert-CSOtherPartitionsPreserved $Disk $Parts $C
        Write-Host $m.CSExecCreateRecovery
        $script:CSExecMutated = $true
        $basic = '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'
        $created = $null
        try {
            $created = New-Partition -DiskNumber ([int]$Disk.Number) -Offset ([uint64]$newStart) `
                -Size ([uint64]$RebuildGeometry.NewSize) -GptType $basic -ErrorAction Stop
        } catch {
            $partial = @(Get-Partition -DiskNumber ([int]$Disk.Number) -ErrorAction Stop |
                Where-Object { [int64]$_.Offset -eq $newStart })
            if ($partial.Count -gt 0) { throw }
            if ($fallbackSize -lt $required -or
                $fallbackSize -ge [int64]$RebuildGeometry.NewSize) { throw }
            Write-Host $m.CSExecCreateFallback -ForegroundColor Yellow
            $created = New-Partition -DiskNumber ([int]$Disk.Number) -Offset ([uint64]$newStart) `
                -Size ([uint64]$fallbackSize) -GptType $basic -ErrorAction Stop
        }
        $newNumber = [int]$created.PartitionNumber
        $newP = Get-Partition -DiskNumber ([int]$Disk.Number) `
            -PartitionNumber $newNumber -ErrorAction Stop
        if ([int64]$newP.Offset -ne [int64]$newStart -or
            [int64]$newP.Size -lt $required -or
            [int64]$newP.Size -gt [int64]$RebuildGeometry.NewSize -or
            $newP.DriveLetter -or $newP.IsSystem -or $newP.IsBoot -or
            (Get-GptId $newP) -ne 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7') {
            throw $m.CSExecNewRecoveryMismatch
        }
        Assert-CSOtherPartitionsPreserved $Disk $Parts $C
        Format-Volume -Partition $newP -FileSystem NTFS -NewFileSystemLabel 'Windows RE tools' `
            -Force -Confirm:$false -ErrorAction Stop | Out-Null
        Set-CSRecoveryType $Disk $newNumber
        $root = Open-CSRecoveryMount ([int]$Disk.Number) $newNumber
        try {
            $folder = Join-Path $root 'Recovery\WindowsRE'
            [void](New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop)
            $dest = Join-Path $folder 'Winre.wim'
            Copy-Item -LiteralPath $stageWim -Destination $dest -Force -ErrorAction Stop
            if ((Get-CSFileSha256 $dest) -ne $stageHash) { throw $m.CSExecHashMismatch }
            $reVol = Get-Volume -Partition $newP -ErrorAction Stop
            if ([int64]$reVol.SizeRemaining -lt 250MB) { throw $m.CSExecRecoveryTooSmall }
            Write-Host $m.CSExecRegisterRecovery
            Invoke-CSExternal 'reagentc.exe' @('/setreimage','/path',$folder)
            Invoke-CSExternal 'reagentc.exe' @('/enable')
            $registered = Get-WinReSnapshot
            if (-not $registered.Enabled -or
                [int]$registered.DiskNumber -ne [int]$Disk.Number -or
                [int]$registered.PartitionNumber -ne $newNumber) {
                throw $m.CSExecWinRENotRegistered
            }
        } finally {
            Close-CSRecoveryMount ([int]$Disk.Number)
        }
        $verified = Get-WinReSnapshot
        if (-not $verified.Enabled -or
            [int]$verified.DiskNumber -ne [int]$Disk.Number -or
            [int]$verified.PartitionNumber -ne $newNumber) {
            throw $m.CSExecWinRENotRegistered
        }
        $finalP = Get-Partition -DiskNumber ([int]$Disk.Number) `
            -PartitionNumber $newNumber -ErrorAction Stop
        if (-not (Test-RecoveryPartition $finalP 'GPT')) { throw $m.CSExecRecoveryTypeFailed }
        Assert-CSOtherPartitionsPreserved $Disk $Parts $C
        $completed = $true
        $script:CSExecLastSucceeded = $true
        Write-Host $m.CSNewComplete -ForegroundColor Green
        Write-Host ((& reagentc.exe /info) | Out-String)
    } catch {
        Write-Host ''
        Write-Host ($m.CSExecError -f $_.Exception.Message) -ForegroundColor Red
        $script:CSExecErrorReportedMessage = $_.Exception.Message
        if ($script:CSExecMutated) {
            Write-Host $m.CSExecManualRecovery -ForegroundColor Yellow
            if ($stageWim) { Write-Host ($m.CSExecStagedAt -f $stageWim) -ForegroundColor Yellow }
        }
        throw
    } finally {
        if ($script:CSExecMount) {
            try { Close-CSRecoveryMount ([int]$Disk.Number) }
            catch { Write-Warning $m.CSExecMountRetained }
        }
        if ($completed -or -not $script:CSExecMutated) {
            if ($script:CSExecStaging -and (Test-Path -LiteralPath $script:CSExecStaging -PathType Container)) {
                try { Remove-Item -LiteralPath $script:CSExecStaging -Recurse -Force -ErrorAction Stop }
                catch { Write-Warning $m.CSExecStagingRetained }
            }
        }
    }
}
