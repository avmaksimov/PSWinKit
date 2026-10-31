# Remove-Paths — interactive file and directory removal

Windows 10/11, Windows PowerShell 5.1 (x86/x64).

## Running

Extract the entire archive, keeping the folder structure. Run
`Remove-Paths.ps1` in PowerShell or choose **Run with PowerShell** in Explorer.
No required parameters:

```powershell
.\Remove-Paths.ps1
```

The shared `Common/Utility.ps1` library checks administrator rights,
selects the Windows UI language with `Get-UICulture`, loads its PSD1, and
prints a standard header. When elevation is needed, the **utility itself**
is relaunched via UAC; the library is not a separate host process. Declining
UAC ends the original invocation without deletion, a summary, or an exit pause.

Optional explicit language file:

```powershell
.\Remove-Paths.ps1 -LanguageFile 'en.psd1'
.\Remove-Paths.ps1 -LanguageFile 'D:\Locales\en.psd1'
```

Language fallback: full UI culture → parent/neutral culture → mandatory
`en.psd1`, e.g. `ru-RU.psd1` → `ru.psd1` → `en.psd1`. Only Russian and English
ship in the package, and exactly one PSD1 is loaded per run.

Explorer launches and elevated windows pause at the end; existing terminal
sessions do not. The library checks the parent process when needed and passes
`-PauseOnExit` to elevated windows.

## Deletion

A prominent warning about **permanent deletion without the Recycle Bin**
is displayed before input. Enter absolute paths as `1. Path:`, `2. Path:`, etc.
**Press Enter on an empty line to finish.** No special `Esc` handling is needed.

After input, the preview shows counts for paths to be deleted and paths
skipped. **Paths are not repeated**; reasons for skipping are displayed only
by original input numbers. Confirm with `Y` or cancel with `N`; there is no
default choice.

During deletion, the original numbers are used. The final summary lists
**only paths not fully deleted**, including their original numbers and full
paths, followed by the number of fully deleted paths, regular files removed
**within fully deleted paths**, and paths skipped during validation. Links and
directories are not counted as files, and files removed from partially
deleted paths are not included in the completed-files total. When interrupted,
not-yet-started targets are counted separately.

If normal deletion fails, the utility may take ownership as Administrators,
reenable inheritance, and give Everyone full control via SID `S-1-1-0`.
There is no recursive `takeown /R` or `icacls /T`.

NTFS junctions, symbolic links, and mount points are unlinked without following
their targets or changing their targets' permissions. Real directories are
processed one entry at a time.

Drive roots, `C:\Users` (including descendants), and other protected system
paths on C: and the active system drive cannot be selected. Paths through
SUBST drives or intermediate reparse points are not allowed.

The final summary is emitted from `finally` after normal completion,
cancellation with `N`, errors, and ordinary Ctrl+C when PowerShell unwinds;
forcefully killing a process cannot guarantee an exit summary.

## Shared functions

The lifecycle uses `Start-Utility` and `Stop-Utility`. Refer to
`Common/UTILITY-CONTRACT.md` for the shared contract.

### Access checks and duration

For each real directory, Windows Authz checks listing and child-deletion permissions. If needed, the utility first grants permissions on that object only; if this fails it takes ownership and retries. It does not force recursive inheritance or follow reparse-point targets. Counters refresh every five seconds, with permanent failures shown in gray. Start and end times use the regional format including seconds, and duration includes days when applicable.
