BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Common.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Discovery.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Symbols.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Tokens.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Json.psm1" -Force
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
            X64dbgRoot = $null; BinaryNinjaRoot = $null; BinaryNinjaMcpCapable = $false
        }
    }

    It 'reports a disabled server as not-installed rather than installing it' {
        $s = Get-TestServer -Name 'ghidramcp' -Kind 'gui-plugin-http' -Enabled $false
        $r = Install-McpServer -Server $s -Config $Script:Cfg -Inventory $Script:Inv
        $r.Status | Should -Be 'not-installed'
        $r.Reason | Should -BeLike '*Disabled*'
    }

    It 'reports a kind with no handler as failed, naming the kind' {
        $s = Get-TestServer -Name 'mystery' -Kind 'not-a-real-kind'
        $r = Install-McpServer -Server $s -Config $Script:Cfg -Inventory $Script:Inv
        $r.Status | Should -Be 'failed'
        $r.Reason | Should -BeLike '*not-a-real-kind*'
    }

    It 'reports plugin-inproc as not-installed when x64dbg is absent' {
        $s = Get-TestServer -Name 'x64dbg-x64' -Kind 'plugin-inproc'
        $inv = [PSCustomObject]@{ Uv = 'uv.exe'; X64dbgRoot = $null }
        $r = Install-McpServer -Server $s -Config $Script:Cfg -Inventory $inv
        $r.Status | Should -Be 'not-installed'
        $r.Reason | Should -BeLike '*x64dbg*'
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
        Mock -ModuleName ReAgent.Servers New-TestCrashDump { 'C:\re\scratch\test.dmp' }
    }

    It 'creates the dump the tier-1 WinDbg check needs' {
        # No caller meant no dump, and the check reported not-testable with
        # "phase 3 creates it" - naming a step that never ran.
        Mock -ModuleName ReAgent.Servers Install-VenvPackage { '1.2.1' }
        $inv = [PSCustomObject]@{ Uv = 'uv.exe'; Cdb = 'C:\cdb.exe'; GhidraRoot = 'C:\g' }
        Install-VenvStdioServer -Server $Script:StdioSrv -Config $Script:StdioCfg `
            -Inventory $inv | Out-Null
        Should -Invoke New-TestCrashDump -ModuleName ReAgent.Servers -Times 1 `
            -ParameterFilter { $OutputPath -eq 'C:\re\scratch\test.dmp' -and $CdbPath -eq 'C:\cdb.exe' }
    }

    It 'still installs when the dump cannot be created' {
        Mock -ModuleName ReAgent.Servers Install-VenvPackage { '1.2.1' }
        Mock -ModuleName ReAgent.Servers New-TestCrashDump { throw 'cdb refused' }
        $inv = [PSCustomObject]@{ Uv = 'uv.exe'; Cdb = 'C:\cdb.exe'; GhidraRoot = 'C:\g' }
        (Install-VenvStdioServer -Server $Script:StdioSrv -Config $Script:StdioCfg `
                -Inventory $inv).Status | Should -Be 'installed'
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

    It 'terminates the debuggee rather than detaching from it' {
        # 'qd' leaves cmd.exe alive holding the inherited stdout pipe, and the
        # caller blocks on the read long after the dump is complete.
        $p = Join-Path $TestDrive 'terminates.dmp'
        Mock -ModuleName ReAgent.Servers Invoke-CommandLine { 'x' | Set-Content $p }
        New-TestCrashDump -CdbPath 'cdb.exe' -OutputPath $p -Confirm:$false | Out-Null
        Should -Invoke -ModuleName ReAgent.Servers Invoke-CommandLine -Times 1 `
            -ParameterFilter { ($Arguments -join ' ') -notmatch ';qd' -and
                ($Arguments -join ' ') -match ';q(\s|$)' }
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

Describe 'Write-X64dbgPreseed' {
    It 'writes the exact field names and casing the plugin reads' {
        $p = Join-Path $TestDrive 'mcp_config.json'
        Write-X64dbgPreseed -ConfigPath $p -Bind '127.0.0.1' -Port 9094 `
            -Token 'aabb' -Confirm:$false
        $c = Get-Content $p -Raw | ConvertFrom-Json
        $c.IpAddress | Should -Be '127.0.0.1'
        $c.Port | Should -Be 9094
        $c.AutoStart | Should -BeTrue
        $c.AuthToken | Should -Be 'aabb'
    }

    It 'round-trips through Get-X64dbgToken' {
        $p = Join-Path $TestDrive 'rt.json'
        Write-X64dbgPreseed -ConfigPath $p -Bind '127.0.0.1' -Port 9095 `
            -Token 'deadbeef' -Confirm:$false
        Get-X64dbgToken -McpConfigPath $p | Should -Be 'deadbeef'
    }

    It 'refuses to seed a non-loopback bind' {
        # The plugin README documents a 0.0.0.0 default. Seeding that would
        # expose a debugger control channel on every adapter attached later.
        { Write-X64dbgPreseed -ConfigPath (Join-Path $TestDrive 'x.json') `
                -Bind '0.0.0.0' -Port 9094 -Token 't' -Confirm:$false } |
            Should -Throw '*0.0.0.0*'
    }
}

Describe 'Get-X64dbgConfigPath' {
    It 'returns both candidate locations, because upstream contradicts itself' {
        $paths = Get-X64dbgConfigPath -ReleaseRoot 'C:\Tools\x64dbg\release' -Arch 'x64'
        $paths[0] | Should -Be 'C:\Tools\x64dbg\release\x64\mcp_config.json'
        $paths[1] | Should -Be 'C:\Tools\x64dbg\release\x64\plugins\mcp_config.json'
    }

    It 'rejects an architecture that is not x32 or x64' {
        { Get-X64dbgConfigPath -ReleaseRoot 'C:\x' -Arch 'arm64' } | Should -Throw
    }
}

Describe 'Get-VerifiedRelease' {
    BeforeAll {
        $Script:RelCfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ toolRoot = $TestDrive }
        }
        function Get-RelServer {
            param($Sha = 'PIN-ME', $Asset = 'a.zip')
            [PSCustomObject]@{
                name   = 'x64dbg-x64'
                source = [PSCustomObject]@{
                    repo   = 'duty1g/x64dbg-mcp-server'; pin = 'v1.3'
                    sha256 = [PSCustomObject]@{ $Asset = $Sha }
                }
            }
        }
    }

    It 'refuses a placeholder hash and reports the real one to record' {
        Mock -ModuleName ReAgent.Servers Invoke-Download {
            'payload' | Set-Content -LiteralPath $OutFile
        }
        { Get-VerifiedRelease -Server (Get-RelServer) -Config $Script:RelCfg } |
            Should -Throw '*not pinned to a hash yet*'
    }

    It 'aborts on a hash mismatch rather than installing unverified code' {
        Mock -ModuleName ReAgent.Servers Invoke-Download {
            'payload' | Set-Content -LiteralPath $OutFile
        }
        { Get-VerifiedRelease -Server (Get-RelServer -Sha ('0' * 64) -Asset 'b.zip') `
                -Config $Script:RelCfg } | Should -Throw '*mismatch*'
    }

    It 'returns the path when the hash matches' {
        Mock -ModuleName ReAgent.Servers Invoke-Download {
            'payload' | Set-Content -LiteralPath $OutFile
        }
        $probe = Join-Path $TestDrive 'probe.txt'
        'payload' | Set-Content -LiteralPath $probe
        $hash = (Get-FileHash -LiteralPath $probe -Algorithm SHA256).Hash.ToLowerInvariant()
        Get-VerifiedRelease -Server (Get-RelServer -Sha $hash -Asset 'c.zip') `
            -Config $Script:RelCfg | Should -BeLike '*c.zip'
    }

    It 'insists on exactly one pinned asset' {
        $s = [PSCustomObject]@{
            name   = 'x'
            source = [PSCustomObject]@{
                repo   = 'a/b'; pin = 'v1'
                sha256 = [PSCustomObject]@{ 'one.zip' = 'x'; 'two.zip' = 'y' }
            }
        }
        { Get-VerifiedRelease -Server $s -Config $Script:RelCfg } |
            Should -Throw '*exactly one*'
    }
}

Describe 'Copy-PluginFile' {
    It 'copies when the destination does not exist' {
        $a = Join-Path $TestDrive 'src1.dll'; 'v1' | Set-Content $a
        $b = Join-Path $TestDrive 'dst1.dll'
        Copy-PluginFile -Source $a -Destination $b | Should -BeTrue
        (Get-Content $b -Raw).Trim() | Should -Be 'v1'
    }

    It 'does nothing when the file is already identical' {
        $a = Join-Path $TestDrive 'src2.dll'; 'same' | Set-Content $a
        $b = Join-Path $TestDrive 'dst2.dll'; 'same' | Set-Content $b
        Copy-PluginFile -Source $a -Destination $b | Should -BeFalse
    }

    It 'backs up what it replaces' {
        $a = Join-Path $TestDrive 'src3.dll'; 'new' | Set-Content $a
        $b = Join-Path $TestDrive 'dst3.dll'; 'old' | Set-Content $b
        Copy-PluginFile -Source $a -Destination $b | Should -BeTrue
        (Get-ChildItem $TestDrive -Filter 'dst3.dll.bak-*').Count | Should -BeGreaterThan 0
    }
}

Describe 'Install-GuiBuiltinHttpServer' {
    BeforeAll {
        $Script:BnCfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ toolRoot = $TestDrive }
        }
        $Script:BnSrv = [PSCustomObject]@{
            name      = 'binaryninja'; kind = 'gui-builtin-http'; enabled = $true
            transport = 'http'; bind = '127.0.0.1'; port = 24642; path = '/mcp'
            auth      = 'bearer-generated'
        }
    }

    It 'reports not-installed when Binary Ninja is absent' {
        $inv = [PSCustomObject]@{ BinaryNinjaRoot = $null; BinaryNinjaMcpCapable = $false }
        (Install-GuiBuiltinHttpServer -Server $Script:BnSrv -Config $Script:BnCfg `
                -Inventory $inv).Status | Should -Be 'not-installed'
    }

    It 'says upgrade Binary Ninja, not broken server, for an old build' {
        $inv = [PSCustomObject]@{
            BinaryNinjaRoot = 'C:\bn'; BinaryNinjaMcpCapable = $false
            BinaryNinjaSettingsPath = 'C:\s.json'
        }
        (Install-GuiBuiltinHttpServer -Server $Script:BnSrv -Config $Script:BnCfg `
                -Inventory $inv).Reason | Should -BeLike '*Upgrade Binary Ninja*'
    }

    It 'merges the four ui.mcp settings without downloading anything' {
        $settings = Join-Path $TestDrive 'bn-settings.json'
        '{ "ui.theme": "dark" }' | Set-Content $settings
        $inv = [PSCustomObject]@{
            BinaryNinjaRoot = 'C:\bn'; BinaryNinjaMcpCapable = $true
            BinaryNinjaSettingsPath = $settings
        }
        $r = Install-GuiBuiltinHttpServer -Server $Script:BnSrv -Config $Script:BnCfg `
            -Inventory $inv
        $r.Status | Should -Be 'installed'
        $s = Get-Content $settings -Raw | ConvertFrom-Json
        $s.'ui.mcp.enabled' | Should -BeTrue
        $s.'ui.mcp.port' | Should -Be 24642
        $s.'ui.mcp.endpoint' | Should -Be '/mcp'
        $s.'ui.mcp.token' | Should -Match '^[0-9a-f]{64}$'
        $s.'ui.theme' | Should -Be 'dark'
    }

    It 'tells the operator the server needs starting every session' {
        $settings = Join-Path $TestDrive 'bn-settings2.json'
        $inv = [PSCustomObject]@{
            BinaryNinjaRoot = 'C:\bn'; BinaryNinjaMcpCapable = $true
            BinaryNinjaSettingsPath = $settings
        }
        (Install-GuiBuiltinHttpServer -Server $Script:BnSrv -Config $Script:BnCfg `
                -Inventory $inv).Reason | Should -BeLike '*ONCE PER SESSION*'
    }
}

Describe 'Install-GuiPluginHttpServer' {
    BeforeAll {
        $Script:GmSrv = [PSCustomObject]@{
            name             = 'ghidramcp'; kind = 'gui-plugin-http'; enabled = $false
            transport        = 'sse'; bind = '127.0.0.1'; port = 8761; path = '/sse'
            auth             = 'bearer-generated'; maxGhidraVersion = '11.3.2'
            source           = [PSCustomObject]@{ pin = '1.4' }
        }
    }

    It 'refuses an extension the installed Ghidra would reject' {
        # GhidraMCP 1.4 targets Ghidra 11.3.2; this host runs 12.1.2.
        $inv = [PSCustomObject]@{ GhidraRoot = 'C:\g'; GhidraVersion = [version]'12.1.2' }
        $r = Install-GuiPluginHttpServer -Server $Script:GmSrv -Config ([PSCustomObject]@{}) `
            -Inventory $inv
        $r.Status | Should -Be 'not-installed'
        $r.Reason | Should -BeLike '*12.1.2*'
    }

    It 'does not treat the version mismatch as a failure' {
        $inv = [PSCustomObject]@{ GhidraRoot = 'C:\g'; GhidraVersion = [version]'12.1.2' }
        (Install-GuiPluginHttpServer -Server $Script:GmSrv -Config ([PSCustomObject]@{}) `
                -Inventory $inv).Status | Should -Not -Be 'failed'
    }

    It 'reports not-installed when Ghidra is absent' {
        $inv = [PSCustomObject]@{ GhidraRoot = $null; GhidraVersion = $null }
        (Install-GuiPluginHttpServer -Server $Script:GmSrv -Config ([PSCustomObject]@{}) `
                -Inventory $inv).Status | Should -Be 'not-installed'
    }
}

Describe 'Expand-X64dbgPlugin' {
    It 'writes nothing to the output stream' {
        # Copy-PluginFile returns a Boolean. Leaking it makes every caller
        # return an array, and the failure only shows up much further away as
        # "the property 'Name' cannot be found on this object".
        $staging = Join-Path $TestDrive 'rel-src'
        foreach ($a in @('x32', 'x64')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $staging "$a\plugins") -Force
            'payload' | Set-Content (Join-Path $staging "$a\plugins\plug.dp")
        }
        $zip = Join-Path $TestDrive 'plugin.zip'
        Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip -Force
        $root = Join-Path $TestDrive 'x64dbg-out'

        $out = @(Expand-X64dbgPlugin -ArchivePath $zip -ReleaseRoot $root)

        $out.Count | Should -Be 0
        Test-Path (Join-Path $root 'x64\plugins\plug.dp') | Should -BeTrue
        Test-Path (Join-Path $root 'x32\plugins\plug.dp') | Should -BeTrue
    }
}

Describe 'Install-PluginInprocServer' {
    BeforeAll {
        $Script:XSrv = [PSCustomObject]@{
            name      = 'x64dbg-x64'; kind = 'plugin-inproc'; enabled = $true; arch = 'x64'
            transport = 'http'; bind = '127.0.0.1'; port = 9094; path = '/'
            auth      = 'bearer-preseeded'
            source    = [PSCustomObject]@{ pin = 'v1.3' }
        }
    }

    It 'pre-seeds a 32 hex char token, matching the plugin format' {
        $root = Join-Path $TestDrive 'x64dbg-release'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'x64') -Force
        Mock -ModuleName ReAgent.Servers Get-VerifiedRelease { 'C:\dl\a.zip' }
        Mock -ModuleName ReAgent.Servers Expand-X64dbgPlugin { }
        $cfg = [PSCustomObject]@{ paths = [PSCustomObject]@{ toolRoot = $TestDrive } }
        $inv = [PSCustomObject]@{ X64dbgRoot = $root }
        $r = Install-PluginInprocServer -Server $Script:XSrv -Config $cfg -Inventory $inv
        $r.Status | Should -Be 'installed'
        $seeded = Get-Content (Join-Path $root 'x64\mcp_config.json') -Raw | ConvertFrom-Json
        $seeded.AuthToken | Should -Match '^[0-9a-f]{32}$'
        $seeded.IpAddress | Should -Be '127.0.0.1'
        $seeded.Port | Should -Be 9094
    }

    It 'preserves a token the plugin already generated rather than inventing one' {
        $root = Join-Path $TestDrive 'x64dbg-release2'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'x64') -Force
        '{ "IpAddress": "127.0.0.1", "Port": 9094, "AutoStart": true,
           "AuthToken": "pluginownedtoken" }' |
            Set-Content (Join-Path $root 'x64\mcp_config.json')
        Mock -ModuleName ReAgent.Servers Get-VerifiedRelease { 'C:\dl\a.zip' }
        Mock -ModuleName ReAgent.Servers Expand-X64dbgPlugin { }
        $cfg = [PSCustomObject]@{ paths = [PSCustomObject]@{ toolRoot = $TestDrive } }
        Install-PluginInprocServer -Server $Script:XSrv -Config $cfg `
            -Inventory ([PSCustomObject]@{ X64dbgRoot = $root }) | Out-Null
        (Get-Content (Join-Path $root 'x64\mcp_config.json') -Raw |
            ConvertFrom-Json).AuthToken | Should -Be 'pluginownedtoken'
    }

    It 'reports not-installed when x64dbg is absent' {
        $cfg = [PSCustomObject]@{ paths = [PSCustomObject]@{ toolRoot = $TestDrive } }
        (Install-PluginInprocServer -Server $Script:XSrv -Config $cfg `
                -Inventory ([PSCustomObject]@{ X64dbgRoot = $null })).Status |
            Should -Be 'not-installed'
    }
}

Describe 'Get-WindbgLaunchCommand' {
    BeforeAll {
        $Script:WinCfg = [PSCustomObject]@{
            paths   = [PSCustomObject]@{
                toolRoot = 'C:\re'; symbolCache = 'C:\re\symbols'
            }
            symbols = [PSCustomObject]@{ server = 'https://example.invalid/symbols' }
        }
    }

    It 'passes the resolved cdb path explicitly' {
        # cdb.exe ships in the WinDbg MSIX package and is never on PATH, so
        # auto-detection inside mcp-windbg cannot find it.
        $c = Get-WindbgLaunchCommand -Config $Script:WinCfg `
            -Inventory ([PSCustomObject]@{ Cdb = 'C:\win\cdb.exe' })
        $c.Arguments | Should -Contain '--cdb-path'
        $c.Arguments | Should -Contain 'C:\win\cdb.exe'
    }

    It 'sets _NT_SYMBOL_PATH to the same value it passes as --symbols-path' {
        $c = Get-WindbgLaunchCommand -Config $Script:WinCfg `
            -Inventory ([PSCustomObject]@{ Cdb = 'C:\win\cdb.exe' })
        $i = [array]::IndexOf($c.Arguments, '--symbols-path')
        $c.Env['_NT_SYMBOL_PATH'] | Should -Be $c.Arguments[$i + 1]
    }

    It 'returns nothing when cdb was never found' {
        Get-WindbgLaunchCommand -Config $Script:WinCfg `
            -Inventory ([PSCustomObject]@{ Cdb = $null }) | Should -BeNullOrEmpty
    }
}

Describe 'Test-ServerRestartNeeded' {
    It 'restarts a server whose launcher was rewritten under it' {
        # This is the pyghidra-mcp defect: the process started at 19:04 and the
        # launcher naming the test binary was written at 19:47, so the running
        # server kept a command line that never imported anything.
        $state = [PSCustomObject]@{
            State = 'Running'; LastRunTime = [datetime]'2026-09-05T19:04:26'
        }
        Test-ServerRestartNeeded -RunState $state `
            -LauncherWriteTime ([datetime]'2026-09-05T19:47:57') | Should -BeTrue
    }

    It 'leaves a server alone when it started after its launcher was written' {
        $state = [PSCustomObject]@{
            State = 'Running'; LastRunTime = [datetime]'2026-09-05T19:48:10'
        }
        Test-ServerRestartNeeded -RunState $state `
            -LauncherWriteTime ([datetime]'2026-09-05T19:47:57') | Should -BeFalse
    }

    It 'starts a task that is registered but not running' {
        $state = [PSCustomObject]@{
            State = 'Ready'; LastRunTime = [datetime]'2026-09-06T09:00:00'
        }
        Test-ServerRestartNeeded -RunState $state `
            -LauncherWriteTime ([datetime]'2026-09-05T19:47:57') | Should -BeTrue
    }

    It 'starts a task that has never run' {
        $state = [PSCustomObject]@{ State = 'Ready'; LastRunTime = $null }
        Test-ServerRestartNeeded -RunState $state `
            -LauncherWriteTime ([datetime]'2026-09-05T19:47:57') | Should -BeTrue
    }

    It 'does nothing when the task does not exist' {
        Test-ServerRestartNeeded -RunState $null `
            -LauncherWriteTime ([datetime]'2026-09-05T19:47:57') | Should -BeFalse
    }
}

Describe 'Restart-StaleServerTask' {
    BeforeEach {
        $Script:LauncherFile = Join-Path $TestDrive ('launch-' + [guid]::NewGuid() + '.cmd')
        Set-Content -LiteralPath $Script:LauncherFile -Value '@echo off' -Encoding ASCII
    }

    It 'restarts the task when the running server predates the launcher' {
        Mock -ModuleName ReAgent.Servers Get-ScheduledTaskRunState {
            [PSCustomObject]@{ State = 'Running'; LastRunTime = [datetime]'2000-01-01' }
        }
        Mock -ModuleName ReAgent.Servers Stop-ScheduledTask {}
        Mock -ModuleName ReAgent.Servers Start-ScheduledTask {}
        Mock -ModuleName ReAgent.Servers Stop-ProcessByPath {}

        Restart-StaleServerTask -Name 'ReLab-pyghidra-mcp' `
            -LauncherPath $Script:LauncherFile -ExecutablePath 'C:\v\pyghidra-mcp.exe' `
            -Confirm:$false | Should -BeTrue
        Should -Invoke -ModuleName ReAgent.Servers Start-ScheduledTask -Times 1
    }

    It 'kills a server the task no longer owns before starting a new one' {
        # Stop-ScheduledTask only reaches instances the task started this
        # session. A server left over from an earlier logon keeps the Ghidra
        # project locked, and the new instance dies with a LockException.
        Mock -ModuleName ReAgent.Servers Get-ScheduledTaskRunState {
            [PSCustomObject]@{ State = 'Ready'; LastRunTime = [datetime]'2000-01-01' }
        }
        Mock -ModuleName ReAgent.Servers Stop-ScheduledTask {}
        Mock -ModuleName ReAgent.Servers Start-ScheduledTask {}
        Mock -ModuleName ReAgent.Servers Stop-ProcessByPath {}

        Restart-StaleServerTask -Name 'ReLab-pyghidra-mcp' `
            -LauncherPath $Script:LauncherFile -ExecutablePath 'C:\v\pyghidra-mcp.exe' `
            -Confirm:$false | Should -BeTrue
        Should -Invoke -ModuleName ReAgent.Servers Stop-ProcessByPath -Times 1 -ParameterFilter {
            $Path -eq 'C:\v\pyghidra-mcp.exe'
        }
    }

    It 'leaves a current server running' {
        Mock -ModuleName ReAgent.Servers Get-ScheduledTaskRunState {
            [PSCustomObject]@{ State = 'Running'; LastRunTime = (Get-Date).AddYears(1) }
        }
        Mock -ModuleName ReAgent.Servers Stop-ScheduledTask {}
        Mock -ModuleName ReAgent.Servers Start-ScheduledTask {}
        Mock -ModuleName ReAgent.Servers Stop-ProcessByPath {}

        Restart-StaleServerTask -Name 'ReLab-pyghidra-mcp' `
            -LauncherPath $Script:LauncherFile -ExecutablePath 'C:\v\pyghidra-mcp.exe' `
            -Confirm:$false | Should -BeFalse
        Should -Invoke -ModuleName ReAgent.Servers Start-ScheduledTask -Times 0
        Should -Invoke -ModuleName ReAgent.Servers Stop-ProcessByPath -Times 0
    }
}

Describe 'Stop-ProcessByPath' {
    It 'stops only the process running exactly that executable' {
        $mine = 'C:\re\mcp\venvs\pyghidra-mcp\Scripts\pyghidra-mcp.exe'
        Mock -ModuleName ReAgent.Servers Get-ProcessIdByPath {
            if ($Path -eq $mine) { return @(4792) }
            return @()
        }
        Mock -ModuleName ReAgent.Servers Stop-ProcessById {}

        Stop-ProcessByPath -Path $mine -Confirm:$false | Should -Be 1
        Should -Invoke -ModuleName ReAgent.Servers Stop-ProcessById -Times 1 -ParameterFilter {
            $Id -eq 4792
        }
    }

    It 'does nothing when no process is running it' {
        Mock -ModuleName ReAgent.Servers Get-ProcessIdByPath { @() }
        Mock -ModuleName ReAgent.Servers Stop-ProcessById {}
        Stop-ProcessByPath -Path 'C:\nope.exe' -Confirm:$false | Should -Be 0
        Should -Invoke -ModuleName ReAgent.Servers Stop-ProcessById -Times 0
    }
}

Describe 'Write-ServerLauncher idempotency' {
    It 'leaves an unchanged launcher untouched' {
        # It is derived state, so it was rewritten unconditionally - which made
        # its LastWriteTime newer than the task's LastRunTime on every run, and
        # Restart-StaleServerTask then restarted pyghidra-mcp every single time,
        # costing a fresh Ghidra analysis and failing the check that followed.
        $p = Join-Path $TestDrive ('idem-' + [guid]::NewGuid() + '.cmd')
        Write-ServerLauncher -Path $p -Executable 'x.exe' -Arguments @('-a') `
            -Environment @{ K = 'v' } | Out-Null
        $first = (Get-Item -LiteralPath $p).LastWriteTime

        Start-Sleep -Milliseconds 30
        Write-ServerLauncher -Path $p -Executable 'x.exe' -Arguments @('-a') `
            -Environment @{ K = 'v' } | Out-Null

        (Get-Item -LiteralPath $p).LastWriteTime | Should -Be $first
    }

    It 'rewrites a launcher whose content changed' {
        $p = Join-Path $TestDrive ('idem2-' + [guid]::NewGuid() + '.cmd')
        Write-ServerLauncher -Path $p -Executable 'x.exe' -Arguments @('-a') | Out-Null
        Write-ServerLauncher -Path $p -Executable 'x.exe' -Arguments @('-b') | Out-Null
        (Get-Content -LiteralPath $p -Raw) | Should -BeLike '*-b*'
    }
}

Describe 'Get-TreeHash' {
    It 'is stable across path separator and case differences' {
        $a = Join-Path $TestDrive 'th-a'; $b = Join-Path $TestDrive 'th-b'
        foreach ($d in @($a, $b)) {
            $null = New-Item -ItemType Directory -Path (Join-Path $d 'sub') -Force
            'one' | Set-Content -LiteralPath (Join-Path $d 'sub\x.md')
            'two' | Set-Content -LiteralPath (Join-Path $d 'y.md')
        }
        Get-TreeHash -Root $a | Should -Be (Get-TreeHash -Root $b)
    }

    It 'changes when any byte changes' {
        $d = Join-Path $TestDrive 'th-c'
        $null = New-Item -ItemType Directory -Path $d -Force
        'one' | Set-Content -LiteralPath (Join-Path $d 'x.md')
        $before = Get-TreeHash -Root $d
        'two' | Set-Content -LiteralPath (Join-Path $d 'x.md')
        Get-TreeHash -Root $d | Should -Not -Be $before
    }

    It 'changes when a stray file is added, which is exactly what it should catch' {
        $d = Join-Path $TestDrive 'th-d'
        $null = New-Item -ItemType Directory -Path $d -Force
        'one' | Set-Content -LiteralPath (Join-Path $d 'x.md')
        $before = Get-TreeHash -Root $d
        'extra' | Set-Content -LiteralPath (Join-Path $d 'stray.ps1')
        Get-TreeHash -Root $d | Should -Not -Be $before
    }
}

Describe 'Expand-SkillPack' {
    It 'locates skill directories by shape rather than an assumed path' {
        $src = Join-Path $TestDrive 'esp-src\repo-abc123\skills\crash'
        $null = New-Item -ItemType Directory -Path $src -Force
        "---`nname: x`n---`nbody" | Set-Content -LiteralPath (Join-Path $src 'SKILL.md')
        $zip = Join-Path $TestDrive 'esp.zip'
        Compress-Archive -Path (Join-Path $TestDrive 'esp-src\*') -DestinationPath $zip
        $dirs = @(Expand-SkillPack -ArchivePath $zip -SubPath '')
        $dirs.Count | Should -Be 1
        $dirs[0].Name | Should -Be 'crash'
    }

    It 'throws naming the layout change when the archive has no SKILL.md anywhere' {
        $src = Join-Path $TestDrive 'esp2-src\repo\docs'
        $null = New-Item -ItemType Directory -Path $src -Force
        'nothing' | Set-Content -LiteralPath (Join-Path $src 'README.md')
        $zip = Join-Path $TestDrive 'esp2.zip'
        Compress-Archive -Path (Join-Path $TestDrive 'esp2-src\*') -DestinationPath $zip
        { Expand-SkillPack -ArchivePath $zip -SubPath '' } |
            Should -Throw '*upstream layout*'
    }

    It 'does not match a subPath as a bare substring of an unrelated directory name' {
        $repo = Join-Path $TestDrive 'esp3-src\repo-abc123'
        $decoy = Join-Path $repo 'myskillset'
        $real = Join-Path $repo 'skills\crash'
        $null = New-Item -ItemType Directory -Path $decoy -Force
        $null = New-Item -ItemType Directory -Path $real -Force
        "---`nname: x`n---`nbody" | Set-Content -LiteralPath (Join-Path $decoy 'SKILL.md')
        "---`nname: x`n---`nbody" | Set-Content -LiteralPath (Join-Path $real 'SKILL.md')
        $zip = Join-Path $TestDrive 'esp3.zip'
        Compress-Archive -Path (Join-Path $TestDrive 'esp3-src\*') -DestinationPath $zip
        $dirs = @(Expand-SkillPack -ArchivePath $zip -SubPath 'skills')
        $dirs.Count | Should -Be 1
        $dirs[0].Name | Should -Be 'crash'
    }

    It 'matches a multi-segment forward-slash subPath against a nested Windows path' {
        $src = Join-Path $TestDrive 'esp4-src\repo\plugins\foo\skills\crash'
        $null = New-Item -ItemType Directory -Path $src -Force
        "---`nname: x`n---`nbody" | Set-Content -LiteralPath (Join-Path $src 'SKILL.md')
        $zip = Join-Path $TestDrive 'esp4.zip'
        Compress-Archive -Path (Join-Path $TestDrive 'esp4-src\*') -DestinationPath $zip
        $dirs = @(Expand-SkillPack -ArchivePath $zip -SubPath 'plugins/foo/skills')
        $dirs.Count | Should -Be 1
        $dirs[0].Name | Should -Be 'crash'
    }
}

Describe 'Get-VerifiedGitHubArchive' {
    BeforeAll {
        function Get-ArchPack {
            [PSCustomObject]@{
                namespace = 'demo'
                source = [PSCustomObject]@{ repo = 'someone/pack'
                    commit = ('c' * 40); treeSha256 = 'PIN-ME' }
            }
        }
    }

    It 'fetches the archive at the pinned commit, not at a branch' {
        Mock -ModuleName ReAgent.Servers Invoke-Download {
            $Script:CapturedUri = $Uri
            'payload' | Set-Content -LiteralPath $OutFile
        }
        $null = Get-VerifiedGitHubArchive -Pack (Get-ArchPack) `
            -CacheRoot (Join-Path $TestDrive 'vc1')
        $Script:CapturedUri | Should -BeLike "*/archive/$('c' * 40).zip"
    }

    It 'names the cached archive after the commit so two pins never collide' {
        Mock -ModuleName ReAgent.Servers Invoke-Download {
            'payload' | Set-Content -LiteralPath $OutFile
        }
        $out = Get-VerifiedGitHubArchive -Pack (Get-ArchPack) `
            -CacheRoot (Join-Path $TestDrive 'vc2')
        (Split-Path -Leaf $out) | Should -Be "demo-$('c' * 40).zip"
    }

    It 'reuses a cached archive rather than downloading twice' {
        # Caching is what makes the PIN-ME loop tolerable: the first run throws with
        # the tree hash, the operator records it, the second run reuses the bytes.
        Mock -ModuleName ReAgent.Servers Invoke-Download {
            'payload' | Set-Content -LiteralPath $OutFile
        }
        $root = Join-Path $TestDrive 'vc3'
        $null = Get-VerifiedGitHubArchive -Pack (Get-ArchPack) -CacheRoot $root
        $null = Get-VerifiedGitHubArchive -Pack (Get-ArchPack) -CacheRoot $root
        Should -Invoke -ModuleName ReAgent.Servers Invoke-Download -Times 1 -Exactly
    }
}

# Note: this function does NOT verify a hash. The tree digest needs the EXPANDED
# tree, so Assert-FileHash is called by tools\Update-VendoredSkill.ps1 (Task 15)
# after Expand-SkillPack. Keeping the fetch dumb keeps the mock seam narrow.

Describe 'Wait-ServerListening' {
    It 'returns as soon as the port answers' {
        $Script:Polls = 0
        Mock -ModuleName ReAgent.Servers Test-TcpPortOpen {
            $Script:Polls++
            return ($Script:Polls -ge 3)
        }
        Wait-ServerListening -Bind '127.0.0.1' -Port 8762 -TimeoutSeconds 30 -PollSeconds 0 |
            Should -BeTrue
        $Script:Polls | Should -Be 3
    }

    It 'gives up rather than blocking forever' {
        Mock -ModuleName ReAgent.Servers Test-TcpPortOpen { $false }
        Wait-ServerListening -Bind '127.0.0.1' -Port 8762 -TimeoutSeconds 0 -PollSeconds 0 |
            Should -BeFalse
    }
}

Describe 'Get-NativeSseLaunchArgument' {
    BeforeAll {
        $script:Cfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ toolRoot = 'C:\re'; stateRoot = 'C:\re\state'
                symbolCache = 'C:\re\symbols' }
        }
    }

    It 'puts the resolved PDB first and pins an explicit port' {
        # pdbsql defaults to a RANDOM port in 9000-9999. Ports are allocated
        # statically from config; a server must never pick its own.
        Mock -ModuleName ReAgent.Servers Resolve-PdbPath {
            'C:\re\symbols\ntdll.pdb\GUID\ntdll.pdb'
        }
        $srv = [PSCustomObject]@{ name = 'pdbsql'; port = 8770
            pdb = [PSCustomObject]@{ module = 'ntdll'; warmTables = @('publics', 'udts') } }
        $a = Get-NativeSseLaunchArgument -Server $srv -Config $script:Cfg `
            -Inventory ([PSCustomObject]@{ GhidraRoot = $null })
        $a[0] | Should -Be 'C:\re\symbols\ntdll.pdb\GUID\ntdll.pdb'
        $a | Should -Contain '--mcp'
        $a | Should -Contain '8770'
        ($a -join ' ') | Should -BeLike '*--warm-tables publics,udts*'
    }

    It 'binds loopback explicitly' {
        Mock -ModuleName ReAgent.Servers Resolve-PdbPath { 'C:\pdb\ntdll.pdb' }
        $srv = [PSCustomObject]@{ name = 'pdbsql'; port = 8770; bind = '127.0.0.1'
            pdb = [PSCustomObject]@{ module = 'ntdll' } }
        (Get-NativeSseLaunchArgument -Server $srv -Config $script:Cfg `
            -Inventory ([PSCustomObject]@{ GhidraRoot = $null })) |
            Should -Contain '127.0.0.1'
    }

    It 'passes --readonly for a server that declares it' {
        # ghidrasql: A3 cannot see a launcher flag, so Q0 checks this separately,
        # but the flag has to be here for Q0 to find.
        $srv = [PSCustomObject]@{ name = 'ghidrasql'; port = 8771; bind = '127.0.0.1'
            readonly = $true; projectRoot = 'C:\re\mcp\ghidrasql\projects' }
        (Get-NativeSseLaunchArgument -Server $srv -Config $script:Cfg `
            -Inventory ([PSCustomObject]@{ GhidraRoot = 'C:\ghidra_12.1.2_PUBLIC' })) |
            Should -Contain '--readonly'
    }

    It 'throws when a pdb server names a module the cache lacks' {
        Mock -ModuleName ReAgent.Servers Resolve-PdbPath { $null }
        $srv = [PSCustomObject]@{ name = 'pdbsql'; port = 8770
            pdb = [PSCustomObject]@{ module = 'nosuch' } }
        { Get-NativeSseLaunchArgument -Server $srv -Config $script:Cfg `
            -Inventory ([PSCustomObject]@{ GhidraRoot = $null }) } |
            Should -Throw '*nosuch*'
    }

    It 'adds --ghidra for a projectRoot server, from Inventory not Config' {
        $srv = [PSCustomObject]@{ name = 'ghidrasql'; port = 8771; bind = '127.0.0.1'
            readonly = $true; projectRoot = 'C:\re\mcp\ghidrasql\projects' }
        $inv = [PSCustomObject]@{ GhidraRoot = 'C:\ghidra_12.1.2_PUBLIC' }
        $a = Get-NativeSseLaunchArgument -Server $srv -Config $script:Cfg -Inventory $inv
        $i = [array]::IndexOf($a, '--ghidra')
        $i | Should -BeGreaterOrEqual 0
        $a[$i + 1] | Should -Be 'C:\ghidra_12.1.2_PUBLIC'
    }

    It 'never adds --ghidra for a server with no projectRoot' {
        Mock -ModuleName ReAgent.Servers Resolve-PdbPath { 'C:\pdb\ntdll.pdb' }
        $srv = [PSCustomObject]@{ name = 'pdbsql'; port = 8770
            pdb = [PSCustomObject]@{ module = 'ntdll' } }
        $inv = [PSCustomObject]@{ GhidraRoot = 'C:\ghidra_12.1.2_PUBLIC' }
        (Get-NativeSseLaunchArgument -Server $srv -Config $script:Cfg -Inventory $inv) |
            Should -Not -Contain '--ghidra'
    }

    It 'throws when a projectRoot server has no Ghidra on this host' {
        $srv = [PSCustomObject]@{ name = 'ghidrasql'; port = 8771
            readonly = $true; projectRoot = 'C:\re\mcp\ghidrasql\projects' }
        $inv = [PSCustomObject]@{ GhidraRoot = $null }
        { Get-NativeSseLaunchArgument -Server $srv -Config $script:Cfg -Inventory $inv } |
            Should -Throw '*Ghidra*'
    }
}

Describe 'Install-McpServer dispatch' {
    It 'routes kind native-sse to its handler rather than reporting no handler' {
        Mock -ModuleName ReAgent.Servers Install-NativeSseServer {
            New-ServerResult -Server $Server -Status 'installed'
        }
        $srv = Get-TestServer -Name 'pdbsql' -Kind 'native-sse'
        $r = Install-McpServer -Server $srv -Config ([PSCustomObject]@{}) `
            -Inventory ([PSCustomObject]@{})
        $r.status | Should -Be 'installed'
        Should -Invoke -ModuleName ReAgent.Servers Install-NativeSseServer -Times 1 -Exactly
    }
}

Describe 'Install-NativeSseServer' {
    BeforeAll {
        $script:SseSrv = [PSCustomObject]@{
            name          = 'pdbsql'; kind = 'native-sse'; enabled = $true
            transport     = 'http'; bind = '127.0.0.1'; port = 8770; path = '/mcp'
            auth          = 'none'; scheduledTask = 'ReLab-pdbsql'
            pdb           = [PSCustomObject]@{ module = 'ntdll' }
            source        = [PSCustomObject]@{ repo = 'x/pdbsql'; pin = 'v1.0'
                sha256 = [PSCustomObject]@{ 'pdbsql-win64.zip' = 'deadbeef' } }
        }
    }

    It 'extracts the release, writes the launcher, and registers the scheduled task' {
        Mock -ModuleName ReAgent.Servers Resolve-PdbPath {
            'C:\re\symbols\ntdll.pdb\GUID\ntdll.pdb'
        }
        Mock -ModuleName ReAgent.Servers Write-ServerLauncher {
            'C:\re\mcp\pdbsql\launch-pdbsql.cmd'
        }
        Mock -ModuleName ReAgent.Servers Register-ServerScheduledTask { $true }
        Mock -ModuleName ReAgent.Servers Restart-StaleServerTask { $false }

        $staging = Join-Path $TestDrive 'pdbsql-release'
        $null = New-Item -ItemType Directory -Path $staging -Force
        $null = New-Item -ItemType File -Path (Join-Path $staging 'pdbsql.exe') -Force
        $zip = Join-Path $TestDrive 'pdbsql.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($staging, $zip)
        Mock -ModuleName ReAgent.Servers Get-VerifiedRelease { $zip }

        $toolRoot = Join-Path $TestDrive 'case1'
        $cfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ toolRoot = $toolRoot; symbolCache = 'C:\re\symbols' }
        }
        $r = Install-NativeSseServer -Server $script:SseSrv -Config $cfg `
            -Inventory ([PSCustomObject]@{})

        $r.Status | Should -Be 'installed'
        Test-Path (Join-Path $toolRoot 'mcp\pdbsql\pdbsql.exe') | Should -BeTrue
        Should -Invoke -ModuleName ReAgent.Servers Register-ServerScheduledTask -Times 1 -Exactly `
            -ParameterFilter { $Name -eq 'ReLab-pdbsql' }
    }

    It 'reports failed when the release archive has no matching exe' {
        Mock -ModuleName ReAgent.Servers Resolve-PdbPath {
            'C:\re\symbols\ntdll.pdb\GUID\ntdll.pdb'
        }
        $staging = Join-Path $TestDrive 'pdbsql-empty'
        $null = New-Item -ItemType Directory -Path $staging -Force
        $null = New-Item -ItemType File -Path (Join-Path $staging 'readme.txt') -Force
        $zip = Join-Path $TestDrive 'pdbsql-empty.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($staging, $zip)
        Mock -ModuleName ReAgent.Servers Get-VerifiedRelease { $zip }

        $cfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ toolRoot = (Join-Path $TestDrive 'case2')
                symbolCache = 'C:\re\symbols' }
        }
        $r = Install-NativeSseServer -Server $script:SseSrv -Config $cfg `
            -Inventory ([PSCustomObject]@{})
        $r.Status | Should -Be 'failed'
        $r.Reason | Should -BeLike '*pdbsql.exe*'
    }

    It 'pins the version onto the manifest record' {
        Mock -ModuleName ReAgent.Servers Resolve-PdbPath {
            'C:\re\symbols\ntdll.pdb\GUID\ntdll.pdb'
        }
        Mock -ModuleName ReAgent.Servers Write-ServerLauncher {
            'C:\re\mcp\pdbsql\launch-pdbsql.cmd'
        }
        Mock -ModuleName ReAgent.Servers Register-ServerScheduledTask { $true }
        Mock -ModuleName ReAgent.Servers Restart-StaleServerTask { $false }

        $staging = Join-Path $TestDrive 'pdbsql-release-version'
        $null = New-Item -ItemType Directory -Path $staging -Force
        $null = New-Item -ItemType File -Path (Join-Path $staging 'pdbsql.exe') -Force
        $zip = Join-Path $TestDrive 'pdbsql-version.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($staging, $zip)
        Mock -ModuleName ReAgent.Servers Get-VerifiedRelease { $zip }

        $cfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ toolRoot = (Join-Path $TestDrive 'case-version')
                symbolCache = 'C:\re\symbols' }
        }
        $r = Install-NativeSseServer -Server $script:SseSrv -Config $cfg `
            -Inventory ([PSCustomObject]@{})
        $r.Version | Should -Be 'v1.0'
    }

    It 'stops an already-running instance before re-extracting over it' {
        # Expand-Archive -Force fails 'access to the path is denied' against a
        # running pdbsql.exe: the exe holds its own file open, so the old
        # process has to go before the new bytes land, not after.
        Mock -ModuleName ReAgent.Servers Resolve-PdbPath {
            'C:\re\symbols\ntdll.pdb\GUID\ntdll.pdb'
        }
        Mock -ModuleName ReAgent.Servers Write-ServerLauncher {
            'C:\re\mcp\pdbsql\launch-pdbsql.cmd'
        }
        Mock -ModuleName ReAgent.Servers Register-ServerScheduledTask { $true }
        Mock -ModuleName ReAgent.Servers Restart-StaleServerTask { $false }
        Mock -ModuleName ReAgent.Servers Stop-ProcessByPath { 1 }

        $toolRoot = Join-Path $TestDrive 'case-stop'
        $installDir = Join-Path $toolRoot 'mcp\pdbsql'
        $null = New-Item -ItemType Directory -Path $installDir -Force
        $existingExe = Join-Path $installDir 'pdbsql.exe'
        $null = New-Item -ItemType File -Path $existingExe -Force

        $staging = Join-Path $TestDrive 'pdbsql-release-stop'
        $null = New-Item -ItemType Directory -Path $staging -Force
        $null = New-Item -ItemType File -Path (Join-Path $staging 'pdbsql.exe') -Force
        $zip = Join-Path $TestDrive 'pdbsql-stop.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($staging, $zip)
        Mock -ModuleName ReAgent.Servers Get-VerifiedRelease { $zip }

        $cfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ toolRoot = $toolRoot; symbolCache = 'C:\re\symbols' }
        }
        $r = Install-NativeSseServer -Server $script:SseSrv -Config $cfg `
            -Inventory ([PSCustomObject]@{})

        $r.Status | Should -Be 'installed'
        Should -Invoke -ModuleName ReAgent.Servers Stop-ProcessByPath -Times 1 -Exactly `
            -ParameterFilter { $Path -eq $existingExe }
    }

    It 'never stops a process on a fresh install with nothing running yet' {
        Mock -ModuleName ReAgent.Servers Resolve-PdbPath {
            'C:\re\symbols\ntdll.pdb\GUID\ntdll.pdb'
        }
        Mock -ModuleName ReAgent.Servers Write-ServerLauncher {
            'C:\re\mcp\pdbsql\launch-pdbsql.cmd'
        }
        Mock -ModuleName ReAgent.Servers Register-ServerScheduledTask { $true }
        Mock -ModuleName ReAgent.Servers Restart-StaleServerTask { $false }
        Mock -ModuleName ReAgent.Servers Stop-ProcessByPath { 0 }

        $staging = Join-Path $TestDrive 'pdbsql-release-fresh'
        $null = New-Item -ItemType Directory -Path $staging -Force
        $null = New-Item -ItemType File -Path (Join-Path $staging 'pdbsql.exe') -Force
        $zip = Join-Path $TestDrive 'pdbsql-fresh.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($staging, $zip)
        Mock -ModuleName ReAgent.Servers Get-VerifiedRelease { $zip }

        $cfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ toolRoot = (Join-Path $TestDrive 'case-fresh')
                symbolCache = 'C:\re\symbols' }
        }
        $r = Install-NativeSseServer -Server $script:SseSrv -Config $cfg `
            -Inventory ([PSCustomObject]@{})

        $r.Status | Should -Be 'installed'
        Should -Invoke -ModuleName ReAgent.Servers Stop-ProcessByPath -Times 0
    }

    It 'restarts the task and waits for the port when the task was stale' {
        Mock -ModuleName ReAgent.Servers Resolve-PdbPath {
            'C:\re\symbols\ntdll.pdb\GUID\ntdll.pdb'
        }
        Mock -ModuleName ReAgent.Servers Write-ServerLauncher {
            'C:\re\mcp\pdbsql\launch-pdbsql.cmd'
        }
        Mock -ModuleName ReAgent.Servers Register-ServerScheduledTask { $true }
        Mock -ModuleName ReAgent.Servers Restart-StaleServerTask { $true }
        Mock -ModuleName ReAgent.Servers Wait-ServerListening { $true }

        $staging = Join-Path $TestDrive 'pdbsql-release-restart'
        $null = New-Item -ItemType Directory -Path $staging -Force
        $null = New-Item -ItemType File -Path (Join-Path $staging 'pdbsql.exe') -Force
        $zip = Join-Path $TestDrive 'pdbsql-restart.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($staging, $zip)
        Mock -ModuleName ReAgent.Servers Get-VerifiedRelease { $zip }

        $toolRoot = Join-Path $TestDrive 'case-restart'
        $cfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ toolRoot = $toolRoot; symbolCache = 'C:\re\symbols' }
        }
        $r = Install-NativeSseServer -Server $script:SseSrv -Config $cfg `
            -Inventory ([PSCustomObject]@{})

        $r.Status | Should -Be 'installed'
        $expectedLauncher = Join-Path $toolRoot 'mcp\pdbsql\launch-pdbsql.cmd'
        Should -Invoke -ModuleName ReAgent.Servers Restart-StaleServerTask -Times 1 -Exactly `
            -ParameterFilter {
                $Name -eq 'ReLab-pdbsql' -and $LauncherPath -eq $expectedLauncher -and
                $ExecutablePath -eq (Join-Path $toolRoot 'mcp\pdbsql\pdbsql.exe')
            }
        Should -Invoke -ModuleName ReAgent.Servers Wait-ServerListening -Times 1 -Exactly `
            -ParameterFilter { $Bind -eq '127.0.0.1' -and $Port -eq 8770 }
    }

    It 'does not wait for the port when the task was already current' {
        Mock -ModuleName ReAgent.Servers Resolve-PdbPath {
            'C:\re\symbols\ntdll.pdb\GUID\ntdll.pdb'
        }
        Mock -ModuleName ReAgent.Servers Write-ServerLauncher {
            'C:\re\mcp\pdbsql\launch-pdbsql.cmd'
        }
        Mock -ModuleName ReAgent.Servers Register-ServerScheduledTask { $true }
        Mock -ModuleName ReAgent.Servers Restart-StaleServerTask { $false }
        Mock -ModuleName ReAgent.Servers Wait-ServerListening { $true }

        $staging = Join-Path $TestDrive 'pdbsql-release-current'
        $null = New-Item -ItemType Directory -Path $staging -Force
        $null = New-Item -ItemType File -Path (Join-Path $staging 'pdbsql.exe') -Force
        $zip = Join-Path $TestDrive 'pdbsql-current.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($staging, $zip)
        Mock -ModuleName ReAgent.Servers Get-VerifiedRelease { $zip }

        $cfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ toolRoot = (Join-Path $TestDrive 'case-current')
                symbolCache = 'C:\re\symbols' }
        }
        $r = Install-NativeSseServer -Server $script:SseSrv -Config $cfg `
            -Inventory ([PSCustomObject]@{})

        $r.Status | Should -Be 'installed'
        Should -Invoke -ModuleName ReAgent.Servers Wait-ServerListening -Times 0
    }
}

Describe 'Resolve-LibGhidraExtensionZip' {
    It 'returns the newest zip under the vendor-cache dist directory' {
        $root = Join-Path $TestDrive 'vc1'
        $dist = Join-Path $root 'libghidra\ghidra-extension\dist'
        New-Item -ItemType Directory -Path $dist -Force | Out-Null
        $old = Join-Path $dist 'old.zip'
        $new = Join-Path $dist 'new.zip'
        Set-Content -LiteralPath $old -Value 'x'
        Start-Sleep -Milliseconds 50
        Set-Content -LiteralPath $new -Value 'y'
        Resolve-LibGhidraExtensionZip -VendorCacheRoot $root | Should -Be $new
    }

    It 'returns $null when no build has ever run' {
        $root = Join-Path $TestDrive 'vc2'
        Resolve-LibGhidraExtensionZip -VendorCacheRoot $root | Should -BeNullOrEmpty
    }
}

Describe 'Install-NativeSseServer, ghidrasql extension wiring' {
    BeforeAll {
        $script:GhSrv = [PSCustomObject]@{
            name = 'ghidrasql'; kind = 'native-sse'; enabled = $true
            transport = 'sse'; bind = '127.0.0.1'; port = 8771; path = '/sse'
            auth = 'none'; scheduledTask = 'ReLab-ghidrasql'
            readonly = $true; projectRoot = ''
            source = [PSCustomObject]@{ repo = 'x/ghidrasql'; pin = 'v0.0.6'
                sha256 = [PSCustomObject]@{ 'ghidrasql-win64.zip' = 'deadbeef' } }
        }
    }

    It 'installs the extension before writing the launcher, then extracts and registers' {
        $toolRoot = Join-Path $TestDrive 'case-gh1'
        $script:GhSrv.projectRoot = Join-Path $toolRoot 'mcp\ghidrasql\projects'

        Mock -ModuleName ReAgent.Servers Write-ServerLauncher {
            'C:\re\mcp\ghidrasql\launch-ghidrasql.cmd'
        }
        Mock -ModuleName ReAgent.Servers Register-ServerScheduledTask { $true }
        Mock -ModuleName ReAgent.Servers Restart-StaleServerTask { $false }
        Mock -ModuleName ReAgent.Servers Install-LibGhidraExtension { $true }

        $staging = Join-Path $TestDrive 'ghidrasql-release'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $staging 'ghidrasql.exe') -Force | Out-Null
        $zip = Join-Path $TestDrive 'ghidrasql.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($staging, $zip)
        Mock -ModuleName ReAgent.Servers Get-VerifiedRelease { $zip }

        $vendorCache = Join-Path $TestDrive 'vc-installed'
        $dist = Join-Path $vendorCache 'libghidra\ghidra-extension\dist'
        New-Item -ItemType Directory -Path $dist -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dist 'ext.zip') -Value 'x'
        Mock -ModuleName ReAgent.Servers Resolve-LibGhidraExtensionZip {
            Join-Path $dist 'ext.zip'
        }

        $cfg = [PSCustomObject]@{ paths = [PSCustomObject]@{ toolRoot = $toolRoot } }
        $inv = [PSCustomObject]@{ GhidraRoot = 'C:\ghidra_12.1.2_PUBLIC' }
        $r = Install-NativeSseServer -Server $script:GhSrv -Config $cfg -Inventory $inv

        $r.Status | Should -Be 'installed'
        Test-Path $script:GhSrv.projectRoot | Should -BeTrue
        Should -Invoke -ModuleName ReAgent.Servers Install-LibGhidraExtension -Times 1 -Exactly `
            -ParameterFilter { $GhidraRoot -eq 'C:\ghidra_12.1.2_PUBLIC' }
    }

    It 'reports not-installed, not failed, when the extension was never built' {
        $toolRoot = Join-Path $TestDrive 'case-gh2'
        $script:GhSrv.projectRoot = Join-Path $toolRoot 'mcp\ghidrasql\projects'
        Mock -ModuleName ReAgent.Servers Resolve-LibGhidraExtensionZip { $null }

        $cfg = [PSCustomObject]@{ paths = [PSCustomObject]@{ toolRoot = $toolRoot } }
        $inv = [PSCustomObject]@{ GhidraRoot = 'C:\ghidra_12.1.2_PUBLIC' }
        $r = Install-NativeSseServer -Server $script:GhSrv -Config $cfg -Inventory $inv

        $r.Status | Should -Be 'not-installed'
        $r.Reason | Should -BeLike '*Build-LibGhidraExtension*'
    }

    It 'reports not-installed, not failed, when no Ghidra was found even with a built extension' {
        # Install-LibGhidraExtension's -GhidraRoot is Mandatory][string]; passing it $null
        # throws a raw ParameterBindingException instead of a readable reason, so this
        # must be caught before that call, not left to fail there.
        $toolRoot = Join-Path $TestDrive 'case-gh3'
        $script:GhSrv.projectRoot = Join-Path $toolRoot 'mcp\ghidrasql\projects'
        Mock -ModuleName ReAgent.Servers Resolve-LibGhidraExtensionZip { 'C:\vc\ext.zip' }
        Mock -ModuleName ReAgent.Servers Install-LibGhidraExtension { $true }

        $cfg = [PSCustomObject]@{ paths = [PSCustomObject]@{ toolRoot = $toolRoot } }
        $inv = [PSCustomObject]@{ GhidraRoot = $null }
        $r = Install-NativeSseServer -Server $script:GhSrv -Config $cfg -Inventory $inv

        $r.Status | Should -Be 'not-installed'
        $r.Reason | Should -BeLike '*Ghidra*'
        Should -Invoke -ModuleName ReAgent.Servers Install-LibGhidraExtension -Times 0
    }
}


Describe 'Install-LibGhidraExtension' {
    BeforeAll {
        # Get-GhidraVersion reads the version out of the install directory's own
        # name (ghidra_X.Y.Z...); this fixture's temp directory does not follow
        # that naming, so it is mocked to report this host's real 12.1.2 instead.
        Mock -ModuleName ReAgent.Servers Get-GhidraVersion { '12.1.2' }
        $script:GRoot = Join-Path ([IO.Path]::GetTempPath()) ("gh-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:GRoot 'Ghidra\Extensions') `
            -Force | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $stage = Join-Path ([IO.Path]::GetTempPath()) ("st-" + [guid]::NewGuid())
        $inner = Join-Path $stage 'LibGhidraHost'
        New-Item -ItemType Directory -Path $inner -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $inner 'extension.properties') `
            -Value "name=LibGhidraHost`nversion=12.1.2"
        $script:Zip = "$stage.zip"
        [IO.Compression.ZipFile]::CreateFromDirectory($stage, $script:Zip)
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
    AfterAll {
        Remove-Item -LiteralPath $script:GRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:Zip -Force -ErrorAction SilentlyContinue
    }

    It 'writes the extension into the Ghidra tree on a first install' {
        Install-LibGhidraExtension -ExtensionZip $script:Zip -GhidraRoot $script:GRoot |
            Should -BeTrue
        Test-Path (Join-Path $script:GRoot `
                'Ghidra\Extensions\LibGhidraHost\extension.properties') | Should -BeTrue
    }

    It 'reports no change on a second run, so a steady-state run touches nothing' {
        Install-LibGhidraExtension -ExtensionZip $script:Zip -GhidraRoot $script:GRoot | Out-Null
        Install-LibGhidraExtension -ExtensionZip $script:Zip -GhidraRoot $script:GRoot |
            Should -BeFalse
    }

    It 'refuses an extension stamped for a different Ghidra than the host runs' {
        # The Task 1 gate again, enforced at install time: a stamp mismatch here
        # means someone substituted a prebuilt release zip for the built one.
        Mock -ModuleName ReAgent.Servers Get-GhidraVersion { '12.1.3' }
        { Install-LibGhidraExtension -ExtensionZip $script:Zip -GhidraRoot $script:GRoot } |
            Should -Throw '*12.1.2*'
    }
}
