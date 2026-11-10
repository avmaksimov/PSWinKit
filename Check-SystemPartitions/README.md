# Check-SystemPartitions

**English** | [Русский](README.ru.md)

**Check-SystemPartitions** builds on the idea behind [Check-WinRE](../Check-WinRE/README.md). While Check-WinRE focuses on checking and, if necessary, restoring the Windows Recovery Environment (WinRE), Check-SystemPartitions examines the system disk layout, checks WinRE health, and proposes partition optimization, including removal of unnecessary partitions.

## Features

- Lists partitions in physical order, including unallocated gaps.
- Locates and validates `Winre.wim`, measures used and available Recovery space, and can propose enlarging and rebuilding Recovery by adjusting C: while preserving the WinRE image and configuration.
- When WinRE is disabled, can register a **validated image on an existing Recovery partition** without repartitioning, but only on the **same physical disk as Windows**, with enough partition capacity and free space. These conditions are rechecked before enabling WinRE.
- Supports creation of a missing Recovery on GPT and constrained MBR scenarios: migrating working WinRE from C: to a new Recovery partition, or creating Recovery for disabled WinRE when the disk layout meets all safety checks.
- Audits potentially obsolete system and Recovery partitions. Deletion is offered only after checking contents and boot dependencies; each deletion requires separate confirmation.
- Where feasible, **aligns the C: capacity displayed in File Explorer to a multiple of 10 GiB** (for example, 130 or 140 GiB). A purely cosmetic adjustment is limited to **256 MiB** and must not compromise the Recovery free-space requirement. Fixing an undersized Recovery takes priority over a round number.

The target is based on the actual NTFS volume capacity, not just partition geometry. Windows partition alignment and filesystem overhead are also considered, so the partition's raw size may differ slightly from the round value shown by File Explorer.

## Run

From the PSWinKit root in Windows PowerShell 5.1:

```powershell
.\Check-SystemPartitions\Check-SystemPartitions.ps1
```

No required parameters. The interactive workflow is: diagnose → propose changes → validate → confirm individual operations → execute → summarize actual results. If no changes are needed, the tool exits without repartitioning.

## Module responsibilities

| File | Responsibility |
|---|---|
| `Check-SystemPartitions.ps1` | Entry point, disk diagnostics, physical partition table, workflow selection, confirmations, and final results. |
| `Planning.ps1` | **Read-only** analysis: Recovery identification, `Winre.wim` validation, GPT/MBR geometry and capacity calculations, and safe planning; includes disabled-WinRE assessment. |
| `Execution.ps1` | Preflight safety checks, staging and backups, C:/Recovery modifications, REAgentC registration, and final verification; also enables WinRE in-place when a suitable Recovery already exists. |
| `IsoWinRE.ps1` | Detects installation media, selects image indexes, extracts `Winre.wim` with 7-Zip or DISM. |
| `Cleanup.ps1` | Audits obsolete partition candidates, boot dependencies, content safety, and individual deletion confirmations. |
| `../Common/Common.ps1` | Shared launch, elevation, localization, and exit/duration handling. |
| `../Common/Languages/en.psd1`, `ru.psd1` | English and Russian localized messages. |

The entry script dot-sources the other modules. `RecoveryRepair.ps1` is no longer required: its planning and execution functions have been moved into the corresponding existing modules.

## Scope and safety

**Warning:** changing system partitions can cause data loss or prevent Windows from starting. Have a verified, restorable full-disk image before proceeding. **There is no automatic rollback.**

- Resizing and rebuilding an existing active Recovery primarily targets GPT disks with Windows on NTFS C: and a Recovery partition immediately after C:.
- **If WinRE is disabled and an existing Recovery is undersized**, the tool reports the condition but **does not automatically repartition that inactive Recovery**. In-place registration is available only when a validated image resides on a sufficiently large Recovery on the same physical Windows disk.
- Replacing a missing or corrupted `Winre.wim` on an existing Recovery is not yet supported. This does not prevent separate missing-Recovery creation with a validated local image or installation ISO.
- Creating Recovery on MBR is subject to additional safeguards: basic disk, no extended/logical partitions, an available primary partition entry, unambiguous registration, and safe geometry.
- EFI, MSR, Windows and other required system partitions are protected; moving EFI or relocating partitions is not supported.
- Before changes, `Winre.wim` and required configuration files are staged in a protected `ProgramData` directory and SHA-256 verified. Staging is removed after success and retained following a failure after destructive changes.
- The new Recovery must have at least **250 MiB free space**, plus a planning allowance for NTFS formatting differences.

Part of [PSWinKit](../README.md). Console messages are available in English and Russian.
