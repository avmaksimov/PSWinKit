# PSWinKit — PowerShell utility development contract

**Version 1.1 (Start-Utility / Stop-Utility, regional formatting)**
**Status: agreed architecture contract.**
This file is both the documentation for `Common/Common.ps1` and the mandatory contract for `Remove-Paths`, `Repair-Windows`, the installer and all future PSWinKit utilities. Russian equivalent: [README.ru.md](README.ru.md).

## 1. Scope and design principles

- Every utility must work fully **without mandatory command-line parameters**. Utility-specific optional parameters are allowed.
- Language selection, title, elevation, overall timing and shutdown live in `Common/Common.ps1`.
- Each utility owns its actual work, warnings, progress and final statistics.
- Do not create `UtilityHost`, `ElevatedHost` or other wrapper processes: UAC restarts the **main PS1 script itself**.
- Do not move utility-specific logic into Common or add speculative architectural complexity.
- This contract states the intended behavior; implementation must be verified on supported Windows versions.

## 2. Compatibility and file encoding

Baseline: **Windows 10+, Windows Server 2016+, Windows PowerShell 5.1**; x86/x64 where supported. Neither PowerShell 7+, unsupported legacy operating systems nor third-party dependencies may be required by the shared library.

All `.ps1` and `.psd1` files must use **UTF-8 with BOM**. Documentation is in Markdown, with equivalent English and Russian content.

## 3. Repository layout

```text
PSWinKit/
├── update.ps1
├── install.ps1
├── README.md
├── README.ru.md
├── Common/
│   ├── Common.ps1
│   ├── README.md
│   ├── README.ru.md
│   └── Languages/
│       ├── en.psd1
│       └── ru.psd1
├── Remove-Paths/
│   ├── Remove-Paths.ps1
│   ├── README.md
│   └── README.ru.md
└── Repair-Windows/
    ├── Repair-Windows.ps1
    ├── README.md
    └── README.ru.md
```

Future utilities have their own folders, but all translations are held centrally in Common/Languages. The shared library is dot-sourced relative to the utility's `$PSScriptRoot`:

```powershell
. (Join-Path $PSScriptRoot '..\Common\Common.ps1')
```

Never copy Common into utility folders or locate resources using the current working directory.

## 4. Main utility parameters

Running without any parameters is mandatory:

```powershell
.\Remove-Paths.ps1
```

Own optional parameters such as `[string[]]$Paths` or `[switch]$DryRun` are allowed. Main utilities **do not need to declare** `LanguageFile`, `PauseOnExit`, `RequireAdministrator` or `ScriptArguments` just for Common. The last name is not a Common API parameter.

For UAC relaunch, Common obtains the **direct caller script's** `$PSBoundParameters` via `Get-Variable -Name PSBoundParameters -Scope 1`, at the very beginning of `Start-Utility`. Therefore `Start-Utility` must be called **at top level in the main script**, never from an extra wrapper function.

Explicitly supplied values of `String`, `Boolean`, `SwitchParameter`, ordinary numeric types, and their one-dimensional arrays are preserved, including an explicit `$false`, an empty string and empty arrays. Defaults that were not explicitly bound are recalculated by the utility. Complex objects, `SecureString`, `PSCredential`, `ScriptBlock`, secrets and arbitrary object types are **not universally supported**; report an understandable error **before** relaunch rather than silently dropping arguments. Unbound positional arguments, `$args`, pipeline input and arbitrary process state are not automatically transferred.

## 5. Public functions

Common exposes **two public functions**:

| Function | Purpose |
| --- | --- |
| `Start-Utility` | Launch parameters, language, optional UAC, header and start time |
| `Stop-Utility` | Finish time, overall duration and final pause |

Internal helpers are allowed but must not become a required public API. A separate `Get-UtilityMessage` function is unnecessary: utility translations are accessed via `$utility.Messages`.

## 6. Start-Utility

A typical call for a tool that requires administrative rights:

```powershell
$utility = Start-Utility -ScriptPath $PSCommandPath -RequireAdministrator
if ($null -eq $utility) { return }
```

For a utility that does not need elevation, omit `-RequireAdministrator`.

| Parameter | Type | Required | Default |
| --- | --- | --- | --- |
| `ScriptPath` | `[string]` | Yes | — |
| `RequireAdministrator` | `[switch]` | No | `$false` |
| `LanguageFile` | `[string]` | No | Unspecified |
| `PauseOnExit` | `[switch]` | No | `$false` |

`ScriptPath` is the main script's `$PSCommandPath`. It determines the utility section (script basename), the title and UAC relaunch target. No `Utility`, `Program` or `Section` parameter is used.

**RequireAdministrator.** Check the actual elevated token (the Administrators role enabled in that token), not merely group membership. Request UAC only when required and not already elevated. The elevated process rechecks the token.

**LanguageFile.** Optional developer-level override when calling `Start-Utility`. By default, `Get-UICulture` determines the file: specific culture (`ru-RU.psd1`) → parent (`ru.psd1`) → required `en.psd1`. Explicit relative paths are resolved against **Common/Languages**. A missing file or non-PSD1 path is an initialization error. Preserve the chosen file across UAC even if another account has a different Windows UI language. A main utility need not expose its own `-LanguageFile` parameter.

**PauseOnExit.** Optional forced final pause. Pausing is also mandatory for interactive windows opened by Common through UAC; an existing terminal should not pause unnecessarily. Detection of launches from Explorer is best-effort only. Noninteractive usage should not intentionally block. UAC cancellation causes no pause.

**Return value.** On success, return `$utility`, holding `StartedAt`, a timer, `Messages`, the selected language, and pause state. If execution is delegated to an elevated process or UAC is canceled, return `$null`: the original script must return immediately **without its summary or Stop-Utility**. Other initialization errors are reported separately.

## 7. Header and start time

As soon as the actual worker has passed its privilege check, `Start-Utility` records start time and starts an independent monotonic `Stopwatch`, before the title and utility work. Waiting for UAC in the original process is not counted. The title is read from `Title` in the **utility's section**; the `Started` label belongs exclusively to Common:

```text
=== Remove files and directories ===
Started: 10/31/2026 10:42:39 PM

```

One blank line follows these two lines. The utility must not print another common title or start time. **Date and time use Windows regional `CurrentCulture` settings**, with seconds, independently of the UI language. The example is illustrative, not a fixed date pattern.

## 8. UAC elevation

1. Decide whether elevation is required and whether the token is already elevated.
2. If elevation is needed, capture the main script's explicitly bound parameters directly in `Start-Utility` and validate supported types.
3. Serialize arguments with `System.Management.Automation.PSSerializer`, preserving their values and types.
4. Build a command that invokes the **same main PS1**, keeping filenames, strings and parameters out of executable source. `powershell.exe -EncodedCommand` with UTF-16LE is allowed; Base64 is **not encryption**.
5. Use `Start-Process -Verb RunAs` with the same PowerShell architecture; reconstruct values using splatting. Carry the selected language and pause state through Common's internal mechanism, not new mandatory main-script arguments.
6. The original process returns `$null` after successful launch. The elevated script dot-sources Common and calls `Start-Utility` again.

Security rules: no `Invoke-Expression`, no unescaped user strings inserted as code, support spaces, apostrophes, quotes and non-ASCII paths, check command length, and avoid temporary files where possible. Never pass secrets on the command line. Keep x86/x64 architecture unchanged unless there is a specific need; preserve working directory where possible, noting that mapped network drives may not exist in the elevated context. **Do not use `-ExecutionPolicy Bypass` or override PowerShell execution policies.** The elevated utility must revalidate destructive inputs and protected paths.

If UAC is canceled (`ERROR_CANCELLED`, 1223), the original invocation exits without the operation, summary, pause or a fabricated deletion failure. Other launch errors must be diagnosed explicitly.

## 9. Localization and ownership

`Common/Languages/en.psd1` and `ru.psd1` contain all PSWinKit translations, grouped into nested sections: `Common`, `Remove-Paths`, `Repair-Windows`, `install`. The section name for a utility is the main `.ps1` filename without its extension. Each utility continues receiving its own **flat** `$utility.Messages` table; shared lifecycle strings are read only by Common. Example:

```powershell
# Common/Languages/en.psd1 (excerpt)
@{
    Common = @{ Started = 'Started: {0}' }
    'Remove-Paths' = @{ Title = 'Remove files and directories' }
    'Repair-Windows' = @{ Title = 'Repair Windows' }
    install = @{ Title = 'PSWinKit installation and update' }
}
```

`Start-Utility` loads the required section from the Windows UI language file and fills missing keys from the **same section** in `en.psd1`. Missing English sections or mandatory `Title` values are errors. A utility must never access the `Common` section directly. `LanguageFile`, when explicitly supplied by the developer, refers to a PSD1 in Common/Languages (or an absolute PSD1 path). No additional public function is required.

**Separate regional rule:** `CurrentCulture` determines formatting of dates, times and durations; `Get-UICulture` determines the language of labels. A Russian UI may use English regional dates. The hour/minute/second separator in durations comes from the regional time format. For one day or longer, display a day count with a localized suffix (`1d 03:24:15` or `1д 03:24:15`; the colons are illustrative). Utilities with per-operation timing follow the same rule. **Do not hard-code** `dd.MM.yyyy HH:mm:ss` or `d.hh:mm:ss` as universal formats.

## 10. Stop-Utility

```powershell
Stop-Utility -Utility $utility
```

The required `Utility` argument is the object returned by `Start-Utility`. Do not pass the script path, language or title again. `Stop-Utility` records the finish time and stops the global timer **immediately on invocation**. After the utility's own summary, it prints **one blank line** and two shared lines in light gray (`Gray`):

```text
Finished: 10/31/2026 10:43:12 PM
Duration: 00:00:33
```

Date/time and duration follow section 9. The word “Finished” is neutral; it does not assert that every action succeeded. Results, errors and numeric statistics are emitted by the utility itself **before** calling `Stop-Utility`. Any necessary final pause follows these two lines. Common does not print an additional summary.

Call `Stop-Utility` only after a successful `Start-Utility`, preferably in `finally`. An ordinary Ctrl+C may still unwind through `finally`; forcibly killing the process cannot guarantee execution.

## 11. Utility template

```powershell
#requires -Version 5.1
# Optional utility-specific parameters (if any) go here.

. (Join-Path $PSScriptRoot '..\Common\Common.ps1')
$utility = Start-Utility -ScriptPath $PSCommandPath -RequireAdministrator
if ($null -eq $utility) { return }

try {
    Write-Host $utility.Messages.WarningTitle
    # Utility-owned work.
}
catch {
    # Utility-owned error reporting.
}
finally {
    # The utility's summary comes first, if applicable.
    Stop-Utility -Utility $utility
}
```

Omit `-RequireAdministrator` for utilities that do not require it. Call `Start-Utility` directly at top level in the main script to capture bound parameters for UAC correctly.

## 12. Documentation

- **Repository root:** `README.md` and `README.ru.md` introduce the collection, available/planned utilities, requirements, license and links.
- **Common:** these two README files are the **complete technical contract**: public API, UAC, localization, timing and lifecycle. Do **not** create separate `CONTRACT.md`, `UTILITY-CONTRACT.md` or translated duplicates.
- **Each utility:** its own `README.md` and `README.ru.md` describe purpose, features, use, optional parameters, examples, limitations and warnings.

Avoid copying the full contract into root or utility README files; link to it instead.

## 13. Development rules

Prefer simple, maintainable code and built-in PowerShell 5.1 mechanisms. Do not change an agreed deletion or repair algorithm for cosmetic refactoring. Preserve native console output from `DISM`, `SFC`, `CHKDSK` and similar tools where practical. Use PSD1 for configuration, localization and machine-updated state. Check and diagnose critical operations. Suggest short English **Title** and **Description** for Git commits.

## 14. Contract changes

When changing Common, preserve compatibility or explicitly agree on a break; update **both** `Common/README.*` documents, and root/affected-utility READMEs when relevant; validate on actual Windows PowerShell 5.1. Requirements specific to a single utility belong in its own README and do not automatically become shared policy.

**Core principle:** common infrastructure, independent utilities, no mandatory parameters, minimal complexity.
