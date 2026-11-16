#Requires -Version 5.1
# Shared interactive choice prompt.
# Source explicitly from a PSWinKit utility after Common/Common.ps1.
# It has no side effects except console input/output.

function Read-PSWinKitChoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Prompt,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string[]]$Choices,
        [string]$Default,
        [Parameter(Mandatory = $true)][hashtable]$Messages
    )

    # This API intentionally accepts only single Latin letters. This is not a
    # numeric or free-text input function. A refusal is returned normally;
    # the caller decides whether N means skip, abort this task, or continue.
    $allowed = New-Object 'System.Collections.Generic.List[string]'
    foreach ($choice in $Choices) {
        if ($null -eq $choice) { throw 'Choice must be a single Latin letter.' }
        $letter = ([string]$choice).Trim().ToUpperInvariant()
        if ($letter -cnotmatch '^[A-Z]$') {
            throw ("Invalid choice '{0}': use one Latin letter." -f $choice)
        }
        if ($allowed.Contains($letter)) {
            throw ("Duplicate choice: {0}" -f $letter)
        }
        $allowed.Add($letter)
    }
    if ($allowed.Count -eq 0) { throw 'At least one choice is required.' }

    $hasDefault = $PSBoundParameters.ContainsKey('Default')
    if ($hasDefault) {
        $Default = $Default.Trim().ToUpperInvariant()
        if (-not $allowed.Contains($Default)) {
            throw ("Default choice '{0}' is not in the allowed choices." -f $Default)
        }
    }
    foreach ($key in @('ChoicePrompt', 'ChoicePromptDefault', 'ChoiceInvalid')) {
        if (-not $Messages.ContainsKey($key)) {
            throw ("Missing Common language key: {0}" -f $key)
        }
    }

    $letters = $allowed -join '/'
    $suffix = if ($hasDefault) {
        [string]::Format([string]$Messages.ChoicePromptDefault, $letters, $Default)
    } else {
        [string]::Format([string]$Messages.ChoicePrompt, $letters)
    }
    $question = $Prompt.TrimEnd() + ' ' + $suffix

    while ($true) {
        # Do not catch PipelineStoppedException (Ctrl+C): the utility's
        # existing catch/finally manages interruption and rescue-file cleanup.
        # Read-Host throws in noninteractive mode; never silently apply a
        # default to an unattended disk-modification command.
        $raw = Read-Host $question
        if ($null -eq $raw) { throw 'No console input was received.' }
        $answer = ([string]$raw).Trim().ToUpperInvariant()
        if ($answer.Length -eq 0 -and $hasDefault) { return $Default }
        if ($allowed.Contains($answer)) { return $answer }
        Write-Host ([string]::Format([string]$Messages.ChoiceInvalid, $letters)) `
            -ForegroundColor Yellow
    }
}
