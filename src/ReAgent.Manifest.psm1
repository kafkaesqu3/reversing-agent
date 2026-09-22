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
    if ($null -eq $Obj.PSObject.Properties[$Name]) { return '' }
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

function ConvertTo-ManifestSkillRecord {
    <#
    .SYNOPSIS
        One skill pack's manifest record, from its install or replayed result.
    .DESCRIPTION
        Split out of Write-Manifest so that function stays a readable shape
        rather than four nested projections.

        skillEntries records every skill the pack declares and, for a disabled
        one, why - design spec section 1.3.5. It sits beside the existing
        skills field rather than replacing it: skills is what installed, which
        is what the orphan sweep and Get-RecordedSkillResult read.

        A result built before skillEntries existed, or by a narrower test, is
        recorded with an empty list rather than throwing under Set-StrictMode.
    .PARAMETER Result
        One skill pack result from Install-AllSkill or Get-RecordedSkillResult.
    .OUTPUTS
        [ordered] The manifest's skills[] entry for that pack.
    .EXAMPLE
        ConvertTo-ManifestSkillRecord -Result $skillResult
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Result)

    $entries = @()
    if ($Result.PSObject.Properties.Name -contains 'SkillEntries') {
        $entries = @($Result.SkillEntries)
    }
    return [ordered]@{
        namespace = $Result.Namespace; status = $Result.Status; repo = $Result.Repo
        commit = $Result.Commit; treeSha256 = $Result.TreeSha256
        reviewedBy = $Result.ReviewedBy; reviewedAt = $Result.ReviewedAt
        skills = @($Result.SkillNames)
        skillEntries = @($entries | ForEach-Object {
                [ordered]@{ name = $_.Name; enabled = $_.Enabled
                    disabledReason = $_.DisabledReason
                } })
        reason = $Result.Reason
        findings = @($Result.Findings | Select-Object -First 20 | ForEach-Object {
                [ordered]@{ rule = $_.RuleId; file = $_.File; line = $_.Line } })
    }
}

function Get-ManifestSkillEntry {
    <#
    .SYNOPSIS
        The per-skill entries recorded against one pack in manifest.json.
    .DESCRIPTION
        skillEntries is newer than the manifest format, so a manifest written
        by an earlier run does not carry it. Reading straight through would
        throw under Set-StrictMode and take verification down on exactly the
        hosts whose recorded state is oldest.
    .PARAMETER Entry
        One skills[] entry read back out of manifest.json.
    .OUTPUTS
        [array] The recorded entries, or empty for a manifest that predates them.
    .EXAMPLE
        Get-ManifestSkillEntry -Entry $recordedPack
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Entry)

    if ($Entry.PSObject.Properties.Name -notcontains 'skillEntries') { return @() }
    return @($Entry.skillEntries)
}

function Get-CodexManifestAgentState {
    param([Parameter(Mandatory)][object]$Record)

    $servers = @()
    $toolCount = 0
    $sandboxMode = ''
    if ($null -ne $Record.PSObject.Properties['Path'] -and
        (Test-Path -LiteralPath $Record.Path -PathType Leaf)) {
        $text = [IO.File]::ReadAllText($Record.Path, [Text.Encoding]::UTF8)
        $sandbox = [regex]::Match($text, '(?m)^sandbox_mode\s*=\s*"(?<value>[^"]+)"\s*$')
        if ($sandbox.Success) { $sandboxMode = $sandbox.Groups['value'].Value }
        $tables = [regex]::Matches($text,
            '(?ms)^\[mcp_servers\."(?<name>[^"]+)"\]\s*(?<body>.*?)(?=^\[|\z)')
        foreach ($table in $tables) {
            $body = $table.Groups['body'].Value
            if ($body -notmatch '(?m)^enabled\s*=\s*true\s*$') { continue }
            $servers += $table.Groups['name'].Value
            $tools = [regex]::Match($body, '(?ms)^enabled_tools\s*=\s*\[(?<items>.*?)\]')
            if ($tools.Success) {
                $toolCount += [regex]::Matches($tools.Groups['items'].Value, '"(?:[^"\\]|\\.)*"').Count
            }
        }
    }
    return [pscustomobject]@{ Servers = @($servers | Sort-Object); ToolCount = $toolCount
        SandboxMode = $sandboxMode }
}

function ConvertTo-CodexWorkspaceManifestRecord {
    <# .SYNOPSIS Projects generated Codex workspace output into a secret-free manifest record. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)

    $config = $Context.Config
    $workspace = if ($Context.ContainsKey('CodexWorkspaceConfiguration')) {
        $Context.CodexWorkspaceConfiguration
    } else { $null }
    $instruction = $null
    $workspaceInstruction = if ($workspace -and
        $null -ne $workspace.PSObject.Properties['Instruction']) {
        $workspace.Instruction
    } else { $null }
    if ($workspaceInstruction) {
        $instruction = [ordered]@{ path = $workspaceInstruction.Path; status = 'installed'
            sha256 = $workspaceInstruction.Sha256 }
    }

    $skills = @()
    if ($Context.ContainsKey('CodexSkillResults')) {
        $skills = @($Context.CodexSkillResults | ForEach-Object {
                if ($null -ne $_.PSObject.Properties['CodexSkillRecords']) {
                    @($_.CodexSkillRecords)
                }
            } | ForEach-Object {
                [ordered]@{ name = $_.Name; status = 'installed'; sha256 = $_.Sha256 }
            } | Sort-Object name)
    }

    $agents = @()
    $omissions = @{}
    if ($workspace -and $null -ne $workspace.PSObject.Properties['Agents']) {
        foreach ($record in @($workspace.Agents | Where-Object Enabled | Sort-Object Name)) {
            $state = Get-CodexManifestAgentState -Record $record
            $agentConfig = @($config.agents | Where-Object { $_.name -eq $record.Name }) |
                Select-Object -First 1
            $level = if ($agentConfig) { [string]$agentConfig.level } else { '' }
            $agents += [ordered]@{ name = $record.Name; status = 'installed'; level = $level
                servers = @($state.Servers); toolCount = $state.ToolCount
                sandbox_mode = $state.SandboxMode }
            if ($null -ne $record.PSObject.Properties['OmittedServers']) {
                foreach ($omitted in @($record.OmittedServers)) {
                    $omissions[[string]$omitted.Name] = [string]$omitted.Reason
                }
            }
        }
    }
    $omittedServers = @($omissions.Keys | Sort-Object | ForEach-Object {
            [ordered]@{ name = $_; reason = $omissions[$_] }
        })
    return [ordered]@{ root = $config.paths.agentRoot; instructions = $instruction
        skills = $skills; agents = $agents; omittedServers = $omittedServers }
}

function Get-RecordedCodexWorkspaceResult {
    <# .SYNOPSIS Replays optional Codex workspace records from a prior manifest. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [string]$ManifestName = 'manifest.json'
    )

    $path = Join-Path $Config.paths.stateRoot $ManifestName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    try { $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    catch { return @() }
    if ($null -eq $manifest.PSObject.Properties['codexWorkspace']) { return @() }
    $record = $manifest.codexWorkspace
    if ($null -eq $record) { return @() }
    $instruction = if ($null -ne $record.PSObject.Properties['instructions']) {
        $entry = $record.instructions
        if ($entry) { [pscustomobject]@{
                Path = Get-SkillPackProp -Obj $entry -Name 'path'
                Status = Get-SkillPackProp -Obj $entry -Name 'status'
                Sha256 = Get-SkillPackProp -Obj $entry -Name 'sha256'; Changed = $false } }
    }
    $skills = if ($null -ne $record.PSObject.Properties['skills']) {
        @($record.skills | ForEach-Object { [pscustomobject]@{
                    Name = Get-SkillPackProp -Obj $_ -Name 'name'
                    Status = Get-SkillPackProp -Obj $_ -Name 'status'
                    Sha256 = Get-SkillPackProp -Obj $_ -Name 'sha256'; Changed = $false } })
    } else { @() }
    $agents = if ($null -ne $record.PSObject.Properties['agents']) {
        @($record.agents | ForEach-Object {
                $servers = if ($null -ne $_.PSObject.Properties['servers']) { @($_.servers) } else { @() }
                $tools = if ($null -ne $_.PSObject.Properties['toolCount']) { [int]$_.toolCount } else { 0 }
                [pscustomobject]@{ Name = Get-SkillPackProp -Obj $_ -Name 'name'
                    Status = Get-SkillPackProp -Obj $_ -Name 'status'
                    Level = Get-SkillPackProp -Obj $_ -Name 'level'
                    Servers = $servers; ToolCount = $tools; Changed = $false }
            })
    } else { @() }
    $omitted = if ($null -ne $record.PSObject.Properties['omittedServers']) {
        @($record.omittedServers)
    } else { @() }
    return [pscustomobject]@{ Instruction = $instruction; Skills = $skills
        Agents = $agents; OmittedServers = $omitted }
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
        MCP server's and a skill pack's last-known state are recorded together,
        including every skill a pack declares and why a disabled one is off.

        Each agent's recorded gate is the real status of phase 6's 'agents'
        check (pass, fail or not-testable), never a hardcoded value: a manifest
        that always says an agent's gate passed would lie on exactly the run
        where it did not.
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
    $agentResults = if ($Context.ContainsKey('AgentResults')) {
        @($Context.AgentResults)
    } else { @() }

    $exemptions = @($config.mcpServers |
            Where-Object { $_.PSObject.Properties.Name -contains 'authExemptReason' } |
            ForEach-Object { [ordered]@{ server = $_.name; reason = $_.authExemptReason } })

    # 'not-testable' when phase 6 did not run this invocation (e.g. -Phases
    # excluded Verify): there is no real signal to report, and a hardcoded
    # 'pass' would be indistinguishable from an actual pass.
    $agentCheck = $Context.VerifyResults | Where-Object { $_.Name -eq 'agents' } |
        Select-Object -First 1
    $agentGate = if ($agentCheck) { $agentCheck.Status } else { 'not-testable' }

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
                ConvertTo-ManifestSkillRecord -Result $_ })
        verification  = @($Context.VerifyResults | ForEach-Object {
                [ordered]@{ name = $_.Name; status = $_.Status }
            })
        agents        = @($agentResults | ForEach-Object {
                [ordered]@{ name = $_.Name; enabled = $_.Enabled
                    disabledReason = $_.DisabledReason; level = $_.Level
                    servers = @($_.Servers); toolCount = $_.ToolCount
                    gate = $agentGate }
            })
        codexWorkspace = ConvertTo-CodexWorkspaceManifestRecord -Context $Context
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
        [Parameter(Mandatory)][AllowNull()][object]$Inventory,
        [string]$ManifestName = 'manifest.json'
    )

    $path = Join-Path $Config.paths.stateRoot $ManifestName
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

    # 'skills' is an optional top-level key so a config written before this
    # subsystem still loads. Phase 6 calls this unconditionally, so reading
    # straight through a config that lacks it would throw under Set-StrictMode
    # and take verification down on exactly those older configs.
    if ($Config.PSObject.Properties.Name -notcontains 'skills') { return @() }

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
            SkillEntries = @(Get-ManifestSkillEntry -Entry $entry)
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

function Get-RecordedAgentResult {
    <#
    .SYNOPSIS
        Replays the last run's agent results out of manifest.json.
    .DESCRIPTION
        Mirrors Get-RecordedSkillResult: -VerifyOnly cannot produce its own
        generation results, so verification reads back what the last real run
        recorded, and says nothing at all when there was none.

        Agents the current config no longer declares are dropped: the manifest
        describes a past run, and the config is what is being verified now.
        Every field comes from the recorded entry rather than from the config
        block - a config edit since then must not silently overwrite what was
        actually generated.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Manifest
        The parsed manifest. When omitted it is read from the state root using
        the same load-and-log-and-swallow pattern as Get-RecordedSkillResult.
    .OUTPUTS
        [array] One record per still-declared agent.
    .EXAMPLE
        Get-RecordedAgentResult -Config $cfg
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [object]$Manifest = $null
    )

    # 'agents' is an optional top-level key, so a config written before this
    # slice must not throw under StrictMode. The indexer form is required, not
    # just style: '.Properties.Name -notcontains' throws PropertyNotFoundStrict
    # of its own when Properties is completely empty, which a bare
    # [PSCustomObject]@{} triggers.
    if ($null -eq $Config.PSObject.Properties['agents']) { return @() }

    if ($null -eq $Manifest) {
        $path = Join-Path $Config.paths.stateRoot 'manifest.json'
        if (-not (Test-Path -LiteralPath $path)) {
            Write-ReAgentLog -Level WARN -Message (
                "No manifest at '$path', so nothing is known about which agents are " +
                'generated. Run the installer without -VerifyOnly first.')
            return @()
        }
        try {
            $Manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        } catch {
            Write-ReAgentLog -Level WARN -Message (
                "Could not read '$path': $($_.Exception.Message) Verification will " +
                'report every agent as unknown.')
            return @()
        }
    }
    if ($null -eq $Manifest.PSObject.Properties['agents']) { return @() }

    $declared = @($Config.agents | ForEach-Object { $_.name })
    $results = @()
    foreach ($entry in $Manifest.agents) {
        if ($declared -notcontains $entry.name) { continue }
        $results += [PSCustomObject]@{
            Name = $entry.name; Enabled = [bool]$entry.enabled
            DisabledReason = "$($entry.disabledReason)"; Level = "$($entry.level)"
            Servers = @($entry.servers); ToolCount = [int]$entry.toolCount
            Path = ''; Changed = $false; Gate = "$($entry.gate)"
        }
    }
    return $results
}

Export-ModuleMember -Function Get-ManualStep, Write-Manifest, Get-RecordedServerResult, `
    Get-SkillPackProp, Test-SkillPackReviewGap, Get-RecordedSkillResult, `
    ConvertTo-ManifestSkillRecord, Get-ManifestSkillEntry, Get-RecordedAgentResult, `
    ConvertTo-CodexWorkspaceManifestRecord, Get-RecordedCodexWorkspaceResult
