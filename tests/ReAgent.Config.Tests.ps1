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
