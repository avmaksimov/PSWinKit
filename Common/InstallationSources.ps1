#requires -Version 5.1
# Shared Windows installation source helpers for Check-Windows and Check-SystemPartitions.
# Import does not access disks, mount images, or modify files.

function Get-PSWinKitInstallationImageAtRoot {
    param([Parameter(Mandatory=$true)][string]$Root)
    foreach ($relative in @('sources\install.wim', 'sources\install.esd',
                            'sources\install.swm', 'install.wim',
                            'install.esd', 'install.swm')) {
        $path = Join-Path $Root $relative
        if ([IO.File]::Exists($path)) { return $path }
    }
    return $null
}

function Get-PSWinKitSplitWimPattern {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][hashtable]$Messages
    )

    $sourceFile = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    if ($sourceFile.PSIsContainer -or $sourceFile.Name -ine 'install.swm') {
        throw ($Messages.InstallSourceFirstSWM -f $Source)
    }
    $folder = $sourceFile.DirectoryName
    $allParts = @(Get-ChildItem -LiteralPath $folder -Filter 'install*.swm' -File -ErrorAction Stop)
    $numbered = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($part in $allParts) {
        $number = 0
        if ($part.Name -ieq 'install.swm') {
            $number = 1
        } elseif ($part.Name -match '(?i)^install([2-9]|[1-9][0-9]+)\.swm$') {
            $number = [int]$Matches[1]
        } else {
            throw ($Messages.InstallSourceUnexpectedSWM -f $part.FullName)
        }
        if (-not $numbered.Add($number)) {
            throw ($Messages.InstallSourceDuplicateSWM -f $number)
        }
    }
    if ($numbered.Count -eq 0 -or -not $numbered.Contains(1)) {
        throw ($Messages.InstallSourceFirstSWM -f $Source)
    }
    $max = [int](($numbered | Measure-Object -Maximum).Maximum)
    for ($i=1; $i -le $max; $i++) {
        if (-not $numbered.Contains($i)) {
            throw ($Messages.InstallSourceMissingSWM -f ('install{0}.swm' -f $i))
        }
    }
    return (Join-Path $folder 'install*.swm')
}

function Get-PSWinKitMountedISOOrigin {
    param([Parameter(Mandatory=$true)][string]$Letter)

    $drive = $Letter.Trim().TrimEnd(':').ToUpperInvariant()
    if ($drive -notmatch '^[A-Z]$') { return $null }
    # CDROM numbers, unlike Win32_CDROMDrive.DeviceID, are valid Get-DiskImage
    # device paths. Check the volume, not the order of CDROM enumeration.
    for ($i=0; $i -lt 64; $i++) {
        try {
            $image = Get-DiskImage -DevicePath ("\\.\CDROM{0}" -f $i) -ErrorAction Stop
            if (-not $image.Attached -or
                [string]$image.ImagePath -notmatch '(?i)\.iso$' -or
                -not [IO.File]::Exists([string]$image.ImagePath)) { continue }
            foreach ($volume in @($image | Get-Volume -ErrorAction Stop)) {
                if ([string]$volume.DriveLetter -ieq $drive) {
                    return [string]$image.ImagePath
                }
            }
        } catch { }
    }
    return $null
}

function Mount-PSWinKitInstallationISO {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][hashtable]$Messages
    )

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    if ([IO.Path]::GetExtension($resolved) -ine '.iso' -or -not [IO.File]::Exists($resolved)) {
        throw ($Messages.InstallSourceISOUnavailable -f $Path)
    }
    $image = Get-DiskImage -ImagePath $resolved -ErrorAction Stop
    if (-not $image.Attached) {
        Write-Host ($Messages.InstallSourceMountingISO -f $resolved) -ForegroundColor Gray
        $image = Mount-DiskImage -ImagePath $resolved -PassThru -ErrorAction Stop
    }
    $sources = @()
    foreach ($volume in @($image | Get-Volume -ErrorAction Stop)) {
        if (-not $volume.DriveLetter) { continue }
        $source = Get-PSWinKitInstallationImageAtRoot (
            ([string]$volume.DriveLetter) + ':\')
        if ($source) { $sources += $source }
    }
    if ($sources.Count -ne 1) {
        throw ($Messages.InstallSourceISOImageCount -f $resolved)
    }
    return [pscustomobject]@{ Source = [string]$sources[0]; ISOPath = $resolved }
}
