BeforeAll {
    foreach ($name in @('Common', 'Tokens', 'Discovery', 'Verify', 'Codex')) {
        Import-Module "$PSScriptRoot/../src/ReAgent.$name.psm1" -Force
    }
    $script:codexPath = (Get-Command codex -ErrorAction Stop).Source
    function Get-CodexFixture {
        [PSCustomObject]@{ Name = 'x64dbg-x64'; Transport = 'http'; Bind = '127.0.0.1'
            Port = 9094; Path = '/'; Auth = 'none'; Enabled = $true; Installed = $true
            Command = $null }
    }
}

Describe 'Codex configuration' {
    It 'merges with existing settings, replaces owned servers, and is byte-idempotent' {
        $target = Join-Path $TestDrive 'merge'
        $null = New-Item -ItemType Directory $target
        $path = Join-Path $target 'config.toml'
        $original = "# analyst settings`nmodel = `"example-model`"`n[mcp_servers.unrelated]`ncommand = `"other.exe`"`n[mcp_servers.'x64dbg-x64']`nurl = `"http://localhost:1/`"`n"
        [IO.File]::WriteAllText($path, $original)
        $params = @{ CodexHome = $target; CodexPath = $script:codexPath
            ServerResults = @((Get-CodexFixture)); ManagedNames = @('x64dbg-x64'); TokenRoot = $TestDrive }
        Write-CodexConfiguration @params
        $first = [IO.File]::ReadAllText($path)
        $first | Should -Match '# analyst settings'
        $first | Should -Match 'example-model'
        $first | Should -Match 'other.exe'
        $first | Should -Match 'http://127.0.0.1:9094/'
        $first | Should -Not -Match 'localhost:1'
        @(Get-ChildItem $target -Filter '*.bak').Count | Should -Be 1
        Write-CodexConfiguration @params
        [IO.File]::ReadAllText($path) | Should -BeExactly $first
        @(Get-ChildItem $target -Filter '*.bak').Count | Should -Be 1
    }

    It 'refuses malformed TOML without modifying it' {
        $target = Join-Path $TestDrive 'invalid'
        $null = New-Item -ItemType Directory $target
        $path = Join-Path $target 'config.toml'
        [IO.File]::WriteAllText($path, '[broken')
        { Write-CodexConfiguration -CodexHome $target -CodexPath $script:codexPath `
            -ServerResults @((Get-CodexFixture)) -ManagedNames @('x64dbg-x64') -TokenRoot $TestDrive } | Should -Throw
        [IO.File]::ReadAllText($path) | Should -BeExactly '[broken'
    }

    It 'does not create a destination under WhatIf' {
        $target = Join-Path $TestDrive 'preview'
        Write-CodexConfiguration -CodexHome $target -CodexPath $script:codexPath `
            -ServerResults @((Get-CodexFixture)) -ManagedNames @('x64dbg-x64') -TokenRoot $TestDrive -WhatIf
        Test-Path $target | Should -BeFalse
    }

    It 'rejects missing bearer tokens rather than registering an unauthenticated server' {
        $server = Get-CodexFixture
        $server.Auth = 'bearer-preseeded'
        { New-CodexServerTable -Result $server -TokenRoot $TestDrive } | Should -Throw '*token*'
    }

    It 'uses stored bearer tokens and leaves unauthenticated HTTP servers without headers' {
        $server = Get-CodexFixture
        (New-CodexServerTable -Result $server -TokenRoot $TestDrive) | Should -Not -Match 'Authorization'
        [IO.File]::WriteAllText((Join-Path $TestDrive 'x64dbg-x64.token'), 'test-token')
        $server.Auth = 'bearer-preseeded'
        (New-CodexServerTable -Result $server -TokenRoot $TestDrive) | Should -Match 'Bearer test-token'
    }

    It 'does not label legacy SSE as streamable HTTP' {
        $server = Get-CodexFixture
        $server.Transport = 'sse'
        { New-CodexServerTable -Result $server -TokenRoot $TestDrive } | Should -Throw '*SSE*'
    }

    It 'round trips Windows stdio paths, arguments and environment through Codex' {
        $server = Get-CodexFixture
        $server.Name = 'mcp-windbg'
        $server.Transport = 'stdio'
        $server.Command = @{ Executable = 'C:\space dir\python.exe'
            Arguments = @('-m', 'mcp_windbg', '--cdb-path', 'C:\debug tools\cdb.exe')
            Env = @{ _NT_SYMBOL_PATH = 'SRV*C:\symbols*https://msdl.microsoft.com/download/symbols' } }
        $target = Join-Path $TestDrive 'stdio'
        Write-CodexConfiguration -CodexHome $target -CodexPath $script:codexPath `
            -ServerResults @($server) -ManagedNames @('mcp-windbg') -TokenRoot $TestDrive
        $entries = @(Invoke-CodexConfigurationCommand -CodexHome $target -CodexPath $script:codexPath -Arguments @('mcp', 'list', '--json') | ConvertFrom-Json)
        $entries[0].transport.command | Should -BeExactly $server.Command.Executable
        $entries[0].transport.args[3] | Should -BeExactly $server.Command.Arguments[3]
        $entries[0].transport.env._NT_SYMBOL_PATH | Should -BeExactly $server.Command.Env._NT_SYMBOL_PATH
    }

    It 'does not require Claude when preflighting Codex' {
        $inventory = [PSCustomObject]@{ ClaudeCode = $null }
        @(Test-Preflight -Inventory $inventory -VerifyOnly -Agent Codex -CodexPath $script:codexPath).Count | Should -Be 0
        @(Test-Preflight -Inventory $inventory -VerifyOnly -Agent Codex).Count | Should -Be 1
    }

    It 'fails verification when a registered server points to the wrong endpoint' {
        $target = Join-Path $TestDrive 'wrong-url'
        $null = New-Item -ItemType Directory $target
        [IO.File]::WriteAllText((Join-Path $target 'config.toml'), "[mcp_servers.'x64dbg-x64']`nurl = `"http://localhost:1/`"`n")
        $server = Get-CodexFixture
        $config = [PSCustomObject]@{ paths = @{ stateRoot = $target }; mcpServers = @($server) }
        Mock Get-ServerCheck -ModuleName ReAgent.Codex { @() }
        $checks = @(Invoke-CodexVerification -Config $config -ServerResults @($server) `
            -CodexPath $script:codexPath -CodexHome $target)
        $checks[0].Status | Should -Be 'fail'
    }

    It 'removes stale owned entries when a server is no longer installed' {
        $target = Join-Path $TestDrive 'stale'
        $null = New-Item -ItemType Directory $target
        [IO.File]::WriteAllText((Join-Path $target 'config.toml'), "[mcp_servers.'x64dbg-x64']`nurl = `"http://localhost:1/`"`n")
        $server = Get-CodexFixture
        $server.Installed = $false
        Write-CodexConfiguration -CodexHome $target -CodexPath $script:codexPath `
            -ServerResults @($server) -ManagedNames @($server.Name) -TokenRoot $TestDrive
        [IO.File]::ReadAllText((Join-Path $target 'config.toml')) | Should -Not -Match 'localhost:1'
    }

    It 'fails verification for incorrect Codex bearer headers: <Header>' -ForEach @(
        @{ Header = 'Authorization = "Bearer stale-token"' },
        @{ Header = 'Unrelated = "value"' }
    ) {
        $target = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory $target
        $tokens = Join-Path $target 'mcp\tokens'
        $null = New-Item -ItemType Directory $tokens -Force
        [IO.File]::WriteAllText((Join-Path $tokens 'x64dbg-x64.token'), 'current-token')
        [IO.File]::WriteAllText((Join-Path $target 'config.toml'), "[mcp_servers.'x64dbg-x64']`nurl = `"http://127.0.0.1:9094/`"`n[mcp_servers.'x64dbg-x64'.http_headers]`n$Header`n")
        $server = Get-CodexFixture
        $server.Auth = 'bearer-preseeded'
        $config = [PSCustomObject]@{ paths = @{ stateRoot = $target; toolRoot = $target }; mcpServers = @($server) }
        Mock Get-ServerCheck -ModuleName ReAgent.Codex { @() }
        $checks = @(Invoke-CodexVerification -Config $config -ServerResults @($server) `
            -CodexPath $script:codexPath -CodexHome $target)
        $checks[0].Status | Should -Be 'fail'
        $checks[0].Detail | Should -Not -Match 'current-token|stale-token'
    }

    It 'fails verification when Codex lost the stdio symbol environment' {
        $target = Join-Path $TestDrive 'lost-env'
        $null = New-Item -ItemType Directory $target
        [IO.File]::WriteAllText((Join-Path $target 'config.toml'), "[mcp_servers.'mcp-windbg']`ncommand = 'C:\python.exe'`nargs = []`n")
        $server = Get-CodexFixture
        $server.Name = 'mcp-windbg'
        $server.Transport = 'stdio'
        $server.Command = @{ Executable = 'C:\python.exe'; Arguments = @(); Env = @{ _NT_SYMBOL_PATH = 'expected-symbols' } }
        $config = [PSCustomObject]@{ paths = @{ stateRoot = $target }; mcpServers = @($server) }
        Mock Get-ServerCheck -ModuleName ReAgent.Codex { @() }
        $checks = @(Invoke-CodexVerification -Config $config -ServerResults @($server) `
            -CodexPath $script:codexPath -CodexHome $target)
        $checks[0].Status | Should -Be 'fail'
    }
}
