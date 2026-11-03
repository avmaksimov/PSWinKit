# PSWinKit

**English** | [Русский](README.ru.md)

**PSWinKit** is a growing collection of independent Windows PowerShell utilities. Every utility runs without required command-line parameters and shares a small library for localization, UAC elevation, startup and shutdown.

## Utilities

| Utility | Purpose |
| --- | --- |
| [Remove-Paths](Remove-Paths/README.md) | Interactively and permanently delete selected files and directories, including protected folders |
| [Repair-Windows](Repair-Windows/README.md) | Windows repair using CHKDSK, DISM and SFC |
| [Repair-WinRE](Repair-WinRE/README.md) | Restore WinRE and repair supported GPT/MBR Recovery layouts |

## Requirements and use

Windows 10+, Windows Server 2016+, Windows PowerShell 5.1; x86/x64 where supported. Some utilities require administrator privileges. No separate PowerShell 7 installation or third-party module is required for the shared library.

From a PowerShell console in the repository root:

```powershell
.\Remove-Paths\Remove-Paths.ps1
.\Repair-Windows\Repair-Windows.ps1
.\Repair-WinRE\Repair-WinRE.ps1
```

For utility-specific instructions and safety warnings, follow the utility link above. Preserve the directory layout; each utility loads `Common/Common.ps1` by a relative path.

## Installation and updates

### Initial installation

Open Windows PowerShell 5.1 **in the existing directory** where you want to install PSWinKit. Download the repository ZIP to a temporary location, extract it, and run `install.ps1`:

```powershell
$name = 'PSWinKit-' + [guid]::NewGuid().ToString('N')
$zip = Join-Path $env:TEMP "$name.zip"
$dir = Join-Path $env:TEMP $name

$url = 'https://github.com/avmaksimov/PSWinKit/archive/refs/heads/main.zip?cacheBust=' + [guid]::NewGuid().ToString('N')
Invoke-WebRequest -Uri $url `
    -Headers @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' } `
    -OutFile $zip -UseBasicParsing -ErrorAction Stop

Expand-Archive -LiteralPath $zip -DestinationPath $dir
& (Join-Path $dir 'PSWinKit-main\install.ps1')
```

The installer reads the files and translations from the extracted archive, but installs PSWinKit **into the current working directory** (`Get-Location`). There is no need to create the target directory in this example, and `update.ps1` is not used for initial installation. Since this direct installation does not pass commit metadata, `install-info` records an unknown SHA and date until a subsequent update.

### Subsequent updates

From the existing PSWinKit installation directory, run:

```powershell
.\update.ps1
```

`update.ps1` compares the installed SHA with the latest commit on GitHub's `main` branch. If they differ or the installed SHA is unknown, it downloads the source archive and invokes a fresh `install.ps1`. When the GitHub API is available, the archive is pinned to a specific commit and its SHA and date are recorded; if the API is unavailable, it falls back to `main.zip` without verified version metadata. The installer does not require elevation unless the destination directory requires it.

Before applying changes, verify the destination and the `INSTALL`, `REPLACE`, `UNCHANGED`, `REMOVE` summary. The installer preserves unrelated files, skips any path containing a dot-prefixed name (including Git metadata) and does not copy itself. It maintains a locally generated `install.psd1` with an `installed-files` list for removal of obsolete files and a separate `install-info` section containing the verified full commit SHA and UTC commit date. An unverified ZIP installation records empty commit fields; a missing `install-info` is treated as a first installation. If the file or list is missing or invalid, obsolete-file removal is skipped. File contents are compared with SHA-256; all changes including removals require one confirmation. Existing-version backups and automatic rollback are not provided. Do not manually edit `install.psd1`.

## Project organization

- [`Common/README.md`](Common/README.md) — **full shared API documentation and the development contract**.
- [`Remove-Paths/README.md`](Remove-Paths/README.md) — Remove-Paths usage, behavior and limitations.
- [`Repair-Windows/README.md`](Repair-Windows/README.md) — Repair-Windows usage, safety and limitations.
- [`Repair-WinRE/README.md`](Repair-WinRE/README.md) — WinRE repair, supported Recovery layouts and safety limits.
- [`README.ru.md`](README.ru.md) — this overview in Russian.

The project is available under the [MIT License](LICENSE).

Commit dates are displayed in the Windows local time and regional format. An equal commit SHA skips the file-by-file check; for a manual reinstall use the latest `install.ps1` from the source archive.
