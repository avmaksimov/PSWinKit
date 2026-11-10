#Requires -Version 5.1
# Diagnostic image-first planning. No disk writes or partition changes.
# Recovery is mounted temporarily for READ access; Close-CSRecoveryMount runs in finally.

$script:CSFreeReserve = [int64]250MB
# Safety allowance for differences when a Recovery volume is freshly formatted.
# This is separate from the mandatory 250 MiB free space for servicing.
$script:CSFormatVariation = [int64]16MB
$script:CSCreateMinimum = [int64]990MB
$script:CSNewNtfsAllowance = [int64]64MB
$script:CSCosmeticLimit = [int64]256MB
$script:CSBeautyStep = [int64](10GB)

function Get-CSImageAssessment($disk, $c, $parts, $reInfo, $activeRecovery) {
    $out = [ordered]@{
        Found = $false; Verified = $false; Source = ''; WIMBytes = [int64]0
        ExtraBytes = [int64]0; Existing = $null; UsedBytes = $null
        FreeBytes = $null; MinRecoveryBytes = $null; ImagePath = ''; Error = ''
    }
    $candidate = $activeRecovery
    if ($null -eq $candidate) {
        # An unregistered Recovery is NEVER assumed safe to delete. Read it only
        # if it is the unique immediate GPT Recovery after C:.
        $following = @($parts | Where-Object {
            [int64]$_.Offset -ge (Get-PartitionEnd $c)
        } | Sort-Object Offset)
        if ($following.Count -gt 0 -and
            (Test-RecoveryPartition $following[0] ([string]$disk.PartitionStyle))) {
            $candidate = $following[0]
        }
    }
    $path = $null
    $mountOpened = $false
    try {
        if ($null -ne $candidate) {
            try {
                $root = Open-CSRecoveryMount ([int]$disk.Number) ([int]$candidate.PartitionNumber)
                $mountOpened = $true
                $folder = Assert-CSRecoveryContent $root
                $candidatePath = Join-Path $folder 'Winre.wim'
                if ([IO.File]::Exists($candidatePath)) {
                    $path = $candidatePath
                    $out.Existing = $candidate
                    $out.Source = if ($null -ne $activeRecovery) {
                        ($m.CS26SourceRegistered -f $candidate.PartitionNumber)
                    } else { ($m.CS26SourceUnregistered -f $candidate.PartitionNumber) }
                    try {
                        $volume = Get-Volume -Partition $candidate -ErrorAction Stop
                        if ($null -ne $volume -and [int64]$volume.Size -gt 0 -and
                            [int64]$volume.SizeRemaining -ge 0 -and
                            [int64]$volume.SizeRemaining -le [int64]$volume.Size) {
                            $out.UsedBytes = [int64]$volume.Size - [int64]$volume.SizeRemaining
                            $out.FreeBytes = [int64]$volume.SizeRemaining
                            # Include the observed difference between NTFS capacity and
                            # partition geometry, not an arbitrary 64 MiB allowance.
                            $out.MinRecoveryBytes = Align-UpMiB ([int64](
                                $out.UsedBytes + $script:CSFreeReserve +
                                [math]::Max([int64]0, [int64]$candidate.Size - [int64]$volume.Size) +
                                $script:MiB + $script:CSFormatVariation))
                        }
                    } catch { }
                }
            } catch {
                # A registered Recovery with unexpected content must not be
                # bypassed by using a different image source for a rebuild.
                if ($null -ne $activeRecovery) { throw }
            }
        }
        # Supported MBR migration: reagentc /info identifies the Windows C:
        # partition itself. Use the registered image on C:, NOT an ISO, and
        # do not disable or delete the original WinRE during planning.
        if ($null -eq $path -and [string]$disk.PartitionStyle -eq 'MBR' -and
            $reInfo.Enabled -and $null -ne $reInfo.DiskNumber -and
            $null -ne $reInfo.PartitionNumber -and
            [int]$reInfo.DiskNumber -eq [int]$disk.Number -and
            [int]$reInfo.PartitionNumber -eq [int]$c.PartitionNumber) {
            $registeredFolder = Join-Path ([string]$env:SystemDrive + '\') 'Recovery\WindowsRE'
            $registeredWim = Join-Path $registeredFolder 'Winre.wim'
            if ([IO.File]::Exists($registeredWim)) {
                $dirInfo = Get-Item -LiteralPath $registeredFolder -Force -ErrorAction Stop
                if (($dirInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw $m.CSMBRUnsafeSource
                }
                foreach ($entry in @(Get-ChildItem -LiteralPath $registeredFolder -Force -ErrorAction Stop)) {
                    if ($entry.PSIsContainer -or
                        (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
                        $entry.Name -notin @('Winre.wim','boot.sdi','ReAgent.xml','ReAgent.old',
                            'SrSettings.ini','WifiSettings.ini','ReCustomization.xml')) {
                        throw $m.CSMBRUnsafeSource
                    }
                }
                $path = $registeredWim
                $out.Source = $m.CSMBRSourceOnC
            }
        }
        if ($null -eq $path) {
            if ($mountOpened) {
                Close-CSRecoveryMount ([int]$disk.Number)
                $mountOpened = $false
            }
            $local = Join-Path $env:windir 'System32\Recovery\Winre.wim'
            if ([IO.File]::Exists($local)) {
                try {
                    Assert-CSWim $local
                    $path = $local
                } catch {
                    if ($null -ne $activeRecovery -or $reInfo.Enabled -or
                        @($parts | Where-Object { Test-RecoveryPartition $_ ([string]$disk.PartitionStyle) }).Count -gt 0) {
                        throw
                    }
                    Write-Host $m.CSIsoLocalInvalid -ForegroundColor Yellow
                }
                if ($path) { $out.Source = $m.CS26SourceLocal }
                # No measured source-volume usage is applicable for a newly
                # created Recovery: use the from-scratch policy instead.
                $out.Existing = $null
                $out.UsedBytes = $null
                $out.FreeBytes = $null
                $out.MinRecoveryBytes = $null
            }
        }
        if ($null -eq $path -and -not $reInfo.Enabled -and
            [string]$disk.PartitionStyle -eq 'GPT' -and
            $null -eq $activeRecovery -and
            @($parts | Where-Object { Test-RecoveryPartition $_ ([string]$disk.PartitionStyle) }).Count -eq 0) {
            # Only the missing-Recovery path may use an ISO source. Obtain and
            # validate the image BEFORE building any destructive disk plan.
            $path = Get-CSISOImage
            if ($path) { $out.Source = $m.CSIsoImageSource }
        }
        if ($null -eq $path) {
            $out.Error = $m.CS26ImageMissing
            return [pscustomobject]$out
        }
        # Validate the WIM header / image with Windows DISM, without copying it.
        Assert-CSWim $path
        $out.WIMBytes = [int64](Get-Item -LiteralPath $path -Force -ErrorAction Stop).Length
        $imageFolder = Split-Path -Parent $path
        foreach ($file in @(Get-ChildItem -LiteralPath $imageFolder -File -Force -ErrorAction Stop |
            Where-Object { $_.Name -ine 'Winre.wim' })) {
            $out.ExtraBytes += [int64]$file.Length
        }
        if ($null -eq $out.MinRecoveryBytes) {
            # A missing/unmeasurable source needs a conservative new-partition
            # estimate; old Recovery dimensions are not a substitute for this.
            $out.MinRecoveryBytes = Align-UpMiB ([int64][math]::Max(
                [double]$script:CSCreateMinimum,
                [double]($out.WIMBytes + $out.ExtraBytes +
                    $script:CSNewNtfsAllowance + $script:CSFreeReserve +
                    $script:CSFormatVariation)))
        }
        $out.ImagePath = [string]$path
        $out.Found = $true
        $out.Verified = $true
        return [pscustomobject]$out
    } catch {
        $out.Error = $_.Exception.Message
        return [pscustomobject]$out
    } finally {
        if ($script:CSExecMount) {
            try { Close-CSRecoveryMount ([int]$disk.Number) }
            catch {
                # A mount that cannot be detached is a hard error, not a
                # cosmetic diagnostic problem.
                throw ($m.CS26MountCleanupFailed -f $_.Exception.Message)
            }
        }
    }
}

function Get-CSProposedGeometry($disk, $c, $parts, $activeRecovery, [int64]$newCSize, $bounds,
    [int64]$maxNewSize = 0) {
    if ($null -ne $activeRecovery) {
        return Get-RebuildPreview $disk $c $parts $activeRecovery $newCSize
    }
    # When creating a missing Recovery, C: may be shrunk to make room or
    # extended into an existing adjacent gap, but may never cross its right
    # boundary. The new Recovery is always placed directly after the new C:.
    if ($newCSize -le 0) { return $null }
    $cEnd = [int64]$c.Offset + $newCSize
    $next = @($parts | Where-Object {
        [int]$_.PartitionNumber -ne [int]$c.PartitionNumber -and
        [int64]$_.Offset -ge (Get-PartitionEnd $c)
    } | Sort-Object Offset)
    $rightEnd = if ($next.Count -gt 0) { [int64]$next[0].Offset }
                elseif ($null -ne $bounds) { [int64]$bounds.End }
                else { return $null }
    $start = Align-UpMiB $cEnd
    # Even an empty gap is useful to planning: C: can be shrunk to create one.
    $available = [int64][math]::Max([int64]0, ($rightEnd - $start))
    $newSize = $available
    if ($maxNewSize -gt 0) {
        $newSize = [int64][math]::Min($available, (Align-DownMiB $maxNewSize))
    }
    return [pscustomobject]@{
        OldNumber = 0; OldSize = [int64]0; NewStart = [int64]$start
        NewSize = [int64]$newSize; RightEnd = [int64]$rightEnd
        AbsorbedGapBytes = [int64]0; IsGeometryPossible = [bool]($newSize -gt 0)
        CreatesMissing = $true
    }
}

function Get-CSPlanningDecision($disk, $c, $parts, $reInfo, $activeRecovery,
    $assessment, $volume, $bounds) {
    if ($null -eq $activeRecovery -and $null -ne $assessment.Existing) {
        # An unregistered partition must not be overwritten or duplicated.
        return $null
    }
    if ($null -ne $activeRecovery -and $null -eq $assessment.Existing) {
        # Registered Recovery lacks its own usable image. Do not silently
        # replace it based on a different source without an explicit repair flow.
        return $null
    }
    if (-not $assessment.Verified -or $null -eq $volume -or
        [int64]$volume.Size -le 0 -or $null -eq $assessment.MinRecoveryBytes) {
        return $null
    }
    $style = [string]$disk.PartitionStyle
    $mbrOnC = ($style -eq 'MBR' -and $reInfo.Enabled -and
        $null -ne $reInfo.DiskNumber -and $null -ne $reInfo.PartitionNumber -and
        [int]$reInfo.DiskNumber -eq [int]$disk.Number -and
        [int]$reInfo.PartitionNumber -eq [int]$c.PartitionNumber -and
        [string]$assessment.ImagePath -ieq (Join-Path ([string]$env:SystemDrive + '\') 'Recovery\WindowsRE\Winre.wim'))
    if ($style -ne 'GPT' -and -not $mbrOnC) { return $null }
    if ($null -eq $activeRecovery) {
        if (@($parts | Where-Object { Test-RecoveryPartition $_ $style }).Count -gt 0) { return $null }
        if (-not $mbrOnC -and ($reInfo.Enabled -or $null -ne $reInfo.DiskNumber)) { return $null }
        if ($mbrOnC -and (@($parts | Where-Object {
            [string]$_.Type -match '(?i)Extended|Logical|Unknown|Reserved|OEM'
        }).Count -gt 0 -or $parts.Count -ge 4)) { return $null }
    }
    $originalCSize = [int64]$c.Size
    $minRecovery = [int64]$assessment.MinRecoveryBytes
    $fsBytes = [int64]$volume.Size
    $fsDelta = [int64][math]::Max([int64]0, $originalCSize - $fsBytes)
    # The measured minimum already includes NTFS formatting overhead.
    # Allocate 512 MiB of future growth inside Recovery, but do not shrink
    # C: for an additional 16 MiB that would only duplicate the allowance.
    $maxNewSize = [int64]($minRecovery + 512MB)
    $originalGeo = Get-CSProposedGeometry $disk $c $parts $activeRecovery $originalCSize $bounds $maxNewSize
    if ($null -eq $originalGeo) { return $null }
    $rightEnd = if ($null -eq $activeRecovery) {
        [int64]$originalGeo.RightEnd
    } else { [int64]$originalGeo.NewStart + [int64]$originalGeo.NewSize }

    # First decide if Windows RE needs repair or more space (independent of C:
    # aesthetics). When recovery is healthy, preserve C: unless beauty is cheap.
    $mustRepair = (-not $reInfo.Enabled -or $null -eq $activeRecovery -or
        ($null -ne $assessment.FreeBytes -and
         [int64]$assessment.FreeBytes -lt $script:CSFreeReserve))
    $baseC = $originalCSize
    if ($mustRepair) {
        if ($null -eq $activeRecovery) {
            # Existing free space is never automatically returned to C:.
            # Preserve the current C: size and present an OPTIONAL numeric
            # allocation choice to the user after they select creating Recovery.
            # Only shrink C: when the adjacent space is too small even for
            # the calculated Recovery minimum.
            $existingGap = [int64][math]::Max([int64]0,
                $rightEnd - (Align-UpMiB (Get-PartitionEnd $c)))
            if ($existingGap -lt $minRecovery) {
                $targetEnd = Align-DownMiB ([int64]($rightEnd - $maxNewSize))
                $baseC = [int64]($targetEnd - [int64]$c.Offset)
                if ($baseC -le 0) { return $null }
            }
        } elseif ([int64]$originalGeo.NewSize -lt $minRecovery) {
            $targetEnd = Align-DownMiB ([int64]($rightEnd - $minRecovery))
            $baseC = [int64]($targetEnd - [int64]$c.Offset)
            if ($baseC -le 0) { return $null }
        }
    }
    $baseGeo = Get-CSProposedGeometry $disk $c $parts $activeRecovery $baseC $bounds $maxNewSize
    if ($null -eq $baseGeo -or [int64]$baseGeo.NewSize -lt $minRecovery) { return $null }

    $chosenC = $baseC
    $beauty = $false
    $beautyGiB = [int64]0
    # Only multiples of TEN GiB. Cosmetic change must not exceed 256 MiB
    # relative to the technical plan, and the candidate must preserve RE room.
    $step = [double]$script:CSBeautyStep
    $lower = [int64]([math]::Floor($fsBytes / $step) * 10)
    $upper = [int64]($lower + 10)
    foreach ($number in @($lower, $upper)) {
        # Cosmetic resizes are not part of creating a missing Recovery.
        if ($null -eq $activeRecovery -or $number -le 0) { continue }
        $goalFS = [int64]($number * $script:GiB)
        $desiredEnd = Align-UpMiB ([int64]($c.Offset + $goalFS + $fsDelta))
        $size = [int64]($desiredEnd - [int64]$c.Offset)
        # Don't propose a cosmetic rebuild for an already-beautiful capacity.
        if (-not $mustRepair -and
            [int64][math]::Floor($fsBytes / [double]$script:GiB) -eq $number) { continue }
        if ([math]::Abs([double]($size - $baseC)) -gt $script:CSCosmeticLimit) { continue }
        $candidateGeo = Get-CSProposedGeometry $disk $c $parts $activeRecovery $size $bounds $maxNewSize
        if ($null -eq $candidateGeo -or [int64]$candidateGeo.NewSize -lt $minRecovery) { continue }
        # Avoid changing a system volume for beauty if the target filesystem
        # is only nominally smaller but Windows can't fit its actual metadata.
        if ($size -le 0) { continue }
        if (-not $beauty -or
            [math]::Abs([double]($size - $baseC)) -lt [math]::Abs([double]($chosenC - $baseC))) {
            $chosenC = $size
            $beautyGiB = $number
            $beauty = $true
        }
    }
    if (-not $mustRepair -and -not $beauty) { return $null }
    $geo = Get-CSProposedGeometry $disk $c $parts $activeRecovery $chosenC $bounds $maxNewSize
    if ($null -eq $geo -or [int64]$geo.NewSize -lt $minRecovery) { return $null }
    $targetExplorer = [int64][math]::Floor(
        ([double]($fsBytes + $chosenC - $originalCSize)) / $script:GiB)
    if ($beauty) { $targetExplorer = $beautyGiB }
    return [pscustomobject]@{
        TargetExplorerGiB = $targetExplorer
        TargetPartitionBytes = [int64]$chosenC
        CurrentVolumeBytes = $fsBytes
        ChangeBytes = [int64]($chosenC - $originalCSize)
        OriginalPartitionBytes = $originalCSize
        Beauty = [bool]$beauty
        MustRepair = [bool]$mustRepair
        MinimumRecoveryBytes = $minRecovery
        ImageSourcePath = [string]$assessment.ImagePath
        MigratingWinREOnC = [bool]$mbrOnC
        Geometry = $geo
    }
}

# Additional WinRE planning: inactive Recovery on the Windows disk and
# conservative MBR partition creation. No disk changes here.

function Get-CSInactiveRecoveryCandidate($disk, $c, $parts, $reInfo) {
    if ($reInfo.Enabled) { return $null }
    if ($null -ne $reInfo.DiskNumber -and
        [int]$reInfo.DiskNumber -ne [int]$disk.Number) {
        Write-Host $m.CSInactiveOtherDisk -ForegroundColor Yellow
        return $null
    }
    $matches = @($parts | Where-Object {
        Test-RecoveryPartition $_ ([string]$disk.PartitionStyle)
    })
    if ($matches.Count -ne 1) {
        if ($matches.Count -gt 1) {
            Write-Host $m.CSInactiveMultiple -ForegroundColor Yellow
        }
        return $null
    }
    $part = $matches[0]
    if ([int]$part.DiskNumber -ne [int]$disk.Number -or
        [int]$part.PartitionNumber -eq [int]$c.PartitionNumber -or
        $part.IsBoot -or $part.IsSystem -or $part.IsActive -or
        $part.DriveLetter) { return $null }
    # A disabled REAgentC may retain a stale location. Do not pick a DIFFERENT
    # partition by guesswork when its recorded partition number is present.
    if ($null -ne $reInfo.PartitionNumber -and
        [int]$reInfo.PartitionNumber -ne [int]$part.PartitionNumber) {
        Write-Host $m.CSInactiveRegisteredElsewhere -ForegroundColor Yellow
        return $null
    }
    $liveDisk = Get-Disk -Number ([int]$part.DiskNumber) -ErrorAction Stop
    if ([string]$liveDisk.UniqueId -ne [string]$disk.UniqueId -or
        [string]$liveDisk.PartitionStyle -ne [string]$disk.PartitionStyle) {
        return $null
    }
    return $part
}

# The regular assessment can inspect a partition supplied as activeRecovery,
# without writing to it. For inactive Recovery the source label must not say
# "registered", and registration is allowed only if the WIM was found THERE.
function Get-CSInactiveRecoveryAssessment($disk, $c, $parts, $reInfo, $candidate) {
    $result = Get-CSImageAssessment $disk $c $parts $reInfo $candidate
    # Report the real source even when that partition is too small to use.
    if ($result.Verified -and $null -ne $result.Existing -and
        [int]$result.Existing.PartitionNumber -eq [int]$candidate.PartitionNumber -and
        [int]$result.Existing.DiskNumber -eq [int]$disk.Number) {
        $result.Source = $m.CSInactiveRecoverySource -f $candidate.PartitionNumber
    }
    if (-not $result.Verified -or $null -eq $result.Existing -or
        [int]$result.Existing.PartitionNumber -ne [int]$candidate.PartitionNumber -or
        [int]$result.Existing.DiskNumber -ne [int]$disk.Number -or
        $null -eq $result.FreeBytes -or
        [int64]$result.FreeBytes -lt $script:CSFreeReserve -or
        $null -eq $result.MinRecoveryBytes -or
        [int64]$candidate.Size -lt [int64]$result.MinRecoveryBytes) {
        return $result
    }
    return $result
}

# True only when the image is verified and its existing partition can serve it.
# This does NOT attempt to resize a disabled Recovery partition.
function Test-CSInactiveRecoveryReady($disk, $candidate, $assessment) {
    return ($null -ne $candidate -and $null -ne $assessment -and
        $assessment.Verified -and $null -ne $assessment.Existing -and
        [int]$candidate.DiskNumber -eq [int]$disk.Number -and
        [int]$assessment.Existing.DiskNumber -eq [int]$disk.Number -and
        [int]$assessment.Existing.PartitionNumber -eq [int]$candidate.PartitionNumber -and
        $null -ne $assessment.FreeBytes -and
        [int64]$assessment.FreeBytes -ge $script:CSFreeReserve -and
        $null -ne $assessment.MinRecoveryBytes -and
        [int64]$candidate.Size -ge [int64]$assessment.MinRecoveryBytes)
}

function Test-CSMissingMBRRecovery($disk, $c, $parts, $reInfo) {
    # Disabled registration may be empty or may still refer to the running C:.
    # Every other disk/partition reference is ambiguous and blocks creation.
    $emptyRegistration = ($null -eq $reInfo.DiskNumber -and
        $null -eq $reInfo.PartitionNumber)
    $registeredOnC = ($null -ne $reInfo.DiskNumber -and
        $null -ne $reInfo.PartitionNumber -and
        [int]$reInfo.DiskNumber -eq [int]$disk.Number -and
        [int]$reInfo.PartitionNumber -eq [int]$c.PartitionNumber)
    if ([string]$disk.PartitionStyle -ne 'MBR' -or
        $reInfo.Enabled -or (-not $emptyRegistration -and -not $registeredOnC) -or
        -not $disk.IsBoot -or $disk.IsOffline -or $disk.IsReadOnly -or
        [int64]$disk.Size -ge 2TB -or $parts.Count -ge 4 -or
        [string]$c.Type -ne 'IFS') { return $false }
    foreach ($part in $parts) {
        if ([int]$part.DiskNumber -ne [int]$disk.Number -or
            [string]$part.Type -match '(?i)Extended|Logical|Unknown|Reserved|OEM' -or
            (Test-RecoveryPartition $part 'MBR')) { return $false }
    }
    return $true
}

function Get-CSMissingMBRImageAssessment($disk, $c, $parts, $reInfo, $original) {
    if (-not (Test-CSMissingMBRRecovery $disk $c $parts $reInfo)) { return $original }
    if ($original.Verified -and $null -eq $original.Existing) { return $original }
    $path = $null
    $source = ''
    $localFolder = Join-Path ([string]$env:SystemDrive + '\') 'Recovery\WindowsRE'
    $localWim = Join-Path $localFolder 'Winre.wim'
    if ([IO.File]::Exists($localWim)) {
        $directory = Get-Item -LiteralPath $localFolder -Force -ErrorAction Stop
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw $m.CSMBRUnsafeSource
        }
        foreach ($entry in @(Get-ChildItem -LiteralPath $localFolder -Force -ErrorAction Stop)) {
            if ($entry.PSIsContainer -or
                (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
                $entry.Name -notin @('Winre.wim','boot.sdi','ReAgent.xml','ReAgent.old',
                    'SrSettings.ini','WifiSettings.ini','ReCustomization.xml')) {
                throw $m.CSMBRUnsafeSource
            }
        }
        Assert-CSWim $localWim
        $path = $localWim
        $source = $m.CSMBRSourceOnC
    }
    if (-not $path) {
        $path = Get-CSISOImage
        if ($path) { $source = $m.CSIsoImageSource }
    }
    if (-not $path) { return $original }
    Assert-CSWim $path
    $bytes = [int64](Get-Item -LiteralPath $path -Force -ErrorAction Stop).Length
    $extra = [int64]0
    foreach ($file in @(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -File -Force -ErrorAction Stop |
        Where-Object { $_.Name -ine 'Winre.wim' })) {
        $extra += [int64]$file.Length
    }
    $minimum = Align-UpMiB ([int64][math]::Max([double]$script:CSCreateMinimum,
        [double]($bytes + $extra + $script:CSNewNtfsAllowance +
            $script:CSFreeReserve + $script:CSFormatVariation)))
    return [pscustomobject]@{
        Found = $true; Verified = $true; Source = $source; WIMBytes = $bytes
        ExtraBytes = $extra; Existing = $null; UsedBytes = $null
        FreeBytes = $null; MinRecoveryBytes = $minimum; ImagePath = [string]$path; Error = ''
    }
}

# MBR missing-Recovery uses the *existing* geometry calculation and executor.
# No fabricated GPT disk and no weakening of the MBR-on-C migration rules.
function Get-CSMissingMBRPlan($disk, $c, $parts, $reInfo, $assessment, $volume, $bounds) {
    if (-not (Test-CSMissingMBRRecovery $disk $c $parts $reInfo) -or
        -not $assessment.Verified -or $null -ne $assessment.Existing -or
        $null -eq $assessment.MinRecoveryBytes -or $null -eq $volume -or
        [string]$volume.FileSystem -ne 'NTFS' -or
        [int64]$volume.Size -le 0 -or $null -eq $bounds) { return $null }
    $minimum = [int64]$assessment.MinRecoveryBytes
    $maxSize = [int64]($minimum + 512MB)
    $originalCSize = [int64]$c.Size
    $initial = Get-CSProposedGeometry $disk $c $parts $null $originalCSize $bounds $maxSize
    if ($null -eq $initial) { return $null }
    $newCSize = $originalCSize
    if ([int64]$initial.NewSize -lt $minimum) {
        $targetEnd = Align-DownMiB ([int64]($initial.RightEnd - $maxSize))
        $newCSize = [int64]($targetEnd - [int64]$c.Offset)
        if ($newCSize -le 0 -or $newCSize -ge $originalCSize) { return $null }
    }
    $geometry = Get-CSProposedGeometry $disk $c $parts $null $newCSize $bounds $maxSize
    if ($null -eq $geometry -or -not $geometry.IsGeometryPossible -or
        [int64]$geometry.NewSize -lt $minimum) { return $null }
    return [pscustomobject]@{
        TargetExplorerGiB = [int64][math]::Floor(
            ([double]$volume.Size + $newCSize - $originalCSize) / $script:GiB)
        TargetPartitionBytes = $newCSize
        CurrentVolumeBytes = [int64]$volume.Size
        ChangeBytes = [int64]($newCSize - $originalCSize)
        OriginalPartitionBytes = $originalCSize
        Beauty = $false
        MustRepair = $true
        MinimumRecoveryBytes = $minimum
        ImageSourcePath = [string]$assessment.ImagePath
        MigratingWinREOnC = $false
        MissingMBR = $true
        Geometry = $geometry
    }
}


# Small, *inactive* Recovery: prefer extending into free space on the right.
# If that cannot satisfy the minimum, plan a rebuild using space from C:.
# A data partition between C: and the old Recovery is NEVER moved: a new
# Recovery can be created after a shrink of C:, leaving the old one untouched.
# Planning is strictly read-only, including Get-PartitionSupportedSize.
function Get-CSInactiveSmallRecoveryPlan($disk, $c, $parts, $reInfo, $candidate, $assessment, $bounds) {
    if ($null -eq $candidate -or $null -eq $assessment -or
        -not $assessment.Verified -or $null -eq $assessment.Existing -or
        [int]$assessment.Existing.DiskNumber -ne [int]$disk.Number -or
        [int]$assessment.Existing.PartitionNumber -ne [int]$candidate.PartitionNumber -or
        $null -eq $assessment.MinRecoveryBytes -or
        [string]$disk.PartitionStyle -notin @('GPT','MBR') -or
        $null -eq $bounds -or $reInfo.Enabled -or
        [int]$candidate.DiskNumber -ne [int]$disk.Number -or
        [int64]$candidate.Offset -lt (Get-PartitionEnd $c)) { return $null }
    if (Test-CSInactiveRecoveryReady $disk $candidate $assessment) { return $null }
    if ($disk.IsOffline -or $disk.IsReadOnly -or -not $disk.IsBoot -or
        $candidate.IsSystem -or $candidate.IsBoot -or $candidate.IsActive -or
        $candidate.DriveLetter) { return $null }
    $volume = Get-Volume -DriveLetter C -ErrorAction Stop
    if ([string]$volume.FileSystem -ne 'NTFS') { return $null }
    if ([string]$disk.PartitionStyle -eq 'GPT') {
        if ((Get-GptId $c) -ne 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7') { return $null }
    } elseif ([string]$c.Type -ne 'IFS' -or [int64]$disk.Size -ge 2TB) { return $null }

    $minimum = Align-UpMiB ([int64][math]::Max(
        [double]$script:CSCreateMinimum, [double]$assessment.MinRecoveryBytes))
    $preferred = Align-UpMiB ([int64]($minimum + 512MB))
    $end = Get-PartitionEnd $candidate
    $right = @($parts | Where-Object {
        [int]$_.PartitionNumber -ne [int]$candidate.PartitionNumber -and
        [int64]$_.Offset -ge $end
    } | Sort-Object Offset)
    $rightLimit = if ($right.Count -gt 0) { [int64]$right[0].Offset } else { [int64]$bounds.End }
    $rightLimit = [int64][math]::Min([double]$rightLimit, [double]$bounds.End)
    if ($rightLimit -lt $end) { return $null }
    $rightCapacity = Align-DownMiB ([int64]($rightLimit - [int64]$candidate.Offset))
    # Avoid an unnecessary change to C: whenever right-side space is enough.
    if ($rightCapacity -ge $minimum -and $rightCapacity -gt [int64]$candidate.Size) {
        $rightSize = [int64][math]::Min([double]$preferred, [double]$rightCapacity)
        return [pscustomobject]@{
            Mode = 'Right'; TargetPartitionBytes = [int64]$c.Size
            ChangeBytes = [int64]0; NewStart = [int64]$candidate.Offset
            NewSize = $rightSize; MinimumRecoveryBytes = $minimum
            OldNumber = [int]$candidate.PartitionNumber; KeepOld = $false
            RightEnd = $rightLimit
        }
    }

    # Shrinking C: does not touch the next partition. Only very simple
    # topologies are eligible, with an image verified on this physical disk.
    $between = @($parts | Where-Object {
        [int]$_.PartitionNumber -ne [int]$c.PartitionNumber -and
        [int]$_.PartitionNumber -ne [int]$candidate.PartitionNumber -and
        [int64]$_.Offset -ge (Get-PartitionEnd $c) -and
        [int64]$_.Offset -lt [int64]$candidate.Offset
    } | Sort-Object Offset)
    $mode = ''
    $boundary = [int64]0
    if ($between.Count -eq 0) {
        $mode = 'Adjacent'
        $boundary = $rightLimit
    } elseif ($between.Count -eq 1 -and
        [string]$between[0].DriveLetter -eq 'D' -and
        -not $between[0].IsBoot -and -not $between[0].IsSystem -and
        -not $between[0].IsActive -and
        [string]$between[0].Type -notmatch '(?i)Extended|Logical|Unknown|OEM') {
        $mode = 'BeforeD'
        $boundary = [int64]$between[0].Offset
    } else { return $null }
    if ($mode -eq 'BeforeD' -and [string]$disk.PartitionStyle -eq 'MBR') {
        if ($parts.Count -ge 4 -or @($parts | Where-Object {
            [string]$_.Type -match '(?i)Extended|Logical|Unknown' -and
            -not (Test-RecoveryPartition $_ 'MBR')
        }).Count -gt 0) { return $null }
    }
    if ($mode -eq 'Adjacent' -and [string]$disk.PartitionStyle -eq 'MBR' -and
        @($parts | Where-Object {
            [string]$_.Type -match '(?i)Extended|Logical|Unknown' -and
            -not (Test-RecoveryPartition $_ 'MBR')
        }).Count -gt 0) { return $null }
    $supported = try {
        Get-PartitionSupportedSize -DiskNumber ([int]$disk.Number) `
            -PartitionNumber ([int]$c.PartitionNumber) -ErrorAction Stop
    } catch { return $null }
    # Reserve a MiB so NTFS/partition rounding cannot undercut SizeMin.
    $smallestC = Align-UpMiB ([int64]$supported.SizeMin + 1MB)
    if ($smallestC -gt [int64]$c.Size) { return $null }
    $maximumCapacity = [int64]($boundary - (Align-UpMiB ([int64]$c.Offset + $smallestC)))
    if ($maximumCapacity -lt $minimum) { return $null }
    $targetSize = Align-DownMiB ([int64][math]::Min([double]$preferred, [double]$maximumCapacity))
    $targetC = Align-DownMiB ([int64]($boundary - $targetSize - [int64]$c.Offset))
    if ($targetC -gt [int64]$c.Size) { $targetC = [int64]$c.Size }
    if ($targetC -lt $smallestC) { $targetC = $smallestC }
    $newStart = Align-UpMiB ([int64]$c.Offset + $targetC)
    $newSize = [int64]($boundary - $newStart)
    if ($newSize -gt $preferred) { $newSize = $preferred }
    $newSize = Align-DownMiB $newSize
    if ($newSize -lt $minimum -or $targetC -le 0 -or
        $targetC -gt [int64]$c.Size -or
        [int64]$newStart + $newSize -gt $boundary) { return $null }
    return [pscustomobject]@{
        Mode = $mode; TargetPartitionBytes = $targetC
        ChangeBytes = [int64]($targetC - [int64]$c.Size)
        NewStart = $newStart; NewSize = $newSize
        MinimumRecoveryBytes = $minimum
        OldNumber = [int]$candidate.PartitionNumber
        KeepOld = [bool]($mode -eq 'BeforeD')
        RightEnd = $boundary
    }
}
