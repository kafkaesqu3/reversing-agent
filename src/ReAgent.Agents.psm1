Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ForbiddenAgentBuiltin = @('Bash', 'Write', 'Edit', 'NotebookEdit', 'Task')

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


function Test-AgentNameCheck {
    <#
    .SYNOPSIS
        Runs check A0: frontmatter name, file basename and config name agree.
    .DESCRIPTION
        Claude Code keys an agent's identity off all three. A disagreement
        means the file does not load, which presents as "the agent ignored its
        tools" rather than as an error - so it is checked before anything else.
    .PARAMETER Frontmatter
        Parsed frontmatter of the generated agent file.
    .PARAMETER FileBaseName
        The file's basename without .md.
    .PARAMETER ConfigName
        The name declared in re-agent.config.json.
    .OUTPUTS
        [array] Zero or one {Check='A0'; Message} findings.
    .EXAMPLE
        Test-AgentNameCheck -Frontmatter $fm -FileBaseName 'verifier' -ConfigName 'verifier'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Frontmatter,
        [Parameter(Mandatory)][string]$FileBaseName,
        [Parameter(Mandatory)][string]$ConfigName
    )

    $fm = "$($Frontmatter['name'])"
    if ($fm -eq $FileBaseName -and $fm -eq $ConfigName) { return @() }
    return @([PSCustomObject]@{ Check = 'A0'; Message = (
                "Agent identity disagrees: frontmatter '$fm', file '$FileBaseName', " +
                "config '$ConfigName'. Claude Code will not load this agent.") })
}

function Test-AgentCatalogCheck {
    <#
    .SYNOPSIS
        Runs check A1: every target server must have a classified catalog entry.
    .DESCRIPTION
        Without one, A2 and A3 cannot judge a single tool from that server, so
        the gap is reported rather than passed over in silence. This is what
        makes an uncaptured server (x64dbg, Binary Ninja) fail closed instead
        of yielding an empty grant that looks like a working agent.
    .PARAMETER Agent
        One entry from the config's agents[].
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .OUTPUTS
        [array] One {Check='A1'; Message} finding per unjudgeable server.
    .EXAMPLE
        Test-AgentCatalogCheck -Agent $a -Catalog (Get-ToolCatalog)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Agent,
        [Parameter(Mandatory)][object]$Catalog
    )

    $findings = @()
    foreach ($server in @($Agent.targetServers)) {
        if ((Get-ToolClassification -Catalog $Catalog -Server $server).Known) { continue }
        $findings += [PSCustomObject]@{ Check = 'A1'; Message = (
                "Agent '$($Agent.name)' targets '$server', which has no classified " +
                'catalog entry. Capture it with .\Install-REAgent.ps1 -Attended ' +
                "-UpdateToolCatalog and classify it, or ship this agent disabled.") }
    }
    return $findings
}

function Test-AgentToolExistenceCheck {
    <#
    .SYNOPSIS
        Runs check A2: every granted MCP tool exists in the catalog.
    .DESCRIPTION
        Built-ins are skipped: they are not catalog tools and A3 judges them.
        A granted name the server does not advertise means the generator built
        it from something other than the catalog, which is the defect spec
        1.3.1 exists to prevent.
    .PARAMETER GrantedTools
        The agent's full tool list, built-ins included.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .OUTPUTS
        [array] One {Check='A2'; Message} finding per absent tool.
    .EXAMPLE
        Test-AgentToolExistenceCheck -GrantedTools $g.Tools -Catalog $cat
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$GrantedTools,
        [Parameter(Mandatory)][object]$Catalog
    )

    $findings = @()
    foreach ($granted in $GrantedTools) {
        if ($granted -notmatch '^mcp__(?<server>[^_]+(?:[^_]|_(?!_))*)__(?<tool>.+)$') { continue }
        $server = $Matches['server']
        $tool = $Matches['tool']
        if ($Catalog.servers.PSObject.Properties.Name -notcontains $server) { continue }
        if (@($Catalog.servers.$server.tools) -contains $tool) { continue }
        $findings += [PSCustomObject]@{ Check = 'A2'; Message = (
                "Granted '$granted', which '$server' does not advertise. The grant was " +
                'not derived from the catalog.') }
    }
    return $findings
}

function Test-AgentLevelCheck {
    <#
    .SYNOPSIS
        Runs check A3: no tool above the agent's level, no forbidden built-in.
    .DESCRIPTION
        This is the check that carries DEPLOYMENT_PLAN Phase 7's line. For the
        verifier it reduces to: nothing in write, nothing in destructive, no
        built-in writer. If A3 passes and the file still grants a writer, the
        generator is wrong, not the gate.

        destructive is rejected for every agent regardless of level - no level
        admits it.
    .PARAMETER Agent
        One entry from the config's agents[].
    .PARAMETER GrantedTools
        The agent's full tool list, built-ins included.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .OUTPUTS
        [array] One {Check='A3'; Message} finding per over-grant.
    .EXAMPLE
        Test-AgentLevelCheck -Agent $a -GrantedTools $g.Tools -Catalog $cat
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Agent,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$GrantedTools,
        [Parameter(Mandatory)][object]$Catalog
    )

    $allowed = if ($Agent.level -eq 'write') { @('read', 'write') } else { @('read') }
    $findings = @()
    foreach ($granted in $GrantedTools) {
        if ($script:ForbiddenAgentBuiltin -contains $granted) {
            $findings += [PSCustomObject]@{ Check = 'A3'; Message = (
                    "Agent '$($Agent.name)' is granted built-in '$granted', which no " +
                    'agent may hold.') }
            continue
        }
        if ($granted -notmatch '^mcp__(?<server>[^_]+(?:[^_]|_(?!_))*)__(?<tool>.+)$') { continue }
        $class = Get-ToolClassification -Catalog $Catalog -Server $Matches['server']
        if (-not $class.Known) { continue }
        $level = Get-ToolLevel -Classification $class -Tool $Matches['tool']
        if ($level -ne 'destructive' -and $allowed -contains $level) { continue }
        $findings += [PSCustomObject]@{ Check = 'A3'; Message = (
                "Agent '$($Agent.name)' declares level '$($Agent.level)' but is granted " +
                "'$granted', classified '$level'.") }
    }
    return $findings
}

function Invoke-AgentGate {
    <#
    .SYNOPSIS
        Runs A0-A4 over one agent and returns every finding.
    .DESCRIPTION
        Runs all five rather than stopping at the first. An operator fixing a
        grant wants the whole list, not one finding per run - the same shape
        the skills gate settled on.
    .PARAMETER Agent
        One entry from the config's agents[].
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER Frontmatter
        Parsed frontmatter of the generated file.
    .PARAMETER FileBaseName
        The generated file's basename without .md.
    .OUTPUTS
        [array] All findings, each {Check; Message}.
    .EXAMPLE
        Invoke-AgentGate -Agent $a -Catalog $cat -Frontmatter $fm -FileBaseName 'verifier'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Agent,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][hashtable]$Frontmatter,
        [Parameter(Mandatory)][string]$FileBaseName
    )

    $grant = Get-AgentToolGrant -Agent $Agent -Catalog $Catalog
    $findings = @()
    $findings += Test-AgentNameCheck -Frontmatter $Frontmatter -FileBaseName $FileBaseName `
        -ConfigName "$($Agent.name)"
    $findings += Test-AgentCatalogCheck -Agent $Agent -Catalog $Catalog
    $findings += Test-AgentToolExistenceCheck -GrantedTools $grant.Tools -Catalog $Catalog
    $findings += Test-AgentLevelCheck -Agent $Agent -GrantedTools $grant.Tools -Catalog $Catalog
    foreach ($server in @($Agent.targetServers)) {
        $findings += Test-AgentClassificationCheck -Catalog $Catalog -Server $server
    }
    return $findings
}

Export-ModuleMember -Function Get-ToolClassification, Get-ToolLevel, `
    Test-AgentClassificationCheck, Get-AgentToolGrant, Test-AgentNameCheck, `
    Test-AgentCatalogCheck, Test-AgentToolExistenceCheck, Test-AgentLevelCheck, `
    Invoke-AgentGate
