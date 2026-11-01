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

Open Windows PowerShell 5.1 **in the existing directory** where you want to install PSWinKit. Download and run the updater directly from PowerShell:

```powershell
$url = 'https://raw.githubusercontent.com/avmaksimov/PSWinKit/main/update.ps1'
$script = Join-Path $env:TEMP 'PSWinKit-bootstrap.ps1'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
try {
    Invoke-WebRequest -Uri $url -OutFile $script -UseBasicParsing -ErrorAction Stop
    & $script
} finally {
    Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue
}
```

For subsequent updates, open PowerShell in the **installed PSWinKit directory** and run:

```powershell
.\update.ps1
```

The target directory is **always the current working directory** (`Get-Location`), not the updater's script folder. `update.ps1` checks the latest `main` commit on GitHub, displays its date and short SHA, and skips downloading when it matches the installed commit. When different, it downloads an archive pinned to that commit and runs the fresh [`install.ps1`](https://github.com/avmaksimov/PSWinKit/blob/main/install.ps1) from a temporary folder. If the GitHub API is unavailable, it attempts `main.zip` without verified commit metadata. That installer uses the matching Common and centralized `Common/Languages` translations without requiring administrator rights (unless the destination itself requires them).

Before applying changes, verify the destination and the `INSTALL`, `REPLACE`, `UNCHANGED`, `REMOVE` summary. The installer preserves unrelated files, skips any path containing a dot-prefixed name (including Git metadata) and does not copy itself. It maintains a locally generated `install.psd1` with an `installed-files` list for removal of obsolete files and a separate `install-info` section containing the verified full commit SHA and UTC commit date. An unverified ZIP installation records empty commit fields; a missing `install-info` is treated as a first installation. If the file or list is missing or invalid, obsolete-file removal is skipped. File contents are compared with SHA-256; all changes including removals require one confirmation. Existing-version backups and automatic rollback are not provided. Do not manually edit `install.psd1`.

## Project organization

- [`Common/README.md`](Common/README.md) — **full shared API documentation and the development contract**.
- [`Remove-Paths/README.md`](Remove-Paths/README.md) — Remove-Paths usage, behavior and limitations.
- [`Repair-Windows/README.md`](Repair-Windows/README.md) — Repair-Windows usage, safety and limitations.
- [`README.ru.md`](README.ru.md) — this overview in Russian.

The project is available under the [MIT License](LICENSE).

Commit dates are displayed in the Windows local time and regional format. An equal commit SHA skips the file-by-file check; for a manual reinstall use the latest `install.ps1` from the source archive.
