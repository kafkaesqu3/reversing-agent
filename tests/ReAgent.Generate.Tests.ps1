BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Common.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Tokens.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Agents.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Skills.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Generate.psm1" -Force

    function Get-TestResult {
        param(
            $Name = 'binaryninja', $Transport = 'http', $Port = 24642, $Path = '/mcp',
            $Auth = 'bearer-generated', $Installed = $true, $Command = $null
        )
        [PSCustomObject]@{
            Name      = $Name; Transport = $Transport; Bind = '127.0.0.1'
            Port      = $Port; Path = $Path; Auth = $Auth; Installed = $Installed
            Command   = $Command; Status = 'installed'; Kind = 'x'; Enabled = $true
            Reason    = ''; Version = ''
        }
    }
}

Describe 'New-McpServerEntry' {
    It 'builds a URL entry for an HTTP server' {
        $e = New-McpServerEntry -Result (Get-TestResult -Auth 'none') -TokenRoot $TestDrive
        $e.type | Should -Be 'http'
        $e.url | Should -Be 'http://127.0.0.1:24642/mcp'
    }

    It 'omits the Authorization header for a server with no auth mechanism' {
        # pyghidra-mcp exposes no bearer, API key or auth flag of any kind.
        $r = Get-TestResult -Name 'pyghidra-mcp' -Port 8762 -Auth 'none'
        $e = New-McpServerEntry -Result $r -TokenRoot $TestDrive
        $e.Keys | Should -Not -Contain 'headers'
    }

    It 'emits a bearer header when a token is stored' {
        Save-ServerToken -Name 'binaryninja' -Token 'sekrit' -TokenRoot $TestDrive
        $e = New-McpServerEntry -Result (Get-TestResult) -TokenRoot $TestDrive
        $e.headers.Authorization | Should -Be 'Bearer sekrit'
    }

    It 'warns rather than inventing a header when the token is missing' {
        $r = Get-TestResult -Name 'no-token-here'
        $e = New-McpServerEntry -Result $r -TokenRoot (Join-Path $TestDrive 'empty')
        $e.Keys | Should -Not -Contain 'headers'
    }

    It 'builds an sse entry preserving the sse type' {
        $r = Get-TestResult -Name 'ghidramcp' -Transport 'sse' -Port 8761 -Path '/sse' -Auth 'none'
        (New-McpServerEntry -Result $r -TokenRoot $TestDrive).type | Should -Be 'sse'
    }

    It 'builds a command entry for a stdio server' {
        $cmd = [PSCustomObject]@{
            Executable = 'C:\v\Scripts\python.exe'
            Arguments  = @('-m', 'mcp_windbg')
            Env        = @{ _NT_SYMBOL_PATH = 'SRV*a*b' }
        }
        $r = Get-TestResult -Name 'mcp-windbg' -Transport 'stdio' -Port 0 -Auth 'none' -Command $cmd
        $e = New-McpServerEntry -Result $r -TokenRoot $TestDrive
        $e.command | Should -Be 'C:\v\Scripts\python.exe'
        $e.args | Should -Contain 'mcp_windbg'
        $e.env._NT_SYMBOL_PATH | Should -Be 'SRV*a*b'
        $e.Keys | Should -Not -Contain 'url'
    }

    It 'uses the x64dbg root endpoint, not /mcp' {
        $r = Get-TestResult -Name 'x64dbg-x64' -Port 9094 -Path '/' -Auth 'none'
        (New-McpServerEntry -Result $r -TokenRoot $TestDrive).url |
            Should -Be 'http://127.0.0.1:9094/'
    }
}

Describe 'New-McpJsonObject' {
    It 'includes only installed servers' {
        $results = @(
            (Get-TestResult -Name 'good' -Auth 'none'),
            (Get-TestResult -Name 'bad' -Auth 'none' -Installed $false)
        )
        $o = New-McpJsonObject -ServerResults $results -TokenRoot $TestDrive
        $o.mcpServers.Keys | Should -Contain 'good'
        $o.mcpServers.Keys | Should -Not -Contain 'bad'
    }

    It 'orders servers by name so a re-run reproduces the file byte for byte' {
        $a = @((Get-TestResult -Name 'zebra' -Auth 'none'),
            (Get-TestResult -Name 'alpha' -Auth 'none'))
        $b = @((Get-TestResult -Name 'alpha' -Auth 'none'),
            (Get-TestResult -Name 'zebra' -Auth 'none'))
        ($a | ForEach-Object { $_ } | Out-Null)
        $ja = New-McpJsonObject -ServerResults $a -TokenRoot $TestDrive | ConvertTo-Json -Depth 12
        $jb = New-McpJsonObject -ServerResults $b -TokenRoot $TestDrive | ConvertTo-Json -Depth 12
        $ja | Should -Be $jb
    }

    It 'produces valid JSON with no servers at all' {
        $o = New-McpJsonObject -ServerResults @() -TokenRoot $TestDrive
        { $o | ConvertTo-Json -Depth 12 | ConvertFrom-Json } | Should -Not -Throw
    }
}

Describe 'New-ClaudeSettingsObject' {
    BeforeAll {
        $Script:Cfg = [PSCustomObject]@{
            mcpServers = @(
                [PSCustomObject]@{ name = 'pyghidra-mcp'; enabled = $true },
                [PSCustomObject]@{ name = 'ghidramcp'; enabled = $false }
            )
        }
    }

    It 'disables exactly the servers marked disabled in config' {
        $s = New-ClaudeSettingsObject -Config $Script:Cfg
        $s.disabledMcpjsonServers | Should -Contain 'ghidramcp'
        $s.disabledMcpjsonServers | Should -Not -Contain 'pyghidra-mcp'
    }

    It 'approves project servers, without which claude mcp list shows nothing connected' {
        (New-ClaudeSettingsObject -Config $Script:Cfg).enableAllProjectMcpServers |
            Should -BeTrue
    }

    It 'uses the json-suffixed key, not the /mcp panel key' {
        $s = New-ClaudeSettingsObject -Config $Script:Cfg
        $s.Keys | Should -Contain 'disabledMcpjsonServers'
        $s.Keys | Should -Not -Contain 'disabledMcpServers'
    }
}

Describe 'Write-AgentConfiguration' {
    BeforeAll {
        $Script:TplRoot = Join-Path $TestDrive 'templates'
        $null = New-Item -ItemType Directory -Path $Script:TplRoot -Force
        '# RE Lab - Operating Contract' | Set-Content (Join-Path $Script:TplRoot 'CLAUDE.md.template')

        $Script:GenCfg = [PSCustomObject]@{
            paths      = [PSCustomObject]@{
                toolRoot  = (Join-Path $TestDrive 're')
                agentRoot = (Join-Path $TestDrive 're\agent')
            }
            mcpServers = @([PSCustomObject]@{ name = 'ghidramcp'; enabled = $false })
        }
        $Script:GenResults = @([PSCustomObject]@{
                Name    = 'pyghidra-mcp'; Transport = 'http'; Bind = '127.0.0.1'
                Port    = 8762; Path = '/mcp'; Auth = 'none'; Installed = $true
                Command = $null
            })
    }

    It 'writes all three artefacts' {
        Write-AgentConfiguration -Config $Script:GenCfg -ServerResults $Script:GenResults `
            -TemplateRoot $Script:TplRoot | Out-Null
        Test-Path (Join-Path $Script:GenCfg.paths.agentRoot '.mcp.json') | Should -BeTrue
        Test-Path (Join-Path $Script:GenCfg.paths.agentRoot '.claude\settings.json') |
            Should -BeTrue
        Test-Path (Join-Path $Script:GenCfg.paths.agentRoot 'CLAUDE.md') | Should -BeTrue
    }

    It 'creates the cases directory' {
        Write-AgentConfiguration -Config $Script:GenCfg -ServerResults $Script:GenResults `
            -TemplateRoot $Script:TplRoot | Out-Null
        Test-Path (Join-Path $Script:GenCfg.paths.agentRoot 'cases') | Should -BeTrue
    }

    It 'regenerates byte-identical output on a second run' {
        # The idempotency contract: generated config is derived state and must
        # carry no timestamps or other varying content.
        Write-AgentConfiguration -Config $Script:GenCfg -ServerResults $Script:GenResults `
            -TemplateRoot $Script:TplRoot | Out-Null
        $first = Get-Content (Join-Path $Script:GenCfg.paths.agentRoot '.mcp.json') -Raw
        Write-AgentConfiguration -Config $Script:GenCfg -ServerResults $Script:GenResults `
            -TemplateRoot $Script:TplRoot | Out-Null
        $second = Get-Content (Join-Path $Script:GenCfg.paths.agentRoot '.mcp.json') -Raw
        $second | Should -Be $first
    }

    It 'emits .mcp.json that parses and references only allocated ports' {
        Write-AgentConfiguration -Config $Script:GenCfg -ServerResults $Script:GenResults `
            -TemplateRoot $Script:TplRoot | Out-Null
        $j = Get-Content (Join-Path $Script:GenCfg.paths.agentRoot '.mcp.json') -Raw |
            ConvertFrom-Json
        $j.mcpServers.'pyghidra-mcp'.url | Should -Be 'http://127.0.0.1:8762/mcp'
    }

    It 'fails loudly when the CLAUDE.md template is missing' {
        # The template carries the trust-boundary contract; silently skipping it
        # would ship an agent with no instruction that binary output is data.
        { Write-AgentConfiguration -Config $Script:GenCfg -ServerResults $Script:GenResults `
                -TemplateRoot (Join-Path $TestDrive 'no-templates') } |
            Should -Throw '*template not found*'
    }

    It 'generates agent files when config includes agents' {
        $agentCfg = [PSCustomObject]@{
            paths      = [PSCustomObject]@{
                toolRoot  = (Join-Path $TestDrive 're')
                agentRoot = (Join-Path $TestDrive 're\agent')
            }
            mcpServers = @([PSCustomObject]@{ name = 'ghidramcp'; enabled = $false })
            agents     = @([PSCustomObject]@{
                name = 'verifier'; enabled = $true; level = 'read'
                targetServers = @('pyghidra-mcp'); builtinTools = @('Read', 'Glob', 'Grep')
                model = 'inherit'; disabledReason = '' })
        }
        $agentTplDir = Join-Path $TestDrive 'templates\agents'
        $null = New-Item -ItemType Directory -Path $agentTplDir -Force
        '{{TOOLS}}
{{SERVERS}}
{{LIMITATIONS}}' | Set-Content (Join-Path $agentTplDir 'verifier.md.template')

        Write-AgentConfiguration -Config $agentCfg -ServerResults $Script:GenResults `
            -TemplateRoot (Split-Path $agentTplDir) | Out-Null
        Test-Path (Join-Path $agentCfg.paths.agentRoot '.claude\agents\verifier.md') | Should -BeTrue
    }

}

Describe 'the shipped CLAUDE.md template' {
    BeforeAll {
        $Script:Tpl = Get-Content `
            (Join-Path (Join-Path $PSScriptRoot '..') 'templates\CLAUDE.md.template') -Raw
    }

    It 'states the trust boundary' {
        $Script:Tpl | Should -BeLike '*NEVER*INSTRUCTIONS*'
    }

    It 'warns that Binary Ninja needs starting every session' {
        $Script:Tpl | Should -BeLike '*ONCE PER SESSION*'
    }

    It 'names both x64dbg servers' {
        $Script:Tpl | Should -BeLike '*x64dbg-x32*'
    }

    It 'warns that Ghidra binary names are program paths' {
        $Script:Tpl | Should -BeLike '*list_project_binaries*'
    }

    It 'keeps the skill-boundary lines that stop a skill overriding the contract' {
        # These are the in-band defence against a malware-free but dangerous-by-design
        # pack, belt and braces with the scanner because the gate can be not-testable.
        # A future edit must not quietly drop them.
        $Script:Tpl | Should -BeLike '*THIS FILE WINS*'
        $Script:Tpl | Should -BeLike '*ai_*'
        $Script:Tpl | Should -BeLike '*Never substitute a similar-sounding tool*'
    }

    It 'sends the agent to the config, not the manifest, for a disabled skill reason' {
        # manifest.json's skills[] carries the ENABLED skill names and a pack-level
        # reason only (Manifest.psm1). An agent told to read the manifest for a
        # per-skill disabledReason finds the disabled skill absent altogether and
        # concludes the capability is genuinely missing - the opposite of what these
        # two lines exist to prevent. The reason lives in re-agent.config.json.
        $Script:Tpl | Should -Not -BeLike '*see the manifest before assuming*'
        $Script:Tpl | Should -Not -Match '(?s)a reason recorded in the\s+manifest'
        $Script:Tpl | Should -BeLike '*disabledReason in re-agent.config.json*'
    }

    It 'does not repeat the corrected two-tool claim about mcp-windbg' {
        # data/tool-catalog.json records the verified ten-tool surface; the contract text
        # claimed a dump-only server, which is the same Task-7 measurement error the
        # windbg skill content already had to be corrected for. Matched with -Match, not
        # -BeLike: the claim is wrapped across two lines in the template.
        $Script:Tpl | Should -Not -Match '(?s)has no\s+live-process tool'
        $Script:Tpl | Should -BeLike '*open_cdb_remote*'
    }
}

Describe 'Write-AgentDefinition' {
    BeforeEach {
        $script:Dir = Join-Path ([IO.Path]::GetTempPath()) ("agt-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:Cat = [PSCustomObject]@{ servers = [PSCustomObject]@{
                'pyghidra-mcp' = [PSCustomObject]@{
                    tools = @('decompile_function', 'rename_function')
                    classification = [PSCustomObject]@{
                        classifiedTools = @('decompile_function', 'rename_function')
                        write = @('rename_function'); destructive = @() } } } }
        $script:Cfg = [PSCustomObject]@{ agents = @(
                [PSCustomObject]@{ name = 'verifier'; enabled = $true; level = 'read'
                    targetServers = @('pyghidra-mcp'); builtinTools = @('Read', 'Glob', 'Grep')
                    model = 'inherit'; disabledReason = '' }) }
        $script:Root = Join-Path $PSScriptRoot '..'
    }
    AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'writes one file per enabled agent, named for the agent' {
        Write-AgentDefinition -Config $script:Cfg -Catalog $script:Cat -RepoRoot $script:Root `
            -AgentDir $script:Dir | Out-Null
        Test-Path (Join-Path $script:Dir 'verifier.md') | Should -BeTrue
    }

    It 'substitutes the derived tool list into the frontmatter' {
        Write-AgentDefinition -Config $script:Cfg -Catalog $script:Cat -RepoRoot $script:Root `
            -AgentDir $script:Dir | Out-Null
        $t = Get-Content -LiteralPath (Join-Path $script:Dir 'verifier.md') -Raw
        $t | Should -BeLike '*mcp__pyghidra-mcp__decompile_function*'
        $t | Should -Not -BeLike '*rename_function*'
        $t | Should -Not -BeLike '*{{TOOLS}}*'
    }

    It 'writes nothing on a second run and reports no change' {
        Write-AgentDefinition -Config $script:Cfg -Catalog $script:Cat -RepoRoot $script:Root `
            -AgentDir $script:Dir | Out-Null
        $second = Write-AgentDefinition -Config $script:Cfg -Catalog $script:Cat `
            -RepoRoot $script:Root -AgentDir $script:Dir
        # Spec 1.3.4: byte-identical regeneration, no timestamp churn.
        @($second | Where-Object { $_.Changed }).Count | Should -Be 0
    }

    It 'does not write a disabled agent, but still reports it' {
        $script:Cfg.agents[0].enabled = $false
        $script:Cfg.agents[0].disabledReason = 'no oracle yet'
        $r = Write-AgentDefinition -Config $script:Cfg -Catalog $script:Cat `
            -RepoRoot $script:Root -AgentDir $script:Dir
        Test-Path (Join-Path $script:Dir 'verifier.md') | Should -BeFalse
        $r[0].Enabled | Should -BeFalse
        $r[0].DisabledReason | Should -Be 'no oracle yet'
    }

    It 'leaves an agent file this installer did not write alone' {
        # The skills slice shipped exactly this defect against a shared root and had
        # to fix it: removal is scoped to names this config knows.
        $foreign = Join-Path $script:Dir 'operators-own.md'
        Set-Content -LiteralPath $foreign -Value 'not ours' -NoNewline
        Write-AgentDefinition -Config $script:Cfg -Catalog $script:Cat -RepoRoot $script:Root `
            -AgentDir $script:Dir | Out-Null
        Test-Path $foreign | Should -BeTrue
    }

    It 'removes a file for an agent this config used to declare and no longer enables' {
        Write-AgentDefinition -Config $script:Cfg -Catalog $script:Cat -RepoRoot $script:Root `
            -AgentDir $script:Dir | Out-Null
        $script:Cfg.agents[0].enabled = $false
        $script:Cfg.agents[0].disabledReason = 'turned off'
        Write-AgentDefinition -Config $script:Cfg -Catalog $script:Cat -RepoRoot $script:Root `
            -AgentDir $script:Dir | Out-Null
        Test-Path (Join-Path $script:Dir 'verifier.md') | Should -BeFalse
    }
}
Describe 'CLAUDE.md agents section' {
    BeforeAll {
        $script:Tpl = Get-Content -LiteralPath (
            Join-Path $PSScriptRoot '../templates/CLAUDE.md.template') -Raw
    }

    It 'has an Agents section' {
        $script:Tpl | Should -Match '(?m)^## Agents$'
    }

    It 'states that the main session routes and no agent spawns another' {
        $script:Tpl | Should -BeLike '*no agent spawns another*'
    }

    It 'states that the verifier runs last and independently' {
        $script:Tpl | Should -BeLike '*last*'
        $script:Tpl | Should -BeLike '*ai_*'
    }

    It 'tells the reader a missing tool is a grant, not a broken server' {
        $script:Tpl | Should -BeLike '*not a broken server*'
    }

    It 'keeps CLAUDE.md winning over any agent that contradicts it' {
        $script:Tpl | Should -BeLike '*CLAUDE.md wins*'
    }
}

