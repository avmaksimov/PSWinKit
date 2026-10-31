#requires -Version 5.1
<#
Remove-Paths.ps1 (Windows 10+, Windows PowerShell 5.1)
Run without arguments, optionally -LanguageFile for translation override.
Common/Utility.ps1 provides UAC, locale selection, header and exit pause.
The utility itself is relaunched after UAC; no host-process flags are needed.
#>
param(
    [string]$LanguageFile,
    [switch]$PauseOnExit
)

. (Join-Path $PSScriptRoot 'Common\Utility.ps1')
$utility = Start-Utility -ScriptPath $PSCommandPath -Section 'RemovePaths' `
    -LanguageFile $LanguageFile -PauseOnExit:$PauseOnExit -RequireAdministrator
if ($null -eq $utility) { return }

$ErrorActionPreference = 'Stop'
$UtilityMessages = $utility.Messages

# Get-UtilityMessage is provided by the dot-sourced common library.
function T {
    param([string]$Key, [object[]]$Values = @())
    return (Get-UtilityMessage -Key ("RemovePaths.$Key") -Messages $UtilityMessages -Values $Values)
}

function Test-IsWithin {
    param([string]$Path, [string]$Base)
    return ($Path.Equals($Base, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Base + '\', [StringComparison]::OrdinalIgnoreCase))
}

$protectedFolders = @(
    'Windows', 'Users', 'Program Files', 'Program Files (x86)',
    'ProgramData', 'Recovery', 'PerfLogs', 'Boot', 'EFI',
    'System Volume Information', '$Recycle.Bin', 'Documents and Settings'
)
$protectedFiles = @(
    'bootmgr', 'BOOTNXT', 'bootmgr.efi', 'bootsect.bak',
    'ntldr', 'NTDETECT.COM', 'boot.ini', 'pagefile.sys',
    'swapfile.sys', 'hiberfil.sys', 'DumpStack.log', 'DumpStack.log.tmp'
)
$protectedDrives = @('C:', $env:SystemDrive.TrimEnd('\')) | Select-Object -Unique

function Test-IsProtected {
    param([string]$Path)
    if ($Path -match '^[A-Za-z]:\\?$') { return $true }
    foreach ($drive in $protectedDrives) {
        foreach ($folder in $protectedFolders) {
            if (Test-IsWithin -Path $Path -Base ($drive + '\' + $folder)) { return $true }
        }
        foreach ($file in $protectedFiles) {
            if ($Path.Equals(($drive + '\' + $file),
                    [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    return $false
}

function Get-Attributes {
    param([string]$Path)
    # GetFileAttributes reads attributes of the reparse point, not its target.
    return [IO.File]::GetAttributes($Path)
}

function Test-IsReparsePoint {
    param([IO.FileAttributes]$Attributes)
    return (($Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-ValidatedPath {
    param([string]$InputPath)
    $value = [Environment]::ExpandEnvironmentVariables($InputPath.Trim().Trim('"').Trim("'")).Replace('/', '\')
    if ($value -notmatch '^[A-Za-z]:\\') { throw (T 'AbsolutePath') }
    if ($value.Substring(2).Contains(':')) { throw (T 'AbsolutePath') }
    $path = [IO.Path]::GetFullPath($value).TrimEnd('\')
    # SUBST can mask a path on C: behind another drive letter.
    $driveLetter = $path.Substring(0, 2)
    foreach ($mapping in @(& subst.exe 2>$null)) {
        if ($mapping -match '^([A-Za-z]:)\\: => ' -and $Matches[1] -ieq $driveLetter) {
            throw (T 'SubstBlocked')
        }
    }
    if (Test-IsProtected -Path $path) { throw (T 'ProtectedPath') }
    if ($path -match '(?i)(^|\\)[^\\]*~[0-9]+' -or
        $path -match '(^|\\)[^\\]*[. ](?=\\|$)') {
        throw (T 'UnsupportedName')
    }

    # Reject a reparse point in any ancestor. The selected item itself may be a link.
    $parent = [IO.Path]::GetDirectoryName($path)
    while ($parent -and $parent.Length -gt 3) {
        $attr = Get-Attributes -Path $parent
        if (Test-IsReparsePoint -Attributes $attr) {
            throw (T 'AncestorLink' -Values @($parent))
        }
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
    return $path
}

$script:ACLRepaired = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
$script:RepairedCount = 0
$script:DeletedCount = 0
$script:LinkCount = 0
$script:FailureCount = 0
$script:FailureSamples = New-Object 'System.Collections.Generic.List[string]'
$script:Phase = T 'PhaseStart'
$script:Result = T 'StatusInterrupted'
$script:InputCount = 0
$script:TargetCount = 0
$script:SkippedCount = 0
$script:StartedCount = 0
$script:TargetsRemoved = 0
$script:TargetsFailed = 0
$script:CurrentTarget = $null
$script:MainError = $null

function Show-Summary {
    Write-Host "`n$(Get-UtilityMessage -Key 'Common.SummaryTitle' -Messages $UtilityMessages)" -ForegroundColor Cyan
    Write-Host (T 'SummaryResult' -Values @($script:Result))
    Write-Host (T 'SummaryPhase' -Values @($script:Phase))
    Write-Host (T 'SummaryInput' -Values @($script:InputCount))
    Write-Host (T 'SummaryTargets' -Values @($script:TargetCount, $script:SkippedCount))
    Write-Host (T 'SummaryStarted' -Values @($script:StartedCount, $script:TargetsRemoved, $script:TargetsFailed))
    $remaining = [Math]::Max(0, $script:TargetCount - $script:StartedCount)
    if ($remaining -gt 0) {
        Write-Host (T 'SummaryUnstarted' -Values @($remaining)) -ForegroundColor Yellow
    }
    if ($script:CurrentTarget) {
        Write-Host (T 'SummaryCurrent' -Values @($script:CurrentTarget)) -ForegroundColor Yellow
    }
    Write-Host (T 'SummaryObjects' -Values @($script:DeletedCount, $script:LinkCount))
    Write-Host (T 'SummaryPermissions' -Values @($script:RepairedCount))
    Write-Host (T 'SummaryErrors' -Values @($script:FailureCount))
    if ($script:MainError) { Write-Warning $script:MainError }
    foreach ($failure in $script:FailureSamples) { Write-Warning $failure }
    if ($script:FailureCount -gt $script:FailureSamples.Count) {
        Write-Warning (T 'SummaryTruncated')
    }
}

function Repair-Access {
    param([string]$Path, [bool]$Directory)

    # Never modify the ACL/owner of reparse points, volume roots or protected paths.
    $attr = Get-Attributes -Path $Path
    if ((Test-IsReparsePoint -Attributes $attr) -or (Test-IsProtected -Path $Path)) {
        throw (T 'AccessBlocked' -Values @($Path))
    }
    if ($script:ACLRepaired.Contains($Path)) { return }

    # Only the selected real object, never /R or /T.
    & takeown.exe /F $Path /A 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw (T 'TakeOwnershipFailed' -Values @($Path)) }
    & icacls.exe $Path /inheritance:e /L /Q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw (T 'InheritanceFailed' -Values @($Path)) }
    $ace = if ($Directory) { '*S-1-1-0:(OI)(CI)F' } else { '*S-1-1-0:F' }
    & icacls.exe $Path /grant $ace /L /Q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw (T 'GrantFailed' -Values @($Path))
    }
    [void]$script:ACLRepaired.Add($Path)
    $script:RepairedCount++
}

function Invoke-DeleteLeaf {
    param([string]$Path, [bool]$Directory, [bool]$Link)

    if ($Link) {
        # Directory.Delete(non-recursive) unlinks junctions/symlinks/mount points.
        # File.Delete unlinks file symbolic links. Neither traverses their target.
        if ($Directory) { [IO.Directory]::Delete($Path) }
        else { [IO.File]::Delete($Path) }
    }
    elseif ($Directory) {
        # The tree has already been traversed by us. Never use -Recurse here.
        [IO.Directory]::Delete($Path)
    }
    else {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
}

function Add-Failure {
    param([string]$Path, [string]$Message)
    $script:FailureCount++
    if ($script:FailureSamples.Count -lt 15) {
        $script:FailureSamples.Add("$Path — $Message")
    }
}

function Remove-SafeEntry {
    param([string]$Path)
    # True means the item itself was removed (false means something remained).
    try { $attr = Get-Attributes -Path $Path }
    catch {
        Add-Failure -Path $Path -Message $_.Exception.Message
        return $false
    }
    $directory = (($attr -band [IO.FileAttributes]::Directory) -ne 0)
    $link = Test-IsReparsePoint -Attributes $attr
    $childFailures = $false

    if ($directory -and -not $link) {
        try {
            $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
        }
        catch {
            try {
                Repair-Access -Path $Path -Directory $true
                $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
            }
            catch {
                Add-Failure -Path $Path -Message (T 'CantReadDirectory' -Values @($_.Exception.Message))
                return $false
            }
        }
        foreach ($child in $children) {
            if (-not (Remove-SafeEntry -Path $child.FullName)) { $childFailures = $true }
        }
        if ($childFailures) { return $false }
    }

    try {
        Invoke-DeleteLeaf -Path $Path -Directory $directory -Link $link
    }
    catch {
        # For a link, repair only its REAL parent directory, never the link itself.
        $parent = [IO.Path]::GetDirectoryName($Path)
        if ($link) {
            if ($parent -and -not (Test-IsProtected -Path $parent)) {
                try {
                    Repair-Access -Path $parent -Directory $true
                    Invoke-DeleteLeaf -Path $Path -Directory $directory -Link $true
                }
                catch {
                    Add-Failure -Path $Path -Message $_.Exception.Message
                    return $false
                }
            }
            else {
                Add-Failure -Path $Path -Message (T 'LinkNotDeleted')
                return $false
            }
        }
        else {
            try {
                if ($parent -and -not (Test-IsProtected -Path $parent)) {
                    Repair-Access -Path $parent -Directory $true
                }
                try {
                    Invoke-DeleteLeaf -Path $Path -Directory $directory -Link $false
                }
                catch {
                    Repair-Access -Path $Path -Directory $directory
                    Invoke-DeleteLeaf -Path $Path -Directory $directory -Link $false
                }
            }
            catch {
                Add-Failure -Path $Path -Message $_.Exception.Message
                return $false
            }
        }
    }

    $script:DeletedCount++
    if ($link) { $script:LinkCount++ }
    return $true
}

function Invoke-Main {
    $script:Phase = T 'PhaseEntry'
    Write-Host (T 'Intro') -ForegroundColor Cyan
    Write-Host (T 'Instructions')
    Write-Host (T 'Protection') -ForegroundColor DarkGray

    $inputs = New-Object 'System.Collections.Generic.List[string]'
    while ($true) {
        $line = Read-Host (T 'PathPrompt')
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        $inputs.Add($line)
        $script:InputCount++
    }
    if ($inputs.Count -eq 0) {
        $script:Result = T 'StatusEmpty'
        $script:Phase = T 'PhaseDone'
        return
    }

    $script:Phase = T 'PhaseValidation'
    $queue = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
    $rejected = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in $inputs) {
        try {
            $path = Get-ValidatedPath -InputPath $candidate
            [void](Get-Attributes -Path $path)
            if ($seen.Add($path)) { $queue.Add($path) }
        }
        catch {
            $rejected.Add("$(T 'PreviewSkip'): $candidate — $($_.Exception.Message)")
        }
    }

    $selected = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in $queue) {
        $nested = $false
        foreach ($other in $queue) {
            if ($candidate -ine $other -and (Test-IsWithin -Path $candidate -Base $other)) {
                $nested = $true
                break
            }
        }
        if (-not $nested) { $selected.Add($candidate) }
    }

    Write-Host "`n$(T 'PreviewTitle')" -ForegroundColor Cyan
    foreach ($path in $selected) {
        $attr = Get-Attributes -Path $path
        $type = if (Test-IsReparsePoint -Attributes $attr) { T 'PreviewLink' } else { T 'PreviewDelete' }
        Write-Host ("{0,-10} {1}" -f $type, $path) -ForegroundColor Yellow
    }
    foreach ($entry in $rejected) { Write-Host $entry -ForegroundColor DarkGray }
    $script:TargetCount = $selected.Count
    $script:SkippedCount = $rejected.Count
    Write-Host (T 'PreviewCounts' -Values @($selected.Count, $rejected.Count))
    if ($selected.Count -eq 0) {
        $script:Result = T 'StatusNoValid'
        $script:Phase = T 'PhaseDone'
        return
    }

    $script:Phase = T 'PhaseConfirmation'
    while ($true) {
        $answer = (Read-Host ((T 'Confirm') + ' ' + (Get-UtilityMessage -Key 'Common.YesNo' -Messages $UtilityMessages))).Trim()
        if ($answer -match '^[YyNn]$') { break }
        Write-Host (Get-UtilityMessage -Key 'Common.InvalidYesNo' -Messages $UtilityMessages) -ForegroundColor Yellow
    }
    if ($answer -ieq 'N') {
        $script:Result = T 'StatusCancelled'
        $script:Phase = T 'PhaseDone'
        return
    }

    $script:Phase = T 'PhaseDeletion'
    foreach ($path in $selected) {
        $script:StartedCount++
        $script:CurrentTarget = $path
        Write-Host "`n$(T 'Removing' -Values @($path))" -ForegroundColor Cyan
        try {
            [void](Get-ValidatedPath -InputPath $path)
            if (Remove-SafeEntry -Path $path) {
                Write-Host (T 'Deleted') -ForegroundColor Green
                $script:TargetsRemoved++
            }
            else {
                $script:TargetsFailed++
                Write-Warning (T 'PartialWarning')
            }
        }
        catch {
            $script:TargetsFailed++
            Add-Failure -Path $path -Message $_.Exception.Message
            Write-Warning (T 'FailedWarning' -Values @($path))
        }
        $script:CurrentTarget = $null
    }

    $script:Result = if ($script:TargetsFailed -eq 0) { Get-UtilityMessage -Key 'Common.Completed' -Messages $UtilityMessages } else { T 'StatusPartial' }
    $script:Phase = T 'PhaseDone'
}

try {
    Invoke-Main
}
catch {
    $script:MainError = $_.Exception.Message
    $script:Result = T 'StatusError'
    Write-Host "`n$script:MainError" -ForegroundColor Red
}
finally {
    # Always show the available summary first, then optionally keep the window open.
    try { Show-Summary }
    finally { Stop-Utility -Context $utility }
}
