Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ReAgent.CodexAdapter.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ReAgent.CodexWorkspace.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ReAgent.Skills.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ReAgent.Verify.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ReAgent.Agents.psm1') -Force

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

function ConvertFrom-CodexTomlString {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -notmatch '^"(?:[^"\\\x00-\x1F]|\\["\\bfnrt/]|\\u[0-9A-Fa-f]{4})*"$') {
        throw 'Expected one TOML basic string.'
    }
    try { return [string](ConvertFrom-Json -InputObject $Value -ErrorAction Stop) }
    catch { throw 'Malformed TOML basic string.' }
}

function ConvertFrom-CodexTomlArray {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value.Trim() -notmatch '^\[.*\]$') { throw 'Expected a TOML string array.' }
    try { $decoded = ConvertFrom-Json -InputObject $Value -ErrorAction Stop }
    catch { throw 'Malformed TOML string array.' }
    if ($null -eq $decoded) { throw 'TOML string array cannot be null.' }
    $items = if ($decoded -is [string]) { @($decoded) } else { @($decoded) }
    foreach ($item in $items) {
        if ($item -isnot [string]) { throw 'TOML array values must be strings.' }
    }
    return [string[]]$items
}

function Get-CodexTomlTableName {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value.StartsWith('"')) { return ConvertFrom-CodexTomlString -Value $Value }
    if ($Value -match "^'[^']+'$") { return $Value.Substring(1, $Value.Length - 2) }
    throw 'Malformed MCP server table name.'
}

function Add-CodexTomlField {
    param(
        [Parameter(Mandatory)][hashtable]$Seen,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Value
    )

    if ($Seen.ContainsKey($Name)) { throw "Duplicate TOML field '$Name'." }
    $Seen[$Name] = $Value
}

function Read-CodexAgentToml {
    <# .SYNOPSIS Reads the exact TOML subset emitted for Codex custom agents. #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseLiteralInitializerForHashtable', '')]
    param([Parameter(Mandatory)][string]$Path)

    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $lines = [regex]::Split($raw, "\r?\n")
    if ($lines.Count -eq 0 -or $lines[0] -cne '# re-agent-managed: codex-custom-agent v1') {
        throw "Custom agent '$Path' has no ownership marker."
    }
    $top = [Collections.Hashtable]::new([StringComparer]::Ordinal)
    $servers = [Collections.Hashtable]::new([StringComparer]::Ordinal)
    $current = $null
    $inEnvironment = $false
    for ($index = 1; $index -lt $lines.Count; $index++) {
        $line = $lines[$index].Trim()
        if (-not $line) { continue }
        $table = [regex]::Match($line,
            '^\[mcp_servers\.(?<name>"(?:[^"\\]|\\.)*"|''[^'']+'')(?<env>\.env)?\]$')
        if ($table.Success) {
            $name = Get-CodexTomlTableName -Value $table.Groups['name'].Value
            if (-not $servers.ContainsKey($name)) {
                $servers[$name] = [pscustomobject]@{ Name = $name; Seen = @{}; Env = @{} }
            } elseif (-not $table.Groups['env'].Success) { throw "Duplicate server table '$name'." }
            $current = $servers[$name]
            $inEnvironment = $table.Groups['env'].Success
            continue
        }
        $assignment = [regex]::Match($line,
            '^(?<key>"(?:[^"\\]|\\.)*"|[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?<value>.*)$')
        if (-not $assignment.Success) { throw "Unsupported TOML line $($index + 1)." }
        $key = $assignment.Groups['key'].Value
        $value = $assignment.Groups['value'].Value
        if ($inEnvironment) {
            if (-not $key.StartsWith('"')) { throw 'Environment keys must be TOML basic strings.' }
            Add-CodexTomlField -Seen $current.Env -Name (ConvertFrom-CodexTomlString $key) `
                -Value (ConvertFrom-CodexTomlString $value)
            continue
        }
        if ($current) {
            if ($key -notin @('enabled', 'enabled_tools', 'url', 'command', 'args', 'cwd')) {
                throw "Unknown MCP field '$key'."
            }
            $parsed = if ($key -eq 'enabled') {
                if ($value -notin @('true', 'false')) { throw 'enabled must be Boolean.' }
                [bool]::Parse($value)
            } elseif ($key -in @('enabled_tools', 'args')) {
                @(ConvertFrom-CodexTomlArray $value)
            } else { ConvertFrom-CodexTomlString $value }
            Add-CodexTomlField -Seen $current.Seen -Name $key -Value $parsed
            continue
        }
        if ($key -notin @('name', 'description', 'developer_instructions', 'sandbox_mode')) {
            throw "Unknown role field '$key'."
        }
        Add-CodexTomlField -Seen $top -Name $key -Value (ConvertFrom-CodexTomlString $value)
    }
    foreach ($field in @('name', 'description', 'developer_instructions', 'sandbox_mode')) {
        if (-not $top.ContainsKey($field)) { throw "Missing role field '$field'." }
    }
    $parsedServers = foreach ($server in $servers.Values) {
        foreach ($field in @('enabled', 'enabled_tools')) {
            if (-not $server.Seen.ContainsKey($field)) {
                throw "Server '$($server.Name)' is incomplete."
            }
        }
        $hasUrl = $server.Seen.ContainsKey('url')
        $hasCommand = $server.Seen.ContainsKey('command')
        if ($hasUrl -eq $hasCommand) { throw "Server '$($server.Name)' has invalid transport." }
        if ($hasUrl -and @(@('args', 'cwd') | Where-Object {
                    $server.Seen.ContainsKey($_) }).Count -gt 0) {
            throw "HTTP server '$($server.Name)' has stdio fields."
        }
        if ($hasUrl -and $server.Env.Count -gt 0) {
            throw "HTTP server '$($server.Name)' has environment values."
        }
        if ($hasCommand -and -not $server.Seen.ContainsKey('args')) {
            throw "Stdio server '$($server.Name)' has no args array."
        }
        [pscustomobject]@{ Name = $server.Name; Enabled = $server.Seen['enabled']
            EnabledTools = @($server.Seen['enabled_tools']); Url = $server.Seen['url']
            Command = $server.Seen['command']; Args = @($server.Seen['args'])
            Cwd = $server.Seen['cwd']; Env = $server.Env }
    }
    return [pscustomobject]@{ Path = $Path; RawText = $raw; Name = $top['name']
        Description = $top['description']; DeveloperInstructions = $top['developer_instructions']
        SandboxMode = $top['sandbox_mode']; Servers = @($parsedServers) }
}

function Get-CodexAgentPath {
    param([Parameter(Mandatory)][object]$Config, [Parameter(Mandatory)][string]$Name)

    return Join-Path $Config.paths.agentRoot ('.codex\agents\' + $Name + '.toml')
}

function Get-CodexMarkedAgentFile {
    param([Parameter(Mandatory)][object]$Config)

    $root = Join-Path $Config.paths.agentRoot '.codex\agents'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $root -File -Filter '*.toml' -Force | Where-Object {
            Test-ReAgentOwnershipMarker -Path $_.FullName `
                -Marker '# re-agent-managed: codex-custom-agent v1'
        })
}

function Get-CodexAgentIdentityCheck {
    <# .SYNOPSIS Checks C5 custom-agent identities and strict TOML shape. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    $findings = @()
    $enabled = @($Config.agents | Where-Object enabled)
    foreach ($agent in $enabled) {
        $path = Get-CodexAgentPath -Config $Config -Name $agent.name
        if (-not (Test-ReAgentOwnershipMarker -Path $path `
                -Marker '# re-agent-managed: codex-custom-agent v1')) {
            $findings += "Agent '$($agent.name)' is missing or unmanaged."
            continue
        }
        try { $parsed = Read-CodexAgentToml -Path $path }
        catch { $findings += "Agent '$($agent.name)' TOML is invalid."; continue }
        if ($parsed.Name -cne $agent.name) {
            $findings += "Agent file '$($agent.name)' declares '$($parsed.Name)'."
        }
    }
    foreach ($file in Get-CodexMarkedAgentFile -Config $Config) {
        $name = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        if (@($enabled | Where-Object { $_.name -ceq $name }).Count -eq 0) {
            $findings += "Marked agent '$name' is not enabled in config."
        }
    }
    if ($findings.Count) {
        return New-CheckResult -Name 'C5 Codex agent identity' -Status fail `
            -Detail ($findings -join ' | ')
    }
    return New-CheckResult -Name 'C5 Codex agent identity' -Status pass `
        -Detail "$($enabled.Count) custom agent(s) have valid identities."
}

function Get-CodexExpectedAgentTool {
    param([Parameter(Mandatory)][object]$Agent, [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][string]$Server)

    $prefix = 'mcp__' + $Server + '__'
    return @((Get-AgentToolGrant -Agent $Agent -Catalog $Catalog).Tools | Where-Object {
            $_.StartsWith($prefix, [StringComparison]::Ordinal)
        } | ForEach-Object { $_.Substring($prefix.Length) })
}

function Test-CodexExactNameSetEqual {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Left,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Right
    )

    if ($Left.Count -ne $Right.Count -or @($Left | Select-Object -Unique).Count -ne $Left.Count -or
        @($Right | Select-Object -Unique).Count -ne $Right.Count) { return $false }
    return Test-CodexNameSetEqual -Left $Left -Right $Right
}

function Get-CodexAgentGrantCheck {
    <# .SYNOPSIS Checks C6 exact per-agent MCP grants against the catalog. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config, [Parameter(Mandatory)][object]$Catalog)

    $findings = @()
    foreach ($agent in @($Config.agents | Where-Object enabled)) {
        $path = Get-CodexAgentPath -Config $Config -Name $agent.name
        try { $parsed = Read-CodexAgentToml -Path $path }
        catch { $findings += "Agent '$($agent.name)' cannot supply a grant."; continue }
        $expected = @()
        foreach ($target in @($agent.targetServers)) {
            $configured = @($Config.mcpServers | Where-Object { $_.name -ceq $target })[0]
            if ($configured -and $configured.transport -in @('http', 'stdio')) {
                $expected += $target
            }
        }
        $actual = @($parsed.Servers | Where-Object Enabled | ForEach-Object Name)
        if (-not (Test-CodexExactNameSetEqual -Left $expected -Right $actual)) {
            $findings += "Agent '$($agent.name)' enabled server grant differs."
        }
        foreach ($name in $expected) {
            $entry = $Catalog.servers.PSObject.Properties[$name]
            if ($null -eq $entry -or
                -not (Get-ToolClassification -Catalog $Catalog -Server $name).Known) {
                $findings += "Agent '$($agent.name)' target '$name' has a stale catalog."
                continue
            }
            foreach ($finding in @(Test-AgentClassificationCheck -Catalog $Catalog -Server $name)) {
                $findings += "Agent '$($agent.name)' target '$name': $($finding.Message)"
            }
            $server = $parsed.Servers | Where-Object { $_.Name -ceq $name } |
                Select-Object -First 1
            $wanted = Get-CodexExpectedAgentTool -Agent $agent -Catalog $Catalog -Server $name
            if (-not $server -or -not (Test-CodexExactNameSetEqual -Left $wanted `
                        -Right @($server.EnabledTools))) {
                $findings += "Agent '$($agent.name)' tool grant for '$name' differs."
            }
        }
    }
    if ($findings.Count) {
        return New-CheckResult -Name 'C6 Codex agent grant' -Status fail `
            -Detail ($findings -join ' | ')
    }
    return New-CheckResult -Name 'C6 Codex agent grant' -Status pass `
        -Detail 'Every enabled MCP server and tool grant is catalog-derived.'
}

function Test-CodexStringMapEqual {
    param([Parameter(Mandatory)][hashtable]$Left, [Parameter(Mandatory)][hashtable]$Right)

    if (-not (Test-CodexNameSetEqual -Left @($Left.Keys) -Right @($Right.Keys))) { return $false }
    foreach ($key in $Left.Keys) { if ($Left[$key] -cne $Right[$key]) { return $false } }
    return $true
}

function Test-CodexStringArrayEqual {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Left,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Right
    )

    if ($Left.Count -ne $Right.Count) { return $false }
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if ($Left[$index] -cne $Right[$index]) { return $false }
    }
    return $true
}

function Get-CodexSensitiveConfigValue {
    param([Parameter(Mandatory)][object]$Value, [int]$Depth = 0)

    if ($Depth -gt 8 -or $null -eq $Value) { return @() }
    if ($Value -is [string]) { return @() }
    $values = @()
    foreach ($property in @($Value.PSObject.Properties)) {
        if ($property.Name -match '(?i)(token|secret|password|authorization|api.?key)' -and
            $property.Value -is [string] -and $property.Value) { $values += $property.Value }
        if ($property.Value -isnot [string]) {
            foreach ($child in @($property.Value)) {
                $values += Get-CodexSensitiveConfigValue -Value $child -Depth ($Depth + 1)
            }
        }
    }
    return $values
}

function Test-CodexServerTransport {
    param([Parameter(Mandatory)][object]$Server, [Parameter(Mandatory)][object]$Result)

    if ($Result.Transport -eq 'http') {
        return $Server.Url -ceq "http://$($Result.Bind):$($Result.Port)$($Result.Path)"
    }
    if ($Result.Transport -ne 'stdio' -or -not $Result.Command) { return $false }
    if ($Server.Command -cne $Result.Command.Executable -or
        -not (Test-CodexStringArrayEqual -Left @($Server.Args) `
                -Right @($Result.Command.Arguments))) {
        return $false
    }
    $expectedCwd = if ($Result.Command.PSObject.Properties.Name -contains 'WorkingDirectory') {
        [string]$Result.Command.WorkingDirectory
    } else { $null }
    if ($Server.Cwd -cne $expectedCwd) { return $false }
    $expected = @{}
    if ($Result.Command.Env) {
        foreach ($key in $Result.Command.Env.Keys) { $expected[$key] = $Result.Command.Env[$key] }
    }
    return Test-CodexStringMapEqual -Left $expected -Right $Server.Env
}

function Get-CodexSecretIsolationCheck {
    <# .SYNOPSIS Checks C7 secret exclusion and transport provenance. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ServerResults
    )

    $findings = @()
    $secrets = @(Get-CodexSensitiveConfigValue -Value $Config | Select-Object -Unique)
    $expected = @($ServerResults | Where-Object {
            $_.Installed -and $_.Transport -in @('http', 'stdio')
        })
    foreach ($record in Get-CodexTextRecord -Config $Config) {
        if ($record.Text -match '(?i)authorization|bearer') {
            $findings += "$($record.File) contains secret-like raw text."
        }
        foreach ($secret in $secrets) {
            if ($secret -and $record.Text.IndexOf($secret, [StringComparison]::Ordinal) -ge 0) {
                $findings += "$($record.File) contains a configured secret value."
            }
        }
    }
    foreach ($file in Get-CodexMarkedAgentFile -Config $Config) {
        try { $parsed = Read-CodexAgentToml -Path $file.FullName }
        catch { $findings += "$($file.Name) cannot be verified."; continue }
        foreach ($value in @($parsed.Name, $parsed.Description, $parsed.DeveloperInstructions) +
            @($parsed.Servers | ForEach-Object {
                    @($_.Url, $_.Command, $_.Cwd) + $_.Args + $_.Env.Values
                })) {
            if ([string]$value -match '(?i)authorization|bearer') {
                $findings += "$($file.Name) has decoded secret-like text."
            }
            foreach ($secret in $secrets) {
                if ($secret -and ([string]$value).IndexOf($secret,
                        [StringComparison]::Ordinal) -ge 0) {
                    $findings += "$($file.Name) has a decoded configured secret value."
                }
            }
        }
        $actual = @($parsed.Servers | Where-Object {
                $_ -and $_.PSObject.Properties.Name -contains 'Name'
            } | ForEach-Object { $_.Name })
        $expectedNames = @($expected | ForEach-Object { $_.Name })
        if (-not (Test-CodexNameSetEqual -Left $expectedNames -Right $actual)) {
            $findings += "$($file.Name) has transport table drift."
        }
        foreach ($server in $parsed.Servers) {
            if (@($server.Env.Keys | Where-Object {
                        $_ -match '(?i)(token|secret|password|auth|key)'
                    }).Count) {
                $findings += "$($file.Name) has a sensitive environment name."
            }
            $result = @($expected | Where-Object { $_.Name -ceq $server.Name })[0]
            $configServer = @($Config.mcpServers | Where-Object { $_.name -ceq $server.Name })[0]
            if (-not $result -or -not $configServer -or
                -not (Test-CodexServerTransport -Server $server -Result $result)) {
                $findings += "$($file.Name) has transport provenance drift for '$($server.Name)'."
            } elseif ($server.Enabled -and $configServer.auth -ne 'none') {
                $findings += "$($file.Name) enables an authenticated target."
            }
        }
    }
    if ($findings.Count) {
        return New-CheckResult -Name 'C7 Codex secret isolation' -Status fail `
            -Detail ($findings -join ' | ')
    }
    return New-CheckResult -Name 'C7 Codex secret isolation' -Status pass `
        -Detail 'Custom-agent files contain only token-free deterministic transports.'
}

function Get-CodexCandidateByte {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $content = if ($Text.EndsWith("`n")) { $Text } else { $Text + "`r`n" }
    return [Text.UTF8Encoding]::new($false).GetBytes($content)
}

function Get-CodexOwnershipCheck {
    <# .SYNOPSIS Checks C8 deterministic bytes and reconciliation ownership. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ServerResults,
        [Parameter(Mandatory)][string]$TemplateRoot,
        [AllowEmptyCollection()][array]$ReconciliationRecords = @()
    )

    $findings = @()
    $candidates = @([pscustomobject]@{ Path = (Join-Path $Config.paths.agentRoot 'AGENTS.md')
            Marker = '<!-- re-agent-managed: codex-operating-contract v1 -->'
            Text = (New-ClientInstructionText -TemplateRoot $TemplateRoot -Client Codex) })
    foreach ($agent in @($Config.agents | Where-Object enabled)) {
        $path = Get-CodexAgentPath -Config $Config -Name $agent.name
        $toml = New-CodexAgentToml -Agent $agent -Catalog $Catalog -Config $Config `
            -ServerResults $ServerResults -TemplateRoot $TemplateRoot
        $candidates += [pscustomobject]@{ Path = $path
            Marker = '# re-agent-managed: codex-custom-agent v1'; Text = $toml }
    }
    foreach ($candidate in $candidates) {
        if (-not (Test-ReAgentOwnershipMarker -Path $candidate.Path -Marker $candidate.Marker)) {
            $findings += "Managed candidate '$($candidate.Path)' is missing or unmanaged."
        } elseif (-not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                [IO.File]::ReadAllBytes($candidate.Path),
                (Get-CodexCandidateByte -Text $candidate.Text))) {
            $findings += "Managed candidate '$($candidate.Path)' has a byte mismatch."
        }
    }
    $expectedNames = @($Config.agents | Where-Object enabled | ForEach-Object name)
    foreach ($file in Get-CodexMarkedAgentFile -Config $Config) {
        if ($expectedNames -cnotcontains [IO.Path]::GetFileNameWithoutExtension($file.Name)) {
            $findings += "Marked agent '$($file.Name)' has no managed candidate."
        }
    }
    foreach ($record in $ReconciliationRecords) {
        if ($record.PSObject.Properties.Name -contains 'Action' -and
            $record.Action -in @('update', 'remove') -and
            $record.PSObject.Properties.Name -contains 'OwnedBefore' -and
            -not $record.OwnedBefore) {
            $findings += "Reconciliation attempted an unowned $($record.Action)."
        }
    }
    if ($findings.Count) {
        return New-CheckResult -Name 'C8 Codex ownership' -Status fail `
            -Detail ($findings -join ' | ')
    }
    return New-CheckResult -Name 'C8 Codex ownership' -Status pass `
        -Detail 'Managed Codex candidates are byte-idempotent and ownership-safe.'
}

function Get-CodexWorkspaceCheck {
    <# .SYNOPSIS Returns deterministic Codex workspace checks C0 through C8 in order. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ServerResults,
        [Parameter(Mandatory)][string]$TemplateRoot,
        [AllowEmptyCollection()][array]$ReconciliationRecords = @()
    )

    return @(Get-CodexInstructionCheck -Config $Config -TemplateRoot $TemplateRoot
        Get-CodexSkillSetCheck -Config $Config
        Get-CodexSkillIdentityCheck -Config $Config
        Get-CodexSkillMcpCheck -Config $Config -Catalog $Catalog
        Get-CodexResidueCheck -Config $Config
        Get-CodexAgentIdentityCheck -Config $Config
        Get-CodexAgentGrantCheck -Config $Config -Catalog $Catalog
        Get-CodexSecretIsolationCheck -Config $Config -ServerResults $ServerResults
        Get-CodexOwnershipCheck -Config $Config -Catalog $Catalog -ServerResults $ServerResults `
            -TemplateRoot $TemplateRoot -ReconciliationRecords $ReconciliationRecords)
}

function New-CodexAcceptanceObservation {
    <# .SYNOPSIS Creates one attended Codex acceptance observation. #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][ValidateSet('L0', 'L1', 'L2', 'L3', 'L4', 'L5')][string]$Id,
        [Parameter(Mandatory)][ValidateSet('pass', 'fail')][string]$Status,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Evidence
    )

    return [pscustomobject][ordered]@{ Id = $Id; Status = $Status; Evidence = $Evidence
        ObservedAt = (Get-Date -Format 'o') }
}

function Assert-CodexAcceptanceObservationSet {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Observations)

    if ($Observations.Count -eq 0) { return }
    $expected = @('L0', 'L1', 'L2', 'L3', 'L4', 'L5')
    if ($Observations.Count -ne $expected.Count) {
        throw 'An attended acceptance record requires exactly one L0-L5 observation.'
    }
    $seen = @{}
    foreach ($observation in $Observations) {
        foreach ($field in @('Id', 'Status', 'Evidence', 'ObservedAt')) {
            if ($observation.PSObject.Properties.Name -notcontains $field) {
                throw "Acceptance observation is missing '$field'."
            }
        }
        if ($observation.Id -notin $expected) { throw "Unknown acceptance ID '$($observation.Id)'." }
        if ($seen.ContainsKey($observation.Id)) { throw "Duplicate acceptance ID '$($observation.Id)'." }
        if ($observation.Status -notin @('pass', 'fail')) {
            throw "Acceptance observation '$($observation.Id)' has an invalid status."
        }
        if ([string]::IsNullOrWhiteSpace([string]$observation.Evidence)) {
            throw "Acceptance observation '$($observation.Id)' requires evidence."
        }
        $seen[$observation.Id] = $true
    }
    foreach ($id in $expected) {
        if (-not $seen.ContainsKey($id)) { throw "Missing acceptance observation '$id'." }
    }
}

function Write-CodexVerificationReport {
    <# .SYNOPSIS Writes the standalone deterministic Codex verification report. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Checks,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Observations
    )

    Assert-CodexAcceptanceObservationSet -Observations $Observations
    $version = if ($Config.PSObject.Properties.Name -contains 'codexVersion') {
        [string]$Config.codexVersion
    } else { 'codex-cli 0.153.4' }
    $report = [ordered]@{ generatedAt = (Get-Date -Format 'o'); codexVersion = $version
        checks = @($Checks); attendedObservations = @($Observations) }
    $path = Join-Path $Config.paths.stateRoot 'codex-verify-report.json'
    $null = New-Item -ItemType Directory -Path $Config.paths.stateRoot -Force
    [IO.File]::WriteAllText($path, ($report | ConvertTo-Json -Depth 12),
        [Text.UTF8Encoding]::new($false))
    return $path
}

Export-ModuleMember -Function Get-CodexInstructionCheck, Get-CodexSkillSetCheck, `
    Get-CodexSkillIdentityCheck, Get-CodexSkillMcpCheck, Get-CodexResidueCheck, `
    Read-CodexAgentToml, Get-CodexAgentIdentityCheck, Get-CodexAgentGrantCheck, `
    Get-CodexSecretIsolationCheck, Get-CodexOwnershipCheck, Get-CodexWorkspaceCheck, `
    New-CodexAcceptanceObservation, Write-CodexVerificationReport
