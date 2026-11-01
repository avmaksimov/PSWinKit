# PSWinKit

**English** | [Русский](README.ru.md)

**PSWinKit** is a growing collection of independent Windows PowerShell utilities. Every utility runs without required command-line parameters and shares a small library for localization, UAC elevation, startup and shutdown.

## Utilities

| Utility | Purpose | Status |
| --- | --- | --- |
| [Remove-Paths](Remove-Paths/README.md) | Interactively and permanently delete selected files and directories, including protected folders | **Available** |
| [Repair-Windows](Repair-Windows/README.md) | Windows repair using CHKDSK, DISM and SFC | **Available** |
| WinRE-Manager | Manage and repair Windows Recovery Environment | Planned migration |

**Remove-Paths** and **Repair-Windows** are included. **WinRE-Manager** is planned for migration.

## Requirements and use

Windows 10+, Windows Server 2016+, Windows PowerShell 5.1; x86/x64 where supported. Some utilities require administrator privileges. No separate PowerShell 7 installation or third-party module is required for the shared library.

From a PowerShell console in the repository root:

```powershell
.\Remove-Paths\Remove-Paths.ps1
.\Repair-Windows\Repair-Windows.ps1
```

For utility-specific instructions and safety warnings, follow the utility link above. Preserve the directory layout; each utility loads `Common/Common.ps1` by a relative path.

## Installation and updates

Download [`update.ps1`](update.ps1), open Windows PowerShell 5.1 and change to your intended installation directory. Run the downloaded script, for example:

```powershell
New-Item -ItemType Directory -Path 'C:\Tools\PSWinKit' -Force | Out-Null
Set-Location 'C:\Tools\PSWinKit'
& "$env:TEMP\update.ps1" # Example if downloaded to TEMP
```

The target directory is **always the current working directory** (`Get-Location`), not the updater's script folder. For later updates, use `./update.ps1` after changing to the installed directory. `update.ps1` downloads the latest ZIP and runs the fresh [`install.ps1`](https://github.com/avmaksimov/PSWinKit/blob/main/install.ps1) from a temporary folder. That installer uses matching Common and localizations without requiring administrator rights (unless the destination itself requires them).

Before applying changes, verify the destination and the `INSTALL`, `REPLACE`, `UNCHANGED`, `REMOVE` summary. The installer preserves unrelated files, skips any path containing a dot-prefixed name (including Git metadata) and does not copy itself. It maintains a locally generated `install.psd1` containing only an `installed-files` list to identify previously installed files that disappeared from the distribution. If the file or list is missing or invalid, obsolete-file removal is skipped. File contents are compared with SHA-256; all changes including removals require one confirmation. Existing-version backups and automatic rollback are not provided. Do not manually edit `install.psd1`.

## Project organization

- [`Common/README.md`](Common/README.md) — **full shared API documentation and the development contract**.
- [`Remove-Paths/README.md`](Remove-Paths/README.md) — Remove-Paths usage, behavior and limitations.
- [`Repair-Windows/README.md`](Repair-Windows/README.md) — Repair-Windows usage, safety and limitations.
- [`README.ru.md`](README.ru.md) — this overview in Russian.

The project is available under the [MIT License](LICENSE).
