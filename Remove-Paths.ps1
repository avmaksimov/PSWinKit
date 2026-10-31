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
$script:DeletedFileCount = 0
$script:FilesInRemovedTargets = 0
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
$script:Confirmed = $false
$script:SelectedTargets = @()
$script:CurrentNumber = $null
$script:DeletedFolderCount = 0
$script:CounterActive = $false
$script:CounterLineLength = 0
$script:CounterStartFiles = 0
$script:CounterStartFolders = 0
$script:CounterStartErrors = 0
$script:CounterWatch = [Diagnostics.Stopwatch]::StartNew()

# Rewrite only the counter line under the current path (up to four times/sec).
function Update-DeletionCounters {
    param([switch]$Force)
    if (-not $script:CounterActive) { return }
    if (-not $Force -and $script:CounterWatch.ElapsedMilliseconds -lt 5000) { return }

    $line = '      ' + (T 'DeleteCounters' -Values @(
        ($script:DeletedFileCount - $script:CounterStartFiles),
        ($script:DeletedFolderCount - $script:CounterStartFolders),
        ($script:FailureCount - $script:CounterStartErrors)))
    $script:CounterLineLength = [Math]::Max($script:CounterLineLength, $line.Length)
    Write-Host ("`r" + $line.PadRight($script:CounterLineLength)) -NoNewline
    $script:CounterWatch.Restart()
}

function Finish-DeletionCounters {
    if (-not $script:CounterActive) { return }
    try { Update-DeletionCounters -Force }
    finally {
        Write-Host ''
        $script:CounterActive = $false
    }
}

function Show-Summary {
    Write-Host "`n$(Get-UtilityMessage -Key 'Common.SummaryTitle' -Messages $UtilityMessages)" -ForegroundColor Cyan
    Write-Host (T 'SummaryResult' -Values @($script:Result))

    # Do not repeat successfully deleted paths. Show only those still remaining,
    # interrupted or not started, keeping the original input numbering.
    if ($script:Confirmed) {
        $incomplete = @($script:SelectedTargets | Where-Object { $_.State -ne 'Removed' })
        if ($incomplete.Count -gt 0) {
            Write-Host (T 'SummaryIncomplete') -ForegroundColor Yellow
            foreach ($item in $incomplete) {
                $statusKey = switch ($item.State) {
                    'Failed'  { 'ItemFailed' }
                    'Started' { 'ItemInterrupted' }
                    default   { 'ItemNotStarted' }
                }
                Write-Host ('{0}. {1} ({2})' -f $item.Number, $item.Path, (T $statusKey)) -ForegroundColor Yellow
            }
        }
        else {
            Write-Host (T 'SummaryNoneIncomplete') -ForegroundColor Green
        }
    }

    if ($script:MainError) { Write-Warning $script:MainError }
    foreach ($failure in $script:FailureSamples) { Write-Warning $failure }
    if ($script:FailureCount -gt $script:FailureSamples.Count) {
        Write-Warning (T 'SummaryTruncated')
    }

    Write-Host (T 'SummaryRemovedTargets' -Values @($script:TargetsRemoved))
    Write-Host (T 'SummaryRemovedFiles' -Values @($script:FilesInRemovedTargets))
    Write-Host (T 'SummarySkipped' -Values @($script:SkippedCount))
    $remaining = [Math]::Max(0, $script:TargetCount - $script:StartedCount)
    if ($remaining -gt 0 -and $script:Confirmed) {
        Write-Host (T 'SummaryUnstarted' -Values @($remaining)) -ForegroundColor Yellow
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
    Update-DeletionCounters
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
    # Only regular files count as files; links are distinct objects.
    if (-not $directory -and -not $link) { $script:DeletedFileCount++ }
    if ($directory -and -not $link) { $script:DeletedFolderCount++ }
    Update-DeletionCounters
    return $true
}

function Invoke-Main {
    $script:Phase = T 'PhaseEntry'
    # Warn before reading even the first path.
    Write-Host ''
    Write-Host ('!' * 68) -ForegroundColor Red
    Write-Host (T 'WarningTitle') -ForegroundColor Red
    Write-Host (T 'WarningPermanence') -ForegroundColor Yellow
    Write-Host (T 'WarningConsequences') -ForegroundColor Yellow
    Write-Host ('!' * 68) -ForegroundColor Red
    Write-Host ''
    Write-Host (T 'Intro') -ForegroundColor Cyan
    Write-Host (T 'Instructions')
    Write-Host (T 'Protection') -ForegroundColor DarkGray

    Write-Host ''
    $inputs = New-Object 'System.Collections.Generic.List[object]'
    while ($true) {
        $number = $inputs.Count + 1
        $line = (Read-Host ('{0}. {1}' -f $number, (T 'PathPrompt'))).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        $inputs.Add([pscustomobject]@{ Number = $number; Raw = $line })
        $script:InputCount++
    }
    if ($inputs.Count -eq 0) {
        $script:Result = T 'StatusEmpty'
        $script:Phase = T 'PhaseDone'
        return
    }

    $script:Phase = T 'PhaseValidation'
    # Keep original numbers, even for duplicates or rejected input.
    $queue = New-Object 'System.Collections.Generic.List[object]'
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)

    foreach ($candidate in $inputs) {
        $entry = [pscustomobject]@{
            Number = $candidate.Number
            Path   = $candidate.Raw
            State  = 'Skipped'
            Reason = ''
        }
        $entries.Add($entry)
        try {
            $path = Get-ValidatedPath -InputPath $candidate.Raw
            $attr = Get-Attributes -Path $path
            $entry.Path = $path
            if ($seen.Add($path)) {
                $entry.State = 'Queued'
                $queue.Add($entry)
            }
            else {
                $entry.Reason = T 'DuplicatePath'
            }
        }
        catch {
            $entry.Reason = $_.Exception.Message
        }
    }

    # If both a directory and one of its descendants are listed, delete only
    # the outer directory. The descendant keeps its original number as skipped.
    $selected = New-Object 'System.Collections.Generic.List[object]'
    foreach ($candidate in $queue) {
        $parent = $null
        foreach ($other in $queue) {
            if ($candidate.Path -ine $other.Path -and
                (Test-IsWithin -Path $candidate.Path -Base $other.Path)) {
                $parent = $other
                break
            }
        }
        if ($null -eq $parent) {
            $selected.Add($candidate)
        }
        else {
            $candidate.State = 'Skipped'
            $candidate.Reason = T 'CoveredByParent' -Values @($parent.Number)
        }
    }

    # Paths are already visible in the numbered input. Do not list them again.
    $script:SelectedTargets = $selected.ToArray()
    $script:TargetCount = $selected.Count
    $script:SkippedCount = $entries.Count - $selected.Count
    Write-Host "`n$(T 'PreviewTitle')" -ForegroundColor Cyan
    Write-Host (T 'PreviewCounts' -Values @($selected.Count, $script:SkippedCount))
    foreach ($entry in $entries) {
        if ($entry.State -eq 'Skipped') {
            Write-Host (T 'PreviewSkippedReason' -Values @($entry.Number, $entry.Reason)) -ForegroundColor DarkGray
        }
    }
    if ($selected.Count -eq 0) {
        $script:Result = T 'StatusNoValid'
        $script:Phase = T 'PhaseDone'
        return
    }

    $script:Phase = T 'PhaseConfirmation'
    Write-Host ''
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
    $script:Confirmed = $true
    foreach ($entry in $selected) {
        $path = $entry.Path
        $script:StartedCount++
        $filesBefore = $script:DeletedFileCount
        $script:CurrentNumber = $entry.Number
        $script:CurrentTarget = $path
        $entry.State = 'Started'
        Write-Host ("`n[{0}/{1}] {2} {3} ..." -f $script:StartedCount, $selected.Count, (T 'Removing'), $path) -ForegroundColor Cyan
        $script:CounterStartFiles = $script:DeletedFileCount
        $script:CounterStartFolders = $script:DeletedFolderCount
        $script:CounterStartErrors = $script:FailureCount
        $script:CounterLineLength = 0
        $script:CounterActive = $true
        $script:CounterWatch.Restart()
        Update-DeletionCounters -Force
        try {
            [void](Get-ValidatedPath -InputPath $path)
            if (Remove-SafeEntry -Path $path) {
                Finish-DeletionCounters
                Write-Host (T 'Deleted') -ForegroundColor Green
                $entry.State = 'Removed'
                $script:TargetsRemoved++
                # Count regular files only inside targets that were fully removed.
                # Partial targets never inflate the completed-file total.
                $script:FilesInRemovedTargets += ($script:DeletedFileCount - $filesBefore)
            }
            else {
                $entry.State = 'Failed'
                $script:TargetsFailed++
                Finish-DeletionCounters
                Write-Warning (T 'PartialWarning')
            }
        }
        catch {
            $entry.State = 'Failed'
            $script:TargetsFailed++
            Add-Failure -Path $path -Message $_.Exception.Message
            Finish-DeletionCounters
            Write-Warning (T 'FailedWarning' -Values @($path))
        }
        finally {
            # Also close the counter line if Ctrl+C interrupts this target.
            Finish-DeletionCounters
        }
        $script:CurrentTarget = $null
        $script:CurrentNumber = $null
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
    Finish-DeletionCounters
    # Always show the available summary first, then optionally keep the window open.
    try { Show-Summary }
    finally { Stop-Utility -Context $utility }
}
