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
