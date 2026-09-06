Set-StrictMode -Version Latest

# Depends on functions exported by sibling modules, which Install-REAgent.ps1
# imports into the session before this one: Write-ReAgentLog,
# Write-FileIfChanged, Assert-FileHash (Common).

$Script:ValidSkillStatus = @('installed', 'skipped', 'not-installed', 'failed')

function New-SkillResult {
    <#
    .SYNOPSIS
        Builds the result record for one skill pack.
    .DESCRIPTION
        Mirrors New-ServerResult deliberately: same four statuses, same
        Installed derivation. A scan refusal is 'failed' with findings on the
        record - inventing a fifth status would mean every consumer grows a
        branch it does not need.
    .PARAMETER Pack
        The pack's config entry.
    .PARAMETER Status
        One of installed, skipped, not-installed, failed.
    .PARAMETER SkillNames
        The skill directory names this pack installed.
    .PARAMETER Reason
        Why, for any status that is not 'installed'.
    .PARAMETER Findings
        Scanner findings, when the pack failed its scan.
    .EXAMPLE
        New-SkillResult -Pack $p -Status 'installed' -SkillNames @('windbg-crash')
    #>
    [CmdletBinding()]
    # Pure factory: builds and returns an object, writes nothing.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][string]$Status,
        [string[]]$SkillNames = @(),
        [string]$Reason = '',
        [array]$Findings = @()
    )

    if ($Script:ValidSkillStatus -notcontains $Status) {
        throw ("Invalid skill pack status '$Status'. Expected one of: " +
            ($Script:ValidSkillStatus -join ', '))
    }

    [PSCustomObject]@{
        Namespace  = $Pack.namespace
        Status     = $Status
        Installed  = ($Status -eq 'installed' -or $Status -eq 'skipped')
        SkillNames = @($SkillNames)
        Repo       = $Pack.source.repo
        Commit     = $Pack.source.commit
        TreeSha256 = $Pack.source.treeSha256
        ReviewedBy = $Pack.review.reviewedBy
        ReviewedAt = $Pack.review.reviewedAt
        Reason     = $Reason
        Findings   = @($Findings)
    }
}

Export-ModuleMember -Function New-SkillResult
