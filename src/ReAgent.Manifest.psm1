Set-StrictMode -Version Latest

# Depends on Write-ReAgentLog and Write-Utf8NoBomFile (Common), and on
# New-ServerResult and Get-WindbgLaunchCommand (Servers), all imported by
# Install-REAgent.ps1 before this module.

function Get-SkillPackProp {
    <#
    .SYNOPSIS
        Reads a property that may not exist, defaulting to an empty string.
    .DESCRIPTION
        A pack object built for a narrower test - or a config that predates a
        given check - may carry no review or source block at all. Reading
        straight through would throw under Set-StrictMode; this is the one
        place that risk is absorbed, so callers can read freely.
    .PARAMETER Obj
        The object to read from. May be $null.
    .PARAMETER Name
        The property name.
    .OUTPUTS
        [string] The property's value, or '' when Obj is $null or lacks it.
    .EXAMPLE
        Get-SkillPackProp -Obj $Pack.review -Name 'reviewedBy'
    #>
    [CmdletBinding()]
    param([object]$Obj, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Obj) { return '' }
    if ($Obj.PSObject.Properties.Name -notcontains $Name) { return '' }
    return $Obj.$Name
}

function Test-SkillPackReviewGap {
    <#
    .SYNOPSIS
        Reports whether a skill pack's human review sign-off is missing or stale.
    .DESCRIPTION
        The staleness half mirrors the rule Test-SkillPackSchema (ReAgent.Config)
        enforces at load time: a review.reviewedCommit that does not match
        source.commit is a sign-off for a different tree.
    .PARAMETER Pack
        The pack's config entry.
    .OUTPUTS
        [bool] True when the pack needs a human to review or re-review it.
    .EXAMPLE
        Test-SkillPackReviewGap -Pack $p
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Pack)

    $review = if ($Pack.PSObject.Properties.Name -contains 'review') { $Pack.review } else { $null }
    $source = if ($Pack.PSObject.Properties.Name -contains 'source') { $Pack.source } else { $null }

    $reviewedBy = Get-SkillPackProp -Obj $review -Name 'reviewedBy'
    $reviewedAt = Get-SkillPackProp -Obj $review -Name 'reviewedAt'
    $reviewedCommit = Get-SkillPackProp -Obj $review -Name 'reviewedCommit'
    $sourceCommit = Get-SkillPackProp -Obj $source -Name 'commit'

    $missing = [string]::IsNullOrWhiteSpace($reviewedBy) -or
        [string]::IsNullOrWhiteSpace($reviewedAt)
    return ($missing -or ($reviewedCommit -ne $sourceCommit))
}

function Get-ManualStep {
    <#
    .SYNOPSIS
        Returns the steps the operator still has to do by hand.
    .DESCRIPTION
        Everything here is deliberately manual - none of it is a defect. They
        are collected so the final report tells the operator what is left rather
        than leaving them to discover it when a server does not answer.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER ServerResults
        Results from Install-AllMcpServer.
    .EXAMPLE
        Get-ManualStep -Config $cfg -ServerResults $r
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ServerResults
    )

    $steps = @(
        "Run 'claude' once in $($Config.paths.agentRoot) and accept the trust prompt. " +
        'Until then the project .mcp.json servers stay at Pending approval and ' +
        "'claude mcp list' will show nothing connected.",
        "Complete Claude Code login interactively if 'claude doctor' reports an " +
        'unauthenticated state. This script never writes credentials.'
    )

    foreach ($r in $ServerResults) {
        if (-not $r.Installed) { continue }
        if ($r.Name -eq 'binaryninja') {
            $steps += ('Restart Binary Ninja, then run Plugins > MCP > Start Server. ' +
                'It does NOT autostart, and this is needed once per session.')
        }
        if ($r.Kind -eq 'plugin-inproc') {
            $steps += ("Open the matching debugger for '$($r.Name)' with the target " +
                'loaded before expecting it to answer.')
        }
    }

    if ($Config.PSObject.Properties.Name -contains 'skills') {
        foreach ($p in $Config.skills) {
            if (Test-SkillPackReviewGap -Pack $p) {
                $steps += ("Review skill pack '$($p.namespace)': its human sign-off is " +
                    'missing or stale. Read every SKILL.md by hand, then record ' +
                    "reviewedBy, reviewedAt and reviewedCommit under skills[$($p.namespace)]" +
                    '.review.')
            }
        }
    }
    return $steps
}

function Write-Manifest {
    <#
    .SYNOPSIS
        Writes manifest.json: what was found, what was installed, and what is left.
    .DESCRIPTION
        Always runs, including after failures - a failed run's manifest is the
        diagnostic. Records the pyghidra-mcp authentication exemption explicitly
        so it stays a visible decision rather than an oversight.

        The top-level keys are fixed: generatedAt, configVersion, inventory,
        phases, servers, skills, verification, authExemptions, manualSteps.
        skills sits beside servers - the manifest is the one place both an
        MCP server's and a skill pack's last-known state are recorded together.
    .PARAMETER Context
        The shared phase context.
    .PARAMETER PhaseResults
        Phase results so far.
    .EXAMPLE
        Write-Manifest -Context $c -PhaseResults $results
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [AllowEmptyCollection()][array]$PhaseResults = @()
    )

    $config = $Context.Config
    $servers = @($Context.ServerResults)
    $skillResults = if ($Context.ContainsKey('SkillResults')) {
        @($Context.SkillResults)
    } else { @() }

    $exemptions = @($config.mcpServers |
            Where-Object { $_.PSObject.Properties.Name -contains 'authExemptReason' } |
            ForEach-Object { [ordered]@{ server = $_.name; reason = $_.authExemptReason } })

    $manifest = [ordered]@{
        generatedAt   = (Get-Date).ToString('o')
        configVersion = $config.version
        inventory     = $Context.Inventory
        phases        = @($PhaseResults | ForEach-Object {
                [ordered]@{
                    id = $_.Id; name = $_.Name; status = $_.Status
                    durationMs = $_.DurationMs; error = $_.ErrorMessage
                }
            })
        servers       = @($servers | ForEach-Object {
                [ordered]@{
                    name = $_.Name; kind = $_.Kind; status = $_.Status
                    version = $_.Version; transport = $_.Transport
                    bind = $_.Bind; port = $_.Port; reason = $_.Reason
                }
            })
        skills        = @($skillResults | Sort-Object Namespace | ForEach-Object {
                [ordered]@{
                    namespace = $_.Namespace; status = $_.Status; repo = $_.Repo
                    commit = $_.Commit; treeSha256 = $_.TreeSha256
                    reviewedBy = $_.ReviewedBy; reviewedAt = $_.ReviewedAt
                    skills = @($_.SkillNames); reason = $_.Reason
                    findings = @($_.Findings | Select-Object -First 20 | ForEach-Object {
                            [ordered]@{ rule = $_.RuleId; file = $_.File; line = $_.Line } })
                } })
        verification  = @($Context.VerifyResults | ForEach-Object {
                [ordered]@{ name = $_.Name; status = $_.Status }
            })
        authExemptions = $exemptions
        manualSteps   = @(Get-ManualStep -Config $config -ServerResults $servers)
    }

    $null = New-Item -ItemType Directory -Path $config.paths.stateRoot -Force
    $path = Join-Path $config.paths.stateRoot 'manifest.json'
    Write-Utf8NoBomFile -Path $path -Text ($manifest | ConvertTo-Json -Depth 10)
    Write-ReAgentLog -Level INFO -Message "Wrote manifest to '$path'."
    return $path
}


function Get-RecordedServerResult {
    <#
    .SYNOPSIS
        Replays the last run's server results out of manifest.json.
    .DESCRIPTION
        -VerifyOnly must not install, so it cannot produce install results of
        its own. Reading them back from the manifest lets verification say what
        the last real run recorded, and say nothing at all when there was none -
        which is honest, unlike inferring "not installed" from an empty list.

        Servers the current config no longer declares are dropped: the manifest
        describes a past run, and the config is what is being verified now.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Inventory
        The host inventory, used to rebuild stdio launch commands.
    .EXAMPLE
        Get-RecordedServerResult -Config $cfg -Inventory $inv
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][AllowNull()][object]$Inventory
    )

    $path = Join-Path $Config.paths.stateRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $path)) {
        Write-ReAgentLog -Level WARN -Message (
            "No manifest at '$path', so nothing is known about what is installed. " +
            'Run the installer without -VerifyOnly first.')
        return @()
    }

    try {
        $recorded = @((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).servers)
    } catch {
        Write-ReAgentLog -Level WARN -Message (
            "Could not read '$path': $($_.Exception.Message) Verification will " +
            'report every server as unknown.')
        return @()
    }

    $results = @()
    foreach ($s in $Config.mcpServers) {
        $entry = $recorded | Where-Object { $_.name -eq $s.name } | Select-Object -First 1
        if (-not $entry) { continue }

        $command = $null
        if ($s.kind -eq 'venv-stdio' -and $Inventory) {
            $command = Get-WindbgLaunchCommand -Config $Config -Inventory $Inventory
        }
        $results += New-ServerResult -Server $s -Status $entry.status `
            -Reason $entry.reason -Version $entry.version -Command $command
    }
    return $results
}

function Get-RecordedSkillResult {
    <#
    .SYNOPSIS
        Replays the last run's skill pack results out of manifest.json.
    .DESCRIPTION
        Mirrors Get-RecordedServerResult: -VerifyOnly cannot produce its own
        install results, so verification reads back what the last real run
        recorded, and says nothing at all when there was none - which is
        honest, unlike inferring "not installed" from an empty list.

        Packs the current config no longer declares are dropped: the manifest
        describes a past run, and the config is what is being verified now.
        Every field comes from the recorded entry rather than from the pack's
        own config block - a manifest entry is what was actually installed and
        reviewed, and a config edit since then must not silently overwrite it.
        Unlike servers, no -Inventory is needed: there are no launch commands
        to rebuild.
    .PARAMETER Config
        The parsed configuration object.
    .EXAMPLE
        Get-RecordedSkillResult -Config $cfg
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    $path = Join-Path $Config.paths.stateRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $path)) {
        Write-ReAgentLog -Level WARN -Message (
            "No manifest at '$path', so nothing is known about which skill packs are " +
            'installed. Run the installer without -VerifyOnly first.')
        return @()
    }

    try {
        $recorded = @((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).skills)
    } catch {
        Write-ReAgentLog -Level WARN -Message (
            "Could not read '$path': $($_.Exception.Message) Verification will " +
            'report every skill pack as unknown.')
        return @()
    }

    $results = @()
    foreach ($p in $Config.skills) {
        $entry = $recorded | Where-Object { $_.namespace -eq $p.namespace } |
            Select-Object -First 1
        if (-not $entry) { continue }

        $results += [PSCustomObject]@{
            Namespace  = $entry.namespace
            Status     = $entry.status
            Installed  = @('installed', 'skipped') -contains $entry.status
            SkillNames = @($entry.skills)
            Repo       = $entry.repo
            Commit     = $entry.commit
            TreeSha256 = $entry.treeSha256
            ReviewedBy = $entry.reviewedBy
            ReviewedAt = $entry.reviewedAt
            Reason     = $entry.reason
            Findings   = @($entry.findings)
        }
    }
    return $results
}

Export-ModuleMember -Function Get-ManualStep, Write-Manifest, Get-RecordedServerResult, `
    Get-SkillPackProp, Test-SkillPackReviewGap, Get-RecordedSkillResult
