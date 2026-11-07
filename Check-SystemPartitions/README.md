# Check-SystemPartitions

**English** | [Русский](README.ru.md)

**Check-SystemPartitions** builds on the idea behind [Check-WinRE](../Check-WinRE/README.md). While Check-WinRE focuses on checking and, if necessary, restoring the Windows Recovery Environment (WinRE), Check-SystemPartitions examines the system disk layout, checks WinRE health, and proposes partition optimization, including removal of unnecessary partitions.

## Features

- Lists partitions in physical order, including unallocated gaps.
- Locates and validates `Winre.wim`, measures used and available Recovery space, and can propose enlarging and rebuilding Recovery by adjusting C: while preserving the WinRE image and configuration.
- Audits potentially obsolete system and Recovery partitions. Deletion is offered only after checking contents and boot dependencies; each deletion requires separate confirmation.
- Where feasible, **aligns the C: capacity displayed in File Explorer to a multiple of 10 GiB** (for example, 130 or 140 GiB). A purely cosmetic adjustment is limited to **256 MiB** and must not compromise the Recovery free-space requirement. Fixing an undersized Recovery takes priority over a round number.

The target is based on the actual NTFS volume capacity, not just partition geometry. Windows partition alignment and filesystem overhead are also considered, so the partition's raw size may differ slightly from the round value shown by File Explorer.

## Run

From the PSWinKit root in Windows PowerShell 5.1:

```powershell
.\Check-SystemPartitions\Check-SystemPartitions.ps1
```

No required parameters. The interactive workflow is: diagnose → propose changes → validate → confirm individual operations → execute → summarize actual results. If no changes are needed, the tool exits without repartitioning.

## Scope and safety

**Warning:** changing system partitions can cause data loss or prevent Windows from starting. Have a verified, restorable full-disk image before proceeding. **There is no automatic rollback.**

- The current C:/Recovery executor targets GPT disks with Windows on NTFS C: and a registered active Recovery partition immediately after C:.
- Missing Recovery or a missing suitable `Winre.wim` can be diagnosed, but creating Recovery from scratch is not yet supported by the execution path.
- EFI, MSR, Windows and other required system partitions are protected; moving EFI or relocating partitions is not supported.
- Before changes, `Winre.wim` and required configuration files are staged in a protected `ProgramData` directory and SHA-256 verified. Staging is removed after success and retained following a failure after destructive changes.
- The new Recovery must have at least **250 MiB free space**, plus a planning allowance for NTFS formatting differences.

Part of [PSWinKit](../README.md). Console messages are available in English and Russian.
