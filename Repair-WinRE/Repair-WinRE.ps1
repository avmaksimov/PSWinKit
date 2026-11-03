#Requires -Version 5.1
# Repair-WinRE: interactive, one-confirmation Windows RE repair.
# Supports simple basic GPT/MBR layouts only. No shrink or partition moves.
# No log files. Changes to disk only after the final Y/N approval.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\Common\Common.ps1')
$utility = Start-Utility -ScriptPath $PSCommandPath -RequireAdministrator
if ($null -eq $utility) { return }
$m = $utility.Messages

$script:MiB = [int64]1048576
$script:GiB = [int64]1073741824
$script:RecoveryGuid = 'DE94BBA4-06D1-4D40-A16A-BFD50179D6AC'
$script:BasicGuid = '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'
$script:WorkDir = $null
$script:MountDir = $null
$script:WimFile = $null
$script:Mounted = $false
$script:MountAccessPath = $null
$script:MountAccessAssigned = $false
$script:MountAccessPartNumber = $null
$script:NewPartNumber = $null
$script:DiskNumber = $null
$script:Mutated = $false
$script:Completed = $false
$script:Failed = $false
$script:ResultWasReported = $false

function Say([string]$message) { Write-Host $message }
function Write-Section([string]$label) {
    Write-Host ''
    Write-Host ("=== {0} ===" -f $label) -ForegroundColor Cyan
}
function Write-Detail([string]$label, [string]$value, [string]$color = 'White') {
    # A single console write prevents column gaps when output is copied or reflowed.
    # Allow room for both English and Russian labels.
    Write-Host ("  {0,-24}{1}" -f ($label + ':'), $value) -ForegroundColor $color
}
function Write-Notice([string]$message) {
    Write-Host ("  {0}" -f $message) -ForegroundColor Yellow
}
function Write-Step([string]$message) {
    Write-Host ("  {0}" -f $message) -ForegroundColor White
}
function Write-Result([string]$message, [bool]$success = $true) {
    Write-Host ''
    if ($success) { Write-Host $message -ForegroundColor Green }
    else { Write-Host $message -ForegroundColor Red }
    $script:ResultWasReported = $true
}
# Ctrl+C stops the PowerShell output pipeline, which may suppress Write-Host
# in finally. Write directly to the console to make an interrupted run visible.
function Write-InterruptedNotice {
    $notice = $m.InterruptedNotice
    $warning = $m.InterruptedWarning
    try {
        $savedColor = [Console]::ForegroundColor
        try {
            [Console]::ForegroundColor = [ConsoleColor]::Red
            [Console]::Error.WriteLine('')
            [Console]::Error.WriteLine($m.InterruptedHeading)
            [Console]::Error.WriteLine('  ' + $notice)
            if ($script:Mutated) {
                [Console]::ForegroundColor = [ConsoleColor]::Yellow
                [Console]::Error.WriteLine('  ' + $warning)
            }
        } finally {
            [Console]::ForegroundColor = $savedColor
        }
    } catch {
        # Fallback for hosts without a usable System.Console.
        Write-Host ''
        Write-Host ('=== ' + $notice + ' ===') -ForegroundColor Red
        if ($script:Mutated) { Write-Host ('  ' + $warning) -ForegroundColor Yellow }
    }
}
function SizeMiB([int64]$bytes) { $m.SizeMiB -f ($bytes / $script:MiB) }
function SizeGiB([int64]$bytes) { $m.SizeGiB -f ($bytes / $script:GiB) }
function SizeGiBWithNtfsMargin([int64]$bytes) {
    if (($bytes % $script:GiB) -eq $script:MiB) {
        return ($m.SizeGiBMargin -f ([math]::Floor($bytes / $script:GiB)))
    }
    return (SizeGiB $bytes)
}
# Let native console tools render their own progress and diagnostics.
# Do not pipe their output through PowerShell unless it must be parsed.
function Run-External([string]$exe, [string[]]$arguments) {
    & $exe @arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw ($m.ExternalFailed -f $exe, $exitCode) }
}
function Run-DiskPart([string[]]$commands) {
    $name = Join-Path $script:WorkDir ([guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllLines($name, $commands, [Text.Encoding]::ASCII)
    try { Run-External 'diskpart.exe' @('/s', $name) }
    finally { Remove-Item -LiteralPath $name -Force -ErrorAction SilentlyContinue }
}
function Get-ReInfo {
    $out = (& reagentc.exe /info 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw ($m.ReInfoFailed -f $out) }
    $match = [regex]::Match($out, '(?im)^\s*[^:\r\n]+:\s*(Enabled|Disabled|\u0412\u043a\u043b\u044e\u0447\u0435\u043d\u043e|\u041e\u0442\u043a\u043b\u044e\u0447\u0435\u043d\u043e)\s*$')
    if (-not $match.Success) { throw ($m.ReInfoParseFailed -f $out) }
    $status = if ($match.Groups[1].Value -match '^(Enabled|\u0412\u043a\u043b\u044e\u0447\u0435\u043d\u043e)$') { 'Enabled' } else { 'Disabled' }
    return [pscustomobject]@{ Status = $status; Output = $out }
}
function Is-RecoveryPartition($part, [string]$style) {
    if ($style -eq 'GPT') {
        return (([string]$part.GptType).Trim('{}') -ieq $script:RecoveryGuid)
    }
    $type = [string]$part.Type
    $mbr = if ($part.PSObject.Properties['MbrType']) { [string]$part.MbrType } else { '' }
    return (($type -ieq 'Recovery') -or ($type -ieq '0x27') -or ($mbr -ieq 'Recovery'))
}
# Mount the Recovery volume into an empty NTFS directory, never a drive letter.
# The mount directory lives OUTSIDE WorkDir so recursive cleanup can never
# descend into Recovery if Windows refuses to detach the mount point.
function Open-RecoveryMount([int]$number) {
    if ($script:MountAccessAssigned) { throw $m.MountAlreadyActive }
    if ([string](Get-Volume -DriveLetter C -ErrorAction Stop).FileSystem -ine 'NTFS') {
        throw $m.MountRequiresNtfs
    }
    $script:MountAccessPath = Join-Path $env:windir ('Temp\WinRE-Manager-Mount-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:MountAccessPath -ErrorAction Stop | Out-Null
    if (@(Get-ChildItem -LiteralPath $script:MountAccessPath -Force -ErrorAction Stop).Count -ne 0) {
        throw $m.MountMustBeEmpty
    }
    # Set this before attaching so cleanup knows which partition to inspect.
    $script:MountAccessPartNumber = $number
    # Assume attachment may have partially succeeded even if the cmdlet errors.
    # In that case, cleanup must NOT delete the directory until detached.
    $script:MountAccessAssigned = $true
    Add-PartitionAccessPath -DiskNumber $script:DiskNumber -PartitionNumber $number `
        -AccessPath $script:MountAccessPath -ErrorAction Stop
    $mountItem = Get-Item -LiteralPath $script:MountAccessPath -Force -ErrorAction Stop
    if (($mountItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        throw $m.MountNotAttached
    }
    Write-Detail $m.TemporaryMount $script:MountAccessPath
}
function Close-RecoveryMount {
    if (-not $script:MountAccessPath) { return }
    if ($script:MountAccessAssigned) {
        Remove-PartitionAccessPath -DiskNumber $script:DiskNumber `
            -PartitionNumber $script:MountAccessPartNumber `
            -AccessPath $script:MountAccessPath -ErrorAction Stop
        $script:MountAccessAssigned = $false
    }
    # An NTFS junction/mount point must be detached BEFORE deleting its folder.
    # Avoid Remove-Item -Recurse here under any circumstances.
    if (Test-Path -LiteralPath $script:MountAccessPath -PathType Container) {
        $mountItem = Get-Item -LiteralPath $script:MountAccessPath -Force -ErrorAction Stop
        if (($mountItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw $m.MountStillAttached
        }
        [IO.Directory]::Delete($script:MountAccessPath, $false)
    }
    $script:MountAccessPath = $null
    $script:MountAccessPartNumber = $null
}
function Test-Wim([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $path -Force).Length -lt (100 * $script:MiB)) { return $false }
    try { $null = Get-WindowsImage -ImagePath $path -Index 1 -ErrorAction Stop; return $true }
    catch { return $false }
}
function Get-RecoveryRoot($part) {
    if ($null -eq $part) { return $null }
    $paths = @()
    try {
        $vol = Get-Volume -Partition $part -ErrorAction Stop
        if ($vol.Path) { $paths += [string]$vol.Path }
    } catch { }
    foreach ($path in @($part.AccessPaths)) { if ($path) { $paths += [string]$path } }
    foreach ($path in ($paths | Select-Object -Unique)) {
        if ($path -match '^\\\\\?\\Volume\{[0-9a-fA-F-]+\}\\?$' -and (Test-Path -LiteralPath $path)) {
            return ($path.TrimEnd('\') + '\')
        }
        if ($path -match '^[A-Z]:\\?$' -and (Test-Path -LiteralPath $path)) {
            return ($path.TrimEnd('\') + '\')
        }
    }
    return $null
}
function Find-Wim($part) {
    Write-Step $m.CheckingLocalImages
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $candidates.Add((Join-Path $env:windir 'System32\Recovery\Winre.wim'))
    $candidates.Add((Join-Path ($env:SystemDrive + '\') 'Recovery\WindowsRE\Winre.wim'))
    $root = Get-RecoveryRoot $part
    if ($root) {
        $candidates.Add((Join-Path $root 'Recovery\WindowsRE\Winre.wim'))
        $candidates.Add((Join-Path $root 'Winre.wim'))
    }
    foreach ($path in @($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-Host ('    {0,-11} {1}' -f $m.ImageNotFound, $path) -ForegroundColor DarkGray
            continue
        }
        if (Test-Wim $path) {
            Write-Host ('    {0,-11} {1}' -f $m.ImageValid, $path) -ForegroundColor Green
            return $path
        }
        Write-Host ('    {0,-11} {1}' -f $m.ImageInvalid, $path) -ForegroundColor Yellow
    }
    if (-not $part) {
        Write-Host $m.RecoveryNotPresent -ForegroundColor DarkGray
    } elseif (-not $root) {
        Write-Host $m.RecoveryUnavailable -ForegroundColor Yellow
    }
    return $null
}
function Get-LayoutMode($disk, $os, $part, $allParts) {
    if ([string]$disk.PartitionStyle -notin @('GPT','MBR')) { throw $m.OnlyGptMbr }
    if ($disk.IsOffline -or $disk.IsReadOnly) { throw $m.DiskOfflineReadOnly }
    if (-not $disk.IsBoot) { throw $m.DiskNotBoot }
    if ([string]$os.Type -match 'Extended') { throw $m.LogicalUnsupported }
    if ([string]$disk.PartitionStyle -eq 'MBR') {
        if (@($allParts | Where-Object { [string]$_.Type -match 'Extended|Logical' }).Count -gt 0) {
            throw $m.ExtendedUnsupported
        }
        if (-not $part -and @($allParts).Count -ge 4) { throw $m.FourPrimary }
    }
    $endC = [int64]($os.Offset + $os.Size)
    $after = @($allParts | Where-Object { $_.Offset -ge $endC } | Sort-Object Offset)
    if ($part) {
        if ($after.Count -lt 1 -or $after[0].PartitionNumber -ne $part.PartitionNumber) {
            throw $m.RecoveryNotFirst
        }
        if ($part.Offset -lt $endC -or ($part.Offset - $endC) -gt 2 * $script:MiB) {
            throw $m.RecoveryNotAdjacent
        }
        if ($part.IsSystem -or $part.IsBoot -or $part.IsActive) { throw $m.RecoveryBootFlags }
        if ($after.Count -gt 1) {
            # Example: C: -> Recovery -> D:. Never delete Recovery or resize C: here.
            return 'InPlace'
        }
        return 'Rebuild'
    }
    if ($after.Count -gt 0) {
        throw $m.PartitionAfterC
    }
    return 'Rebuild'
}
function Assert-BitLockerSafe {
    $command = Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue
    if (-not $command) { throw $m.BitLockerUnavailable }
    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ($null -eq $bl) { throw $m.BitLockerNoStatus }
    if ([string]$bl.VolumeStatus -ne 'FullyDecrypted' -and [string]$bl.VolumeStatus -ne '0') {
        throw $m.BitLockerEncrypted
    }
    if ([string]$bl.ProtectionStatus -eq 'On' -or [string]$bl.ProtectionStatus -eq '1') {
        throw $m.BitLockerActive
    }
}
function Find-IsoImage([string]$letter) {
    foreach ($name in @('sources\install.wim', 'sources\install.esd')) {
        $candidate = "$letter`:\$name"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}
function Get-NormalizedArchitecture([string]$value) {
    switch -Regex ($value.Trim()) {
        '^(9|x64|AMD64)$' { return 'x64' }
        '^(12|ARM64)$' { return 'ARM64' }
        '^(0|x86|I386)$' { return 'x86' }
        default { return $value.Trim().ToUpperInvariant() }
    }
}
function Test-SharedWindows11Core([int]$installedBuild, [int]$imageBuild) {
    # Windows 11 24H2, 25H2 and 26H2 share the 26100 servicing core.
    return ($installedBuild -in @(26100,26200,26300) -and $imageBuild -in @(26100,26200,26300))
}
function Select-IsoIndex([string]$path, [string]$edition, [int]$build, [string]$arch) {
    # Architecture is detected numerically, not through localized OSArchitecture strings.
    $expectedArch = Get-NormalizedArchitecture $arch
    if ($expectedArch -notin @('x64', 'x86', 'ARM64')) {
        throw ($m.UnsupportedArchitecture -f $expectedArch)
    }
    $all = @(Get-WindowsImage -ImagePath $path -ErrorAction Stop)
    if ($all.Count -eq 0) { throw $m.IsoCatalogEmpty }

    $rows = @()
    $matching = @()
    foreach ($img in $all) {
        $detail = Get-WindowsImage -ImagePath $path -Index ([int]$img.ImageIndex) -ErrorAction Stop
        $imageEdition = [string]$detail.EditionId
        $imageArch = Get-NormalizedArchitecture ([string]$detail.Architecture)
        $imageVersion = [version]$detail.Version
        $imageBuild = [int]$imageVersion.Build
        $editionMatch = ($imageEdition -ieq $edition)
        $archMatch = ($imageArch -ieq $expectedArch)
        $exactBuild = ($imageBuild -eq $build)
        $sharedBuild = Test-SharedWindows11Core $build $imageBuild
        $rows += [pscustomobject]@{
            Index=[int]$detail.ImageIndex
            Edition=$imageEdition
            Build=$imageBuild
            Architecture=$imageArch
            Name=[string]$detail.ImageName
        }
        if ($editionMatch -and $archMatch -and ($exactBuild -or $sharedBuild)) {
            $matching += [pscustomobject]@{
                Index=[int]$detail.ImageIndex
                Edition=$imageEdition
                Build=$imageBuild
                Architecture=$imageArch
                Name=[string]$detail.ImageName
                Exact=$exactBuild
            }
        }
    }
    Write-Host ''
    Write-Host $m.AvailableIsoImages -ForegroundColor Gray
    $rows | Sort-Object Index | Format-Table @{ Label = $m.TableIndex; Expression = { $_.Index } },
        @{ Label = $m.TableEdition; Expression = { $_.Edition } },
        @{ Label = $m.TableBuild; Expression = { $_.Build } },
        @{ Label = $m.TableArchitecture; Expression = { $_.Architecture }; Alignment = 'Center' },
        @{ Label = $m.TableName; Expression = { $_.Name } } -AutoSize | Out-Host

    $exact = @($matching | Where-Object { $_.Exact })
    $compatible = @($matching | Where-Object { -not $_.Exact })
    $selected = $null
    if ($exact.Count -eq 1) { $selected = $exact[0] }
    elseif ($exact.Count -eq 0 -and $compatible.Count -eq 1) { $selected = $compatible[0] }

    if (-not $selected) {
        throw ($m.NoUniqueIso -f $edition, $build, $expectedArch, $exact.Count, $compatible.Count)
    }
    Write-Detail $m.SelectedImage ($m.SelectedImageValue -f $selected.Index, $selected.Edition, $selected.Build, $selected.Architecture) 'Green'
    if (-not $selected.Exact) {
        Write-Notice ($m.IsoBuildDiffers -f $selected.Build, $build)
        Write-Notice $m.SharedCoreAccepted
    }
    return [int]$selected.Index
}
# Optional acceleration: use an existing 7-Zip installation. Never download or bundle it.
function Find-SevenZip {
    # Only use the official Program Files installation location.
    # ProgramW6432 avoids Program Files (x86) from 32-bit PowerShell on 64-bit Windows.
    $base = if ([Environment]::Is64BitOperatingSystem) {
        $env:ProgramW6432
    } else {
        $env:ProgramFiles
    }
    if (-not $base) { return $null }
    $candidate = Join-Path $base '7-Zip\7z.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return $null
}
function Try-Extract-SevenZip([string]$source, [int]$index) {
    $sevenZip = Find-SevenZip
    if (-not $sevenZip) {
        Write-Step $m.SevenZipNotInstalled
        return
    }
    $internalPath = ('{0}\Windows\System32\Recovery\Winre.wim' -f $index)
    Write-Step $m.SevenZipExtracting
    Write-Detail $m.SevenZipExecutable $sevenZip
    Write-Detail $m.ArchiveEntry $internalPath
    Write-Detail $m.TemporaryWinre $script:WimFile
    try {
        # Use the executable's native console output; do not capture or reformat its progress.
        & $sevenZip 'e' $source $internalPath ("-o$script:WorkDir") '-y'
        if ($LASTEXITCODE -ne 0) { throw ($m.SevenZipExitCode -f $LASTEXITCODE) }
        if (-not (Test-Wim $script:WimFile)) { throw $m.ExtractedWimInvalid }
        $script:ExtractionMethod = '7-Zip'
        Write-Step $m.ExtractionCompleted
    } catch {
        Write-Notice ($m.SevenZipFailed + $_.Exception.Message)
        if (Test-Path -LiteralPath $script:WimFile) {
            Remove-Item -LiteralPath $script:WimFile -Force -ErrorAction Stop
        }
        Write-Step $m.DismFallback
    }
}
function Extract-IsoWinre([string]$source, [int]$index) {
    $script:ExtractionMethod = 'DISM'
    Try-Extract-SevenZip $source $index
    if ($script:ExtractionMethod -eq '7-Zip') { return }

    # The fallback needs more scratch space than direct extraction.
    $free = [int64](Get-Volume -DriveLetter C -ErrorAction Stop).SizeRemaining
    $needed = if ([IO.Path]::GetExtension($source) -ieq '.esd') { 9 * $script:GiB } else { 2 * $script:GiB }
    if ($free -lt $needed) {
        throw ($m.DismSpaceRequired -f (SizeGiB $needed))
    }
    $image = $source
    if ([IO.Path]::GetExtension($source) -ieq '.esd') {
        $image = Join-Path $script:WorkDir 'Install-Selected.wim'
        Write-Step $m.ExportingEsd
        Write-Detail $m.TemporaryWim $image
        Run-External 'dism.exe' @('/English', '/Export-Image', "/SourceImageFile:$source", "/SourceIndex:$index", "/DestinationImageFile:$image", '/Compress:max', '/CheckIntegrity')
        Write-Step $m.ExportCompleted
        $index = 1
    }
    New-Item -ItemType Directory -Path $script:MountDir -Force | Out-Null
    Write-Step $m.MountingImage
    Write-Detail $m.MountDirectory $script:MountDir
    Run-External 'dism.exe' @('/English','/Mount-Image',"/ImageFile:$image","/Index:$index","/MountDir:$script:MountDir",'/ReadOnly')
    $script:Mounted = $true
    Write-Step $m.LocatingWinre
    $inside = Join-Path $script:MountDir 'Windows\System32\Recovery\Winre.wim'
    if (-not (Test-Path -LiteralPath $inside -PathType Leaf)) { throw $m.WinreMissingInImage }
    Write-Step $m.CopyingWinre
    Copy-Item -LiteralPath $inside -Destination $script:WimFile -Force -ErrorAction Stop
    Write-Detail $m.TemporaryWinre $script:WimFile
    Write-Step $m.UnmountingImage
    Run-External 'dism.exe' @('/English','/Unmount-Image',"/MountDir:$script:MountDir",'/Discard')
    $script:Mounted = $false
}
function Make-Plan($disk, $os, [int64]$minSize) {
    # Explicit 4 MiB tail margin; all planned boundaries are aligned to 1 MiB.
    $end = [int64]([math]::Floor(($disk.Size - 4 * $script:MiB) / $script:MiB) * $script:MiB)
    $cEnd = [int64]($os.Offset + $os.Size)
    if ($end - $cEnd -lt $minSize) { throw ($m.InsufficientSpace -f (SizeMiB ($end - $cEnd)), (SizeMiB $minSize)) }
    $maxC = [int64]($end - $os.Offset - $minSize)
    $roundedC = [int64]([math]::Floor($maxC / $script:GiB) * $script:GiB)
    $targetC = [int64]$os.Size
    # NTFS reports a volume size about one cluster smaller than its partition.
    # An exact 65 GiB partition appeared as 64.9 GiB in Explorer in our test.
    # Add 1 MiB when possible so Explorer can display a whole-GiB capacity.
    # Never shrink C:, and never exceed the space left for minimum Recovery.
    $preferredC = [int64]($roundedC + $script:MiB)
    if ($preferredC -gt $targetC -and $preferredC -le $maxC) {
        $targetC = $preferredC
    }
    $capacity = [int64]($end - $os.Offset - $targetC)
    $maxRecovery = [int64]($minSize + $script:GiB)
    $targetRecovery = [int64]([math]::Floor(([math]::Min($capacity,$maxRecovery)) / $script:MiB) * $script:MiB)
    if ($targetRecovery -lt $minSize) { throw $m.CalculatedRecoveryTooSmall }
    return [pscustomobject]@{ TargetC=$targetC; Recovery=$targetRecovery; MinRecovery=$minSize; MaxRecovery=$maxRecovery; Offset=[int64]($os.Offset + $targetC) }
}
function Assert-PlanGeometry($disk, $os, $old, $plan) {
    # Recheck all arithmetic in bytes before showing the destructive plan.
    $diskSize = [int64]$disk.Size
    $osStart = [int64]$os.Offset
    $currentCEnd = [int64]($osStart + [int64]$os.Size)
    if ($diskSize -le 0 -or $osStart -lt 0 -or $currentCEnd -gt $diskSize) {
        throw $m.InvalidDiskGeometry
    }
    if ([int64]$plan.TargetC -lt [int64]$os.Size -or [int64]$plan.MinRecovery -le 0 -or
        [int64]$plan.Recovery -lt [int64]$plan.MinRecovery) {
        throw $m.InvalidPlanSizes
    }
    if ($plan.Mode -eq 'Rebuild') {
        $recoveryStart = [int64]($osStart + [int64]$plan.TargetC)
        $recoveryEnd = [int64]($recoveryStart + [int64]$plan.Recovery)
        $usableEnd = [int64]([math]::Floor(($diskSize - 4 * $script:MiB) / $script:MiB) * $script:MiB)
        if ($recoveryStart -ne [int64]$plan.Offset -or $recoveryStart -lt $currentCEnd -or
            $recoveryEnd -gt $usableEnd -or $recoveryEnd -le $recoveryStart -or
            ($recoveryStart % $script:MiB) -ne 0 -or ($recoveryEnd % $script:MiB) -ne 0) {
            throw ($m.InvalidPlanGeometry -f (SizeGiB $diskSize), (SizeGiB $recoveryEnd))
        }
        if ([int64]$plan.Recovery -gt [int64]$plan.MaxRecovery) {
            throw $m.RecoveryExceedsMaximum
        }
        foreach ($part in @(Get-Partition -DiskNumber $script:DiskNumber -ErrorAction Stop)) {
            if ([int]$part.PartitionNumber -eq [int]$os.PartitionNumber) { continue }
            if ($old -and [int]$part.PartitionNumber -eq [int]$old.PartitionNumber) { continue }
            $partStart = [int64]$part.Offset
            $partEnd = [int64]($partStart + [int64]$part.Size)
            if ($partStart -lt $recoveryEnd -and $partEnd -gt $currentCEnd) {
                throw ($m.PartitionOverlap -f $part.PartitionNumber)
            }
        }
    } else {
        if (-not $old -or [int64]$plan.TargetC -ne [int64]$os.Size -or
            [int64]$plan.Offset -ne [int64]$old.Offset -or
            [int64]$plan.Recovery -ne [int64]$old.Size) {
            throw $m.InPlaceMismatch
        }
    }
}
function Assert-StillSame($os, $old, [string]$identity, [int64]$diskSize) {
    $nowDisk = Get-Disk -Number $script:DiskNumber -ErrorAction Stop
    if ([string]$nowDisk.UniqueId -ne $identity) { throw $m.DiskIdentityChanged }
    if ([int64]$nowDisk.Size -ne $diskSize) { throw $m.DiskCapacityChanged }
    $nowC = Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $os.PartitionNumber -ErrorAction Stop
    if ($nowC.Offset -ne $os.Offset -or $nowC.Size -ne $os.Size -or [string]$nowC.DriveLetter -ine 'C') { throw $m.CChanged }
    if ($old) {
        $nowOld = Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $old.PartitionNumber -ErrorAction Stop
        if ($nowOld.Offset -ne $old.Offset -or $nowOld.Size -ne $old.Size -or -not (Is-RecoveryPartition $nowOld ([string]$nowDisk.PartitionStyle))) {
            throw $m.RecoveryChanged
        }
    }
}
function Assert-DiskLayoutSnapshot($snapshot) {
    $current = @(Get-Partition -DiskNumber $script:DiskNumber -ErrorAction Stop | Sort-Object Offset)
    if ($current.Count -ne $snapshot.Count) { throw $m.PartitionCountChanged }
    for ($i = 0; $i -lt $current.Count; $i++) {
        if ($current[$i].PartitionNumber -ne $snapshot[$i].PartitionNumber -or
            $current[$i].Offset -ne $snapshot[$i].Offset -or
            $current[$i].Size -ne $snapshot[$i].Size) {
            throw $m.LayoutChanged
        }
    }
}
function Assert-OldPartitionSafe($part) {
    # Never delete a known OEM/custom recovery partition with other content.
    if (-not $part) { return }
    $root = Get-RecoveryRoot $part
    if (-not $root) { throw $m.RecoveryCannotInspect }
    $allowed = @('Recovery', 'System Volume Information', '$RECYCLE.BIN')
    foreach ($entry in @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop)) {
        if ($entry.Name -notin $allowed) { throw ($m.UnexpectedRecoveryItem -f $entry.Name) }
    }
    $recoveryFolder = Join-Path $root 'Recovery'
    if (Test-Path -LiteralPath $recoveryFolder) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $recoveryFolder -Force -ErrorAction Stop)) {
            if ($entry.Name -notin @('WindowsRE')) { throw ($m.OemRecoveryItem -f $entry.Name) }
        }
        $windowsReFolder = Join-Path $recoveryFolder 'WindowsRE'
        if (Test-Path -LiteralPath $windowsReFolder) {
            foreach ($entry in @(Get-ChildItem -LiteralPath $windowsReFolder -Force -ErrorAction Stop)) {
                if ($entry.PSIsContainer -or $entry.Name -notin @('Winre.wim','ReAgent.xml','boot.sdi')) {
                    throw ($m.UnrecognizedWindowsReItem -f $entry.Name)
                }
            }
        }
    }
}
function Set-RecoveryType([int]$number, [string]$style) {
    if ($style -eq 'GPT') {
        Run-DiskPart @("select disk $script:DiskNumber", "select partition $number", "set id=$script:RecoveryGuid override", 'gpt attributes=0x8000000000000001')
    } else {
        Run-DiskPart @("select disk $script:DiskNumber", "select partition $number", 'set id=27 override')
    }
    $checked = Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $number
    if (-not (Is-RecoveryPartition $checked $style)) { throw $m.RecoveryTypeFailed }
    if ($style -eq 'GPT') {
        # Get-Partition.NoDefaultDriveLetter can be null on a correctly configured
        # recovery volume. Inspect the actual GPT attribute via DiskPart instead.
        $probeFile = Join-Path $script:WorkDir ([guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllLines($probeFile, @(
            "select disk $script:DiskNumber", "select partition $number", 'detail partition'
        ), [Text.Encoding]::ASCII)
        try {
            $probe = (& diskpart.exe /s $probeFile 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) { throw $m.GptReadFailed }
            if ($probe -notmatch '(?i)0x8000000000000001') {
                throw $m.GptAttributesWrong
            }
        } finally {
            Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    Import-Module Storage -ErrorAction Stop
    Import-Module Dism -ErrorAction Stop
    if ($env:SystemDrive -ine 'C:') { throw $m.OnlyC }
    $osData = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$osData.CurrentBuildNumber
    if ($build -lt 14393) { throw $m.OsTooOld }
    $edition = [string]$osData.EditionID
    $processor = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
    $arch = Get-NormalizedArchitecture ([string]$processor.Architecture)
    $os = Get-Partition -DriveLetter C -ErrorAction Stop
    $script:DiskNumber = [int]$os.DiskNumber
    $disk = Get-Disk -Number $script:DiskNumber -ErrorAction Stop
    $parts = @(Get-Partition -DiskNumber $script:DiskNumber | Sort-Object Offset)
    $recoveries = @($parts | Where-Object { Is-RecoveryPartition $_ ([string]$disk.PartitionStyle) })
    if ($recoveries.Count -gt 1) { throw $m.MultipleRecoveries }
    $old = if ($recoveries.Count -eq 1) { $recoveries[0] } else { $null }
    $state = Get-ReInfo
    Write-Section $m.AnalysisSection
    Write-Detail $m.WindowsLabel ($m.WindowsValue -f $edition, $build, $arch)
    Write-Detail $m.SystemDisk ("$script:DiskNumber ($($disk.PartitionStyle))")
    Write-Detail $m.DiskCapacity (SizeGiB ([int64]$disk.Size))
    Write-Detail $m.CLabel (SizeGiB $os.Size)
    $statusColor = if ($state.Status -eq 'Enabled') { 'Green' } else { 'Yellow' }
    Write-Detail $m.WinreLabel $(if ($state.Status -eq 'Enabled') { $m.StatusEnabled } else { $m.StatusDisabled }) $statusColor
    Write-Detail $m.RecoveryLabel $(if ($old) { ($m.RecoveryValue -f $old.PartitionNumber, (SizeMiB $old.Size)) } else { $m.NotFound })
    if ($state.Status -eq 'Enabled') {
        Write-Result $m.AlreadyEnabled
        return
    }
    $layoutMode = Get-LayoutMode $disk $os $old $parts
    Assert-OldPartitionSafe $old
    Assert-BitLockerSafe
    # Staging is local to C:, so it survives deletion of the old Recovery.
    $script:WorkDir = Join-Path $env:windir ('Temp\WinRE-Manager-' + [guid]::NewGuid().ToString('N'))
    $script:MountDir = Join-Path $script:WorkDir 'Mount'
    $script:WimFile = Join-Path $script:WorkDir 'Winre.wim'
    New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null
    Write-Section $m.ImageSourceSection
    $source = Find-Wim $old
    Write-Host ''
    $sourceInfo = $null
    if ($source) {
        Write-Detail $m.LocalWinre $source 'Green'
        Copy-Item -LiteralPath $source -Destination $script:WimFile -Force -ErrorAction Stop
        $sourceInfo = ($m.LocalSource -f $source)
        $script:ExtractionMethod = 'Local file'
    } else {
        Write-Detail $m.LocalWinre $m.NoUsableImage 'Yellow'
        Write-Notice $m.IsoRequired
        Write-Host ''
        $letter = (Read-Host $m.IsoLetterPrompt).Trim().ToUpperInvariant()
        if (-not $letter) { Write-Result $m.CanceledPartitions; return }
        if ($letter -notmatch '^[A-Z]$') { throw $m.LetterWithoutColon }
        $install = Find-IsoImage $letter
        if (-not $install) { throw ($m.IsoMissingInstall -f $letter) }
        Write-Detail $m.InstallationFile $install
        $index = Select-IsoIndex $install $edition $build $arch
        Extract-IsoWinre $install $index
        $sourceInfo = ($m.IsoSource -f $letter, $index)
    }
    Write-Step $m.ValidatingStagedWim
    if (-not (Test-Wim $script:WimFile)) { throw $m.StagedWimInvalid }
    $imageSize = [int64](Get-Item -LiteralPath $script:WimFile -Force).Length
    Write-Detail $m.WinreImage ((SizeMiB $imageSize) + $m.ValidatedSuffix) 'Green'
    $minSize = [int64]([math]::Ceiling(([math]::Max(990 * $script:MiB, $imageSize + 250 * $script:MiB + 32 * $script:MiB)) / $script:MiB) * $script:MiB)
    if ($layoutMode -eq 'InPlace') {
        if ($old.Size -lt $minSize) {
            throw ($m.InPlaceTooSmall -f (SizeMiB $old.Size), (SizeMiB $minSize))
        }
        $plan = [pscustomobject]@{
            Mode='InPlace'; TargetC=[int64]$os.Size; Recovery=[int64]$old.Size;
            MinRecovery=$minSize; MaxRecovery=[int64]$old.Size;
            Offset=[int64]$old.Offset
        }
    } else {
        $plan = Make-Plan $disk $os $minSize
        $plan | Add-Member -NotePropertyName Mode -NotePropertyValue 'Rebuild'
    }
    # Refuse impossible geometry before the user can approve a destructive change.
    Assert-PlanGeometry $disk $os $old $plan
    $identity = [string]$disk.UniqueId
    $partitionSnapshot = @($parts | ForEach-Object {
        [pscustomobject]@{ PartitionNumber=$_.PartitionNumber; Offset=$_.Offset; Size=$_.Size }
    })
    Write-Section $m.PlanSection
    Write-Detail $m.ImageSource $sourceInfo
    Write-Detail $m.ImageExtraction $(if ($script:ExtractionMethod -eq 'Local file') { $m.LocalFileMethod } else { $script:ExtractionMethod })
    Write-Detail $m.ImageSize (SizeMiB $imageSize)
    Write-Detail $m.DiskCapacity (SizeGiB ([int64]$disk.Size))
    Write-Detail $m.CCurrent (SizeGiB $os.Size)
    Write-Detail $m.CProposed (SizeGiBWithNtfsMargin $plan.TargetC) $(if ($plan.TargetC -gt $os.Size) { 'Yellow' } else { 'White' })
    Write-Detail $m.RecoveryCurrent $(if ($old) { SizeMiB $old.Size } else { $m.None })
    Write-Detail $m.RecoveryTarget (SizeMiB $plan.Recovery) 'Yellow'
    Write-Detail $m.RecoveryMinimum (SizeMiB $plan.MinRecovery)
    if ($plan.Mode -eq 'Rebuild') {
        $unusedTail = [int64]($disk.Size - $plan.Offset - $plan.Recovery)
        Write-Detail $m.UnallocatedAfter (SizeMiB $unusedTail)
    }
    Write-Host ''
    Write-Host $m.PlannedActions -ForegroundColor Gray
    if ($old) { Write-Step $m.PlanTryEnable }
    else { Write-Step $m.PlanMissingRecovery }
    if ($plan.Mode -eq 'InPlace') {
        Write-Step $m.PlanKeepLater
        Write-Step ($m.PlanReformat -f $old.PartitionNumber)
    } else {
        if ($old) { Write-Step ($m.PlanDelete -f $old.PartitionNumber) }
        else { Write-Step $m.PlanUseUnallocated }
        if ($plan.TargetC -gt $os.Size) { Write-Step ($m.PlanExtend -f (SizeGiBWithNtfsMargin $plan.TargetC)) }
        Write-Step ($m.PlanCreate -f (SizeMiB $plan.Recovery))
    }
    Write-Section $m.SafetySection
    Write-Notice $m.RecoveryContentWarning
    Write-Notice $m.BackupWarning
    Write-Host $m.AnalysisNoChanges -ForegroundColor DarkGray
    Write-Host $m.NoRollback -ForegroundColor DarkGray
    Write-Host ''
    $decision = (Read-Host $m.ConfirmPlan).Trim().ToUpperInvariant()
    if ($decision -cne 'Y') { Write-Result $m.CanceledSettings; return }

    Write-Section $m.ExecutionSection
    Assert-StillSame $os $old $identity ([int64]$disk.Size)
    Assert-DiskLayoutSnapshot $partitionSnapshot
    # When the Recovery partition is missing, a successful /enable may merely
    # register WinRE on C:, defeating the approved goal of recreating Recovery.
    if ($old) {
        Write-Step $m.TryingEnable
        & reagentc.exe /enable
        $code = $LASTEXITCODE
        $nowState = Get-ReInfo
        if ($code -eq 0 -and $nowState.Status -eq 'Enabled') {
            Write-Result $m.SuccessWithoutRepartition
            $script:Completed = $true
            return
        }
        if ($nowState.Status -eq 'Enabled') {
            throw $m.EnableInconsistent
        }
        Write-Notice $m.EnableFailedContinue
    } else {
        Write-Step $m.CreatingMissingRecovery
    }
    Assert-StillSame $os $old $identity ([int64]$disk.Size)
    Assert-DiskLayoutSnapshot $partitionSnapshot
    if ($plan.Mode -eq 'InPlace') {
        $script:NewPartNumber = [int]$old.PartitionNumber
        $script:Mutated = $true
        $mountedPart = Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $script:NewPartNumber -ErrorAction Stop
        if ($mountedPart.Offset -ne $old.Offset -or $mountedPart.Size -ne $old.Size) {
            throw $m.RecoveryChangedUnexpectedly
        }
        Say ($m.FormattingRecovery -f $script:NewPartNumber)
        Format-Volume -Partition $mountedPart -FileSystem NTFS -NewFileSystemLabel 'Windows RE tools' -Force -Confirm:$false -ErrorAction Stop | Out-Null
        Open-RecoveryMount $script:NewPartNumber
    } else {
        if ($old) {
            Say ($m.DeletingRecovery -f $old.PartitionNumber)
            $script:Mutated = $true
            Run-DiskPart @("select disk $script:DiskNumber", "select partition $($old.PartitionNumber)", 'delete partition override')
            $afterDelete = @(Get-Partition -DiskNumber $script:DiskNumber | Where-Object { $_.Offset -eq $old.Offset })
            if ($afterDelete.Count -ne 0) { throw $m.RecoveryNotRemoved }
        }
        if ($plan.TargetC -gt $os.Size) {
            Say ($m.ExtendingC -f (SizeGiBWithNtfsMargin $plan.TargetC))
            $supported = Get-PartitionSupportedSize -DiskNumber $script:DiskNumber -PartitionNumber $os.PartitionNumber -ErrorAction Stop
            if ($supported.SizeMax -lt $plan.TargetC) { throw $m.CannotExtendC }
            $script:Mutated = $true
            Resize-Partition -DiskNumber $script:DiskNumber -PartitionNumber $os.PartitionNumber -Size $plan.TargetC -ErrorAction Stop
        }
        $updatedC = Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $os.PartitionNumber -ErrorAction Stop
        if ($updatedC.Offset -ne $os.Offset -or $updatedC.Size -ne $plan.TargetC) { throw $m.CResizeMismatch }
        $offset = [int64]($updatedC.Offset + $updatedC.Size)
        if ($offset -ne $plan.Offset) { throw $m.RecoveryOffsetMismatch }
        Say ($m.CreatingRecovery -f (SizeMiB $plan.Recovery))
        $script:Mutated = $true
        if ([string]$disk.PartitionStyle -eq 'GPT') {
            $created = New-Partition -DiskNumber $script:DiskNumber -Offset $offset -Size $plan.Recovery -GptType $script:BasicGuid -ErrorAction Stop
        } else {
            $created = New-Partition -DiskNumber $script:DiskNumber -Offset $offset -Size $plan.Recovery -MbrType IFS -ErrorAction Stop
        }
        $script:NewPartNumber = [int]$created.PartitionNumber
        $new = Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $script:NewPartNumber
        if ($new.Offset -ne $offset -or $new.Size -lt $plan.MinRecovery -or $new.Size -ne $plan.Recovery) {
            throw $m.CreatedRecoveryMismatch
        }
        if ($new.DriveLetter) {
            throw $m.UnexpectedDriveLetter
        }
        Format-Volume -Partition $new -FileSystem NTFS -NewFileSystemLabel 'Windows RE tools' -Force -Confirm:$false -ErrorAction Stop | Out-Null
        Open-RecoveryMount $script:NewPartNumber
    }
    $targetDir = Join-Path $script:MountAccessPath 'Recovery\WindowsRE'
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    $targetFile = Join-Path $targetDir 'Winre.wim'
    Copy-Item -LiteralPath $script:WimFile -Destination $targetFile -Force -ErrorAction Stop
    if ((Get-FileHash -LiteralPath $script:WimFile -Algorithm SHA256).Hash -ine (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash) {
        throw $m.WimHashMismatch
    }
    $newVolume = Get-Volume -Partition (Get-Partition -DiskNumber $script:DiskNumber -PartitionNumber $script:NewPartNumber) -ErrorAction Stop
    if ($newVolume.SizeRemaining -lt 250 * $script:MiB) { throw $m.RecoveryFreeSpaceLow }
    Say $m.RegisteringWinre
    Run-External 'reagentc.exe' @('/setreimage','/path',$targetDir)
    Run-External 'reagentc.exe' @('/enable')
    $final = Get-ReInfo
    if ($final.Status -ne 'Enabled') { throw $m.WinreNotEnabled }
    if ($final.Output -notmatch "(?i)harddisk$script:DiskNumber\\partition$script:NewPartNumber(\\|\b)") {
        throw $m.WinreLocationUnverified
    }
    # Detach the temporary NTFS folder mount BEFORE changing GPT type.
    # There is never a temporary drive letter in this workflow.
    Write-Step $m.RemovingMount
    Close-RecoveryMount
    if ($plan.Mode -eq 'Rebuild') {
        Say $m.ApplyingRecoveryType
        Set-RecoveryType $script:NewPartNumber ([string]$disk.PartitionStyle)
    }
    $final = Get-ReInfo
    if ($final.Status -ne 'Enabled' -or $final.Output -notmatch "(?i)harddisk$script:DiskNumber\\partition$script:NewPartNumber(\\|\b)") {
        throw $m.FinalValidationFailed
    }
    Say $final.Output
    $script:Completed = $true
    Write-Result $m.Success
} catch {
    if ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) {
        # Ctrl+C may surface as a pipeline-stopped exception. The finally
        # block prints the same interruption notice as a direct pipeline stop.
    } else {
        $script:Failed = $true
        Write-Section $m.ErrorSection
        Write-Host ('  ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host ''
        if ($script:Mutated) {
            Write-Notice $m.DiskMayHaveChanged
        }
        Write-Host $m.Diagnostics -ForegroundColor Gray
    }
} finally {
    try {
        if ($script:Mounted) {
            try {
                Run-External 'dism.exe' @('/English','/Unmount-Image',"/MountDir:$script:MountDir",'/Discard')
                $script:Mounted = $false
            } catch { Write-Warning ($m.UnmountFailed -f $_) }
        }
        if ($script:MountAccessPath) {
            try {
                Close-RecoveryMount
            } catch {
                Write-Warning ($m.DetachFailed -f $script:MountAccessPath, $_)
                Write-Warning $m.MountRetained
            }
        }
        if ($script:WorkDir -and (Test-Path -LiteralPath $script:WorkDir -PathType Container)) {
            if ($script:Mutated -and -not $script:Completed) {
                Say ($m.StagedWimPreserved -f $script:WimFile)
                Say ($m.WorkDirectory -f $script:WorkDir)
            } elseif (-not $script:Mounted) {
                try { Remove-Item -LiteralPath $script:WorkDir -Recurse -Force -ErrorAction Stop }
                catch { Write-Warning ($m.RemoveWorkFailed -f $_) }
            }
        }
        if (-not $script:Failed -and -not $script:ResultWasReported) {
            # Unwinding from Ctrl+C can bypass catch. No normal result was printed.
            $global:LASTEXITCODE = 130
            Write-InterruptedNotice
        } elseif ($script:Failed) {
            $global:LASTEXITCODE = 1
        }
    } finally {
        Stop-Utility -Utility $utility
    }
}

if ($script:Failed) { throw $m.Failed }
