# Shared PowerShell utility contract

## Scope

- Windows 10+, Windows PowerShell 5.1, x86/x64.
- Dot-source `Common/Utility.ps1` as a function library; no separate host process.
- No mandatory CLI options; elevation, language, header and exit handling are shared.
- `.ps1` / `.psd1` files must use UTF-8 with BOM for Windows PowerShell 5.1.
- Public lifecycle functions are **`Start-Utility`** and **`Stop-Utility`**;
  the library also provides the `Get-UtilityMessage` helper.

## Layout

```text
Remove-Paths.ps1
WinRE-Manager.ps1         # future integration
WinRepair.ps1             # future integration
Common/
  Utility.ps1
  Languages/
    en.psd1
    ru.psd1
  UTILITY-CONTRACT.md
  UTILITY-CONTRACT.ru.md
```

## Utility template

```powershell
param(
    [string]$LanguageFile,
    [switch]$PauseOnExit
)

. (Join-Path $PSScriptRoot 'Common\Utility.ps1')

$utility = Start-Utility -ScriptPath $PSCommandPath -Section 'RemovePaths' `
    -LanguageFile $LanguageFile -PauseOnExit:$PauseOnExit -RequireAdministrator

if ($null -eq $utility) { return }

$messages = $utility.Messages
try {
    # Utility logic and its own error handling
}
finally {
    # Utility-specific final summary
    Stop-Utility -Context $utility
}
```

`-Section` identifies a PSD1 section with a `Title` message.
Omit `-RequireAdministrator` if elevation is not required.

## Start-Utility

- Selects the UI language with `Get-UICulture` or respects an explicitly
  selected PSD1, checks administrator privileges and requests UAC if needed.
- With sufficient rights, loads exactly one PSD1, prints the shared title,
  and returns a context containing `LanguageFile`, `Messages`, `PauseOnExit`.
- After launching an elevated copy, returns **`$null`**; the original script
  returns without doing any utility work or calling `Stop-Utility`.
- When UAC is declined (`ERROR_CANCELLED`, 1223), also returns **`$null`**;
  there is no work, summary, or exit prompt.
- Other elevation or startup errors are **not** swallowed: they throw.
- Relaunches only the utility, passing the absolute `-LanguageFile` and
  `-PauseOnExit`. Resolving the language before UAC preserves the original
  user's UI language even if alternate administrator credentials are used.
- No serialized tables or interprocess object transfer is involved.
- An already elevated process is never relaunched unnecessarily.

## Stop-Utility

- Call only after successful initialization, normally in `finally` after the
  utility's summary.
- Optionally wait for a key when opened from Explorer or when
  `-PauseOnExit` was requested; never pause an existing terminal otherwise.
- Never call after UAC refusal.

## Parameters

- Every utility explicitly declares `[string]$LanguageFile` and
  `[switch]$PauseOnExit` — normal, transparent PowerShell parameter binding.
- Explicit `-LanguageFile` accepts a PSD1 filename within `Common/Languages`
  or an absolute file path; missing/non-PSD1 files are errors.
- `-PauseOnExit` is normally internal but may be supplied by the user.
- UAC relaunch uses `Start-Process -Verb RunAs` on the utility, not on the library.

## PSD1 resource files

- Native loading with `Import-PowerShellDataFile -LiteralPath`; no custom INI parser.
- Full UI culture → parent/neutral cultures → mandatory `en.psd1`.
  Example: `ru-RU.psd1` → `ru.psd1` → `en.psd1`.
- Exactly one file is loaded, and English is always the fallback.
- The package includes `ru.psd1` and `en.psd1` for now. Keep keys and sections
  consistent when adding languages.
- `Common` holds truly shared strings, `Host` elevation/pause strings, and
  each utility has its own section (`RemovePaths`, `WinREManager`, `WinRepair`).
- Use Latin section/key names, single-quoted strings, doubled apostrophes,
  and positional `String.Format` placeholders `{0}`, `{1}`, etc.
- The utility uses `$utility.Messages`; no redundant PSD1 loading is needed.

## Errors and safety

- Destructive operations require a preview and explicit Y/N with no default.
- Each utility owns its `finally` summary; ordinary Ctrl+C allows best-effort
  stack unwinding and summary, unlike forceful process termination.
- Never traverse NTFS junctions, symlinks or mount points when deleting or
  changing owners and ACLs. Unlink only the reparse-point object itself.
- Protect running Windows system paths and all of `C:\Users`.
- Keep README stable (no temporary testing-status notes).
- Git commits should have short English Title and Description.
