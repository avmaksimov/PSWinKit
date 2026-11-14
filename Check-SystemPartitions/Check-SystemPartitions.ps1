#Requires -Version 5.1
# Check-SystemPartitions — interactive system partition diagnostics and repair.
# GPT/NTFS modifications require per-operation selection, prechecks and final confirmation.
# Standard PSWinKit common parameters are optional; no mode switches are needed.

[CmdletBinding()]
param(
    [string]$LanguageFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'


. (Join-Path $PSScriptRoot '..\Common\Common.ps1')
$utility = Start-Utility -ScriptPath $PSCommandPath -RequireAdministrator `
    -LanguageFile $LanguageFile
if ($null -eq $utility) { return }
$m = $utility.Messages
# Execution.ps1 — execution preflight, disk and WinRE changes, staging safety.
# IsoWinRE.ps1 — ISO discovery, image selection and Winre.wim extraction.
# Planning.ps1 — read-only WinRE assessment and partition geometry decisions.
# Cleanup.ps1 — audit and optional deletion of obsolete partitions.
# Common/Common.ps1 — launch, elevation, localization and exit handling.
. (Join-Path $PSScriptRoot 'Execution.ps1')
. (Join-Path $PSScriptRoot 'IsoWinRE.ps1')
. (Join-Path $PSScriptRoot 'Planning.ps1')
. (Join-Path $PSScriptRoot 'Cleanup.ps1')


$script:MiB = [int64]1048576
$script:GiB = [int64]1073741824
# Preserve all physical gaps, including gaps smaller than 1 MiB.
# Do not treat GPT header and partition tables as free space.
$script:KiB = [int64]1024
$script:RecoveryGuid = 'DE94BBA4-06D1-4D40-A16A-BFD50179D6AC'
$script:CSStagingCleanedSuccessfully = $false
$script:CSStagingCleanupAllowed = $false
$script:EfiGuid = 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B'
$script:MsrGuid = 'E3C9E316-0B5C-4DB8-817D-F92DF00215AE'
function Format-PartitionSize([int64]$bytes) {
    if ($bytes -ge $script:GiB) { return ($m.CSSizeGiB -f ([math]::Round($bytes / $script:GiB, 2))) }
    if ($bytes -ge $script:MiB) { return ($m.CSSizeMiB -f ([math]::Round($bytes / $script:MiB, 0))) }
    if ($bytes -ge $script:KiB) { return ($m.CSSizeKiB -f ([math]::Round($bytes / $script:KiB, 2))) }
    return ($m.CSSizeBytes -f $bytes)
}
function Format-ExplorerCapacity([int64]$bytes) {
    # This PC (Explorer) shows the filesystem capacity rather than the partition
    # geometry. Show two decimal digits without rounding up: for example,
    # 129.999996 GiB becomes 129.99 GiB. Explorer itself shows just 129 GiB.
    # Do not use this display value in any geometry calculations.
    if ($bytes -ge $script:GiB) {
        $hundredths = [math]::Floor(($bytes / [double]$script:GiB) * 100)
        return ($m.CSSizeGiB -f ($hundredths / 100))
    }
    if ($bytes -ge $script:MiB) {
        return ($m.CSSizeMiB -f ([math]::Round($bytes / [double]$script:MiB, 1)))
    }
    if ($bytes -ge $script:KiB) {
        return ($m.CSSizeKiB -f ([math]::Round($bytes / [double]$script:KiB, 1)))
    }
    return ($m.CSSizeBytes -f $bytes)
}
function Get-VolumeSizeMap($parts) {
    # Only mounted drive-letter volumes are presented as Explorer capacities.
    # Missing, unformatted and inaccessible volumes fall back to partition size.
    $sizes = @{}
    foreach ($part in $parts) {
        if (-not $part.DriveLetter) { continue }
        try {
            $v = Get-Volume -DriveLetter ([char]$part.DriveLetter) -ErrorAction Stop
            if ($null -ne $v -and [int64]$v.Size -gt 0 -and
                -not [string]::IsNullOrWhiteSpace([string]$v.FileSystem)) {
                $sizes[[string]$part.PartitionNumber] = [int64]$v.Size
            }
        } catch {
            # A failure to read volume capacity must not interrupt diagnostics.
        }
    }
    return $sizes
}
function Format-FreeSpaceSize([int64]$bytes) {
    # Do not round a positive free gap down to zero or hide sub-MiB gaps.
    if ($bytes -ge $script:GiB) { return ($m.CSSizeGiB -f ([math]::Round($bytes / $script:GiB, 2))) }
    if ($bytes -ge $script:MiB) { return ($m.CSSizeMiB -f ([math]::Round($bytes / $script:MiB, 2))) }
    if ($bytes -ge $script:KiB) { return ($m.CSSizeKiB -f ([math]::Round($bytes / $script:KiB, 2))) }
    return ($m.CSSizeBytes -f $bytes)
}
function Format-DetailedSize([int64]$bytes) {
    if ($bytes -ge $script:GiB) {
        return ($m.CSSizeGiB -f ([math]::Round($bytes / [double]$script:GiB, 2)))
    }
    return ($m.CSSizeMiB -f ([math]::Round($bytes / [double]$script:MiB, 2)))
}
function Get-PartitionEnd($part) { return ([int64]$part.Offset + [int64]$part.Size) }
function Get-GptUsableBounds($disk) {
    # Query exact GPT usable boundaries from Windows, not a guessed 33-sector
    # reservation. IOCTL_DISK_GET_DRIVE_LAYOUT_EX is a READ-ONLY query.
    # If it fails, avoid displaying edge gaps as free: they could be GPT metadata.
    try {
        if (-not ([System.Management.Automation.PSTypeName]'PSWinKitGptLayoutReader15').Type) {
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class PSWinKitGptLayoutReader15 {
    [DllImport("kernel32.dll", EntryPoint="CreateFileW", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeviceIoControl(SafeFileHandle device, uint control,
        IntPtr input, uint inputSize, [Out] byte[] output, uint outputSize,
        out uint bytesReturned, IntPtr overlapped);

    public static long[] GetUsableBounds(int diskNumber) {
        if (diskNumber < 0) throw new ArgumentOutOfRangeException("diskNumber");
        // Access 0: query device metadata only, without opening disk for writes.
        using (SafeFileHandle handle = CreateFile(@"\\.\PhysicalDrive" + diskNumber,
            0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            byte[] buffer = new byte[65536];
            uint count;
            if (!DeviceIoControl(handle, 0x00070050, IntPtr.Zero, 0, buffer,
                (uint)buffer.Length, out count, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            // DRIVE_LAYOUT_INFORMATION_EX: PartitionStyle DWORD at 0;
            // GPT=1 (MBR=0, RAW=2); union GPT data at 8, usable start at 24, length at 32.
            if (count < 44 || BitConverter.ToInt32(buffer, 0) != 1)
                throw new InvalidOperationException("Unexpected GPT drive layout");
            long start = BitConverter.ToInt64(buffer, 24);
            long length = BitConverter.ToInt64(buffer, 32);
            if (start < 0 || length <= 0 || start > long.MaxValue - length)
                throw new InvalidOperationException("Invalid GPT usable bounds");
            return new long[] { start, start + length };
        }
    }
}
'@ -ErrorAction Stop
        }
        $bounds = [PSWinKitGptLayoutReader15]::GetUsableBounds([int]$disk.Number)
        if ([int64]$bounds[0] -ge [int64]$bounds[1] -or
            [int64]$bounds[1] -gt [int64]$disk.Size) {
            throw 'GPT usable bounds outside disk size.'
        }
        return [pscustomobject]@{ Start = [int64]$bounds[0]; End = [int64]$bounds[1] }
    }
    catch { return $null }
}
function Get-UsableDiskBounds($disk, $parts) {
    if ([string]$disk.PartitionStyle -eq 'GPT') {
        $bounds = Get-GptUsableBounds $disk
        if ($null -eq $bounds) { return $null }
        # Sanity check: every known partition must fall inside the GPT usable range.
        foreach ($p in $parts) {
            if ([int64]$p.Offset -lt [int64]$bounds.Start -or
                (Get-PartitionEnd $p) -gt [int64]$bounds.End) { return $null }
        }
        return $bounds
    }
    # MBR uses its first logical sector for partition-table metadata.
    $sector = [int64]$disk.LogicalSectorSize
    if ($sector -lt 512) { $sector = 512 }
    return [pscustomobject]@{ Start = $sector; End = [int64]$disk.Size }
}
function Add-FreeRow($records, [int64]$start, [int64]$end) {
    if ($end -le $start) { return }
    $bytes = [int64]($end - $start)
    $records.Add([pscustomobject]@{
        Number = '-'; Name = $m.CSUnallocated; Size = (Format-FreeSpaceSize $bytes);
        Role = $m.CSRoleFree; Recommendation = ''; Kind = 'Free'; PartitionNumber = -1;
        Offset = $start; Bytes = $bytes
    })
}
function Get-GptId($part) { return ([string]$part.GptType).Trim('{}').ToUpperInvariant() }
function Test-RecoveryPartition($part, [string]$style) {
    if ($null -eq $part) { return $false }
    if ($style -eq 'GPT') { return ((Get-GptId $part) -eq $script:RecoveryGuid) }
    if ($style -ne 'MBR') { return $false }

    # Some MSFT_Partition adapters expose MbrType through an adapted property,
    # which is not necessarily present in PSObject.Properties['MbrType'].
    # Read the value directly: 39 (decimal) is the MBR Recovery ID 0x27.
    $mbr = $null
    try { $mbr = $part.MbrType } catch { }
    if ($null -ne $mbr -and -not [string]::IsNullOrWhiteSpace([string]$mbr)) {
        $text = ([string]$mbr).Trim()
        if ($text -match '^(?i:Recovery|0x27)$') { return $true }
        try {
            return ([uint16]::Parse($text, [System.Globalization.NumberStyles]::Integer,
                [System.Globalization.CultureInfo]::InvariantCulture) -eq [uint16]39)
        } catch { return $false }
    }
    # Fallback only when the Storage adapter does not expose MbrType.
    # Never override a known, non-Recovery MBR ID by a friendly Type label.
    return (([string]$part.Type).Trim() -match '^(?i:Recovery|0x27)$')
}
# Prefer hypervisor-specific manufacturer/model evidence. A Hyper-V host may
# report HypervisorPresent, so that property must not classify a physical host as a VM.
function Get-CSMachineType {
    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $manufacturer = [string]$computer.Manufacturer
        $model = [string]$computer.Model
        $description = ($manufacturer + ' ' + $model).Trim()
        if (-not $description) { throw 'Manufacturer and Model are empty.' }
        $platform = ''
        if ($description -match '(?i)VMware') { $platform = 'VMware' }
        elseif ($description -match '(?i)VirtualBox|innotek') { $platform = 'VirtualBox' }
        elseif ($description -match '(?i)QEMU|KVM|Proxmox|Standard PC \(Q35|Standard PC \(i440FX') {
            $platform = 'KVM/QEMU'
        }
        elseif ($description -match '(?i)Xen|HVM domU') { $platform = 'Xen' }
        elseif ($description -match '(?i)Parallels') { $platform = 'Parallels' }
        elseif ($description -match '(?i)bhyve') { $platform = 'bhyve' }
        elseif ($description -match '(?i)Nutanix|AHV') { $platform = 'Nutanix AHV' }
        elseif ($description -match '(?i)Virtual Machine|OpenStack|Google Compute Engine|Amazon EC2') {
            $platform = if ($manufacturer -match '(?i)Microsoft') { 'Hyper-V' }
                        else { $description }
        }
        return [pscustomobject]@{
            IsVirtual = (-not [string]::IsNullOrEmpty($platform))
            IsKnown = $true
            Platform = $platform
        }
    } catch {
        return [pscustomobject]@{ IsVirtual = $false; IsKnown = $false; Platform = '' }
    }
}

function Get-WinReSnapshot {
    # Run REAgentC directly. A UNC working directory is safe here and native
    # stderr never becomes a PowerShell error record when $ErrorActionPreference
    # is Stop (Windows PowerShell 5.1).
    $command = Get-Command 'reagentc.exe' -CommandType Application -ErrorAction Stop
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $command.Source
    $start.Arguments = '/info'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WorkingDirectory = $env:SystemRoot
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Console]::OutputEncoding
    $start.StandardErrorEncoding = [Console]::OutputEncoding
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw ($m.ReInfoFailed -f '') }
        # Both streams are consumed concurrently to avoid pipe-buffer deadlock.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = ($stdout.GetAwaiter().GetResult() + [Environment]::NewLine +
            $stderr.GetAwaiter().GetResult()).Trim()
        if ($process.ExitCode -ne 0) { throw ($m.ReInfoFailed -f $output) }
    } finally {
        $process.Dispose()
    }
    $status = [regex]::Match($output,
      '(?im)^\s*[^:\r\n]+:\s*(Enabled|Disabled|\u0412\u043a\u043b\u044e\u0447\u0435\u043d\u043e|\u041e\u0442\u043a\u043b\u044e\u0447\u0435\u043d\u043e)\s*$')
    if (-not $status.Success) { throw ($m.ReInfoParseFailed -f $output) }
    $enabled = $status.Groups[1].Value -match '^(Enabled|\u0412\u043a\u043b\u044e\u0447\u0435\u043d\u043e)$'
    $location = [regex]::Match($output, '(?i)harddisk(\d+)\\partition(\d+)')
    $diskNo = $null; $partNo = $null
    if ($location.Success) {
        $diskNo = [int]$location.Groups[1].Value
        $partNo = [int]$location.Groups[2].Value
    }
    return [pscustomobject]@{ Enabled = [bool]$enabled; DiskNumber = $diskNo; PartitionNumber = $partNo; Output = $output }
}
function Get-PartitionRole($part, [string]$style, [int]$cNumber, $reInfo, [int]$diskNumber) {
    $n = [int]$part.PartitionNumber
    if ($n -eq $cNumber) { return 'Windows' }
    if ($style -eq 'GPT' -and (Get-GptId $part) -eq $script:EfiGuid) { return 'EFI' }
    if ($style -eq 'GPT' -and (Get-GptId $part) -eq $script:MsrGuid) { return 'MSR' }
    if (Test-RecoveryPartition $part $style) {
        if ($reInfo.Enabled -and $reInfo.DiskNumber -eq $diskNumber -and $reInfo.PartitionNumber -eq $n) { return 'RecoveryActive' }
        return 'RecoveryOther'
    }
    if ($part.IsSystem -or $part.IsBoot -or $part.IsActive) { return 'BootOther' }
    if ([string]$part.Type -match '(?i)OEM|Reserved|Unknown') { return 'Unknown' }
    if ($part.DriveLetter) { return 'Data' }
    return 'Unknown'
}
function Get-RoleLabel([string]$role) {
    switch ($role) {
        Windows { return $m.CSRoleWindows }
        EFI { return $m.CSRoleEFI }
        MSR { return $m.CSRoleMSR }
        RecoveryActive { return $m.CSRoleRecoveryActive }
        RecoveryOther { return $m.CSRoleRecoveryOther }
        BootOther { return $m.CSRoleBootOther }
        Data { return $m.CSRoleData }
        default { return $m.CSRoleUnknown }
    }
}
function New-PartitionRows($disk, $c, $parts, $reInfo, $usableBounds, $volumeSizeMap) {
    $records = New-Object 'System.Collections.Generic.List[object]'
    $cursor = [int64]0
    $hadPartition = $false
    foreach ($part in @($parts | Sort-Object Offset)) {
        $start = [int64]$part.Offset
        if ($start -gt $cursor -and ($hadPartition -or $null -ne $usableBounds)) {
            $gapStart = [int64]$cursor
            $gapEnd = [int64]$start
            if ($null -ne $usableBounds) {
                $gapStart = [int64][math]::Max($gapStart, [int64]$usableBounds.Start)
                $gapEnd = [int64][math]::Min($gapEnd, [int64]$usableBounds.End)
            }
            Add-FreeRow $records $gapStart $gapEnd
        }
        $role = Get-PartitionRole $part ([string]$disk.PartitionStyle) ([int]$c.PartitionNumber) $reInfo ([int]$disk.Number)
        # A tiny basic-data volume ahead of Windows can be an obsolete installer/OEM
        # leftover, but size alone never authorizes deletion. This is REVIEW ONLY.
        $smallData = ($role -eq 'Data' -and
            [int64]$part.Size -le [int64]128MB -and
            [int64]$part.Offset -lt [int64]$c.Offset -and
            -not $part.IsBoot -and -not $part.IsSystem -and -not $part.IsActive)
        $recommendation = ''
        if ($role -eq 'RecoveryOther') { $recommendation = $m.CSRecommendOtherRecovery }
        elseif ($smallData) { $recommendation = $m.CSRecommendSmallData }
        elseif ($role -eq 'Unknown') { $recommendation = $m.CSRecommendUnknown }
        elseif ($role -eq 'EFI' -and [int64]$part.Offset -ge (Get-PartitionEnd $c)) {
            $recommendation = $m.CSRecommendEFIAfterC
        }
        $letter = if ($part.DriveLetter) { ([string]$part.DriveLetter + ':') } else { '' }
        $displaySize = Format-PartitionSize ([int64]$part.Size)
        $partKey = [string]$part.PartitionNumber
        if ($letter -and $null -ne $volumeSizeMap -and $volumeSizeMap.ContainsKey($partKey)) {
            $displaySize = Format-ExplorerCapacity ([int64]$volumeSizeMap[$partKey])
        }
        $records.Add([pscustomobject]@{
            Number = [string]$part.PartitionNumber
            Name = $letter
            Size = $displaySize
            Role = (Get-RoleLabel $role)
            Recommendation = $recommendation
            Kind = $role
            SimulationCandidate = [bool]($role -eq 'RecoveryOther' -or $smallData)
            PartitionNumber = [int]$part.PartitionNumber
            Offset = [int64]$part.Offset
            Bytes = [int64]$part.Size
        })
        $cursor = [math]::Max($cursor, (Get-PartitionEnd $part))
        $hadPartition = $true
    }
    # A GPT disk's backup header and partition-entry array are NOT free space.
    # With unknown usable bounds, omit edge gaps rather than mislabel metadata.
    if ($null -ne $usableBounds) {
        $gapStart = [int64][math]::Max([int64]$cursor, [int64]$usableBounds.Start)
        Add-FreeRow $records $gapStart ([int64]$usableBounds.End)
    }
    return @($records.ToArray())
}
function Show-Partitions($records, [string]$title = '', [bool]$showFootnote = $true) {
    if ([string]::IsNullOrWhiteSpace($title)) { $title = $m.CSTableTitle }
    Write-Host ''
    Write-Host ('=== ' + $title + ' ===') -ForegroundColor Cyan
    $tableRows = @($records | ForEach-Object {
        [pscustomobject]@{
            ($m.CSColNumber) = $_.Number
            ($m.CSColVolume) = $_.Name
            ($m.CSColSize) = $_.Size
            ($m.CSColRole) = $_.Role
            ($m.CSColRecommendation) = $_.Recommendation
        }
    })
    # Explicit wide formatting prevents Format-Table dropping long recommendations.
    $width = 150
    try { $width = [math]::Max(110, [int]$Host.UI.RawUI.WindowSize.Width) } catch { }
    Write-Host (($tableRows | Format-Table -Wrap -AutoSize | Out-String -Width $width).TrimEnd())
    # A footnote clarifies that an EFI partition after C: need not be relocated.
    if ($showFootnote -and
        @($records | Where-Object { $_.Kind -eq 'EFI' -and $_.Recommendation -eq $m.CSRecommendEFIAfterC }).Count -gt 0) {
        Write-Host ''
        Write-Host (' * ' + $m.CSEfiFootnote)
    }
}
function Test-DeletionCandidate($row) {
    # Explicitly exclude ordinary data partitions, boot/EFI/MSR, Windows, and active WinRE.
    # Small *pre-Windows* data volumes are simulation-only and need manual review.
    return ($row.Kind -eq 'RecoveryOther' -or
        ($row.Kind -eq 'Data' -and $row.SimulationCandidate -eq $true))
}
function Align-UpMiB([int64]$bytes) {
    $rem = $bytes % $script:MiB
    if ($rem -eq 0) { return [int64]$bytes }
    return [int64]($bytes + $script:MiB - $rem)
}
function Align-DownMiB([int64]$bytes) {
    return [int64]($bytes - ($bytes % $script:MiB))
}
function Get-CRoundProposal($c, $volume) {
    if ($null -eq $volume -or [int64]$volume.Size -le 0) { return $null }
    $fsBytes = [int64]$volume.Size
    $partBytes = [int64]$c.Size
    $deltaBytes = [int64]([math]::Max([int64]0, ($partBytes - $fsBytes)))
    $nearestGiB = [int64][math]::Floor(($fsBytes / [double]$script:GiB) + 0.5)
    if ($nearestGiB -lt 1) { return $null }
    $desiredFS = [int64]($nearestGiB * $script:GiB)
    if ($fsBytes -eq $desiredFS) { return $null }
    # Align the END offset to 1 MiB, not only the total size. Allow for NTFS
    # being slightly smaller than the partition (4 KiB on test machine).
    # The 1 MiB reserve is an advisory margin, not a resize guarantee.
    $minimumEnd = [int64]$c.Offset + $desiredFS + $deltaBytes
    $targetEnd = Align-UpMiB $minimumEnd
    $targetSize = [int64]($targetEnd - [int64]$c.Offset)
    if ($targetSize -eq $partBytes) {
        if ($fsBytes -lt $desiredFS) { $targetSize = [int64]($partBytes + $script:MiB) }
        else { return $null }
    }
    return [pscustomobject]@{
        TargetExplorerGiB = $nearestGiB
        OriginalPartitionBytes = $partBytes
        CurrentVolumeBytes = $fsBytes
        TargetPartitionBytes = $targetSize
        ChangeBytes = [int64]($targetSize - $partBytes)
        FilesystemDifferenceBytes = $deltaBytes
    }
}
function Get-ActiveRecovery($parts, $reInfo, [int]$diskNumber, [string]$style) {
    if (-not $reInfo.Enabled -or $null -eq $reInfo.PartitionNumber -or
        $null -eq $reInfo.DiskNumber -or [int]$reInfo.DiskNumber -ne $diskNumber) { return $null }
    foreach ($p in $parts) {
        if ([int]$p.PartitionNumber -eq [int]$reInfo.PartitionNumber -and
            (Test-RecoveryPartition $p $style)) { return $p }
    }
    return $null
}
function Get-RebuildPreview($disk, $c, $parts, $activeRecovery, [int64]$proposedCSize) {
    if ($null -eq $activeRecovery) { return $null }
    $cEnd = Get-PartitionEnd $c
    $reStart = [int64]$activeRecovery.Offset
    $reEnd = Get-PartitionEnd $activeRecovery
    # Only the physically next Recovery can be recreated in this workflow.
    foreach ($p in $parts) {
        if ([int]$p.PartitionNumber -eq [int]$c.PartitionNumber -or
            [int]$p.PartitionNumber -eq [int]$activeRecovery.PartitionNumber) { continue }
        if ([int64]$p.Offset -ge $cEnd -and [int64]$p.Offset -lt $reStart) { return $null }
    }
    if ($reStart -lt $cEnd) { return $null }
    # Preview use of the entire contiguous extent up to the next existing
    # partition (optional deletion choices are not included in this boundary). Only the new Recovery START is aligned to 1 MiB. Its end can
    # use the next partition's sector-aligned start as a boundary; it need not
    # be rounded down to 1 MiB here. The Storage API must validate the exact
    # size again at execution time, before any destructive operation.
    $newStart = Align-UpMiB ([int64]([int64]$c.Offset + $proposedCSize))
    $nextStarts = @($parts | Where-Object {
        [int]$_.PartitionNumber -ne [int]$activeRecovery.PartitionNumber -and
        [int64]$_.Offset -ge $reEnd
    } | Sort-Object Offset)
    $newEnd = [int64]$reEnd
    if ($nextStarts.Count -gt 0) {
        $nextOffset = [int64]$nextStarts[0].Offset
        # A real partition offset must be aligned to the logical sector size.
        # Keep a gap if this invariant is unexpectedly violated.
        $sector = [int64]$disk.LogicalSectorSize
        if ($sector -lt 512 -or ($nextOffset % $sector) -ne 0) { return $null }
        $newEnd = $nextOffset
    }
    if ($newEnd -le $newStart) { return $null }
    $newSize = [int64]($newEnd - $newStart)
    return [pscustomobject]@{
        OldNumber = [int]$activeRecovery.PartitionNumber
        OldSize = [int64]$activeRecovery.Size
        NewStart = $newStart
        NewSize = $newSize
        AbsorbedGapBytes = [int64]($newEnd - $reEnd)
        IsGeometryPossible = [bool]($newSize -gt 0)
    }
}
function New-ProjectedPartition($part, [int64]$offset, [int64]$size) {
    # A detached view used only by the read-only geometry renderer.
    $mbr = if ($part.PSObject.Properties['MbrType']) { $part.MbrType } else { '' }
    $gpt = if ($part.PSObject.Properties['GptType']) { $part.GptType } else { '' }
    return [pscustomobject]@{
        PartitionNumber = [int]$part.PartitionNumber
        Offset = $offset
        Size = $size
        DriveLetter = $part.DriveLetter
        Type = $part.Type
        GptType = $gpt
        MbrType = $mbr
        IsBoot = [bool]$part.IsBoot
        IsSystem = [bool]$part.IsSystem
        IsActive = [bool]$part.IsActive
    }
}
function New-ProjectedLayout($parts, $c, $activeRecovery, [int64]$plannedCSize, $rebuildGeometry,
    [int[]]$excludedNumbers) {
    $view = New-Object 'System.Collections.Generic.List[object]'
    foreach ($part in $parts) {
        if ([int]$part.PartitionNumber -in $excludedNumbers) { continue }
        $offset = [int64]$part.Offset
        $size = [int64]$part.Size
        if ([int]$part.PartitionNumber -eq [int]$c.PartitionNumber) {
            $size = $plannedCSize
        } elseif ($null -ne $rebuildGeometry -and $null -ne $activeRecovery -and
            [int]$part.PartitionNumber -eq [int]$activeRecovery.PartitionNumber) {
            $offset = [int64]$rebuildGeometry.NewStart
            $size = [int64]$rebuildGeometry.NewSize
        }
        $view.Add((New-ProjectedPartition $part $offset $size))
    }
    return @($view.ToArray() | Sort-Object Offset)
}
# Hypothetical Recovery for the shared before/after partition table. The new
# partition has no number yet; this function never changes the live disk.
function New-CSProjectedRecovery($disk, [int64]$start, [int64]$size) {
    return [pscustomobject]@{
        PartitionNumber = 0; Offset = $start; Size = $size; DriveLetter = $null
        Type = 'Recovery'
        GptType = if ([string]$disk.PartitionStyle -eq 'GPT') {
            '{' + $script:RecoveryGuid + '}'
        } else { '' }
        MbrType = if ([string]$disk.PartitionStyle -eq 'MBR') { [uint16]0x27 } else { $null }
        IsBoot = $false; IsSystem = $false; IsActive = $false
    }
}

# Reuse New-ProjectedLayout/New-PartitionRows/Show-Partitions instead of a
# second text-only plan UI for an inactive, undersized Recovery.
function Show-CSInactiveSmallPreview($disk, $c, $parts, $source, $proposal,
    $reInfo, $bounds, $volumeSizes) {
    $excluded = if ($proposal.Mode -eq 'Adjacent') {
        @([int]$source.PartitionNumber)
    } else { @() }
    $editedRecovery = if ($proposal.Mode -eq 'Right') { $source } else { $null }
    $geometry = if ($proposal.Mode -eq 'Right') { $proposal } else { $null }
    $view = @(New-ProjectedLayout $parts $c $editedRecovery `
        ([int64]$proposal.TargetPartitionBytes) $geometry $excluded)
    if ($proposal.Mode -ne 'Right') {
        $view = @($view + @(New-CSProjectedRecovery $disk `
            ([int64]$proposal.NewStart) ([int64]$proposal.NewSize)) | Sort-Object Offset)
    }
    $cView = @($view | Where-Object {
        [int]$_.PartitionNumber -eq [int]$c.PartitionNumber
    })
    if ($cView.Count -ne 1) { throw $m.CSExecLayoutChanged }
    $sizes = @{}
    foreach ($key in $volumeSizes.Keys) { $sizes[$key] = [int64]$volumeSizes[$key] }
    $cKey = [string]$c.PartitionNumber
    if ($sizes.ContainsKey($cKey)) {
        $sizes[$cKey] = [int64]($sizes[$cKey] +
            [int64]$proposal.TargetPartitionBytes - [int64]$c.Size)
    }
    # Estimated NTFS volume size, not a promise about the live filesystem.
    # A recreated Recovery is left unmeasured; show its partition size only.
    $sizes.Remove([string]$source.PartitionNumber) | Out-Null
    $rows = @(New-PartitionRows $disk $cView[0] $view $reInfo `
        (Get-PreviewBounds $bounds $parts) $sizes)
    foreach ($row in $rows) {
        if ($row.Kind -eq 'RecoveryOther' -and [int]$row.PartitionNumber -eq 0) {
            $row.Number = '+'
            $row.Role = $m.CS26NewRecovery
            $row.Recommendation = ''
        } elseif ($row.Kind -eq 'RecoveryOther' -and
            [int]$row.PartitionNumber -eq [int]$source.PartitionNumber) {
            $row.Role = $m.CSInactiveRecoveryRole
            $row.Recommendation = ''
        }
    }
    Show-Partitions $rows $m.CSSimulationLayoutTitle $false
    Write-Host $m.CSSimulationLayoutNotice -ForegroundColor Yellow
}

function Get-PreviewBounds($usableBounds, $originalParts) {
    if ($null -ne $usableBounds) { return $usableBounds }
    # Even if the GPT ioctl fails, locations that were occupied by known
    # partitions are safe to show as hypothetically free after their removal.
    # Unknown edge space outside the original partition span remains hidden.
    $sorted = @($originalParts | Sort-Object Offset)
    if ($sorted.Count -eq 0) { return $null }
    $edge = [int64]0
    foreach ($part in $sorted) { $edge = [math]::Max($edge, (Get-PartitionEnd $part)) }
    return [pscustomobject]@{ Start = [int64]$sorted[0].Offset; End = [int64]$edge }
}
function Read-YesNo([string]$prompt) {
    # Visually separate the final destructive confirmation from the backup
    # acknowledgement and other preflight output, in every language.
    if ($prompt -eq $m.CSExecFinalConfirm -or $prompt -eq $m.CSNewFinalConfirm -or
        $prompt -eq $m.CSFinalConfirmationQuestion) {
        Write-Host ''
    }
    while ($true) {
        $answer = (Read-Host ($prompt + ' ' + $m.CSYesNo)).Trim().ToUpperInvariant()
        if ($answer -eq 'Y') { return $true }
        if ($answer -eq 'N') { return $false }
        Write-Host $m.CSInvalidYesNo -ForegroundColor Yellow
    }
}


# Explicit MiB allocation choice for new Recovery (never implicit expansion).
function Read-CSRecoveryCExtraMiB([int64]$maximum) {
    while ($true) {
        $inputText = (Read-Host ($m.CSNewCExtraPrompt -f $maximum)).Trim()
        if ($inputText -eq '') { return [int64]0 }
        $chosen = [int64]0
        if ([int64]::TryParse($inputText, [System.Globalization.NumberStyles]::None,
                [System.Globalization.CultureInfo]::InvariantCulture, [ref]$chosen) -and
            $chosen -ge 0 -and $chosen -le $maximum) {
            return $chosen
        }
        Write-Host ($m.CSNewCExtraInvalid -f $maximum) -ForegroundColor Yellow
    }
}

# Read back actual state after successful steps and any optional deletions.
# Do not infer success from old partition numbers: Windows may renumber on reboot.
function Show-CSFinalSummary {
    param($OriginalDisk, $OriginalC, $CleanupAudits)

    $liveDisk = Get-Disk -Number ([int]$OriginalDisk.Number) -ErrorAction Stop
    if ([string]$liveDisk.UniqueId -ne [string]$OriginalDisk.UniqueId) {
        throw $m.CSExecLayoutChanged
    }
    $liveC = Get-Partition -DriveLetter C -ErrorAction Stop
    if ([int]$liveC.DiskNumber -ne [int]$OriginalDisk.Number -or
        [int64]$liveC.Offset -ne [int64]$OriginalC.Offset) {
        throw $m.CSExecLayoutChanged
    }
    $liveParts = @(Get-Partition -DiskNumber ([int]$liveDisk.Number) -ErrorAction Stop | Sort-Object Offset)
    $liveRE = Get-WinReSnapshot
    $liveActive = Get-ActiveRecovery $liveParts $liveRE ([int]$liveDisk.Number) ([string]$liveDisk.PartitionStyle)
    $liveCVolume = Get-Volume -DriveLetter C -ErrorAction Stop

    Write-Host ''
    Write-Host ('=== ' + $m.CSFinalTitle + ' ===') -ForegroundColor Cyan
    Write-Host ($m.CSFinalC -f (Format-ExplorerCapacity ([int64]$liveCVolume.Size)))
    if ($null -ne $liveActive) {
        $reVolume = Get-Volume -Partition $liveActive -ErrorAction Stop
        Write-Host ($m.CSFinalRE -f $liveActive.PartitionNumber,
            (Format-DetailedSize ([int64]$liveActive.Size)),
            (Format-DetailedSize ([int64]$reVolume.SizeRemaining)))
        if ([int64]$reVolume.SizeRemaining -lt [int64]250MB) {
            Write-Host $m.CSFinalFreeWarning -ForegroundColor Yellow
        }
    } else {
        Write-Host $m.CSFinalREUnknown -ForegroundColor Yellow
    }
    $enabledText = if ($liveRE.Enabled) { $m.CSWinREEnabled } else { $m.CSWinREDisabled }
    Write-Host ($m.CSFinalREState -f $enabledText)
    foreach ($audit in @($CleanupAudits | Where-Object { $null -ne $_ })) {
        $remaining = @($liveParts | Where-Object {
            [string]$_.Guid -eq [string]$audit.PartitionGuid -and
            [int64]$_.Offset -eq [int64]$audit.Offset
        })
        $status = if ($remaining.Count -eq 0) { $m.CSFinalRemoved } else { $m.CSFinalRetained }
        Write-Host ($m.CSFinalOptional -f $audit.Number, $status)
    }
    Write-Host $m.CSFinalReboot -ForegroundColor DarkGray

    $liveRows = @(New-PartitionRows $liveDisk $liveC $liveParts $liveRE `
        (Get-UsableDiskBounds $liveDisk $liveParts) (Get-VolumeSizeMap $liveParts))
    Show-Partitions $liveRows $m.CSFinalLayoutTitle
}

$script:CSRunHandled = $false
try {
    Import-Module Storage -ErrorAction Stop
    Write-Host $m.CSFinalInteractiveWarning -ForegroundColor Yellow
    if ($env:SystemDrive -ine 'C:') { throw $m.OnlyC }
    $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuildNumber
    if ($build -lt 14393) { throw $m.OsTooOld }
    $c = Get-Partition -DriveLetter C -ErrorAction Stop
    $disk = Get-Disk -Number ([int]$c.DiskNumber) -ErrorAction Stop
    if ([string]$disk.PartitionStyle -notin @('GPT','MBR')) { throw $m.OnlyGptMbr }
    $parts = @(Get-Partition -DiskNumber ([int]$disk.Number) -ErrorAction Stop | Sort-Object Offset)
    Assert-CSBasicDisk $disk $parts
    $usableBounds = Get-UsableDiskBounds $disk $parts
    $reInfo = Get-WinReSnapshot
    $machineType = Get-CSMachineType
    # Defer any interactive cleanup prompts until after the non-interactive
    # early pending-CHKDSK guard, so a reboot notice always takes priority.
    $volumeSizes = Get-VolumeSizeMap $parts
    $rows = @(New-PartitionRows $disk $c $parts $reInfo $usableBounds $volumeSizes)
    $activeRecovery = Get-ActiveRecovery $parts $reInfo ([int]$disk.Number) ([string]$disk.PartitionStyle)

    Write-Host ''
    Write-Host ('=== ' + $m.CSAnalysisTitle + ' ===') -ForegroundColor Cyan
    $machineLabel = if ($machineType.IsVirtual) {
        $m.CSMachineVirtual -f $machineType.Platform
    } elseif ($machineType.IsKnown) { $m.CSMachinePhysical }
    else { $m.CSMachineUnknown }
    $machineColor = if ($machineType.IsKnown) { 'Gray' } else { 'Yellow' }
    Write-Host ($m.CSMachineType -f $machineLabel) -ForegroundColor $machineColor
    Write-Host $m.CSMachineDetectionNotice -ForegroundColor DarkGray
    Write-Host ($m.CSInfoDisk -f $disk.Number, $disk.PartitionStyle, (Format-PartitionSize ([int64]$disk.Size)))
    $reText = if ($reInfo.Enabled) { $m.CSWinREEnabled } else { $m.CSWinREDisabled }
    $reSuffix = ''
    if ($reInfo.Enabled) {
        if ($null -ne $reInfo.DiskNumber -and $null -ne $reInfo.PartitionNumber) {
            if ([int]$reInfo.DiskNumber -eq [int]$disk.Number) {
                $reSuffix = $m.CSRePartition -f $reInfo.PartitionNumber
            } else {
                $reSuffix = $m.CSReOtherDisk -f $reInfo.DiskNumber, $reInfo.PartitionNumber
            }
        } else { $reSuffix = $m.CSReUnknown }
    }
    Write-Host ($m.CSInfoRe -f $reText, $reSuffix)
    $inactiveRecovery = Get-CSInactiveRecoveryCandidate $disk $c $parts $reInfo

    # Read-only boot check BEFORE any ISO/edition or cleanup prompt.
    if (Test-CSPendingBootCheckC) {
        Write-Host ''
        Write-Host $m.CSFsAlreadyScheduled -ForegroundColor Yellow
        $script:CSRunHandled = $true
        return
    }
    # First give Windows its standard non-repartitioning WinRE recovery path.
    # reagentc /enable changes recovery configuration, so always ask first.
    # A successful attempt ends this run: do not combine it with disk changes.
    if (-not $reInfo.Enabled) {
        Write-Host ''
        Write-Host ('=== ' + $m.CSReEnableTitle + ' ===') -ForegroundColor Cyan
        if (Read-YesNo $m.CSReEnableQuestion) {
            Write-Host $m.CSReEnableRunning -ForegroundColor Cyan
            $enableError = ''
            $enableExitCode = $null
            try {
                Invoke-CSExternal 'reagentc.exe' @('/enable')
            } catch {
                if ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) { throw }
                $enableError = $_.Exception.Message
                # REAgentC prints its own diagnosis. Report only the exit code
                # rather than repeating the same failure in a second sentence.
                if ($null -ne $LASTEXITCODE -and [int]$LASTEXITCODE -ne 0) {
                    $enableExitCode = [int]$LASTEXITCODE
                }
            }
            # The exit code alone is insufficient: REAgentC may have changed
            # registration before returning a failure. Always inspect reality.
            $reInfo = Get-WinReSnapshot
            $parts = @(Get-Partition -DiskNumber ([int]$disk.Number) -ErrorAction Stop | Sort-Object Offset)
            if ($reInfo.Enabled) {
                Write-Host $m.CSReEnableSucceeded -ForegroundColor Green
                $liveActive = Get-ActiveRecovery $parts $reInfo `
                    ([int]$disk.Number) ([string]$disk.PartitionStyle)
                if ($null -ne $liveActive) {
                    Write-Host ($m.CSReEnableRegistered -f $disk.Number, $liveActive.PartitionNumber)
                    try {
                        $check = Get-CSImageAssessment $disk $c $parts $reInfo $liveActive
                        if ($check.Verified) {
                            Write-Host ($m.CSReEnableVerified -f (Format-DetailedSize $check.WIMBytes))
                            if ($null -eq $check.FreeBytes -or
                                [int64]$check.FreeBytes -lt $script:CSFreeReserve) {
                                Write-Host $m.CSReEnableSpaceWarning -ForegroundColor Yellow
                            }
                        } else {
                            Write-Host ($m.CSReEnableVerifyWarning -f $check.Error) -ForegroundColor Yellow
                        }
                    } catch {
                        if ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) { throw }
                        Write-Host ($m.CSReEnableVerifyWarning -f $_.Exception.Message) -ForegroundColor Yellow
                    }
                } else {
                    Write-Host $m.CSReEnableLocationWarning -ForegroundColor Yellow
                }
                if ($enableError) { Write-Host ($m.CSReEnableCommandWarning -f $enableError) -ForegroundColor Yellow }
                Show-CSFinalSummary -OriginalDisk $disk -OriginalC $c -CleanupAudits @()
                $script:CSRunHandled = $true
                return
            }
            if ($enableError) {
                if ($null -ne $enableExitCode) {
                    Write-Host ($m.CSReEnableExitCode -f $enableExitCode) -ForegroundColor Yellow
                } else {
                    Write-Host ($m.CSReEnableFailed -f $enableError) -ForegroundColor Yellow
                }
            } else {
                Write-Host $m.CSReEnableStillDisabled -ForegroundColor Yellow
            }
            # The attempted registration may have updated REAgentC metadata.
            # Do not use stale candidate/partition information afterwards.
            $activeRecovery = Get-ActiveRecovery $parts $reInfo `
                ([int]$disk.Number) ([string]$disk.PartitionStyle)
            $inactiveRecovery = Get-CSInactiveRecoveryCandidate $disk $c $parts $reInfo
            $rows = @(New-PartitionRows $disk $c $parts $reInfo $usableBounds `
                (Get-VolumeSizeMap $parts))
        } else {
            Write-Host $m.CSReEnableSkipped -ForegroundColor DarkGray
        }
    }

    # Assess the *source image* BEFORE offering any size recommendation. At this
    # stage Windows RE is read/validated in place; no WIM is copied to staging.
    Write-Host ''
    Write-Host ('=== ' + $m.CS26ImageTitle + ' ===') -ForegroundColor Cyan
    Write-Host $m.CS26ImageChecking -ForegroundColor DarkGray
    $assessment = if ($null -ne $inactiveRecovery) {
        Get-CSInactiveRecoveryAssessment $disk $c $parts $reInfo $inactiveRecovery
    } else {
        Get-CSImageAssessment $disk $c $parts $reInfo $activeRecovery ([bool]$machineType.IsVirtual)
    }
    if (-not $machineType.IsVirtual -and $null -eq $inactiveRecovery -and
        -not $assessment.Verified -and [string]$disk.PartitionStyle -eq 'MBR') {
        $assessment = Get-CSMissingMBRImageAssessment $disk $c $parts $reInfo $assessment
    }
    $vol = $null
    try { $vol = Get-Volume -DriveLetter C -ErrorAction Stop } catch { }
    if ($assessment.Verified) {
        Write-Host ($m.CS26ImageSource -f $assessment.Source)
        Write-Host ($m.CS26ImageSize -f (Format-DetailedSize $assessment.WIMBytes))
        if ($null -ne $assessment.FreeBytes) {
            Write-Host ($m.CS26CurrentFree -f (Format-DetailedSize ([int64]$assessment.FreeBytes)))
        }
        Write-Host ($m.CS26MinimumSize -f (Format-DetailedSize ([int64]$assessment.MinRecoveryBytes)))
        Write-Host $m.CS27MinimumIncludesMargin -ForegroundColor DarkGray
    } else {
        if ($machineType.IsVirtual -and $null -ne $inactiveRecovery) {
            # REAgentC has already reported its failure, if attempted. State
            # only the image-inspection result for this existing partition.
            Write-Host ($m.CSVmMissingRecoveryImage -f $inactiveRecovery.PartitionNumber) -ForegroundColor Yellow
        } elseif ($machineType.IsVirtual) {
            Write-Host $m.CSVmNoVerifiedImage -ForegroundColor Yellow
        } else {
            Write-Host ($m.CS26ImageUnavailable -f
                (([string]$assessment.Error).TrimEnd().TrimEnd('.'))) -ForegroundColor Yellow
        }
    }
    if ($null -ne $inactiveRecovery -and $assessment.Verified) {
        if ($null -eq $assessment.Existing) {
            # Only when a validated image came from another location: this
            # existing Recovery still cannot be registered automatically.
            Write-Host $m.CSInactiveImageUnavailable -ForegroundColor Yellow
        } elseif ($null -ne $assessment.MinRecoveryBytes -and
            [int64]$inactiveRecovery.Size -lt [int64]$assessment.MinRecoveryBytes) {
            Write-Host ($m.CSInactiveSizeTooSmall -f
                (Format-DetailedSize ([int64]$inactiveRecovery.Size)),
                (Format-DetailedSize ([int64]$assessment.MinRecoveryBytes))) -ForegroundColor Yellow
        } elseif ($null -eq $assessment.FreeBytes -or
            [int64]$assessment.FreeBytes -lt $script:CSFreeReserve) {
            Write-Host $m.CSInactiveVolumeUnsafe -ForegroundColor Yellow
        }
    }
    # In a VM, keep C: as the last partition when it already is; never offer
    # new/recreated Recovery after C:, even for cosmetic C: alignment.
    $proposal = if ($machineType.IsVirtual -or $null -ne $inactiveRecovery) { $null } else {
        Get-CSPlanningDecision $disk $c $parts $reInfo $activeRecovery `
            $assessment $vol $usableBounds
    }
    if (-not $machineType.IsVirtual -and $null -eq $proposal -and
        $null -eq $inactiveRecovery -and [string]$disk.PartitionStyle -eq 'MBR') {
        $proposal = Get-CSMissingMBRPlan $disk $c $parts $reInfo `
            $assessment $vol $usableBounds
    }
    $geometryCandidate = if ($null -ne $proposal) { $proposal.Geometry } else { $null }
    $canPreviewC = ($null -ne $geometryCandidate -and $geometryCandidate.IsGeometryPossible)
    $cRow = @($rows | Where-Object { $_.Kind -eq 'Windows' } | Select-Object -First 1)
    if ($cRow.Count -eq 1 -and $canPreviewC) {
        if ($proposal.Beauty) {
            $cRow[0].Recommendation = $m.CSRecommendRoundCWithRE -f $proposal.TargetExplorerGiB
        } elseif ($proposal.MustRepair) {
            if ($reInfo.Enabled -and $null -ne $assessment.FreeBytes -and
                [int64]$assessment.FreeBytes -lt $script:CSFreeReserve) {
                $cRow[0].Recommendation = $m.CS284RecommendIncreaseRecovery
            } else {
                $recoveryPartitions = @($parts | Where-Object {
                    Test-RecoveryPartition $_ ([string]$disk.PartitionStyle)
                })
                if ($proposal.MigratingWinREOnC) {
                    $cRow[0].Recommendation = $m.CSMBRRecommendMoveWinRE
                } elseif (-not $reInfo.Enabled -and $recoveryPartitions.Count -eq 0) {
                    $cRow[0].Recommendation = $m.CS26RecommendationCreateMissing
                } else {
                    $cRow[0].Recommendation = $m.CS26RecommendationRepair
                }
            }
        }
    }
    if ($null -ne $inactiveRecovery) {
        $inactiveRows = @($rows | Where-Object {
            [int]$_.PartitionNumber -eq [int]$inactiveRecovery.PartitionNumber
        })
        if ($inactiveRows.Count -eq 1) {
            $inactiveRows[0].Role = $m.CSInactiveRecoveryRole
            $inactiveRows[0].Recommendation = if (
                Test-CSInactiveRecoveryReady $disk $inactiveRecovery $assessment) {
                $m.CSInactiveRecoveryRecommendation
            } else { $m.CSInactiveRecoveryReview }
        }
    }
    Show-Partitions $rows
    if ($null -eq $usableBounds) {
        Write-Host $m.CSGptBoundsUnavailable -ForegroundColor Yellow
    }

    if ($machineType.IsVirtual -and -not $reInfo.Enabled) {
        Write-Host ''
        Write-Host $m.CSVmPreserveTail -ForegroundColor DarkGray
    }
    if ($null -eq $vol) { Write-Host $m.CSPlanNoCapacity -ForegroundColor Yellow }
    # WinRE registered on C: is known; it is not a missing/unknown WinRE.
    # The supported MBR migration intentionally has no separate Recovery yet.
    if ($reInfo.Enabled -and $null -eq $activeRecovery -and
        -not ($null -ne $proposal -and $proposal.MigratingWinREOnC)) {
        Write-Host $m.CSActiveRecoveryUnknown -ForegroundColor Yellow
    }

    # Disabled WinRE with one valid image on a separate Recovery partition of
    # THIS physical system disk: register in place, without repartitioning.
    # Do not offer a destructive Recovery operation in this same run.
    if (Test-CSInactiveRecoveryReady $disk $inactiveRecovery $assessment) {
        Write-Host ''
        Write-Host ('=== ' + $m.CSProposedPlanTitle + ' ===') -ForegroundColor Cyan
        Write-Host ($m.CSInactiveRecoveryPlan -f $disk.Number, $inactiveRecovery.PartitionNumber)
        if (Invoke-CSRegisterInactiveRecovery $disk $c $inactiveRecovery $reInfo) {
            Show-CSFinalSummary -OriginalDisk $disk -OriginalC $c -CleanupAudits @()
            $script:CSStagingCleanupAllowed = $true
        }
        $script:CSRunHandled = $true
        return
    }

    # A too-small inactive Recovery must not be registered in place. First
    # prefer its right-side free space, then a guarded C: shrink. If D: sits
    # between C: and the old Recovery, create a NEW Recovery before D: and
    # retain the old partition for a later, separately audited cleanup.
    if (-not $machineType.IsVirtual -and $null -ne $inactiveRecovery -and
        $assessment.Verified -and $null -ne $assessment.Existing -and
        -not (Test-CSInactiveRecoveryReady $disk $inactiveRecovery $assessment)) {
        $smallPlan = Get-CSInactiveSmallRecoveryPlan $disk $c $parts $reInfo `
            $inactiveRecovery $assessment $usableBounds
        if ($null -ne $smallPlan) {
            Write-Host ''
            Write-Host ('=== ' + $m.CSPlanSelectionTitle + ' ===') -ForegroundColor Cyan
            if (-not (Read-YesNo $m.CSInactiveSmallSelect)) {
                Write-Host $m.CSExecCancelled -ForegroundColor Yellow
                $script:CSRunHandled = $true
                return
            }
            Write-Host ''
            Write-Host ('=== ' + $m.CSProposedPlanTitle + ' ===') -ForegroundColor Cyan
            if ($smallPlan.Mode -eq 'Right') {
                Write-Host ($m.CSInactiveSmallRight -f $inactiveRecovery.PartitionNumber,
                    (Format-DetailedSize $smallPlan.NewSize))
            } elseif ($smallPlan.Mode -eq 'Adjacent') {
                Write-Host ($m.CSInactiveSmallAdjacent -f $inactiveRecovery.PartitionNumber,
                    (Format-DetailedSize $smallPlan.NewSize))
            } else {
                Write-Host ($m.CSInactiveSmallBeforeD -f
                    (Format-DetailedSize $smallPlan.NewSize))
            }
            if ([int64]$smallPlan.ChangeBytes -lt 0) {
                Write-Host ($m.CSInactiveSmallShrink -f
                    (Format-DetailedSize ([int64][math]::Abs($smallPlan.ChangeBytes))))
            }
            if ($smallPlan.Mode -eq 'BeforeD') {
                if ([string]$disk.PartitionStyle -eq 'GPT') {
                    Write-Host $m.CSInactiveSmallCleanupOffer -ForegroundColor Yellow
                } else {
                    Write-Host $m.CSInactiveSmallCleanupMBR -ForegroundColor Yellow
                }
            }
            Write-Host $m.CSPlanReValidation -ForegroundColor Yellow
            Write-Host $m.CSPreviewCalculating -ForegroundColor DarkGray
            Show-CSInactiveSmallPreview $disk $c $parts $inactiveRecovery `
                $smallPlan $reInfo $usableBounds $volumeSizes
            Invoke-CSRepairSmallInactiveRecovery $disk $c $parts $reInfo `
                $inactiveRecovery $smallPlan
            if ($script:CSExecLastSucceeded) {
                $oldAudits = @()
                # An obsolete Recovery can be audited only AFTER the new WinRE
                # has passed registration/size checks. Cleanup is independently
                # optional; the initial simulated table keeps the old partition.
                if ($smallPlan.Mode -eq 'BeforeD' -and
                    [string]$disk.PartitionStyle -eq 'GPT') {
                    Write-Host ''
                    Write-Host ('=== ' + $m.CS28AuditTitle + ' ===') -ForegroundColor Cyan
                    $liveDisk = Get-Disk -Number ([int]$disk.Number) -ErrorAction Stop
                    if ([string]$liveDisk.UniqueId -ne [string]$disk.UniqueId) {
                        throw $m.CSExecLayoutChanged
                    }
                    $liveC = Get-Partition -DriveLetter C -ErrorAction Stop
                    $liveRE = Get-WinReSnapshot
                    if (-not $liveRE.Enabled -or
                        [int]$liveRE.DiskNumber -ne [int]$disk.Number -or
                        $null -eq $liveRE.PartitionNumber) {
                        throw $m.CSExecWinRENotRegistered
                    }
                    $newPart = Get-Partition -DiskNumber ([int]$disk.Number) `
                        -PartitionNumber ([int]$liveRE.PartitionNumber) -ErrorAction Stop
                    if (-not (Test-RecoveryPartition $newPart 'GPT') -or
                        [int64]$newPart.Offset -eq [int64]$inactiveRecovery.Offset -or
                        [string]$newPart.Guid -eq [string]$inactiveRecovery.Guid) {
                        throw $m.CSExecWinRENotRegistered
                    }
                    $newVolume = Get-Volume -Partition $newPart -ErrorAction Stop
                    if ([int64]$newVolume.SizeRemaining -lt $script:CSFreeReserve) {
                        throw $m.CSExecRecoveryTooSmall
                    }
                    $oldParts = @(Get-Partition -DiskNumber ([int]$disk.Number) `
                        -ErrorAction Stop | Where-Object {
                            [int64]$_.Offset -eq [int64]$inactiveRecovery.Offset -and
                            [int64]$_.Size -eq [int64]$inactiveRecovery.Size -and
                            [string]$_.Guid -eq [string]$inactiveRecovery.Guid
                        })
                    if ($oldParts.Count -ne 1) { throw $m.CSExecLayoutChanged }
                    $audit = Get-CSCleanupCandidateAudit $liveDisk $liveC `
                        $oldParts[0] 'RecoveryOther' $liveRE
                    Show-CSCleanupCandidateAudit $audit
                    if ($audit.Permitted) {
                        $oldAudits = @($audit)
                        Write-Host $m.CSInactiveSmallCleanupSeparate -ForegroundColor Yellow
                        Invoke-CSOptionalPartitionDeletion -disk $liveDisk -c $liveC `
                            -audits $oldAudits -BackupAlreadyConfirmed
                    } else {
                        Write-Host $m.CSInactiveSmallCleanupBlocked -ForegroundColor Yellow
                    }
                } elseif ($smallPlan.Mode -eq 'BeforeD') {
                    Write-Host $m.CSInactiveSmallCleanupMBR -ForegroundColor Yellow
                }
                Show-CSFinalSummary -OriginalDisk $disk -OriginalC $c `
                    -CleanupAudits $oldAudits
                # Final success (and removal of rescue files) requires a real,
                # enabled WinRE on this physical disk, not merely a printed table.
                $verifiedRE = Get-WinReSnapshot
                if (-not $verifiedRE.Enabled -or
                    $null -eq $verifiedRE.DiskNumber -or
                    $null -eq $verifiedRE.PartitionNumber -or
                    [int]$verifiedRE.DiskNumber -ne [int]$disk.Number) {
                    throw $m.CSExecWinRENotRegistered
                }
                $verifiedPartition = Get-Partition -DiskNumber ([int]$disk.Number) `
                    -PartitionNumber ([int]$verifiedRE.PartitionNumber) -ErrorAction Stop
                if (-not (Test-RecoveryPartition $verifiedPartition ([string]$disk.PartitionStyle))) {
                    throw $m.CSExecRecoveryTypeFailed
                }
                $verifiedVolume = Get-Volume -Partition $verifiedPartition -ErrorAction Stop
                if ([int64]$verifiedVolume.SizeRemaining -lt $script:CSFreeReserve) {
                    throw $m.CSExecRecoveryTooSmall
                }
                $script:CSStagingCleanupAllowed = $true
            }
            $script:CSRunHandled = $true
            return
        }
        Write-Host $m.CSInactiveSmallNoSafePlan -ForegroundColor Yellow
    }

    $selected = New-Object 'System.Collections.Generic.List[int]'
    $optimiseC = $false
    # Initialize a real array: an empty @() emitted from an if-expression
    # becomes $null in PowerShell 5.1, and $null.Count fails under StrictMode.
    $candidates = @()
    if ($null -eq $inactiveRecovery) {
        $candidates = @($rows | Where-Object {
            (Test-DeletionCandidate $_) -and
            -not (-not $reInfo.Enabled -and $_.Kind -eq 'RecoveryOther')
        })
    }
    # When inactive WinRE remains unresolved, no partition deletion is offered.
    # Inspect every suspicious partition BEFORE it can be selected.
    # The audit is read-only. A partition with unknown/OEM contents is blocked
    # from optional deletion, even when the user selects it for simulation.
    $candidateAudits = @()
    if ($candidates.Count -gt 0) {
        Write-Host ''
        Write-Host ('=== ' + $m.CS28AuditTitle + ' ===') -ForegroundColor Cyan
        foreach ($row in $candidates) {
            $part = @($parts | Where-Object { [int]$_.PartitionNumber -eq [int]$row.PartitionNumber })
            if ($part.Count -ne 1) { throw $m.CSExecLayoutChanged }
            $audit = Get-CSCleanupCandidateAudit $disk $c $part[0] $row.Kind $reInfo
            $candidateAudits += $audit
            Show-CSCleanupCandidateAudit $audit
        }
        Write-Host $m.CS28AuditDisclaimer -ForegroundColor Yellow
    }
    $hasChoices = ($canPreviewC -or $candidates.Count -gt 0)
    if ($hasChoices) {
        Write-Host ''
        Write-Host ('=== ' + $m.CSPlanSelectionTitle + ' ===') -ForegroundColor Cyan
        Write-Host $m.CSSelectionNotice -ForegroundColor Yellow
        # Select each operation explicitly; the actual executor performs
        # preflight checks and obtains separate final confirmation.
        if ($canPreviewC) {
            if ($null -eq $activeRecovery) {
                $optimiseC = if ($proposal.MigratingWinREOnC) {
                    Read-YesNo $m.CSMBRAskMove
                } else { Read-YesNo $m.CSAskCreateRecovery }
                if ($optimiseC) {
                    # Only the surplus beyond the planned Recovery size can
                    # be assigned to C:. Leave C: unchanged by default.
                    $reSize = [int64]$proposal.Geometry.NewSize
                    $maxGrowBytes = [int64][math]::Max([int64]0,
                        (Align-DownMiB ([int64]$proposal.Geometry.RightEnd - $reSize)) -
                        ([int64]$c.Offset + [int64]$proposal.TargetPartitionBytes))
                    $maxGrowMiB = [int64][math]::Floor($maxGrowBytes / [double]$script:MiB)
                    if ($maxGrowMiB -gt 0 -and [int64]$proposal.ChangeBytes -ge 0) {
                        $growMiB = Read-CSRecoveryCExtraMiB $maxGrowMiB
                        if ($growMiB -gt 0) {
                            $targetC = [int64]($proposal.TargetPartitionBytes + $growMiB * $script:MiB)
                            $newGeo = Get-CSProposedGeometry $disk $c $parts $null $targetC `
                                $usableBounds $reSize
                            if ($null -eq $newGeo -or -not $newGeo.IsGeometryPossible -or
                                [int64]$newGeo.NewSize -ne $reSize -or
                                [int64]$newGeo.RightEnd -ne [int64]$proposal.Geometry.RightEnd) {
                                throw $m.CSExecLayoutUnsupported
                            }
                            $proposal.TargetPartitionBytes = $targetC
                            $proposal.ChangeBytes = [int64]($targetC - [int64]$c.Size)
                            $proposal.Geometry = $newGeo
                            $geometryCandidate = $newGeo
                        }
                    }
                }
            } elseif ($proposal.Beauty) {
                $optimiseC = Read-YesNo ($m.CSAskOptimiseCWithRE -f
                    $proposal.TargetExplorerGiB, $activeRecovery.PartitionNumber)
            } elseif ($reInfo.Enabled -and $null -ne $assessment.FreeBytes -and
                [int64]$assessment.FreeBytes -lt $script:CSFreeReserve -and
                [int64]$proposal.ChangeBytes -lt 0) {
                $optimiseC = Read-YesNo ($m.CSAskIncreaseRecovery -f
                    (Format-DetailedSize ([int64]$proposal.Geometry.NewSize)),
                    (Format-DetailedSize ([int64][math]::Abs($proposal.ChangeBytes))))
            } else {
                $optimiseC = Read-YesNo $m.CS26AskRecoveryRepair
            }
        }
        foreach ($candidate in $candidates) {
            $details = @()
            if (-not [string]::IsNullOrWhiteSpace($candidate.Name)) { $details += $candidate.Name }
            $details += $candidate.Size
            $details += $candidate.Role
            $candidateAudit = @($candidateAudits | Where-Object {
                [int]$_.Number -eq [int]$candidate.PartitionNumber
            })
            if ($candidateAudit.Count -ne 1 -or -not $candidateAudit[0].Permitted) {
                Write-Host ($m.CSSelectionBlocked -f $candidate.PartitionNumber) -ForegroundColor Yellow
                continue
            }
            if (Read-YesNo ($m.CSAskDeletePartition -f $candidate.PartitionNumber, ($details -join ', '))) {
                $selected.Add([int]$candidate.PartitionNumber)
            }
        }
    } elseif ($null -ne $proposal) {
        Write-Host $m.CSPlanCUnavailable -ForegroundColor Yellow
    }

    Write-Host ''
    $planTitle = $m.CSProposedPlanTitle
    Write-Host ('=== ' + $planTitle + ' ===') -ForegroundColor Cyan
    $anyAction = $false
    $plannedCSize = [int64]$c.Size
    $rebuildGeometry = $null
    if ($optimiseC) {
        $anyAction = $true
        $plannedCSize = [int64]$proposal.TargetPartitionBytes
        $rebuildGeometry = $geometryCandidate
        $changeLabel = Format-PartitionSize ([int64][math]::Abs($proposal.ChangeBytes))
        $operation = if ($proposal.ChangeBytes -gt 0) { $m.CSPlanGrow } else { $m.CSPlanShrink }
        # The active Recovery is temporary removed/recreated only as part
        # of THIS combined operation, never an independent deletion choice.
        if ($null -eq $activeRecovery) {
            Write-Host ($m.CS26PlanCreate -f (Format-DetailedSize ([int64]$rebuildGeometry.NewSize)),
                (Format-DetailedSize ([int64]$proposal.MinimumRecoveryBytes)))
            if ($proposal.MigratingWinREOnC) {
                Write-Host $m.CSMBRPlanMigration
            }
            if ($proposal.ChangeBytes -ne 0) {
                Write-Host ($m.CS26PlanCChange -f $operation, $changeLabel)
            }
        } else {
            if ($proposal.Beauty) {
                Write-Host ($m.CSPlanCWithRE -f $operation, $changeLabel, $proposal.TargetExplorerGiB, $activeRecovery.PartitionNumber)
            } elseif ($proposal.ChangeBytes -eq 0) {
                Write-Host ($m.CS26PlanRebuildOnly -f $activeRecovery.PartitionNumber)
            } else {
                Write-Host ($m.CS26PlanTechnical -f $operation, $changeLabel, $activeRecovery.PartitionNumber)
            }
            Write-Host ($m.CSPlanRebuildRE -f $activeRecovery.PartitionNumber,
                (Format-DetailedSize $rebuildGeometry.OldSize), (Format-DetailedSize $rebuildGeometry.NewSize))
        }
        if ([int64]$rebuildGeometry.AbsorbedGapBytes -gt 0) {
            Write-Host ($m.CSPlanAbsorbGap -f (Format-FreeSpaceSize ([int64]$rebuildGeometry.AbsorbedGapBytes))) -ForegroundColor DarkGray
        }
        if ($null -eq $activeRecovery) {
            # Do not describe resizing C: when creating Recovery from free space
            # with the user-selected default of zero additional MiB.
            if ([int64]$proposal.ChangeBytes -ne 0) {
                Write-Host $m.CSNewCreateOrder -ForegroundColor DarkGray
            }
        } elseif ($proposal.ChangeBytes -gt 0) {
            Write-Host $m.CSPlanOrderGrow
        } else {
            Write-Host $m.CSPlanOrderShrink
        }
        Write-Host $m.CSPlanReValidation -ForegroundColor Yellow
        if ($proposal.ChangeBytes -lt 0) {
            # Get-PartitionSupportedSize may take time on a live Windows volume.
            # Report progress BEFORE the blocking Storage API call.
            Write-Host ($m.CSCheckingShrinkSize -f (Format-DetailedSize ([int64][math]::Abs($proposal.ChangeBytes)))) -ForegroundColor DarkGray
            try {
                $supported = Get-PartitionSupportedSize -DiskNumber ([int]$disk.Number) -PartitionNumber ([int]$c.PartitionNumber) -ErrorAction Stop
                $possibleShrink = [int64][math]::Max([int64]0, ([int64]$c.Size - [int64]$supported.SizeMin))
                $neededShrink = [int64][math]::Abs($proposal.ChangeBytes)
                Write-Host ($m.CSShrinkAvailable -f (Format-DetailedSize $possibleShrink),
                    (Format-DetailedSize $neededShrink),
                    (Format-DetailedSize ([int64]$supported.SizeMin))) -ForegroundColor DarkGray
                if ($plannedCSize -lt [int64]$supported.SizeMin) {
                    Write-Host ($m.CSPlanShrinkBlocked -f (Format-PartitionSize ([int64]$supported.SizeMin))) -ForegroundColor Yellow
                    # The preview geometry remains conditional, not executable.
                } else {
                    Write-Host ($m.CSCheckedShrinkSize -f (Format-DetailedSize ([int64][math]::Abs($proposal.ChangeBytes)))) -ForegroundColor DarkGray
                }
            } catch { Write-Host $m.CSPlanSupportedSizeUnknown -ForegroundColor Yellow }
        }
    }
    if ($selected.Count -gt 0) {
        $anyAction = $true
        Write-Host $m.CSPlanOptionalDeletionHeader
        foreach ($n in $selected) {
            $record = @($rows | Where-Object { $_.PartitionNumber -eq $n } | Select-Object -First 1)
            if ($record.Count -eq 1) {
                Write-Host ($m.CSPlanCandidateDeletion -f $n, $record[0].Role) -ForegroundColor Yellow
                $selectedAudit = @($candidateAudits | Where-Object { [int]$_.Number -eq [int]$n })
                if ($selectedAudit.Count -ne 1 -or -not $selectedAudit[0].Permitted) {
                    Write-Host ('  ' + $m.CS282BlockedSimulation) -ForegroundColor Red
                }
                $side = if ($record[0].Offset -lt [int64]$c.Offset) { $m.CSPlanLeftOfC } else {
                    $m.CSPlanNotAdjacentC
                }
                Write-Host ('  ' + $side)
            }
        }
        Write-Host $m.CSPlanDeletionReview -ForegroundColor Yellow
    }
    if ($anyAction) {
        Write-Host $m.CSPreviewCalculating -ForegroundColor DarkGray
        $excluded = @($selected.ToArray())
        $projectedParts = @(New-ProjectedLayout $parts $c $activeRecovery $plannedCSize $rebuildGeometry $excluded)
        if ($optimiseC -and $null -eq $activeRecovery -and $null -ne $rebuildGeometry) {
            # Synthetic partition for display ONLY. Number 0 signifies new.
            $newRecovery = New-CSProjectedRecovery $disk `
                ([int64]$rebuildGeometry.NewStart) ([int64]$rebuildGeometry.NewSize)
            $projectedParts = @($projectedParts + @($newRecovery) | Sort-Object Offset)
        }
        $projectedC = @($projectedParts | Where-Object { [int]$_.PartitionNumber -eq [int]$c.PartitionNumber } | Select-Object -First 1)
        if ($projectedC.Count -ne 1) { throw 'Projected Windows partition is missing.' }
        $previewBounds = Get-PreviewBounds $usableBounds $parts
        # Estimate capacity of a resized C: from the observed NTFS/partition
        # delta. It is a preview only: only the executor can verify final NTFS size.
        $previewVolumeSizes = @{}
        foreach ($key in $volumeSizes.Keys) {
            $previewVolumeSizes[$key] = [int64]$volumeSizes[$key]
        }
        $cKey = [string]$c.PartitionNumber
        if ($optimiseC -and $previewVolumeSizes.ContainsKey($cKey)) {
            $previewVolumeSizes[$cKey] = [int64](
                [int64]$previewVolumeSizes[$cKey] + $plannedCSize - [int64]$c.Size)
        }
        $simulatedRows = @(New-PartitionRows $disk $projectedC[0] $projectedParts $reInfo $previewBounds $previewVolumeSizes)
        if ($optimiseC -and $null -eq $activeRecovery) {
            foreach ($row in $simulatedRows) {
                if ($row.Kind -eq 'RecoveryOther' -and [int]$row.PartitionNumber -eq 0) {
                    $row.Recommendation = ''
                    $row.Number = '+'
                    $row.Role = $m.CS26NewRecovery
                }
            }
        }
        Show-Partitions $simulatedRows $m.CSSimulationLayoutTitle $false
        Write-Host ''
        Write-Host $m.CSSimulationLayoutNotice -ForegroundColor Yellow
        if ($null -eq $usableBounds) {
            Write-Host $m.CSPreviewBoundsFallback -ForegroundColor Yellow
        }
    } else {
        if ($reInfo.Enabled -and $null -ne $activeRecovery -and
            $assessment.Verified -and $null -ne $assessment.FreeBytes -and
            [int64]$assessment.FreeBytes -ge $script:CSFreeReserve) {
            Write-Host $m.CSPlanAlreadyHealthy -ForegroundColor Green
        } else {
            Write-Host $m.CSPlanNoActions
        }
    }
    if (@($rows | Where-Object { $_.Kind -eq 'EFI' -and $_.Recommendation -eq $m.CSRecommendEFIAfterC }).Count -gt 0) {
        Write-Host $m.CSPlanManualEFI -ForegroundColor DarkGray
    }
    $selectedAudits = @($candidateAudits | Where-Object {
        [int]$_.Number -in $selected.ToArray()
    })
    # Never begin mutation if any selected optional deletion failed its audit.
    $invalid = @($selectedAudits | Where-Object { -not $_.Permitted })
    $coreSucceeded = $false
    $finalReadbackSucceeded = $false
    if ($selectedAudits.Count -ne $selected.Count -or $invalid.Count -gt 0) {
        Write-Host $m.CS28BlockedExecutionSelection -ForegroundColor Red
    } else {
        if ($optimiseC) {
            if ($null -eq $activeRecovery) {
                Invoke-CSCreateMissingRecovery -Disk $disk -C $c -Parts $parts `
                    -ReInfo $reInfo -Proposal $proposal -RebuildGeometry $rebuildGeometry `
                    -AdditionalDeletions $selectedAudits
            } else {
                Invoke-CSCRecoveryExecution -Disk $disk -C $c -Parts $parts `
                    -ActiveRecovery $activeRecovery -ReInfo $reInfo -Proposal $proposal `
                    -RebuildGeometry $rebuildGeometry -AdditionalDeletions $selectedAudits
            }
            $coreSucceeded = [bool]$script:CSExecLastSucceeded
        } elseif ($selectedAudits.Count -gt 0) {
            # Optional deletions retain their separate audited confirmations.
            $coreSucceeded = $true
        }
        # No action is also reported above in the proposed plan, only once.
        if ($coreSucceeded -and $selectedAudits.Count -gt 0) {
            Write-Host ''
            Write-Host ('=== ' + $m.CS28ExecuteTitle + ' ===') -ForegroundColor Yellow
            Invoke-CSOptionalPartitionDeletion -disk $disk -c $c -audits $selectedAudits `
                -BackupAlreadyConfirmed:$optimiseC
        }
        if ($coreSucceeded) {
            try {
                Show-CSFinalSummary -OriginalDisk $disk -OriginalC $c `
                    -CleanupAudits $selectedAudits
                $finalReadbackSucceeded = $true
            } catch {
                Write-Warning ($m.CSFinalReadbackFailed -f $_.Exception.Message)
            }
        }
    }
    # Only allow cleanup after successful execution/readback or verified
    # healthy no-change diagnostics. Actual cleanup follows the final stage
    # report in finally, so failures and Ctrl+C retain their rescue images.
    $anySelectedAction = ($optimiseC -or $selectedAudits.Count -gt 0)
    $normalCompletion = ($selectedAudits.Count -eq $selected.Count -and
        $invalid.Count -eq 0 -and $assessment.Verified -and
        (-not $anySelectedAction -or ($coreSucceeded -and $finalReadbackSucceeded)))
    if ($normalCompletion) {
        try {
            $finalRE = Get-WinReSnapshot
            if ($finalRE.Enabled -and $null -ne $finalRE.DiskNumber -and
                $null -ne $finalRE.PartitionNumber -and
                [int]$finalRE.DiskNumber -eq [int]$disk.Number) {
                $script:CSStagingCleanupAllowed = $true
            }
        } catch {
            if ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) { throw }
            Write-Warning $_.Exception.Message
        }
    }
    $script:CSRunHandled = $true
}
catch {
    $script:CSRunHandled = $true
    if ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) {
        $utility.InterruptedByUser = $true
    } elseif ([string]$script:CSExecErrorReportedMessage -ne $_.Exception.Message) {
        # The execution module already displayed this exact error, with recovery advice.
        Write-Host ''
        Write-Host ('=== ' + $m.ErrorSection + ' ===') -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}
finally {
    # Ctrl+C may bypass catch, but normally still enters finally.
    if (-not $script:CSRunHandled) { $utility.InterruptedByUser = $true }
    try {
        # Capture and show the existing Stage-* folders before deletion.
        # This is deliberately at the end, both for successful and failed runs.
        $stageReportSucceeded = $false
        try {
            Show-CSExistingStages
            $stageReportSucceeded = $true
        } catch {
            Write-Warning $_.Exception.Message
        }
        if ($stageReportSucceeded -and $script:CSStagingCleanupAllowed -and
            -not $utility.InterruptedByUser) {
            try {
                Invoke-CSCleanupStaging
                $script:CSStagingCleanedSuccessfully = $true
            } catch {
                if ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) { throw }
                Write-Warning $_.Exception.Message
            }
        }
        if (-not $script:CSStagingCleanedSuccessfully) {
            try { Show-CSPreservedStages }
            catch { Write-Warning $_.Exception.Message }
        }
        # ISO staging may contain WinRE rescue material after a failed disk change.
        Clear-CSISOStage
    } finally {
        Stop-Utility -Utility $utility
    }
}
