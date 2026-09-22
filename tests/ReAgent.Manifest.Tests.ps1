BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Common.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Discovery.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Symbols.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Servers.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Manifest.psm1" -Force

    function Write-TestManifest {
        param([string]$StateRoot, [array]$Servers)
        $json = [ordered]@{ generatedAt = '2026-09-06T00:00:00'; servers = $Servers } |
            ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText((Join-Path $StateRoot 'manifest.json'), $json)
    }
}

AfterAll {
    Get-Module 'ReAgent.*' | Remove-Module -Force
}

Describe 'Get-RecordedServerResult' {
    BeforeEach {
        $Script:State = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $Script:State -Force
        $Script:Cfg = [PSCustomObject]@{
            version    = 1
            paths      = [PSCustomObject]@{
                toolRoot    = (Join-Path $TestDrive 'tools')
                agentRoot   = (Join-Path $TestDrive 'agent')
                stateRoot   = $Script:State
                symbolCache = (Join-Path $TestDrive 'symbols')
            }
            symbols    = [PSCustomObject]@{ server = 'https://example.invalid/symbols' }
            mcpServers = @(
                [PSCustomObject]@{
                    name = 'pyghidra-mcp'; enabled = $true; kind = 'venv-http'
                    transport = 'http'; bind = '127.0.0.1'; port = 8762
                    path = '/mcp'; auth = 'none'
                },
                [PSCustomObject]@{
                    name = 'mcp-windbg'; enabled = $true; kind = 'venv-stdio'
                    transport = 'stdio'; bind = '127.0.0.1'; port = 0; auth = 'none'
                },
                [PSCustomObject]@{
                    name = 'ghidramcp'; enabled = $false; kind = 'gui-plugin-http'
                    transport = 'sse'; bind = '127.0.0.1'; port = 8761
                    path = '/sse'; auth = 'bearer-generated'
                }
            )
        }
        $Script:Inv = [PSCustomObject]@{ Cdb = 'C:\win\cdb.exe' }
    }

    It 'reconstructs an installed server the manifest recorded' {
        Write-TestManifest -StateRoot $Script:State -Servers @(
            @{ name = 'pyghidra-mcp'; kind = 'venv-http'; status = 'installed'
                version = '0.2.5'; reason = '' })
        $r = @(Get-RecordedServerResult -Config $Script:Cfg -Inventory $Script:Inv)
        $one = $r | Where-Object { $_.Name -eq 'pyghidra-mcp' }
        $one.Installed | Should -BeTrue
        $one.Version | Should -Be '0.2.5'
        $one.Port | Should -Be 8762
    }

    It 'carries through a server the manifest recorded as not installed' {
        Write-TestManifest -StateRoot $Script:State -Servers @(
            @{ name = 'ghidramcp'; kind = 'gui-plugin-http'; status = 'not-installed'
                version = ''; reason = 'Disabled in re-agent.config.json.' })
        $one = @(Get-RecordedServerResult -Config $Script:Cfg -Inventory $Script:Inv) |
            Where-Object { $_.Name -eq 'ghidramcp' }
        $one.Installed | Should -BeFalse
        $one.Reason | Should -Be 'Disabled in re-agent.config.json.'
    }

    It 'rebuilds the launch command for a stdio server so its probe can run' {
        # Without this the stdio check cannot start the server and reports a
        # false negative - the exact failure -VerifyOnly shipped with.
        Write-TestManifest -StateRoot $Script:State -Servers @(
            @{ name = 'mcp-windbg'; kind = 'venv-stdio'; status = 'installed'
                version = '1.2.1'; reason = '' })
        $one = @(Get-RecordedServerResult -Config $Script:Cfg -Inventory $Script:Inv) |
            Where-Object { $_.Name -eq 'mcp-windbg' }
        $one.Command | Should -Not -BeNullOrEmpty
        $one.Command.Arguments | Should -Contain '--cdb-path'
        $one.Command.Arguments | Should -Contain 'C:\win\cdb.exe'
    }

    It 'returns nothing when no manifest has ever been written' {
        @(Get-RecordedServerResult -Config $Script:Cfg -Inventory $Script:Inv).Count |
            Should -Be 0
    }

    It 'returns nothing rather than throwing on a corrupt manifest' {
        [IO.File]::WriteAllText((Join-Path $Script:State 'manifest.json'), '{ not json')
        @(Get-RecordedServerResult -Config $Script:Cfg -Inventory $Script:Inv).Count |
            Should -Be 0
    }

    It 'ignores a manifest entry naming a server the config no longer has' {
        Write-TestManifest -StateRoot $Script:State -Servers @(
            @{ name = 'retired-server'; kind = 'venv-http'; status = 'installed'
                version = '1.0'; reason = '' })
        @(Get-RecordedServerResult -Config $Script:Cfg -Inventory $Script:Inv).Count |
            Should -Be 0
    }
}

Describe 'Get-ManualStep' {
    It 'always tells the operator to accept the trust prompt' {
        $cfg = [PSCustomObject]@{ paths = [PSCustomObject]@{ agentRoot = 'C:\re\agent' } }
        (Get-ManualStep -Config $cfg -ServerResults @()) -join ' ' |
            Should -BeLike '*trust prompt*'
    }

    It 'names the per-session Binary Ninja step only when it is installed' {
        $cfg = [PSCustomObject]@{ paths = [PSCustomObject]@{ agentRoot = 'C:\re\agent' } }
        $installed = @([PSCustomObject]@{ Name = 'binaryninja'; Kind = 'gui-builtin-http'
                Installed = $true })
        $absent = @([PSCustomObject]@{ Name = 'binaryninja'; Kind = 'gui-builtin-http'
                Installed = $false })
        (Get-ManualStep -Config $cfg -ServerResults $installed) -join ' ' |
            Should -BeLike '*Start Server*'
        (Get-ManualStep -Config $cfg -ServerResults $absent) -join ' ' |
            Should -Not -BeLike '*Start Server*'
    }

    It 'says nothing about a config with no skills key at all' {
        # Configs predating skill packs, and hand-built test fixtures, must not crash.
        $cfg = [PSCustomObject]@{ paths = [PSCustomObject]@{ agentRoot = 'C:\re\agent' } }
        { Get-ManualStep -Config $cfg -ServerResults @() } | Should -Not -Throw
    }

    It 'names a skill pack with no recorded review at all' {
        $cfg = [PSCustomObject]@{
            paths  = [PSCustomObject]@{ agentRoot = 'C:\re\agent' }
            skills = @([PSCustomObject]@{ namespace = 'x64dbg' })
        }
        (Get-ManualStep -Config $cfg -ServerResults @()) -join ' ' | Should -BeLike '*x64dbg*'
    }

    It 'names a skill pack whose reviewedCommit does not match source.commit' {
        $cfg = [PSCustomObject]@{
            paths  = [PSCustomObject]@{ agentRoot = 'C:\re\agent' }
            skills = @([PSCustomObject]@{
                    namespace = 'windbg'
                    source    = [PSCustomObject]@{ commit = ('a' * 40) }
                    review    = [PSCustomObject]@{
                        reviewedBy = 'david'; reviewedAt = '2026-09-08'
                        reviewedCommit = ('b' * 40)
                    }
                })
        }
        (Get-ManualStep -Config $cfg -ServerResults @()) -join ' ' | Should -BeLike '*windbg*'
    }

    It 'says nothing about a fully reviewed, current skill pack' {
        $cfg = [PSCustomObject]@{
            paths  = [PSCustomObject]@{ agentRoot = 'C:\re\agent' }
            skills = @([PSCustomObject]@{
                    namespace = 'windbg'
                    source    = [PSCustomObject]@{ commit = ('a' * 40) }
                    review    = [PSCustomObject]@{
                        reviewedBy = 'david'; reviewedAt = '2026-09-08'
                        reviewedCommit = ('a' * 40)
                    }
                })
        }
        (Get-ManualStep -Config $cfg -ServerResults @()) -join ' ' |
            Should -Not -BeLike '*windbg*'
    }
}

Describe 'Write-Manifest skills key' {
    BeforeAll {
        function New-MCfg {
            # Pure factory: builds and returns an in-memory PSCustomObject, writes nothing.
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSUseShouldProcessForStateChangingFunctions', '')]
            param($StateRoot)
            [PSCustomObject]@{
                version = 1
                paths = [PSCustomObject]@{
                    stateRoot = $StateRoot
                    agentRoot = (Join-Path $StateRoot 'agent')
                }
                mcpServers = @()
                skills = @([PSCustomObject]@{ namespace = 'x64dbg' })
            }
        }
        function New-MSkillResult {
            # Pure factory: builds and returns an in-memory PSCustomObject, writes nothing.
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSUseShouldProcessForStateChangingFunctions', '')]
            param($Reason = '', $Findings = @(), $SkillEntries = @())
            [PSCustomObject]@{
                Namespace = 'x64dbg'; Status = 'installed'; Installed = $true
                SkillNames = @('x64dbg-find-oep'); Repo = 'dariushoule/x64dbg-skills'
                Commit = ('a' * 40); TreeSha256 = ('b' * 64)
                ReviewedBy = 'david'; ReviewedAt = '2026-09-08'
                SkillEntries = @($SkillEntries)
                Reason = $Reason; Findings = $Findings
            }
        }
        function Get-WrittenManifest {
            param($Context)
            $null = Write-Manifest -Context $Context -PhaseResults @()
            $p = Join-Path $Context.Config.paths.stateRoot 'manifest.json'
            return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json)
        }
    }

    It 'records provenance and sign-off for every pack' {
        $cfg = New-MCfg -StateRoot (Join-Path $TestDrive 'wm-prov')
        $ctx = @{ Config = $cfg; Inventory = $null; ServerResults = @()
            VerifyResults = @(); SkillResults = @(New-MSkillResult) }
        $m = Get-WrittenManifest -Context $ctx
        $m.skills[0].commit | Should -Be ('a' * 40)
        $m.skills[0].reviewedBy | Should -Be 'david'
        $m.skills[0].treeSha256 | Should -Be ('b' * 64)
    }

    It 'carries a disabled skill reason verbatim so nobody re-enables it blindly' {
        $cfg = New-MCfg -StateRoot (Join-Path $TestDrive 'wm-reason')
        $r = New-MSkillResult -Reason 'drives angr, which is not installed on this host'
        $ctx = @{ Config = $cfg; Inventory = $null; ServerResults = @()
            VerifyResults = @(); SkillResults = @($r) }
        (Get-WrittenManifest -Context $ctx).skills[0].reason | Should -BeLike '*angr*'
    }

    It 'truncates findings to twenty and keeps only rule, file and line' {
        # manifest.json already embeds the whole inventory; a pack with many findings
        # would bloat it. Reasons and remedies go to the log, not here.
        $many = 1..30 | ForEach-Object {
            [PSCustomObject]@{ RuleId = 'pipe-to-shell'; File = "f$_.md"; Line = $_
                Severity = 'block'; Text = 'noise' } }
        $cfg = New-MCfg -StateRoot (Join-Path $TestDrive 'wm-trunc')
        $ctx = @{ Config = $cfg; Inventory = $null; ServerResults = @()
            VerifyResults = @(); SkillResults = @(New-MSkillResult -Findings $many) }
        $m = Get-WrittenManifest -Context $ctx
        $m.skills[0].findings.Count | Should -Be 20
        @($m.skills[0].findings[0].PSObject.Properties.Name) |
            Should -Be @('rule', 'file', 'line')
    }

    It 'records every declared skill, including the disabled ones and why' {
        # Design spec 1.3.5: the manifest records every pack and skill 'including
        # which shipped disabled and why'. The skills field carries only what
        # installed, so six skills shipping disabled reached nothing a reader of the
        # manifest could see - and in the shipped state, where every pack refuses at
        # the review gate, it names zero skills for any pack.
        $entries = @(
            [PSCustomObject]@{ Name = 'x64dbg-find-oep'; Enabled = $true
                DisabledReason = '' },
            [PSCustomObject]@{ Name = 'x64dbg-trace'; Enabled = $false
                DisabledReason = 'drives angr, which is not installed on this host' })
        $cfg = New-MCfg -StateRoot (Join-Path $TestDrive 'wm-entries')
        $ctx = @{ Config = $cfg; Inventory = $null; ServerResults = @()
            VerifyResults = @(); SkillResults = @(New-MSkillResult -SkillEntries $entries) }
        $m = Get-WrittenManifest -Context $ctx
        $m.skills[0].skillEntries.Count | Should -Be 2
        $off = $m.skills[0].skillEntries | Where-Object { -not $_.enabled }
        $off.name | Should -Be 'x64dbg-trace'
        $off.disabledReason | Should -BeLike '*angr*'
    }

    It 'records a refused pack every declared skill even though it installed none' {
        # Every pack ships held at the human review gate, so SkillNames is empty for
        # all of them. skillEntries must still say what the pack declares.
        $entries = @([PSCustomObject]@{ Name = 'x64dbg-find-oep'; Enabled = $true
                DisabledReason = '' })
        $r = New-MSkillResult -SkillEntries $entries
        $r.Status = 'not-installed'
        $r.SkillNames = @()
        $cfg = New-MCfg -StateRoot (Join-Path $TestDrive 'wm-refused')
        $ctx = @{ Config = $cfg; Inventory = $null; ServerResults = @()
            VerifyResults = @(); SkillResults = @($r) }
        $m = Get-WrittenManifest -Context $ctx
        $m.skills[0].skills.Count | Should -Be 0
        $m.skills[0].skillEntries.Count | Should -Be 1
    }

    It 'writes an empty skills array without a SkillResults key in the context' {
        # Write-Manifest always runs, including after failures; a context a caller
        # built without SkillResults must not crash it.
        $cfg = New-MCfg -StateRoot (Join-Path $TestDrive 'wm-noskillresults')
        $ctx = @{ Config = $cfg; Inventory = $null; ServerResults = @(); VerifyResults = @() }
        (Get-WrittenManifest -Context $ctx).skills.Count | Should -Be 0
    }
}

Describe 'Write-Manifest agents key' {
    BeforeAll {
        function New-MAgentCfg {
            # Pure factory: builds and returns an in-memory PSCustomObject, writes nothing.
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSUseShouldProcessForStateChangingFunctions', '')]
            param($StateRoot)
            [PSCustomObject]@{
                version = 1
                paths = [PSCustomObject]@{
                    stateRoot = $StateRoot
                    agentRoot = (Join-Path $StateRoot 'agent')
                }
                mcpServers = @()
            }
        }
        function New-MAgentResult {
            # Pure factory: builds and returns an in-memory PSCustomObject, writes nothing.
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSUseShouldProcessForStateChangingFunctions', '')]
            param($Name = 'verifier')
            [PSCustomObject]@{ Name = $Name; Enabled = $true; DisabledReason = ''
                Level = 'read'; Servers = @('pyghidra-mcp'); ToolCount = 15 }
        }
        function Get-WrittenManifest {
            param($Context)
            $null = Write-Manifest -Context $Context -PhaseResults @()
            $p = Join-Path $Context.Config.paths.stateRoot 'manifest.json'
            return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json)
        }
    }

    It 'records the agents check status as the gate, not a hardcoded pass' {
        # This is the defect the fix closes: a manifest that always wrote 'pass'
        # would say a failed A0-A4 gate passed.
        $cfg = New-MAgentCfg -StateRoot (Join-Path $TestDrive 'wm-agent-fail')
        $ctx = @{ Config = $cfg; Inventory = $null; ServerResults = @()
            VerifyResults = @([PSCustomObject]@{ Name = 'agents'; Status = 'fail'
                    Detail = '[A3] over-grant' })
            AgentResults = @(New-MAgentResult) }
        $m = Get-WrittenManifest -Context $ctx
        $m.agents[0].gate | Should -Be 'fail'
    }

    It 'records a real pass when the agents check actually passed' {
        $cfg = New-MAgentCfg -StateRoot (Join-Path $TestDrive 'wm-agent-pass')
        $ctx = @{ Config = $cfg; Inventory = $null; ServerResults = @()
            VerifyResults = @([PSCustomObject]@{ Name = 'agents'; Status = 'pass'
                    Detail = '1 agent(s) on record; the A0-A4 gate found no over-grant.' })
            AgentResults = @(New-MAgentResult) }
        $m = Get-WrittenManifest -Context $ctx
        $m.agents[0].gate | Should -Be 'pass'
    }

    It 'records not-testable rather than pass when phase 6 did not run' {
        $cfg = New-MAgentCfg -StateRoot (Join-Path $TestDrive 'wm-agent-notestable')
        $ctx = @{ Config = $cfg; Inventory = $null; ServerResults = @()
            VerifyResults = @(); AgentResults = @(New-MAgentResult) }
        $m = Get-WrittenManifest -Context $ctx
        $m.agents[0].gate | Should -Be 'not-testable'
    }
}

Describe 'Get-RecordedSkillResult' {
    It 'warns rather than throwing when there is no manifest' {
        # Mirrors Get-RecordedServerResult: a missing manifest is 'nothing recorded yet',
        # never a crash mid-verification.
        $cfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ stateRoot = (Join-Path $TestDrive 'grs-none') }
            skills = @() }
        @(Get-RecordedSkillResult -Config $cfg) | Should -BeNullOrEmpty
    }

    It 'drops packs the current config no longer declares' {
        $state = Join-Path $TestDrive 'grs-drop'
        $null = New-Item -ItemType Directory -Path $state -Force
        $manifest = @{ skills = @(
                @{ namespace = 'windbg'; status = 'installed'; repo = 'a/b'
                    commit = ('a' * 40); treeSha256 = ('b' * 64); reviewedBy = 'david'
                    reviewedAt = '2026-09-08'; skills = @('windbg-crash'); reason = ''
                    findings = @() },
                @{ namespace = 'retired'; status = 'installed'; repo = 'c/d'
                    commit = ('c' * 40); treeSha256 = ('d' * 64); reviewedBy = 'david'
                    reviewedAt = '2026-09-08'; skills = @('retired-x'); reason = ''
                    findings = @() }) }
        $manifest | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath (Join-Path $state 'manifest.json')

        $cfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ stateRoot = $state }
            skills = @([PSCustomObject]@{ namespace = 'windbg' }) }
        $got = @(Get-RecordedSkillResult -Config $cfg)
        $got.Count | Should -Be 1
        $got[0].Namespace | Should -Be 'windbg'
    }

    It 'round-trips a manifest Write-Manifest itself produced' {
        # The two tests above use a hand-written manifest.json; this ties the read
        # side back to Write-Manifest's actual on-disk shape end to end.
        $state = Join-Path $TestDrive 'grs-roundtrip'
        $cfg = [PSCustomObject]@{
            version = 1
            paths = [PSCustomObject]@{
                stateRoot = $state
                agentRoot = (Join-Path $state 'agent')
            }
            mcpServers = @()
            skills = @([PSCustomObject]@{ namespace = 'x64dbg' })
        }
        $skillResult = [PSCustomObject]@{
            Namespace = 'x64dbg'; Status = 'installed'; Installed = $true
            SkillNames = @('x64dbg-find-oep'); Repo = 'dariushoule/x64dbg-skills'
            Commit = ('a' * 40); TreeSha256 = ('b' * 64)
            ReviewedBy = 'david'; ReviewedAt = '2026-09-08'
            Reason = ''; Findings = @()
        }
        $ctx = @{ Config = $cfg; Inventory = $null; ServerResults = @()
            VerifyResults = @(); SkillResults = @($skillResult) }
        $null = Write-Manifest -Context $ctx -PhaseResults @()

        $got = @(Get-RecordedSkillResult -Config $cfg)
        $got.Count | Should -Be 1
        $got[0].Namespace | Should -Be 'x64dbg'
        $got[0].Status | Should -Be 'installed'
        $got[0].Installed | Should -BeTrue
        $got[0].Commit | Should -Be ('a' * 40)
        $got[0].TreeSha256 | Should -Be ('b' * 64)
        $got[0].SkillNames | Should -Be @('x64dbg-find-oep')
    }

    It 'returns nothing when the config has no skills key, even with a manifest present' {
        # 'skills' is an optional top-level key so a config written before this subsystem
        # still loads. Reading straight through it throws under Set-StrictMode, and phase
        # 6 calls this unconditionally - so an old config would take verification down.
        $state = Join-Path $TestDrive 'grs-nokey'
        $null = New-Item -ItemType Directory -Path $state -Force
        '{ "skills": [] }' | Set-Content -LiteralPath (Join-Path $state 'manifest.json')
        $cfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ stateRoot = $state } }
        @(Get-RecordedSkillResult -Config $cfg) | Should -BeNullOrEmpty
    }

    It 'returns nothing when the config declares no skill packs' {
        $cfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ stateRoot = (Join-Path $TestDrive 'grs-noskills') }
            skills = @() }
        @(Get-RecordedSkillResult -Config $cfg) | Should -BeNullOrEmpty
    }
}

Describe 'Get-RecordedAgentResult' {
    It 'returns nothing for a config with no agents key' {
        # StrictMode: the same defect Get-RecordedSkillResult hit.
        { Get-RecordedAgentResult -Config ([PSCustomObject]@{}) } | Should -Not -Throw
    }

    It 'replays name, level, servers and tool count from the manifest' {
        $cfg = [PSCustomObject]@{ agents = @([PSCustomObject]@{ name = 'verifier' }) }
        $man = [PSCustomObject]@{ agents = @([PSCustomObject]@{ name = 'verifier'
                    enabled = $true; level = 'read'; servers = @('pyghidra-mcp')
                    toolCount = 15; gate = 'pass'; disabledReason = '' }) }
        $r = Get-RecordedAgentResult -Config $cfg -Manifest $man
        $r[0].ToolCount | Should -Be 15
        $r[0].Level | Should -Be 'read'
    }

    It 'drops an agent the current config no longer declares' {
        $cfg = [PSCustomObject]@{ agents = @() }
        $man = [PSCustomObject]@{ agents = @([PSCustomObject]@{ name = 'gone'
                    enabled = $true; level = 'read'; servers = @(); toolCount = 1
                    gate = 'pass'; disabledReason = '' }) }
        @(Get-RecordedAgentResult -Config $cfg -Manifest $man).Count | Should -Be 0
    }
}

Describe 'Codex workspace manifest records' {
    BeforeEach {
        $Script:CwRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $Script:CwAgentRoot = Join-Path $Script:CwRoot 'agent'
        $Script:CwStateRoot = Join-Path $Script:CwRoot 'state'
        $null = New-Item -ItemType Directory -Path (Join-Path $Script:CwAgentRoot '.codex\agents') -Force
        $null = New-Item -ItemType Directory -Path $Script:CwStateRoot -Force
        $instruction = Join-Path $Script:CwAgentRoot 'AGENTS.md'
        [IO.File]::WriteAllText($instruction, '<!-- re-agent-managed -->')
        [IO.File]::WriteAllText((Join-Path $Script:CwAgentRoot '.codex\agents\static-analyst.toml'),
            @'
# re-agent-managed: codex-custom-agent v1
name = "static-analyst"
sandbox_mode = "workspace-write"
[mcp_servers."pyghidra-mcp"]
enabled = true
enabled_tools = ["decompile_function", "rename_function"]
[mcp_servers."pdbsql"]
enabled = false
enabled_tools = []
'@)
        [IO.File]::WriteAllText((Join-Path $Script:CwAgentRoot '.codex\agents\verifier.toml'),
            @'
# re-agent-managed: codex-custom-agent v1
name = "verifier"
sandbox_mode = "read-only"
[mcp_servers."mcp-windbg"]
enabled = true
enabled_tools = ["read_memory"]
[mcp_servers."pyghidra-mcp"]
enabled = true
enabled_tools = ["decompile_function"]
'@)
        $Script:CwConfig = [pscustomobject]@{
            version = 1
            paths = [pscustomobject]@{ agentRoot = $Script:CwAgentRoot
                stateRoot = $Script:CwStateRoot }
            mcpServers = @()
            skills = @([pscustomobject]@{ enabled = $true; namespace = 'fixture'
                    skills = @([pscustomobject]@{ name = 'alpha'; enabled = $true }) })
            agents = @(
                [pscustomobject]@{ name = 'static-analyst'; enabled = $true; level = 'write' },
                [pscustomobject]@{ name = 'verifier'; enabled = $true; level = 'read' })
        }
        $Script:CwContext = @{
            Config = $Script:CwConfig
            CodexWorkspaceConfiguration = [pscustomobject]@{
                Instruction = [pscustomobject]@{ Path = $instruction; Status = 'created'
                    Sha256 = ('a' * 64) }
                Agents = @(
                    [pscustomobject]@{ Name = 'static-analyst'; Enabled = $true
                        Path = (Join-Path $Script:CwAgentRoot '.codex\agents\static-analyst.toml')
                        Status = 'created'; OmittedServers = @(
                            [pscustomobject]@{ Agent = 'static-analyst'; Name = 'pdbsql'
                                Reason = 'legacy SSE is unsupported by Codex' },
                            [pscustomobject]@{ Agent = 'static-analyst'; Name = 'ghidrasql'
                                Reason = 'legacy SSE is unsupported by Codex' }) },
                    [pscustomobject]@{ Name = 'verifier'; Enabled = $true
                        Path = (Join-Path $Script:CwAgentRoot '.codex\agents\verifier.toml')
                        Status = 'created'; OmittedServers = @(
                            [pscustomobject]@{ Agent = 'verifier'; Name = 'pdbsql'
                                Reason = 'legacy SSE is unsupported by Codex' }) })
            }
            CodexSkillResults = @([pscustomobject]@{ CodexSkillRecords = @(
                        [pscustomobject]@{ Name = 'alpha'; Status = 'installed'
                            Sha256 = ('b' * 64); Path = (Join-Path $Script:CwAgentRoot '.agents\skills\alpha') }) })
        }
    }

    It 'records generated instructions, enabled skills, compatible agents, and exact SSE omissions' {
        $record = ConvertTo-CodexWorkspaceManifestRecord -Context $Script:CwContext
        $record.root | Should -Be $Script:CwAgentRoot
        $record.instructions.path | Should -Be (Join-Path $Script:CwAgentRoot 'AGENTS.md')
        $record.instructions.status | Should -Be 'installed'
        $record.instructions.sha256 | Should -Be ('a' * 64)
        @($record.skills).Count | Should -Be 1
        $record.skills[0].name | Should -Be 'alpha'
        $record.skills[0].sha256 | Should -Be ('b' * 64)
        @($record.agents).Count | Should -Be 2
        $static = @($record.agents | Where-Object name -eq 'static-analyst')[0]
        $static.servers | Should -Be @('pyghidra-mcp')
        $static.toolCount | Should -Be 2
        $verifier = @($record.agents | Where-Object name -eq 'verifier')[0]
        $verifier.servers | Should -Be @('mcp-windbg', 'pyghidra-mcp')
        $verifier.toolCount | Should -Be 2
        @($record.omittedServers | ForEach-Object { "$($_.name):$($_.reason)" }) |
            Should -Be @('ghidrasql:legacy SSE is unsupported by Codex',
                'pdbsql:legacy SSE is unsupported by Codex')
    }

    It 'serializes no Codex user configuration or secret-bearing preference' {
        $Script:CwContext.Config | Add-Member -NotePropertyName fixtureToken `
            -NotePropertyValue 'manifest-fixture-secret'
        $record = ConvertTo-CodexWorkspaceManifestRecord -Context $Script:CwContext
        $json = $record | ConvertTo-Json -Depth 12
        foreach ($forbidden in @('manifest-fixture-secret', 'Authorization', 'config.toml',
                'model =', 'model_reasoning_effort', 'approval_policy', 'login', 'memories',
                'plugins')) {
            $json | Should -Not -Match ([regex]::Escape($forbidden))
        }
        $json | Should -Match 'sandbox_mode'
    }

    It 'replays the optional workspace object and tolerates a pre-parity manifest' {
        $record = ConvertTo-CodexWorkspaceManifestRecord -Context $Script:CwContext
        [IO.File]::WriteAllText((Join-Path $Script:CwStateRoot 'codex-manifest.json'),
            ([ordered]@{ codexWorkspace = $record } | ConvertTo-Json -Depth 12))
        $replayed = Get-RecordedCodexWorkspaceResult -Config $Script:CwConfig `
            -ManifestName 'codex-manifest.json'
        $replayed.Instruction.Sha256 | Should -Be ('a' * 64)
        $replayed.Skills[0].Name | Should -Be 'alpha'
        $replayed.Agents[0].Servers.Count | Should -BeGreaterThan 0

        [IO.File]::WriteAllText((Join-Path $Script:CwStateRoot 'manifest.json'), '{"servers":[]}')
        { Get-RecordedCodexWorkspaceResult -Config $Script:CwConfig } | Should -Not -Throw
        @(Get-RecordedCodexWorkspaceResult -Config $Script:CwConfig).Count | Should -Be 0
    }

    It 'defaults missing fields in an early workspace record instead of throwing' {
        [IO.File]::WriteAllText((Join-Path $Script:CwStateRoot 'manifest.json'),
            '{"codexWorkspace":{"instructions":{},"skills":[{}],"agents":[{}]}}')
        { Get-RecordedCodexWorkspaceResult -Config $Script:CwConfig } | Should -Not -Throw
        $got = Get-RecordedCodexWorkspaceResult -Config $Script:CwConfig
        $got.Instruction.Sha256 | Should -Be ''
        $got.Skills[0].Name | Should -Be ''
        $got.Agents[0].Servers.Count | Should -Be 0
    }
}
