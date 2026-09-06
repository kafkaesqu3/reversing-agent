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
            param($Reason = '', $Findings = @())
            [PSCustomObject]@{
                Namespace = 'x64dbg'; Status = 'installed'; Installed = $true
                SkillNames = @('x64dbg-find-oep'); Repo = 'dariushoule/x64dbg-skills'
                Commit = ('a' * 40); TreeSha256 = ('b' * 64)
                ReviewedBy = 'david'; ReviewedAt = '2026-09-08'
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

    It 'writes an empty skills array without a SkillResults key in the context' {
        # Write-Manifest always runs, including after failures; a context a caller
        # built without SkillResults must not crash it.
        $cfg = New-MCfg -StateRoot (Join-Path $TestDrive 'wm-noskillresults')
        $ctx = @{ Config = $cfg; Inventory = $null; ServerResults = @(); VerifyResults = @() }
        (Get-WrittenManifest -Context $ctx).skills.Count | Should -Be 0
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

    It 'returns nothing when the config declares no skill packs' {
        $cfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ stateRoot = (Join-Path $TestDrive 'grs-noskills') }
            skills = @() }
        @(Get-RecordedSkillResult -Config $cfg) | Should -BeNullOrEmpty
    }
}
