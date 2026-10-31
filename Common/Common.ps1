#requires -Version 5.1
<#
Shared utility functions (dot-source from the main script).
The utility itself is relaunched for UAC; the library never launches itself.
#>

# Capture the common directory while this file is dot-sourced.
$script:UtilityCommonRoot = $PSScriptRoot

function Test-UtilityAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-UtilityStandaloneLaunch {
    # Explorer launch usually owns a short-lived console.
    # Parent process information is not proof of console ownership.
    try {
        $current = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
        if (-not $current -or -not $current.ParentProcessId) { return $false }
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($current.ParentProcessId)" -ErrorAction Stop
        if (-not $parent) { return $false }
        if ([datetime]$parent.CreationDate -gt [datetime]$current.CreationDate) { return $false }
        return ($parent.Name -ieq 'explorer.exe')
    }
    catch { return $false }
}

function Resolve-UtilityLanguageFile {
    param([string]$Requested)

    $languages = Join-Path $script:UtilityCommonRoot 'Languages'
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $path = if ([IO.Path]::IsPathRooted($Requested)) {
            [IO.Path]::GetFullPath($Requested)
        }
        else { [IO.Path]::GetFullPath((Join-Path $languages $Requested)) }
        if (-not [IO.File]::Exists($path)) { throw "Language file not found: $path" }
        if ([IO.Path]::GetExtension($path) -ine '.psd1') {
            throw "Expected a .psd1 language file: $path"
        }
        return $path
    }

    # Try the UI culture, its neutral parents, and finally mandatory English.
    # Example: zh-Hans-CN -> zh-Hans -> zh -> en.
    $culture = Get-UICulture
    while ($culture -and -not [string]::IsNullOrEmpty($culture.Name)) {
        $candidate = Join-Path $languages ($culture.Name + '.psd1')
        if ([IO.File]::Exists($candidate)) { return [IO.Path]::GetFullPath($candidate) }
        $culture = $culture.Parent
    }

    $fallback = Join-Path $languages 'en.psd1'
    if ([IO.File]::Exists($fallback)) { return [IO.Path]::GetFullPath($fallback) }
    throw "Fallback language file missing: $fallback"
}

function Test-UtilityUacCancelled {
    param([Parameter(Mandatory = $true)][Exception]$Exception)

    # UAC cancellation is Win32 ERROR_CANCELLED (1223 / 0x800704C7).
    # Search the inner exception chain because Start-Process can wrap it.
    $errorObject = $Exception
    while ($null -ne $errorObject) {
        if ($errorObject -is [ComponentModel.Win32Exception] -and
            $errorObject.NativeErrorCode -eq 1223) { return $true }
        if ($errorObject.HResult -eq -2147023673) { return $true }
        $errorObject = $errorObject.InnerException
    }
    return $false
}

function Get-UtilityMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][hashtable]$Messages,
        [object[]]$Values = @()
    )
    $parts = $Key.Split('.')
    if ($parts.Count -ne 2 -or
        -not $Messages.ContainsKey($parts[0]) -or
        -not ($Messages[$parts[0]] -is [hashtable]) -or
        -not $Messages[$parts[0]].ContainsKey($parts[1])) {
        throw "Missing language key: $Key"
    }
    $template = [string]$Messages[$parts[0]][$parts[1]]
    if ($Values.Count -eq 0) { return $template }
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture,
                            $template, [object[]]$Values)
}

function Start-Utility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$Section,
        [string]$LanguageFile,
        [switch]$PauseOnExit,
        [switch]$RequireAdministrator
    )

    $scriptPathResolved = [IO.Path]::GetFullPath($ScriptPath)
    if (-not [IO.File]::Exists($scriptPathResolved)) {
        throw "Script not found: $scriptPathResolved"
    }

    $languagePath = Resolve-UtilityLanguageFile -Requested $LanguageFile

    if ($RequireAdministrator -and -not (Test-UtilityAdministrator)) {
        # Language path is carried across UAC; object serialization is unnecessary.
        # The original process returns $null whether elevation was started or declined.
        $messages = Import-PowerShellDataFile -LiteralPath $languagePath -ErrorAction Stop
        Write-Host (Get-UtilityMessage -Key 'Host.RequestElevation' -Messages $messages) -ForegroundColor Yellow

        $exe = Join-Path $PSHOME 'powershell.exe'
        $argumentLine = '-NoProfile -ExecutionPolicy Bypass -File "' +
            $scriptPathResolved + '" -LanguageFile "' + $languagePath + '" -PauseOnExit'
        try {
            Start-Process -FilePath $exe -ArgumentList $argumentLine -Verb RunAs `
                -WorkingDirectory ([IO.Path]::GetDirectoryName($scriptPathResolved)) `
                -ErrorAction Stop | Out-Null
        }
        catch {
            if (Test-UtilityUacCancelled -Exception $_.Exception) { return $null }
            throw
        }
        return $null
    }

    # Only the active process loads and uses the localization for its work.
    $messages = Import-PowerShellDataFile -LiteralPath $languagePath -ErrorAction Stop
    if (-not ($messages -is [hashtable])) {
        throw "Invalid language data file: $languagePath"
    }

    $title = Get-UtilityMessage -Key ($Section + '.Title') -Messages $messages
    Write-Host ('=== {0} ===' -f $title) -ForegroundColor Cyan

    return [pscustomobject]@{
        LanguageFile = $languagePath
        Messages     = $messages
        PauseOnExit  = [bool]($PauseOnExit -or (Test-UtilityStandaloneLaunch))
    }
}

function Stop-Utility {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)

    if (-not $Context.PauseOnExit) { return }
    try {
        $messages = $Context.Messages
        Write-Host "`n$(Get-UtilityMessage -Key 'Host.PressAnyKey' -Messages $messages)" -ForegroundColor DarkGray
        try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
        catch { [void](Read-Host (Get-UtilityMessage -Key 'Host.PressEnter' -Messages $messages)) }
    }
    catch { }
}
