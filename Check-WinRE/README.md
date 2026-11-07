# Check-WinRE

**Check-WinRE** is an interactive Windows Recovery Environment (WinRE) diagnostic and optional repair tool for Windows PowerShell 5.1. It supports basic GPT and MBR disks, searches for an existing `Winre.wim`, and can restore WinRE from a matching Windows installation ISO when necessary.

**[Русская документация](README.ru.md)**

Before requesting confirmation, an existing 7-Zip installation at the official `Program Files\7-Zip\7z.exe` location (both 32-bit and 64-bit Windows) is tried for direct extraction of `Winre.wim` from `install.wim`/`install.esd`. The PATH and `Program Files (x86)` locations are never searched. No external binaries are included or downloaded. If 7-Zip is unavailable or extraction fails validation, Windows DISM is used automatically; DISM may require more temporary disk space. The summary names the extraction method. Both tools retain their native console output.

> [!WARNING]
> This tool can format or permanently remove a Windows Recovery partition and may extend the system volume C:. **Create a complete disk backup or a verified VM checkpoint before running it.** There is no automatic rollback. Test on a disposable VM before using it on a production computer.

## Usage

From the PSWinKit root, run:

```powershell
.\Check-WinRE\Check-WinRE.ps1
```

No command-line parameters are required. You can also run `Check-WinRE.ps1` from its folder or use **Run with PowerShell**. Preserve the full PSWinKit directory layout: the utility loads `..\Common\Common.ps1` relative to its script, independently of the current directory.

`Start-Utility` handles language, the Check-WinRE header, timing and UAC. If needed, it relaunches the same script in a separate elevated window with the same PowerShell architecture. The original console returns immediately; UAC cancellation performs no work. `Stop-Utility` runs after cleanup and prints the finish time and duration. An existing terminal does not normally pause; a window opened by Common through UAC pauses on exit. Explorer detection is best-effort. There is no utility-specific UAC or keypress handler.

All utility-owned messages, including errors and ISO table headings, are in the `Check-WinRE` sections of `Common/Languages/en.psd1` and `ru.psd1`. Windows UI culture selects the language with English fallback. Native output from DISM, DiskPart, REAgentC, 7-Zip and Windows exceptions is retained; it is not retranslated. DISM keeps the source utility's `/English` switch. Regional settings determine numeric, date and time formatting independently of the UI language. See the [Common contract](../Common/README.md).

Workflow: **analyze → show a proposed plan → one `Y/N` confirmation → execute**. Color-coded sections separate analysis, image selection, proposed actions, safety warnings, execution, and results. Labels and values are aligned in clearly spaced columns. Any response other than `Y` cancels. There are no log files.

- When WinRE is already `Enabled`, no changes are performed, even if partition sizes could be optimized.
- When WinRE is disabled, the tool searches for a usable local `Winre.wim` first and shows the status of each standard location (`%WINDIR%\System32\Recovery`, `C:\Recovery\WindowsRE`, and the Recovery partition if present). Existing files are validated; missing and invalid images are distinguished. The permanent image is stored on the Recovery partition, not duplicated in the Windows system directory. If none is found, it asks you to mount a matching Windows ISO and enter **one drive letter without a colon**, e.g. `F`.
- The tool supports `sources\install.wim` and `sources\install.esd` on the ISO. It verifies the edition ID and architecture independently of Windows display language, and prefers an exact OS build. For Windows 11 24H2/25H2/26H2 (builds 26100/26200/26300), it also accepts a single edition- and architecture-matching image from the shared servicing-core family, with an explicit warning. It displays the ISO image editions, builds, and architectures for diagnosis, then stages `Winre.wim` on C: before any destructive work.
- Before the final confirmation, it computes the Recovery minimum as `max(990 MiB, Winre.wim size + 250 MiB + 32 MiB)`, displays the actual system disk capacity and remaining unallocated space, and independently checks the planned C:/Recovery geometry in bytes. A plan extending beyond the disk or overlapping another partition is rejected before confirmation.
- After approval, it first tries `reagentc /enable` **when an existing Recovery partition is present**. If no Recovery partition exists, the tool recreates it instead of enabling WinRE on C: and exiting prematurely.

### Supported layouts and changes

| Disk layout | Behavior if standard `reagentc /enable` fails |
|---|---|
| `C: → Recovery → unallocated` | Delete the identified Recovery, optionally **extend** C: to a whole-GiB Explorer display (with a 1 MiB NTFS margin), and create a correctly typed/formatted Recovery partition. Never shrink C:. |
| `C: → Recovery → D:` (or another later partition) | If the existing Recovery meets the calculated minimum, **format and reuse it in place**; C: and following partitions are not resized or moved. If Recovery is too small, stop without changing the partition layout. |
| `C: → unallocated` | Create Recovery in available space if enough space exists. Skip the preliminary `reagentc /enable` to ensure the missing Recovery is recreated. |
| `C: → D:` with no Recovery | Unsupported by this version; no existing partition is moved or shrunk. |

For rebuilding at the end of the disk, C: is extended to an integer number of GiB **plus 1 MiB where possible**. This compensates for the small NTFS capacity difference (e.g., Explorer showing 64.9 GiB for an exact 65 GiB partition). The displayed outcome must still be verified on the target Windows installation. The maximum target Recovery size is the calculated minimum plus 1024 MiB. All sizes and offsets are computed in bytes and aligned to 1 MiB. A new Recovery is formatted without assigning a drive letter: it is temporarily mounted under a separate empty NTFS folder in `%WINDIR%\Temp`, detached after registration, then given its Recovery type/attributes. If cleanup cannot detach the mount folder, the folder is retained for manual inspection (never recursively deleted). The created Recovery uses the GPT Windows RE type GUID (`DE94BBA4-06D1-4D40-A16A-BFD50179D6AC`) and required GPT attributes, or MBR type `0x27`.

### Safety limits

- Only Windows installed on **C:**; Windows 10/11 and Windows Server 2016 or later, subject to available built-in Windows utilities. Primary target: Windows 11.
- Basic disk, recognized Recovery partition type, simple adjacent layout, automatic UAC elevation, and a readable existing Recovery partition before destructive operations.
- Never deletes unidentified/OEM partitions or custom recovery content. Never reformats D: or moves it.
- BitLocker-protected or unverifiable system volumes are not modified.
- The `Winre.wim` image and any required ISO extraction are prepared *before* asking for the final `Y/N`. Temporary files are stored under `%WINDIR%\Temp\WinRE-Manager-<GUID>`, with the full WIM path displayed before export. DISM displays its native console progress directly, without any PowerShell progress wrapper. The script also shows the mount directory, WinRE extraction destination, and validation result so mounting/unmounting does not appear to be a no-op. Temporary files can occupy significant space on C:, even if you later cancel.
- The final GPT attribute check uses DiskPart rather than the unreliable `Get-Partition.NoDefaultDriveLetter` property.
- If a failure occurs **after** destructive changes, the script stops and preserves the staged `Winre.wim` for manual recovery; it does not automatically undo disk operations.
- If you interrupt the operation with **Ctrl+C**, the script tries to clean up temporary resources and displays a prominent red **OPERATION INTERRUPTED** status instead of silently showing only the final keypress prompt. If partition changes were started, inspect disk and WinRE state before retrying. A forced process termination cannot guarantee cleanup or an interruption message.

## Installation and updates

Use PSWinKit's root [`install.ps1` and `update.ps1`](../README.md#installation-and-updates). Check-WinRE has no separate installer. The complete Common folder and central translations are required. No separate language files belong in this utility's folder.

## TODO

- Optimize C: and/or Recovery even when WinRE is already healthy; currently an enabled WinRE always causes an immediate exit.
- Support resizing an undersized Recovery between C: and D: by safely shrinking C: and rebuilding Recovery **without moving D:**.
- Add other safe shrink/grow/repartition workflows and preserve whole-GiB C: sizes where possible.
- Support more complex partition layouts with explicit safety checks.

## Microsoft documentation

- [GPT partition guidance](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-uefigpt-based-hard-drive-partitions)
- [MBR partition guidance](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-biosmbr-based-hard-drive-partitions)
- [REAgentC command-line options](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/reagentc-command-line-options)

## Repository layout

```text
Check-WinRE/
├── Check-WinRE.ps1
├── README.md
└── README.ru.md
```

Shared messages: `../Common/Languages/en.psd1` and `ru.psd1`. The internal temporary names `%WINDIR%\Temp\WinRE-Manager-<GUID>` and `WinRE-Manager-Mount-<GUID>` intentionally retain their original spelling.
