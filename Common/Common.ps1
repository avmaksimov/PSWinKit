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

function Test-PSWinKitSkipPause([string]$CommandLine) {
    # Be conservative: return true only for a proven interactive shell, an
    # explicit -NoExit launch or a -NonInteractive process that cannot read keys.
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    $launch = [regex]::Match($CommandLine,
        '^\s*(?:"[^"]+"|\S+)(?:\s+(?<Options>.*))?\s*$')
    if (-not $launch.Success) { return $false }
    $remaining = [string]$launch.Groups['Options'].Value
    $noExit = $false
    while ($true) {
        $remaining = $remaining.TrimStart()
        if (-not $remaining) { return $true }
        $option = [regex]::Match($remaining,
            '(?i)^-(?<Name>[a-z][a-z0-9-]*)(?=\s|:|$)')
        if (-not $option.Success) { return $false }
        $name = $option.Groups['Name'].Value
        $remaining = $remaining.Substring($option.Length)
        if ($name -match '^(NoExit)$') {
            $noExit = $true
            continue
        }
        if ($name -match '^(NonInteractive)$') { return $true }
        if ($name -match '^(File|F|Command|C|EncodedCommand|EncodedComman|Enc|E)$') {
            return $noExit
        }
        if ($name -match '^(NoProfile|NoLogo|Sta|Mta)$') { continue }
        if ($name -match '^(ExecutionPolicy|Ep|InputFormat|OutputFormat|Version|WorkingDirectory)$') {
            # Consume the option value; if it cannot be identified, keep the pause.
            $value = [regex]::Match($remaining,
                '^\s*:?(?:"[^"]+"|[^-\s:]\S*)')
            if (-not $value.Success) { return $false }
            $valueText = $value.Value.TrimStart() -replace '^:', ''
            if ($valueText -match '^"?-') { return $false }
            $remaining = $remaining.Substring($value.Length)
            continue
        }
        return $false
    }
}

function Test-PSWinKitPauseRequired {
    # Fail-safe default is to pause. Avoid blocking noninteractive hosts.
    if (-not [Environment]::UserInteractive) { return $false }
    try {
        if ($Host.Name -ine 'ConsoleHost') { return $true }
        $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
        if ($null -eq $process) { return $true }
        return (-not (Test-PSWinKitSkipPause ([string]$process.CommandLine)))
    } catch {
        return $true
    }
}

# PowerShell paths (including provider-qualified UNC paths and PSDrives) are
# not necessarily valid arguments for System.IO or the .NET PowerShell parser.
# FileInfo.FullName supplies the native filesystem path without evaluating code.
function Resolve-PSWinKitLanguageFilePath {
    param([Parameter(Mandatory = $true)][string]$File)
    $item = Get-Item -LiteralPath $File -ErrorAction Stop
    if ($item -isnot [IO.FileInfo] -or
        [IO.Path]::GetExtension($item.FullName) -ine '.psd1') {
        throw "Language file not found or not PSD1: $File"
    }
    return $item.FullName
}

function Find-PSWinKitLanguageFile {
    param(
        [Parameter(Mandatory = $true)][string]$Folder,
        [string]$Language,
        [switch]$Explicit
    )
    if ($Explicit) {
        # A provider-qualified FileSystem path is absolute in PowerShell even
        # though System.IO.Path.IsPathRooted does not recognize its prefix.
        $candidate = if ([IO.Path]::IsPathRooted($Language) -or $Language -match '^[^:]+::') {
            $Language
        } else { Join-Path $Folder $Language }
        return (Resolve-PSWinKitLanguageFilePath -File $candidate)
    }
    if ($Language) {
        try { $culture = [Globalization.CultureInfo]::GetCultureInfo($Language) }
        catch { $culture = $null }
    }
    else { $culture = Get-UICulture }
    while ($culture -and $culture.Name) {
        $candidate = Join-Path $Folder ($culture.Name + '.psd1')
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-PSWinKitLanguageFilePath -File $candidate)
        }
        $culture = $culture.Parent
    }
    $english = Join-Path $Folder 'en.psd1'
    if (-not (Test-Path -LiteralPath $english -PathType Leaf)) {
        throw "English language file missing: $english"
    }
    return (Resolve-PSWinKitLanguageFilePath -File $english)
}

# PSD1 is data, not executable code. PowerShell 5.1's Import-PowerShellDataFile
# rejects files with over 500 keys; the in-memory hashtable has no such limit.
# Use the built-in .NET PowerShell parser and accept only literal strings and
# nested hashtables. Never evaluate the file or create a script block from it.
function Convert-PSWinKitLanguageAst {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.HashtableAst]$HashtableAst,
        [Parameter(Mandatory = $true)][string]$File
    )
    $result = @{}
    foreach ($pair in $HashtableAst.KeyValuePairs) {
        if ($pair.Item1 -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            throw "Language key must be a literal string: $File (line $($pair.Item1.Extent.StartLineNumber))"
        }
        $key = [string]$pair.Item1.Value
        if ([string]::IsNullOrEmpty($key) -or $result.ContainsKey($key)) {
            throw "Empty or duplicate language key: $key ($File)"
        }
        if ($pair.Item2 -isnot [System.Management.Automation.Language.PipelineAst]) {
            throw "Invalid language value for '$key': $File"
        }
        $value = $pair.Item2.GetPureExpression()
        if ($value -is [System.Management.Automation.Language.HashtableAst]) {
            $result[$key] = Convert-PSWinKitLanguageAst -HashtableAst $value -File $File
        } elseif ($value -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $result[$key] = $value.Value
        } else {
            throw "Language value must be a literal string or hashtable: $key ($File)"
        }
    }
    return $result
}

function Import-PSWinKitLanguageData {
    param([Parameter(Mandatory = $true)][string]$File)

    $File = Resolve-PSWinKitLanguageFilePath -File $File
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $File, [ref]$tokens, [ref]$parseErrors)
    if ($null -eq $ast -or $parseErrors.Count -gt 0) {
        $details = if ($parseErrors.Count -gt 0) { [string]$parseErrors[0].Message } else { 'Unknown parser error.' }
        throw "Invalid PSD1 language file: $File. $details"
    }
    # Exactly one hashtable literal is allowed at file scope.
    if ($null -ne $ast.ParamBlock -or $null -ne $ast.BeginBlock -or
        $null -ne $ast.ProcessBlock -or $null -ne $ast.DynamicParamBlock -or
        $null -eq $ast.EndBlock -or $ast.EndBlock.Statements.Count -ne 1 -or
        $ast.EndBlock.Statements[0] -isnot [System.Management.Automation.Language.PipelineAst]) {
        throw "Expected one PSD1 hashtable and no executable statements: $File"
    }
    $expression = $ast.EndBlock.Statements[0].GetPureExpression()
    if ($expression -isnot [System.Management.Automation.Language.HashtableAst]) {
        throw "Expected one PSD1 hashtable: $File"
    }
    return (Convert-PSWinKitLanguageAst -HashtableAst $expression -File $File)
}

function Import-PSWinKitTranslations {
    param([string]$Folder, [string]$SelectedFile, [string]$Section, [switch]$RequireTitle)
    $fallbackCandidate = Join-Path $Folder 'en.psd1'
    if (-not (Test-Path -LiteralPath $fallbackCandidate -PathType Leaf)) {
        throw "English language file missing: $fallbackCandidate"
    }
    $fallbackFile = Resolve-PSWinKitLanguageFilePath -File $fallbackCandidate
    $SelectedFile = Resolve-PSWinKitLanguageFilePath -File $SelectedFile
    $fallback = Import-PSWinKitLanguageData -File $fallbackFile
    $selected = if ($SelectedFile -ieq $fallbackFile) {
        $fallback
    } else {
        Import-PSWinKitLanguageData -File $SelectedFile
    }
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

# Capture known user folders while HKCU and environment belong to the user
# who INITIATED the utility, before a possible UAC credential switch.
function Get-PSWinKitUserFolderSnapshot {
    $paths = @{}
    $sid = ''
    try { $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }
    $special = @{
        UserProfile = 'UserProfile'
        Desktop = 'Desktop'
        Documents = 'MyDocuments'
        Pictures = 'MyPictures'
        Music = 'MyMusic'
        Videos = 'MyVideos'
        RoamingAppData = 'ApplicationData'
        LocalAppData = 'LocalApplicationData'
    }
    foreach ($key in $special.Keys) {
        try {
            $value = [Environment]::GetFolderPath([Environment+SpecialFolder]([string]$special[$key]))
            if (-not [string]::IsNullOrWhiteSpace($value) -and
                (Test-Path -LiteralPath $value -PathType Container -ErrorAction SilentlyContinue)) {
                $paths[$key] = [string]$value
            }
        } catch { }
    }
    if (-not $paths.ContainsKey('UserProfile') -and $env:USERPROFILE -and
        (Test-Path -LiteralPath $env:USERPROFILE -PathType Container -ErrorAction SilentlyContinue)) {
        $paths['UserProfile'] = [string]$env:USERPROFILE
    }
    if ($env:TEMP -and (Test-Path -LiteralPath $env:TEMP -PathType Container -ErrorAction SilentlyContinue)) {
        $paths['TEMP'] = [string]$env:TEMP
    }

    # Downloads has no Environment.SpecialFolder entry. The registry is also
    # a fallback when another Known Folder is not available through .NET.
    $registryNames = @{
        Downloads = '{374DE290-123F-4565-9164-39C4925E467B}'
        Desktop = 'Desktop'
        Documents = 'Personal'
        Pictures = 'My Pictures'
        Music = 'My Music'
        Videos = 'My Video'
        RoamingAppData = 'AppData'
        LocalAppData = 'Local AppData'
    }
    try {
        $userFolders = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop
        foreach ($key in $registryNames.Keys) {
            if ($paths.ContainsKey($key)) { continue }
            $value = [string]$userFolders.($registryNames[$key])
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $expanded = [Environment]::ExpandEnvironmentVariables($value)
                if (Test-Path -LiteralPath $expanded -PathType Container -ErrorAction SilentlyContinue) {
                    $paths[$key] = $expanded
                }
            }
        }
    } catch { }
    return @{ SID = $sid; Paths = $paths }
}

function Start-Utility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [switch]$RequireAdministrator,
        [string]$LanguageFile
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
    $inheritedUserFolders = [Environment]::GetEnvironmentVariable('PSWINKIT_INTERNAL_USER_FOLDERS')
    [Environment]::SetEnvironmentVariable('PSWINKIT_INTERNAL_LANGUAGE', $null, 'Process')
    [Environment]::SetEnvironmentVariable('PSWINKIT_INTERNAL_ELEVATED', $null, 'Process')
    [Environment]::SetEnvironmentVariable('PSWINKIT_INTERNAL_USER_FOLDERS', $null, 'Process')
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
        $originalUserFolders = Get-PSWinKitUserFolderSnapshot
        $foldersXml = [Management.Automation.PSSerializer]::Serialize($originalUserFolders)
        $folders64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($foldersXml))
        $code = @"
`$payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$args64'))
`$raw = [Management.Automation.PSSerializer]::Deserialize(`$payload)
if (-not (`$raw -is [Collections.IDictionary])) { throw 'Invalid PSWinKit UAC argument data.' }
`$arguments = @{}
foreach (`$key in `$raw.Keys) { `$arguments[[string]`$key] = `$raw[`$key] }
`$env:PSWINKIT_INTERNAL_LANGUAGE = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$lang64'))
`$env:PSWINKIT_INTERNAL_ELEVATED = '1'
`$env:PSWINKIT_INTERNAL_USER_FOLDERS = '$folders64'
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

    # Only a relaunch made by Start-Utility has the original user's snapshot.
    # A directly elevated launch uses the currently logged-on account instead.
    if ($inheritedElevation -eq '1') {
        if ([string]::IsNullOrEmpty($inheritedUserFolders)) {
            throw 'Original user folder context was not passed through UAC.'
        }
        try {
            $folderXml = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($inheritedUserFolders))
            $originalUserFolders = [Management.Automation.PSSerializer]::Deserialize($folderXml)
            if (-not ($originalUserFolders -is [Collections.IDictionary]) -or
                -not ($originalUserFolders.Paths -is [Collections.IDictionary])) {
                throw 'Invalid original user folder context.'
            }
        } catch { throw ('Unable to restore original user folders: ' + $_.Exception.Message) }
    } else {
        $originalUserFolders = Get-PSWinKitUserFolderSnapshot
    }

    # The actual worker owns both clocks. UAC waiting is not included in duration.
    $startedAt = Get-Date
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $pause = [bool](Test-PSWinKitPauseRequired)
    $utility = [pscustomobject]@{
        StartedAt      = $startedAt
        Stopwatch      = $watch
        Language       = $selectedCulture
        LanguageFile   = $selectedFile
        Messages       = $utilityMessages
        CommonMessages = $commonMessages
        PauseOnExit     = $pause
        InterruptedByUser = $false
        OriginalUserFolders = $originalUserFolders
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
    if ($Utility.PSObject.Properties.Match('InterruptedByUser').Count -gt 0 -and
        [bool]$Utility.InterruptedByUser) {
        # Ctrl+C can stop the PowerShell output pipeline. Prefer writing the
        # cancellation notice directly to the console; do not alter Ctrl+C.
        $notice = Get-PSWinKitText -Messages $commonMessages -Key 'InterruptedByUser'
        try {
            $oldColor = [Console]::ForegroundColor
            try {
                [Console]::ForegroundColor = [ConsoleColor]::Red
                [Console]::Error.WriteLine([Environment]::NewLine)
                [Console]::Error.WriteLine($notice)
            } finally {
                [Console]::ForegroundColor = $oldColor
            }
        } catch {
            try { Write-Host ''; Write-Host ''; Write-Host $notice -ForegroundColor Red } catch { }
        }
    }
    Write-Host ''
    Write-Host (Get-PSWinKitText -Messages $commonMessages -Key 'Finished' `
        -Values @((Format-PSWinKitDateTime $finishedAt))) -ForegroundColor Gray
    Write-Host (Get-PSWinKitText -Messages $commonMessages -Key 'Duration' `
        -Values @((Format-PSWinKitDuration -Value $elapsed -Messages $commonMessages))) -ForegroundColor Gray

    if ($Utility.PauseOnExit) {
        try {
            Write-Host ''
            Write-Host (Get-PSWinKitText -Messages $commonMessages -Key 'PressAnyKey') -ForegroundColor DarkGray
            try { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
            catch { [void](Read-Host (Get-PSWinKitText -Messages $commonMessages -Key 'PressEnter')) }
        }
        catch { }
    }
}
