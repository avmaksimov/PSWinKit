# Remove-Paths — permanent file and directory deletion

**English** | [Русский](README.ru.md)

An interactive tool for deleting selected files and directories, including objects with restrictive NTFS permissions, read-only attributes and long paths.

**Warning: deletes directly, bypassing the Recycle Bin. Windows provides no built-in undo.** Review all paths before confirming.

## Requirements and running

Windows 10+, Windows Server 2016+, Windows PowerShell 5.1, x86/x64 where applicable. Elevated administrator rights are required; `Common/Common.ps1` requests UAC when needed. PowerShell 7 and external modules are not required.

From the PSWinKit repository root:

```powershell
.\Remove-Paths\Remove-Paths.ps1
```

From the `Remove-Paths` folder:

```powershell
.\Remove-Paths.ps1
```

There are no mandatory or utility-specific command-line parameters. The display language follows `Get-UICulture` (specific culture → parent language → English). Date/time and duration separators follow Windows regional settings. UAC relaunches the main script itself; cancellation produces no deletion or summary.

## Workflow

1. A prominent irreversible-deletion warning appears **before** the first path entry.
2. Enter one absolute path at a time: `1. Path:`, `2. Path:`, etc. **Press Enter on an empty line** to finish.
3. The preview validates selections and excludes duplicates, overlaps, and protected paths; it reports selected and skipped counts.
4. Confirm with `Y` or decline with `N`; there is no default choice.
5. Targets are deleted sequentially with original numbering, live counters and an **individual duration** for each target.
6. The end summary lists the outcome, only the targets not fully deleted, counts and overall execution duration.

A single console status line is rewritten with counts of deleted files, directories and errors, or the current object during enumeration, ACL repair or ownership change. It normally refreshes every five seconds. Definitive failures are emitted as separate gray lines in the form `Could not delete [reason]: path`.

## Safety and deletion behavior

- Drive roots, `C:\Users`, and other protected system paths on C: and the active Windows system drive cannot be selected. SUBST paths, intermediate NTFS reparse points and ambiguous 8.3 names are rejected.
- The tool **does not follow targets** of NTFS symbolic links, junctions or mount points. It unlinks only the link itself without modifying permissions or ownership of the target.
- Windows Authz checks effective permissions on real directories. When necessary, the utility first tries an ACL grant **on the current object only**. It takes ownership only if that grant fails. There is no recursive `takeown /R`, `icacls /T` or forced inheritance modification.
- Extended-length Windows paths (`\\?\...`) handle long names. Files are removed with `Remove-Item -Force`; ordinary empty folders use .NET deletion, with a read-only-attribute retry when needed.
- Only irrecoverable deletion failures count as errors. A normal Ctrl+C may still reach the summary; forcibly terminating the process cannot guarantee cleanup or reporting.
- The total for files inside **fully deleted** targets includes regular files only. Directories, links and files removed from incomplete targets are excluded.

The global clock starts in `Start-Utility` after privilege checks/elevation, before the header and main work; it finishes in `Stop-Utility`. Per-target clocks are independent; overall duration is **not** their sum. Dates, times and time separators follow regional settings, and durations over one day use a localized day suffix (`d` / `д`).

## Project structure

- `Remove-Paths.ps1` — the utility and its deletion logic.
- `../Common/Languages/en.psd1`, `../Common/Languages/ru.psd1` — centralized translations in the `Remove-Paths` section.
- `../Common/Common.ps1` — UAC, startup, language selection, shared messages and shutdown.
- [`../Common/README.md`](../Common/README.md) — the **contract** governing all utilities.

`.ps1` and `.psd1` files use UTF-8 with BOM for Windows PowerShell 5.1. Do not copy Common into individual utility directories.
