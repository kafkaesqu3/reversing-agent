BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.CodexVerify.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.CodexWorkspace.psm1" -Force

function Write-TestUtf8File {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)

    $parent = Split-Path -Parent $Path
    $null = New-Item -ItemType Directory -Path $parent -Force
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
function New-CodexVerificationFixture {
    # Test fixture: creates only isolated files beneath Pester TestDrive.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param()
    $root = Join-Path $TestDrive ('codex-verify-' + [guid]::NewGuid().ToString('N'))
    $templates = Join-Path $root 'templates'
    $config = [pscustomobject]@{
        paths = [pscustomobject]@{ agentRoot = $root }
        mcpServers = @(
            [pscustomobject]@{ name = 'pyghidra-mcp'; enabled = $true; transport = 'http' }
            [pscustomobject]@{ name = 'pdbsql'; enabled = $true; transport = 'sse' }
        )
        skills = @(
            [pscustomobject]@{
                namespace = 'fixture'; enabled = $true; targetServers = @('pyghidra-mcp')
                codexScanExceptions = @()
                skills = @([pscustomobject]@{ upstream = 'alpha'; name = 'alpha'; enabled = $true })
            }
        )
    }
    $catalog = [pscustomobject]@{ servers = [pscustomobject]@{
            'pyghidra-mcp' = [pscustomobject]@{ tools = @('read_binary') }
            pdbsql = [pscustomobject]@{ tools = @('get_schema') }
        } }

    Write-TestUtf8File -Path (Join-Path $templates 'instructions/common.md.template') -Text '# Common'
    Write-TestUtf8File -Path (Join-Path $templates 'instructions/codex.md.template') -Text 'Use Codex.'
    $agents = "<!-- re-agent-managed: codex-operating-contract v1 -->`n`n# Common`n`nUse Codex.`n"
    Write-TestUtf8File -Path (Join-Path $root 'AGENTS.md') -Text $agents

    $skill = "---`nname: alpha`ndescription: fixture`n---`nUse mcp__pyghidra_mcp__read_binary.`n"
    Write-TestUtf8File -Path (Join-Path $root '.claude/skills/alpha/SKILL.md') -Text $skill
    Write-TestUtf8File -Path (Join-Path $root '.claude/skills/alpha/.re-agent-managed') -Text 'fixture/alpha'
    Write-TestUtf8File -Path (Join-Path $root '.agents/skills/alpha/SKILL.md') -Text $skill
    Write-TestUtf8File -Path (Join-Path $root '.agents/skills/alpha/.re-agent-managed') -Text 'codex:fixture/alpha'
    Write-TestUtf8File -Path (Join-Path $root '.agents/skills/alpha/references/guide.md') -Text 'Generated guide.'
    return [pscustomobject]@{ Root = $root; Config = $config; Catalog = $catalog; Templates = $templates }
}

function Add-TestText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)

    $current = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    Write-TestUtf8File -Path $Path -Text ($current + $Text)
}

function New-CodexAgentVerificationFixture {
    # Test fixture: extends an isolated fixture with generated agent files.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param()
    $fixture = New-CodexVerificationFixture
    $fixture.Config.paths | Add-Member -NotePropertyName stateRoot -NotePropertyValue $fixture.Root
    $fixture.Config.mcpServers = @(
        [pscustomobject]@{ name = 'pyghidra-mcp'; enabled = $true
            transport = 'http'; auth = 'none' }
        [pscustomobject]@{ name = 'mcp-windbg'; enabled = $true
            transport = 'stdio'; auth = 'none' }
        [pscustomobject]@{ name = 'x64dbg-x64'; enabled = $true; transport = 'http'; auth = 'none' }
    )
    $fixture.Config | Add-Member -NotePropertyName agents -NotePropertyValue @(
        [pscustomobject]@{ name = 'static-analyst'; enabled = $true; level = 'write'
            targetServers = @('pyghidra-mcp'); builtinTools = @('Read') }
        [pscustomobject]@{ name = 'verifier'; enabled = $true; level = 'read'
            targetServers = @('pyghidra-mcp', 'mcp-windbg'); builtinTools = @('Read') }
    )
    $fixture.Catalog.servers | Add-Member -NotePropertyName 'mcp-windbg' -NotePropertyValue (
        [pscustomobject]@{ tools = @('list_dumps', 'write_memory')
            classification = [pscustomobject]@{
                classifiedTools = @('list_dumps', 'write_memory')
                write = @('write_memory'); destructive = @()
            } })
    $fixture.Catalog.servers.'pyghidra-mcp' = [pscustomobject]@{
        tools = @('read_binary', 'rename_function', 'delete_binary')
        classification = [pscustomobject]@{
            classifiedTools = @('read_binary', 'rename_function', 'delete_binary')
            write = @('rename_function'); destructive = @('delete_binary')
        }
    }
    $agentTemplates = Join-Path $fixture.Templates 'agents'
    $unicode = 'caf' + [char]0x00e9
    Write-TestUtf8File -Path (Join-Path $agentTemplates 'static-analyst.md.template') -Text (
        "---`nname: static-analyst`ndescription: Static 'analysis'`n---`n" +
        "Use C:\tools\agent.exe, $unicode, a quote `" and `"`"`".`nLine two." +
        '{{SERVERS}}{{LIMITATIONS}}{{CLIENT_LIMITATIONS}}')
    Write-TestUtf8File -Path (Join-Path $agentTemplates 'verifier.md.template') -Text (
        "---`nname: verifier`ndescription: Verifier`n---`nVerify independently." +
        '{{SERVERS}}{{LIMITATIONS}}{{CLIENT_LIMITATIONS}}')
    $command = [pscustomobject]@{ Executable = 'C:\tools\windbg.exe'
        Arguments = @('--mcp', "O'Hara"); Env = @{} }
    $serverResults = @(
        [pscustomobject]@{ Name = 'pyghidra-mcp'; Installed = $true; Transport = 'http'
            Bind = '127.0.0.1'; Port = 9103; Path = '/mcp'; Auth = 'none' }
        [pscustomobject]@{ Name = 'mcp-windbg'; Installed = $true; Transport = 'stdio'
            Command = $command; Auth = 'none' }
        [pscustomobject]@{ Name = 'x64dbg-x64'; Installed = $true; Transport = 'http'
            Bind = '127.0.0.1'; Port = 9100; Path = '/mcp'; Auth = 'none' }
    )
    $null = Write-CodexAgentDefinition -Config $fixture.Config -Catalog $fixture.Catalog `
        -ServerResults $serverResults -TemplateRoot $fixture.Templates
    $fixture | Add-Member -NotePropertyName ServerResults -NotePropertyValue $serverResults
    return $fixture
}
}

Describe 'Codex workspace verification C0-C4' {
    It 'passes every deterministic check for a complete marked workspace' {
        $fixture = New-CodexVerificationFixture
        $checks = @(
            Get-CodexInstructionCheck -Config $fixture.Config -TemplateRoot $fixture.Templates
            Get-CodexSkillSetCheck -Config $fixture.Config
            Get-CodexSkillIdentityCheck -Config $fixture.Config
            Get-CodexSkillMcpCheck -Config $fixture.Config -Catalog $fixture.Catalog
            Get-CodexResidueCheck -Config $fixture.Config
        )

        $checks.Status | Should -Be @('pass', 'pass', 'pass', 'pass', 'pass')
        $checks[0].Name | Should -Match '^C0'
        $checks[1].Name | Should -Match '^C1'
        $checks[2].Name | Should -Match '^C2'
        $checks[3].Name | Should -Match '^C3'
        $checks[4].Name | Should -Match '^C4'
    }

    It 'C0 reports an unmanaged instruction file when its marker is removed' {
        $fixture = New-CodexVerificationFixture
        Write-TestUtf8File -Path (Join-Path $fixture.Root 'AGENTS.md') -Text 'operator owned'

        $check = Get-CodexInstructionCheck -Config $fixture.Config -TemplateRoot $fixture.Templates

        $check.Name | Should -Match '^C0'
        $check.Status | Should -Be 'fail'
        $check.Detail | Should -Match 'AGENTS\.md.*unmanaged'
    }

    It 'C0 reports an instruction byte mismatch after managed text drifts' {
        $fixture = New-CodexVerificationFixture
        Add-TestText -Path (Join-Path $fixture.Root 'AGENTS.md') -Text 'drift'

        $check = Get-CodexInstructionCheck -Config $fixture.Config -TemplateRoot $fixture.Templates

        $check.Name | Should -Match '^C0'
        $check.Status | Should -Be 'fail'
        $check.Detail | Should -Match 'AGENTS\.md.*byte mismatch'
    }

    It 'C1 reports sorted configured Claude and Codex sets when an enabled Codex skill is absent' {
        $fixture = New-CodexVerificationFixture
        Remove-Item -LiteralPath (Join-Path $fixture.Root '.agents/skills/alpha') -Recurse -Force

        $check = Get-CodexSkillSetCheck -Config $fixture.Config

        $check.Name | Should -Match '^C1'
        $check.Status | Should -Be 'fail'
        $check.Detail | Should -Match 'expected.*alpha.*Claude.*alpha.*Codex.*\[\]'
    }

    It 'C1 reports sorted configured Claude and Codex sets when an extra marked Codex skill exists' {
        $fixture = New-CodexVerificationFixture
        Write-TestUtf8File -Path (Join-Path $fixture.Root '.agents/skills/beta/SKILL.md') -Text (
            "---`nname: beta`n---`nGenerated.`n")
        Write-TestUtf8File -Path (Join-Path $fixture.Root '.agents/skills/beta/.re-agent-managed') -Text 'codex:fixture/beta'

        $check = Get-CodexSkillSetCheck -Config $fixture.Config

        $check.Name | Should -Match '^C1'
        $check.Status | Should -Be 'fail'
        $check.Detail | Should -Match 'expected.*alpha.*Claude.*alpha.*Codex.*alpha, beta'
    }

    It 'C1 treats a case-only configured skill-name drift as a mismatch' {
        $fixture = New-CodexVerificationFixture
        $fixture.Config.skills[0].skills[0].name = 'Alpha'

        $check = Get-CodexSkillSetCheck -Config $fixture.Config

        $check.Name | Should -Match '^C1'
        $check.Status | Should -Be 'fail'
        $check.Detail | Should -Match 'expected \[Alpha\].*Claude \[alpha\].*Codex \[alpha\]'
    }

    It 'C2 reports the directory declared and configured identities when frontmatter drifts' {
        $fixture = New-CodexVerificationFixture
        Write-TestUtf8File -Path (Join-Path $fixture.Root '.agents/skills/alpha/SKILL.md') -Text (
            "---`nname: renamed`n---`nGenerated.`n")

        $check = Get-CodexSkillIdentityCheck -Config $fixture.Config

        $check.Name | Should -Match '^C2'
        $check.Status | Should -Be 'fail'
        $check.Detail | Should -Match 'directory.*alpha.*declared.*renamed.*configured.*alpha'
    }

    It 'C3 reports legacy SSE references as unsupported by Codex' {
        $fixture = New-CodexVerificationFixture
        Add-TestText -Path (Join-Path $fixture.Root '.agents/skills/alpha/references/guide.md') -Text (
            "`nmcp__pdbsql__get_schema`n")

        $check = Get-CodexSkillMcpCheck -Config $fixture.Config -Catalog $fixture.Catalog

        $check.Name | Should -Match '^C3'
        $check.Status | Should -Be 'fail'
        $check.Detail | Should -Match 'legacy SSE is unsupported by Codex'
    }

    It 'C3 reports a referenced tool absent from the catalog' {
        $fixture = New-CodexVerificationFixture
        Add-TestText -Path (Join-Path $fixture.Root '.agents/skills/alpha/references/guide.md') -Text (
            "`nmcp__pyghidra_mcp__not_catalogued`n")

        $check = Get-CodexSkillMcpCheck -Config $fixture.Config -Catalog $fixture.Catalog

        $check.Name | Should -Match '^C3'
        $check.Status | Should -Be 'fail'
        $check.Detail | Should -Match 'tool absent from catalog'
    }

    It 'C3 rejects a wrong-cased MCP <Part>' -ForEach @(
        @{ Part = 'namespace'; Reference = 'mcp__Pyghidra_mcp__read_binary'; Detail = 'server absent from config' }
        @{ Part = 'tool'; Reference = 'mcp__pyghidra_mcp__Read_Binary'; Detail = 'tool absent from catalog' }
    ) {
        $fixture = New-CodexVerificationFixture
        Add-TestText -Path (Join-Path $fixture.Root '.agents/skills/alpha/references/guide.md') -Text (
            "`n$Reference`n")

        $check = Get-CodexSkillMcpCheck -Config $fixture.Config -Catalog $fixture.Catalog

        $check.Name | Should -Match '^C3'
        $check.Status | Should -Be 'fail'
        $check.Detail | Should -Match $Detail
    }

    It 'C3 accumulates transport and absent-tool findings for one legacy SSE reference' {
        $fixture = New-CodexVerificationFixture
        Add-TestText -Path (Join-Path $fixture.Root '.agents/skills/alpha/references/guide.md') -Text (
            "`nmcp__pdbsql__not_catalogued`n")

        $check = Get-CodexSkillMcpCheck -Config $fixture.Config -Catalog $fixture.Catalog

        $check.Name | Should -Match '^C3'
        $check.Status | Should -Be 'fail'
        $check.Detail | Should -Match 'legacy SSE is unsupported by Codex'
        $check.Detail | Should -Match 'tool absent from catalog'
    }

    It 'C4 reports <RuleId> with a file and one-based line number' -ForEach @(
        @{ RuleId = 'C4-CLAUDE-SKILL-PATH'; Text = '.claude/skills' }
        @{ RuleId = 'C4-CLAUDE-AGENT-PATH'; Text = '.claude/agents' }
        @{ RuleId = 'C4-CLAUDE-PRECEDENCE'; Text = 'CLAUDE.md wins' }
        @{ RuleId = 'C4-TODOWRITE'; Text = 'TodoWrite' }
        @{ RuleId = 'C4-TASK-TOOL'; Text = 'Task tool' }
        @{ RuleId = 'C4-AGENT-TOOL'; Text = 'Agent tool' }
        @{ RuleId = 'C4-SKILL-TOOL'; Text = 'Skill tool' }
        @{ RuleId = 'C4-HYPHENATED-MCP'; Text = 'mcp__server-with-hyphen__tool' }
    ) {
        $fixture = New-CodexVerificationFixture
        Add-TestText -Path (Join-Path $fixture.Root 'AGENTS.md') -Text ("`n$Text`n")

        $check = Get-CodexResidueCheck -Config $fixture.Config

        $check.Name | Should -Match '^C4'
        $check.Status | Should -Be 'fail'
        $check.Detail | Should -Match ('AGENTS\.md.*' + $RuleId + '.*line [0-9]+')
    }

    It 'C4 waives only an exact skill file and rule identity' -ForEach @(
        @{ Case = 'exact match'; Skill = 'alpha'; File = 'SKILL.md'; RuleId = 'C4-TODOWRITE'; Expected = 'pass' }
        @{ Case = 'different skill'; Skill = 'other'; File = 'SKILL.md'; RuleId = 'C4-TODOWRITE'; Expected = 'fail' }
        @{ Case = 'different file'; Skill = 'alpha'; File = 'references/guide.md'; RuleId = 'C4-TODOWRITE'; Expected = 'fail' }
        @{ Case = 'different rule'; Skill = 'alpha'; File = 'SKILL.md'; RuleId = 'C4-TASK-TOOL'; Expected = 'fail' }
    ) {
        $fixture = New-CodexVerificationFixture
        Add-TestText -Path (Join-Path $fixture.Root '.agents/skills/alpha/SKILL.md') -Text "TodoWrite`n"
        $fixture.Config.skills[0].codexScanExceptions = @([pscustomobject]@{
                skill = $Skill; file = $File; ruleId = $RuleId; justification = 'quoted history'
            })

        $check = Get-CodexResidueCheck -Config $fixture.Config

        $check.Name | Should -Match '^C4'
        $check.Status | Should -Be $Expected
        if ($Expected -eq 'fail') { $check.Detail | Should -Match 'C4-TODOWRITE' }
    }
}

Describe 'Codex custom-agent verification C5-C8' {
    It 'reads generator-subset TOML with escaped strings, paths, Unicode and arrays' {
        $fixture = New-CodexAgentVerificationFixture
        $path = Join-Path $fixture.Root '.codex/agents/static-analyst.toml'

        $parsed = Read-CodexAgentToml -Path $path

        $parsed.Name | Should -BeExactly 'static-analyst'
        $parsed.Description | Should -BeExactly "Static 'analysis'"
        $parsed.DeveloperInstructions | Should -Match 'C:\\tools\\agent\.exe'
        $parsed.DeveloperInstructions | Should -Match ('caf' + [char]0x00e9)
        $parsed.DeveloperInstructions | Should -Match 'Line two'
        $parsed.DeveloperInstructions | Should -Match '"""'
        @($parsed.Servers | Where-Object Name -eq 'mcp-windbg')[0].Args |
            Should -Be @('--mcp', "O'Hara")
    }

    It 'rejects malformed generator-subset TOML: <Case>' -ForEach @(
        @{ Case = 'missing scalar'; Text = '# re-agent-managed: codex-custom-agent v1' +
            "`nname = `"x`"" },
        @{ Case = 'duplicate field'; Text = '# re-agent-managed: codex-custom-agent v1' +
            "`nname = `"x`"`nname = `"y`"" },
        @{ Case = 'unknown field'; Text = '# re-agent-managed: codex-custom-agent v1' +
            "`nname = `"x`"`nunknown = `"y`"" },
        @{ Case = 'malformed string'; Text = '# re-agent-managed: codex-custom-agent v1' +
            "`nname = `"unterminated" },
        @{ Case = 'malformed array'; Text = '# re-agent-managed: codex-custom-agent v1' +
            "`nname = [`"x`"]" }
    ) {
        $path = Join-Path $TestDrive ($Case + '.toml')
        Write-TestUtf8File -Path $path -Text $Text

        { Read-CodexAgentToml -Path $path } | Should -Throw
    }

    It 'rejects scalar and null values for generator string-array fields: <Value>' -ForEach @(
        @{ Value = '"read_binary"' }, @{ Value = 'null' }
    ) {
        $fixture = New-CodexAgentVerificationFixture
        $path = Join-Path $fixture.Root '.codex/agents/static-analyst.toml'
        $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        $text = [regex]::Replace($text,
            '(?m)^enabled_tools = .+$', ('enabled_tools = ' + $Value))
        Write-TestUtf8File -Path $path -Text $text

        { Read-CodexAgentToml -Path $path } | Should -Throw
    }

    It 'C5 rejects an agent whose parsed name disagrees with its file and config name' {
        $fixture = New-CodexAgentVerificationFixture
        $path = Join-Path $fixture.Root '.codex/agents/verifier.toml'
        $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8).Replace(
            'name = "verifier"', 'name = "renamed"')
        Write-TestUtf8File -Path $path -Text $text

        $check = Get-CodexAgentIdentityCheck -Config $fixture.Config

        $check.Status | Should -Be 'fail'
        $check.Detail | Should -Match 'renamed'
    }

    It 'C5 rejects a custom agent with an incomplete transport table' {
        $fixture = New-CodexAgentVerificationFixture
        $path = Join-Path $fixture.Root '.codex/agents/static-analyst.toml'
        $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) `
            -replace '(?m)^url = .+\r?\n', ''
        Write-TestUtf8File -Path $path -Text $text

        (Get-CodexAgentIdentityCheck -Config $fixture.Config).Status | Should -Be 'fail'
    }

    It 'C6 rejects unintended enabled servers and verifier write or destructive grants' -ForEach @(
        @{ Case = 'unintended server'; Name = 'static-analyst'; Find = 'x64dbg-x64'
            Tools = $null },
        @{ Case = 'write tool'; Name = 'verifier'; Find = 'pyghidra-mcp'
            Tools = '["read_binary","rename_function"]' },
        @{ Case = 'destructive tool'; Name = 'verifier'; Find = 'pyghidra-mcp'
            Tools = '["read_binary","delete_binary"]' }
    ) {
        $fixture = New-CodexAgentVerificationFixture
        $path = Join-Path $fixture.Root ('.codex/agents/' + $Name + '.toml')
        $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        if ($null -eq $Tools) {
            $text = [regex]::Replace($text, '(?ms)(\[mcp_servers\."' +
                [regex]::Escape($Find) + '"\]\r?\n)enabled = false', '$1enabled = true')
        } else {
            $text = [regex]::Replace($text, '(?ms)(\[mcp_servers\."' +
                [regex]::Escape($Find) + '"\][\s\S]*?enabled_tools = )\[[^\]]*\]', '$1' + $Tools)
        }
        Write-TestUtf8File -Path $path -Text $text

        $check = Get-CodexAgentGrantCheck -Config $fixture.Config -Catalog $fixture.Catalog

        $check.Status | Should -Be 'fail'
        $check.Detail | Should -Match 'grant|enabled'
    }

    It 'C6 rejects a newly cataloged tool whose classification is incomplete' {
        $fixture = New-CodexAgentVerificationFixture
        $fixture.Catalog.servers.'pyghidra-mcp'.tools += 'newly_cataloged'
        foreach ($name in @('static-analyst', 'verifier')) {
            $path = Join-Path $fixture.Root ('.codex/agents/' + $name + '.toml')
            $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
            $oldGrant = if ($name -eq 'static-analyst') {
                'enabled_tools = ["read_binary","rename_function"]'
            } else { 'enabled_tools = ["read_binary"]' }
            $newGrant = $oldGrant.Replace(']', ',"newly_cataloged"]')
            $text = $text.Replace($oldGrant, $newGrant)
            Write-TestUtf8File -Path $path -Text $text
        }

        $check = Get-CodexAgentGrantCheck -Config $fixture.Config -Catalog $fixture.Catalog

        $check.Status | Should -Be 'fail'
        $check.Detail | Should -Match 'captured but unclassified|classification'
    }

    It 'C7 rejects literal secret leakage, sensitive environment keys and transport drift' `
        -ForEach @(
        @{ Case = 'Bearer text'; Edit = 'developer_instructions = "Bearer leaked"' },
        @{ Case = 'configured token'; Edit = '# fixture-token' },
        @{ Case = 'sensitive environment key'; Edit = '[mcp_servers."mcp-windbg".env]' +
            "`n`"API_TOKEN`" = `"value`"" },
        @{ Case = 'transport drift'; Edit = 'url = "http://127.0.0.1:1/mcp"' }
    ) {
        $fixture = New-CodexAgentVerificationFixture
        $fixture.Config | Add-Member -NotePropertyName token -NotePropertyValue 'fixture-token'
        $path = Join-Path $fixture.Root '.codex/agents/verifier.toml'
        Add-TestText -Path $path -Text ("`n" + $Edit + "`n")

        $check = Get-CodexSecretIsolationCheck -Config $fixture.Config `
            -ServerResults $fixture.ServerResults

        $check.Status | Should -Be 'fail'
        $check.Detail | Should -Not -Match 'fixture-token|leaked'
    }

    It 'C7 rejects configured tokens inside decoded TOML text: <Encoded>' -ForEach @(
        @{ Encoded = 'fixture\u002dtoken' },
        @{ Encoded = 'prefix fixture\u002dtoken suffix' }
    ) {
        $fixture = New-CodexAgentVerificationFixture
        $fixture.Config | Add-Member -NotePropertyName token -NotePropertyValue 'fixture-token'
        $path = Join-Path $fixture.Root '.codex/agents/verifier.toml'
        $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        $text = [regex]::Replace($text, '(?m)^developer_instructions = .+$',
            ('developer_instructions = "' + $Encoded + '"'))
        Write-TestUtf8File -Path $path -Text $text

        $check = Get-CodexSecretIsolationCheck -Config $fixture.Config `
            -ServerResults $fixture.ServerResults

        $check.Status | Should -Be 'fail'
        $check.Detail | Should -Not -Match 'fixture-token'
    }

    It 'C8 rejects changed marked bytes and unowned reconciliation actions' {
        $fixture = New-CodexAgentVerificationFixture
        Add-TestText -Path (Join-Path $fixture.Root '.codex/agents/verifier.toml') `
            -Text "`n# drift`n"

        $check = Get-CodexOwnershipCheck -Config $fixture.Config -Catalog $fixture.Catalog `
            -ServerResults $fixture.ServerResults -TemplateRoot $fixture.Templates `
            -ReconciliationRecords @(
                [pscustomobject]@{ Action = 'update'; Path = 'operator-file'
                    OwnedBefore = $false })

        $check.Status | Should -Be 'fail'
        $check.Detail | Should -Match 'byte mismatch|unowned'
    }

    It 'C8 ignores an unmarked sibling instead of treating it as a managed artifact' {
        $fixture = New-CodexAgentVerificationFixture
        Write-TestUtf8File -Path (Join-Path $fixture.Root '.codex/agents/operator.toml') `
            -Text 'operator owned'

        (Get-CodexOwnershipCheck -Config $fixture.Config -Catalog $fixture.Catalog `
            -ServerResults $fixture.ServerResults -TemplateRoot $fixture.Templates).Status |
            Should -Be 'pass'
    }

    It 'C8 permits a recorded creation while still rejecting unowned updates' {
        $fixture = New-CodexAgentVerificationFixture
        $check = Get-CodexOwnershipCheck -Config $fixture.Config -Catalog $fixture.Catalog `
            -ServerResults $fixture.ServerResults -TemplateRoot $fixture.Templates `
            -ReconciliationRecords @(
                [pscustomobject]@{ Action = 'create'; Path = 'new-skill'
                    OwnedBefore = $false; Changed = $true })

        $check.Status | Should -Be 'pass'
    }

    It 'composes ordered C0-C8 checks and serializes the standalone Codex report' {
        $fixture = New-CodexAgentVerificationFixture
        $checks = @(Get-CodexWorkspaceCheck -Config $fixture.Config -Catalog $fixture.Catalog `
            -ServerResults $fixture.ServerResults -TemplateRoot $fixture.Templates)
        $path = Write-CodexVerificationReport -Config $fixture.Config -Checks $checks `
            -Observations @()
        $report = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json

        $checks.Status | Should -Be @('pass', 'pass', 'pass', 'pass', 'pass', 'pass',
            'pass', 'pass', 'pass')
        $checks.Name | Should -Be @('C0 Codex instructions', 'C1 Codex skill set',
            'C2 Codex skill identity', 'C3 Codex MCP references', 'C4 Codex residue',
            'C5 Codex agent identity', 'C6 Codex agent grant', 'C7 Codex secret isolation',
            'C8 Codex ownership')
        $report.codexVersion | Should -BeExactly 'codex-cli 0.153.4'
        @($report.attendedObservations).Count | Should -Be 0
    }
}

Describe 'Codex attended acceptance observations' {
    It 'creates a timestamped L0 observation with its supplied evidence' {
        $observation = New-CodexAcceptanceObservation -Id L0 -Status pass `
            -Evidence 'Codex reported AGENTS.md as the instruction source.'

        $observation.Id | Should -BeExactly 'L0'
        $observation.Status | Should -BeExactly 'pass'
        $observation.Evidence | Should -BeExactly 'Codex reported AGENTS.md as the instruction source.'
        $observation.ObservedAt | Should -Not -BeNullOrEmpty
    }

    It 'rejects an unknown observation ID, status, or empty evidence' -ForEach @(
        @{ Id = 'L6'; Status = 'pass'; Evidence = 'unexpected ID' }
        @{ Id = 'L0'; Status = 'not-testable'; Evidence = 'unexpected status' }
        @{ Id = 'L0'; Status = 'pass'; Evidence = '' }
    ) {
        { New-CodexAcceptanceObservation -Id $Id -Status $Status -Evidence $Evidence } |
            Should -Throw
    }

    It 'requires exactly one evidenced observation for every L0-L5 ID in an attended report' {
        $fixture = New-CodexAgentVerificationFixture
        $checks = @(Get-CodexWorkspaceCheck -Config $fixture.Config -Catalog $fixture.Catalog `
            -ServerResults $fixture.ServerResults -TemplateRoot $fixture.Templates)
        $observations = @(
            New-CodexAcceptanceObservation -Id L0 -Status pass -Evidence 'instructions'
            New-CodexAcceptanceObservation -Id L1 -Status pass -Evidence 'skills'
            New-CodexAcceptanceObservation -Id L2 -Status pass -Evidence 'agents'
            New-CodexAcceptanceObservation -Id L3 -Status pass -Evidence 'boundary'
            New-CodexAcceptanceObservation -Id L4 -Status pass -Evidence 'read-only call'
            New-CodexAcceptanceObservation -Id L5 -Status pass -Evidence 'x32dbg closed'
        )

        $path = Write-CodexVerificationReport -Config $fixture.Config -Checks $checks `
            -Observations $observations
        $report = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json

        @($report.attendedObservations).Id | Should -Be @('L0', 'L1', 'L2', 'L3', 'L4', 'L5')
    }

    It 'rejects duplicate, incomplete, or evidence-free passing attended observations' -ForEach @(
        @{ Case = 'duplicate'; Observations = @(
                @{ Id = 'L0'; Status = 'pass'; Evidence = 'first' },
                @{ Id = 'L0'; Status = 'fail'; Evidence = 'second' }) }
        @{ Case = 'missing ID'; Observations = @(
                @{ Id = 'L0'; Status = 'pass'; Evidence = 'instructions' }) }
        @{ Case = 'empty passing evidence'; Observations = @(
                @{ Id = 'L0'; Status = 'pass'; Evidence = '' },
                @{ Id = 'L1'; Status = 'pass'; Evidence = 'skills' },
                @{ Id = 'L2'; Status = 'pass'; Evidence = 'agents' },
                @{ Id = 'L3'; Status = 'pass'; Evidence = 'boundary' },
                @{ Id = 'L4'; Status = 'pass'; Evidence = 'read-only call' },
                @{ Id = 'L5'; Status = 'pass'; Evidence = 'x32dbg closed' }) }
    ) {
        $fixture = New-CodexAgentVerificationFixture
        $observations = @($Observations | ForEach-Object { [pscustomobject]$_ })

        { Write-CodexVerificationReport -Config $fixture.Config -Checks @() `
                -Observations $observations } | Should -Throw
    }
}
