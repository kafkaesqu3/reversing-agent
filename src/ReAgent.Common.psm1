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

Export-ModuleMember -Function Write-ReAgentLog, New-PhaseResult, Get-ReAgentExitCode
