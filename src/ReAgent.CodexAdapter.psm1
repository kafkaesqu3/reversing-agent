Set-StrictMode -Version Latest

function ConvertTo-CodexMcpNamespace {
    <#
    .SYNOPSIS
        Normalizes a configured MCP server name for Codex tool references.
    .PARAMETER Name
        Configured MCP server name.
    .EXAMPLE
        ConvertTo-CodexMcpNamespace -Name 'mcp-windbg'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $value = [regex]::Replace($Name, '[^A-Za-z0-9]+', '_').Trim('_')
    $value = [regex]::Replace($value, '_+', '_').ToLowerInvariant()
    if (-not $value) { throw "MCP server name '$Name' has no alphanumeric namespace." }
    return $value
}

function Get-CodexMcpNamespaceMap {
    <#
    .SYNOPSIS
        Builds an injective configured-name to Codex-namespace map.
    .PARAMETER Servers
        Configured MCP server records.
    .EXAMPLE
        Get-CodexMcpNamespaceMap -Servers $config.mcpServers
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Servers)

    $map = @{}
    $owners = @{}
    foreach ($server in $Servers) {
        $name = [string]$server.name
        $namespace = ConvertTo-CodexMcpNamespace -Name $name
        if ($owners.ContainsKey($namespace)) {
            throw ("MCP namespace collision: '$name' and '$($owners[$namespace])' " +
                "both normalize to '$namespace'.")
        }
        $owners[$namespace] = $name
        $map[$name] = $namespace
    }
    return $map
}

function ConvertTo-CodexMcpReference {
    <#
    .SYNOPSIS
        Rewrites validated structured MCP references for Codex.
    .PARAMETER Text
        Text that may contain structured MCP references.
    .PARAMETER NamespaceMap
        Configured server names mapped to Codex namespaces.
    .PARAMETER Catalog
        Captured MCP tool catalog.
    .PARAMETER CompatibleServers
        Configured servers whose transports Codex supports.
    .EXAMPLE
        ConvertTo-CodexMcpReference -Text $text -NamespaceMap $map `
            -Catalog $catalog -CompatibleServers @('mcp-windbg')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][hashtable]$NamespaceMap,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CompatibleServers
    )

    $referenceMap = $NamespaceMap
    $referenceCatalog = $Catalog
    $supportedServers = $CompatibleServers
    $pattern = '(?<![A-Za-z0-9_])mcp__([A-Za-z0-9][A-Za-z0-9_-]*)__' +
        '([A-Za-z0-9][A-Za-z0-9_-]*)(?![A-Za-z0-9_-])'
    $evaluator = [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $server = $match.Groups[1].Value
        $tool = $match.Groups[2].Value
        if (-not $referenceMap.ContainsKey($server)) {
            throw "MCP server '$server' in structured reference is unknown."
        }
        if ($supportedServers -notcontains $server) {
            throw "MCP server '$server' is unsupported by Codex."
        }
        $property = $referenceCatalog.servers.PSObject.Properties[$server]
        if ($null -eq $property -or @($property.Value.tools) -notcontains $tool) {
            throw "MCP tool '$tool' for server '$server' is unknown."
        }
        return 'mcp__' + $referenceMap[$server] + '__' + $tool
    }
    return [regex]::Replace($Text, $pattern, $evaluator)
}

function ConvertTo-CodexTomlValue {
    <#
    .SYNOPSIS
        Encodes a string as a TOML basic string.
    .PARAMETER Value
        String to encode.
    .EXAMPLE
        ConvertTo-CodexTomlValue -Value 'C:\re'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    $escaped = $escaped.Replace("`b", '\b').Replace("`t", '\t')
    $escaped = $escaped.Replace("`n", '\n').Replace("`f", '\f')
    $escaped = $escaped.Replace("`r", '\r')
    if ($escaped -match '[\x00-\x07\x0B\x0E-\x1F\x7F]') {
        throw 'TOML basic strings cannot contain unencoded control characters.'
    }
    return '"' + $escaped + '"'
}

function ConvertTo-CodexTomlArray {
    <#
    .SYNOPSIS
        Encodes strings as a TOML array of basic strings.
    .PARAMETER Values
        Strings to encode in their supplied order.
    .EXAMPLE
        ConvertTo-CodexTomlArray -Values @('one', 'two')
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Values)

    $encoded = @($Values | ForEach-Object { ConvertTo-CodexTomlValue -Value $_ })
    return '[' + ($encoded -join ',') + ']'
}

function ConvertTo-CodexFrontmatter {
    <#
    .SYNOPSIS
        Removes Claude tool permissions from opening skill frontmatter.
    .PARAMETER Text
        Skill Markdown text.
    .EXAMPLE
        ConvertTo-CodexFrontmatter -Text $skillText
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $newLine = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [regex]::Split($Text, '\r?\n')
    if ($lines.Count -eq 0 -or $lines[0] -cne '---') { return $Text }
    $end = [Array]::IndexOf($lines, '---', 1)
    if ($end -lt 0) { return $Text }

    $output = [Collections.Generic.List[string]]::new()
    $output.Add($lines[0])
    $skipList = $false
    for ($index = 1; $index -lt $end; $index++) {
        $line = $lines[$index]
        if ($line -cmatch '^allowed-tools\s*:') {
            $skipList = $true
            continue
        }
        if ($skipList -and $line -cmatch '^\s+-\s') { continue }
        $skipList = $false
        $output.Add($line)
    }
    for ($index = $end; $index -lt $lines.Count; $index++) {
        $output.Add($lines[$index])
    }
    return $output -join $newLine
}

function ConvertTo-CodexActiveWorkflowLine {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SkillNames
    )

    $exact = [ordered]@{
        '.claude/skills' = '.agents/skills'
        '.claude/agents' = '.codex/agents'
        'CLAUDE.md wins' = 'AGENTS.md wins'
        'TodoWrite' = 'a concise Codex task or plan list'
        'Task tool' = 'Codex subagent collaboration'
        'Agent tool' = 'Codex subagent collaboration'
        'Skill tool' = '/skills discovery'
    }
    $builtins = [ordered]@{
        'Bash' = 'the Codex shell, using PowerShell on this Windows host'
        'Read|Glob|Grep' = 'file reading plus `rg`/`rg --files` through the Codex shell'
        'Write|Edit' = 'Codex file-editing tools, preferring `apply_patch` for repository edits'
        'Agent|Task' = 'Codex subagent collaboration, only where the skill is allowed to delegate'
    }
    $converted = $Line
    foreach ($item in $builtins.GetEnumerator()) {
        $pattern = '(?:the\s+)?`(?:' + $item.Key + ')` tool'
        $converted = [regex]::Replace($converted, $pattern, $item.Value)
    }
    $knownSkills = $SkillNames
    $slashEvaluator = [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        if ($knownSkills -contains $match.Groups[1].Value) {
            return '$' + $match.Groups[1].Value
        }
        return $match.Value
    }
    $converted = [regex]::Replace(
        $converted, '(?<![A-Za-z0-9_$])/([a-z0-9]+(?:-[a-z0-9]+)*)\b', $slashEvaluator)
    foreach ($item in $exact.GetEnumerator()) {
        $converted = $converted.Replace($item.Key, $item.Value)
    }
    return $converted
}

function ConvertTo-CodexWorkflowLine {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SkillNames
    )

    $parts = [regex]::Split($Line, '("[^"]*")')
    $converted = foreach ($part in $parts) {
        if ($part -cmatch '^"[^"]*"$') {
            $part
        } else {
            ConvertTo-CodexActiveWorkflowLine -Line $part -SkillNames $SkillNames
        }
    }
    return $converted -join ''
}

function Test-CodexFenceClosingMarker {
    param(
        [Parameter(Mandatory)][string]$Line,
        [Parameter(Mandatory)][string]$OpeningMarker
    )

    $match = [regex]::Match($Line, '^\s*(`{3,}|~{3,})(.*)$')
    if (-not $match.Success) { return $false }
    $candidate = $match.Groups[1].Value
    if ($candidate[0] -cne $OpeningMarker[0]) { return $false }
    if ($candidate.Length -lt $OpeningMarker.Length) { return $false }
    return $match.Groups[2].Value -match '^\s*$'
}

function ConvertTo-CodexWorkflowText {
    <#
    .SYNOPSIS
        Converts reviewed Claude workflow syntax into Codex wording.
    .PARAMETER Text
        Skill Markdown text to convert.
    .PARAMETER SkillNames
        Installed skill names eligible for slash-invocation conversion.
    .EXAMPLE
        ConvertTo-CodexWorkflowText -Text $text -SkillNames @('windbg-crash')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SkillNames
    )

    $newLine = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [regex]::Split($Text, '\r?\n')
    $fenceMarker = ''
    $converted = foreach ($line in $lines) {
        $fenceMatch = [regex]::Match($line, '^\s*(`{3,}|~{3,})')
        if ($fenceMarker) {
            $line
            if (Test-CodexFenceClosingMarker -Line $line `
                    -OpeningMarker $fenceMarker) {
                $fenceMarker = ''
            }
        } elseif ($fenceMatch.Success) {
            $fenceMarker = $fenceMatch.Groups[1].Value
            $line
        } elseif ($line -cmatch '^\s*>') {
            $line
        } else {
            ConvertTo-CodexWorkflowLine -Line $line -SkillNames $SkillNames
        }
    }
    return $converted -join $newLine
}

function Get-CodexStdioTableLine {
    param(
        [Parameter(Mandatory)][object]$Command,
        [Parameter(Mandatory)][string]$Table
    )

    $lines = @('command = ' + (ConvertTo-CodexTomlValue -Value $Command.Executable))
    $lines += 'args = ' + (ConvertTo-CodexTomlArray -Values @($Command.Arguments))
    if ($Command.PSObject.Properties.Name -contains 'WorkingDirectory') {
        $lines += 'cwd = ' + (ConvertTo-CodexTomlValue -Value $Command.WorkingDirectory)
    }
    if (-not $Command.Env) { return $lines }

    $keys = @($Command.Env.Keys | Sort-Object)
    foreach ($key in $keys) {
        if ($key -match '(?i)(TOKEN|SECRET|PASSWORD|AUTH|KEY)') {
            throw "Sensitive environment name '$key' cannot be emitted in a Codex agent."
        }
    }
    $lines += "[$Table.env]"
    foreach ($key in $keys) {
        $encodedKey = ConvertTo-CodexTomlValue -Value ([string]$key)
        $encodedValue = ConvertTo-CodexTomlValue -Value ([string]$Command.Env[$key])
        $lines += $encodedKey + ' = ' + $encodedValue
    }
    return $lines
}

function New-CodexAgentServerTable {
    <#
    .SYNOPSIS
        Renders one complete token-free MCP table for a Codex custom agent.
    .PARAMETER ConfigServer
        Configured MCP server record.
    .PARAMETER ServerResult
        Installed server result containing the resolved transport.
    .PARAMETER Enabled
        Whether the custom agent may use this server.
    .PARAMETER EnabledTools
        Complete tool allowlist for the custom agent.
    .EXAMPLE
        New-CodexAgentServerTable -ConfigServer $server -ServerResult $result `
            -Enabled $false -EnabledTools @()
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][object]$ConfigServer,
        [Parameter(Mandatory)][object]$ServerResult,
        [Parameter(Mandatory)][bool]$Enabled,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$EnabledTools
    )

    $transport = [string]$ServerResult.Transport
    if ($transport -eq 'sse') { throw 'Legacy SSE transport is unsupported by Codex agents.' }
    $auth = if ($ConfigServer.PSObject.Properties.Name -contains 'auth') {
        [string]$ConfigServer.auth
    } else { 'none' }
    if ($transport -in @('http', 'stdio') -and $Enabled -and $auth -ne 'none') {
        throw "Authenticated server '$($ConfigServer.name)' cannot be enabled."
    }

    $table = 'mcp_servers.' + (ConvertTo-CodexTomlValue -Value $ConfigServer.name)
    $lines = @(
        "[$table]"
        'enabled = ' + ([string]$Enabled).ToLowerInvariant()
        'enabled_tools = ' + (ConvertTo-CodexTomlArray -Values $EnabledTools)
    )
    if ($transport -eq 'http') {
        $url = "http://$($ServerResult.Bind):$($ServerResult.Port)$($ServerResult.Path)"
        $lines += 'url = ' + (ConvertTo-CodexTomlValue -Value $url)
    } elseif ($transport -eq 'stdio') {
        if (-not $ServerResult.Command -or -not $ServerResult.Command.Executable) {
            throw "Missing stdio command for '$($ConfigServer.name)'."
        }
        $lines += Get-CodexStdioTableLine -Command $ServerResult.Command -Table $table
    } else {
        throw "Unsupported transport '$transport'."
    }
    return $lines -join "`n"
}

Export-ModuleMember -Function ConvertTo-CodexMcpNamespace, Get-CodexMcpNamespaceMap, `
    ConvertTo-CodexMcpReference, ConvertTo-CodexFrontmatter, ConvertTo-CodexWorkflowText, `
    ConvertTo-CodexTomlValue, ConvertTo-CodexTomlArray, New-CodexAgentServerTable
