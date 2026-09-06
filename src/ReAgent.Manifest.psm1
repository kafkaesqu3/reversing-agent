Set-StrictMode -Version Latest

# Depends on Write-ReAgentLog (Common), imported by Install-REAgent.ps1.

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

Export-ModuleMember -Function Get-ManualStep, Write-Manifest
