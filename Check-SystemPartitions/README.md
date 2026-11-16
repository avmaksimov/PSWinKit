# Check-SystemPartitions

**English** | [Русский](README.ru.md)

**Check-SystemPartitions** diagnoses and repairs the Windows Recovery Environment (WinRE), checks the system disk layout, and offers optional C:/Recovery optimization and carefully audited deletion of obsolete partitions.

## Features

- Lists partitions in physical order, including unallocated gaps, and identifies common virtualization platforms via `Win32_ComputerSystem` (manufacturer/model, not `HypervisorPresent`). Shows the detected computer type and virtualization platform where available (for example, `Virtual machine (Hyper-V)`). If the classification is wrong, the console asks the administrator to report it to the PSWinKit developer and not approve repartitioning based on that classification.
- When Windows RE is disabled, **first offers `reagentc /enable`** after the read-only boot checks and explicit `Y/N` consent, before ISO selection or disk changes. The command can change REAgentC/boot configuration but does not repartition the disk. State and registered location are checked again; a successful enable ends the run. When the registered partition can be identified, its WIM and free space are assessed. A failed attempt does not stop ordinary physical-machine planning.
- On a recognized **virtual machine**, **do not offer creating or rebuilding Recovery after C:**; allow enabling a suitable existing Recovery in place. ISO discovery for a missing Recovery is skipped on VMs. This preserves straightforward extension of C: after the virtual disk grows. VM detection may be inconclusive; unknown hardware follows the normal workflow and is labeled as unknown. After an unsuccessful `reagentc /enable`, report its exit code only (the command already prints its own diagnostic); print the image-check result once and the VM layout policy once after the partition table.
- Locates and validates `Winre.wim`, measures used and available Recovery space, and can propose enlarging and rebuilding Recovery by adjusting C: while preserving the WinRE image and configuration.
- When WinRE is disabled and the sole existing Recovery has a missing or invalid `Winre.wim`, checks whether it can be repaired in place, then reuses a verified local image when available or searches matching installation media (shared JSON catalog, mounted image or selected path), validates `Winre.wim`, and **offers restoration to the same partition** after a separate confirmation. A corrupt original WIM and standard WinRE settings are first backed up to protected storage on C: and SHA-256 verified. Normally, the replacement is atomic, using a temporary file on Recovery. If there is insufficient room for two WIMs, but deleting the corrupt original would leave the required free-space reserve, an **additional Y/N confirmation (default N)** offers a non-atomic replacement. Both the original and the validated replacement WIM are staged on C: before removing just the damaged WIM. If writing fails, both rescue copies remain available for manual recovery; the partition is never formatted. There is no additional yes/no question before ISO discovery. SHA-256, disk identity, partition layout and remaining free space are checked before and after writing. VMs never get a proposed new Recovery after C:. For Server 2019 and similar older Windows on a Recovery smaller than 500 MiB, the minimum free space is 50 MiB plus a 4 MiB registration allowance; writes are refused when there is insufficient space.
- Local image discovery checks `%WINDIR%\System32\Recovery\Winre.wim` and `C:\Recovery\WindowsRE\Winre.wim`. For the single inactive Recovery, a valid Winre.wim at the partition root can be validated and registered without moving it, provided no unknown or OEM items are present.
- When WinRE is disabled, can register a **validated image on an existing Recovery partition** without repartitioning, but only on the **same physical disk as Windows**, with enough partition capacity and free space. These conditions are rechecked before enabling WinRE.
- Supports creation of a missing Recovery on GPT and constrained MBR scenarios: migrating working WinRE from C: to a new Recovery partition, or creating Recovery for disabled WinRE when the disk layout meets all safety checks.
- For an undersized Recovery with disabled WinRE, first uses space on the **right**: attempts expansion and, if Windows rejects it with no layout changes, rebuilds in place **only after verified image/settings backup**. If right-side space is insufficient and Recovery immediately follows C:, the tool can shrink C: and rebuild Recovery.
- For **C: → D: → Recovery**, when right-side space cannot accommodate WinRE, the tool can shrink **C: only** and create a new Recovery **before D:**. Both D: and the old Recovery remain untouched until the new WinRE has been verified; on GPT, the script can offer to remove the old Recovery **in the same run**, but only after the new WinRE is verified and the old partition passes a separate safety audit and confirmations. On MBR the old partition remains.

- Audits potentially obsolete system and Recovery partitions. Deletion is offered only after checking contents and boot dependencies; each deletion requires separate confirmation.
- Where feasible, **aligns the C: capacity displayed in File Explorer to a multiple of 10 GiB** (for example, 130 or 140 GiB). A purely cosmetic adjustment is limited to **256 MiB** and must not compromise the Recovery free-space requirement. Fixing an undersized Recovery takes priority over a round number.

The target is based on the actual NTFS volume capacity, not just partition geometry. Windows partition alignment and filesystem overhead are also considered, so the partition's raw size may differ slightly from the round value shown by File Explorer.


**C: rounding choice:** when WinRE repair is required and cosmetic rounding is also possible, a single `Y/R/N` prompt defaults to `Y`: `Y` repairs with rounding, `R` repairs without cosmetic rounding, and `N` declines the repair. `R` recalculates the technical-only partition geometry. If WinRE is healthy and only rounding is offered, the `Y/N` prompt defaults to `Y`. Optional obsolete-partition deletion remains a separately audited `Y/N` choice, default `N`.

## Run

From the PSWinKit root in Windows PowerShell 5.1:

```powershell
.\Check-SystemPartitions\Check-SystemPartitions.ps1
```

No required parameters. The interactive workflow is: diagnose and show the current partition table → select operations → preview the proposed layout in the same table format → validate → confirm → execute → verify and optionally clean up an obsolete Recovery (GPT only after a separate audit). If no changes are needed, the tool exits without repartitioning.

## Module responsibilities

| File | Responsibility |
|---|---|
| `Check-SystemPartitions.ps1` | Entry point, disk diagnostics, physical partition table, workflow selection, confirmations, and final results. |
| `Module-Planning.ps1` | **Read-only** Recovery/image assessment and GPT/MBR geometry calculations, including choosing right-side expansion, rebuild after C:, or new Recovery before D:. |
| `Module-Execution.ps1` | Safety preflight, SHA-256 checked backups, C:/Recovery changes, REAgentC registration and final verification; supports disabled WinRE both in-place and with insufficient Recovery space. |
| `Module-IsoWinRE.ps1` | Finds known or mounted Windows ISO sources, attaches ISO files, selects an image index and extracts `Winre.wim` with 7-Zip/DISM. |
| `../Common/ImageCatalog.ps1` | Shared `Common/Data/images.json` catalog: read, GUID-fragment publication, Windows/SMB locks, atomic merging and `.tmp` cleanup; reusable by `Check-Windows` later. |
| `Module-Cleanup.ps1` | Audits obsolete partition candidates, boot dependencies, content safety, and individual deletion confirmations. |
| `../Common/Common.ps1` | Shared launch, elevation, localization, and exit/duration handling. |
| `../Common/Languages/en.psd1`, `ru.psd1` | English and Russian localized messages. |

Only `Check-SystemPartitions.ps1` is launched directly; it loads the auxiliary modules automatically.

## Shared Windows ISO catalog

The index resides **only in `Common/Data` under PSWinKit** (`Common/Data/images.json`, `Common/Data/images_<GUID>.json`, `Common/Data/images.lock`), including when PSWinKit runs from a network drive. The directory is created as needed; there is no separate local index. ISO files themselves are **not copied or downloaded**. Preserve `Common/Data` across PSWinKit updates.

**When upgrading an existing installation:** if `Data` already exists at the PSWinKit root, first stop all utilities using the catalog (including access from other computers over SMB), then move its **contents** into `Common/Data` without overwriting any files there. Keep `images.json`, all `images_<GUID>.json` fragments, and `images.lock` together. Inspect any conflicting files before merging; do not discard the old directory until the new catalog works. The application does not move or delete user-generated data automatically.

When an installation image is needed, the utility checks saved compatible ISO paths first, then mounted setup media, then accepts a **drive letter** (`F` or `F:`), an **ISO filename** or a **directory path**. Explicit folders and drive roots are searched recursively, without following directory reparse points and with an enumeration limit. Absolute, relative and UNC paths are accepted. ISO files are mounted via built-in Windows tools, using the actual mounted drive letter, and are not automatically dismounted after use.

The stored catalog is only a hint: `install.wim`, `install.esd` or `install.swm` metadata is rechecked before use for the required edition, architecture, installation type and build. Only the defined client Windows 11 shared-core exception applies. A verified ISO is saved immediately **before** WinRE extraction, regardless of any later partition operation result. A physical DVD drive letter alone is not persisted. Local file paths are tagged with the originating computer name; mapped network paths are converted to UNC where possible.

New records are published as `images_<GUID>.json` under a shared `images.lock` handle. At exit, an exclusive handle protects merging into `images.json`, duplicate elimination and cleanup of abandoned GUID `.tmp` files. Normal reads require no lock. Catalog failures do not block the primary WinRE task; damaged fragments are retained for investigation.

## Scope and safety

**Warning:** changing system partitions can cause data loss or prevent Windows from starting. Have a verified, restorable full-disk image before proceeding. **There is no automatic rollback.**

- Resizing and rebuilding an existing active Recovery primarily targets GPT disks with Windows on NTFS C: and a Recovery partition immediately after C:.
- **If WinRE is disabled and Recovery is too small**, the tool proposes right-side expansion or a guarded rebuild. For C: → D: → Recovery, it may create a new Recovery before D: while leaving D: and the old Recovery intact. If no safe plan is available, the layout is unchanged. A validated image must reside on the same physical disk as Windows C:.
- A missing or invalid `Winre.wim` on an existing Recovery can be restored **only when WinRE is disabled**, on one unambiguously identified Recovery partition on the Windows disk with safe NTFS, no unexpected OEM content, and enough free space to stage the complete replacement before swapping it. The original WIM and standard settings are SHA-256 backed up on C: first. On failure, the backup is retained for manual recovery; there is no automatic rollback. An enabled WinRE is never replaced.
- Creating Recovery on MBR is subject to additional safeguards: basic disk, no extended/logical partitions, an available primary partition entry, unambiguous registration, and safe geometry.
- EFI, MSR, Windows and other required system partitions are protected; moving EFI or relocating partitions is not supported.
- Before changes, `Winre.wim` and required configuration files are staged in a protected `ProgramData` directory and SHA-256 verified. Staging is removed after success and retained following a failure after destructive changes.
- The new Recovery must have at least **250 MiB free space**, plus a planning allowance for NTFS formatting differences.

Part of [PSWinKit](../README.md). Console messages are available in English and Russian.
