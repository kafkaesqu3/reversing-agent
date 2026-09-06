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
        if ($p.source.commit -notmatch '^[0-9a-f]{40}$') {
            throw ("Skill pack '$($p.namespace)' pins source.commit to " +
                "'$($p.source.commit)'. A 40-character commit SHA is required - a branch " +
                'or tag moves under you.')
        }
        if ($p.review.reviewedCommit -ne $p.source.commit) {
            throw ("Skill pack '$($p.namespace)' has review.reviewedCommit " +
                "'$($p.review.reviewedCommit)' but source.commit " +
                "'$($p.source.commit)'. The sign-off is for a different tree; re-review.")
        }
        foreach ($t in $p.targetServers) {
            if ($serverNames -notcontains $t) {
                throw ("Skill pack '$($p.namespace)' targets server '$t', which is not " +
                    'declared in mcpServers.')
            }
        }
        foreach ($x in $p.scanExceptions) {
            if ([string]::IsNullOrWhiteSpace($x.justification)) {
                throw ("Skill pack '$($p.namespace)' has a scan exception for rule " +
                    "'$($x.ruleId)' with no justification. An unreviewed suppression is " +
                    'not an exception.')
            }
        }
        foreach ($s in $p.skills) {
            Test-SkillEntrySchema -Pack $p -Skill $s -SeenNames $seenNames
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

    if (-not $Skill.enabled -and [string]::IsNullOrWhiteSpace($Skill.disabledReason)) {
        throw ("Skill '$($Skill.name)' is disabled with no disabledReason. An omission " +
            'that is not written down becomes an oversight.')
    }
}

Export-ModuleMember -Function Get-ReAgentConfig, Test-ReAgentConfigSchema, `
    Get-ServerPortMap, Write-PortsJson, Test-SkillPackSchema, Test-SkillEntrySchema
