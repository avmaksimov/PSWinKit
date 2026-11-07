#Requires -Version 5.1
# Optional-partition inspection and separately confirmed deletion.
# Narrow allow-lists for previously inspected legacy boot and Recovery layouts.
# The active Windows RE, EFI, MSR and Windows C: partitions are never deletion candidates.
# An audit is a conservative compatibility check, not proof of absent OEM dependencies.

function Get-CSCleanupCandidateAudit($disk, $c, $part, [string]$kind, $reInfo) {
    $issues = New-Object 'System.Collections.Generic.List[string]'
    $contents = New-Object 'System.Collections.Generic.List[string]'
    $details = New-Object 'System.Collections.Generic.List[string]'
    $hints = New-Object 'System.Collections.Generic.List[string]'
    $out = [pscustomobject]@{
        DiskNumber = [int]$disk.Number
        DiskId = [string]$disk.UniqueId
        Number = [int]$part.PartitionNumber
        Offset = [int64]$part.Offset
        Size = [int64]$part.Size
        GptType = (Get-GptId $part)
        PartitionGuid = [string]$part.Guid
        DriveLetter = [string]$part.DriveLetter
        Kind = $kind
        Permitted = $false
        Contents = $contents
        Details = $details
        Hints = $hints
        Issues = $issues
        Signature = ''
    }
    if ([string]$disk.PartitionStyle -ne 'GPT' -or $disk.IsOffline -or $disk.IsReadOnly) {
        $issues.Add($m.CS28UnsafeDisk)
    }
    if ($part.IsSystem -or $part.IsBoot -or $part.IsActive -or
        [int64]$part.Size -le 0 -or [int]$part.PartitionNumber -eq [int]$c.PartitionNumber) {
        $issues.Add($m.CS28ProtectedPartition)
    }
    if ($null -eq $reInfo -or -not $reInfo.Enabled -or
        [int]$reInfo.DiskNumber -ne [int]$disk.Number) {
        $issues.Add($m.CS28WinReNotEnabled)
    }
    if ($null -ne $reInfo -and $null -ne $reInfo.PartitionNumber -and
        [int]$reInfo.PartitionNumber -eq [int]$part.PartitionNumber) {
        $issues.Add($m.CS28ProtectedPartition)
    }
    $root = $null
    $mounted = $false
    try {
        if ($kind -eq 'RecoveryOther') {
            if ($out.GptType -ne $script:RecoveryGuid -or $part.DriveLetter) {
                $issues.Add($m.CS28WrongPartitionType)
            } else {
                $root = Open-CSRecoveryMount ([int]$disk.Number) ([int]$part.PartitionNumber)
                $mounted = $true
            }
        } elseif ($kind -eq 'Data') {
            # Only a very small, lettered basic-data volume before C:.
            # Any real content prevents deletion, including installation files.
            if ($out.GptType -ne 'EBD0A0A2-B9E5-4433-87C0-68B6B72699C7' -or
                -not $part.DriveLetter -or [int64]$part.Size -gt 128MB -or
                [int64]$part.Offset -ge [int64]$c.Offset -or
                ([string]$part.DriveLetter).ToUpperInvariant() -eq 'C') {
                $issues.Add($m.CS28WrongPartitionType)
            } else {
                $letter = ([string]$part.DriveLetter).ToUpperInvariant()
                $root = $letter + ':\'
                if (-not [IO.Directory]::Exists($root)) {
                    $issues.Add($m.CS28NoAccess)
                }
                # A paging file or a BCD reference to this volume is disqualifying.
                try {
                    foreach ($pg in @(Get-CimInstance Win32_PageFileUsage -ErrorAction Stop)) {
                        if ([string]$pg.Name -match ('(?i)^' + [regex]::Escape($letter) + ':\\')) {
                            $issues.Add($m.CS28PageFileUsed)
                        }
                    }
                    foreach ($pg in @(Get-CimInstance Win32_PageFileSetting -ErrorAction Stop)) {
                        if ([string]$pg.Name -match ('(?i)^' + [regex]::Escape($letter) + ':\\')) {
                            $issues.Add($m.CS28PageFileUsed)
                        }
                    }
                } catch { $issues.Add($m.CS28SystemUsageUnknown) }
                try {
                    $bcd = (& bcdedit.exe /enum all /v 2>&1 | Out-String)
                    if ($LASTEXITCODE -ne 0) { throw 'BCD read failed.' }
                    if ($bcd -match ('(?i)(partition\s*=|ramdisk\s*=\s*\[?)' +
                        [regex]::Escape($letter) + ':')) {
                        $issues.Add($m.CS28BootReference)
                    }
                } catch { $issues.Add($m.CS28SystemUsageUnknown) }
                # The legacy-boot exception is deliberately narrower than
                # the generic small-data-volume candidate rule. The current
                # Windows installation MUST boot from a DIFFERENT EFI system
                # partition. Do not confuse HarddiskVolumeN with GPT partition N.
                try {
                    $volume = Get-Volume -Partition $part -ErrorAction Stop
                    if ([string]$volume.FileSystem -ne 'NTFS' -or
                        [string]$volume.FileSystemLabel -notin @('Зарезервировано системой','System Reserved') -or
                        [int64]$part.Size -ne 50MB) {
                        $issues.Add($m.CS283LegacyVolumeNotMatch)
                    }
                    $systemParts = @(Get-Partition -DiskNumber ([int]$disk.Number) -ErrorAction Stop |
                        Where-Object { $_.IsSystem })
                    if ($systemParts.Count -ne 1 -or
                        (Get-GptId $systemParts[0]) -ne 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B' -or
                        [int]$systemParts[0].PartitionNumber -eq [int]$part.PartitionNumber) {
                        $issues.Add($m.CS283UefiUnverified)
                    }
                    $bootManager = (& bcdedit.exe /enum '{bootmgr}' /v 2>&1 | Out-String)
                    if ($LASTEXITCODE -ne 0 -or
                        $bootManager -notmatch '(?i)\\EFI\\MICROSOFT\\BOOT\\BOOTMGFW\.EFI') {
                        $issues.Add($m.CS283UefiUnverified)
                    }
                } catch { $issues.Add($m.CS283UefiUnverified) }
            }
        } else {
            $issues.Add($m.CS28WrongPartitionType)
        }
        if ($root -and [IO.Directory]::Exists($root)) {
            $top = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop)
            foreach ($entry in $top) {
                if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $issues.Add(($m.CS28LinkDetected -f $entry.Name))
                    continue
                }
                if ($entry.PSIsContainer -and
                    $entry.Name -in @('System Volume Information','$RECYCLE.BIN')) {
                    $contents.Add(($m.CS28SystemDirectory -f $entry.Name))
                    continue
                }
                $contents.Add($entry.Name)
                if ($kind -eq 'Data') {
                    # Permit ONLY the three observed BIOS-era boot files, as
                    # ordinary files, on the tightly verified legacy volume.
                    # Any subdirectory (including Boot\BCD), unknown file or
                    # link blocks deletion, even if the label matched.
                    if ($entry.PSIsContainer -or
                        $entry.Name -notin @('bootmgr','BOOTNXT','BOOTSECT.BAK')) {
                        $issues.Add(($m.CS28ContainsData -f $entry.Name))
                    }
                } elseif ($entry.Name -ne 'Recovery' -or -not $entry.PSIsContainer) {
                    $issues.Add(($m.CS28UnexpectedContent -f $entry.Name))
                }
            }
            if ($kind -eq 'Data' -and
                @($top | Where-Object { -not $_.PSIsContainer -and
                    $_.Name -in @('bootmgr','BOOTNXT','BOOTSECT.BAK') }).Count -gt 0) {
                if ($issues.Count -eq 0) { $hints.Add($m.CS283LegacyMatched) }
                else { $hints.Add($m.CS282LegacyBootHint) }
            }
            if ($kind -eq 'RecoveryOther' -and
                (Test-Path -LiteralPath (Join-Path $root 'Recovery') -PathType Container)) {
                $rdir = Join-Path $root 'Recovery'
                $rdirItem = Get-Item -LiteralPath $rdir -Force -ErrorAction Stop
                if (($rdirItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $issues.Add(($m.CS28LinkDetected -f 'Recovery'))
                } else {
                foreach ($entry in @(Get-ChildItem -LiteralPath $rdir -Force -ErrorAction Stop)) {
                    if ($entry.Name -ne 'WindowsRE' -or -not $entry.PSIsContainer -or
                        (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                        # The only recognized non-WindowsRE directory is a
                        # legacy Logs folder containing Reload.xml alone.
                        # Validate its full immediate contents; any other
                        # file/subdirectory/link, or an unreadable folder, blocks.
                        $recognizedLogs = ($entry.Name -eq 'Logs' -and $entry.PSIsContainer -and
                            (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0))
                        if (-not $recognizedLogs) {
                            $issues.Add(($m.CS28UnexpectedContent -f ('Recovery\' + $entry.Name)))
                        }
                        # Enumerate the Logs tree without opening reparse points.
                        if ($recognizedLogs) {
                            $logContents = @(Get-ChildItem -LiteralPath $entry.FullName -Force -ErrorAction Stop)
                            if ($logContents.Count -ne 1 -or $logContents[0].PSIsContainer -or
                                $logContents[0].Name -ne 'Reload.xml' -or
                                (($logContents[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
                                [int64]$logContents[0].Length -gt 64KB) {
                                $issues.Add(($m.CS28UnexpectedContent -f 'Recovery\Logs'))
                                $hints.Add($m.CS282LogsHint)
                            } else {
                                $hints.Add($m.CS283LogsMatched)
                            }
                            $queue = New-Object 'System.Collections.Generic.Queue[object]'
                            $queue.Enqueue([pscustomobject]@{
                                Path = [string]$entry.FullName
                                Relative = 'Recovery\Logs'
                                Depth = 0
                            })
                            $scanned = 0
                            while ($queue.Count -gt 0 -and $scanned -lt 200) {
                                $node = $queue.Dequeue()
                                foreach ($logItem in @(Get-ChildItem -LiteralPath $node.Path -Force -ErrorAction Stop)) {
                                    $scanned++
                                    $relative = [string]$node.Relative + '\' + [string]$logItem.Name
                                    $contents.Add($relative)
                                    if (($logItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                                        $issues.Add(($m.CS28LinkDetected -f $relative))
                                        continue
                                    }
                                    if ($logItem.PSIsContainer) {
                                        $details.Add(($m.CS282FoundDirectory -f $relative))
                                        if ([int]$node.Depth -lt 3) {
                                            $queue.Enqueue([pscustomobject]@{
                                                Path = [string]$logItem.FullName
                                                Relative = $relative
                                                Depth = [int]$node.Depth + 1
                                            })
                                        } else {
                                            $issues.Add(($m.CS282InspectionLimit -f $relative))
                                        }
                                    } else {
                                        $details.Add(($m.CS282FoundFile -f $relative,
                                            ([math]::Round(([double]$logItem.Length / 1KB), 1))))
                                    }
                                    if ($scanned -ge 200) { break }
                                }
                            }
                            if ($queue.Count -gt 0 -or $scanned -ge 200) {
                                $issues.Add(($m.CS282InspectionLimit -f 'Recovery\Logs'))
                            }
                            if ($scanned -eq 0) { $details.Add($m.CS282EmptyLogs) }
                        }
                    }
                }
                $winreFolder = Join-Path $rdir 'WindowsRE'
                if (Test-Path -LiteralPath $winreFolder -PathType Container) {
                    $winreItem = Get-Item -LiteralPath $winreFolder -Force -ErrorAction Stop
                    if (($winreItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        $issues.Add(($m.CS28LinkDetected -f 'Recovery\WindowsRE'))
                    } else {
                    $approvedNames = @('Winre.wim','ReAgent.xml','boot.sdi',
                        'SrSettings.ini','WifiSettings.ini','ReCustomization.xml','ReAgent.old')
                    foreach ($entry in @(Get-ChildItem -LiteralPath $winreFolder -Force -ErrorAction Stop)) {
                        $relative = 'Recovery\WindowsRE\' + $entry.Name
                        $contents.Add($relative)
                        if ($entry.PSIsContainer -or $entry.Name -notin $approvedNames -or
                            (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                            $issues.Add(($m.CS28UnexpectedContent -f $relative))
                        }
                    }
                    }
                }
                }
            }
        }
    } catch {
        $issues.Add(($m.CS28InspectionError -f $_.Exception.Message))
    } finally {
        if ($mounted -or $script:CSExecMount) {
            try { Close-CSRecoveryMount ([int]$disk.Number) }
            catch { $issues.Add(($m.CS28InspectionError -f $_.Exception.Message)) }
        }
    }
    $out.Permitted = ($issues.Count -eq 0)
    # A lightweight fingerprint; each candidate is re-inspected before deletion.
    $out.Signature = @($contents.ToArray() | Sort-Object) -join '|'
    return $out
}

function Show-CSCleanupCandidateAudit($audit) {
    Write-Host ($m.CS28AuditHeader -f $audit.Number, (Format-PartitionSize $audit.Size)) -ForegroundColor Cyan
    if ($audit.Contents.Count -eq 0) {
        Write-Host ('  ' + $m.CS28AppearsEmpty)
    } else {
        foreach ($item in @($audit.Contents.ToArray() | Select-Object -First 12)) {
            Write-Host ('  ' + $item)
        }
        if ($audit.Contents.Count -gt 12) {
            Write-Host ('  ' + ($m.CS28MoreEntries -f ($audit.Contents.Count - 12)))
        }
    }
    foreach ($detail in @($audit.Details.ToArray() | Select-Object -First 30)) {
        Write-Host ('    ' + $detail) -ForegroundColor DarkGray
    }
    if ($audit.Details.Count -gt 30) {
        Write-Host ('    ' + ($m.CS28MoreEntries -f ($audit.Details.Count - 30))) -ForegroundColor DarkGray
    }
    foreach ($hint in $audit.Hints.ToArray()) {
        Write-Host ('  ' + $hint) -ForegroundColor DarkYellow
    }
    if ($audit.Permitted) {
        Write-Host ('  ' + $m.CS28Eligible) -ForegroundColor Yellow
    } else {
        Write-Host ('  ' + $m.CS28Blocked) -ForegroundColor Red
        foreach ($issue in @($audit.Issues.ToArray() | Select-Object -Unique | Select-Object -First 8)) {
            Write-Host ('  ' + $issue) -ForegroundColor Yellow
        }
    }
}

function Invoke-CSOptionalDiskPart([string[]]$commands) {
    # Core execution deletes its staging folder after success. Never depend
    # on that now-removed directory for optional deletion commands.
    $base = Join-Path $env:ProgramData 'PSWinKit\Check-SystemPartitions'
    $folder = Join-Path $base ('DiskPart-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop)
    try {
        Protect-CSStagingDirectory $folder
        $path = Join-Path $folder 'commands.txt'
        [IO.File]::WriteAllLines($path, $commands, [Text.Encoding]::ASCII)
        & diskpart.exe /s $path | Out-Host
        if ($LASTEXITCODE -ne 0) { throw $m.CSExecDiskPartFailed }
    } finally {
        if (Test-Path -LiteralPath $folder -PathType Container) {
            Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop
        }
    }
}

function Invoke-CSOptionalPartitionDeletion($disk, $c, $audits, [switch]$BackupAlreadyConfirmed) {
    if ($audits.Count -eq 0) { return }
    foreach ($audit in $audits) {
        if (-not $audit.Permitted) { throw ($m.CS28BlockedExecution -f $audit.Number) }
    }
    if (-not $BackupAlreadyConfirmed) {
        Write-Host $m.CSExecNeedBackup -ForegroundColor Yellow
        if (-not (Read-YesNo $m.CSExecBackupConfirmed)) {
            Write-Host $m.CSExecCancelled -ForegroundColor Yellow
            return
        }
    }
    Write-Host $m.CS28DeletionFinalWarning -ForegroundColor Red
    if (-not (Read-YesNo $m.CS28DeletionFinalQuestion)) {
        Write-Host $m.CSExecCancelled -ForegroundColor Yellow
        return
    }
    foreach ($audit in $audits) {
        $freshDisk = Get-Disk -Number ([int]$audit.DiskNumber) -ErrorAction Stop
        if ([string]$freshDisk.UniqueId -ne $audit.DiskId -or
            [string]$freshDisk.PartitionStyle -ne 'GPT') { throw $m.CSExecLayoutChanged }
        $current = @(Get-Partition -DiskNumber ([int]$audit.DiskNumber) -ErrorAction Stop |
            Where-Object { [int64]$_.Offset -eq [int64]$audit.Offset -and
                [int64]$_.Size -eq [int64]$audit.Size -and
                (Get-GptId $_) -eq $audit.GptType -and
                [string]$_.Guid -eq $audit.PartitionGuid })
        if ($current.Count -ne 1) { throw $m.CSExecLayoutChanged }
        $candidate = $current[0]
        $liveC = Get-Partition -DriveLetter C -ErrorAction Stop
        if ([int]$liveC.DiskNumber -ne [int]$audit.DiskNumber -or
            [int64]$liveC.Offset -ne [int64]$c.Offset) { throw $m.CSExecLayoutChanged }
        $liveRE = Get-WinReSnapshot
        if (-not $liveRE.Enabled -or [int]$liveRE.DiskNumber -ne [int]$audit.DiskNumber -or
            [int]$liveRE.PartitionNumber -eq [int]$candidate.PartitionNumber) {
            throw $m.CS28WinReNotEnabled
        }
        # Re-inspect after core repair and after any preceding deletion.
        $check = Get-CSCleanupCandidateAudit $freshDisk $liveC $candidate $audit.Kind $liveRE
        if (-not $check.Permitted -or $check.Signature -cne $audit.Signature -or
            $check.GptType -ne $audit.GptType -or
            $check.Offset -ne $audit.Offset -or $check.Size -ne $audit.Size -or
            $check.PartitionGuid -ne $audit.PartitionGuid) {
            throw $m.CS28AuditChanged
        }
        if (-not (Read-YesNo ($m.CS28DeleteOneQuestion -f $candidate.PartitionNumber,
                (Format-PartitionSize ([int64]$candidate.Size))))) {
            Write-Host $m.CSExecCancelled -ForegroundColor Yellow
            continue
        }
        Write-Host ($m.CS28Deleting -f $candidate.PartitionNumber) -ForegroundColor Yellow
        if ($audit.Kind -eq 'Data') {
            # No force/override on basic data volumes.
            Remove-Partition -DiskNumber ([int]$audit.DiskNumber) -PartitionNumber ([int]$candidate.PartitionNumber) `
                -Confirm:$false -ErrorAction Stop
        } elseif ($audit.Kind -eq 'RecoveryOther') {
            Invoke-CSOptionalDiskPart @("select disk $($audit.DiskNumber)",
                "select partition $($candidate.PartitionNumber)",'delete partition override')
        } else { throw $m.CS28WrongPartitionType }
        $remaining = @(Get-Partition -DiskNumber ([int]$audit.DiskNumber) -ErrorAction Stop |
            Where-Object { [int64]$_.Offset -eq [int64]$audit.Offset })
        if ($remaining.Count -gt 0) { throw $m.CS28DeletionFailed }
        $afterRE = Get-WinReSnapshot
        if (-not $afterRE.Enabled -or [int]$afterRE.DiskNumber -ne [int]$audit.DiskNumber) {
            throw $m.CS28WinReNotEnabled
        }
        Write-Host ($m.CS28Deleted -f $candidate.PartitionNumber) -ForegroundColor Green
    }
}
