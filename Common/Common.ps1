#requires -Version 5.1
<#
PSWinKit shared lifecycle (Windows PowerShell 5.1).
Public interface: Start-Utility, Stop-Utility.
All other functions below are internal implementation details.
#>

$script:PSWinKitCommonRoot = $PSScriptRoot

function Test-PSWinKitAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    # Under UAC a filtered, unelevated administrator token does not have this role enabled.
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-PSWinKitStandalone {
    # Best effort only; Explorer launches normally need a final pause.
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

function Find-PSWinKitLanguageFile {
    param(
        [Parameter(Mandatory = $true)][string]$Folder,
        [string]$Language,
        [switch]$Explicit
    )
    if ($Explicit) {
        $resolved = if ([IO.Path]::IsPathRooted($Language)) {
            [IO.Path]::GetFullPath($Language)
        }
        else { [IO.Path]::GetFullPath((Join-Path $Folder $Language)) }
        if ([IO.Path]::GetExtension($resolved) -ine '.psd1' -or -not [IO.File]::Exists($resolved)) {
            throw "Language file not found or not PSD1: $resolved"
        }
        return $resolved
    }
    if ($Language) {
        try { $culture = [Globalization.CultureInfo]::GetCultureInfo($Language) }
        catch { $culture = $null }
    }
    else { $culture = Get-UICulture }
    while ($culture -and $culture.Name) {
        $candidate = Join-Path $Folder ($culture.Name + '.psd1')
        if ([IO.File]::Exists($candidate)) { return [IO.Path]::GetFullPath($candidate) }
        $culture = $culture.Parent
    }
    $english = Join-Path $Folder 'en.psd1'
    if (-not [IO.File]::Exists($english)) { throw "English language file missing: $english" }
    return [IO.Path]::GetFullPath($english)
}

function Import-PSWinKitTranslations {
    param([string]$Folder, [string]$SelectedFile, [string]$Section, [switch]$RequireTitle)
    $fallbackFile = Join-Path $Folder 'en.psd1'
    if (-not [IO.File]::Exists($fallbackFile)) { throw "English language file missing: $fallbackFile" }
    $fallback = Import-PowerShellDataFile -LiteralPath $fallbackFile -ErrorAction Stop
    $selected = Import-PowerShellDataFile -LiteralPath $SelectedFile -ErrorAction Stop
    if (-not ($fallback -is [hashtable]) -or -not ($selected -is [hashtable])) {
        throw "Invalid translation table: $SelectedFile"
    }
    if (-not $fallback.ContainsKey($Section) -or -not ($fallback[$Section] -is [hashtable])) {
        throw "Missing English language section: $Section ($fallbackFile)"
    }
    $englishSection = $fallback[$Section]
    $localSection = @{}
    if ($selected.ContainsKey($Section)) {
        if (-not ($selected[$Section] -is [hashtable])) {
            throw "Invalid language section: $Section ($SelectedFile)"
        }
        $localSection = $selected[$Section]
    }
    if ($RequireTitle -and (-not $englishSection.ContainsKey('Title') -or
        [string]::IsNullOrWhiteSpace([string]$englishSection['Title']))) {
        throw "Missing mandatory Title in English section: $Section ($fallbackFile)"
    }
    $messages = @{}
    foreach ($key in $englishSection.Keys) { $messages[$key] = $englishSection[$key] }
    foreach ($key in $localSection.Keys) { $messages[$key] = $localSection[$key] }
    return $messages
}

function Get-PSWinKitText {
    param([hashtable]$Messages, [string]$Key, [object[]]$Values = @())
    if (-not $Messages.ContainsKey($Key)) { throw "Missing Common language key: $Key" }
    $template = [string]$Messages[$Key]
    if ($Values.Count -eq 0) { return $template }
    return [string]::Format([Globalization.CultureInfo]::CurrentCulture, $template, [object[]]$Values)
}

function Format-PSWinKitDateTime {
    param([datetime]$Value)
    return $Value.ToString('G', [Globalization.CultureInfo]::CurrentCulture)
}

function Format-PSWinKitDuration {
    param([timespan]$Value, [hashtable]$Messages)
    $separator = [Globalization.CultureInfo]::CurrentCulture.DateTimeFormat.TimeSeparator
    $clock = '{0:00}{3}{1:00}{3}{2:00}' -f $Value.Hours, $Value.Minutes, $Value.Seconds, $separator
    $days = [long][Math]::Floor($Value.TotalDays)
    if ($days -gt 0) {
        $number = $days.ToString('N0', [Globalization.CultureInfo]::CurrentCulture)
        return ($number + (Get-PSWinKitText -Messages $Messages -Key 'DaySuffix') + ' ' + $clock)
    }
    return $clock
}

function Test-PSWinKitSimpleValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [string] -or $Value -is [bool] -or
        $Value -is [Management.Automation.SwitchParameter] -or
        $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) { return $true }
    if ($Value -is [array]) {
        foreach ($item in $Value) {
            if ($item -is [array] -or -not (Test-PSWinKitSimpleValue -Value $item)) { return $false }
        }
        return $true
    }
    return $false
}

function Test-PSWinKitUacCancelled {
    param([Exception]$Exception)
    while ($null -ne $Exception) {
        if ($Exception -is [ComponentModel.Win32Exception] -and
            $Exception.NativeErrorCode -eq 1223) { return $true }
        if ($Exception.HResult -eq -2147023673) { return $true }
        $Exception = $Exception.InnerException
    }
    return $false
}

function Start-Utility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [switch]$RequireAdministrator,
        [string]$LanguageFile,
        [switch]$PauseOnExit
    )

    # IMPORTANT: read the direct caller's PSBoundParameters at scope 1, not inside a helper.
    $bound = Get-Variable -Name PSBoundParameters -Scope 1 -ValueOnly -ErrorAction SilentlyContinue
    $explicitParameters = @{}
    if ($bound -is [Collections.IDictionary]) {
        foreach ($name in $bound.Keys) { $explicitParameters[[string]$name] = $bound[$name] }
    }

    $scriptFile = [IO.Path]::GetFullPath($ScriptPath)
    if (-not [IO.File]::Exists($scriptFile)) { throw "Script not found: $scriptFile" }
    $utilityRoot = [IO.Path]::GetDirectoryName($scriptFile)
    # The main script's basename selects one section of the central dictionary.
    # Utility messages remain flat via $utility.Messages.
    $utilitySection = [IO.Path]::GetFileNameWithoutExtension($scriptFile)
    $languageFolder = Join-Path $script:PSWinKitCommonRoot 'Languages'

    # Internal values are set only by the elevated launch command, not script parameters.
    $inheritedLanguage = [Environment]::GetEnvironmentVariable('PSWINKIT_INTERNAL_LANGUAGE')
    $inheritedElevation = [Environment]::GetEnvironmentVariable('PSWINKIT_INTERNAL_ELEVATED')
    [Environment]::SetEnvironmentVariable('PSWINKIT_INTERNAL_LANGUAGE', $null, 'Process')
    [Environment]::SetEnvironmentVariable('PSWINKIT_INTERNAL_ELEVATED', $null, 'Process')
    if (-not $LanguageFile -and $inheritedLanguage) { $LanguageFile = $inheritedLanguage }

    $explicitLanguage = -not [string]::IsNullOrEmpty($LanguageFile)
    $selectedFile = Find-PSWinKitLanguageFile -Folder $languageFolder -Language $LanguageFile -Explicit:$explicitLanguage
    $selectedCulture = [IO.Path]::GetFileNameWithoutExtension($selectedFile)
    $utilityMessages = Import-PSWinKitTranslations -Folder $languageFolder -SelectedFile $selectedFile -Section $utilitySection -RequireTitle
    if (-not $utilityMessages.ContainsKey('Title') -or -not [string]$utilityMessages['Title']) {
        throw "Missing mandatory Title in utility translations: $selectedFile ($utilitySection)"
    }
    $commonMessages = Import-PSWinKitTranslations -Folder $languageFolder -SelectedFile $selectedFile -Section 'Common'

    if ($RequireAdministrator -and -not (Test-PSWinKitAdministrator)) {
        if ($inheritedElevation -eq '1') {
            throw (Get-PSWinKitText -Messages $commonMessages -Key 'ElevationFailed')
        }
        foreach ($name in $explicitParameters.Keys) {
            $value = $explicitParameters[$name]
            if (-not (Test-PSWinKitSimpleValue -Value $value)) {
                $type = if ($null -eq $value) { 'null' } else { $value.GetType().FullName }
                throw "Unsupported UAC parameter -$name ($type). Only simple values and arrays are supported."
            }
            if ($value -is [Management.Automation.SwitchParameter]) {
                $explicitParameters[$name] = [bool]$value
            }
        }
        # Serialization is data-only; all inserted literals below are base64, never user code.
        $xml = [Management.Automation.PSSerializer]::Serialize($explicitParameters)
        $args64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($xml))
        $path64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($scriptFile))
        $lang64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($selectedFile))
        $code = @"
`$payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$args64'))
`$raw = [Management.Automation.PSSerializer]::Deserialize(`$payload)
if (-not (`$raw -is [Collections.IDictionary])) { throw 'Invalid PSWinKit UAC argument data.' }
`$arguments = @{}
foreach (`$key in `$raw.Keys) { `$arguments[[string]`$key] = `$raw[`$key] }
`$env:PSWINKIT_INTERNAL_LANGUAGE = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$lang64'))
`$env:PSWINKIT_INTERNAL_ELEVATED = '1'
`$scriptFile = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$path64'))
& `$scriptFile @arguments
"@
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $argumentLine = '-NoProfile -EncodedCommand ' + $encodedCommand
        if ($argumentLine.Length -ge 30000) {
            throw 'Too many UAC arguments: the encoded command exceeds the safe Windows command-line length.'
        }
        $exe = Join-Path $PSHOME 'powershell.exe' # Retains x86/x64 bitness.
        $workdir = $utilityRoot
        try {
            if ($PWD.Provider.Name -eq 'FileSystem' -and [IO.Directory]::Exists($PWD.ProviderPath)) {
                $workdir = $PWD.ProviderPath
            }
        }
        catch { }
        Write-Host (Get-PSWinKitText -Messages $commonMessages -Key 'RequestElevation') -ForegroundColor Yellow
        try {
            Start-Process -FilePath $exe -ArgumentList $argumentLine -Verb RunAs `
                -WorkingDirectory $workdir -ErrorAction Stop | Out-Null
        }
        catch {
            if (Test-PSWinKitUacCancelled -Exception $_.Exception) { return $null }
            throw
        }
        return $null
    }

    # The actual worker owns both clocks. UAC waiting is not included in duration.
    $startedAt = Get-Date
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $pause = [bool]([Environment]::UserInteractive -and
        ($PauseOnExit -or ($inheritedElevation -eq '1') -or (Test-PSWinKitStandalone)))
    $utility = [pscustomobject]@{
        StartedAt      = $startedAt
        Stopwatch      = $watch
        Language       = $selectedCulture
        LanguageFile   = $selectedFile
        Messages       = $utilityMessages
        CommonMessages = $commonMessages
        PauseOnExit     = $pause
    }
    Write-Host ('=== {0} ===' -f [string]$utilityMessages['Title']) -ForegroundColor Cyan
    Write-Host (Get-PSWinKitText -Messages $commonMessages -Key 'Started' -Values @((Format-PSWinKitDateTime $startedAt))) -ForegroundColor Gray
    Write-Host ''
    return $utility
}

function Stop-Utility {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Utility)

    $finishedAt = Get-Date
    $Utility.Stopwatch.Stop()
    $elapsed = $Utility.Stopwatch.Elapsed
    $commonMessages = $Utility.CommonMessages
    Write-Host ''
    Write-Host (Get-PSWinKitText -Messages $commonMessages -Key 'Finished' `
        -Values @((Format-PSWinKitDateTime $finishedAt))) -ForegroundColor Gray
    Write-Host (Get-PSWinKitText -Messages $commonMessages -Key 'Duration' `
        -Values @((Format-PSWinKitDuration -Value $elapsed -Messages $commonMessages))) -ForegroundColor Gray

    if ($Utility.PauseOnExit) {
        try {
            Write-Host "`n$(Get-PSWinKitText -Messages $commonMessages -Key 'PressAnyKey')" -ForegroundColor DarkGray
            try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
            catch { [void](Read-Host (Get-PSWinKitText -Messages $commonMessages -Key 'PressEnter')) }
        }
        catch { }
    }
}
