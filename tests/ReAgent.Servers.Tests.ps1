BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Common.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Discovery.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Symbols.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Servers.psm1" -Force

    function Get-TestServer {
        param(
            $Name = 'pyghidra-mcp', $Kind = 'venv-http', $Transport = 'http',
            $Port = 8762, $Path = '/mcp', $Auth = 'none', $Enabled = $true
        )
        [PSCustomObject]@{
            name      = $Name; kind = $Kind; enabled = $Enabled
            transport = $Transport; bind = '127.0.0.1'; port = $Port
            path      = $Path; auth = $Auth
        }
    }
}

Describe 'New-ServerResult' {
    It 'carries the config fields through to the result' {
        $r = New-ServerResult -Server (Get-TestServer) -Status 'installed' -Version '0.2.5'
        $r.Name | Should -Be 'pyghidra-mcp'
        $r.Kind | Should -Be 'venv-http'
        $r.Port | Should -Be 8762
        $r.Version | Should -Be '0.2.5'
    }

    It 'treats installed and skipped as Installed, for .mcp.json generation' {
        (New-ServerResult -Server (Get-TestServer) -Status 'installed').Installed |
            Should -BeTrue
        (New-ServerResult -Server (Get-TestServer) -Status 'skipped').Installed |
            Should -BeTrue
    }

    It 'treats not-installed and failed as not Installed' {
        (New-ServerResult -Server (Get-TestServer) -Status 'not-installed').Installed |
            Should -BeFalse
        (New-ServerResult -Server (Get-TestServer) -Status 'failed').Installed |
            Should -BeFalse
    }

    It 'rejects a status outside the known set' {
        { New-ServerResult -Server (Get-TestServer) -Status 'banana' } |
            Should -Throw '*banana*'
    }

    It 'tolerates a server entry with no path, as stdio servers have' {
        $s = Get-TestServer -Transport 'stdio' -Port 0
        $s.PSObject.Properties.Remove('path')
        (New-ServerResult -Server $s -Status 'installed').Path | Should -Be ''
    }
}

Describe 'Get-VenvPackageVersion' {
    It 'returns null when the venv does not exist' {
        Get-VenvPackageVersion -VenvPath (Join-Path $TestDrive 'nope') -Package 'x' |
            Should -BeNullOrEmpty
    }

    It 'reads the version from importlib.metadata' {
        Mock -ModuleName ReAgent.Servers Test-Path { $true }
        Mock -ModuleName ReAgent.Servers Invoke-CommandLine { '0.2.5' }
        Get-VenvPackageVersion -VenvPath 'C:\v' -Package 'pyghidra-mcp' | Should -Be '0.2.5'
    }

    It 'returns null when the package is not installed' {
        Mock -ModuleName ReAgent.Servers Test-Path { $true }
        Mock -ModuleName ReAgent.Servers Invoke-CommandLine { throw 'PackageNotFoundError' }
        Get-VenvPackageVersion -VenvPath 'C:\v' -Package 'absent' | Should -BeNullOrEmpty
    }

    It 'ignores output that is not a version' {
        Mock -ModuleName ReAgent.Servers Test-Path { $true }
        Mock -ModuleName ReAgent.Servers Invoke-CommandLine { 'Traceback (most recent call last)' }
        Get-VenvPackageVersion -VenvPath 'C:\v' -Package 'x' | Should -BeNullOrEmpty
    }
}

Describe 'Install-VenvPackage' {
    It 'does nothing when the pinned version is already installed' {
        Mock -ModuleName ReAgent.Servers Get-VenvPackageVersion { '1.2.1' }
        Mock -ModuleName ReAgent.Servers Invoke-CommandLine { }
        Install-VenvPackage -VenvPath 'C:\v' -Package 'mcp-windbg' -Pin '1.2.1' `
            -UvPath 'uv.exe' -Confirm:$false | Should -Be '1.2.1'
        Should -Invoke -ModuleName ReAgent.Servers Invoke-CommandLine -Times 0 -Exactly
    }

    It 'creates the venv and installs when nothing is there' {
        Mock -ModuleName ReAgent.Servers Get-VenvPackageVersion { $null }
        Mock -ModuleName ReAgent.Servers Test-Path { $false }
        Mock -ModuleName ReAgent.Servers Invoke-CommandLine { }
        Install-VenvPackage -VenvPath 'C:\v' -Package 'mcp-windbg' -Pin '1.2.1' `
            -UvPath 'uv.exe' -Confirm:$false | Out-Null
        # one 'uv venv', one 'uv pip install'
        Should -Invoke -ModuleName ReAgent.Servers Invoke-CommandLine -Times 2 -Exactly
    }

    It 'reuses an existing venv rather than recreating it' {
        Mock -ModuleName ReAgent.Servers Get-VenvPackageVersion { $null }
        Mock -ModuleName ReAgent.Servers Test-Path { $true }
        Mock -ModuleName ReAgent.Servers Invoke-CommandLine { }
        Install-VenvPackage -VenvPath 'C:\v' -Package 'mcp-windbg' -Pin '1.2.1' `
            -UvPath 'uv.exe' -Confirm:$false | Out-Null
        Should -Invoke -ModuleName ReAgent.Servers Invoke-CommandLine -Times 1 -Exactly
    }

    It 'upgrades when the installed version is not the pin' {
        Mock -ModuleName ReAgent.Servers Get-VenvPackageVersion { '1.0.0' }
        Mock -ModuleName ReAgent.Servers Test-Path { $true }
        Mock -ModuleName ReAgent.Servers Invoke-CommandLine { }
        Install-VenvPackage -VenvPath 'C:\v' -Package 'mcp-windbg' -Pin '1.2.1' `
            -UvPath 'uv.exe' -Confirm:$false | Out-Null
        Should -Invoke -ModuleName ReAgent.Servers Invoke-CommandLine -Times 1 -Exactly
    }
}

Describe 'Write-ServerLauncher' {
    It 'sets each environment variable before invoking the executable' {
        $p = Join-Path $TestDrive 'launch.cmd'
        Write-ServerLauncher -Path $p -Executable 'C:\v\Scripts\pyghidra-mcp.exe' `
            -Arguments @('--transport', 'streamable-http') `
            -Environment @{ GHIDRA_INSTALL_DIR = 'C:\ghidra' } | Out-Null
        $text = Get-Content $p -Raw
        $text | Should -BeLike '*set "GHIDRA_INSTALL_DIR=C:\ghidra"*'
        $text | Should -BeLike '*pyghidra-mcp.exe" --transport streamable-http*'
    }

    It 'quotes arguments that contain spaces' {
        $p = Join-Path $TestDrive 'launch2.cmd'
        Write-ServerLauncher -Path $p -Executable 'x.exe' `
            -Arguments @('--project-path', 'C:\re\my cases') | Out-Null
        (Get-Content $p -Raw) | Should -BeLike '*"C:\re\my cases"*'
    }

    It 'creates the parent directory' {
        $p = Join-Path $TestDrive 'deep\er\launch.cmd'
        Write-ServerLauncher -Path $p -Executable 'x.exe' | Out-Null
        Test-Path $p | Should -BeTrue
    }

    It 'is byte-identical when regenerated with the same inputs' {
        # Idempotency: a second run must not produce a different file.
        $a = Join-Path $TestDrive 'i1.cmd'
        $b = Join-Path $TestDrive 'i2.cmd'
        $env = @{ B = '2'; A = '1' }
        Write-ServerLauncher -Path $a -Executable 'x.exe' -Arguments @('-p') -Environment $env |
            Out-Null
        Write-ServerLauncher -Path $b -Executable 'x.exe' -Arguments @('-p') -Environment $env |
            Out-Null
        (Get-Content $a -Raw) | Should -Be (Get-Content $b -Raw)
    }

    It 'orders environment variables deterministically regardless of hashtable order' {
        $a = Join-Path $TestDrive 'o1.cmd'
        $b = Join-Path $TestDrive 'o2.cmd'
        Write-ServerLauncher -Path $a -Executable 'x.exe' -Environment @{ A = '1'; B = '2' } |
            Out-Null
        Write-ServerLauncher -Path $b -Executable 'x.exe' -Environment @{ B = '2'; A = '1' } |
            Out-Null
        (Get-Content $a -Raw) | Should -Be (Get-Content $b -Raw)
    }
}

Describe 'Install-McpServer dispatch' {
    BeforeAll {
        $Script:Cfg = [PSCustomObject]@{
            paths   = [PSCustomObject]@{
                toolRoot = 'C:\re'; agentRoot = 'C:\re\agent'; symbolCache = 'C:\re\symbols'
            }
            symbols = [PSCustomObject]@{ server = 'https://msdl/symbols' }
        }
        $Script:Inv = [PSCustomObject]@{
            Uv = 'uv.exe'; Cdb = 'C:\cdb.exe'; GhidraRoot = 'C:\ghidra'
        }
    }

    It 'reports a disabled server as not-installed rather than installing it' {
        $s = Get-TestServer -Name 'ghidramcp' -Kind 'gui-plugin-http' -Enabled $false
        $r = Install-McpServer -Server $s -Config $Script:Cfg -Inventory $Script:Inv
        $r.Status | Should -Be 'not-installed'
        $r.Reason | Should -BeLike '*Disabled*'
    }

    It 'reports a kind with no handler as failed, naming the kind' {
        $s = Get-TestServer -Name 'x64dbg-x64' -Kind 'plugin-inproc'
        $r = Install-McpServer -Server $s -Config $Script:Cfg -Inventory $Script:Inv
        $r.Status | Should -Be 'failed'
        $r.Reason | Should -BeLike '*plugin-inproc*'
    }

    It 'turns a handler exception into a failed result instead of throwing' {
        Mock -ModuleName ReAgent.Servers Install-VenvHttpServer { throw 'network died' }
        $r = Install-McpServer -Server (Get-TestServer) -Config $Script:Cfg -Inventory $Script:Inv
        $r.Status | Should -Be 'failed'
        $r.Reason | Should -BeLike '*network died*'
    }
}

Describe 'Install-VenvStdioServer' {
    BeforeAll {
        $Script:StdioCfg = [PSCustomObject]@{
            paths   = [PSCustomObject]@{ toolRoot = 'C:\re'; symbolCache = 'C:\re\symbols' }
            symbols = [PSCustomObject]@{ server = 'https://msdl/symbols' }
        }
        $Script:StdioSrv = [PSCustomObject]@{
            name      = 'mcp-windbg'; kind = 'venv-stdio'; enabled = $true
            transport = 'stdio'; bind = '127.0.0.1'; port = 0; auth = 'none'
            source    = [PSCustomObject]@{ package = 'mcp-windbg'; pin = '1.2.1' }
        }
    }

    It 'refuses to install without cdb, and says how to get it' {
        $inv = [PSCustomObject]@{ Uv = 'uv.exe'; Cdb = $null; GhidraRoot = 'C:\ghidra' }
        $r = Install-VenvStdioServer -Server $Script:StdioSrv -Config $Script:StdioCfg -Inventory $inv
        $r.Status | Should -Be 'not-installed'
        $r.Reason | Should -BeLike '*WinDbg*'
    }

    It 'passes cdb explicitly rather than trusting auto-detection' {
        # The WinDbg MSIX package that ships cdb.exe is not on PATH, so the
        # server's own auto-detection cannot find it.
        Mock -ModuleName ReAgent.Servers Install-VenvPackage { '1.2.1' }
        $inv = [PSCustomObject]@{ Uv = 'uv.exe'; Cdb = 'C:\pkg\amd64\cdb.exe'; GhidraRoot = 'C:\g' }
        $r = Install-VenvStdioServer -Server $Script:StdioSrv -Config $Script:StdioCfg -Inventory $inv
        $r.Command.Arguments | Should -Contain '--cdb-path'
        $r.Command.Arguments | Should -Contain 'C:\pkg\amd64\cdb.exe'
    }

    It 'launches via the venv interpreter, never the system one' {
        Mock -ModuleName ReAgent.Servers Install-VenvPackage { '1.2.1' }
        $inv = [PSCustomObject]@{ Uv = 'uv.exe'; Cdb = 'C:\cdb.exe'; GhidraRoot = 'C:\g' }
        $r = Install-VenvStdioServer -Server $Script:StdioSrv -Config $Script:StdioCfg -Inventory $inv
        $r.Command.Executable | Should -BeLike '*\mcp\venvs\mcp-windbg\Scripts\python.exe'
        $r.Command.Arguments | Should -Contain 'mcp_windbg'
    }

    It 'hands the server the Phase 2 symbol path' {
        Mock -ModuleName ReAgent.Servers Install-VenvPackage { '1.2.1' }
        $inv = [PSCustomObject]@{ Uv = 'uv.exe'; Cdb = 'C:\cdb.exe'; GhidraRoot = 'C:\g' }
        $r = Install-VenvStdioServer -Server $Script:StdioSrv -Config $Script:StdioCfg -Inventory $inv
        $r.Command.Env._NT_SYMBOL_PATH | Should -Be 'SRV*C:\re\symbols*https://msdl/symbols'
    }
}

Describe 'Install-VenvHttpServer' {
    BeforeAll {
        $Script:HttpCfg = [PSCustomObject]@{
            paths   = [PSCustomObject]@{
                toolRoot = 'C:\re'; agentRoot = 'C:\re\agent'; symbolCache = 'C:\re\symbols'
            }
            symbols = [PSCustomObject]@{ server = 'https://msdl/symbols' }
        }
        $Script:HttpSrv = [PSCustomObject]@{
            name      = 'pyghidra-mcp'; kind = 'venv-http'; enabled = $true
            transport = 'http'; bind = '127.0.0.1'; port = 8762; path = '/mcp'
            auth      = 'none'; scheduledTask = 'ReLab-pyghidra-mcp'
            source    = [PSCustomObject]@{ package = 'pyghidra-mcp'; pin = '0.2.5' }
        }
    }

    BeforeEach {
        Mock -ModuleName ReAgent.Servers Install-VenvPackage { '0.2.5' }
        Mock -ModuleName ReAgent.Servers Invoke-ChromaPrewarm { }
        Mock -ModuleName ReAgent.Servers Write-ServerLauncher { 'C:\re\mcp\launch-pyghidra-mcp.cmd' }
        Mock -ModuleName ReAgent.Servers Register-ServerScheduledTask { $true }
    }

    It 'refuses to install without Ghidra' {
        $inv = [PSCustomObject]@{ Uv = 'uv.exe'; GhidraRoot = $null }
        $r = Install-VenvHttpServer -Server $Script:HttpSrv -Config $Script:HttpCfg -Inventory $inv
        $r.Status | Should -Be 'not-installed'
        $r.Reason | Should -BeLike '*Ghidra*'
    }

    It 'runs over streamable-http, not stdio' {
        # stdio kills its symbol loading: ghidrecomp prints to stdout, which IS
        # the MCP channel, and analysis dies while the handshake still succeeds.
        $inv = [PSCustomObject]@{ Uv = 'uv.exe'; GhidraRoot = 'C:\ghidra' }
        $r = Install-VenvHttpServer -Server $Script:HttpSrv -Config $Script:HttpCfg -Inventory $inv
        $r.Command.Arguments | Should -Contain 'streamable-http'
        $r.Command.Arguments | Should -Contain '8762'
    }

    It 'binds loopback only' {
        $inv = [PSCustomObject]@{ Uv = 'uv.exe'; GhidraRoot = 'C:\ghidra' }
        $r = Install-VenvHttpServer -Server $Script:HttpSrv -Config $Script:HttpCfg -Inventory $inv
        $r.Command.Arguments | Should -Contain '127.0.0.1'
        $r.Command.Arguments | Should -Not -Contain '0.0.0.0'
    }

    It 'sets GHIDRA_INSTALL_DIR, without which the server will not start' {
        $inv = [PSCustomObject]@{ Uv = 'uv.exe'; GhidraRoot = 'C:\ghidra_12.1.2' }
        $r = Install-VenvHttpServer -Server $Script:HttpSrv -Config $Script:HttpCfg -Inventory $inv
        $r.Command.Env.GHIDRA_INSTALL_DIR | Should -Be 'C:\ghidra_12.1.2'
    }

    It 'registers the scheduled task that owns the process' {
        $inv = [PSCustomObject]@{ Uv = 'uv.exe'; GhidraRoot = 'C:\ghidra' }
        Install-VenvHttpServer -Server $Script:HttpSrv -Config $Script:HttpCfg -Inventory $inv |
            Out-Null
        Should -Invoke -ModuleName ReAgent.Servers Register-ServerScheduledTask -Times 1 -Exactly
    }

    It 'pre-warms the chromadb model so the first tool call does not look like a hang' {
        $inv = [PSCustomObject]@{ Uv = 'uv.exe'; GhidraRoot = 'C:\ghidra' }
        Install-VenvHttpServer -Server $Script:HttpSrv -Config $Script:HttpCfg -Inventory $inv |
            Out-Null
        Should -Invoke -ModuleName ReAgent.Servers Invoke-ChromaPrewarm -Times 1 -Exactly
    }
}

Describe 'Register-ServerScheduledTask' {
    It 'does nothing when the registered action already matches' {
        Mock -ModuleName ReAgent.Servers Get-ScheduledTaskActionText { 'C:\re\mcp\launch.cmd' }
        Register-ServerScheduledTask -Name 'T' -LauncherPath 'C:\re\mcp\launch.cmd' `
            -Confirm:$false | Should -BeFalse
    }
}

Describe 'Invoke-ChromaPrewarm' {
    It 'warns rather than failing when the pre-warm errors' {
        Mock -ModuleName ReAgent.Servers Invoke-CommandLine { throw 'no network' }
        { Invoke-ChromaPrewarm -VenvPath 'C:\v' } | Should -Not -Throw
    }
}

Describe 'New-TestCrashDump' {
    It 'leaves an existing dump alone' {
        $p = Join-Path $TestDrive 'test.dmp'
        'x' | Set-Content $p
        Mock -ModuleName ReAgent.Servers Invoke-CommandLine { }
        New-TestCrashDump -CdbPath 'cdb.exe' -OutputPath $p -Confirm:$false | Should -Be $p
        Should -Invoke -ModuleName ReAgent.Servers Invoke-CommandLine -Times 0 -Exactly
    }

    It 'throws a specific error when cdb produces nothing' {
        Mock -ModuleName ReAgent.Servers Invoke-CommandLine { }
        { New-TestCrashDump -CdbPath 'cdb.exe' `
                -OutputPath (Join-Path $TestDrive 'never.dmp') -Confirm:$false } |
            Should -Throw '*did not produce a dump*'
    }
}

Describe 'Install-AllMcpServer' {
    It 'returns one result per configured server, whatever happens to each' {
        $cfg = [PSCustomObject]@{
            paths      = [PSCustomObject]@{ toolRoot = 'C:\re'; agentRoot = 'C:\re\agent' }
            mcpServers = @(
                (Get-TestServer -Name 'a' -Enabled $false),
                (Get-TestServer -Name 'b' -Kind 'plugin-inproc')
            )
        }
        $r = @(Install-AllMcpServer -Config $cfg -Inventory ([PSCustomObject]@{ Uv = 'uv' }))
        $r.Count | Should -Be 2
        $r[0].Status | Should -Be 'not-installed'
        $r[1].Status | Should -Be 'failed'
    }

    It 'does not let one server failure stop the others' {
        $cfg = [PSCustomObject]@{
            paths      = [PSCustomObject]@{ toolRoot = 'C:\re'; agentRoot = 'C:\re\agent' }
            mcpServers = @(
                (Get-TestServer -Name 'boom' -Kind 'plugin-inproc'),
                (Get-TestServer -Name 'fine' -Enabled $false)
            )
        }
        { Install-AllMcpServer -Config $cfg -Inventory ([PSCustomObject]@{ Uv = 'uv' }) } |
            Should -Not -Throw
    }
}
