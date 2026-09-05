<#
.SYNOPSIS
    Wires Claude Code to x64dbg, Ghidra, Binary Ninja, and WinDbg via MCP on an existing FLARE VM.
.DESCRIPTION
    Adopt-and-reconcile: inventories the host, installs only what is missing, and
    generates all agent configuration from re-agent.config.json. Idempotent - a
    second run reports every phase skipped and regenerates byte-identical config.

    Phase bodies live in src\ReAgent.*.psm1. The table below is runtime execution
    order; docs/mvp/MVP_PLAN.md gives the development order, which differs
    deliberately.
.PARAMETER ConfigPath
    Path to re-agent.config.json. Defaults to the copy beside this script.
.PARAMETER Phases
    Run only these phase ids. Default runs all of them.
.PARAMETER Force
    Re-run phases their Test block reports as already satisfied.
.PARAMETER VerifyOnly
    Run only verification and manifest (phases 5 and 6).
.PARAMETER Attended
    Include tier-2 verification, which needs x64dbg and Binary Ninja open.
.EXAMPLE
    .\Install-REAgent.ps1
.EXAMPLE
    .\Install-REAgent.ps1 -VerifyOnly -Attended
.NOTES
    RUN ONLY ON A VIRTUAL MACHINE. Requires Administrator.
    Spec: docs/mvp/MVP_SPEC.md - Findings: docs/mvp/MVP_FINDINGS.md
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = "$PSScriptRoot\re-agent.config.json",
    [int[]] $Phases,
    [switch]$Force,
    [switch]$VerifyOnly,
    [switch]$Attended
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleNames = @('Common', 'Config', 'Discovery', 'Prereqs', 'Symbols',
    'Tokens', 'Json', 'Servers', 'Generate', 'Verify', 'Manifest')
foreach ($m in $moduleNames) {
    $modulePath = "$PSScriptRoot\src\ReAgent.$m.psm1"
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw ("Required module '$modulePath' is missing. This build is incomplete; " +
            'see docs/mvp/MVP_PLAN.md for which task creates it.')
    }
    Import-Module $modulePath -Force
}

$config = Get-ReAgentConfig -Path $ConfigPath

if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Wire Claude Code to the RE tools via MCP')) {
    return
}

$null = New-Item -ItemType Directory -Path $config.paths.stateRoot -Force
$transcript = Join-Path $config.paths.stateRoot 'install.log'
try {
    Start-Transcript -Path $transcript -Append | Out-Null
    $transcribing = $true
} catch {
    Write-ReAgentLog -Level WARN -Message "Could not start a transcript: $($_.Exception.Message)"
    $transcribing = $false
}

# Attended travels in the context rather than being closed over from script
# scope: phases read everything they need from one place, and the analyzer can
# actually see the parameter being used.
$context = @{
    Config        = $config
    Inventory     = $null
    Attended      = [bool]$Attended
    ServerResults = @()
    VerifyResults = @()
}

$phaseTable = @(
    @{ Id   = 0; Name = 'Preflight'
        Test = { $false }
        Fn   = { param($c) $c.Inventory = Get-HostInventory; Assert-Preflight -Inventory $c.Inventory }
    }
    @{ Id   = 1; Name = 'Prerequisites'
        Test = { param($c) Test-PrereqsSatisfied -Inventory $c.Inventory }
        Fn   = { param($c) Install-Prereqs -Inventory $c.Inventory }
    }
    @{ Id   = 2; Name = 'Symbols'
        Test = { param($c) Test-SymbolsReady -Config $c.Config }
        Fn   = { param($c) Install-Symbols -Config $c.Config }
    }
    @{ Id   = 3; Name = 'McpServers'
        Test = { $false }
        Fn   = { param($c) $c.ServerResults = Install-AllMcpServers -Config $c.Config -Inventory $c.Inventory }
    }
    @{ Id   = 4; Name = 'AgentConfig'
        Test = { $false }
        Fn   = { param($c) Write-AgentConfiguration -Config $c.Config -ServerResults $c.ServerResults }
    }
    @{ Id   = 5; Name = 'Verify'
        Test = { $false }
        Fn   = { param($c) $c.VerifyResults = Invoke-Verification -Config $c.Config -Attended:$c.Attended }
    }
    @{ Id   = 6; Name = 'Manifest'
        Test = { $false }
        Fn   = { param($c) Write-Manifest -Context $c }
    }
)

$selected = if ($VerifyOnly) { $phaseTable | Where-Object { $_.Id -in @(5, 6) } }
elseif ($Phases) { $phaseTable | Where-Object { $_.Id -in $Phases } }
else { $phaseTable }

$results = @()
foreach ($p in $selected) {
    $r = Invoke-Phase -Phase $p -Context $context -Force:$Force
    $results += $r

    # Phase 0 is the only hard dependency of everything else: without an
    # inventory no later phase can decide anything. Its failure aborts.
    if ($r.Status -eq 'failed' -and $p.Id -eq 0) {
        $results[-1].Status = 'aborted'
        Write-ReAgentLog -Level ERROR -Message 'Preflight failed; aborting the run.'
        break
    }
}

foreach ($w in @(Get-PreflightWarning -Inventory $context.Inventory)) {
    Write-ReAgentLog -Level WARN -Message $w
}

if ($transcribing) { Stop-Transcript | Out-Null }
exit (Get-ReAgentExitCode -PhaseResults $results)
