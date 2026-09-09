Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ReAgent.Agents.psm1') -Force

# Depends on functions exported by sibling modules, which Install-REAgent.ps1
# imports into the session before this one: Write-ReAgentLog (Common),
# Get-ServerToken (Tokens), Get-ToolCatalog (Skills).

function New-McpServerEntry {
    <#
    .SYNOPSIS
        Builds the .mcp.json entry for one installed server.
    .DESCRIPTION
        stdio servers carry a command; HTTP and SSE servers carry a URL. An
        Authorization header is emitted only where the server can actually read
        one - pyghidra-mcp exposes no auth mechanism at all, and a header it
        ignores would only make the config lie about itself.
    .PARAMETER Result
        The server result from Install-McpServer.
    .PARAMETER TokenRoot
        Directory holding token files.
    .EXAMPLE
        New-McpServerEntry -Result $r -TokenRoot 'C:\re\mcp\tokens'
    #>
    [CmdletBinding()]
    # Pure factory: builds and returns an object, writes nothing.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][object]$Result,
        [Parameter(Mandatory)][string]$TokenRoot
    )

    if ($Result.Transport -eq 'stdio') {
        $entry = [ordered]@{
            command = $Result.Command.Executable
            args    = @($Result.Command.Arguments)
        }
        if ($Result.Command.Env) {
            $env = [ordered]@{}
            foreach ($k in ($Result.Command.Env.Keys | Sort-Object)) {
                $env[$k] = $Result.Command.Env[$k]
            }
            $entry['env'] = $env
        }
        return $entry
    }

    $entry = [ordered]@{
        type = $Result.Transport
        url  = "http://$($Result.Bind):$($Result.Port)$($Result.Path)"
    }
    if ($Result.Auth -ne 'none') {
        $token = Get-ServerToken -Name $Result.Name -TokenRoot $TokenRoot
        if ($token) {
            $entry['headers'] = [ordered]@{ Authorization = "Bearer $token" }
        } else {
            Write-ReAgentLog -Level WARN -Message (
                "No token found for '$($Result.Name)'; emitting its .mcp.json entry " +
                'without an Authorization header.')
        }
    }
    return $entry
}

function New-McpJsonObject {
    <#
    .SYNOPSIS
        Builds the whole .mcp.json object from server results.
    .DESCRIPTION
        Servers are emitted in name order so a re-run reproduces the file
        byte-identically. Installed-but-disabled servers are included: disabling
        is settings.json's job, not an omission here.
    .PARAMETER ServerResults
        Results from Install-AllMcpServer.
    .PARAMETER TokenRoot
        Directory holding token files.
    .EXAMPLE
        New-McpJsonObject -ServerResults $r -TokenRoot $t
    #>
    [CmdletBinding()]
    # Pure factory: builds and returns an object, writes nothing.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ServerResults,
        [Parameter(Mandatory)][string]$TokenRoot
    )

    $servers = [ordered]@{}
    foreach ($r in ($ServerResults | Where-Object { $_.Installed } | Sort-Object Name)) {
        $servers[$r.Name] = New-McpServerEntry -Result $r -TokenRoot $TokenRoot
    }
    return [ordered]@{ mcpServers = $servers }
}

function New-ClaudeSettingsObject {
    <#
    .SYNOPSIS
        Builds .claude/settings.json.
    .DESCRIPTION
        Two keys, both load-bearing:

        disabledMcpjsonServers keeps a present-but-unwanted server out of every
        session. Deny wins over any enable, at any config layer.

        enableAllProjectMcpServers stops every OTHER server sitting at Pending
        approval. It is necessary but not sufficient: Claude Code still needs to
        be run once interactively in the project directory with the trust prompt
        accepted, which Phase 7 reports as a manual step.

        Note these are NOT the same keys as disabledMcpServers/enabledMcpServers
        (no 'json'), which are the /mcp panel's toggles in ~/.claude.json.
    .PARAMETER Config
        The parsed configuration object.
    .EXAMPLE
        New-ClaudeSettingsObject -Config $cfg
    #>
    [CmdletBinding()]
    # Pure factory: builds and returns an object, writes nothing.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param([Parameter(Mandatory)][object]$Config)

    $disabled = @($Config.mcpServers | Where-Object { -not $_.enabled } |
            Select-Object -ExpandProperty name | Sort-Object)

    return [ordered]@{
        enableAllProjectMcpServers = $true
        disabledMcpjsonServers     = $disabled
    }
}

function Write-JsonFile {
    <#
    .SYNOPSIS
        Writes an object as formatted JSON with a trailing newline.
    .DESCRIPTION
        Generated config is derived state and is rewritten unconditionally. No
        timestamps or other varying content go in, so a re-run reproduces the
        file byte for byte - which is what the idempotency check asserts.
    .PARAMETER Object
        The object to serialise.
    .PARAMETER Path
        Destination file.
    .EXAMPLE
        Write-JsonFile -Object $mcp -Path 'C:\re\agent\.mcp.json'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Path
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    Write-Utf8NoBomFile -Path $Path -Text ($Object | ConvertTo-Json -Depth 12)
    return $Path
}

function Write-AgentConfiguration {
    <#
    .SYNOPSIS
        Generates .mcp.json, .claude\settings.json and CLAUDE.md from config.
    .DESCRIPTION
        Emitted from data, never hand-written. This is what makes a later move
        to a remote Ghidra a config edit rather than a rewrite.

        No credentials are ever written here beyond the bearer tokens this
        script itself generated: Claude Code login stays interactive and manual.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER ServerResults
        Results from Install-AllMcpServer.
    .PARAMETER TemplateRoot
        Directory holding CLAUDE.md.template.
    .OUTPUTS
        [array] One record per declared agent, from Write-AgentDefinition. Empty
        when the config declares no agents.
    .EXAMPLE
        Write-AgentConfiguration -Config $c.Config -ServerResults $c.ServerResults
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ServerResults,
        [string]$TemplateRoot = (Join-Path $PSScriptRoot '..\templates')
    )

    $agentRoot = $Config.paths.agentRoot
    $tokenRoot = Join-Path $Config.paths.toolRoot 'mcp\tokens'

    $written = @()
    $written += Write-JsonFile -Path (Join-Path $agentRoot '.mcp.json') `
        -Object (New-McpJsonObject -ServerResults $ServerResults -TokenRoot $tokenRoot)

    $written += Write-JsonFile -Path (Join-Path $agentRoot '.claude\settings.json') `
        -Object (New-ClaudeSettingsObject -Config $Config)

    $template = Join-Path $TemplateRoot 'CLAUDE.md.template'
    if (-not (Test-Path -LiteralPath $template)) {
        throw ("CLAUDE.md template not found at '$template'. It carries the trust-boundary " +
            'contract and is not optional.')
    }
    $claudeMd = Join-Path $agentRoot 'CLAUDE.md'
    Copy-Item -LiteralPath $template -Destination $claudeMd -Force
    $written += $claudeMd

    $null = New-Item -ItemType Directory -Path (Join-Path $agentRoot 'cases') -Force

    $agentDir = Join-Path $agentRoot '.claude\agents'
    $catalog = Get-ToolCatalog
    $agentResults = Write-AgentDefinition -Config $Config -Catalog $catalog `
        -RepoRoot (Split-Path $TemplateRoot) -AgentDir $agentDir
    $written += @($agentResults | Where-Object { $_.Enabled -and $_.Changed } |
        Select-Object -ExpandProperty Path)

    foreach ($w in $written) {
        Write-ReAgentLog -Level INFO -Message "Generated '$w'."
    }
    return $agentResults
}

function Write-AgentDefinition {
    <#
    .SYNOPSIS
        Generates one agent file per enabled agent, from template plus catalog.
    .DESCRIPTION
        Written through Write-FileIfChanged so a steady-state run touches no
        timestamp - the lesson from the launcher-rewrite regression, where
        unconditional writes made a staleness check fire on every run.

        Removal is scoped to names this config declares. The .claude/agents
        directory is shared and may hold files this installer never wrote;
        deleting by "not in my wanted list" against a shared root is the defect
        the skills slice shipped and had to fix.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER RepoRoot
        Repository root, for locating templates/agents.
    .PARAMETER AgentDir
        Destination directory, normally <agentRoot>\.claude\agents.
    .OUTPUTS
        [array] One record per declared agent.
    .EXAMPLE
        Write-AgentDefinition -Config $cfg -Catalog $cat -RepoRoot $root -AgentDir $d
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$AgentDir
    )

    if ($Config.PSObject.Properties.Name -notcontains 'agents') { return @() }
    if (-not (Test-Path -LiteralPath $AgentDir)) {
        New-Item -ItemType Directory -Path $AgentDir -Force | Out-Null
    }

    $results = @()
    foreach ($agent in $Config.agents) {
        $path = Join-Path $AgentDir "$($agent.name).md"

        if (-not $agent.enabled) {
            if ((Test-Path -LiteralPath $path) -and $PSCmdlet.ShouldProcess($path, 'Remove')) {
                Remove-Item -LiteralPath $path -Force
            }
            $results += [PSCustomObject]@{ Name = $agent.name; Enabled = $false
                DisabledReason = "$($agent.disabledReason)"; Level = $agent.level
                Servers = @($agent.targetServers); ToolCount = 0; Path = $path; Changed = $false }
            continue
        }

        $grant = Get-AgentToolGrant -Agent $agent -Catalog $Catalog
        $tpl = Join-Path $RepoRoot "templates\agents\$($agent.name).md.template"
        if (-not (Test-Path -LiteralPath $tpl)) {
            throw ("No template at '$tpl' for agent '$($agent.name)'. Every declared " +
                'agent needs one; agent bodies are authored here, not vendored.')
        }
        $text = Get-Content -LiteralPath $tpl -Raw
        $text = $text.Replace('{{TOOLS}}', ($grant.Tools -join ', '))
        $text = $text.Replace('{{SERVERS}}', (Get-AgentServerProse -Agent $agent -Grant $grant))
        $text = $text.Replace('{{LIMITATIONS}}',
            (Get-AgentLimitationProse -Agent $agent -Catalog $Catalog))

        $changed = Write-FileIfChanged -Path $path -Text $text
        $results += [PSCustomObject]@{ Name = $agent.name; Enabled = $true
            DisabledReason = ''; Level = $agent.level; Servers = @($agent.targetServers)
            ToolCount = $grant.Tools.Count; Path = $path; Changed = $changed }
    }
    return $results
}

function Get-AgentServerProse {
    <#
    .SYNOPSIS
        Renders the {{SERVERS}} block: one line per target server.
    .PARAMETER Agent
        One entry from the config's agents[].
    .PARAMETER Grant
        From Get-AgentToolGrant.
    .OUTPUTS
        [string] Markdown list.
    .EXAMPLE
        Get-AgentServerProse -Agent $a -Grant $g
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Agent,
        [Parameter(Mandatory)][object]$Grant
    )

    $lines = @()
    foreach ($s in @($Agent.targetServers)) {
        $n = @($Grant.Tools | Where-Object { $_ -like "mcp__${s}__*" }).Count
        $lines += "- ``$s`` --- $n tool(s) at level ``$($Agent.level)``."
    }
    if (-not $lines) { $lines = @('- None. This agent has no MCP reach.') }
    return ($lines -join "`n")
}

function Get-AgentLimitationProse {
    <#
    .SYNOPSIS
        Renders the {{LIMITATIONS}} block from what the catalog cannot judge.
    .DESCRIPTION
        A target server with no classified catalog entry contributes a line, so
        the agent states the gap rather than presenting an empty reach as a
        working one. This is the prose half of check A1.
    .PARAMETER Agent
        One entry from the config's agents[].
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .OUTPUTS
        [string] Markdown list.
    .EXAMPLE
        Get-AgentLimitationProse -Agent $a -Catalog $cat
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Agent,
        [Parameter(Mandatory)][object]$Catalog
    )

    $lines = @()
    foreach ($s in @($Agent.targetServers)) {
        if ((Get-ToolClassification -Catalog $Catalog -Server $s).Known) { continue }
        $lines += ("- ``$s`` is declared but not captured, so you hold no tools for it. " +
            'Report this rather than working around it.')
    }
    $lines += ('- A tool you expect and cannot see is your grant, not a broken server. ' +
        'The remedy is a config change plus an installer re-run --- never a workaround.')
    return ($lines -join "`n")
}

Export-ModuleMember -Function New-McpServerEntry, New-McpJsonObject, `
    New-ClaudeSettingsObject, Write-JsonFile, Write-AgentConfiguration, `
    Write-AgentDefinition, Get-AgentServerProse, Get-AgentLimitationProse
