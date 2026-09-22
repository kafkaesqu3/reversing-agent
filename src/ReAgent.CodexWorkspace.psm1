Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ReAgent.CodexAdapter.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ReAgent.Agents.psm1') -Force

$script:CodexInstructionMarker =
    '<!-- re-agent-managed: codex-operating-contract v1 -->'

function ConvertTo-InstructionNewline {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    return ([regex]::Replace($Text, '\r?\n', "`n")).TrimEnd([char[]]@("`r", "`n"))
}

function Get-ManagedTextByte {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $content = if ($Text.EndsWith("`n")) { $Text } else { $Text + "`r`n" }
    $encoding = New-Object Text.UTF8Encoding($false)
    return $encoding.GetBytes($content)
}

function Get-ManagedByteHash {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '')
    } finally {
        $algorithm.Dispose()
    }
}

function New-ManagedTextResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][bool]$Changed,
        [AllowEmptyString()][string]$BackupPath = ''
    )

    return [PSCustomObject]@{
        Path = $Path; Status = $Status; Sha256 = $Sha256
        Changed = $Changed; BackupPath = $BackupPath
    }
}

function Invoke-ManagedTextReplace {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PendingPath,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][bool]$DestinationExists,
        [AllowEmptyString()][string]$BackupPath = ''
    )

    try {
        [IO.File]::WriteAllBytes($PendingPath, $Bytes)
        if (-not $DestinationExists) {
            [IO.File]::Move($PendingPath, $Path)
        } else {
            $backup = if ($BackupPath) { $BackupPath } else { $null }
            [IO.File]::Replace($PendingPath, $Path, $backup)
        }
    } finally {
        if (Test-Path -LiteralPath $PendingPath) {
            Remove-Item -LiteralPath $PendingPath -Force
        }
    }
}

function New-ClientInstructionText {
    <#
    .SYNOPSIS
        Renders the shared operating contract for Claude or Codex.
    .PARAMETER TemplateRoot
        Directory containing the instructions template directory.
    .PARAMETER Client
        Client whose instruction tail is selected.
    .OUTPUTS
        [string] Deterministic Markdown with LF newlines and one final newline.
    .EXAMPLE
        New-ClientInstructionText -TemplateRoot '.\templates' -Client Codex
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][string]$TemplateRoot,
        [Parameter(Mandatory)][ValidateSet('Claude', 'Codex')][string]$Client
    )

    $instructionRoot = Join-Path $TemplateRoot 'instructions'
    $commonPath = Join-Path $instructionRoot 'common.md.template'
    $tailPath = Join-Path $instructionRoot ($Client.ToLowerInvariant() + '.md.template')
    foreach ($path in @($commonPath, $tailPath)) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Instruction template not found at '$path'."
        }
    }

    $common = ConvertTo-InstructionNewline -Text (
        Get-Content -LiteralPath $commonPath -Raw -Encoding UTF8)
    $tail = ConvertTo-InstructionNewline -Text (
        Get-Content -LiteralPath $tailPath -Raw -Encoding UTF8)
    $body = $common + "`n`n" + $tail + "`n"
    if ($Client -eq 'Claude') { return $body }

    $body = ConvertTo-CodexWorkflowText -Text $body -SkillNames @()
    return $script:CodexInstructionMarker + "`n`n" + $body
}

function Test-ReAgentOwnershipMarker {
    <#
    .SYNOPSIS
        Tests whether a text file starts with an exact RE Agent marker.
    .PARAMETER Path
        Existing text file to inspect.
    .PARAMETER Marker
        Exact first-line ownership marker.
    .OUTPUTS
        [bool] True only when the marker is the complete first line.
    .EXAMPLE
        Test-ReAgentOwnershipMarker -Path '.\AGENTS.md' -Marker '<!-- managed -->'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Marker
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($null -eq $text) { return $false }
    $comparison = [StringComparison]::Ordinal
    return [string]::Equals($text, $Marker, $comparison) -or
        $text.StartsWith($Marker + "`n", $comparison) -or
        $text.StartsWith($Marker + "`r`n", $comparison)
}

function Set-ManagedTextFile {
    <#
    .SYNOPSIS
        Reconciles one ownership-marked UTF-8 text file safely.
    .DESCRIPTION
        Refuses unmanaged collisions before ShouldProcess, preserves unchanged
        files, and replaces changed files from a same-directory pending file.
    .PARAMETER Path
        Managed destination path.
    .PARAMETER Text
        Complete candidate text.
    .PARAMETER Marker
        Exact marker required at the start of an existing file.
    .PARAMETER BackupOnChange
        Whether a changed destination receives a unique backup.
    .OUTPUTS
        [pscustomobject] Path, status, hash, changed flag, and backup path.
    .EXAMPLE
        Set-ManagedTextFile -Path '.\AGENTS.md' -Text $text `
            -Marker '<!-- managed -->' -BackupOnChange $true
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][bool]$BackupOnChange
    )

    $fullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    $wanted = Get-ManagedTextByte -Text $Text
    $hash = Get-ManagedByteHash -Bytes $wanted
    $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
    if ($exists -and -not (Test-ReAgentOwnershipMarker -Path $fullPath -Marker $Marker)) {
        throw "Refusing to replace unmanaged file '$fullPath'."
    }
    if ($exists) {
        $current = [IO.File]::ReadAllBytes($fullPath)
        if ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                $current, $wanted)) {
            return New-ManagedTextResult -Path $fullPath -Status 'unchanged' `
                -Sha256 $hash -Changed $false
        }
    }
    if (-not $PSCmdlet.ShouldProcess($fullPath, 'Write managed text')) {
        return New-ManagedTextResult -Path $fullPath -Status 'what-if' `
            -Sha256 $hash -Changed $true
    }

    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    $leaf = Split-Path -Leaf $fullPath
    $id = [guid]::NewGuid().ToString('N')
    $pending = Join-Path $parent "$leaf.$id.pending"
    $backup = if ($BackupOnChange -and $exists) {
        Join-Path $parent "$leaf.$id.bak"
    } else { '' }
    Invoke-ManagedTextReplace -Path $fullPath -PendingPath $pending `
        -Bytes $wanted -DestinationExists $exists -BackupPath $backup
    $status = if ($exists) { 'updated' } else { 'created' }
    return New-ManagedTextResult -Path $fullPath -Status $status `
        -Sha256 $hash -Changed $true -BackupPath $backup
}

function Write-CodexInstruction {
    <#
    .SYNOPSIS
        Reconciles the project-scoped Codex AGENTS.md contract.
    .PARAMETER Config
        Configuration containing paths.agentRoot.
    .PARAMETER TemplateRoot
        Directory containing instruction templates.
    .OUTPUTS
        [pscustomobject] Managed-file reconciliation record.
    .EXAMPLE
        Write-CodexInstruction -Config $config -TemplateRoot '.\templates'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$TemplateRoot
    )

    $path = Join-Path $Config.paths.agentRoot 'AGENTS.md'
    $text = New-ClientInstructionText -TemplateRoot $TemplateRoot -Client Codex
    return Set-ManagedTextFile -Path $path -Text $text `
        -Marker $script:CodexInstructionMarker -BackupOnChange $true `
        -WhatIf:$WhatIfPreference
}

$script:CodexAgentMarker = '# re-agent-managed: codex-custom-agent v1'

function Get-CodexAgentTemplatePart {
    param([Parameter(Mandatory)][string]$Path)

    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $match = [regex]::Match($text,
        '\A---\r?\n(?<front>[\s\S]*?)\r?\n---\r?\n(?<body>[\s\S]*)\z')
    if (-not $match.Success) { throw "Agent template '$Path' has no strict frontmatter." }
    $description = [regex]::Match($match.Groups['front'].Value, '(?m)^description:\s*(?<v>.*)$')
    if (-not $description.Success) { throw "Agent template '$Path' has no description." }
    return [pscustomobject]@{
        Description = $description.Groups['v'].Value
        Body = $match.Groups['body'].Value
    }
}

function Get-CodexAgentToolsByServer {
    param(
        [Parameter(Mandatory)][object]$Agent,
        [Parameter(Mandatory)][object]$Grant,
        [Parameter(Mandatory)][string]$Server
    )

    if (@($Agent.targetServers) -notcontains $Server) { return @() }
    $prefix = "mcp__${Server}__"
    return @($Grant.Tools | Where-Object {
            $_.StartsWith($prefix, [StringComparison]::Ordinal)
        } | ForEach-Object { $_.Substring($prefix.Length) } | Sort-Object)
}

function Get-CodexAgentServerProse {
    param([Parameter(Mandatory)][object]$Agent, [Parameter(Mandatory)][object]$Grant)

    $lines = foreach ($server in @($Agent.targetServers)) {
        $count = @(Get-CodexAgentToolsByServer -Agent $Agent -Grant $Grant -Server $server).Count
        "- ``$server`` $([char]0x2014) $count tool(s) at level ``$($Agent.level)``."
    }
    if (-not $lines) { return '- None. This agent has no MCP reach.' }
    return $lines -join "`n"
}

function Get-CodexAgentLimitation {
    param([Parameter(Mandatory)][object]$Agent, [Parameter(Mandatory)][object]$Catalog)

    $lines = foreach ($server in @($Agent.targetServers)) {
        if ((Get-ToolClassification -Catalog $Catalog -Server $server).Known) { continue }
        "- ``$server`` is declared but not captured, so you hold no tools for it."
    }
    $lines += ('- A missing tool is your grant, not a broken server. ' +
        'Report it; do not work around it.')
    return $lines -join "`n"
}

function Get-CodexAgentClientLimitation {
    param([Parameter(Mandatory)][object]$Agent, [Parameter(Mandatory)][object]$Config)

    $sse = @($Config.mcpServers | Where-Object {
            $_.name -in @($Agent.targetServers) -and $_.transport -eq 'sse'
        } | ForEach-Object { $_.name })
    $lines = @()
    if ($sse.Count) {
        $lines += ('- Legacy SSE is unsupported by Codex; unavailable targets: ' +
            ($sse -join ', ') + '.')
    }
    $lines += ('- If a GUI-hosted tool is unavailable, the host application is normally closed. ' +
        'Ask the main session or operator to start it; do not work around the missing grant.')
    return $lines -join "`n"
}

function Get-CodexAgentOmittedServer {
    param([Parameter(Mandatory)][object]$Agent,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ServerResults)

    return @($ServerResults | Where-Object {
            $_.Installed -and $_.Transport -eq 'sse' -and $_.Name -in @($Agent.targetServers)
        } | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ Agent = $Agent.name; Name = $_.Name
                Reason = 'legacy SSE is unsupported by Codex' }
        })
}

function Assert-CodexAgentAuthentication {
    param(
        [Parameter(Mandatory)][object]$Agent,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ServerResults
    )

    foreach ($server in @($Config.mcpServers | Where-Object {
                $_.name -in @($Agent.targetServers) -and $_.auth -ne 'none'
            })) {
        $result = @($ServerResults | Where-Object {
                $_.Installed -and $_.Name -eq $server.name -and
                $_.Transport -in @('http', 'stdio')
            })[0]
        if ($result) {
            throw "Authenticated server '$($server.name)' cannot be enabled for Codex agents."
        }
    }
}

function New-CodexAgentToml {
    <#
    .SYNOPSIS
        Renders a complete, token-free Codex custom-agent TOML document.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][object]$Agent,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ServerResults,
        [Parameter(Mandatory)][string]$TemplateRoot
    )

    Assert-CodexAgentAuthentication -Agent $Agent -Config $Config -ServerResults $ServerResults
    $templatePath = Join-Path $TemplateRoot "agents\$($Agent.name).md.template"
    $template = Get-CodexAgentTemplatePart -Path $templatePath
    $grant = Get-AgentToolGrant -Agent $Agent -Catalog $Catalog
    $serverProse = Get-CodexAgentServerProse -Agent $Agent -Grant $grant
    $body = $template.Body.Replace('{{SERVERS}}', $serverProse)
    $limitation = Get-CodexAgentLimitation -Agent $Agent -Catalog $Catalog
    $body = $body.Replace('{{LIMITATIONS}}', $limitation)
    $body = $body.Replace('{{CLIENT_LIMITATIONS}}',
        (Get-CodexAgentClientLimitation -Agent $Agent -Config $Config))
    $sandbox = if ($Agent.level -eq 'write') { 'workspace-write' } else { 'read-only' }
    $lines = @($script:CodexAgentMarker,
        ('name = ' + (ConvertTo-CodexTomlValue -Value ([string]$Agent.name))),
        ('description = ' + (ConvertTo-CodexTomlValue -Value ([string]$template.Description))),
        ('developer_instructions = ' + (ConvertTo-CodexTomlValue -Value $body)),
        ('sandbox_mode = ' + (ConvertTo-CodexTomlValue -Value $sandbox)))
    foreach ($result in @($ServerResults | Where-Object {
                $_.Installed -and $_.Transport -in @('http', 'stdio')
            } | Sort-Object Name)) {
        $server = @($Config.mcpServers | Where-Object { $_.name -eq $result.Name })[0]
        if (-not $server) { throw "Installed server '$($result.Name)' is absent from config." }
        $tools = @(Get-CodexAgentToolsByServer -Agent $Agent -Grant $grant -Server $result.Name)
        $isTarget = @($Agent.targetServers) -contains $result.Name
        $lines += ''
        $lines += New-CodexAgentServerTable -ConfigServer $server -ServerResult $result `
            -Enabled $isTarget -EnabledTools $tools
    }
    return $lines -join "`n"
}

function Remove-DisabledCodexAgentDefinition {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object]$Agent, [Parameter(Mandatory)][string]$AgentDir)

    $path = Join-Path $AgentDir "$($Agent.name).toml"
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{
            Name = $Agent.name; Enabled = $false; Path = $path; Changed = $false
            OmittedServers = @()
        }
    }
    if (-not (Test-ReAgentOwnershipMarker -Path $path -Marker $script:CodexAgentMarker)) {
        throw "Refusing to remove unmanaged Codex agent '$path'."
    }
    if ($PSCmdlet.ShouldProcess($path, 'Remove disabled Codex custom agent')) {
        Remove-Item -LiteralPath $path -Force
        return [pscustomobject]@{
            Name = $Agent.name; Enabled = $false; Path = $path; Changed = $true
            OmittedServers = @()
        }
    }
    return [pscustomobject]@{
        Name = $Agent.name; Enabled = $false; Path = $path; Changed = $true
        OmittedServers = @()
    }
}

function Write-CodexAgentDefinition {
    <#
    .SYNOPSIS
        Reconciles one marked Codex TOML file per declared custom agent.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ServerResults,
        [Parameter(Mandatory)][string]$TemplateRoot
    )

    $agentDir = Join-Path $Config.paths.agentRoot '.codex\agents'
    $enabled = @($Config.agents | Where-Object enabled)
    $candidates = @{}
    foreach ($agent in $enabled) {
        $candidates[$agent.name] = New-CodexAgentToml -Agent $agent -Catalog $Catalog `
            -Config $Config `
            -ServerResults $ServerResults -TemplateRoot $TemplateRoot
    }
    $results = @()
    foreach ($agent in @($Config.agents | Where-Object { -not $_.enabled })) {
        $results += Remove-DisabledCodexAgentDefinition -Agent $agent -AgentDir $agentDir `
            -WhatIf:$WhatIfPreference
    }
    foreach ($agent in $enabled) {
        $path = Join-Path $agentDir "$($agent.name).toml"
        $record = Set-ManagedTextFile -Path $path -Text $candidates[$agent.name] `
            -Marker $script:CodexAgentMarker -BackupOnChange:$false -WhatIf:$WhatIfPreference
        $results += [pscustomobject]@{ Name = $agent.name; Enabled = $true; Path = $path
            Changed = $record.Changed; Status = $record.Status
            OmittedServers = @(Get-CodexAgentOmittedServer -Agent $agent `
                    -ServerResults $ServerResults) }
    }
    return $results
}

function Write-CodexWorkspaceConfiguration {
    <#
    .SYNOPSIS
        Reconciles Codex instructions and custom agents below the project root.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ServerResults,
        [Parameter(Mandatory)][string]$TemplateRoot
    )

    $instruction = Write-CodexInstruction -Config $Config -TemplateRoot $TemplateRoot `
        -WhatIf:$WhatIfPreference
    $agents = @(Write-CodexAgentDefinition -Config $Config -Catalog $Catalog `
            -ServerResults $ServerResults -TemplateRoot $TemplateRoot -WhatIf:$WhatIfPreference)
    return [pscustomobject]@{ Instruction = $instruction; Agents = $agents
        OmittedServers = @($agents | ForEach-Object { $_.OmittedServers }) }
}

function Assert-SkillTreePath {
    <#
    .SYNOPSIS
        Resolves a contained skill path and rejects reparse-point traversal.
    .PARAMETER Root
        Expected skill tree root.
    .PARAMETER Path
        Candidate child path, including paths that do not yet exist.
    .EXAMPLE
        Assert-SkillTreePath -Root 'C:\agent\.agents\skills' -Path $destination
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $base = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Root).TrimEnd('\', '/')
    $full = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not $full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe skill path '$full': outside '$base'."
    }
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Unsafe skill path '$full': reparse point '$current'."
            }
        }
        $current = Split-Path -Parent $current
    }
    return $full
}

function Get-CodexResidueRule {
    $patterns = [ordered]@{
        'C4-CLAUDE-SKILL-PATH' = '\.claude[/\\]skills'
        'C4-CLAUDE-AGENT-PATH' = '\.claude[/\\]agents'
        'C4-CLAUDE-PRECEDENCE' = 'CLAUDE\.md wins'
        'C4-TODOWRITE' = '\bTodoWrite\b'
        'C4-TASK-TOOL' = '\bTask tool\b'
        'C4-AGENT-TOOL' = '(?<![A-Za-z0-9_-])Agent tool\b'
        'C4-SKILL-TOOL' = '\bSkill tool\b'
        'C4-HYPHENATED-MCP' = 'mcp__[A-Za-z0-9_-]*-[A-Za-z0-9_-]*__'
        'C4-CLAUDE-BUILTIN' = '`(?:Bash|Read|Glob|Grep|Write|Edit|Agent|Task)` tools?'
    }
    foreach ($entry in $patterns.GetEnumerator()) {
        [pscustomobject]@{ id = $entry.Key; pattern = $entry.Value; severity = 'block' }
    }
}

function Get-CodexSkillExceptionRule {
    param(
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][string]$Upstream,
        [Parameter(Mandatory)][string]$RelativePath
    )

    if ($Pack.PSObject.Properties.Name -notcontains 'codexScanExceptions') { return }
    return @($Pack.codexScanExceptions | Where-Object {
        $_.skill -ceq $Upstream -and $_.file -ceq $RelativePath -and
        -not [string]::IsNullOrWhiteSpace($_.justification)
    } | ForEach-Object { $_.ruleId })
}

function Assert-CodexSkillText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][object]$Skill,
        [Parameter(Mandatory)][bool]$Changed
    )

    if ($RelativePath -ceq 'SKILL.md') {
        $frontmatter = Get-SkillFrontmatter -Text $Text
        if ([string]$frontmatter['name'] -cne [string]$Skill.name) {
            throw "Codex frontmatter name does not match '$($Skill.name)'."
        }
        if ($frontmatter.ContainsKey('allowed-tools')) {
            throw 'Codex frontmatter retains allowed-tools.'
        }
    }
    $exceptions = @(Get-CodexSkillExceptionRule -Pack $Pack -Upstream $Skill.upstream `
        -RelativePath $RelativePath)
    $findings = @(Test-SkillContent -Text $Text -Rules @(Get-CodexResidueRule) `
        -File "$($Skill.name)/$RelativePath" | Where-Object {
            $exceptions -cnotcontains $_.RuleId
        })
    if ($Changed) {
        $raw = @(Test-SkillContent -Text $Text -Rules (Get-SkillScanRule) `
            -File "$($Skill.name)/$RelativePath")
        $findings += @(Select-UnwaivedFinding -Findings $raw `
            -Exceptions @($Pack.scanExceptions) -Skill $Skill.upstream |
            Where-Object { $_.Severity -eq 'block' })
    }
    if ($findings.Count) {
        $first = $findings[0]
        throw "Codex $($first.RuleId) in $($first.File):$($first.Line): $($first.Text)"
    }
}

function Get-CodexSkillFileRecord {
    param(
        [Parameter(Mandatory)][IO.FileInfo]$File,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][hashtable]$Conversion,
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][object]$Skill
    )

    $path = Assert-SkillTreePath -Root $Source -Path $File.FullName
    $relative = $path.Substring($Source.Length).TrimStart('\', '/').Replace('\', '/')
    if ($relative -eq '.re-agent-managed') { throw 'Reviewed source contains a managed marker.' }
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($File.Extension -in @('.md', '.markdown', '.txt', '.json', '.yaml', '.yml', '.toml')) {
        $original = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        $converted = ConvertTo-CodexSkillText -Text $original @Conversion
        $changed = $original -cne $converted
        Assert-CodexSkillText -Text $converted -RelativePath $relative `
            -Pack $Pack -Skill $Skill -Changed $changed
        if ($changed) { $bytes = [Text.Encoding]::UTF8.GetBytes($converted) }
    }
    return [pscustomobject]@{ RelativePath = $relative; Bytes = $bytes }
}

function New-CodexSkillCandidate {
    <#
    .SYNOPSIS
        Builds and validates an in-memory Codex skill tree from reviewed source.
    .PARAMETER Source
        Skill directory under the repository vendor/skills tree.
    .PARAMETER Destination
        Exact final Codex skill directory.
    .PARAMETER Pack
        Reviewed pack configuration, including exact residue exceptions.
    .PARAMETER Skill
        Enabled skill configuration.
    .PARAMETER Catalog
        Pinned MCP tool catalog.
    .PARAMETER Config
        Configuration containing MCP transports and enabled skill names.
    .EXAMPLE
        New-CodexSkillCandidate -Source $source -Destination $destination `
            -Pack $pack -Skill $skill -Catalog $catalog -Config $config
    #>
    [CmdletBinding(PositionalBinding = $false)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][object]$Skill,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][object]$Config
    )

    $sourceRoot = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Source).TrimEnd('\', '/')
    if ($sourceRoot -notmatch '[/\\]vendor[/\\]skills[/\\]') {
        throw 'Codex skills must be built from reviewed vendor/skills source.'
    }
    $servers = @($Config.mcpServers)
    $null = Assert-SkillTreePath -Root (Split-Path $sourceRoot) -Path $sourceRoot
    $names = @($Pack.skills | Where-Object enabled | ForEach-Object { $_.name })
    if ($Config.PSObject.Properties.Name -contains 'skills') {
        $names = @($Config.skills | Where-Object enabled | ForEach-Object { $_.skills } |
            Where-Object enabled | ForEach-Object { $_.name })
    }
    $conversion = @{
        NamespaceMap = Get-CodexMcpNamespaceMap -Servers $servers
        Catalog = $Catalog; SkillNames = $names
        CompatibleServers = @($servers | Where-Object { $_.transport -in @('http', 'stdio') } |
            ForEach-Object { $_.name })
    }
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot 'SKILL.md') -PathType Leaf)) {
        throw "Codex source '$sourceRoot' has no SKILL.md."
    }
    $paths = [string[]]@(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force |
        ForEach-Object { $_.FullName })
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $files = @($paths | ForEach-Object {
            Get-CodexSkillFileRecord -File (Get-Item -LiteralPath $_ -Force) `
                -Source $sourceRoot -Conversion $conversion `
                -Pack $Pack -Skill $Skill
        })
    $marker = "codex:$($Pack.namespace)/$($Skill.upstream)"
    $files += [pscustomobject]@{ RelativePath = '.re-agent-managed'
        Bytes = [Text.Encoding]::UTF8.GetBytes($marker) }
    $candidate = [pscustomobject]@{ Name = $Skill.name; Destination = $Destination
        Files = $files; Marker = $marker }
    $null = Assert-CodexSkillDestination -Candidate $candidate -SkillRoot (Split-Path $Destination)
    return $candidate
}

function Get-CodexSkillDigest {
    param([Parameter(Mandatory)][array]$Files)

    $entries = @{}
    foreach ($file in $Files) { $entries[[string]$file.RelativePath] = $file.Bytes }
    $paths = [string[]]@($entries.Keys)
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $lines = foreach ($path in $paths) {
        $path + ':' + (Get-ManagedByteHash -Bytes $entries[$path])
    }
    return Get-ManagedByteHash -Bytes ([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))
}

function Get-CodexInstalledFileRecord {
    param([Parameter(Mandatory)][string]$Path)

    foreach ($file in Get-ChildItem -LiteralPath $Path -Recurse -Force) {
        $safe = Assert-SkillTreePath -Root $Path -Path $file.FullName
        if ($file.PSIsContainer) { continue }
        [pscustomobject]@{
            RelativePath = $safe.Substring($Path.Length).TrimStart('\').Replace('\', '/')
            Bytes = [IO.File]::ReadAllBytes($safe)
        }
    }
}

function Assert-CodexSkillDestination {
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][string]$SkillRoot
    )

    if ($Candidate.Name -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw "Unsafe skill name '$($Candidate.Name)'."
    }
    $path = Assert-SkillTreePath -Root $SkillRoot -Path $Candidate.Destination
    $expected = Join-Path $SkillRoot $Candidate.Name
    $expected = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($expected)
    if ($path -ne $expected) { throw "Unexpected skill destination path '$path'." }
    if (Test-Path -LiteralPath $path) {
        $marker = Join-Path $path '.re-agent-managed'
        $null = Assert-SkillTreePath -Root $SkillRoot -Path $marker
        if (-not (Test-ReAgentOwnershipMarker -Path $marker -Marker $Candidate.Marker)) {
            throw "Refusing to replace unmanaged skill '$path'."
        }
    }
    $seen = @{}
    foreach ($file in $Candidate.Files) {
        if ($file.RelativePath -eq '.re-agent-stage-owner') {
            throw 'Reserved candidate path .re-agent-stage-owner.'
        }
        if ($file.RelativePath -match '(^|[/\\])\.\.([/\\]|$)|[:*?]') {
            throw "Unsafe candidate relative path '$($file.RelativePath)'."
        }
        $target = Assert-SkillTreePath -Root $path -Path (Join-Path $path $file.RelativePath)
        if ($seen.ContainsKey($target)) { throw "Duplicate candidate path '$target'." }
        $seen[$target] = $true
    }
    return $path
}

function Get-OwnedCodexSkillArtifact {
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][string]$SkillRoot,
        [ValidateSet('stage', 'previous')][string]$Kind
    )

    if (-not (Test-Path -LiteralPath $SkillRoot)) { return }
    $pattern = '^\.re-agent-' + $Kind + '-' + [regex]::Escape($Candidate.Name) +
        '-[a-f0-9]{32}$'
    foreach ($item in Get-ChildItem -LiteralPath $SkillRoot -Directory -Force) {
        if ($item.Name -cnotmatch $pattern) { continue }
        $path = Assert-SkillTreePath -Root $SkillRoot -Path $item.FullName
        $markers = @('.re-agent-managed')
        if ($Kind -eq 'stage') { $markers += '.re-agent-stage-owner' }
        foreach ($name in $markers) {
            $marker = Assert-SkillTreePath -Root $SkillRoot -Path (Join-Path $path $name)
            if (Test-ReAgentOwnershipMarker -Path $marker -Marker $Candidate.Marker) {
                $item
                break
            }
        }
    }
}

function Remove-ObsoleteCodexSkillArtifact {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][string]$SkillRoot
    )

    # Called only after the installed tree matches the candidate or a publish succeeds.
    foreach ($kind in @('previous', 'stage')) {
        foreach ($item in Get-OwnedCodexSkillArtifact -Candidate $Candidate `
                -SkillRoot $SkillRoot -Kind $kind) {
            if ($PSCmdlet.ShouldProcess($item.FullName, 'Remove obsolete owned skill artifact')) {
                Remove-CodexSkillStage -Path $item.FullName -SkillRoot $SkillRoot -Confirm:$false
            }
        }
    }
}

function Restore-CodexSkillDirectory {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][string]$SkillRoot
    )

    if (-not (Test-Path -LiteralPath $SkillRoot)) { return }
    if (Test-Path -LiteralPath $Candidate.Destination) { return }
    $previous = @(Get-OwnedCodexSkillArtifact -Candidate $Candidate -SkillRoot $SkillRoot `
        -Kind previous | Sort-Object LastWriteTimeUtc, Name -Descending)
    if ($previous.Count -eq 0) { return }
    $path = Assert-SkillTreePath -Root $SkillRoot -Path $previous[0].FullName
    $marker = Assert-SkillTreePath -Root $SkillRoot -Path (Join-Path $path '.re-agent-managed')
    if (-not (Test-ReAgentOwnershipMarker -Path $marker -Marker $Candidate.Marker)) {
        throw "Refusing unmanaged previous skill '$path'."
    }
    $null = @(Get-CodexInstalledFileRecord -Path $path)
    if ($PSCmdlet.ShouldProcess($path, 'Recover previous Codex skill')) {
        Move-Item -LiteralPath $path -Destination $Candidate.Destination -ErrorAction Stop
    }
}

function Remove-CodexSkillStage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SkillRoot
    )

    $safe = Assert-SkillTreePath -Root $SkillRoot -Path $Path
    if (-not (Test-Path -LiteralPath $safe)) { return }
    $null = @(Get-CodexInstalledFileRecord -Path $safe)
    if ($PSCmdlet.ShouldProcess($safe, 'Remove managed staging directory')) {
        Remove-Item -LiteralPath $safe -Recurse -Force -ErrorAction Stop
    }
}

function Publish-CodexSkillStage {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Previous,
        [Parameter(Mandatory)][string]$SkillRoot
    )

    $moved = $false
    try {
        if (Test-Path -LiteralPath $Destination) {
            Move-Item -LiteralPath $Destination -Destination $Previous -ErrorAction Stop
            $moved = $true
        }
        Move-Item -LiteralPath $Stage -Destination $Destination -ErrorAction Stop
    } catch {
        if ($moved) {
            if (Test-Path -LiteralPath $Destination) {
                Remove-CodexSkillStage -Path $Destination -SkillRoot $SkillRoot -Confirm:$false
            }
            Move-Item -LiteralPath $Previous -Destination $Destination -ErrorAction Stop
        }
        throw
    }
    Remove-CodexSkillStage -Path $Previous -SkillRoot $SkillRoot -Confirm:$false
}

function Install-CodexSkillDirectory {
    <#
    .SYNOPSIS
        Atomically reconciles a validated ownership-marked Codex skill tree.
    .PARAMETER Candidate
        In-memory skill name, destination, file records and ownership marker.
    .PARAMETER SkillRoot
        Exact parent of the destination and all staging directories.
    .OUTPUTS
        Name, path, status, deterministic SHA-256 tree digest and changed flag.
    .EXAMPLE
        Install-CodexSkillDirectory -Candidate $candidate -SkillRoot 'C:\agent\.agents\skills'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][string]$SkillRoot
    )

    $path = Assert-CodexSkillDestination -Candidate $Candidate -SkillRoot $SkillRoot
    $ownedBefore = Test-Path -LiteralPath $path
    Restore-CodexSkillDirectory -Candidate $Candidate -SkillRoot $SkillRoot `
        -WhatIf:$WhatIfPreference -Confirm:$false
    $hash = Get-CodexSkillDigest -Files $Candidate.Files
    $result = [pscustomobject]@{ Name = $Candidate.Name; Path = $path
        Status = 'what-if'; Sha256 = $hash; Changed = $true
        Action = $(if ($ownedBefore) { 'update' } else { 'create' })
        OwnedBefore = $ownedBefore }
    if (-not $PSCmdlet.ShouldProcess($path, 'Install complete Codex skill tree')) { return $result }
    $id = [guid]::NewGuid().ToString('N')
    $stage = Join-Path $SkillRoot ".re-agent-stage-$($Candidate.Name)-$id"
    $previous = Join-Path $SkillRoot ".re-agent-previous-$($Candidate.Name)-$id"
    $stage = Assert-SkillTreePath -Root $SkillRoot -Path $stage
    try {
        $null = New-Item -ItemType Directory -Path $stage -Force -ErrorAction Stop
        $owner = Join-Path $stage '.re-agent-stage-owner'
        [IO.File]::WriteAllBytes($owner, [Text.Encoding]::UTF8.GetBytes($Candidate.Marker))
        foreach ($file in $Candidate.Files) {
            $target = Assert-SkillTreePath -Root $stage -Path (Join-Path $stage $file.RelativePath)
            $null = New-Item -ItemType Directory -Path (Split-Path $target) -Force -ErrorAction Stop
            [IO.File]::WriteAllBytes($target, $file.Bytes)
        }
        Remove-Item -LiteralPath $owner -Force -ErrorAction Stop
        $currentHash = ''
        if (Test-Path -LiteralPath $path) {
            $currentHash = Get-CodexSkillDigest -Files @(Get-CodexInstalledFileRecord -Path $path)
        }
        if ($currentHash -eq $hash) {
            Remove-ObsoleteCodexSkillArtifact -Candidate $Candidate -SkillRoot $SkillRoot `
                -Confirm:$false
            $result.Status = 'unchanged'; $result.Changed = $false
            $result.Action = 'none'
            return $result
        }
        Publish-CodexSkillStage -Stage $stage -Destination $path -Previous $previous `
            -SkillRoot $SkillRoot
        Remove-ObsoleteCodexSkillArtifact -Candidate $Candidate -SkillRoot $SkillRoot `
            -Confirm:$false
        $result.Status = 'installed'
        return $result
    } finally {
        Remove-CodexSkillStage -Path $stage -SkillRoot $SkillRoot -Confirm:$false
    }
}

Export-ModuleMember -Function New-ClientInstructionText, Write-CodexInstruction, `
    Test-ReAgentOwnershipMarker, Set-ManagedTextFile, New-CodexSkillCandidate, `
    Install-CodexSkillDirectory, Assert-SkillTreePath, New-CodexAgentToml, `
    Write-CodexAgentDefinition, Write-CodexWorkspaceConfiguration
