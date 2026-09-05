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
    $PortMap | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
}

Export-ModuleMember -Function Get-ReAgentConfig, Test-ReAgentConfigSchema, `
    Get-ServerPortMap, Write-PortsJson
