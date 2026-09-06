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
}
