Set-StrictMode -Version Latest

# Depends on functions exported by sibling modules, which Install-REAgent.ps1
# imports into the session before this one: Write-ReAgentLog (Common),
# Get-ServerToken (Tokens).

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

    foreach ($w in $written) {
        Write-ReAgentLog -Level INFO -Message "Generated '$w'."
    }
    return $written
}

Export-ModuleMember -Function New-McpServerEntry, New-McpJsonObject, `
    New-ClaudeSettingsObject, Write-JsonFile, Write-AgentConfiguration
