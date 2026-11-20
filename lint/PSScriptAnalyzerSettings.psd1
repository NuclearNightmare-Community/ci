# Shared PSScriptAnalyzer settings for every mod repo; ci/check.ps1 runs Invoke-ScriptAnalyzer -Settings <this file>
# on each .ps1, .psm1 and .psd1, skipping the same folders as lint/.luacheckrc (build, .worktrees, unreal, native,
# ue4ss-src, ci, nucleus). Any Error or Warning fails the check. Every excluded rule carries a one-line reason.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The scripts are console tools: their output for people goes to the host on purpose.
        'PSAvoidUsingWriteHost',
        # Script-internal helpers, not cmdlets: none offers -WhatIf/-Confirm.
        'PSUseShouldProcessForStateChangingFunctions',
        # Script-internal helper names (Pair-Log, Get-Hits) are chosen for reading, not exported as cmdlets.
        'PSUseApprovedVerbs',
        'PSUseSingularNouns',
        # It can't follow dynamic scope: variables read by dot-sourcing scripts ($ModScripts), set for code a test
        # loads, or preference variables ($PSNativeCommandArgumentPassing) are reported as unused.
        'PSUseDeclaredVarsMoreThanAssignments',
        # Same blind spot for parameters used inside nested functions and script blocks.
        'PSReviewUnusedParameter',
        # try { ... } catch { } is the repos' best-effort read: a missing or unreadable file keeps the default.
        'PSAvoidUsingEmptyCatchBlock'
    )
}
