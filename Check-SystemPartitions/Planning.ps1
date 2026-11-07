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
        FreeBytes = $null; MinRecoveryBytes = $null; Error = ''
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
                                [math]::Max(0, [int64]$candidate.Size - [int64]$volume.Size) +
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
        if ($null -eq $path) {
            if ($mountOpened) {
                Close-CSRecoveryMount ([int]$disk.Number)
                $mountOpened = $false
            }
            $local = Join-Path $env:windir 'System32\Recovery\Winre.wim'
            if ([IO.File]::Exists($local)) {
                $path = $local
                $out.Source = $m.CS26SourceLocal
                # No measured source-volume usage is applicable for a newly
                # created Recovery: use the from-scratch policy instead.
                $out.Existing = $null
                $out.UsedBytes = $null
                $out.FreeBytes = $null
                $out.MinRecoveryBytes = $null
            }
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

function Get-CSProposedGeometry($disk, $c, $parts, $activeRecovery, [int64]$newCSize, $bounds) {
    if ($null -ne $activeRecovery) {
        return Get-RebuildPreview $disk $c $parts $activeRecovery $newCSize
    }
    # READ-ONLY new-Recovery layout proposal: the executor does not support it.
    $cEnd = [int64]$c.Offset + $newCSize
    $next = @($parts | Where-Object {
        [int]$_.PartitionNumber -ne [int]$c.PartitionNumber -and
        [int64]$_.Offset -ge (Get-PartitionEnd $c)
    } | Sort-Object Offset)
    $rightEnd = if ($next.Count -gt 0) { [int64]$next[0].Offset }
                elseif ($null -ne $bounds) { [int64]$bounds.End }
                else { return $null }
    $start = Align-UpMiB $cEnd
    if ($rightEnd -le $start) { return $null }
    return [pscustomobject]@{
        OldNumber = 0; OldSize = [int64]0; NewStart = [int64]$start
        NewSize = [int64]($rightEnd - $start)
        AbsorbedGapBytes = [int64]0; IsGeometryPossible = $true
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
    if ([string]$disk.PartitionStyle -ne 'GPT') { return $null }
    $originalCSize = [int64]$c.Size
    $minRecovery = [int64]$assessment.MinRecoveryBytes
    $fsBytes = [int64]$volume.Size
    $fsDelta = [int64][math]::Max(0, $originalCSize - $fsBytes)
    $originalGeo = Get-CSProposedGeometry $disk $c $parts $activeRecovery $originalCSize $bounds
    if ($null -eq $originalGeo) { return $null }
    $rightEnd = [int64]$originalGeo.NewStart + [int64]$originalGeo.NewSize

    # First decide if Windows RE needs repair or more space (independent of C:
    # aesthetics). When recovery is healthy, preserve C: unless beauty is cheap.
    $mustRepair = (-not $reInfo.Enabled -or $null -eq $activeRecovery -or
        ($null -ne $assessment.FreeBytes -and
         [int64]$assessment.FreeBytes -lt $script:CSFreeReserve))
    $baseC = $originalCSize
    if ($mustRepair -and [int64]$originalGeo.NewSize -lt $minRecovery) {
        $maxEnd = Align-DownMiB ([int64]($rightEnd - $minRecovery))
        $baseC = [int64]($maxEnd - [int64]$c.Offset)
        if ($baseC -le 0) { return $null }
    }
    $baseGeo = Get-CSProposedGeometry $disk $c $parts $activeRecovery $baseC $bounds
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
        if ($number -le 0) { continue }
        $goalFS = [int64]($number * $script:GiB)
        $desiredEnd = Align-UpMiB ([int64]($c.Offset + $goalFS + $fsDelta))
        $size = [int64]($desiredEnd - [int64]$c.Offset)
        # Don't propose a cosmetic rebuild for an already-beautiful capacity.
        if (-not $mustRepair -and
            [int64][math]::Floor($fsBytes / [double]$script:GiB) -eq $number) { continue }
        if ([math]::Abs([double]($size - $baseC)) -gt $script:CSCosmeticLimit) { continue }
        $candidateGeo = Get-CSProposedGeometry $disk $c $parts $activeRecovery $size $bounds
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
    $geo = Get-CSProposedGeometry $disk $c $parts $activeRecovery $chosenC $bounds
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
        Geometry = $geo
    }
}
