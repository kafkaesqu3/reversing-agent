Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ReAgent.CodexAdapter.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ReAgent.CodexWorkspace.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ReAgent.Skills.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ReAgent.Verify.psm1') -Force

function Get-CodexEnabledSkill {
    param([Parameter(Mandatory)][object]$Config)

    if ($Config.PSObject.Properties.Name -notcontains 'skills') { return @() }
    $skills = @()
    foreach ($pack in @($Config.skills | Where-Object enabled)) {
        foreach ($skill in @($pack.skills | Where-Object enabled)) {
            $skills += [pscustomobject]@{ Pack = $pack; Skill = $skill
                Name = [string]$skill.name; Upstream = [string]$skill.upstream }
        }
    }
    return $skills
}

function Get-CodexSortedName {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Names)

    $sorted = [string[]]@($Names | Select-Object -Unique)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return $sorted
}

function Format-CodexNameSet {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Names)

    return '[' + ((Get-CodexSortedName -Names $Names) -join ', ') + ']'
}

function Test-CodexNameSetEqual {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Left,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Right
    )

    $leftSorted = @(Get-CodexSortedName -Names $Left)
    $rightSorted = @(Get-CodexSortedName -Names $Right)
    if ($leftSorted.Count -ne $rightSorted.Count) { return $false }
    for ($index = 0; $index -lt $leftSorted.Count; $index++) {
        if (-not [string]::Equals($leftSorted[$index], $rightSorted[$index],
                [StringComparison]::Ordinal)) { return $false }
    }
    return $true
}

function Get-CodexMarkedSkill {
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][ValidateSet('Claude', 'Codex')][string]$Client
    )

    $relativeRoot = if ($Client -eq 'Claude') { '.claude\skills' } else { '.agents\skills' }
    $root = Join-Path $Config.paths.agentRoot $relativeRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }

    $prefix = if ($Client -eq 'Claude') { '' } else { 'codex:' }
    $records = @()
    foreach ($directory in Get-ChildItem -LiteralPath $root -Directory -Force) {
        $marker = Join-Path $directory.FullName '.re-agent-managed'
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { continue }
        $value = [IO.File]::ReadAllText($marker, [Text.Encoding]::UTF8).Trim()
        if ($Client -eq 'Codex' -and -not $value.StartsWith($prefix, [StringComparison]::Ordinal)) {
            continue
        }
        if ($Client -eq 'Claude' -and $value -notmatch '^[^/]+/[^/]+$') { continue }
        $identity = if ($Client -eq 'Codex') { $value.Substring($prefix.Length) } else { $value }
        $parts = $identity -split '/', 2
        if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) { continue }
        $records += [pscustomobject]@{ Name = $directory.Name; Directory = $directory.FullName
            Namespace = $parts[0]; Upstream = $parts[1]; Client = $Client }
    }
    return $records
}

function Get-CodexTextRecord {
    param([Parameter(Mandatory)][object]$Config)

    $records = @()
    $agents = Join-Path $Config.paths.agentRoot 'AGENTS.md'
    $marker = '<!-- re-agent-managed: codex-operating-contract v1 -->'
    if (Test-ReAgentOwnershipMarker -Path $agents -Marker $marker) {
        $records += [pscustomobject]@{ File = 'AGENTS.md'; Text = [IO.File]::ReadAllText(
                $agents, [Text.Encoding]::UTF8); Pack = $null; Skill = $null; RelativePath = '' }
    }

    foreach ($skillRecord in Get-CodexMarkedSkill -Config $Config -Client Codex) {
        $pack = @($Config.skills | Where-Object { $_.namespace -ceq $skillRecord.Namespace }) |
            Select-Object -First 1
        $skill = if ($pack) {
            @($pack.skills | Where-Object { $_.upstream -ceq $skillRecord.Upstream }) |
                Select-Object -First 1
        } else { $null }
        foreach ($file in Get-ChildItem -LiteralPath $skillRecord.Directory -Recurse -File -Force) {
            if ($file.Name -eq '.re-agent-managed' -or $file.Extension -notin @(
                    '.md', '.markdown', '.txt', '.json', '.yaml', '.yml', '.toml')) { continue }
            $relative = $file.FullName.Substring($skillRecord.Directory.Length).TrimStart('\', '/')
            $records += [pscustomobject]@{ File = ('skills/' + $skillRecord.Name + '/' +
                    $relative.Replace('\', '/')); Text = [IO.File]::ReadAllText($file.FullName,
                    [Text.Encoding]::UTF8); Pack = $pack; Skill = $skill; RelativePath = $relative.Replace('\', '/') }
        }
    }

    $agentRoot = Join-Path $Config.paths.agentRoot '.codex\agents'
    if (Test-Path -LiteralPath $agentRoot -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $agentRoot -File -Filter '*.toml' -Force) {
            $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
            if ($text.StartsWith('# re-agent-managed: codex-custom-agent v1',
                    [StringComparison]::Ordinal)) {
                $records += [pscustomobject]@{ File = 'agents/' + $file.Name; Text = $text
                    Pack = $null; Skill = $null; RelativePath = '' }
            }
        }
    }
    return $records
}

function Get-CodexInstructionCheck {
    <# .SYNOPSIS Checks C0 deterministic Codex instruction bytes. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$TemplateRoot
    )

    $path = Join-Path $Config.paths.agentRoot 'AGENTS.md'
    $marker = '<!-- re-agent-managed: codex-operating-contract v1 -->'
    if (-not (Test-ReAgentOwnershipMarker -Path $path -Marker $marker)) {
        return New-CheckResult -Name 'C0 Codex instructions' -Status fail `
            -Detail "$path is unmanaged."
    }
    $expected = [Text.UTF8Encoding]::new($false).GetBytes(
        (New-ClientInstructionText -TemplateRoot $TemplateRoot -Client Codex))
    $actual = [IO.File]::ReadAllBytes($path)
    if (-not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals($actual, $expected)) {
        return New-CheckResult -Name 'C0 Codex instructions' -Status fail `
            -Detail "$path byte mismatch."
    }
    return New-CheckResult -Name 'C0 Codex instructions' -Status pass `
        -Detail "$path matches the deterministic Codex render."
}

function Get-CodexSkillSetCheck {
    <# .SYNOPSIS Checks C1 enabled skill sets across config and both clients. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    $expected = @((Get-CodexEnabledSkill -Config $Config) | ForEach-Object { $_.Name })
    $claude = @(Get-CodexMarkedSkill -Config $Config -Client Claude | ForEach-Object { $_.Name })
    $codex = @(Get-CodexMarkedSkill -Config $Config -Client Codex | ForEach-Object { $_.Name })
    $detail = 'expected ' + (Format-CodexNameSet -Names $expected) + '; Claude ' +
        (Format-CodexNameSet -Names $claude) + '; Codex ' + (Format-CodexNameSet -Names $codex) + '.'
    if (-not (Test-CodexNameSetEqual -Left $expected -Right $claude) -or
        -not (Test-CodexNameSetEqual -Left $expected -Right $codex)) {
        return New-CheckResult -Name 'C1 Codex skill set' -Status fail -Detail $detail
    }
    return New-CheckResult -Name 'C1 Codex skill set' -Status pass -Detail $detail
}

function Get-CodexSkillIdentityCheck {
    <# .SYNOPSIS Checks C2 generated Codex skill frontmatter identities. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    $expected = @(Get-CodexEnabledSkill -Config $Config)
    $records = @(Get-CodexMarkedSkill -Config $Config -Client Codex)
    $findings = @()
    foreach ($record in $records) {
        $configured = @($expected | Where-Object { $_.Name -ceq $record.Name }) |
            Select-Object -First 1
        $configuredName = if ($configured) { $configured.Name } else { '<not configured>' }
        $skillPath = Join-Path $record.Directory 'SKILL.md'
        $declared = '<missing>'
        if (Test-Path -LiteralPath $skillPath -PathType Leaf) {
            try { $declared = [string](Get-SkillFrontmatter -Text (
                        [IO.File]::ReadAllText($skillPath, [Text.Encoding]::UTF8)))['name'] }
            catch { $declared = '<unparseable>' }
        }
        if ($declared -cne $record.Name -or $declared -cne $configuredName) {
            $findings += "directory '$($record.Name)', declared '$declared', configured '$configuredName'"
        }
    }
    foreach ($skill in $expected) {
        if (@($records | Where-Object { $_.Name -ceq $skill.Name }).Count -eq 0) {
            $findings += "directory '$($skill.Name)', declared '<missing>', configured '$($skill.Name)'"
        }
    }
    if ($findings.Count) {
        return New-CheckResult -Name 'C2 Codex skill identity' -Status fail `
            -Detail ($findings -join ' | ')
    }
    return New-CheckResult -Name 'C2 Codex skill identity' -Status pass `
        -Detail "$($records.Count) generated SKILL.md identity record(s) match configuration."
}

function Get-CodexSkillMcpCheck {
    <# .SYNOPSIS Checks C3 active Codex MCP references against config and catalog. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Catalog
    )

    $map = Get-CodexMcpNamespaceMap -Servers @($Config.mcpServers)
    $byNamespace = [Collections.Generic.Dictionary[string, string]]::new(
        [StringComparer]::Ordinal)
    foreach ($name in $map.Keys) { $byNamespace[$map[$name]] = $name }
    $findings = @()
    foreach ($record in Get-CodexTextRecord -Config $Config) {
        foreach ($reference in Get-CodexMcpReference -Text $record.Text) {
            if (-not $byNamespace.ContainsKey($reference.Namespace)) {
                $findings += "$($record.File):$($reference.Line) $($reference.Reference): server absent from config"
                continue
            }
            $name = $byNamespace[$reference.Namespace]
            $server = @($Config.mcpServers | Where-Object { $_.name -ceq $name }) | Select-Object -First 1
            if ([string]$server.transport -notin @('http', 'stdio')) {
                $findings += "$($record.File):$($reference.Line) $($reference.Reference): legacy SSE is unsupported by Codex"
            }
            $entry = $Catalog.servers.PSObject.Properties[$name]
            if ($null -eq $entry) {
                $findings += "$($record.File):$($reference.Line) $($reference.Reference): server absent from catalog"
                continue
            }
            if ($reference.Tool -and $reference.Tool -ne '*' -and
                @($entry.Value.tools) -cnotcontains $reference.Tool) {
                $findings += "$($record.File):$($reference.Line) $($reference.Reference): tool absent from catalog"
            }
        }
    }
    if ($findings.Count) {
        return New-CheckResult -Name 'C3 Codex MCP references' -Status fail `
            -Detail ($findings -join ' | ')
    }
    return New-CheckResult -Name 'C3 Codex MCP references' -Status pass `
        -Detail 'All active Codex MCP references have compatible catalog entries.'
}

function Get-CodexResidueCheckRule {
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

function Test-CodexResidueException {
    param(
        [Parameter(Mandatory)][object]$Record,
        [Parameter(Mandatory)][string]$RuleId
    )

    if (-not $Record.Pack -or -not $Record.Skill -or
        $Record.Pack.PSObject.Properties.Name -notcontains 'codexScanExceptions') { return $false }
    foreach ($exception in @($Record.Pack.codexScanExceptions)) {
        if (@('skill', 'file', 'ruleId', 'justification') | Where-Object {
                $exception.PSObject.Properties.Name -notcontains $_
            }) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$exception.justification)) { continue }
        if ([string]$exception.skill -ceq [string]$Record.Skill.upstream -and
            [string]$exception.file -ceq $Record.RelativePath -and
            [string]$exception.ruleId -ceq $RuleId) { return $true }
    }
    return $false
}

function Get-CodexResidueCheck {
    <# .SYNOPSIS Checks C4 active generated text for Claude-only residue. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    $findings = @()
    $rules = @(Get-CodexResidueCheckRule)
    foreach ($record in Get-CodexTextRecord -Config $Config) {
        foreach ($finding in Test-SkillContent -Text $record.Text -Rules $rules -File $record.File) {
            if (Test-CodexResidueException -Record $record -RuleId $finding.RuleId) { continue }
            $findings += "$($finding.File) $($finding.RuleId) line $($finding.Line): $($finding.Text)"
        }
    }
    if ($findings.Count) {
        return New-CheckResult -Name 'C4 Codex residue' -Status fail -Detail ($findings -join ' | ')
    }
    return New-CheckResult -Name 'C4 Codex residue' -Status pass `
        -Detail 'No Claude-only residue appears in active generated Codex text.'
}

Export-ModuleMember -Function Get-CodexInstructionCheck, Get-CodexSkillSetCheck, `
    Get-CodexSkillIdentityCheck, Get-CodexSkillMcpCheck, Get-CodexResidueCheck
