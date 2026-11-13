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
    $script:CSISOSelectedCatalogMetadata = @()
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
            InstallationType = [string]$d.InstallationType
            Language = [string](@($d.Languages) | Select-Object -First 1)
        }
        if ($ed -ieq $edition -and $ar -ieq $architecture -and ($exact -or $shared)) {
            $matches += [pscustomobject]@{
                Index = [int]$d.ImageIndex; Build = $ib; Exact = $exact
                Name = [string]$d.ImageName
            }
        }
    }
    $script:CSISOSelectedCatalogMetadata = @($rows | ForEach-Object {
        [pscustomobject]@{
            index = [int]$_.Index; name = [string]$_.Name
            editionId = [string]$_.Edition; build = [int]$_.Build
            architecture = [string]$_.Architecture
            installationType = [string]$_.InstallationType
            language = [string]$_.Language
        }
    })
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

# Common catalog is shared by Check-SystemPartitions and future Check-Windows.
# No local machine-specific cache is created.
. (Join-Path $PSScriptRoot '..\Common\ImageCatalog.ps1')

function Get-CSInstallationSourceAtRoot([string]$root) {
    foreach ($name in @('sources\install.wim', 'sources\install.esd', 'sources\install.swm')) {
        $candidate = Join-Path $root $name
        if ([IO.File]::Exists($candidate)) { return $candidate }
    }
    return $null
}

function Get-CSInstallationSource([string]$letter) {
    return (Get-CSInstallationSourceAtRoot ($letter.ToUpperInvariant() + ':\'))
}

function Get-CSSplitWimPattern([string]$source) {
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
        if ($numbers -notcontains $n) { throw ($m.CSIsoSplitMissingPart -f $n) }
    }
    return (Join-Path $folder 'install*.swm')
}

function Get-CSMountedISOOrigin([string]$letter) {
    try {
        $cd = @(Get-CimInstance Win32_CDROMDrive -ErrorAction Stop |
            Where-Object { ([string]$_.Drive).TrimEnd(':') -ieq $letter } |
            Select-Object -First 1)
        if ($cd.Count -ne 1) { return $null }
        $image = Get-DiskImage -DevicePath ([string]$cd[0].DeviceID) -ErrorAction Stop
        if ($image.Attached -and [string]$image.ImagePath -match '(?i)\.iso$' -and
            [IO.File]::Exists([string]$image.ImagePath)) {
            return [string]$image.ImagePath
        }
    } catch { }
    return $null
}

function Mount-CSInstallationISO([string]$path) {
    $full = (Resolve-Path -LiteralPath $path -ErrorAction Stop).ProviderPath
    if ([IO.Path]::GetExtension($full) -ine '.iso' -or -not [IO.File]::Exists($full)) {
        throw ($m.CSIsoInvalidPath -f $path)
    }
    $image = Get-DiskImage -ImagePath $full -ErrorAction Stop
    if (-not $image.Attached) {
        Write-Host ($m.CSIsoMountingFile -f $full) -ForegroundColor Gray
        $image = Mount-DiskImage -ImagePath $full -PassThru -ErrorAction Stop
    }
    $volumes = @($image | Get-Volume -ErrorAction Stop |
        Where-Object { $_.DriveLetter })
    $sources = @()
    foreach ($volume in $volumes) {
        $source = Get-CSInstallationSource ([string]$volume.DriveLetter)
        if ($source) { $sources += $source }
    }
    if ($sources.Count -ne 1) { throw ($m.CSIsoMountedInvalid -f $full) }
    return [pscustomobject]@{ Source = $sources[0]; ISOPath = $full }
}

function Get-CSCatalogMatchingISOs {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $edition = [string]$cv.EditionID
    $build = [int]$cv.CurrentBuildNumber
    $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
    $arch = Get-CSNormalizedArchitecture ([string]$cpu.Architecture)
    $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $isClient = ([int]$osInfo.ProductType -eq 1)
    $candidates = @()
    $catalog = @(Get-PSWinKitImageCatalogEntries)
    foreach ($invalidFile in @($script:PSWinKitImageCatalogReadErrors)) {
        Write-Warning ($m.CSIsoCatalogCorrupt -f $invalidFile)
    }
    foreach ($item in $catalog) {
        if ($item.host -and [string]$item.host -ine $env:COMPUTERNAME) { continue }
        if (-not [IO.File]::Exists([string]$item.path)) { continue }
        $fileInfo = [IO.FileInfo]::new([string]$item.path)
        if ([int64]$fileInfo.Length -ne [int64]$item.fileSize -or
            $fileInfo.LastWriteTimeUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture) -ne
                [string]$item.lastWriteUtc) { continue }
        $score = -1
        foreach ($index in @($item.indexes)) {
            if ($index.editionId -ine $edition -or
                (Get-CSNormalizedArchitecture ([string]$index.architecture)) -ine $arch) { continue }
            if ($isClient -and [string]$index.installationType -match '(?i)^Server') { continue }
            if (-not $isClient -and [string]$index.installationType -eq 'Client') { continue }
            if ([int]$index.build -eq $build) { $score = 2; break }
            if ($isClient -and (Test-CSSharedWindows11Core $build ([int]$index.build))) {
                $score = [math]::Max($score, 1)
            }
        }
        if ($score -ge 0) {
            $candidates += [pscustomobject]@{
                Path = [string]$item.path; Score = $score
                CheckedUtc = [string]$item.checkedUtc
            }
        }
    }
    return @($candidates | Sort-Object @{Expression='Score';Descending=$true},
        @{Expression='CheckedUtc';Descending=$true}, Path)
}

function Select-CSCatalogOrFoundSource([object[]]$candidates, [string]$heading) {
    if ($candidates.Count -eq 0) { return $null }
    if ($candidates.Count -eq 1) { return $candidates[0] }
    Write-Host ''
    Write-Host $heading -ForegroundColor Cyan
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $display = if ($candidates[$i].PSObject.Properties['Path']) {
            [string]$candidates[$i].Path
        } else { [string]$candidates[$i].Source }
        Write-Host ('  [{0}] {1}' -f ($i + 1), $display)
    }
    do {
        $answer = (Read-Host ($m.CSIsoChooseOption -f $candidates.Count)).Trim()
        if (-not $answer) { return $null }
        $number = [int]0
        $valid = [int]::TryParse($answer, [ref]$number) -and
            $number -ge 1 -and $number -le $candidates.Count
    } while (-not $valid)
    return $candidates[$number - 1]
}

function Find-CSInstallationSourcesInFolder([string]$folder) {
    # Explicit user request only. Avoid reparse points and infinite directory loops.
    $found = New-Object 'System.Collections.Generic.List[object]'
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push([IO.Path]::GetFullPath($folder))
    $scanned = 0
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        $scanned++
        if ($scanned -gt 20000) { throw $m.CSIsoSearchLimit }
        try {
            $di = [IO.DirectoryInfo]::new($directory)
            if (($di.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $source = Get-CSInstallationSourceAtRoot $directory
            if ($source) {
                $found.Add([pscustomobject]@{ Source=$source; ISOPath='' })
            }
            foreach ($file in $di.EnumerateFiles('*.iso', [IO.SearchOption]::TopDirectoryOnly)) {
                $found.Add([pscustomobject]@{ Source=''; ISOPath=$file.FullName })
                if ($found.Count -gt 250) { throw $m.CSIsoSearchLimit }
            }
            foreach ($child in $di.EnumerateDirectories()) {
                if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                    $pending.Push($child.FullName)
                }
            }
        } catch [System.UnauthorizedAccessException] { continue }
    }
    return @($found.ToArray())
}

function Resolve-CSUserInstallationSource([string]$inputText) {
    $entry = $inputText.Trim().Trim('"')
    if ($entry -match '^[A-Za-z]:?$') { $entry = $entry[0] + ':\' }
    try {
        $resolved = (Resolve-Path -LiteralPath $entry -ErrorAction Stop).ProviderPath
    } catch { throw ($m.CSIsoInvalidPath -f $inputText) }
    if ([IO.File]::Exists($resolved)) {
        if ([IO.Path]::GetExtension($resolved) -ine '.iso') {
            throw ($m.CSIsoInvalidPath -f $inputText)
        }
        return (Mount-CSInstallationISO $resolved)
    }
    if (-not [IO.Directory]::Exists($resolved)) { throw ($m.CSIsoInvalidPath -f $inputText) }
    $sources = @(Find-CSInstallationSourcesInFolder $resolved)
    if ($sources.Count -eq 0) { throw ($m.CSIsoNoFilesInFolder -f $resolved) }
    $picked = Select-CSCatalogOrFoundSource $sources $m.CSIsoFoundSources
    if ($null -eq $picked) { return $null }
    if ($picked.ISOPath) { return (Mount-CSInstallationISO $picked.ISOPath) }
    # If a user entered F / F: for a mounted ISO, remember the original ISO
    # path rather than the temporary drive letter. Physical DVDs stay transient.
    if ([string]$picked.Source -match '^([A-Za-z]):\') {
        $picked.ISOPath = Get-CSMountedISOOrigin $matches[1]
    }
    return $picked
}

function Get-CSSelectedInstallationSource {
    # 1. Saved ISO files from the shared Data catalog.
    $known = @()
    try { $known = @(Get-CSCatalogMatchingISOs) }
    catch { Write-Warning ($m.CSIsoCatalogReadFailed -f $_.Exception.Message) }
    if ($known.Count -gt 0) {
        $chosen = Select-CSCatalogOrFoundSource $known $m.CSIsoKnownSources
        if ($null -eq $chosen) { return $null }
        try {
            $mountedSource = Mount-CSInstallationISO $chosen.Path
            # Cache data is only a hint; validate the actual installation media.
            $mountedIndex = Select-CSISOImageIndex $mountedSource.Source
            $mountedSource | Add-Member -NotePropertyName VerifiedIndex -NotePropertyValue $mountedIndex
            return $mountedSource
        } catch { Write-Warning ($m.CSIsoKnownInvalid -f $_.Exception.Message) }
    }

    # 2. Already mounted installation media (including hypervisor virtual DVDs).
    $mounted = @(Get-CSMountedInstallationImages)
    if ($mounted.Count -gt 0) {
        $selected = Select-CSCatalogOrFoundSource $mounted $m.CSIsoMountedSources
        if ($null -eq $selected) { return $null }
        try {
            $mountedIndex = Select-CSISOImageIndex ([string]$selected.Source)
            return [pscustomobject]@{
                Source = [string]$selected.Source
                ISOPath = (Get-CSMountedISOOrigin ([string]$selected.Letter))
                VerifiedIndex = [int]$mountedIndex
            }
        } catch { Write-Warning ($m.CSIsoMountedMismatch -f $_.Exception.Message) }
    }

    # 3. User-provided drive, folder, ISO, UNC or relative path.
    Write-Host $m.CSIsoNeeded -ForegroundColor Yellow
    $answer = (Read-Host $m.CSIsoSourcePrompt).Trim()
    if (-not $answer) { return $null }
    return (Resolve-CSUserInstallationSource $answer)
}

function Get-CSMountedInstallationImages {
    $images = New-Object 'System.Collections.Generic.List[object]'
    try { $drives = @(Get-CimInstance Win32_CDROMDrive -ErrorAction Stop) }
    catch { return @() }
    foreach ($drive in $drives) {
        $letter = ([string]$drive.Drive).Trim().TrimEnd(':').ToUpperInvariant()
        if ($letter -notmatch '^[A-Z]$') { continue }
        $source = Get-CSInstallationSource $letter
        if (-not $source) { continue }
        $label = ''
        $origin = Get-CSMountedISOOrigin $letter
        if ($origin) { $label = [IO.Path]::GetFileName($origin) }
        if (-not $label) {
            try { $label = [string](Get-Volume -DriveLetter ([char]$letter) -ErrorAction Stop).FileSystemLabel }
            catch { }
        }
        if (-not $label) { $label = [string]$drive.Name }
        $images.Add([pscustomobject]@{ Letter=$letter; Name=$label; Source=$source })
    }
    return @($images.ToArray() | Sort-Object Letter)
}

function Get-CSISOImage {
    if ($script:CSISOImagePath -and [IO.File]::Exists($script:CSISOImagePath)) {
        return $script:CSISOImagePath
    }

    $selected = Get-CSSelectedInstallationSource
    if ($null -eq $selected) { return $null }
    $source = [string]$selected.Source
    $isoPath = [string]$selected.ISOPath
    Write-Host ($m.CSIsoInstallFile -f $source)
    # This performs the authoritative compatibility check, independent of the cache.
    $index = if ($selected.PSObject.Properties['VerifiedIndex']) {
        [int]$selected.VerifiedIndex
    } else { Select-CSISOImageIndex $source }
    # Save as soon as the source is validated, BEFORE extraction and disk changes.
    if ($isoPath -and [IO.File]::Exists($isoPath)) {
        try {
            Add-PSWinKitImageCatalogISO $isoPath @($script:CSISOSelectedCatalogMetadata)
            Write-Host $m.CSIsoCatalogSaved -ForegroundColor DarkGray
        } catch { Write-Warning ($m.CSIsoCatalogSaveFailed -f $_.Exception.Message) }
    }

    $base = Join-Path $env:ProgramData 'PSWinKit\Check-SystemPartitions'
    [void](New-Item -Path $base -ItemType Directory -Force -ErrorAction Stop)
    $script:CSISOStageDir = Join-Path $base ('Stage-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -Path $script:CSISOStageDir -ItemType Directory -ErrorAction Stop)
    Protect-CSStagingDirectory $script:CSISOStageDir
    $wimDirectory = Join-Path $script:CSISOStageDir 'Source'
    [void](New-Item -Path $wimDirectory -ItemType Directory -ErrorAction Stop)
    $destination = Join-Path $wimDirectory 'Winre.wim'

    $extension = [IO.Path]::GetExtension($source).ToLowerInvariant()
    $swmPattern = $null
    if ($extension -eq '.swm') { $swmPattern = Get-CSSplitWimPattern $source }
    $zip = Get-CSSevenZipPath
    if ($zip -and $extension -ne '.swm') {
        $entry = ('{0}\Windows\System32\Recovery\Winre.wim' -f $index)
        Write-Host $m.CSIsoTrying7Zip -ForegroundColor DarkGray
        try {
            & $zip 'e' $source $entry ("-o$wimDirectory") '-y' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw ($m.CSIsoExternalFailed -f '7-Zip', $LASTEXITCODE) }
            Assert-CSWim $destination
        } catch {
            Write-Host ($m.CSIso7ZipFallback -f $_.Exception.Message) -ForegroundColor Yellow
            if ([IO.File]::Exists($destination)) { Remove-Item -LiteralPath $destination -Force -ErrorAction Stop }
        }
    }
    if (-not [IO.File]::Exists($destination)) {
        $free = [int64](Get-Volume -DriveLetter C -ErrorAction Stop).SizeRemaining
        $need = if ($extension -in @('.esd', '.swm')) { [int64](9GB) } else { [int64](2GB) }
        if ($free -lt $need) { throw ($m.CSIsoSpaceRequired -f (Format-PartitionSize $need)) }
        $image = $source
        if ($extension -in @('.esd', '.swm')) {
            $image = Join-Path $script:CSISOStageDir 'Install-Selected.wim'
            $exportArgs = @('/English', '/Export-Image', "/SourceImageFile:$source",
                "/SourceIndex:$index", "/DestinationImageFile:$image", '/CheckIntegrity')
            if ($extension -eq '.swm') {
                Write-Host $m.CSIsoExportingSWM -ForegroundColor DarkGray
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
        $script:CSISOMounted = $true
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
    # Publication is already complete; merge fragments before staging cleanup.
    try { Merge-PSWinKitImageCatalog }
    catch { Write-Warning ($m.CSIsoCatalogMergeFailed -f $_.Exception.Message) }
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
