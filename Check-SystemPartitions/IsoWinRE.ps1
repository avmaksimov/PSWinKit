#Requires -Version 5.1
# Internal, read-only ISO source loader for missing Recovery creation.
# Staged Windows images live on C:; none of these functions changes partitions.

$script:CSISOStageDir = $null
$script:CSISOImagePath = $null
$script:CSISOMounted = $false

function Get-CSNormalizedArchitecture([string]$value) {
    switch -Regex ($value.Trim()) {
        '^(9|x64|AMD64)$' { return 'x64' }
        '^(12|ARM64)$' { return 'ARM64' }
        '^(0|x86|I386)$' { return 'x86' }
        default { return $value.Trim().ToUpperInvariant() }
    }
}

function Test-CSSharedWindows11Core([int]$installed, [int]$image) {
    return ($installed -in @(26100,26200,26300) -and
        $image -in @(26100,26200,26300))
}

function Select-CSISOImageIndex([string]$path) {
    Import-Module Dism -ErrorAction Stop
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $edition = [string]$cv.EditionID
    $build = [int]$cv.CurrentBuildNumber
    $installationType = [string]$cv.InstallationType
    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
    $architecture = Get-CSNormalizedArchitecture ([string]$cpu.Architecture)
    if ($architecture -notin @('x64','ARM64','x86')) {
        throw ($m.CSIsoUnsupportedArchitecture -f $architecture)
    }

    # Shared 26100/26200/26300 servicing-core matching is CLIENT ONLY.
    # A Windows Server 2025 ISO must match the installed server build exactly.
    $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $isClient = ([int]$osInfo.ProductType -eq 1)
    $catalog = @(Get-WindowsImage -ImagePath $path -ErrorAction Stop)
    if ($catalog.Count -eq 0) { throw $m.CSIsoEmptyCatalog }
    $rows = @()
    $matches = @()
    foreach ($item in $catalog) {
        $d = Get-WindowsImage -ImagePath $path -Index ([int]$item.ImageIndex) -ErrorAction Stop
        $ed = [string]$d.EditionId
        $ar = Get-CSNormalizedArchitecture ([string]$d.Architecture)
        $ib = [int]([version]$d.Version).Build
        $exact = $ib -eq $build
        $shared = ($isClient -and (Test-CSSharedWindows11Core $build $ib))
        $rows += [pscustomobject]@{
            Index = [int]$d.ImageIndex; Edition = $ed; Build = $ib
            Architecture = $ar; Name = [string]$d.ImageName
        }
        if ($ed -ieq $edition -and $ar -ieq $architecture -and ($exact -or $shared)) {
            $matches += [pscustomobject]@{
                Index = [int]$d.ImageIndex; Build = $ib; Exact = $exact
                Name = [string]$d.ImageName
            }
        }
    }
    Write-Host ''
    Write-Host $m.CSIsoCatalogTitle -ForegroundColor Gray
    $rows | Sort-Object Index | Format-Table `
        @{Label=$m.CSIsoColumnIndex;Expression={$_.Index}}, `
        @{Label=$m.CSIsoColumnEdition;Expression={$_.Edition}}, `
        @{Label=$m.CSIsoColumnBuild;Expression={$_.Build}}, `
        @{Label=$m.CSIsoColumnArch;Expression={$_.Architecture}}, `
        @{Label=$m.CSIsoColumnName;Expression={$_.Name}} -AutoSize | Out-Host
    # Exact build wins over compatible Windows 11 shared-core images.
    $preferredMatches = @($matches | Where-Object { $_.Exact })
    if ($preferredMatches.Count -eq 0) {
        $preferredMatches = @($matches | Where-Object { -not $_.Exact })
    }
    $chosen = $null
    if ($preferredMatches.Count -eq 1) {
        $chosen = $preferredMatches[0]
    } elseif (-not $isClient -and $preferredMatches.Count -eq 2 -and
        $installationType -in @('Server', 'Server Core')) {
        # Windows Server ISO typically contains Core and Desktop Experience
        # with identical EditionId, build and architecture. A pair can be
        # distinguished only if precisely ONE image is explicitly named as
        # Desktop Experience. Never rely on a hard-coded index or image order.
        # The Russian name occurs on localized Windows Server 2019 media.
        $desktop = @($preferredMatches | Where-Object {
            $_.Name -match '(?i:Desktop Experience|возможности рабочего стола)'
        })
        if ($desktop.Count -eq 1) {
            if ($installationType -eq 'Server') {
                $chosen = $desktop[0]
            } else {
                $other = @($preferredMatches | Where-Object {
                    $_.Index -ne $desktop[0].Index
                })
                if ($other.Count -eq 1) { $chosen = $other[0] }
            }
        }
    }
    if ($null -eq $chosen) {
        # Fail closed for unfamiliar / ambiguous server ISO naming.
        throw ($m.CSIsoNoUniqueMatch -f $edition, $build, $architecture)
    }
    Write-Host ($m.CSIsoSelected -f $chosen.Index, $edition, $chosen.Build, $architecture) -ForegroundColor Green
    if (-not $chosen.Exact) {
        Write-Host ($m.CSIsoBuildWarning -f $chosen.Build, $build) -ForegroundColor Yellow
    }
    return [int]$chosen.Index
}

function Get-CSSevenZipPath {
    $base = if ([Environment]::Is64BitOperatingSystem) { $env:ProgramW6432 }
            else { $env:ProgramFiles }
    if (-not $base) { return $null }
    $path = Join-Path $base '7-Zip\7z.exe'
    if ([IO.File]::Exists($path)) { return $path }
    return $null
}

function Get-CSInstallationSource([string]$letter) {
    # The first SWM part has no numeric suffix; later parts are install2.swm, etc.
    foreach ($name in @('sources\install.wim', 'sources\install.esd', 'sources\install.swm')) {
        $candidate = "$letter`:\$name"
        if ([IO.File]::Exists($candidate)) { return $candidate }
    }
    return $null
}

function Get-CSSplitWimPattern([string]$source) {
    # DISM requires all split parts in the same directory.
    $folder = Split-Path -Path $source -Parent
    $parts = @(Get-ChildItem -LiteralPath $folder -Filter 'install*.swm' -File -ErrorAction Stop |
        Where-Object { $_.Name -match '(?i)^install(?:[2-9]|[1-9][0-9]+)?\.swm$' })
    if ($parts.Count -eq 0 -or -not [IO.File]::Exists($source)) {
        throw $m.CSIsoSplitMissingSource
    }
    $numbers = @($parts | ForEach-Object {
        if ($_.Name -ieq 'install.swm') { 1 }
        else { [int]([regex]::Match($_.Name, '(?i)^install([0-9]+)\.swm$').Groups[1].Value) }
    })
    $max = [int](($numbers | Measure-Object -Maximum).Maximum)
    for ($n = 2; $n -le $max; $n++) {
        if ($numbers -notcontains $n) {
            throw ($m.CSIsoSplitMissingPart -f $n)
        }
    }
    return (Join-Path $folder 'install*.swm')
}

function Get-CSMountedInstallationImages {
    # Win32_CDROMDrive also sees installation ISOs attached by the hypervisor.
    # Get-DiskImage alone does NOT identify a host-mounted virtual DVD in a guest.
    $images = New-Object 'System.Collections.Generic.List[object]'
    try {
        $drives = @(Get-CimInstance -ClassName Win32_CDROMDrive -ErrorAction Stop)
    } catch {
        # Discovery is optional: retain the manual drive-letter fallback.
        return @()
    }
    foreach ($drive in $drives) {
        $letter = ([string]$drive.Drive).Trim().TrimEnd(':').ToUpperInvariant()
        if ($letter -notmatch '^[A-Z]$') { continue }

        # A CD/DVD device is not sufficient: it must contain Windows setup media.
        $source = Get-CSInstallationSource $letter
        if (-not $source) { continue }

        # Native mounted ISO: prefer its filename. Hyper-V guest virtual DVDs
        # may expose only a volume label, so use that if Get-DiskImage fails.
        $label = ''
        try {
            $diskImage = Get-DiskImage -DevicePath ([string]$drive.DeviceID) -ErrorAction Stop
            if ($diskImage.Attached -and ([string]$diskImage.ImagePath) -match '(?i)\.iso$') {
                $label = [IO.Path]::GetFileName([string]$diskImage.ImagePath)
            }
        } catch { }
        if (-not $label) {
            try {
                $volume = Get-Volume -DriveLetter ([char]$letter) -ErrorAction Stop
                $label = [string]$volume.FileSystemLabel
            } catch { }
        }
        if (-not $label) { $label = [string]$drive.Name }

        $images.Add([pscustomobject]@{
            Letter = $letter; Name = $label; Source = $source
        })
    }
    return @($images.ToArray() | Sort-Object Letter)
}

function Get-CSISOImage {
    if ($script:CSISOImagePath -and [IO.File]::Exists($script:CSISOImagePath)) {
        return $script:CSISOImagePath
    }

    $mounted = @(Get-CSMountedInstallationImages)
    $source = $null
    if ($mounted.Count -eq 1) {
        # One installation ISO/DVD: no drive selection is needed.
        $source = $mounted[0].Source
    } elseif ($mounted.Count -gt 1) {
        # Choose the installation medium first; only then inspect its indexes.
        Write-Host ''
        Write-Host ($m.CSIsoInstallFile -f '') -ForegroundColor Gray
        for ($i = 0; $i -lt $mounted.Count; $i++) {
            Write-Host ('  [{0}] {1}:  {2}' -f ($i + 1), $mounted[$i].Letter, $mounted[$i].Name)
        }
        do {
            $selection = (Read-Host ('{0} (1-{1})' -f $m.CSIsoColumnIndex, $mounted.Count)).Trim()
            if (-not $selection) { return $null }
            $number = 0
            $valid = [int]::TryParse($selection, [ref]$number) -and
                $number -ge 1 -and $number -le $mounted.Count
        } while (-not $valid)
        $source = $mounted[$number - 1].Source
    } else {
        # No mounted Windows installation media: keep manual input available.
        Write-Host $m.CSIsoNeeded -ForegroundColor Yellow
        $letter = (Read-Host $m.CSIsoLetterPrompt).Trim().TrimEnd(':').ToUpperInvariant()
        if (-not $letter) { return $null }
        if ($letter -notmatch '^[A-Z]$') { throw $m.CSIsoInvalidLetter }
        $source = Get-CSInstallationSource $letter
        if (-not $source) { throw ($m.CSIsoInstallMissing -f $letter) }
    }
    Write-Host ($m.CSIsoInstallFile -f $source)
    $extension = [IO.Path]::GetExtension($source).ToLowerInvariant()
    $swmPattern = $null
    if ($extension -eq '.swm') {
        $swmPattern = Get-CSSplitWimPattern $source
    }
    $index = Select-CSISOImageIndex $source

    $base = Join-Path $env:ProgramData 'PSWinKit\Check-SystemPartitions'
    [void](New-Item -Path $base -ItemType Directory -Force -ErrorAction Stop)
    $script:CSISOStageDir = Join-Path $base ('Stage-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -Path $script:CSISOStageDir -ItemType Directory -ErrorAction Stop)
    Protect-CSStagingDirectory $script:CSISOStageDir
    $wimDirectory = Join-Path $script:CSISOStageDir 'Source'
    [void](New-Item -Path $wimDirectory -ItemType Directory -ErrorAction Stop)
    $destination = Join-Path $wimDirectory 'Winre.wim'

    $zip = Get-CSSevenZipPath
    if ($zip) {
        $entry = ('{0}\Windows\System32\Recovery\Winre.wim' -f $index)
        Write-Host $m.CSIsoTrying7Zip -ForegroundColor DarkGray
        try {
            # Native stdout is NOT part of the function result.
            # Only the final verified Winre.wim path may enter the pipeline.
            & $zip 'e' $source $entry ("-o$wimDirectory") '-y' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw ($m.CSIsoExternalFailed -f '7-Zip', $LASTEXITCODE) }
            Assert-CSWim $destination
        } catch {
            Write-Host ($m.CSIso7ZipFallback -f $_.Exception.Message) -ForegroundColor Yellow
            if ([IO.File]::Exists($destination)) {
                Remove-Item -LiteralPath $destination -Force -ErrorAction Stop
            }
        }
    }
    if (-not [IO.File]::Exists($destination)) {
        $free = [int64](Get-Volume -DriveLetter C -ErrorAction Stop).SizeRemaining
        # Exporting ESD or split SWM to a temporary single-index WIM may need
        # several GiB; ordinary WIM can be mounted in place instead.
        $need = if ($extension -in @('.esd', '.swm')) { [int64](9GB) } else { [int64](2GB) }
        if ($free -lt $need) { throw ($m.CSIsoSpaceRequired -f (Format-PartitionSize $need)) }
        $image = $source
        if ($extension -in @('.esd', '.swm')) {
            $image = Join-Path $script:CSISOStageDir 'Install-Selected.wim'
            $exportArgs = @('/English', '/Export-Image', "/SourceImageFile:$source",
                "/SourceIndex:$index", "/DestinationImageFile:$image", '/CheckIntegrity')
            if ($extension -eq '.swm') {
                Write-Host $m.CSIsoExportingSWM -ForegroundColor DarkGray
                # A split WIM cannot be mounted as-is; DISM can export the
                # selected index when supplied with all the SWM parts.
                $exportArgs += "/SWMFile:$swmPattern"
            } else {
                Write-Host $m.CSIsoExportingESD -ForegroundColor DarkGray
                $exportArgs += '/Compress:max'
            }
            Invoke-CSExternal 'dism.exe' $exportArgs | Out-Null
            $index = 1
        }
        $mount = Join-Path $script:CSISOStageDir 'Mount'
        [void](New-Item -Path $mount -ItemType Directory -ErrorAction Stop)
        Write-Host $m.CSIsoMounting -ForegroundColor DarkGray
        $script:CSISOMounted = $true  # conservative until a successful unmount
        try {
            Invoke-CSExternal 'dism.exe' @('/English','/Mount-Image',
                "/ImageFile:$image", "/Index:$index", "/MountDir:$mount", '/ReadOnly') | Out-Null
            $inside = Join-Path $mount 'Windows\System32\Recovery\Winre.wim'
            if (-not [IO.File]::Exists($inside)) { throw $m.CSIsoWinreMissing }
            Copy-Item -LiteralPath $inside -Destination $destination -Force -ErrorAction Stop
        } finally {
            Write-Host $m.CSIsoUnmounting -ForegroundColor DarkGray
            & dism.exe /English /Unmount-Image "/MountDir:$mount" /Discard | Out-Null
            if ($LASTEXITCODE -eq 0) { $script:CSISOMounted = $false }
            else { throw $m.CSIsoUnmountFailed }
        }
        if ($image -ne $source -and [IO.File]::Exists($image)) {
            Remove-Item -LiteralPath $image -Force -ErrorAction Stop
        }
    }
    Assert-CSWim $destination
    $script:CSISOImagePath = $destination
    Write-Host ($m.CSIsoReady -f (Format-DetailedSize ([int64](Get-Item -LiteralPath $destination -Force).Length))) -ForegroundColor Green
    return $destination
}

function Clear-CSISOStage {
    if (-not $script:CSISOStageDir) { return }
    if ($script:CSISOMounted -or ($script:CSExecMutated -and -not $script:CSExecLastSucceeded)) {
        Write-Warning ($m.CSIsoStageRetained -f $script:CSISOStageDir)
        return
    }
    if (Test-Path -LiteralPath $script:CSISOStageDir -PathType Container) {
        try {
            if (-not (Test-CSStagingTreeSafe $script:CSISOStageDir)) {
                throw $m.CS27CleanupUnsafeRoot
            }
            Remove-Item -LiteralPath $script:CSISOStageDir -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Warning ($m.CSIsoCleanupFailed -f $script:CSISOStageDir, $_.Exception.Message)
        }
    }
    $script:CSISOImagePath = $null
    $script:CSISOStageDir = $null
}
