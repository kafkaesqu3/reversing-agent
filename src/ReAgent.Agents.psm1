Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ToolClassification {
    <#
    .SYNOPSIS
        Reads one server's tool classification out of the catalog.
    .DESCRIPTION
        The classification is a sibling of the captured tools[], never inside
        it (spec AG4): -UpdateToolCatalog rewrites tools[] and must not be able
        to erase a classification, nor be blocked by one.

        A server with no classification returns Known=$false rather than empty
        lists. Empty lists would read as "everything here is readable", which
        is the failure that hands an unjudged tool to the verifier.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER Server
        MCP server name.
    .OUTPUTS
        [PSCustomObject] Known, ClassifiedTools, Write, Destructive.
    .EXAMPLE
        Get-ToolClassification -Catalog (Get-ToolCatalog) -Server 'pyghidra-mcp'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][string]$Server
    )

    $absent = [PSCustomObject]@{ Known = $false; ClassifiedTools = @()
        Write = @(); Destructive = @() }
    if ($Catalog.servers.PSObject.Properties.Name -notcontains $Server) { return $absent }
    $entry = $Catalog.servers.$Server
    if ($entry.PSObject.Properties.Name -notcontains 'classification') { return $absent }

    $c = $entry.classification
    return [PSCustomObject]@{
        Known           = $true
        ClassifiedTools = @($c.classifiedTools)
        Write           = @($c.write)
        Destructive     = @($c.destructive)
    }
}

function Get-ToolLevel {
    <#
    .SYNOPSIS
        Returns a single tool's level: read, write or destructive.
    .DESCRIPTION
        Anything classified and in neither list is read. A tool listed twice
        takes the highest level, so a careless duplicate fails safe upward
        rather than downward.
    .PARAMETER Classification
        From Get-ToolClassification.
    .PARAMETER Tool
        Bare tool name, without the mcp__server__ prefix.
    .OUTPUTS
        [string] read | write | destructive.
    .EXAMPLE
        Get-ToolLevel -Classification $c -Tool 'save'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Classification,
        [Parameter(Mandatory)][string]$Tool
    )

    if ($Classification.Destructive -contains $Tool) { return 'destructive' }
    if ($Classification.Write -contains $Tool) { return 'write' }
    return 'read'
}

function Test-AgentClassificationCheck {
    <#
    .SYNOPSIS
        Runs check A4: a server's classification must cover its tools exactly.
    .DESCRIPTION
        Set equality in both directions. A tool captured but unclassified would
        default to read and reach the verifier; a tool classified but no longer
        captured means the classification is describing a surface that moved.
        Both are stale data, and the gate stops rather than guessing.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER Server
        MCP server name.
    .OUTPUTS
        [array] Zero or one {Check='A4'; Message} findings.
    .EXAMPLE
        Test-AgentClassificationCheck -Catalog $cat -Server 'pyghidra-mcp'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][string]$Server
    )

    $class = Get-ToolClassification -Catalog $Catalog -Server $Server
    if (-not $class.Known) { return @() }

    $captured = @($Catalog.servers.$Server.tools)
    $unclassified = @($captured | Where-Object { $class.ClassifiedTools -notcontains $_ })
    $stale = @($class.ClassifiedTools | Where-Object { $captured -notcontains $_ })
    if ($unclassified.Count -eq 0 -and $stale.Count -eq 0) { return @() }

    $parts = @()
    if ($unclassified.Count) { $parts += ("captured but unclassified: [" +
                "$($unclassified -join ', ')]") }
    if ($stale.Count) { $parts += ("classified but not captured: [" +
                "$($stale -join ', ')]") }
    return @([PSCustomObject]@{ Check = 'A4'; Message = (
                "Server '$Server' classification is stale - $($parts -join '; '). " +
                'Reclassify before any agent may be granted this server.') })
}

function Get-AgentToolGrant {
    <#
    .SYNOPSIS
        Derives the concrete tool list one agent receives.
    .DESCRIPTION
        Derived from the catalog, never hand-listed (spec 1.3.1). An agent at
        level write receives read + write; at read, only read. destructive is
        granted to nobody at any level, so it is filtered unconditionally
        rather than by comparing against the agent's level.

        A target server with no classification contributes nothing rather than
        contributing everything. Check A1 reports that separately - silence
        here plus a finding there is what makes the gate fail closed instead
        of shipping an unjudged grant.

        Ordering is total: built-ins in declared order, then MCP tools sorted
        by full prefixed name. Spec 1.3.4 wants a re-run to reproduce the file
        byte for byte, which incidental ordering would break.
    .PARAMETER Agent
        One entry from the config's agents[].
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .OUTPUTS
        [PSCustomObject] Tools, McpCount.
    .EXAMPLE
        Get-AgentToolGrant -Agent $a -Catalog (Get-ToolCatalog)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Agent,
        [Parameter(Mandatory)][object]$Catalog
    )

    $allowed = if ($Agent.level -eq 'write') { @('read', 'write') } else { @('read') }
    $mcp = @()
    foreach ($server in @($Agent.targetServers)) {
        $class = Get-ToolClassification -Catalog $Catalog -Server $server
        if (-not $class.Known) { continue }
        foreach ($tool in @($Catalog.servers.$server.tools)) {
            $level = Get-ToolLevel -Classification $class -Tool $tool
            if ($level -eq 'destructive') { continue }
            if ($allowed -notcontains $level) { continue }
            $mcp += "mcp__${server}__${tool}"
        }
    }
    $mcp = @($mcp | Sort-Object)
    return [PSCustomObject]@{
        Tools    = @(@($Agent.builtinTools) + $mcp)
        McpCount = $mcp.Count
    }
}

Export-ModuleMember -Function Get-ToolClassification, Get-ToolLevel, `
    Test-AgentClassificationCheck, Get-AgentToolGrant
