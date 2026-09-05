Set-StrictMode -Version Latest

$Script:ValidPhaseStatus = @('ok', 'skipped', 'failed', 'aborted')

function Write-ReAgentLog {
    <#
    .SYNOPSIS
        Writes a timestamped, levelled log line to the host and the transcript.
    .PARAMETER Level
        One of INFO, WARN, ERROR.
    .PARAMETER Message
        The text to log.
    .EXAMPLE
        Write-ReAgentLog -Level INFO -Message 'Phase 0 (Preflight): starting.'
    #>
    [CmdletBinding()]
    # Write-Host is deliberate: this is operator-facing installer progress that must
    # land in the Start-Transcript log. Write-Verbose is suppressed by default and
    # Write-Information is not reliably transcribed on PowerShell 5.1.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $stamp = (Get-Date).ToString('o')
    Write-Host "[$stamp] [$Level] $Message"
}

function New-PhaseResult {
    <#
    .SYNOPSIS
        Builds the result record for a single phase.
    .DESCRIPTION
        Validation lives here rather than on the parameter so the error names the
        offending value and lists the valid set, which a ValidateSet failure does
        not do as clearly for a caller reading a transcript.
    .PARAMETER Id
        The phase number from the phase table.
    .PARAMETER Name
        The phase name from the phase table.
    .PARAMETER Status
        One of ok, skipped, failed, aborted.
    .PARAMETER DurationMs
        Wall-clock duration of the phase, in milliseconds.
    .PARAMETER ErrorMessage
        The failure text, when Status is failed or aborted.
    .EXAMPLE
        New-PhaseResult -Id 3 -Name 'McpServers' -Status 'ok' -DurationMs 1200
    #>
    [CmdletBinding()]
    # New-PhaseResult is a pure factory: it builds and returns an object and
    # touches nothing outside itself. ShouldProcess would be noise on a call
    # that cannot be declined into a meaningful no-op.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][int]$DurationMs,
        [string]$ErrorMessage = ''
    )
    if ($Script:ValidPhaseStatus -notcontains $Status) {
        throw "Invalid phase status '$Status'. Expected one of: $($Script:ValidPhaseStatus -join ', ')"
    }
    [PSCustomObject]@{
        Id           = $Id
        Name         = $Name
        Status       = $Status
        DurationMs   = $DurationMs
        ErrorMessage = $ErrorMessage
    }
}

function Get-ReAgentExitCode {
    <#
    .SYNOPSIS
        Maps a set of phase results to the script's process exit code.
    .DESCRIPTION
        0 = all good, 1 = completed with non-fatal failures, 2 = aborted on a hard blocker.
        Aborted outranks failed: a hard blocker is the more actionable signal.
    .PARAMETER PhaseResults
        The phase result objects from this run. An empty run is a clean run.
    .EXAMPLE
        exit (Get-ReAgentExitCode -PhaseResults $results)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$PhaseResults)

    if ($PhaseResults | Where-Object { $_.Status -eq 'aborted' }) { return 2 }
    if ($PhaseResults | Where-Object { $_.Status -eq 'failed' }) { return 1 }
    return 0
}

function Invoke-Phase {
    <#
    .SYNOPSIS
        Runs one phase with logging, idempotency, timing, and failure isolation.
    .DESCRIPTION
        Calls the phase's Test block first; when it returns true and -Force was
        not given, the phase is skipped. A throwing phase is recorded as failed
        and does not stop the run - the caller decides what is a hard dependency.

        A Test block that throws is treated as "cannot confirm, so run it",
        never as a failure: an idempotency probe that errors must not be able to
        abort an install.
    .PARAMETER Phase
        Hashtable with keys Id, Name, Test (scriptblock), Fn (scriptblock).
    .PARAMETER Context
        Shared state passed to both blocks. Mutated by phases to publish results.
    .PARAMETER Force
        Run the phase even when its Test reports it already satisfied.
    .EXAMPLE
        Invoke-Phase -Phase $p -Context $context -Force:$Force
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Phase,
        [Parameter(Mandatory)][hashtable]$Context,
        [switch]$Force
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $already = & $Phase.Test $Context
    } catch {
        $already = $false
    }

    if ($already -and -not $Force) {
        $sw.Stop()
        Write-ReAgentLog -Level INFO `
            -Message "Phase $($Phase.Id) ($($Phase.Name)): already satisfied, skipping."
        return New-PhaseResult -Id $Phase.Id -Name $Phase.Name -Status 'skipped' `
            -DurationMs ([int]$sw.ElapsedMilliseconds)
    }

    Write-ReAgentLog -Level INFO -Message "Phase $($Phase.Id) ($($Phase.Name)): starting."
    try {
        $null = & $Phase.Fn $Context
        $sw.Stop()
        Write-ReAgentLog -Level INFO `
            -Message "Phase $($Phase.Id) ($($Phase.Name)): ok in $($sw.ElapsedMilliseconds)ms."
        return New-PhaseResult -Id $Phase.Id -Name $Phase.Name -Status 'ok' `
            -DurationMs ([int]$sw.ElapsedMilliseconds)
    } catch {
        $sw.Stop()
        $msg = $_.Exception.Message
        Write-ReAgentLog -Level ERROR `
            -Message "Phase $($Phase.Id) ($($Phase.Name)): FAILED - $msg"
        return New-PhaseResult -Id $Phase.Id -Name $Phase.Name -Status 'failed' `
            -DurationMs ([int]$sw.ElapsedMilliseconds) -ErrorMessage $msg
    }
}

Export-ModuleMember -Function Write-ReAgentLog, New-PhaseResult, Get-ReAgentExitCode, `
    Invoke-Phase
