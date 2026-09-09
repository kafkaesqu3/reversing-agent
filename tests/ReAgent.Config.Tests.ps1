BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Config.psm1" -Force

    $Script:GoodConfig = [PSCustomObject]@{
        version    = 1
        paths      = [PSCustomObject]@{
            toolRoot = 'C:\re'; agentRoot = 'C:\re\agent'
            stateRoot = 'C:\ProgramData\re-lab'; symbolCache = 'C:\re\symbols'
        }
        mcpServers = @(
            [PSCustomObject]@{ name = 'x64dbg-x64'; enabled = $true; kind = 'plugin-inproc';
                transport = 'http'; bind = '127.0.0.1'; port = 9094
            },
            [PSCustomObject]@{ name = 'binaryninja'; enabled = $true; kind = 'gui-builtin-http';
                transport = 'http'; bind = '127.0.0.1'; port = 24642
            },
            [PSCustomObject]@{ name = 'pyghidra-mcp'; enabled = $true; kind = 'venv-stdio';
                transport = 'stdio'; bind = '127.0.0.1'; port = 0
            }
        )
    }
}

Describe 'Test-ReAgentConfigSchema' {
    It 'accepts a well-formed config' {
        Test-ReAgentConfigSchema -Config $Script:GoodConfig | Should -BeTrue
    }

    It 'rejects a server bound to 0.0.0.0' {
        $bad = $Script:GoodConfig | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $bad.mcpServers[0].bind = '0.0.0.0'
        { Test-ReAgentConfigSchema -Config $bad } | Should -Throw '*0.0.0.0*'
    }

    It 'rejects an unknown kind' {
        $bad = $Script:GoodConfig | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $bad.mcpServers[0].kind = 'magic'
        { Test-ReAgentConfigSchema -Config $bad } | Should -Throw '*magic*'
    }

    It 'accepts the venv-http kind that pyghidra-mcp needs' {
        $ok = $Script:GoodConfig | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $ok.mcpServers[2].kind = 'venv-http'
        $ok.mcpServers[2].transport = 'http'
        $ok.mcpServers[2].port = 8762
        Test-ReAgentConfigSchema -Config $ok | Should -BeTrue
    }

    It 'rejects duplicate ports across HTTP servers' {
        $bad = $Script:GoodConfig | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $bad.mcpServers[1].port = 9094
        { Test-ReAgentConfigSchema -Config $bad } | Should -Throw '*9094*'
    }

    It 'allows several stdio servers to share the meaningless port 0' {
        $ok = $Script:GoodConfig | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $ok.mcpServers[0].transport = 'stdio'
        $ok.mcpServers[0].port = 0
        $ok.mcpServers[1].transport = 'stdio'
        $ok.mcpServers[1].port = 0
        Test-ReAgentConfigSchema -Config $ok | Should -BeTrue
    }

    It 'rejects duplicate server names' {
        $bad = $Script:GoodConfig | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $bad.mcpServers[1].name = 'x64dbg-x64'
        { Test-ReAgentConfigSchema -Config $bad } | Should -Throw '*x64dbg-x64*'
    }

    It 'rejects a config missing a required top-level key' {
        $bad = [PSCustomObject]@{ version = 1; paths = $Script:GoodConfig.paths }
        { Test-ReAgentConfigSchema -Config $bad } | Should -Throw '*mcpServers*'
    }
}

Describe 'Get-ServerPortMap' {
    It 'includes only servers that actually use a port' {
        # pyghidra-mcp is transport=stdio in this fixture only; the shipped config
        # uses venv-http. The rule under test is 'stdio has no port', not the pin.
        $map = Get-ServerPortMap -Config $Script:GoodConfig
        $map['x64dbg-x64'] | Should -Be 9094
        $map['binaryninja'] | Should -Be 24642
        $map.ContainsKey('pyghidra-mcp') | Should -BeFalse
    }
}

Describe 'Write-PortsJson' {
    It 'round-trips the port map through disk' {
        $tmp = Join-Path $TestDrive 'ports.json'
        Write-PortsJson -PortMap @{ 'x64dbg-x64' = 9094 } -Path $tmp
        (Get-Content $tmp -Raw | ConvertFrom-Json).'x64dbg-x64' | Should -Be 9094
    }

    It 'creates the parent directory when it does not exist' {
        $tmp = Join-Path $TestDrive 'nested\deeper\ports.json'
        Write-PortsJson -PortMap @{ a = 1 } -Path $tmp
        Test-Path $tmp | Should -BeTrue
    }
}

Describe 'Test-ReAgentConfigSchema skills validation' {
    BeforeAll {
        function New-SkillPack {
            # Pure factory: builds and returns an in-memory PSCustomObject, writes nothing.
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSUseShouldProcessForStateChangingFunctions', '')]
            param($Namespace = 'windbg', $Commit = ('a' * 40), $Name = 'windbg-crash',
                  $Enabled = $true, $Skills = $null, $Targets = @('mcp-windbg'))
            if ($null -eq $Skills) {
                $Skills = @([PSCustomObject]@{ upstream = 'crash'; name = $Name
                        enabled = $Enabled })
            }
            [PSCustomObject]@{
                namespace = $Namespace; enabled = $true
                source = [PSCustomObject]@{ type = 'github-archive'
                    repo = 'svnscha/mcp-windbg'; commit = $Commit
                    treeSha256 = 'PIN-ME'; subPath = 'skills' }
                review = [PSCustomObject]@{ reviewedBy = 'david'; reviewedAt = '2026-09-08'
                    reviewedCommit = $Commit }
                targetServers = $Targets
                scanExceptions = @()
                skills = $Skills
            }
        }
        function New-CfgWith {
            # Pure factory: builds and returns an in-memory PSCustomObject, writes nothing.
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSUseShouldProcessForStateChangingFunctions', '')]
            param($Packs)
            [PSCustomObject]@{
                version = 1
                paths = [PSCustomObject]@{ toolRoot = 'C:\re'; agentRoot = 'C:\re\agent'
                    stateRoot = 'C:\ProgramData\re-lab'; symbolCache = 'C:\re\symbols' }
                symbols = [PSCustomObject]@{ enabled = $false; server = ''; prewarm = @() }
                mcpServers = @([PSCustomObject]@{
                        name = 'mcp-windbg'; enabled = $true; kind = 'venv-stdio'
                        transport = 'stdio'; bind = '127.0.0.1'; port = 0
                    })
                skills = $Packs
            }
        }
    }

    It 'accepts a config with no skills key at all, so an old config still loads' {
        $cfg = New-CfgWith -Packs @()
        $cfg.PSObject.Properties.Remove('skills')
        { Test-ReAgentConfigSchema -Config $cfg } | Should -Not -Throw
    }

    It 'rejects a branch name where a 40-hex commit is required, because tags move' {
        $p = New-SkillPack -Commit 'main'
        { Test-ReAgentConfigSchema -Config (New-CfgWith -Packs @($p)) } |
            Should -Throw '*commit*'
    }

    It 'rejects a sign-off recorded against a different commit as stale' {
        $p = New-SkillPack
        $p.review.reviewedCommit = ('b' * 40)
        { Test-ReAgentConfigSchema -Config (New-CfgWith -Packs @($p)) } |
            Should -Throw '*reviewedCommit*'
    }

    It 'rejects a skill name that does not start with its pack namespace' {
        $p = New-SkillPack -Name 'crash-analysis'
        { Test-ReAgentConfigSchema -Config (New-CfgWith -Packs @($p)) } |
            Should -Throw '*namespace*'
    }

    It 'rejects two packs producing the same skill name' {
        $a = New-SkillPack -Namespace 'windbg' -Name 'windbg-x'
        $b = New-SkillPack -Namespace 'windbg' -Name 'windbg-x'
        $b.namespace = 'windbg'
        { Test-ReAgentConfigSchema -Config (New-CfgWith -Packs @($a, $b)) } |
            Should -Throw '*unique*'
    }

    It 'rejects a targetServers entry naming a server that is not declared' {
        $p = New-SkillPack -Targets @('does-not-exist')
        { Test-ReAgentConfigSchema -Config (New-CfgWith -Packs @($p)) } |
            Should -Throw '*does-not-exist*'
    }

    It 'rejects a disabled skill with no disabledReason, so an omission is never silent' {
        $p = New-SkillPack -Skills @([PSCustomObject]@{ upstream = 'ttd'
                name = 'windbg-ttd'; enabled = $false })
        { Test-ReAgentConfigSchema -Config (New-CfgWith -Packs @($p)) } |
            Should -Throw '*disabledReason*'
    }

    It 'rejects a scan exception with no justification, so no suppression is unreviewed' {
        $p = New-SkillPack
        $p.scanExceptions = @([PSCustomObject]@{ skill = 'crash'; ruleId = 'remote-fetch'
                justification = '' })
        { Test-ReAgentConfigSchema -Config (New-CfgWith -Packs @($p)) } |
            Should -Throw '*justification*'
    }
}

Describe 'the shipped re-agent.config.json' {
    BeforeAll {
        # Join-Path takes only -Path and -ChildPath on PowerShell 5.1; the
        # three-argument form is 6+ only and throws here. Nest instead.
        $Script:ShippedPath = Join-Path (Join-Path $PSScriptRoot '..') 're-agent.config.json'
        $Script:Shipped = Get-ReAgentConfig -Path $Script:ShippedPath
    }

    It 'passes schema validation' {
        { Get-ReAgentConfig -Path $Script:ShippedPath } | Should -Not -Throw
    }

    It 'keeps every server on loopback' {
        foreach ($s in $Script:Shipped.mcpServers) { $s.bind | Should -Be '127.0.0.1' }
    }

    It 'carries both x64dbg architectures on their compiled-in ports' {
        $map = Get-ServerPortMap -Config $Script:Shipped
        $map['x64dbg-x64'] | Should -Be 9094
        $map['x64dbg-x32'] | Should -Be 9095
    }

    It 'leaves Binary Ninja on the vendor default port' {
        (Get-ServerPortMap -Config $Script:Shipped)['binaryninja'] | Should -Be 24642
    }

    It 'runs pyghidra-mcp over http, because stdio breaks its symbol loading' {
        $s = $Script:Shipped.mcpServers | Where-Object { $_.name -eq 'pyghidra-mcp' }
        $s.kind | Should -Be 'venv-http'
        $s.transport | Should -Be 'http'
    }

    It 'records why pyghidra-mcp is exempt from the bearer-token rule' {
        $s = $Script:Shipped.mcpServers | Where-Object { $_.name -eq 'pyghidra-mcp' }
        $s.auth | Should -Be 'none'
        $s.authExemptReason | Should -Not -BeNullOrEmpty
    }

    It 'ships ghidramcp disabled' {
        ($Script:Shipped.mcpServers | Where-Object { $_.name -eq 'ghidramcp' }).enabled |
            Should -BeFalse
    }

    It 'pins every downloaded source' {
        foreach ($s in $Script:Shipped.mcpServers) {
            if ($s.PSObject.Properties.Name -contains 'source') {
                $s.source.pin | Should -Not -Be 'PIN-ME'
                $s.source.pin | Should -Not -BeNullOrEmpty
            }
        }
    }

    It 'points at a test binary that exists on this host' {
        Test-Path -LiteralPath $Script:Shipped.testBinary | Should -BeTrue
    }
}

Describe 'Test-AgentSchema' {
    BeforeAll {
        function Get-TestAgentConfig {
            param($Agents)
            [PSCustomObject]@{
                mcpServers = @([PSCustomObject]@{ name = 'pyghidra-mcp' },
                    [PSCustomObject]@{ name = 'mcp-windbg' })
                agents     = $Agents
            }
        }
        function Get-TestAgent {
            param($Name = 'verifier', $Level = 'read', $Servers = @('pyghidra-mcp'),
                  $Builtins = @('Read', 'Glob', 'Grep'), $Enabled = $true, $Reason = '')
            [PSCustomObject]@{ name = $Name; enabled = $Enabled; level = $Level
                targetServers = $Servers; builtinTools = $Builtins
                model = 'inherit'; disabledReason = $Reason }
        }
    }

    It 'accepts a config with no agents key at all' {
        # StrictMode defect the skills slice already hit in Get-RecordedSkillResult.
        { Test-AgentSchema -Config ([PSCustomObject]@{ mcpServers = @() }) } | Should -Not -Throw
    }

    It 'accepts a well-formed agent' {
        { Test-AgentSchema -Config (Get-TestAgentConfig @(Get-TestAgent)) } | Should -Not -Throw
    }

    It 'rejects a name that is not a valid file basename' {
        { Test-AgentSchema -Config (Get-TestAgentConfig @(Get-TestAgent -Name 'Verifier')) } |
            Should -Throw '*Verifier*'
    }

    It 'rejects two agents sharing a name' {
        $c = Get-TestAgentConfig @((Get-TestAgent), (Get-TestAgent))
        { Test-AgentSchema -Config $c } | Should -Throw '*duplicate*'
    }

    It 'rejects an agent declaring level destructive' {
        { Test-AgentSchema -Config (Get-TestAgentConfig @(Get-TestAgent -Level 'destructive')) } |
            Should -Throw '*destructive*'
    }

    It 'rejects a targetServer absent from mcpServers' {
        $c = Get-TestAgentConfig @(Get-TestAgent -Servers @('ida-pro'))
        { Test-AgentSchema -Config $c } | Should -Throw '*ida-pro*'
    }

    It 'rejects Bash in builtinTools' {
        # NEGATIVE TEST 5 from spec 11. BLUEPRINT 7.1: no host code execution while
        # the model is reading untrusted decompiler output.
        $c = Get-TestAgentConfig @(Get-TestAgent -Builtins @('Read', 'Bash'))
        { Test-AgentSchema -Config $c } | Should -Throw '*Bash*'
    }

    It 'rejects Task in builtinTools so no agent can spawn an agent' {
        $c = Get-TestAgentConfig @(Get-TestAgent -Builtins @('Read', 'Task'))
        { Test-AgentSchema -Config $c } | Should -Throw '*Task*'
    }

    It 'requires a reason when an agent ships disabled' {
        $c = Get-TestAgentConfig @(Get-TestAgent -Enabled $false -Reason '')
        { Test-AgentSchema -Config $c } | Should -Throw '*disabledReason*'
    }

    It 'rejects a disabled agent with disabledReason property omitted entirely' {
        # StrictMode guard: agent has enabled=false but no disabledReason key at all.
        # Should throw the crafted error, not a PropertyNotFoundException.
        $agent = [PSCustomObject]@{ name = 'verifier'; enabled = $false; level = 'read'
            targetServers = @('pyghidra-mcp'); builtinTools = @('Read', 'Glob', 'Grep')
            model = 'inherit' }
        $c = Get-TestAgentConfig @($agent)
        { Test-AgentSchema -Config $c } | Should -Throw '*disabledReason*'
    }
}

