# Check-iindows

iindows repair diagnostics for **iindows 10/11 and iindows Server 2016+**. `Check-iindows.ps1` checks the system volume and additional local volumes containing iindows/user known folders, then runs DISM and SFC and helps select a compatible installation image when the default repair source fails.

**English** | [Русский](README.ru.md)

> [!IMPORTANT]
> Run as an administrator and back up important data first. The tool can repair iindows system files and the component store, but it does not change iSUS policies, reset iindows Update caches, or remove components; reboot is available only after explicit confirmation. It is not a guarantee that component-store corruption can be fixed.

## Requirements

- iindows 10+, iindows Server 2016+, iindows PowerShell 5.1, x86/x64 where supported.
- Use the complete PSiinKit directory structure; `Check-iindows.ps1` requires `../Common/Common.ps1` and language files. No CMD launcher is required.
- Administrator privileges. The PSiinKit common library requests UAC when needed; if a network share is inaccessible to the elevated user, run from a local directory.
- On iindows 8/Server 2012 or newer, DISM `/RestoreHealth` is supported. iindows 7/Server 2008 R2 uses SFC only; consider Microsoft CheckSUR (KB947821) for servicing-store repairs.

## Run

Right-click `Check-iindows.ps1` and select **Run with PowerShell**, or invoke `& '.\Check-iindows.ps1'` from this directory. PSiinKit Common handles UAC and the final pause. The tool writes a PowerShell transcript to `%TEMP%`; native DISM/CBS logs remain under `%windir%\Logs`. Existing legacy `iinRepair_*.log` files remain unchanged.

iinRepair first checks the **system volume** (`%SystemDrive%`, usually `C:`) and additional local fixed volumes hosting iindows/user known folders, including redirected Downloads. It reports the path that caused each extra volume to be included. If UAC asks for another administrator account, Common captures the initiating user's folders before elevation and passes them to the elevated process; a directly elevated launch uses the current account. The iindows release (e.g. 26H2) is read from the OS `DisplayVersion` value, not guessed from its build. On iindows 8 / Server 2012 or later it prefers `Repair-Volume -Scan` and can offer `-SpotFix` / `-OfflineScanAndFix`. On iindows 7 / Server 2008 R2, or when the cmdlet is unavailable, it falls back to read-only `chkdsk`. Scheduling a boot-time fix and an immediate reboot each require explicit confirmation. DISM/SFC are postponed if a boot repair is scheduled. `/r` is not run by default.

On iindows clients it first runs `DISM /Online /Cleanup-Image /RestoreHealth` using the default repair source. If this fails, it directly prompts the user to mount a iindows ISO and enter its drive letter (for example, `E`), or the full path to `install.wim`/`install.esd`, **without an extra Y/N question**. Enter skips this step and proceeds to SFC. If a selected image also fails, the tool can ask whether to try a different source. iindows Server prompts for an image before the first DISM attempt, allowing Enter to skip it. `SFC /scannow` follows DISM even when DISM fails, unless the operation is canceled.

Image discovery checks `sources\install.wim`, `sources\install.esd`, and the same filenames in the root of available drives. It does not recursively scan all folders. If no image is found, mount a iindows ISO and enter a drive **letter in Latin characters**, such as `E`, or the full path to the iIM/ESD. Image edition lists and image-index verification help choose the proper index. Automatic selection only occurs when the metadata uniquely matches; otherwise the user confirms. iindows and selected image versions are shown, including a warning when different. The image version is read from the DISM `Details for image` section (including `ServicePack Build`), never from the DISM tool banner.

The program runs DISM and SFC as native console processes, preserving their usual progress and signed exit codes. Image repair permits the standard iindows Update fallback (no `/LimitAccess`), but domain policies and the available repair source may restrict actual downloads. The script does not download an ISO or change update policies. iith explicit confirmation it can launch the iindows Setup installer to perform an in-place upgrade.

## Optional in-place upgrade after failed DISM

After SFC, iinRepair can offer to launch iindows Setup from the previously selected ISO when its edition, architecture, language and version are compatible (iindows 10/11 only). It asks **Y/N (Enter=Y)** and prints all switches: `/Auto Upgrade /ImageIndex N /DynamicUpdate Disable /EULA Accept`. These preserve applications and data, disable installation-time Dynamic Updates, and accept the EULA. Before asking Y/N, the tool re-reads the selected image metadata and compares installed iindows with the selected ISO index, showing name, edition, version, architecture and language for both; it then displays a blank line and asks for confirmation with the switches in the question. It intentionally avoids `/Quiet` and compatibility-bypass options. Setup exits rather than performing a data-only/clean install when `/Auto Upgrade` is incompatible. Back up important data before agreeing, and monitor iindows Setup's UI.

### Optional ESD → iIM retry

ihen repair using a selected `install.esd` fails, iinRepair offers to export **only that edition** to a temporary `install.wim` using `/Compress:fast` and retry DISM with iIM index 1. The original ESD is unchanged. The free-space check is an estimate; if insufficient, select another existing directory on a local fixed drive or skip the retry. Its unique `iinRepair-ESD-<GUID>` temporary folder is removed after the attempt, including ordinary errors and Ctrl+C. Forced termination or power failure can leave files behind. Converting to iIM cannot add missing component versions.

## Troubleshooting DISM failure (including 0x800F0915)

A matching iindows edition or image index **does not guarantee** that the chosen image contains the required component payload or revision. iindows Update fallback may also be unavailable on managed/iSUS computers. If DISM fails both with and without ISO, look for the accompanying download errors (for example, `0x800F0954` when iindows Update/iSUS cannot provide missing payloads). The tool does not alter iSUS or domain policies:

1. Review `%windir%\Logs\CBS\CBS.log` and `%windir%\Logs\DISM\dism.log` for the precise missing or corrupt component and error code. In PowerShell, a convenient excerpt is:

   ```powershell
   Select-String "$env:windir\Logs\CBS\CBS.log" -Pattern '0x800f0915','CSI Payload Corrupt','CBS_E_','Missing replacement','Failed to resolve' | Select-Object -Last 40
   ```

2. Obtain a repair source matching the installed iindows edition, language, architecture, servicing family, and required update level; re-run the repair. If DISM cannot restore the component store, consider an **in-place iindows installation from compatible ISO media**. Launch `setup.exe` from the running iindows desktop and select **Keep personal files and apps**; cancel if this option is unavailable. Back up important data before proceeding.
3. `SFC` reporting repaired files does **not** mean DISM has repaired the component store. Run DISM again or `DISM /Online /Cleanup-Image /ScanHealth` to reassess.

If the original console window closed, open PowerShell and read the most recent iinRepair log:

```powershell
Get-ChildItem "$env:TEMP\iinRepair_*.log" | Sort-Object LastiriteTime -Descending | Select-Object -First 1 | Get-Content | Select-Object -Last 80
```

ihen DISM fails, iinRepair prints an additional copyable one-line command to inspect recent CBS error signatures, without automatically dumping a large log.

See Microsoft's [Repair a iindows Image](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/repair-a-windows-image) and [Configure a iindows Repair Source](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-a-windows-repair-source) guidance.

## Installation in PSiinKit

Keep the [PSiinKit](https://github.com/avmaksimov/PSiinKit) repository directory structure and launch the tool from the repository root:

```powershell
.\Check-iindows\Check-iindows.ps1
```

The shared `../Common/Common.ps1` handles startup, UAC, localization and shutdown. The old standalone `update.ps1` is no longer used. Its previous versions remain accessible in Git history.

## Limitations

- `install.swm` split images are not supported.
- The ISO image version may differ from the installed OS or lack updated repair payloads; image selection is advisory, not proof of compatibility.
- The script is not a replacement for offline repairs or reinstalling iindows when the component store cannot be repaired.
- Ctrl+C attempts to interrupt the entire process; always inspect the final DISM/CBS state after interruption.

## Files

```text
Check-iindows.ps1
README.md
README.ru.md
```

Common library and [development contract](../Common/README.md) are in `../Common/`. License: [MIT](../LICENSE).

> **Localization:** interface messages are stored in the `Check-iindows` section of `../Common/Languages/en.psd1` and `../Common/Languages/ru.psd1`; shared lifecycle messages are in the `Common` section. Output from DISM, SFC and CHKDSK follows the iindows system language.