#Requires -Version 5.1
# Common Windows installation ISO index. Dot-source from a utility; no work on import.
# All participating Windows/SMB clients use the same PSWinKit\Data directory.
# Cache is advisory: neither failure to save nor failure to merge blocks a repair.

Set-StrictMode -Version 2.0

# Capture the module location on import; do not depend on the caller's working dir.
$script:PSWinKitImageCatalogDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Data'))

function Get-PSWinKitImageCatalogDirectory {
    return $script:PSWinKitImageCatalogDirectory
}

function Get-PSWinKitImageCatalogHost([string]$path) {
    if ($path -match '^\\\\[^\\]+\\[^\\]+(?:\\|$)') { return '' }
    return [string]$env:COMPUTERNAME
}

function Resolve-PSWinKitISOPath([string]$path) {
    $full = [IO.Path]::GetFullPath($path)
    # A mapped drive must not be confused with an identically lettered local
    # drive on another machine. Prefer its stable UNC provider root.
    if ($full -match '^([A-Za-z]):\\') {
        $letter = $matches[1].ToUpperInvariant()
        try {
            $drive = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}:'" -f $letter) -ErrorAction Stop
            $provider = [string]$drive.ProviderName
            if ($provider -match '^\\\\[^\\]+\\[^\\]+') {
                $suffix = $full.Substring(3)
                return (Join-Path $provider $suffix)
            }
        } catch { } # An ordinary local drive does not need CIM to work.
    }
    return $full
}

function Test-PSWinKitImageCatalogFileName([string]$name, [string]$extension) {
    $pattern = '^images_([0-9a-fA-F]{32})\.' + [regex]::Escape($extension) + '$'
    return ($name -cmatch $pattern)
}

function ConvertTo-PSWinKitCatalogEntry($source) {
    if ($null -eq $source) { return $null }
    $path = [string]$source.path
    if ([string]::IsNullOrWhiteSpace($path) -or $path -notmatch '(?i)\.iso$' -or
        -not [IO.Path]::IsPathRooted($path)) { return $null }
    $size = [int64]0
    if (-not [int64]::TryParse(([string]$source.fileSize), [ref]$size) -or $size -lt 1) { return $null }
    $stamp = [string]$source.lastWriteUtc
    $checked = [string]$source.checkedUtc
    $date = [datetime]::MinValue
    if (-not [datetime]::TryParse($stamp, [ref]$date) -or
        -not [datetime]::TryParse($checked, [ref]$date)) { return $null }
    $hostName = [string]$source.host
    if ($path -match '^\\\\[^\\]+\\[^\\]+(?:\\|$)') { $hostName = '' }
    elseif ([string]::IsNullOrWhiteSpace($hostName)) { return $null }
    $indexes = @()
    foreach ($item in @($source.indexes)) {
        if ($null -eq $item) { continue }
        $number = [int]0
        $build = [int]0
        if (-not [int]::TryParse(([string]$item.index), [ref]$number) -or $number -lt 1 -or
            -not [int]::TryParse(([string]$item.build), [ref]$build) -or $build -lt 1) { continue }
        $indexes += [pscustomobject]@{
            index = $number; name = [string]$item.name; editionId = [string]$item.editionId
            build = $build; architecture = [string]$item.architecture
            installationType = [string]$item.installationType; language = [string]$item.language
        }
    }
    if ($indexes.Count -eq 0) { return $null }
    return [pscustomobject]@{
        path = $path; host = $hostName; fileSize = $size
        lastWriteUtc = $stamp; checkedUtc = $checked; indexes = @($indexes)
    }
}

function Read-PSWinKitImageCatalogFile([string]$path) {
    $raw = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    $doc = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    if ($null -eq $doc -or [int]$doc.schemaVersion -ne 1 -or
        $null -eq $doc.images) { throw ('Invalid image catalog schema: ' + $path) }
    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in @($doc.images)) {
        $valid = ConvertTo-PSWinKitCatalogEntry $item
        if ($null -eq $valid) { throw ('Invalid image catalog entry: ' + $path) }
        $result.Add($valid)
    }
    return @($result.ToArray())
}

function Get-PSWinKitImageCatalogParts([string]$directory) {
    if (-not [IO.Directory]::Exists($directory)) { return @() }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($file in [IO.Directory]::EnumerateFiles($directory, 'images_*.json', [IO.SearchOption]::TopDirectoryOnly)) {
        if (Test-PSWinKitImageCatalogFileName ([IO.Path]::GetFileName($file)) 'json') {
            $parts.Add($file)
        }
    }
    return @($parts.ToArray() | Sort-Object)
}

function Merge-PSWinKitImageCatalogEntries([object[]]$entries) {
    # One source per normalized path and machine; a changed ISO replaces its
    # older metadata. Repeated identical entries merge their image indexes.
    $byPath = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($entries)) {
        $item = ConvertTo-PSWinKitCatalogEntry $entry
        if ($null -eq $item) { continue }
        $key = [string]$item.host + '|' + [string]$item.path
        if (-not $byPath.ContainsKey($key)) {
            $byPath.Add($key, $item)
            continue
        }
        $old = $byPath[$key]
        $sameImage = ([int64]$old.fileSize -eq [int64]$item.fileSize -and
            [string]$old.lastWriteUtc -eq [string]$item.lastWriteUtc)
        $oldDate = [datetime]::Parse([string]$old.checkedUtc)
        $newDate = [datetime]::Parse([string]$item.checkedUtc)
        if (-not $sameImage) {
            if ($newDate -ge $oldDate) { $byPath[$key] = $item }
            continue
        }
        $unique = @{}
        foreach ($idx in @($old.indexes) + @($item.indexes)) {
            $idxKey = [string]$idx.index
            if (-not $unique.ContainsKey($idxKey) -or $newDate -ge $oldDate) {
                $unique[$idxKey] = $idx
            }
        }
        $latest = if ($newDate -ge $oldDate) { $item } else { $old }
        $latest.indexes = @($unique.Values | Sort-Object index)
        $byPath[$key] = $latest
    }
    return @($byPath.Values | Sort-Object host,path)
}

function Get-PSWinKitImageCatalogEntries {
    $script:PSWinKitImageCatalogReadErrors = @()
    $directory = Get-PSWinKitImageCatalogDirectory
    if (-not [IO.Directory]::Exists($directory)) { return @() }
    $all = New-Object 'System.Collections.Generic.List[object]'
    $paths = @((Join-Path $directory 'images.json')) + @(Get-PSWinKitImageCatalogParts $directory)
    foreach ($path in $paths) {
        if (-not [IO.File]::Exists($path)) { continue }
        try {
            foreach ($item in @(Read-PSWinKitImageCatalogFile $path)) { $all.Add($item) }
        } catch {
            # A damaged fragment is retained for inspection and cannot stop ISO discovery.
            $script:PSWinKitImageCatalogReadErrors += $path
            Write-Verbose ('Unreadable image catalog {0}: {1}' -f $path, $_.Exception.Message)
        }
    }
    return @(Merge-PSWinKitImageCatalogEntries $all.ToArray())
}

function Enter-PSWinKitImageCatalogLock([string]$directory, [bool]$exclusive) {
    $lockPath = Join-Path $directory 'images.lock'
    # Create only once. Creating a lock file does not acquire a logical lock.
    if (-not [IO.File]::Exists($lockPath)) {
        try {
            $initial = [IO.FileStream]::new($lockPath,
                [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            $initial.Dispose()
        } catch [IO.IOException] {
            if (-not [IO.File]::Exists($lockPath)) { throw }
        }
    }
    $access = if ($exclusive) { [IO.FileAccess]::ReadWrite } else { [IO.FileAccess]::Read }
    $share = if ($exclusive) { [IO.FileShare]::None } else { [IO.FileShare]::Read }
    return ([IO.FileStream]::new($lockPath, [IO.FileMode]::Open, $access, $share))
}

function Write-PSWinKitImageCatalogDocument([string]$path, [object[]]$entries) {
    $json = ConvertTo-Json -InputObject ([ordered]@{
        schemaVersion = 1
        images = @($entries)
    }) -Depth 8 -ErrorAction Stop
    $utf8 = [Text.UTF8Encoding]::new($false)
    $bytes = $utf8.GetBytes($json + "`n")
    $stream = [IO.FileStream]::new($path, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
    # Validate content, not merely ConvertTo-Json successful serialization.
    [void]@(Read-PSWinKitImageCatalogFile $path)
}

function Add-PSWinKitImageCatalogISO([string]$path, [object[]]$indexes) {
    if (-not [IO.File]::Exists($path)) { throw 'ISO source is not accessible.' }
    $full = Resolve-PSWinKitISOPath $path
    $info = [IO.FileInfo]::new($path)
    $entry = ConvertTo-PSWinKitCatalogEntry ([pscustomobject]@{
        path = $full
        host = (Get-PSWinKitImageCatalogHost $full)
        fileSize = [int64]$info.Length
        lastWriteUtc = $info.LastWriteTimeUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        checkedUtc = [datetime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        indexes = @($indexes)
    })
    if ($null -eq $entry) { throw 'Invalid verified ISO metadata.' }
    $directory = Get-PSWinKitImageCatalogDirectory
    [void][IO.Directory]::CreateDirectory($directory)
    $guard = Enter-PSWinKitImageCatalogLock $directory $false
    try {
        $id = [guid]::NewGuid().ToString('N')
        $temporary = Join-Path $directory ('images_' + $id + '.tmp')
        $published = Join-Path $directory ('images_' + $id + '.json')
        Write-PSWinKitImageCatalogDocument $temporary @($entry)
        # Same-directory Move is atomic on a compatible local / SMB filesystem.
        [IO.File]::Move($temporary, $published)
    } finally { $guard.Dispose() }
}

function Merge-PSWinKitImageCatalog {
    $directory = Get-PSWinKitImageCatalogDirectory
    if (-not [IO.Directory]::Exists($directory)) { return }
    $guard = Enter-PSWinKitImageCatalogLock $directory $true
    try {
        $main = Join-Path $directory 'images.json'
        $parts = @(Get-PSWinKitImageCatalogParts $directory)
        if ($parts.Count -gt 0) {
            $records = New-Object 'System.Collections.Generic.List[object]'
            if ([IO.File]::Exists($main)) {
                # Fail closed if main index is corrupt: never overwrite it.
                foreach ($record in @(Read-PSWinKitImageCatalogFile $main)) { $records.Add($record) }
            }
            $processed = New-Object 'System.Collections.Generic.List[string]'
            foreach ($part in $parts) {
                try {
                    foreach ($record in @(Read-PSWinKitImageCatalogFile $part)) { $records.Add($record) }
                    $processed.Add($part)
                } catch { # Retain corrupt fragments for inspection.
                    Write-Verbose ('Preserved invalid image catalog fragment: ' + $part)
                }
            }
            if ($processed.Count -gt 0) {
                $combined = @(Merge-PSWinKitImageCatalogEntries $records.ToArray())
                $tempName = Join-Path $directory ('images_' + [guid]::NewGuid().ToString('N') + '.tmp')
                try {
                    Write-PSWinKitImageCatalogDocument $tempName $combined
                    if ([IO.File]::Exists($main)) {
                        [IO.File]::Replace($tempName, $main, $null)
                    } else {
                        [IO.File]::Move($tempName, $main)
                    }
                    # Do not delete fragments until the replaced main is valid.
                    [void]@(Read-PSWinKitImageCatalogFile $main)
                    foreach ($processedPart in $processed) { [IO.File]::Delete($processedPart) }
                } finally {
                    if ([IO.File]::Exists($tempName)) {
                        # A failed replace must not destroy the only usable fragment.
                        # The original GUID .json files are still present.
                        [IO.File]::Delete($tempName)
                    }
                }
            }
        }
        # No writer can be between publishing .tmp and .json while we own the
        # exclusive lock. All stranded GUID .tmp are therefore safe to remove.
        foreach ($temp in [IO.Directory]::EnumerateFiles($directory, 'images_*.tmp',
                [IO.SearchOption]::TopDirectoryOnly)) {
            if (Test-PSWinKitImageCatalogFileName ([IO.Path]::GetFileName($temp)) 'tmp') {
                [IO.File]::Delete($temp)
            }
        }
    } finally { $guard.Dispose() }
}
