# Shared messages for Windows PowerShell 5.1 utilities.
# UTF-8 with BOM. Positional placeholders: {0}, {1}, ...
# Each utility owns its own section; Common and Host are shared.
@{
    Common = @{
        YesNo        = '(Y/N)'
        SummaryTitle = '--- Final summary ---'
        InvalidYesNo = 'Enter Y or N. There is no default.'
        Completed    = 'Completed'
    }

    Host = @{
        RequestElevation = 'Requesting administrator privileges...'
        ElevationFailed  = 'Administrator privileges were not obtained after relaunch.'
        StartFailed      = 'Startup error: {0}'
        PressAnyKey      = 'Press any key to close this window...'
        PressEnter       = 'Press Enter'
    }

    RemovePaths = @{
        Title               = 'Remove files and directories'
        PhaseStart          = 'Starting'
        PhaseEntry          = 'Entering paths'
        PhaseValidation     = 'Validating paths'
        PhaseConfirmation   = 'Waiting for confirmation'
        PhaseDeletion       = 'Deleting'
        PhaseDone           = 'Finished'
        StatusInterrupted   = 'Interrupted before completion (possibly Ctrl+C)'
        StatusEmpty         = 'No paths entered; nothing deleted'
        StatusNoValid       = 'No valid paths; nothing deleted'
        StatusCancelled     = 'Cancelled by user (N); nothing deleted'
        StatusPartial       = 'Completed with errors'
        StatusError         = 'Execution error'
        Intro               = 'Enter paths to delete, one per line.'
        Instructions        = 'Press Enter on an empty line to finish. Nothing is deleted until confirmation.'
        Protection          = 'C:\Users and other important system folders on drive C are protected.'
        PathPrompt          = 'Path'
        AbsolutePath        = 'An absolute local drive path is required, e.g. D:\Windows.'
        SubstBlocked        = 'SUBST drive paths are not supported.'
        ProtectedPath       = 'Protected system path.'
        UnsupportedName     = 'Short (8.3) names and trailing spaces/dots are not supported.'
        AncestorLink        = 'An intermediate path component is an NTFS link: {0}'
        PreviewTitle        = '--- Deletion preview ---'
        PreviewDelete       = 'DELETE'
        PreviewLink         = 'LINK'
        PreviewSkip         = 'SKIPPED'
        PreviewCounts       = 'Queued: {0}; skipped: {1}'
        Confirm             = 'Delete the listed items permanently'
        Removing            = 'Removing: {0}'
        Deleted             = 'Deleted.'
        PartialWarning      = 'Some items remain. See the final summary.'
        FailedWarning       = 'Could not delete: {0}'
        CantReadDirectory   = 'Cannot read directory: {0}'
        LinkNotDeleted      = 'Link not deleted; permissions on its target were not changed.'
        AccessBlocked       = 'Cannot change permissions on: {0}'
        TakeOwnershipFailed = 'Failed to take ownership: {0}'
        InheritanceFailed   = 'Failed to enable inheritance: {0}'
        GrantFailed         = 'Failed to grant full control: {0}'
        SummaryResult       = 'Result: {0}'
        SummaryPhase        = 'Phase: {0}'
        SummaryInput        = 'Paths entered: {0}'
        SummaryTargets      = 'Targets: {0}; skipped during validation: {1}'
        SummaryStarted      = 'Started: {0}; fully deleted: {1}; not fully deleted: {2}'
        SummaryUnstarted    = 'Not started: {0}'
        SummaryCurrent      = 'Interrupted at: {0}'
        SummaryObjects      = 'Objects deleted: {0} (links: {1})'
        SummaryPermissions  = 'Objects with repaired permissions: {0}'
        SummaryErrors       = 'Errors recorded: {0}'
        SummaryTruncated    = 'Only the first 15 errors are shown.'
    }

}
