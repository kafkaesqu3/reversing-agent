Set-StrictMode -Version Latest

# Depends on Write-ReAgentLog and Write-Utf8NoBomFile (Common), and on
# New-ServerResult and Get-WindbgLaunchCommand (Servers), all imported by
# Install-REAgent.ps1 before this module.

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

Export-ModuleMember -Function Get-ManualStep, Write-Manifest, Get-RecordedServerResult
