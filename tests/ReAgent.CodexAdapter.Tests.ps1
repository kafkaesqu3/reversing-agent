BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.CodexAdapter.psm1" -Force
}

Describe 'ConvertTo-CodexMcpNamespace' {
    It 'normalizes <ServerName> to <Expected>' -ForEach @(
        @{ ServerName = 'pyghidra-mcp'; Expected = 'pyghidra_mcp' }
        @{ ServerName = 'MCP-WinDBG'; Expected = 'mcp_windbg' }
        @{ ServerName = 'x64dbg---x32'; Expected = 'x64dbg_x32' }
        @{ ServerName = 'already_ok'; Expected = 'already_ok' }
    ) {
        ConvertTo-CodexMcpNamespace -Name $ServerName | Should -BeExactly $Expected
    }

    It 'rejects two configured names that normalize to one namespace' {
        { Get-CodexMcpNamespaceMap -Servers @(
                [pscustomobject]@{ name = 'a-b' },
                [pscustomobject]@{ name = 'a_b' }) } | Should -Throw '*collision*'
    }
}

Describe 'ConvertTo-CodexMcpReference' {
    BeforeAll {
        $Script:NamespaceMap = @{ 'mcp-windbg' = 'mcp_windbg' }
        $Script:Catalog = [pscustomobject]@{ servers = [pscustomobject]@{
                'mcp-windbg' = [pscustomobject]@{ tools = @('list_dumps') } } }
    }

    It 'rewrites only an exact structured reference' {
        $text = 'Call mcp__mcp-windbg__list_dumps; prose mcp-windbg stays.'
        $params = @{
            Text = $text
            NamespaceMap = $Script:NamespaceMap
            Catalog = $Script:Catalog
            CompatibleServers = @('mcp-windbg')
        }
        ConvertTo-CodexMcpReference @params |
            Should -BeExactly 'Call mcp__mcp_windbg__list_dumps; prose mcp-windbg stays.'
    }

    It 'rejects an incompatible server reference' {
        $map = @{ pdbsql = 'pdbsql' }
        $catalog = [pscustomobject]@{ servers = [pscustomobject]@{
                pdbsql = [pscustomobject]@{ tools = @('query') } } }
        { ConvertTo-CodexMcpReference -Text 'mcp__pdbsql__query' `
                -NamespaceMap $map -Catalog $catalog -CompatibleServers @() } |
            Should -Throw '*pdbsql*unsupported*'
    }

    It 'rejects an unknown server reference' {
        { ConvertTo-CodexMcpReference -Text 'mcp__missing__query' `
                -NamespaceMap $Script:NamespaceMap -Catalog $Script:Catalog `
                -CompatibleServers @('mcp-windbg') } | Should -Throw '*missing*unknown*'
    }

    It 'rejects an unknown tool reference' {
        { ConvertTo-CodexMcpReference -Text 'mcp__mcp-windbg__missing' `
                -NamespaceMap $Script:NamespaceMap -Catalog $Script:Catalog `
            -CompatibleServers @('mcp-windbg') } | Should -Throw '*missing*unknown*'
    }

    It 'validates and rewrites a structured reference with a hyphenated tool name' {
        $catalog = [pscustomobject]@{ servers = [pscustomobject]@{
                'mcp-windbg' = [pscustomobject]@{ tools = @('read-memory') } } }
        ConvertTo-CodexMcpReference -Text 'mcp__mcp-windbg__read-memory' `
            -NamespaceMap $Script:NamespaceMap -Catalog $catalog `
            -CompatibleServers @('mcp-windbg') |
            Should -BeExactly 'mcp__mcp_windbg__read-memory'
    }
}

Describe 'ConvertTo-CodexFrontmatter' {
    It 'removes allowed-tools and its list while retaining descriptive metadata' {
        $text = @"
---
name: crash-analysis
description: Analyze a crash
allowed-tools:
  - Read
  - mcp__mcp-windbg__list_dumps
license: MIT
keywords:
  - crash
custom: stable
---
Body
"@
        $expected = @"
---
name: crash-analysis
description: Analyze a crash
license: MIT
keywords:
  - crash
custom: stable
---
Body
"@
        ConvertTo-CodexFrontmatter -Text $text | Should -BeExactly $expected
    }

    It 'leaves text without opening frontmatter unchanged' {
        ConvertTo-CodexFrontmatter -Text 'Body allowed-tools: prose' |
            Should -BeExactly 'Body allowed-tools: prose'
    }
}

Describe 'ConvertTo-CodexWorkflowText' {
    It 'converts reviewed workflow phrases and a known slash invocation' {
        $text = @'
.claude/skills and .claude/agents; CLAUDE.md wins.
Use TodoWrite, then the Task tool or Agent tool and the Skill tool.
Use /windbg-crash.
'@
        $actual = ConvertTo-CodexWorkflowText -Text $text `
            -SkillNames @('windbg-crash')
        $actual | Should -Match '\.agents/skills and \.codex/agents; AGENTS\.md wins\.'
        $actual | Should -Match 'a concise Codex task or plan list'
        $actual | Should -Match 'Codex subagent collaboration'
        $actual | Should -Match '/skills discovery'
        $actual | Should -Match 'Use \$windbg-crash\.'
    }

    It 'converts backticked builtins only in tool-call phrases' {
        $text = 'Use the `Bash` tool and the `Read` tool, then the `Edit` tool.'
        $actual = ConvertTo-CodexWorkflowText -Text $text -SkillNames @()
        $actual | Should -Match 'Codex shell, using PowerShell'
        $actual | Should -Match 'file reading plus `rg`/`rg --files`'
        $actual | Should -Match 'preferring `apply_patch`'
        $actual | Should -Not -Match 'the the'
    }

    It 'leaves unknown slash names quoted history and unrelated builtins unchanged' {
        $text = @'
Use /not-installed and mention `Bash` casually.
> History: TodoWrite and /windbg-crash.
```
TodoWrite /windbg-crash
```
'@
        ConvertTo-CodexWorkflowText -Text $text -SkillNames @('windbg-crash') |
            Should -BeExactly $text
    }

    It 'preserves inline quoted history while converting active prose' {
        $text = 'History says "Use TodoWrite"; use TodoWrite now.'
        $expected = 'History says "Use TodoWrite"; use a concise Codex task or plan list now.'
        ConvertTo-CodexWorkflowText -Text $text -SkillNames @() |
            Should -BeExactly $expected
    }

    It 'preserves tilde-fenced historical content' {
        $text = "~~~text`nUse TodoWrite and /windbg-crash.`n~~~"
        ConvertTo-CodexWorkflowText -Text $text -SkillNames @('windbg-crash') |
            Should -BeExactly $text
    }

    It 'preserves mixed markers in <CaseName> history' -ForEach @(
        @{
            CaseName = 'backtick-fenced'
            SourceText = @'
```text
History uses TodoWrite.
~~~
Still history uses /windbg-crash.
```
Use TodoWrite and /windbg-crash.
'@
            ExpectedText = @'
```text
History uses TodoWrite.
~~~
Still history uses /windbg-crash.
```
Use a concise Codex task or plan list and $windbg-crash.
'@
        }
        @{
            CaseName = 'tilde-fenced'
            SourceText = @'
~~~text
History uses TodoWrite.
```
Still history uses /windbg-crash.
~~~
Use TodoWrite and /windbg-crash.
'@
            ExpectedText = @'
~~~text
History uses TodoWrite.
```
Still history uses /windbg-crash.
~~~
Use a concise Codex task or plan list and $windbg-crash.
'@
        }
    ) {
        ConvertTo-CodexWorkflowText -Text $SourceText -SkillNames @('windbg-crash') |
            Should -BeExactly $ExpectedText
    }

    It 'does not reinterpret generated skills discovery as a skill invocation' {
        ConvertTo-CodexWorkflowText -Text 'Use the Skill tool.' -SkillNames @('skills') |
            Should -BeExactly 'Use the /skills discovery.'
    }
}

Describe 'New-CodexAgentServerTable' {
    BeforeEach {
        $httpConfig = [pscustomobject]@{ name = 'x64dbg-mcp-x64'; auth = 'bearer' }
        $httpResult = [pscustomobject]@{
            Transport = 'http'; Bind = '127.0.0.1'; Port = 8765; Path = '/mcp'
        }
        $stdioConfig = [pscustomobject]@{ name = 'mcp-windbg'; auth = 'none' }
        $stdioResult = [pscustomobject]@{
            Transport = 'stdio'
            Command = [pscustomobject]@{
                Executable = 'C:\Program Files\WinDbg MCP\server.exe'
                Arguments = @('--mode', 'read only')
                Env = [ordered]@{ RE_MODE = 'analysis'; RE_LABEL = "cafÃ©" }
            }
        }
    }

    It 'emits a complete disabled authenticated HTTP table without credentials' {
        $actual = New-CodexAgentServerTable -ConfigServer $httpConfig `
            -ServerResult $httpResult -Enabled $false -EnabledTools @()
        $actual | Should -Match 'url = "http://127\.0\.0\.1:8765/mcp"'
        $actual | Should -Match 'enabled = false'
        $actual | Should -Not -Match '(?i)Authorization|Bearer|token'
    }

    It 'emits command args cwd and sorted non-secret environment for stdio' {
        $actual = New-CodexAgentServerTable -ConfigServer $stdioConfig `
            -ServerResult $stdioResult -Enabled $true -EnabledTools @('list_dumps')
        $actual | Should -Match 'command = "C:\\\\Program Files\\\\WinDbg MCP\\\\server\.exe"'
        $actual | Should -Match 'args = \["--mode","read only"\]'
        $actual.IndexOf('RE_LABEL') | Should -BeLessThan $actual.IndexOf('RE_MODE')
    }

    It 'parses stdio controls as server fields rather than environment entries' {
        $actual = New-CodexAgentServerTable -ConfigServer $stdioConfig `
            -ServerResult $stdioResult -Enabled $true -EnabledTools @('list_dumps')
        $path = Join-Path $TestDrive 'agent-server.toml'
        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($path, $actual, $utf8)
        $code = "import json,sys,tomllib; print(json.dumps(" +
            "tomllib.load(open(sys.argv[1], 'rb'))))"
        $json = & python -c $code $path
        $LASTEXITCODE | Should -Be 0
        $server = ($json | ConvertFrom-Json).mcp_servers.'mcp-windbg'
        $server.enabled | Should -BeTrue
        @($server.enabled_tools) | Should -BeExactly @('list_dumps')
        $server.env.RE_MODE | Should -BeExactly 'analysis'
        $server.env.PSObject.Properties.Name | Should -Not -Contain 'enabled'
        $server.env.PSObject.Properties.Name | Should -Not -Contain 'enabled_tools'
    }

    It 'emits cwd when the shared command record supplies it' {
        $stdioResult.Command | Add-Member -NotePropertyName WorkingDirectory `
            -NotePropertyValue 'C:\re\work'
        $actual = New-CodexAgentServerTable -ConfigServer $stdioConfig `
            -ServerResult $stdioResult -Enabled $true -EnabledTools @('list_dumps')
        $actual | Should -Match 'cwd = "C:\\\\re\\\\work"'
    }

    It 'rejects an enabled authenticated HTTP target' {
        { New-CodexAgentServerTable -ConfigServer $httpConfig `
                -ServerResult $httpResult -Enabled $true -EnabledTools @('read_mem') } |
            Should -Throw '*authenticated*enabled*'
    }

    It 'rejects an enabled authenticated stdio target' {
        $stdioConfig.auth = 'bearer'
        { New-CodexAgentServerTable -ConfigServer $stdioConfig `
                -ServerResult $stdioResult -Enabled $true `
                -EnabledTools @('list_dumps') } | Should -Throw '*authenticated*enabled*'
    }

    It 'rejects legacy SSE before rendering' {
        $result = [pscustomobject]@{ Transport = 'sse' }
        { New-CodexAgentServerTable -ConfigServer $stdioConfig `
                -ServerResult $result -Enabled $false -EnabledTools @() } |
            Should -Throw '*SSE*'
    }

    It 'rejects the sensitive environment name <Name>' -ForEach @(
        @{ Name = 'API_TOKEN' }
        @{ Name = 'CLIENT_SECRET' }
        @{ Name = 'DB_PASSWORD' }
        @{ Name = 'AUTH_HEADER' }
        @{ Name = 'PRIVATE_KEY' }
    ) {
        $stdioResult.Command.Env = @{ $Name = 'fixture-sensitive-value' }
        { New-CodexAgentServerTable -ConfigServer $stdioConfig `
                -ServerResult $stdioResult -Enabled $true -EnabledTools @('list_dumps') } |
            Should -Throw '*environment*'
    }

    It 'escapes quotes apostrophes backslashes Unicode and newlines' {
        $value = 'quote " apostrophe '' slash \ cafÃ©' + "`nnext"
        $encoded = ConvertTo-CodexTomlValue -Value $value
        $encoded | Should -BeExactly '"quote \" apostrophe '' slash \\ cafÃ©\nnext"'
    }

    It 'renders an exact TOML basic string array' {
        ConvertTo-CodexTomlArray -Values @('a', 'b c') |
            Should -BeExactly '["a","b c"]'
    }
}
