BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Common.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Tokens.psm1" -Force
}

Describe 'New-BearerToken' {
    It 'returns 64 hex characters by default' {
        New-BearerToken | Should -Match '^[0-9a-f]{64}$'
    }
    It 'returns 32 hex characters at 16 bytes, matching the x64dbg plugin format' {
        New-BearerToken -ByteCount 16 | Should -Match '^[0-9a-f]{32}$'
    }
    It 'returns a different value each call' {
        (New-BearerToken) | Should -Not -Be (New-BearerToken)
    }
}

Describe 'Save-ServerToken and Get-ServerToken' {
    It 'round-trips a token through disk' {
        Save-ServerToken -Name 'binaryninja' -Token 'abc123' -TokenRoot $TestDrive
        Get-ServerToken -Name 'binaryninja' -TokenRoot $TestDrive | Should -Be 'abc123'
    }
    It 'returns null for a server with no stored token' {
        Get-ServerToken -Name 'nothing' -TokenRoot $TestDrive | Should -BeNullOrEmpty
    }
    It 'creates the token directory when it does not exist' {
        $root = Join-Path $TestDrive 'tokens-new'
        Save-ServerToken -Name 's' -Token 't' -TokenRoot $root
        Test-Path (Join-Path $root 's.token') | Should -BeTrue
    }
}

Describe 'Get-OrNewServerToken' {
    It 'generates and persists a token when none exists' {
        $root = Join-Path $TestDrive 'gon1'
        $t = Get-OrNewServerToken -Name 'srv' -TokenRoot $root
        $t | Should -Match '^[0-9a-f]{64}$'
        Get-ServerToken -Name 'srv' -TokenRoot $root | Should -Be $t
    }

    It 'reuses an existing token rather than rotating it' {
        # Regenerating breaks whatever server is already running with the old
        # value, so a re-run must never rotate.
        $root = Join-Path $TestDrive 'gon2'
        $first = Get-OrNewServerToken -Name 'srv' -TokenRoot $root
        Get-OrNewServerToken -Name 'srv' -TokenRoot $root | Should -Be $first
    }

    It 'honours a shorter byte count for a new token' {
        $root = Join-Path $TestDrive 'gon3'
        Get-OrNewServerToken -Name 'x64dbg-x64' -TokenRoot $root -ByteCount 16 |
            Should -Match '^[0-9a-f]{32}$'
    }
}

Describe 'Get-X64dbgToken' {
    It 'reads the AuthToken field the plugin actually writes' {
        $p = Join-Path $TestDrive 'mcp_config.json'
        '{ "IpAddress": "127.0.0.1", "Port": 9094, "AutoStart": true,
           "AuthToken": "plugin-owned-token" }' | Set-Content $p
        Get-X64dbgToken -McpConfigPath $p | Should -Be 'plugin-owned-token'
    }

    It 'returns null for a lowercase token field, which is NOT what the plugin writes' {
        $p = Join-Path $TestDrive 'wrongcase.json'
        '{ "token": "nope" }' | Set-Content $p
        Get-X64dbgToken -McpConfigPath $p | Should -BeNullOrEmpty
    }

    It 'returns null when the plugin has not run yet' {
        Get-X64dbgToken -McpConfigPath (Join-Path $TestDrive 'absent.json') |
            Should -BeNullOrEmpty
    }

    It 'returns null rather than throwing on a corrupt config' {
        $p = Join-Path $TestDrive 'corrupt.json'
        'not json' | Set-Content $p
        Get-X64dbgToken -McpConfigPath $p | Should -BeNullOrEmpty
    }
}
