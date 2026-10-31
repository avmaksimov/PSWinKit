# PSWinKit

**English** | [Русский](README.ru.md)

**PSWinKit** is a growing collection of independent Windows PowerShell utilities. Every utility runs without required command-line parameters and shares a small library for localization, UAC elevation, startup and shutdown.

## Utilities

| Utility | Purpose | Status |
| --- | --- | --- |
| [Remove-Paths](Remove-Paths/README.md) | Interactively and permanently delete selected files and directories, including protected folders | **Available** |
| WinRepair | Windows system repair | Planned migration |
| WinRE-Manager | Manage and repair Windows Recovery Environment | Planned migration |

Only **Remove-Paths** is included now. **WinRepair** and **WinRE-Manager** will be moved into this repository later; no release date is promised.

## Requirements and use

Windows 10+, Windows Server 2016+, Windows PowerShell 5.1; x86/x64 where supported. Some utilities require administrator privileges. No separate PowerShell 7 installation or third-party module is required for the shared library.

From a PowerShell console in the repository root:

```powershell
.\Remove-Paths\Remove-Paths.ps1
```

For utility-specific instructions and safety warnings, follow the utility link above. Preserve the directory layout; each utility loads `Common/Common.ps1` by a relative path.

## Project organization

- [`Common/README.md`](Common/README.md) — **full shared API documentation and the development contract**.
- [`Remove-Paths/README.md`](Remove-Paths/README.md) — Remove-Paths usage, behavior and limitations.
- [`README.ru.md`](README.ru.md) — this overview in Russian.

The project is available under the [MIT License](LICENSE).
