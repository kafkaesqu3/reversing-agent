<#
.SYNOPSIS
    Installs the MVP MCP services and registers them in Codex on a FLARE VM.
.DESCRIPTION
    Reuses the RE Agent server installers, pins, discovery and live probes.
    Run as the analyst user, elevated for a full install. Codex CLI is a
    prerequisite. Existing Codex settings are merged with a backup.
.PARAMETER ConfigPath
    Defaults to re-agent.config.json beside this script.
.PARAMETER CodexHome
    Codex configuration directory. Defaults to CODEX_HOME or ~/.codex.
    When using a different administrator account, specify the analyst's directory.
.PARAMETER ConfigureOnly
    Adopt the existing MVP manifest and configure Codex without installing servers.
.PARAMETER VerifyOnly
    Read configuration and run live checks without installing or changing settings.
.PARAMETER Attended
    Include GUI tool checks; open the debuggers and start Binary Ninja MCP first.
.EXAMPLE
    .\install-codex.ps1
.EXAMPLE
    .\install-codex.ps1 -ConfigureOnly
.EXAMPLE
    .\install-codex.ps1 -VerifyOnly -Attended
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath,
    [string]$CodexHome,
    [switch]$ConfigureOnly,
    [switch]$VerifyOnly,
    [switch]$Attended
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($ConfigureOnly -and $VerifyOnly) { throw 'Choose either -ConfigureOnly or -VerifyOnly.' }
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 're-agent.config.json' }
if (-not $CodexHome) {
    $CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
}
$CodexHome = [IO.Path]::GetFullPath($CodexHome)
$moduleNames = @('Common', 'Config', 'Discovery', 'Prereqs', 'Symbols',
        'Tokens', 'Json', 'Servers', 'Generate', 'Skills', 'Verify', 'Manifest', 'Agents',
        'CodexAdapter', 'CodexWorkspace', 'CodexVerify', 'Codex')
foreach ($name in $moduleNames) {
    Import-Module (Join-Path $PSScriptRoot "src\ReAgent.$name.psm1") -Force
}
foreach ($name in $moduleNames) {
    Import-Module (Join-Path $PSScriptRoot "src\ReAgent.$name.psm1") -Global
}
$config = Get-ReAgentConfig -Path $ConfigPath
if (-not $PSCmdlet.ShouldProcess($CodexHome, 'Install/configure or verify RE Lab MCP services for Codex')) { return }
$codexCommand = Get-Command codex -ErrorAction SilentlyContinue
$codexPath = if ($codexCommand) { $codexCommand.Source } else { '' }
$serverResults = @()
$checks = @()
$workspaceConfiguration = $null
$codexSkillResults = @()
$reconciliationRecords = @()
$exitCode = 0
try {
    $inventory = Get-HostInventory
    Assert-Preflight -Inventory $inventory -Agent Codex -CodexPath $codexPath `
        -VerifyOnly:($VerifyOnly -or $ConfigureOnly)
} catch {
    Write-ReAgentLog -Level ERROR -Message $_.Exception.Message
    exit 2
}

try {
    if ($VerifyOnly -or $ConfigureOnly) {
        $manifestName = if (Test-Path -LiteralPath (Join-Path $config.paths.stateRoot 'codex-manifest.json')) {
            'codex-manifest.json'
        } else { 'manifest.json' }
        $serverResults = @(Get-RecordedServerResult -Config $config -Inventory $inventory -ManifestName $manifestName)
        if (-not $serverResults.Count) { throw 'No recorded server installation. Run install-codex.ps1 without -ConfigureOnly or -VerifyOnly first.' }
    } else {
        $null = New-Item -ItemType Directory -Path $config.paths.stateRoot -Force
        $null = Grant-PathFullControl -Path $config.paths.stateRoot -Identity $env:USERNAME -Confirm:$false
        if (-not (Test-PrereqSatisfied -Inventory $inventory)) {
            Install-Prereq -Inventory $inventory
            $inventory = Get-HostInventory
        }
        if ($config.symbols.enabled -and -not (Test-SymbolsReady -Config $config)) {
            Install-Symbols -Config $config
        }
        $serverResults = @(Install-AllMcpServer -Config $config -Inventory $inventory)
    }
    if (@($serverResults | Where-Object { $_.Status -eq 'failed' }).Count) { $exitCode = 1 }
    if (-not $VerifyOnly) {
        Write-CodexConfiguration -CodexPath $codexPath -CodexHome $CodexHome `
            -ServerResults $serverResults -ManagedNames @($config.mcpServers.name) `
            -TokenRoot (Join-Path $config.paths.toolRoot 'mcp\tokens')

        $catalog = Get-ToolCatalog
        $workspaceConfiguration = Write-CodexWorkspaceConfiguration -Config $config `
            -Catalog $catalog -ServerResults $serverResults `
            -TemplateRoot (Join-Path $PSScriptRoot 'templates') -WhatIf:$WhatIfPreference
        $reconciliationRecords = @($workspaceConfiguration.Instruction) +
            @($workspaceConfiguration.Agents) | ForEach-Object {
                $action = if ($_.PSObject.Properties.Name -contains 'Status' -and
                    $_.Status -eq 'created') { 'create' }
                elseif ($_.PSObject.Properties.Name -contains 'Status' -and
                    $_.Status -eq 'updated') { 'update' }
                else { 'none' }
                [pscustomobject]@{ Action = $action; Path = $_.Path
                    OwnedBefore = ($action -ne 'create'); Changed = [bool]$_.Changed }
            }

        $skillRoot = Join-Path $config.paths.agentRoot '.agents\skills'
        $wanted = @()
        $markers = @{}
        foreach ($pack in @($config.skills)) {
            foreach ($skill in @($pack.skills)) {
                $markers[$skill.name] = "codex:$($pack.namespace)/$($skill.upstream)"
            }
            if (-not $pack.enabled) { continue }
            if (-not (Test-SkillPackReviewed -Pack $pack)) {
                throw "Skill pack '$($pack.namespace)' has no current human review."
            }
            $packRoot = Join-Path $PSScriptRoot "vendor\skills\$($pack.namespace)"
            $gate = Test-SkillPackGate -Pack $pack -PackRoot $packRoot -Catalog $catalog
            if ($gate.Findings.Count) { throw $gate.Summary }
            $records = @()
            foreach ($skill in @($pack.skills | Where-Object enabled)) {
                $wanted += $skill.name
                $candidate = New-CodexSkillCandidate -Source (Join-Path $packRoot $skill.name) `
                    -Destination (Join-Path $skillRoot $skill.name) -Pack $pack -Skill $skill `
                    -Catalog $catalog -Config $config
                $records += Install-CodexSkillDirectory -Candidate $candidate `
                    -SkillRoot $skillRoot -Confirm:$false -WhatIf:$WhatIfPreference
            }
            $codexSkillResults += [pscustomobject]@{ Namespace = $pack.namespace
                CodexSkillRecords = $records }
            $reconciliationRecords += $records
        }
        $orphanRecords = @(Remove-OrphanedSkill -SkillRoot $skillRoot -Wanted $wanted `
                -Client Codex -ExpectedMarkers $markers -ReturnRecords -Confirm:$false `
                -WhatIf:$WhatIfPreference)
        $reconciliationRecords += $orphanRecords
    }

    if ($VerifyOnly) {
        $recordedWorkspace = Get-RecordedCodexWorkspaceResult -Config $config `
            -ManifestName $manifestName
        if ($recordedWorkspace) {
            $reconciliationRecords = @($recordedWorkspace.Skills) +
                @($recordedWorkspace.Agents)
        }
    }
    $checks = @(Get-CodexRegistrationCheck -Config $config -ServerResults $serverResults `
            -CodexPath $codexPath -CodexHome $CodexHome)
    $checks += @(Get-CodexWorkspaceCheck -Config $config -Catalog (Get-ToolCatalog) `
            -ServerResults $serverResults -TemplateRoot (Join-Path $PSScriptRoot 'templates') `
            -ReconciliationRecords $reconciliationRecords)
    $checks += @(Get-ServerCheck -Config $config -ServerResults $serverResults `
            -Attended:$Attended)
    foreach ($check in $checks) {
        Write-ReAgentLog -Level INFO -Message "[$($check.Status)] $($check.Name): $($check.Detail)"
    }
    if (@($checks | Where-Object { $_.Status -eq 'fail' }).Count) { $exitCode = 1 }
} catch {
    $exitCode = 1
    Write-ReAgentLog -Level ERROR -Message $_.Exception.Message
} finally {
    # A separate manifest preserves the existing Claude deployment record.
    # Server result objects contain launch metadata, never bearer tokens.
    $manifestContext = @{ Config = $config
        CodexWorkspaceConfiguration = $workspaceConfiguration
        CodexSkillResults = $codexSkillResults }
    $manifest = [ordered]@{
        generatedAt = (Get-Date).ToString('o'); agent = 'Codex'; codexHome = $CodexHome
        configVersion = $config.version; inventory = $inventory; servers = @($serverResults)
        sources = @($config.mcpServers | Select-Object name, source)
        verification = @($checks); exitCode = $exitCode
        authExemptions = @($config.mcpServers | Where-Object { $_.PSObject.Properties.Name -contains 'authExemptReason' } |
            Select-Object name, authExemptReason)
        manualSteps = @('Restart Codex to load the updated MCP configuration.',
            'Open x64dbg and x32dbg with the target loaded for attended debugging.',
            'In Binary Ninja, run Plugins > MCP > Start Server each session.',
            'GhidraMCP is disabled; the MVP release is incompatible with Ghidra 12.1.2. Use pyghidra-mcp.')
        codexWorkspace = ConvertTo-CodexWorkspaceManifestRecord -Context $manifestContext
    }
    if (-not $VerifyOnly -and $serverResults.Count -gt 0) {
        $null = New-Item -ItemType Directory -Path $config.paths.stateRoot -Force
        Write-Utf8NoBomFile -Path (Join-Path $config.paths.stateRoot 'codex-manifest.json') `
            -Text ($manifest | ConvertTo-Json -Depth 12)
    }
}
Write-ReAgentLog -Level INFO -Message "Codex setup exit code: $exitCode. Reports: $($config.paths.stateRoot)\codex-*.json"
Write-ReAgentLog -Level INFO -Message (
    "Restart Codex. Attended checks requested: $([bool]$Attended). Open x64dbg/x32dbg " +
    'and run Binary Ninja > Plugins > MCP > Start Server for attended tools.')
exit $exitCode
