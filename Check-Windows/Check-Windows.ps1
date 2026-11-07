#requires -Version 5.1
<#
WinRepair: OS-aware Windows repair (Windows 7/Server 2008 R2 and newer).
- Windows client 8+: first try DISM with default source. Offer ISO/WIM/ESD on failure.
- Windows Server 2012+: ask for source immediately, but allow default source.
- Check the system volume and local volumes hosting known Windows folders before repair (Repair-Volume or CHKDSK).
- Windows 7 / Server 2008 R2 and earlier: no unsupported RestoreHealth; run SFC.
- Run SFC even if DISM fails. Offer a safe in-place Windows Setup from selected media on failure.
- Ctrl+C cancels the script.
- No WSUS policy changes, component cleanup or cache reset; reboot only with consent.
- Compatible with Windows PowerShell 2.0 (shipped with Windows 7).
#>
. (Join-Path $PSScriptRoot '..\Common\Common.ps1')
$utility = Start-Utility -ScriptPath $PSCommandPath -RequireAdministrator
if ($null -eq $utility) { return }
$script:RepairMessages = $utility.Messages


$script:DiskResult = $null
$script:SfcResult = $null
$script:VolumeStatus = $script:RepairMessages.NotChecked
$script:VolumeChecks = @()
$script:VolumeNeedsAttention = $false
$script:VolumeScheduled = $false
$script:RestartRequested = $false
$script:RestartInitiated = $false
$script:HadError = $false
$script:TranscriptOn = $false
$script:LogPath = $null
$script:SelectedRepairImage = $null
$script:SelectedRepairDetails = $null
$script:SelectedRepairIndex = 0
$script:SetupLaunched = $false
$script:ProgramDirectory = Join-Path $env:SystemRoot 'System32'
if (($env:PROCESSOR_ARCHITEW6432 -ne $null) -and ($env:PROCESSOR_ARCHITEW6432 -ne '')) {
    # Running 32-bit PowerShell on a 64-bit OS: use native system binaries.
    $script:ProgramDirectory = Join-Path $env:SystemRoot 'Sysnative'
}
$script:DismExe = Join-Path $script:ProgramDirectory 'dism.exe'
$script:SfcExe = Join-Path $script:ProgramDirectory 'sfc.exe'
$script:ChkdskExe = Join-Path $script:ProgramDirectory 'chkdsk.exe'
$script:ChkntfsExe = Join-Path $script:ProgramDirectory 'chkntfs.exe'

function Ask-YesNo {
    param([string]$Question, [bool]$DefaultYes)
    $defaultText = if ($DefaultYes) { 'Y' } else { 'N' }
    while ($true) {
        $answer = (Read-Host ("{0} [Y/N, Enter={1}]" -f $Question, $defaultText)).Trim().ToUpperInvariant()
        if ($answer.Length -eq 0) { return $DefaultYes }
        if (@('Д', 'ДА', 'Y', 'YES') -contains $answer) { return $true }
        if (@('Н', 'НЕТ', 'N', 'NO') -contains $answer) { return $false }
        Write-Host $script:RepairMessages.EnterYOrN -ForegroundColor Yellow
    }
}

function Format-ExitCode {
    param([int]$Code)
    return ('{0} (0x{1:X8})' -f $Code, ([BitConverter]::ToUInt32([BitConverter]::GetBytes($Code), 0)))
}

function Find-ImageAtPath {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    $value = $Path.Trim().Trim('"')
    if ($value -match '^[A-Za-z]:$') { $value = $value + '\' }
    if ($value -match '^[A-Za-z]$') { $value = $value + ':\' }
    if (-not (Test-Path -LiteralPath $value)) { return $null }
    $item = Get-Item -LiteralPath $value -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        if ($item.Extension -match '^\.(wim|esd)$') { return $item.FullName }
        return $null
    }
    foreach ($relative in @('sources\install.wim', 'sources\install.esd', 'install.wim', 'install.esd')) {
        $candidate = Join-Path $item.FullName $relative
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Find-ImagesOnDrives {
    # Search only conventional ISO roots, not a costly recursive scan of disks.
    $found = @()
    $checked = @()
    try {
        $drives = @(Get-WmiObject -Class Win32_LogicalDisk -ErrorAction Stop |
            Where-Object { @('2','3','4','5') -contains ([string]$_.DriveType) } |
            Sort-Object DeviceID)
    } catch {
        $drives = @()
        foreach ($disk in [IO.DriveInfo]::GetDrives()) {
            if ($disk.DriveType -ne [IO.DriveType]::Unknown) {
                $drives += (New-Object PSObject -Property @{ DeviceID = $disk.Name.TrimEnd('\'); DriveType = [string][int]$disk.DriveType })
            }
        }
    }
    foreach ($drive in $drives) {
        $root = [string]$drive.DeviceID
        if ($root -notmatch '^[A-Za-z]:$') { continue }
        $checked += $root
        $file = $null
        try { $file = Find-ImageAtPath $root } catch { }
        if (($file -ne $null) -and (-not ($found -contains $file))) { $found += $file }
    }
    Write-Host ($script:RepairMessages.CheckedDrives + $(if ($checked.Count -gt 0) { $checked -join ', ' } else { $script:RepairMessages.UnableToListDrives }))
    Write-Host $script:RepairMessages.OnlySourcesInstallWim
    return $found
}

function Choose-Image {
    param([switch]$AskForDrive)
    # After failed DISM without ISO, ask for the mounted drive directly.
    # For other scenarios, retain the existing automatic image discovery.
    if (-not $AskForDrive) {
        Write-Host ''
        Write-Host $script:RepairMessages.SearchingAvailableDrivesFor -ForegroundColor Cyan
        $found = @(Find-ImagesOnDrives)
        if ($found.Count -eq 1) {
            Write-Host ($script:RepairMessages.FoundOneImage + $found[0]) -ForegroundColor Green
            Write-Host $script:RepairMessages.UsingTheDetectedImage
            return [string]$found[0]
        }
        if ($found.Count -gt 1) {
            Write-Host $script:RepairMessages.MultipleImagesFound -ForegroundColor Cyan
            for ($i = 0; $i -lt $found.Count; $i++) {
                Write-Host (' {0}. {1}' -f ($i + 1), $found[$i])
            }
            while ($true) {
                $answer = (Read-Host $script:RepairMessages.ImageNumberEnterSpecify).Trim()
                if ($answer -eq '') { break }
                $selected = 0
                if ([int]::TryParse($answer, [ref]$selected) -and $selected -gt 0 -and $selected -le $found.Count) {
                    return [string]$found[$selected - 1]
                }
                Write-Host $script:RepairMessages.InvalidNumber -ForegroundColor Yellow
            }
        } else {
            Write-Host $script:RepairMessages.NoMountedWindowsInstallation -ForegroundColor Yellow
        }
    }
    Write-Host ''
    Write-Host $script:RepairMessages.MountAWindowsInstallation -ForegroundColor Cyan
    Write-Host $script:RepairMessages.YouMayAlsoEnter
    Write-Host $script:RepairMessages.EnterSkipISOBased
    while ($true) {
        $raw = (Read-Host $script:RepairMessages.DriveLetter).Trim()
        if ($raw.Length -eq 0) { return $null }
        try { $file = Find-ImageAtPath $raw } catch { $file = $null }
        if ($file -ne $null) {
            Write-Host ($script:RepairMessages.FoundImage + $file) -ForegroundColor Green
            return $file
        }
        Write-Host $script:RepairMessages.CouldNotFindSources -ForegroundColor Yellow
    }
}

function Get-OsImageProfile {
    param($OperatingSystem, [string]$Edition, [bool]$IsServer)
    # Win32_Processor.AddressWidth is the operating system bitness, even with 32-bit PowerShell.
    $cpu = Get-WmiObject Win32_Processor | Select-Object -First 1
    $arch = ''
    if ($cpu -ne $null) {
        if ([int]$cpu.AddressWidth -eq 32) { $arch = 'x86' }
        elseif ([int]$cpu.Architecture -eq 12) { $arch = 'arm64' }
        elseif ([int]$cpu.AddressWidth -eq 64) { $arch = 'x64' }
    }
    $installation = if ($IsServer) { 'Server' } else { 'Client' }
    if ($IsServer) {
        try {
            $installation = [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).InstallationType
        } catch { $installation = '' }
    }
    # Get-UICulture is advisory for the default image language, not a guarantee of OS integrity.
    $lang = ''
    try { $lang = [string](Get-UICulture).Name } catch { }
    $osFamily = ''
    $name = [string]$OperatingSystem.Caption
    $familyMatch = [regex]::Match($name, '(?i)Windows Server\s+\d{4}(?:\s+R2)?|Windows\s+(?:11|10|8\.1|8|7)')
    if ($familyMatch.Success) { $osFamily = $familyMatch.Value }
    return (New-Object PSObject -Property @{
        Edition = $Edition; Architecture = $arch; Installation = $installation
        Language = $lang; Version = [string]$OperatingSystem.Version; Family = $osFamily
    })
}

function Get-ImageDetails {
    param([string]$ImagePath, [int]$ImageIndex)
    $raw = @(& $script:DismExe /English /Get-WimInfo ("/WimFile:{0}" -f $ImagePath) ("/Index:{0}" -f $ImageIndex) 2>&1)
    if ([int]$LASTEXITCODE -ne 0) { return $null }
    $output = [string]::Join("`n", [string[]]$raw)
    # DISM prints its OWN "Version: ..." before the image details. Parse only
    # the "Details for image" section, never the executable banner.
    $detailsHeading = [regex]::Match($output, '(?im)^\s*Details\s+for\s+image\s*:\s*[^\r\n]*')
    if (-not $detailsHeading.Success) {
        Write-Host $script:RepairMessages.CouldNotFindThe -ForegroundColor Yellow
        return $null
    }
    $body = $output.Substring($detailsHeading.Index + $detailsHeading.Length)
    $result = New-Object PSObject -Property @{
        Name = ''; Edition = ''; Architecture = ''; Installation = ''; Language = ''; Version = ''; ServicePackBuild = ''
    }
    foreach ($name in @('Name', 'Edition', 'Architecture', 'Installation', 'Version')) {

        $match = [regex]::Match($body, ('(?im)^\s*{0}\s*:\s*(.*?)\s*$' -f $name))
        if ($match.Success) { $result.$name = $match.Groups[1].Value.Trim() }
    }
    $servicePackBuild = [regex]::Match($body, '(?im)^\s*ServicePack Build\s*:\s*(\d+)\s*$')
    if ($servicePackBuild.Success) { $result.ServicePackBuild = $servicePackBuild.Groups[1].Value }
    # Prefer the language explicitly marked as Default. A single-language image is unambiguous too.
    $languageHeading = [regex]::Match($body, '(?im)^\s*Languages\s*:\s*([^\r\n]*)')
    if ($languageHeading.Success) {
        $rest = $body.Substring($languageHeading.Index + $languageHeading.Length)
        $nextSection = [regex]::Match($rest, '(?m)^\s*[A-Za-z][A-Za-z ]{2,}\s*:\s*')
        if ($nextSection.Success) { $rest = $rest.Substring(0, $nextSection.Index) }
        $langValues = @()
        foreach ($line in ($languageHeading.Groups[1].Value + "`n" + $rest).Split([char[]]@("`r", "`n"), [StringSplitOptions]::RemoveEmptyEntries)) {
            $match = [regex]::Match($line, '(?i)\b([a-z]{2,3}-[a-z0-9-]+)\b')
            if ($match.Success) {
                $langValues += (New-Object PSObject -Property @{ Name = $match.Groups[1].Value; Default = ($line -match '(?i)\(Default\)') })
            }
        }
        $default = @($langValues | Where-Object { $_.Default })
        if ($default.Count -eq 1) { $result.Language = $default[0].Name }
        elseif ($langValues.Count -eq 1) { $result.Language = $langValues[0].Name }
    }
    return $result
}

function Choose-ImageIndex {
    param([string]$ImagePath, [string]$OsCaption, $OsProfile, [bool]$IsServer)
    Write-Host ''
    Write-Host ($script:RepairMessages.EditionsIn + $ImagePath) -ForegroundColor Cyan

    $rawLines = @(& $script:DismExe /English /Get-WimInfo ("/WimFile:{0}" -f $ImagePath) 2>&1)
    $code = [int]$LASTEXITCODE
    if ($code -ne 0) {
        foreach ($line in $rawLines) { Write-Host ([string]$line) }
        Write-Host ($script:RepairMessages.CouldNotReadImage + (Format-ExitCode $code)) -ForegroundColor Red
        return $null
    }
    $images = @()
    $currentIndex = 0
    foreach ($line in $rawLines) {
        $value = [string]$line
        if ($value -match '^\s*Index\s*:\s*(\d+)\s*$') {
            $currentIndex = [int]$Matches[1]
        } elseif (($currentIndex -gt 0) -and ($value -match '^\s*Name\s*:\s*(.+?)\s*$')) {
            $images += (New-Object PSObject -Property @{ Index = $currentIndex; Name = $Matches[1] })
            $currentIndex = 0
        }
    }
    if ($images.Count -eq 0) {
        Write-Host $script:RepairMessages.CouldNotReadThe -ForegroundColor Yellow
        foreach ($line in $rawLines) { Write-Host ([string]$line) }
        return $null
    }

    $targetName = ($OsCaption -replace '^\s*(Microsoft|Майкрософт)\s+', '').Trim()
    $nameMatches = @($images | Where-Object { $_.Name.Trim() -ieq $targetName })
    $suggested = 0
    if (($nameMatches.Count -eq 1) -and (-not $IsServer)) { $suggested = [int]$nameMatches[0].Index }

    Write-Host ''
    foreach ($image in $images) {
        $mark = if ([int]$image.Index -eq $suggested) { $script:RepairMessages.NameMatches } else { '' }
        Write-Host (' {0,2} — {1}{2}' -f $image.Index, $image.Name, $mark)
    }
    Write-Host ($script:RepairMessages.InstalledOS0EditionID -f $OsCaption, $OsProfile.Edition)

    # Verify real WIM/ESD metadata (not only friendly name). Skip questions only if
    # Edition, Architecture, InstallationType and default language all match uniquely.
    Write-Host $script:RepairMessages.CheckingEditionWindowsVersion -ForegroundColor Cyan
    $verified = @()
    $candidate = @()
    foreach ($image in $images) {
        $d = Get-ImageDetails -ImagePath $ImagePath -ImageIndex ([int]$image.Index)
        if ($null -eq $d) { continue }
        $sameEdition = ($OsProfile.Edition -ne '') -and ($d.Edition -ieq $OsProfile.Edition)
        $sameArch = ($OsProfile.Architecture -ne '') -and ($d.Architecture -ieq $OsProfile.Architecture)
        $sameInstallation = ($OsProfile.Installation -ne '') -and ($d.Installation -ieq $OsProfile.Installation)
        $sameLanguage = ($OsProfile.Language -ne '') -and ($d.Language -ieq $OsProfile.Language)
        $sameFamily = ($OsProfile.Family -ne '') -and ($image.Name.IndexOf([string]$OsProfile.Family, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        # Verify the build when available. Shared servicing baselines may differ, so
        # mismatches are not silently accepted but may still be manually confirmed.
        $sameVersion = ($d.Version -ne '') -and ($d.Version -ieq $OsProfile.Version)
        if ($sameEdition -and $sameArch -and $sameInstallation -and $sameFamily) {
            $candidate += [int]$image.Index
            if ($sameLanguage -and $sameVersion) { $verified += [int]$image.Index }
        }
    }
    if ($verified.Count -eq 1) {
        Write-Host ($script:RepairMessages.Index0SelectedAutomatically -f $verified[0]) -ForegroundColor Green
        return [int]$verified[0]
    }
    # If language information is absent or different, do not assume 100% compatibility.
    # Offer Enter to accept a single well-supported candidate without hiding ambiguity.
    if ($candidate.Count -eq 1) { $suggested = [int]$candidate[0] }
    if ($verified.Count -gt 1) { $suggested = 0 }
    if ($candidate.Count -ne 1) { $suggested = 0 }

    if ($suggested -gt 0) {
        Write-Host ($script:RepairMessages.SuggestedIndex0Press -f $suggested) -ForegroundColor Cyan
        Write-Host $script:RepairMessages.AutomaticSelectionSkippedNot -ForegroundColor Yellow
    } else {
        Write-Host $script:RepairMessages.NoUnambiguousMatchSelect -ForegroundColor Yellow
        if ($IsServer) { Write-Host $script:RepairMessages.OnServersDistinguishCarefully -ForegroundColor Yellow }
    }
    Write-Host $script:RepairMessages.TheSourceMustMatch -ForegroundColor Yellow

    while ($true) {
        $question = if ($suggested -gt 0) { $script:RepairMessages.ImageIndexEnterSuggested } else { $script:RepairMessages.ImageIndexEnterCancel }
        $raw = (Read-Host $question).Trim()
        if ($raw.Length -eq 0) {
            if ($suggested -gt 0) { return $suggested }
            return $null
        }
        $index = 0
        if ([int]::TryParse($raw, [ref]$index)) {
            foreach ($image in $images) {
                if ([int]$image.Index -eq $index) { return $index }
            }
        }
        Write-Host $script:RepairMessages.TheIndexIsNot -ForegroundColor Yellow
    }
}

function Invoke-RepairExecutable {
    param([string]$Executable, [string]$Arguments)
    # System.Diagnostics.Process inherits the parent console, so DISM/SFC can
    # render their normal in-place progress. It also avoids the PowerShell bug
    # where Start-Process -NoNewWindow can report a bogus ExitCode of 0.
    $process = New-Object System.Diagnostics.Process
    try {
        $process.StartInfo.FileName = $Executable
        $process.StartInfo.Arguments = $Arguments
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $false
        if (-not $process.Start()) { throw ($script:RepairMessages.FailedToStart + $Executable) }
        while (-not $process.WaitForExit(400)) { }
        $process.Refresh()
        return [int]$process.ExitCode
    } finally {
        if ($process -ne $null) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill()
                    $process.WaitForExit(3000) | Out-Null
                }
            } catch { }
            $process.Dispose()
        }
    }
}

function Run-Dism {
    param([string]$ImagePath, [int]$ImageIndex)
    $argList = @('/Online', '/Cleanup-Image', '/RestoreHealth')
    if (-not [string]::IsNullOrEmpty($ImagePath)) {
        $kind = if ($ImagePath.ToLowerInvariant().EndsWith('.esd')) { 'ESD' } else { 'WIM' }
        # Quoted filename preserves spaces in the native DISM command line.
        $argList += ('/Source:{0}:"{1}":{2}' -f $kind, $ImagePath, $ImageIndex)
        # Always permit the Windows Update fallback: do not add /LimitAccess.
        # Actual Microsoft Update access still depends on local policies/network.
        Write-Host ''
        Write-Host ($script:RepairMessages.DISMUsingSource0 -f $ImagePath, $ImageIndex) -ForegroundColor Cyan
        Write-Host $script:RepairMessages.WindowsUpdateFallbackIs
    } else {
        Write-Host ''
        Write-Host $script:RepairMessages.DISMUsingTheDefault -ForegroundColor Cyan
    }

    # Do not catch cancellation and turn it into an ordinary DISM error.
    # In particular, Ctrl+C must not trigger the ISO prompt or SFC.
    $arguments = [string]::Join(' ', [string[]]$argList)
    $code = Invoke-RepairExecutable -Executable $script:DismExe -Arguments $arguments
    $color = if (($code -eq 0) -or ($code -eq 3010)) { 'Green' } else { 'Red' }
    Write-Host ('DISM: ' + (Format-ExitCode $code)) -ForegroundColor $color
    if ($code -eq -2146498283) {
        Write-Host $script:RepairMessages.Error0x800F0915InspectCBS -ForegroundColor Yellow
    }
    if (($code -ne 0) -and ($code -ne 3010) -and (-not [string]::IsNullOrEmpty($ImagePath))) {
        Write-Host $script:RepairMessages.RepairUsingTheISO -ForegroundColor Yellow
        Write-Host $script:RepairMessages.SomeRequiredFileVersions -ForegroundColor Yellow
        if ($code -eq -2146498283) {
            Write-Host $script:RepairMessages.TheRepairSourceDid -ForegroundColor Yellow
        } else {
            Write-Host $script:RepairMessages.CheckCBSLogAnd -ForegroundColor Yellow
        }
    }
    return $code
}


# Schedule an offline repair only with the user's explicit approval.
function Schedule-SystemVolumeCheck {
    param([string]$Drive)
    if (-not (Ask-YesNo ($script:RepairMessages.ScheduleARepairOf -f $Drive) $true)) {
        Write-Host $script:RepairMessages.StartupTimeCheckingWas -ForegroundColor Yellow
        return
    }
    $code = Invoke-RepairExecutable -Executable $script:ChkntfsExe -Arguments ('/c ' + $Drive)
    if ($code -eq 0) {
        $script:VolumeScheduled = $true
        $script:VolumeNeedsAttention = $true
        $script:VolumeStatus = 'ScheduledAtBoot'
        Write-Host $script:RepairMessages.RepairScheduledForThe -ForegroundColor Yellow
    } else {
        Write-Host ($script:RepairMessages.ChkntfsError + (Format-ExitCode $code)) -ForegroundColor Red
    }
}

# Keep the native Repair-Volume progress, but put the actual drive letter
# in the command text shown by the PowerShell host (rather than $letter).
# Both interpolated values are strictly validated before building the block.
function Invoke-RepairVolume {
    param(
        [char]$DriveLetter,
        [ValidateSet('Scan', 'SpotFix', 'OfflineScanAndFix')][string]$Mode
    )
    $name = [string]$DriveLetter
    if ($name -notmatch '^[A-Za-z]$') { throw $script:RepairMessages.InvalidVolumeDriveLetter }
    $command = ('Repair-Volume -DriveLetter {0} -{1} -ErrorAction Stop' -f $name, $Mode)
    if ($Mode -ne 'Scan') { $command += ' -Confirm:$false' }
    & ([scriptblock]::Create($command))
}

# Read the installed Windows release directly, never infer it from OS build.
function Get-WindowsRelease {
    try {
        $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        return ([string]$cv.DisplayVersion).Trim()
    } catch { return '' }
}

# Inspect fixed local volumes hosting Windows folders and the ORIGINAL user's
# folders as captured by Common before any UAC elevation.
function Get-RepairVolumes {
    $candidates = New-Object System.Collections.ArrayList
    foreach ($entry in @(
        @{ Name = 'Windows'; Path = [string]$env:SystemRoot }
        @{ Name = 'ProgramData'; Path = [string]$env:ProgramData }
        @{ Name = 'Program Files'; Path = [string]$env:ProgramFiles }
        @{ Name = 'Public'; Path = [string]$env:PUBLIC }
        @{ Name = 'TEMP'; Path = [string]$env:TEMP }
    )) { [void]$candidates.Add($entry) }
    if (${env:ProgramFiles(x86)}) {
        [void]$candidates.Add(@{ Name = 'Program Files (x86)'; Path = [string]${env:ProgramFiles(x86)} })
    }

    $labels = @{
        UserProfile  = $script:RepairMessages.FolderProfile
        Downloads    = $script:RepairMessages.FolderDownloads
        Desktop      = $script:RepairMessages.FolderDesktop
        Documents    = $script:RepairMessages.FolderDocuments
        Pictures     = $script:RepairMessages.FolderPictures
        Music        = $script:RepairMessages.FolderMusic
        Videos       = $script:RepairMessages.FolderVideos
        RoamingAppData = 'AppData (Roaming)'
        LocalAppData = 'AppData (Local)'
        TEMP         = 'TEMP'
    }
    $snapshot = $utility.OriginalUserFolders
    if ($null -ne $snapshot -and $snapshot.Paths -is [Collections.IDictionary]) {
        foreach ($key in @('UserProfile','Downloads','Desktop','Documents','Pictures','Music','Videos','RoamingAppData','LocalAppData','TEMP')) {
            $value = [string]$snapshot.Paths[$key]
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                [void]$candidates.Add(@{ Name = [string]$labels[$key]; Path = $value; Prechecked = $true })
            }
        }
    }

    $fixed = @{}
    try {
        foreach ($disk in @(Get-WmiObject Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop)) {
            $fixed[([string]$disk.DeviceID).ToUpperInvariant()] = $true
        }
    } catch { }
    if ($fixed.Count -eq 0) {
        try {
            foreach ($disk in [IO.DriveInfo]::GetDrives()) {
                if ($disk.DriveType -eq [IO.DriveType]::Fixed -and $disk.IsReady) {
                    $fixed[$disk.Name.Substring(0, 2).ToUpperInvariant()] = $true
                }
            }
        } catch { }
    }

    $volumes = [ordered]@{}
    $systemDrive = [string]$env:SystemDrive
    if ($systemDrive -match '^[A-Za-z]:$') {
        $volumes[$systemDrive.ToUpperInvariant()] = $true
    }
    foreach ($candidate in $candidates) {
        # The original user's environment variables were expanded BEFORE UAC.
        $path = [string]$candidate.Path
        if ($path -notmatch '^[A-Za-z]:\\') { continue }
        if (-not $candidate.Prechecked -and
            -not (Test-Path -LiteralPath $path -PathType Container -ErrorAction SilentlyContinue)) { continue }
        $drive = $path.Substring(0, 2).ToUpperInvariant()
        if (-not $fixed.ContainsKey($drive)) { continue }
        if (-not $volumes.Contains($drive)) {
            $volumes[$drive] = $true
            Write-Host ($script:RepairMessages.VolumeAddedForFolder -f $drive, $candidate.Name, $path) -ForegroundColor Cyan
        }
    }
    return @($volumes.Keys)
}

# Present recognizable Repair-Volume statuses in the active utility language.
# Keep the raw status in the summary only when no mapping exists.
function Get-VolumeStatusText {
    param([string]$Status)
    switch ($Status) {
        'NoErrorsFound'            { return $script:RepairMessages.TheFileSystemIs }
        'SpotFixNeeded'            { return $script:RepairMessages.VolumeSpotFixNeeded }
        'OfflineScanAndFixNeeded'  { return $script:RepairMessages.VolumeOfflineFixNeeded }
        'ScanNeeded'               { return $script:RepairMessages.VolumeScanNeeded }
        'Repaired'                 { return $script:RepairMessages.VerificationNoErrorsFound }
        default                    { return $Status }
    }
}

function Test-SystemVolume {
    param([version]$OsVersion, [string]$Drive)
    $drive = [string]$Drive
    if ($drive -notmatch '^[A-Za-z]:$') {
        $script:VolumeStatus = 'UnknownSystemDrive'
        $script:VolumeNeedsAttention = $true
        Write-Host ($script:RepairMessages.CouldNotDetermineThe + $drive) -ForegroundColor Red
        return
    }
    $letter = [char]$drive.Substring(0, 1)
    if ($script:VolumeChecks.Count -gt 0) { Write-Host '' }
    Write-Host ($script:RepairMessages.CheckingFileSystemOn -f $drive) -ForegroundColor Cyan
    if ($OsVersion -ge [version]'6.2') {
        $cmdlet = Get-Command Repair-Volume -ErrorAction SilentlyContinue
        if ($null -ne $cmdlet) {
            try {
                $scan = @(Invoke-RepairVolume -DriveLetter $letter -Mode Scan)
                if ($scan.Count -ne 1) { throw $script:RepairMessages.RepairVolumeReturnedAn }
                $status = ([string]$scan[0]).Trim()
                $script:VolumeStatus = $status
                if ($status -eq 'NoErrorsFound') {
                    Write-Host $script:RepairMessages.TheFileSystemIs -ForegroundColor Green
                    return
                }
                if (@('SpotFixNeeded', 'OfflineScanAndFixNeeded', 'ScanNeeded') -contains $status) {
                    $script:VolumeNeedsAttention = $true
                    Write-Host (Get-VolumeStatusText -Status $status) -ForegroundColor Yellow
                    $spot = ($status -eq 'SpotFixNeeded')
                    $mode = if ($spot) { 'SpotFix' } else { 'OfflineScanAndFix' }
                    if (Ask-YesNo ($script:RepairMessages.TryRepairVolume0 -f $mode, $drive) $true) {
                        try {
                            if ($spot) {
                                $fix = @(Invoke-RepairVolume -DriveLetter $letter -Mode SpotFix)
                            } else {
                                $fix = @(Invoke-RepairVolume -DriveLetter $letter -Mode OfflineScanAndFix)
                            }
                            Write-Host ($script:RepairMessages.RepairResult + ($fix -join ', '))
                            $verify = @(Invoke-RepairVolume -DriveLetter $letter -Mode Scan)
                            if (($verify.Count -eq 1) -and (([string]$verify[0]).Trim() -eq 'NoErrorsFound')) {
                                $script:VolumeNeedsAttention = $false
                                $script:VolumeStatus = 'Repaired'
                                Write-Host $script:RepairMessages.VerificationNoErrorsFound -ForegroundColor Green
                                return
                            }
                            Write-Host ($script:RepairMessages.FurtherCheckingIsStill + ($verify -join ', ')) -ForegroundColor Yellow
                        } catch [System.Management.Automation.PipelineStoppedException] {
                            throw
                        } catch {
                            Write-Host ($script:RepairMessages.OnlineRepairDidNot + $_.Exception.Message) -ForegroundColor Red
                        }
                    }
                    Schedule-SystemVolumeCheck -Drive $drive
                    return
                }
                Write-Host ($script:RepairMessages.UnknownRepairVolumeStatus -f $status) -ForegroundColor Yellow
            } catch [System.Management.Automation.PipelineStoppedException] {
                throw
            } catch {
                $errorText = [string]$_.Exception.Message
                if ([string]::IsNullOrWhiteSpace($errorText)) {
                    $errorText = Format-ExitCode ([int]$_.Exception.HResult)
                }
                Write-Host ($script:RepairMessages.CouldNotCheckThe + $errorText) -ForegroundColor Red
                Write-Host $script:RepairMessages.SwitchingToReadOnly -ForegroundColor Yellow
            }
        } else {
            Write-Host $script:RepairMessages.RepairVolumeIsUnavailable -ForegroundColor Yellow
        }
    } else {
        Write-Host $script:RepairMessages.Windows7Server2008 -ForegroundColor Cyan
    }
    # Read-only fallback: neither /f nor /r is used automatically.
    $code = Invoke-RepairExecutable -Executable $script:ChkdskExe -Arguments $drive
    $script:VolumeStatus = ('CHKDSK ' + (Format-ExitCode $code))
    if ($code -eq 0) {
        Write-Host $script:RepairMessages.CHKDSKNoErrorsFound -ForegroundColor Green
        return
    }
    $script:VolumeNeedsAttention = $true
    Write-Host ('CHKDSK: ' + (Format-ExitCode $code)) -ForegroundColor Red
    Write-Host $script:RepairMessages.TheFileSystemMay
    Schedule-SystemVolumeCheck -Drive $drive
}


# Only offer Setup from an installation source that was already explicitly
# selected for DISM. /Auto Upgrade preserves BOTH applications and data; if
# unsupported, Windows Setup must fail instead of switching to DataOnly/Clean.
function Offer-InPlaceWindowsSetup {
    param([string]$OsCaption, $OsProfile, [bool]$IsServer, [version]$OsVersion)

    if ($IsServer -or ($OsVersion -lt [version]'10.0')) {
        Write-Host $script:RepairMessages.AutomaticSetupLaunchIs -ForegroundColor Yellow
        return
    }
    $image = [string]$script:SelectedRepairImage
    if ([string]::IsNullOrEmpty($image)) {
        Write-Host $script:RepairMessages.NoInstallationISOWas -ForegroundColor Yellow
        return
    }
    # Require an image in the standard sources folder and setup.exe on the
    # very same media; a random .wim/.esd cannot safely identify its installer.
    $match = [regex]::Match($image, '(?i)^([A-Z]:)\\sources\\install\.(?:wim|esd)$')
    if (-not $match.Success) {
        Write-Host $script:RepairMessages.TheWIMESDSource -ForegroundColor Yellow
        Write-Host $script:RepairMessages.RunSetupExeManually -ForegroundColor Yellow
        return
    }
    $setup = Join-Path ($match.Groups[1].Value + '\') 'setup.exe'
    if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) {
        Write-Host ($script:RepairMessages.InstallerNotFoundOn + $setup) -ForegroundColor Yellow
        return
    }
    $index = [int]$script:SelectedRepairIndex
    if ($index -le 0) {
        Write-Host $script:RepairMessages.NoImageIndexWas -ForegroundColor Yellow
        return
    }
    # Re-read metadata for exactly the index being passed to setup.exe.
    # Do not rely on the earlier DISM choice if media content has changed.
    $details = Get-ImageDetails -ImagePath $image -ImageIndex $index
    if ($null -eq $details) {
        Write-Host $script:RepairMessages.CouldNotVerifyInstallation -ForegroundColor Yellow
        return
    }
    if (($OsProfile.Edition -eq '') -or ($details.Edition -ieq '') -or
        ($details.Edition -ine $OsProfile.Edition)) {
        Write-Host ($script:RepairMessages.ISOEditionNotVerified -f $OsProfile.Edition, $script:SelectedRepairIndex, $details.Edition) -ForegroundColor Yellow
        Write-Host $script:RepairMessages.SetupCanceledUnverifiedEdition -ForegroundColor Yellow
        return
    }
    if (($OsProfile.Architecture -eq '') -or ($details.Architecture -eq '') -or
        ($details.Architecture -ine $OsProfile.Architecture) -or
        ($details.Installation -ine 'Client')) {
        Write-Host $script:RepairMessages.TheISOArchitectureOr -ForegroundColor Yellow
        return
    }
    if (($OsProfile.Language -eq '') -or ($details.Language -eq '') -or
        ($details.Language -ine $OsProfile.Language)) {
        Write-Host ($script:RepairMessages.LanguageMismatchOrUnknown -f $OsProfile.Language, $details.Language) -ForegroundColor Yellow
        Write-Host $script:RepairMessages.ToKeepAppsThe -ForegroundColor Yellow
        return
    }
    try {
        $installed = [version]$OsProfile.Version
        $target = [version]$details.Version
        if ($target -lt $installed) {
            Write-Host ($script:RepairMessages.TheISOContainsAn -f $target, $installed) -ForegroundColor Yellow
            Write-Host $script:RepairMessages.SetupCanceledDowngrade -ForegroundColor Yellow
            return
        }
    } catch {
        Write-Host $script:RepairMessages.CouldNotReliablyCompare -ForegroundColor Yellow
        return
    }

    # Explicitly preserve apps and files. DynamicUpdate Disable avoids downloads
    # during Setup, /EULA Accept avoids the extra Windows 11 license dialog.
    # Explicitly specify the index already checked by DISM. No /Quiet or
    # compatibility bypass: the user must see Setup and its warnings.
    $args = ('/Auto Upgrade /ImageIndex {0} /DynamicUpdate Disable /EULA Accept' -f $index)
    Write-Host ''
    $targetVersion = [string]$details.Version
    if (($details.ServicePackBuild -ne '') -and ($details.ServicePackBuild -ne '0')) {
        $targetVersion += '.' + $details.ServicePackBuild
    }
    Write-Host $script:RepairMessages.EDITIONCOMPARISON -ForegroundColor Cyan
    Write-Host $script:RepairMessages.CurrentWindows -ForegroundColor Cyan
    Write-Host ($script:RepairMessages.InstalledWindowsName -f $OsCaption)
    Write-Host ($script:RepairMessages.InstalledWindowsEdition -f $OsProfile.Edition)
    Write-Host ($script:RepairMessages.InstalledWindowsVersion -f $OsProfile.Version)
    Write-Host ($script:RepairMessages.InstalledWindowsArchitecture -f $OsProfile.Architecture)
    Write-Host ($script:RepairMessages.InstalledWindowsLanguage -f $OsProfile.Language)
    Write-Host ($script:RepairMessages.ISOImageIndex0 -f $index) -ForegroundColor Cyan
    Write-Host ($script:RepairMessages.IsoImageName -f $details.Name)
    Write-Host ($script:RepairMessages.IsoImageEdition -f $details.Edition)
    Write-Host ($script:RepairMessages.IsoImageVersion -f $targetVersion)
    Write-Host ($script:RepairMessages.IsoImageArchitecture -f $details.Architecture)
    Write-Host ($script:RepairMessages.IsoImageLanguage -f $details.Language)
    Write-Host ($script:RepairMessages.Installer0 -f $setup)
    Write-Host $script:RepairMessages.EditionArchitectureAndLanguage -ForegroundColor Green
    Write-Host $script:RepairMessages.CarefullyReviewBothEditions -ForegroundColor Yellow
    Write-Host ''
    if (-not (Ask-YesNo ($script:RepairMessages.StartAnInPlace -f $args) $true)) {
        Write-Host $script:RepairMessages.InstallationCanceledByThe
        return
    }
    try {
        # Windows Setup runs independently. The console remains open at script
        # exit only when the original launch was from Explorer.
        $process = Start-Process -FilePath $setup -ArgumentList $args -PassThru -ErrorAction Stop
        if ($null -eq $process) { throw $script:RepairMessages.StartProcessDidNot }
        $script:SetupLaunched = $true
        Write-Host ($script:RepairMessages.WindowsSetupStartedPID -f $process.Id) -ForegroundColor Green
    } catch [System.Management.Automation.PipelineStoppedException] {
        throw
    } catch {
        $script:HadError = $true
        Write-Host ($script:RepairMessages.CouldNotStartWindows + $_.Exception.Message) -ForegroundColor Red
    }
}


function Try-RepairFromImage {
    param([string]$OsCaption, $OsProfile, [bool]$IsServer, [switch]$AskForDrive)
    $image = Choose-Image -AskForDrive:$AskForDrive
    if ($null -eq $image) { return $null }
    $index = Choose-ImageIndex -ImagePath $image -OsCaption $OsCaption -OsProfile $OsProfile -IsServer $IsServer
    if ($null -eq $index) { return $null }
    # The image name/edition may match while its servicing build differs.
    # Show the image version so the user can diagnose a missing repair payload.
    $details = Get-ImageDetails -ImagePath $image -ImageIndex $index
    # Keep the exact media and selected edition for an optional in-place Setup.
    # This is only a candidate; Windows Setup performs its own compatibility check.
    $script:SelectedRepairImage = [string]$image
    $script:SelectedRepairIndex = [int]$index
    $script:SelectedRepairDetails = $details
    if (($null -ne $details) -and (-not [string]::IsNullOrEmpty($details.Version))) {
        $displayVersion = [string]$details.Version
        if (($details.ServicePackBuild -ne '') -and ($details.ServicePackBuild -ne '0')) {
            $displayVersion += ('.' + $details.ServicePackBuild)
        }
        Write-Host ($script:RepairMessages.WindowsVersion0ISO -f $OsProfile.Version, $displayVersion)
        if (($OsProfile.Version -ne '') -and ($details.Version -ine $OsProfile.Version)) {
            Write-Host $script:RepairMessages.VersionsDifferTheImage -ForegroundColor Yellow
            Write-Host $script:RepairMessages.DISMRestoreHealthNeedsThe -ForegroundColor Yellow
        }
    }
    return (Run-Dism -ImagePath $image -ImageIndex $index)
}

try {

    try {
        $folder = $env:TEMP
        $script:LogPath = Join-Path $folder ('WinRepair_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Start-Transcript -Path $script:LogPath -ErrorAction Stop | Out-Null
        $script:TranscriptOn = $true
        Write-Host ($script:RepairMessages.RepairWindowsLogStarted + $script:LogPath)
    } catch {
        Write-Host ($script:RepairMessages.CouldNotStartThe + $_.Exception.Message) -ForegroundColor Yellow
    }
    Write-Host ''

    $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop
    $version = [version]$os.Version
    $isServer = ([int]$os.ProductType -ne 1)
    $canRestoreHealth = ($version.Major -gt 6) -or (($version.Major -eq 6) -and ($version.Minor -ge 2))
    $edition = ''
    try { $edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID } catch { }
    $profile = Get-OsImageProfile -OperatingSystem $os -Edition $edition -IsServer $isServer

    $release = Get-WindowsRelease
    $osName = ([string]$os.Caption).Trim()
    if ($release) { $osName = '{0} {1}' -f $osName, $release }
    Write-Host ($script:RepairMessages.OS0Version1 -f $osName, $os.Version)
    Write-Host ($script:RepairMessages.Edition0Type1 -f $edition, $(if ($isServer) { 'Server' } else { 'Client' }))
    Write-Host ''
    Write-Host $script:RepairMessages.TheScriptDoesNot
    Write-Host $script:RepairMessages.CtrlCCancelAll -ForegroundColor Yellow
    Write-Host ''

    $anyAttention = $false
    $anyScheduled = $false
    $systemNeedsAttention = $false
    $systemScheduled = $false
    foreach ($drive in @(Get-RepairVolumes)) {
        $script:VolumeStatus = $script:RepairMessages.NotChecked
        $script:VolumeNeedsAttention = $false
        $script:VolumeScheduled = $false
        Test-SystemVolume -OsVersion $version -Drive $drive
        $script:VolumeChecks += [pscustomobject]@{
            Drive = $drive
            Status = $script:VolumeStatus
            NeedsAttention = $script:VolumeNeedsAttention
            Scheduled = $script:VolumeScheduled
        }
        if ($script:VolumeNeedsAttention) { $anyAttention = $true }
        if ($script:VolumeScheduled) { $anyScheduled = $true }
        if ($drive -ieq $env:SystemDrive) {
            $systemNeedsAttention = $script:VolumeNeedsAttention
            $systemScheduled = $script:VolumeScheduled
        }
    }
    $script:VolumeNeedsAttention = $anyAttention
    $script:VolumeScheduled = $anyScheduled
    $skipWindowsRepair = $systemScheduled
    if ($systemNeedsAttention -and (-not $skipWindowsRepair)) {
        Write-Host $script:RepairMessages.FileSystemIntegrityCould -ForegroundColor Yellow
        if (-not (Ask-YesNo $script:RepairMessages.ContinueWithDISMSFC $false)) {
            $skipWindowsRepair = $true
        }
    }
    if ($skipWindowsRepair) {
        Write-Host $script:RepairMessages.DISMAndSFCSkipped -ForegroundColor Yellow
    } else {
        if (-not $canRestoreHealth) {
            Write-Host ''
            Write-Host $script:RepairMessages.DISMRestoreHealthIsNot -ForegroundColor Yellow
            Write-Host $script:RepairMessages.OnlySFCWillRun
            Write-Host 'https://www.catalog.update.microsoft.com/Search.aspx?q=KB947821'
        } else {
            if ($isServer) {
                Write-Host ''
                Write-Host $script:RepairMessages.WindowsServerSpecifyAn -ForegroundColor Yellow
                $script:DiskResult = Try-RepairFromImage -OsCaption $os.Caption -OsProfile $profile -IsServer $isServer
                if ($null -eq $script:DiskResult) {
                    Write-Host $script:RepairMessages.NoSourceSelectedRunning
                    $script:DiskResult = Run-Dism -ImagePath $null -ImageIndex 0
                }
            } else {
                Write-Host ''
                Write-Host $script:RepairMessages.WindowsClientTryingDISM -ForegroundColor Cyan
                $script:DiskResult = Run-Dism -ImagePath $null -ImageIndex 0
            }
            if (($script:DiskResult -ne 0) -and ($script:DiskResult -ne 3010)) {
                if ($null -eq $script:SelectedRepairImage) {
                    # The first attempt used the built-in/default source.
                    # A mounted ISO can now be entered without an extra Y/N prompt.
                    Write-Host ''
                    Write-Host $script:RepairMessages.DISMCouldNotRepair -ForegroundColor Yellow
                    $ret = Try-RepairFromImage -OsCaption $os.Caption -OsProfile $profile -IsServer $isServer
                    if ($null -ne $ret) { $script:DiskResult = $ret }
                    else { Write-Host $script:RepairMessages.NoRepairSourceSelected -ForegroundColor Yellow }
                } elseif (Ask-YesNo $script:RepairMessages.RepairWithTheSelected $true) {
                    $ret = Try-RepairFromImage -OsCaption $os.Caption -OsProfile $profile -IsServer $isServer -AskForDrive
                    if ($null -ne $ret) { $script:DiskResult = $ret }
                    else { Write-Host $script:RepairMessages.RetryUsingISOCanceled -ForegroundColor Yellow }
                }
            }
        }

        # SFC must NOT be in finally: Ctrl+C must not launch the next repair operation.
        Write-Host ''
        Write-Host $script:RepairMessages.CheckingSystemFilesSFC -ForegroundColor Cyan
        $script:SfcResult = Invoke-RepairExecutable -Executable $script:SfcExe -Arguments '/scannow'
    }
    Write-Host ''
    Write-Host $script:RepairMessages.SUMMARY -ForegroundColor Cyan
    Write-Host $script:RepairMessages.CheckedVolumes
    foreach ($check in $script:VolumeChecks) {
        $statusText = Get-VolumeStatusText -Status ([string]$check.Status)
        $statusColor = if (-not $check.NeedsAttention) { 'Green' } else { 'Yellow' }
        Write-Host ('  {0} {1}' -f $check.Drive, $statusText) -ForegroundColor $statusColor
    }
    if ($script:VolumeScheduled) { Write-Host $script:RepairMessages.RepairScheduledAtStartup -ForegroundColor Yellow }
    if ($null -ne $script:DiskResult) {
        Write-Host ('DISM: ' + (Format-ExitCode $script:DiskResult))
    } else {
        Write-Host $script:RepairMessages.DISMNotRunOr
    }
    if ($null -ne $script:SfcResult) {
        Write-Host ('SFC:  ' + (Format-ExitCode $script:SfcResult))
    } else {
        Write-Host $script:RepairMessages.SFCNotRun
    }
    Write-Host $script:RepairMessages.AlsoEvaluateTheSFC
    Write-Host ($script:RepairMessages.DISMLog + (Join-Path $env:SystemRoot 'Logs\DISM\dism.log'))
    Write-Host ($script:RepairMessages.CBSLog + (Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'))
    if ($script:LogPath -ne $null -and $script:TranscriptOn) {
        Write-Host ($script:RepairMessages.RepairWindowsLogSummary + $script:LogPath)
    }
    if (($null -ne $script:DiskResult) -and ($script:DiskResult -ne 0) -and ($script:DiskResult -ne 3010)) {
        Write-Host $script:RepairMessages.DISMDidNotRepair -ForegroundColor Yellow
        Write-Host ''
        Write-Host $script:RepairMessages.IfDISMISORepair -ForegroundColor Yellow
        Write-Host $script:RepairMessages.ConsiderInstallingACompatible
        Write-Host $script:RepairMessages.MountAnISOFrom
        Write-Host $script:RepairMessages.SelectKeepPersonalFiles
        Write-Host $script:RepairMessages.IfThatOptionIs
        Write-Host $script:RepairMessages.BackUpImportantData
        $script:HadError = $true
    }
    if (($null -ne $script:SfcResult) -and ($script:SfcResult -ne 0)) { $script:HadError = $true }
    if ($script:VolumeNeedsAttention) { $script:HadError = $true }
    if ($script:DiskResult -eq 3010) { Write-Host $script:RepairMessages.DISMReportedThatA -ForegroundColor Yellow }

    Write-Host ''
    Write-Host $script:RepairMessages.ToViewTheResult -ForegroundColor Cyan
    if ($script:LogPath -ne $null -and (Test-Path -LiteralPath $script:LogPath)) {
        # Quoting with doubled apostrophes keeps the command copyable even
        # when the log directory contains apostrophes.
        $quotedLog = $script:LogPath.Replace("'", "''")
        Write-Host ("Get-Content -LiteralPath '{0}' | Select-Object -Last 80" -f $quotedLog)
    } else {
        Write-Host 'Get-ChildItem "$env:TEMP\WinRepair_*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content | Select-Object -Last 80'
    }
    if (($null -ne $script:DiskResult) -and ($script:DiskResult -ne 0) -and ($script:DiskResult -ne 3010)) {
        Write-Host $script:RepairMessages.RecentCharacteristicCBSErrors -ForegroundColor Yellow
        Write-Host 'Select-String -Path "$env:windir\Logs\CBS\CBS.log" -Pattern "CSI Payload Corrupt","CBS_E_","Missing replacement","Failed to resolve","0x800f" | Select-Object -Last 30'
    }
    Write-Host '=================================================='
    if (($null -ne $script:DiskResult) -and ($script:DiskResult -ne 0) -and
        ($script:DiskResult -ne 3010) -and (-not $script:VolumeScheduled)) {
        Offer-InPlaceWindowsSetup -OsCaption $os.Caption -OsProfile $profile -IsServer $isServer -OsVersion $version
    }
    if ($script:VolumeScheduled) {
        Write-Host $script:RepairMessages.SaveYourFilesBefore
        $script:RestartRequested = Ask-YesNo $script:RepairMessages.RestartTheComputerNow $false
    }
    if ($script:RestartRequested) {
        try {
            Restart-Computer -ErrorAction Stop
            $script:RestartInitiated = $true
        } catch [System.Management.Automation.PipelineStoppedException] {
            throw
        } catch {
            Write-Host ($script:RepairMessages.CouldNotRestartThe + $_.Exception.Message) -ForegroundColor Red
            $script:HadError = $true
        }
    }
} catch {
    # All unexpected failures, including cancellation, end the complete script.
    Write-Host ($script:RepairMessages.RepairWindowsError + $_.Exception.Message) -ForegroundColor Red
    throw
} finally {
    # Never start a repair operation from finally: only cleanup belongs here.
    if ($script:TranscriptOn) {
        try { Stop-Transcript | Out-Null } catch { }
    }
    if ($script:RestartInitiated) { $utility.PauseOnExit = $false }
    Stop-Utility -Utility $utility
}
if ($script:HadError) { exit 1 } else { exit 0 }
