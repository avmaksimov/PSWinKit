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

# Format counts consistently with spaces, regardless of the Windows culture.
function Format-Count {
    param([long]$Value)
    return $Value.ToString('N0', [Globalization.CultureInfo]::InvariantCulture).Replace(',', ' ')
}

# Get-UtilityMessage is provided by the dot-sourced common library.
function T {
    param([string]$Key, [object[]]$Values = @())
    $formatted = @(
        foreach ($value in $Values) {
            if ($value -is [int] -or $value -is [long]) { Format-Count $value }
            else { $value }
        }
    )
    return (Get-UtilityMessage -Key ("RemovePaths.$Key") -Messages $UtilityMessages -Values $formatted)
}


# Regional date/time (including seconds); days in the elapsed time are localized.
$script:StartedAt = Get-Date
$script:RunWatch = [Diagnostics.Stopwatch]::StartNew()
function Format-RegionalDateTime {
    param([datetime]$Value)
    $culture = [Globalization.CultureInfo]::CurrentCulture
    return ($Value.ToString('d', $culture) + ' ' + $Value.ToString('T', $culture))
}
function Format-ElapsedTime {
    param([TimeSpan]$Value)
    $clock = '{0:00}:{1:00}:{2:00}' -f $Value.Hours, $Value.Minutes, $Value.Seconds
    $days = [long][Math]::Floor($Value.TotalDays)
    if ($days -gt 0) {
        $suffix = if ($utility.LanguageFile -match '(?i)[\/]ru(?:-[^\/]+)?\.psd1$') { 'д' } else { 'd' }
        return ((Format-Count $days) + $suffix + ' ' + $clock)
    }
    return $clock
}
Write-Host (T 'StartTime' -Values @((Format-RegionalDateTime $script:StartedAt))) -ForegroundColor DarkGray

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

# Authz is used only for real directories: links are never checked or modified.
# C# is compiled once per PowerShell process; security descriptors come directly from NTFS.
$authzSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;

public static class RemovePathsAuthz {
    [StructLayout(LayoutKind.Sequential)]
    private struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)]
    private struct AUTHZ_ACCESS_REQUEST {
        public uint DesiredAccess;
        public IntPtr PrincipalSelfSid;
        public IntPtr ObjectTypeList;
        public uint ObjectTypeListLength;
        public IntPtr OptionalArguments;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct AUTHZ_ACCESS_REPLY {
        public uint ResultListLength;
        public IntPtr GrantedAccessMask;
        public IntPtr SaclEvaluationResults;
        public IntPtr Error;
    }
    [DllImport("authz.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool AuthzInitializeResourceManager(uint flags, IntPtr a, IntPtr b,
        IntPtr c, string name, out IntPtr resourceManager);
    [DllImport("authz.dll", SetLastError=true)]
    private static extern bool AuthzInitializeContextFromToken(uint flags, IntPtr token,
        IntPtr resourceManager, IntPtr expiry, LUID identifier,
        IntPtr args, out IntPtr clientContext);
    [DllImport("authz.dll")]
    private static extern bool AuthzFreeContext(IntPtr context);
    [DllImport("authz.dll")]
    private static extern bool AuthzFreeResourceManager(IntPtr manager);
    [DllImport("authz.dll", SetLastError=true)]
    private static extern bool AuthzAccessCheck(uint flags, IntPtr context,
        ref AUTHZ_ACCESS_REQUEST request, IntPtr auditEvent,
        IntPtr securityDescriptor, IntPtr additionalDescriptors, uint additionalCount,
        ref AUTHZ_ACCESS_REPLY reply, IntPtr cachedResults);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, EntryPoint="GetNamedSecurityInfoW", ExactSpelling=true)]
    private static extern uint GetNamedSecurityInfoW(string path, uint objectType, uint info,
        out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl,
        out IntPtr descriptor);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr value);
    private static IntPtr manager = IntPtr.Zero;
    private static IntPtr context = IntPtr.Zero;

    public static void Initialize() {
        if (context != IntPtr.Zero) return;
        if (!AuthzInitializeResourceManager(1, IntPtr.Zero, IntPtr.Zero,
            IntPtr.Zero, "Remove-Paths", out manager))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        using (WindowsIdentity identity = WindowsIdentity.GetCurrent()) {
            LUID identifier = new LUID();
            if (!AuthzInitializeContextFromToken(0, identity.Token, manager,
                    IntPtr.Zero, identifier, IntPtr.Zero, out context)) {
                int error = Marshal.GetLastWin32Error();
                AuthzFreeResourceManager(manager);
                manager = IntPtr.Zero;
                throw new Win32Exception(error);
            }
        }
    }
    public static bool HasAccess(string path, uint rights) {
        if (context == IntPtr.Zero) throw new InvalidOperationException("Not initialized");
        IntPtr owner, group, dacl, sacl, descriptor;
        // OWNER + DACL are mandatory for AuthzAccessCheck.
        uint status = GetNamedSecurityInfoW(path, 1, 0x00000005,
            out owner, out group, out dacl, out sacl, out descriptor);
        if (status != 0) return false; // Check unavailable: try ACL correction.
        IntPtr granted = IntPtr.Zero, saclResults = IntPtr.Zero, errors = IntPtr.Zero;
        try {
            granted = Marshal.AllocHGlobal(4);
            saclResults = Marshal.AllocHGlobal(4);
            errors = Marshal.AllocHGlobal(4);
            Marshal.WriteInt32(granted, 0);
            Marshal.WriteInt32(saclResults, 0);
            Marshal.WriteInt32(errors, 0);
            AUTHZ_ACCESS_REQUEST req = new AUTHZ_ACCESS_REQUEST();
            req.DesiredAccess = rights;
            AUTHZ_ACCESS_REPLY reply = new AUTHZ_ACCESS_REPLY();
            reply.ResultListLength = 1;
            reply.GrantedAccessMask = granted;
            reply.SaclEvaluationResults = saclResults;
            reply.Error = errors;
            if (!AuthzAccessCheck(0, context, ref req, IntPtr.Zero, descriptor,
                IntPtr.Zero, 0, ref reply, IntPtr.Zero)) return false;
            if (Marshal.ReadInt32(errors) != 0) return false;
            return (((uint)Marshal.ReadInt32(granted) & rights) == rights);
        }
        finally {
            if (granted != IntPtr.Zero) Marshal.FreeHGlobal(granted);
            if (saclResults != IntPtr.Zero) Marshal.FreeHGlobal(saclResults);
            if (errors != IntPtr.Zero) Marshal.FreeHGlobal(errors);
            if (descriptor != IntPtr.Zero) LocalFree(descriptor);
        }
    }
    public static void Dispose() {
        if (context != IntPtr.Zero) { AuthzFreeContext(context); context = IntPtr.Zero; }
        if (manager != IntPtr.Zero) { AuthzFreeResourceManager(manager); manager = IntPtr.Zero; }
    }
}
'@
$script:AuthzReady = $false
try {
    if (-not ('RemovePathsAuthz' -as [type])) {
        Add-Type -TypeDefinition $authzSource -ErrorAction Stop
    }
    [RemovePathsAuthz]::Initialize()
    $script:AuthzReady = $true
}
catch {
    # Keep the deletion path functional if Authz initialization is unavailable.
    $script:AuthzReady = $false
    Write-Warning (T 'AuthzUnavailable')
}

function Test-DirectoryDeleteAccess {
    param([string]$Path)
    if (-not $script:AuthzReady) { return $true }
    # FILE_LIST_DIRECTORY (1) + FILE_DELETE_CHILD (0x40)
    try { return [RemovePathsAuthz]::HasAccess($Path, [uint32]0x41) }
    catch {
        # Revert to actual operations; never guess that an ACL change is necessary.
        return $true
    }
}

function Grant-ObjectAccess {
    param([string]$Path, [bool]$Directory)
    # Deliberately only THIS object: no OI/CI propagation through the subtree.
    $everyone = [Security.Principal.SecurityIdentifier]::new('S-1-1-0')
    $rights = [Security.AccessControl.FileSystemRights]::FullControl
    $allow = [Security.AccessControl.AccessControlType]::Allow
    if ($Directory) {
        $item = [IO.DirectoryInfo]::new($Path)
        $acl = $item.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $everyone, $rights, [Security.AccessControl.InheritanceFlags]::None,
            [Security.AccessControl.PropagationFlags]::None, $allow)
        $acl.AddAccessRule($rule)
        $item.SetAccessControl($acl)
    }
    else {
        $item = [IO.FileInfo]::new($Path)
        $acl = $item.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($everyone, $rights, $allow)
        $acl.AddAccessRule($rule)
        $item.SetAccessControl($acl)
    }
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
$script:CounterStage = ''
$script:CounterStageKey = ''
$script:CounterLastShownStage = ''
$script:CounterStagesSeen = New-Object 'System.Collections.Generic.HashSet[string]'

# Update the current stage before operations which can take a long time.
function Set-DeletionStage {
    param([string]$Key)
    if (-not $script:CounterActive -or $script:CounterStageKey -eq $Key) { return }
    $script:CounterStageKey = $Key
    $script:CounterStage = T $Key
    $firstTime = $script:CounterStagesSeen.Add($Key)
    if ($firstTime -or
        ($script:CounterStage -ne $script:CounterLastShownStage -and
         $script:CounterWatch.ElapsedMilliseconds -ge 1000)) {
        Update-DeletionCounters -Force
    }
}

# Rewrite only the counter line under the current path (normally every 5 sec).
function Update-DeletionCounters {
    param([switch]$Force)
    if (-not $script:CounterActive) { return }
    if (-not $Force -and $script:CounterWatch.ElapsedMilliseconds -lt 5000) { return }

    $line = '      ' + (T 'DeleteCounters' -Values @(
        ($script:DeletedFileCount - $script:CounterStartFiles),
        ($script:DeletedFolderCount - $script:CounterStartFolders),
        ($script:FailureCount - $script:CounterStartErrors)))
    if ($script:CounterStageKey -in @('StageEnumerating', 'StageOwnership', 'StagePermissions')) {
        $line = '      ' + $script:CounterStage
    }
    $script:CounterLastShownStage = $script:CounterStage
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
                Write-Host ('{0}. {1} ({2})' -f (Format-Count $item.Number), $item.Path, (T $statusKey)) -ForegroundColor Yellow
            }
        }
        else {
            Write-Host (T 'SummaryNoneIncomplete') -ForegroundColor Green
        }
    }

    if ($script:MainError) { Write-Warning $script:MainError }

    Write-Host (T 'SummaryRemovedTargets' -Values @($script:TargetsRemoved))
    Write-Host (T 'SummaryRemovedFiles' -Values @($script:FilesInRemovedTargets))
    Write-Host (T 'SummarySkipped' -Values @($script:SkippedCount))
    $remaining = [Math]::Max(0, $script:TargetCount - $script:StartedCount)
    if ($remaining -gt 0 -and $script:Confirmed) {
        Write-Host (T 'SummaryUnstarted' -Values @($remaining)) -ForegroundColor Yellow
    }
    $finishedAt = Get-Date
    Write-Host (T 'EndTime' -Values @((Format-RegionalDateTime $finishedAt),
        (Format-ElapsedTime $script:RunWatch.Elapsed))) -ForegroundColor DarkGray
}
function Repair-Access {
    param([string]$Path, [bool]$Directory)
    # Never change link security (could refer to another drive), protected paths or roots.
    try {
        $attr = Get-Attributes -Path $Path
        if ((Test-IsReparsePoint -Attributes $attr) -or
            (Test-IsProtected -Path $Path) -or $Path -match '^[A-Za-z]:\\?$') { return $false }
        if ($script:ACLRepaired.Contains($Path)) { return $true }

        # First grant ACL. Only if that fails, take ownership and retry ACL.
        $granted = $false
        Set-DeletionStage -Key 'StagePermissions'
        try { Grant-ObjectAccess -Path $Path -Directory $Directory; $granted = $true }
        catch { }
        if (-not $granted) {
            Set-DeletionStage -Key 'StageOwnership'
            try { & takeown.exe /F $Path /A 2>&1 | Out-Null } catch { }
            Set-DeletionStage -Key 'StagePermissions'
            try { Grant-ObjectAccess -Path $Path -Directory $Directory; $granted = $true }
            catch { }
        }
        if ($granted) {
            [void]$script:ACLRepaired.Add($Path)
            $script:RepairedCount++
        }
        return $granted
    }
    finally { Set-DeletionStage -Key 'StageDeleting' }
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
    if ($script:CounterActive) {
        # Erase the old changing line, print a permanent gray error, resume counters.
        Write-Host ("`r" + (' ' * $script:CounterLineLength) + "`r") -NoNewline
        Write-Host ('      ' + (T 'DeleteFailure' -Values @($Path))) -ForegroundColor DarkGray
        $script:CounterLineLength = 0
        $script:CounterStage = ''
        $script:CounterStageKey = 'StageDeleting'
        Update-DeletionCounters -Force
    }
    else {
        Write-Host (T 'DeleteFailure' -Values @($Path)) -ForegroundColor DarkGray
    }
}

function Remove-SafeEntry {
    param([string]$Path)
    try { $attr = Get-Attributes -Path $Path }
    catch {
        Add-Failure -Path $Path -Message $_.Exception.Message
        return $false
    }
    $directory = (($attr -band [IO.FileAttributes]::Directory) -ne 0)
    $link = Test-IsReparsePoint -Attributes $attr
    $childFailures = $false

    if ($directory -and -not $link) {
        # Check only actual directories, once when entering them (not each file).
        # Any missing LIST_DIRECTORY or DELETE_CHILD rights are fixed locally.
        if (-not (Test-DirectoryDeleteAccess -Path $Path)) {
            [void](Repair-Access -Path $Path -Directory $true)
        }
        Set-DeletionStage -Key 'StageEnumerating'
        try {
            $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
        }
        catch {
            [void](Repair-Access -Path $Path -Directory $true)
            try { $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop) }
            catch {
                Add-Failure -Path $Path -Message $_.Exception.Message
                return $false
            }
        }
        foreach ($child in $children) {
            if (-not (Remove-SafeEntry -Path $child.FullName)) { $childFailures = $true }
        }
        if ($childFailures) { return $false }
    }

    Set-DeletionStage -Key 'StageDeleting'
    # Attempt deletion even after unsuccessful access repair.
    try { Invoke-DeleteLeaf -Path $Path -Directory $directory -Link $link }
    catch {
        $parent = [IO.Path]::GetDirectoryName($Path)
        if ($link) {
            # Reparse points may be unlinked, but NEVER receive changed ACL/owner.
            if ($parent -and -not (Test-IsProtected -Path $parent)) {
                [void](Repair-Access -Path $parent -Directory $true)
            }
        }
        else {
            # For a failed file or empty directory: first use parent's DELETE_CHILD,
            # then this object's ACL, changing owner only when needed.
            if ($parent -and -not (Test-IsProtected -Path $parent)) {
                [void](Repair-Access -Path $parent -Directory $true)
            }
        }
        try { Invoke-DeleteLeaf -Path $Path -Directory $directory -Link $link }
        catch {
            if (-not $link) { [void](Repair-Access -Path $Path -Directory $directory) }
            try { Invoke-DeleteLeaf -Path $Path -Directory $directory -Link $link }
            catch {
                Add-Failure -Path $Path -Message $_.Exception.Message
                return $false
            }
        }
    }

    $script:DeletedCount++
    if ($link) { $script:LinkCount++ }
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
        $line = (Read-Host ('{0}. {1}' -f (Format-Count $number), (T 'PathPrompt'))).Trim()
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
        Write-Host ("`n[{0}/{1}] {2} {3} ..." -f (Format-Count $script:StartedCount), (Format-Count $selected.Count), (T 'Removing'), $path) -ForegroundColor Cyan
        $script:CounterStartFiles = $script:DeletedFileCount
        $script:CounterStartFolders = $script:DeletedFolderCount
        $script:CounterStartErrors = $script:FailureCount
        $script:CounterLineLength = 0
        $script:CounterActive = $true
        $script:CounterStage = ''
        $script:CounterStageKey = ''
        $script:CounterLastShownStage = ''
        $script:CounterStagesSeen.Clear()
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
    finally {
        if ($script:AuthzReady) { [RemovePathsAuthz]::Dispose() }
        Stop-Utility -Context $utility
    }
}
