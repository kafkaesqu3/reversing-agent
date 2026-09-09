Set-StrictMode -Version Latest

$Script:ValidKinds = @('plugin-inproc', 'venv-stdio', 'venv-http',
    'gui-builtin-http', 'gui-plugin-http')

function Get-ReAgentConfig {
    <#
    .SYNOPSIS
        Loads and validates the installer configuration file.
    .DESCRIPTION
        This file is the single source of truth for pins, ports, paths, and which
        servers exist. Code reads data; it does not embed it.
    .PARAMETER Path
        Path to re-agent.config.json.
    .EXAMPLE
        $cfg = Get-ReAgentConfig -Path .\re-agent.config.json
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("Config file not found at '$Path'. " +
            'Copy re-agent.config.json next to the script or pass -ConfigPath.')
    }
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $null = Test-ReAgentConfigSchema -Config $config
    return $config
}

function Test-ReAgentConfigSchema {
    <#
    .SYNOPSIS
        Validates config structure and the invariants the installer depends on.
    .DESCRIPTION
        Throws a specific, actionable error on the first violation found. The
        loopback check is a security invariant, not a style preference: binding
        0.0.0.0 would expose a debugger control channel on every adapter the VM
        is ever given.
    .PARAMETER Config
        The parsed configuration object.
    .EXAMPLE
        Test-ReAgentConfigSchema -Config $cfg
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    foreach ($key in @('version', 'paths', 'mcpServers')) {
        if (-not $Config.PSObject.Properties.Name.Contains($key)) {
            throw "Config is missing the required top-level key '$key'."
        }
    }

    $seenNames = @{}
    $seenPorts = @{}
    foreach ($s in $Config.mcpServers) {
        if ($Script:ValidKinds -notcontains $s.kind) {
            throw ("Server '$($s.name)' has unknown kind '$($s.kind)'. " +
                "Valid kinds: $($Script:ValidKinds -join ', ')")
        }
        if ($s.bind -ne '127.0.0.1') {
            throw ("Server '$($s.name)' binds '$($s.bind)'. Only 127.0.0.1 is permitted; " +
                '0.0.0.0 would expose the debugger.')
        }
        if ($seenNames.ContainsKey($s.name)) {
            throw "Duplicate server name '$($s.name)' in config."
        }
        $seenNames[$s.name] = $true

        # stdio servers have no port; several legitimately carry the placeholder 0.
        if ($s.transport -ne 'stdio') {
            if ($seenPorts.ContainsKey($s.port)) {
                throw "Port $($s.port) is assigned to both '$($seenPorts[$s.port])' and '$($s.name)'."
            }
            $seenPorts[$s.port] = $s.name
        }
    }
    $null = Test-SkillPackSchema -Config $Config
    $null = Test-AgentSchema -Config $Config
    return $true
}

function Get-ServerPortMap {
    <#
    .SYNOPSIS
        Builds the authoritative server-name to port mapping.
    .DESCRIPTION
        stdio servers have no port and are omitted. Two of the HTTP servers own
        their port numbers upstream (x64dbg compiles 9094/9095 in; Binary Ninja
        defaults to 24642), so this map records allocation rather than choosing it.
    .PARAMETER Config
        The parsed configuration object.
    .EXAMPLE
        $ports = Get-ServerPortMap -Config $cfg
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    $map = @{}
    foreach ($s in $Config.mcpServers) {
        if ($s.transport -ne 'stdio') { $map[$s.name] = [int]$s.port }
    }
    return $map
}

function Write-PortsJson {
    <#
    .SYNOPSIS
        Emits ports.json, the single source of truth for allocated ports.
    .DESCRIPTION
        Derived state: regenerated unconditionally on every run. Config generation
        and any future firewall rules read ports from this one place.
    .PARAMETER PortMap
        Server name to port, from Get-ServerPortMap.
    .PARAMETER Path
        Destination file. Parent directories are created if absent.
    .EXAMPLE
        Write-PortsJson -PortMap (Get-ServerPortMap -Config $cfg) -Path C:\re\mcp\ports.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$PortMap,
        [Parameter(Mandatory)][string]$Path
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    Write-Utf8NoBomFile -Path $Path -Text ($PortMap | ConvertTo-Json -Depth 4)
}


function Test-SkillPackSchema {
    <#
    .SYNOPSIS
        Validates the skills array in re-agent.config.json.
    .DESCRIPTION
        Supply-chain rule 1 as code: a branch or a tag is rejected here, not by
        discipline. Tags move; a 40-hex commit cannot. A sign-off recorded
        against a different commit is a sign-off for a different tree.
    .PARAMETER Config
        The parsed configuration object.
    .EXAMPLE
        Test-SkillPackSchema -Config $cfg
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    if ($Config.PSObject.Properties.Name -notcontains 'skills') { return }

    $serverNames = @($Config.mcpServers | ForEach-Object { $_.name })
    $seenNames = @{}

    foreach ($p in $Config.skills) {
        Test-SkillPackSourceSchema -Pack $p
        Test-SkillPackTargetsSchema -Pack $p -ServerNames $serverNames
        Test-SkillPackScanExceptionsSchema -Pack $p
        foreach ($s in $p.skills) {
            Test-SkillEntrySchema -Pack $p -Skill $s -SeenNames $seenNames
        }
    }
}

function Test-SkillPackSourceSchema {
    <#
    .SYNOPSIS
        Validates a skill pack's commit pin and review freshness.
    .DESCRIPTION
        Supply-chain rule 1 as code: a branch or a tag is rejected here, not by
        discipline. Tags move; a 40-hex commit cannot. A sign-off recorded
        against a different commit is a sign-off for a different tree.
    .PARAMETER Pack
        The skill pack config entry.
    .EXAMPLE
        Test-SkillPackSourceSchema -Pack $p
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Pack)

    if ($Pack.source.commit -notmatch '^[0-9a-f]{40}$') {
        throw ("Skill pack '$($Pack.namespace)' pins source.commit to " +
            "'$($Pack.source.commit)'. A 40-character commit SHA is required - a branch " +
            'or tag moves under you.')
    }
    if ($Pack.review.reviewedCommit -ne $Pack.source.commit) {
        throw ("Skill pack '$($Pack.namespace)' has review.reviewedCommit " +
            "'$($Pack.review.reviewedCommit)' but source.commit " +
            "'$($Pack.source.commit)'. The sign-off is for a different tree; re-review.")
    }
}

function Test-SkillPackTargetsSchema {
    <#
    .SYNOPSIS
        Validates that every targetServers entry names a declared server.
    .PARAMETER Pack
        The skill pack config entry.
    .PARAMETER ServerNames
        Names of the servers declared in mcpServers.
    .EXAMPLE
        Test-SkillPackTargetsSchema -Pack $p -ServerNames $serverNames
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][array]$ServerNames
    )

    foreach ($t in $Pack.targetServers) {
        if ($ServerNames -notcontains $t) {
            throw ("Skill pack '$($Pack.namespace)' targets server '$t', which is not " +
                'declared in mcpServers.')
        }
    }
}

function Test-SkillPackScanExceptionsSchema {
    <#
    .SYNOPSIS
        Validates that every scan exception carries a justification.
    .PARAMETER Pack
        The skill pack config entry.
    .EXAMPLE
        Test-SkillPackScanExceptionsSchema -Pack $p
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Pack)

    foreach ($x in $Pack.scanExceptions) {
        if ([string]::IsNullOrWhiteSpace($x.justification)) {
            throw ("Skill pack '$($Pack.namespace)' has a scan exception for rule " +
                "'$($x.ruleId)' with no justification. An unreviewed suppression is " +
                'not an exception.')
        }
    }
}

function Test-SkillEntrySchema {
    <#
    .SYNOPSIS
        Validates one skill entry inside a pack.
    .PARAMETER Pack
        The owning pack config entry.
    .PARAMETER Skill
        The skill entry.
    .PARAMETER SeenNames
        Hashtable accumulating names across all packs, for uniqueness.
    .EXAMPLE
        Test-SkillEntrySchema -Pack $p -Skill $s -SeenNames $seen
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][object]$Skill,
        [Parameter(Mandatory)][hashtable]$SeenNames
    )

    if ($Skill.name -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$' -or $Skill.name.Length -gt 64) {
        throw ("Skill name '$($Skill.name)' must be lowercase, hyphen-separated and at " +
            'most 64 characters. Claude Code will not load a skill otherwise.')
    }
    if (-not $Skill.name.StartsWith($Pack.namespace + '-')) {
        throw ("Skill name '$($Skill.name)' must start with its pack namespace " +
            "'$($Pack.namespace)-'. Generic names collide across packs.")
    }
    if ($SeenNames.ContainsKey($Skill.name)) {
        throw ("Skill name '$($Skill.name)' is not unique across packs; it is declared " +
            "by both '$($SeenNames[$Skill.name])' and '$($Pack.namespace)'.")
    }
    $SeenNames[$Skill.name] = $Pack.namespace

    $reason = $null
    if ($Skill.PSObject.Properties['disabledReason']) { $reason = $Skill.disabledReason }
    if (-not $Skill.enabled -and [string]::IsNullOrWhiteSpace($reason)) {
        throw ("Skill '$($Skill.name)' is disabled with no disabledReason. An omission " +
            'that is not written down becomes an oversight.')
    }
}


$script:AllowedAgentBuiltin = @('Read', 'Glob', 'Grep')

function Test-SingleAgentSchema {
    <#
    .SYNOPSIS
        Validates a single agent entry in the agents array.
    .DESCRIPTION
        Checks name format, duplicates, permission level, target server references,
        forbidden built-in tools, and disabled-reason requirement.
    .PARAMETER Agent
        The agent configuration object to validate.
    .PARAMETER ServerNames
        Names of declared servers for targetServers validation.
    .EXAMPLE
        Test-SingleAgentSchema -Agent $a -ServerNames $serverNames
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Agent,
        [Parameter(Mandatory)][array]$ServerNames
    )

    if ("$($Agent.name)" -cnotmatch '^[a-z][a-z0-9-]{2,31}$') {
        throw ("Agent name '$($Agent.name)' is not a valid basename. It is also the " +
            'file name and the frontmatter name:; Claude Code will not load a ' +
            'file where those disagree. Use ^[a-z][a-z0-9-]{2,31}$.')
    }

    if ($Agent.level -notin @('read', 'write')) {
        throw ("Agent '$($Agent.name)' declares level '$($Agent.level)'. Valid levels are " +
            "read and write; destructive is never granted to an agent.")
    }
    foreach ($s in @($Agent.targetServers)) {
        if ($ServerNames -notcontains $s) {
            throw ("Agent '$($Agent.name)' targets server '$s', which mcpServers does " +
                "not declare. Known: [$($ServerNames -join ', ')].")
        }
    }
    foreach ($b in @($Agent.builtinTools)) {
        if ($script:AllowedAgentBuiltin -notcontains $b) {
            throw ("Agent '$($Agent.name)' declares built-in '$b', which is not in the " +
                "allowed set: [$($script:AllowedAgentBuiltin -join ', ')].")
        }
    }

    $reason = if ($Agent.PSObject.Properties['disabledReason']) { "$($Agent.disabledReason)" } else { '' }
    if (-not $Agent.enabled -and -not $reason.Trim()) {
        throw "Agent '$($Agent.name)' ships disabled with no disabledReason."
    }
}

function Test-AgentSchema {
    <#
    .SYNOPSIS
        Validates the optional agents array in re-agent.config.json.
    .DESCRIPTION
        Optional matters: a config written before this slice must still load,
        so an absent key returns rather than throwing.

        level 'destructive' is rejected outright. The value exists so the
        classification can name that class of tool, not so an agent can ask
        for it. The forbidden built-ins are rejected here rather than only at
        the gate so the operator is told at load, where they can act on it.
    .PARAMETER Config
        The parsed configuration object.
    .EXAMPLE
        Test-AgentSchema -Config $cfg
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    if ($Config.PSObject.Properties.Name -notcontains 'agents') { return }

    $serverNames = @($Config.mcpServers | ForEach-Object { $_.name })
    $seenNames = @()
    foreach ($a in $Config.agents) {
        if ($seenNames -contains $a.name) { throw "Agent '$($a.name)' is a duplicate name." }
        $null = Test-SingleAgentSchema -Agent $a -ServerNames $serverNames
        $seenNames += $a.name
    }
}

Export-ModuleMember -Function Get-ReAgentConfig, Test-ReAgentConfigSchema, `
    Get-ServerPortMap, Write-PortsJson, Test-SkillPackSchema, Test-SkillEntrySchema, `
    Test-SkillPackSourceSchema, Test-SkillPackTargetsSchema, Test-SkillPackScanExceptionsSchema, Test-AgentSchema