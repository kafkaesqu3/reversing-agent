BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.CodexVerify.psm1" -Force

function Write-TestUtf8File {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)

    $parent = Split-Path -Parent $Path
    $null = New-Item -ItemType Directory -Path $parent -Force
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function New-CodexVerificationFixture {
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
