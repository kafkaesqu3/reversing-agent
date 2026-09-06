BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Common.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Discovery.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Config.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Symbols.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Servers.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Verify.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Manifest.psm1" -Force
}

Describe 'New-CheckResult' {
    It 'accepts the three real statuses' {
        foreach ($s in @('pass', 'fail', 'not-testable')) {
            (New-CheckResult -Name 'x' -Status $s).Status | Should -Be $s
        }
    }
    It 'rejects anything else' {
        { New-CheckResult -Name 'x' -Status 'maybe' } | Should -Throw '*maybe*'
    }
}

Describe 'Invoke-McpProbe' {
    It 'parses the JSON report the probe prints' {
        Mock -ModuleName ReAgent.Verify Invoke-CommandLine {
            @('INFO: chatter on stderr', '{"ok": true, "toolCount": 20}')
        }
        $r = Invoke-McpProbe -PythonPath 'py.exe' -ProbeScript 'p.py' -ProbeArgs @()
        $r.ok | Should -BeTrue
        $r.toolCount | Should -Be 20
    }

    It 'ignores server log noise and takes the JSON line' {
        Mock -ModuleName ReAgent.Verify Invoke-CommandLine {
            @('INFO:pyghidra_mcp:starting', 'INFO:more noise', '{"ok": false, "error": "boom"}')
        }
        (Invoke-McpProbe -PythonPath 'py.exe' -ProbeScript 'p.py' -ProbeArgs @()).error |
            Should -Be 'boom'
    }

    It 'reports a probe that printed nothing as not ok, rather than throwing' {
        Mock -ModuleName ReAgent.Verify Invoke-CommandLine { @('only noise') }
        (Invoke-McpProbe -PythonPath 'py.exe' -ProbeScript 'p.py' -ProbeArgs @()).ok |
            Should -BeFalse
    }

    It 'turns an exception into a report rather than propagating it' {
        Mock -ModuleName ReAgent.Verify Invoke-CommandLine { throw 'python missing' }
        (Invoke-McpProbe -PythonPath 'py.exe' -ProbeScript 'p.py' -ProbeArgs @()).error |
            Should -BeLike '*python missing*'
    }
}

Describe 'Test-ClaudeCli' {
    It 'fails when Claude Code is absent' {
        (Test-ClaudeCli -ClaudePath $null).Status | Should -Be 'fail'
    }
    It 'passes on a version banner' {
        Mock -ModuleName ReAgent.Verify Invoke-CommandLine { '2.1.261 (Claude Code)' }
        (Test-ClaudeCli -ClaudePath 'claude.exe').Status | Should -Be 'pass'
    }
    It 'fails when the output carries no version' {
        Mock -ModuleName ReAgent.Verify Invoke-CommandLine { 'command not found' }
        (Test-ClaudeCli -ClaudePath 'claude.exe').Status | Should -Be 'fail'
    }
}

Describe 'Test-ClaudeMcpList' {
    It 'reports pending approval as not-testable, not as a broken server' {
        # Project .mcp.json servers stay pending until claude has been run
        # interactively once and the trust prompt accepted.
        Mock -ModuleName ReAgent.Verify Invoke-CommandLine { 'pyghidra-mcp - Pending approval' }
        $r = Test-ClaudeMcpList -ClaudePath 'claude.exe' -WorkingDirectory $TestDrive
        $r.Status | Should -Be 'not-testable'
        $r.Detail | Should -BeLike '*trust prompt*'
    }

    It 'fails on a genuine connection failure' {
        Mock -ModuleName ReAgent.Verify Invoke-CommandLine { 'binaryninja - Failed to connect' }
        (Test-ClaudeMcpList -ClaudePath 'claude.exe' -WorkingDirectory $TestDrive).Status |
            Should -Be 'fail'
    }

    It 'passes when everything is connected' {
        Mock -ModuleName ReAgent.Verify Invoke-CommandLine { 'pyghidra-mcp - Connected' }
        (Test-ClaudeMcpList -ClaudePath 'claude.exe' -WorkingDirectory $TestDrive).Status |
            Should -Be 'pass'
    }

    It 'restores the working directory even when the call throws' {
        Mock -ModuleName ReAgent.Verify Invoke-CommandLine { throw 'nope' }
        $before = (Get-Location).Path
        Test-ClaudeMcpList -ClaudePath 'claude.exe' -WorkingDirectory $TestDrive | Out-Null
        (Get-Location).Path | Should -Be $before
    }
}

Describe 'Test-WindbgLive' {
    BeforeAll {
        $Script:WbCfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ toolRoot = (Join-Path $TestDrive 'wb') }
        }
        $null = New-Item -ItemType Directory `
            -Path (Join-Path $Script:WbCfg.paths.toolRoot 'scratch') -Force
        'dump' | Set-Content (Join-Path $Script:WbCfg.paths.toolRoot 'scratch\test.dmp')
        $Script:WbSrv = [PSCustomObject]@{ name = 'mcp-windbg' }
        $Script:WbRes = [PSCustomObject]@{
            Command = [PSCustomObject]@{
                Executable = 'python.exe'; Arguments = @('-m', 'mcp_windbg'); Env = @{}
            }
        }
        $Script:Lm = @'
Command: lm

Output:
0:000> start             end                 module name
00007ffb`bb4b0000 00007ffb`bb5fc000   ucrtbase   (deferred)
00007ffb`bd8e0000 00007ffb`bdb46000   ntdll      (pdb symbols)          c:\re\symbols\ntdll.pdb\1D\ntdll.pdb
'@
    }

    It 'passes when ntdll has symbols, even beside a deferred module' {
        # cdb defers every module nothing has touched. An unrelated '(deferred)'
        # says nothing about whether the symbol path resolves.
        Mock -ModuleName ReAgent.Verify Invoke-McpProbe {
            [PSCustomObject]@{ ok = $true
                calls = @([PSCustomObject]@{ text = 'session_id: cdb-1' },
                    [PSCustomObject]@{ text = $Script:Lm })
            }
        }
        (Test-WindbgLive -Server $Script:WbSrv -Config $Script:WbCfg `
                -Result $Script:WbRes).Status | Should -Be 'pass'
    }

    It 'fails when ntdll itself has no symbols' {
        Mock -ModuleName ReAgent.Verify Invoke-McpProbe {
            [PSCustomObject]@{ ok = $true
                calls = @([PSCustomObject]@{ text = 'ntdll      (deferred)' })
            }
        }
        $r = Test-WindbgLive -Server $Script:WbSrv -Config $Script:WbCfg -Result $Script:WbRes
        $r.Status | Should -Be 'fail'
        $r.Detail | Should -BeLike '*did not resolve*'
    }

    It 'threads the session id from open_cdb_dump into run_cdb_command' {
        # run_cdb_command rejects a call without session_id, and the id only
        # exists in the text open_cdb_dump returns.
        Mock -ModuleName ReAgent.Verify Invoke-McpProbe {
            [PSCustomObject]@{ ok = $true
                calls = @([PSCustomObject]@{ text = 'session_id: cdb-1' },
                    [PSCustomObject]@{ text = $Script:Lm })
            }
        }
        Test-WindbgLive -Server $Script:WbSrv -Config $Script:WbCfg `
            -Result $Script:WbRes | Out-Null
        Should -Invoke -ModuleName ReAgent.Verify Invoke-McpProbe -Times 1 -ParameterFilter {
            $Calls[0].capture.session_id -and $Calls[1].args.session_id -eq '{{session_id}}'
        }
    }
}

Describe 'Test-GeneratedConfig' {
    BeforeAll {
        $Script:Cfg = [PSCustomObject]@{
            paths      = [PSCustomObject]@{ agentRoot = (Join-Path $TestDrive 'agent') }
            mcpServers = @(
                [PSCustomObject]@{ name = 'pyghidra-mcp'; transport = 'http'
                    bind = '127.0.0.1'; port = 8762; kind = 'venv-http'
                }
            )
        }
        $null = New-Item -ItemType Directory `
            -Path (Join-Path $Script:Cfg.paths.agentRoot '.claude') -Force
        '{}' | Set-Content (Join-Path $Script:Cfg.paths.agentRoot '.claude\settings.json')
    }

    It 'fails when .mcp.json is missing' {
        $missing = [PSCustomObject]@{
            paths      = [PSCustomObject]@{ agentRoot = (Join-Path $TestDrive 'nothing') }
            mcpServers = @()
        }
        (Test-GeneratedConfig -Config $missing).Status | Should -Be 'fail'
    }

    It 'fails on a server bound off loopback' {
        '{ "mcpServers": { "x": { "type": "http", "url": "http://0.0.0.0:8762/mcp" } } }' |
            Set-Content (Join-Path $Script:Cfg.paths.agentRoot '.mcp.json')
        $r = Test-GeneratedConfig -Config $Script:Cfg
        $r.Status | Should -Be 'fail'
        $r.Detail | Should -BeLike '*loopback*'
    }

    It 'fails on a port that was never allocated' {
        '{ "mcpServers": { "x": { "type": "http", "url": "http://127.0.0.1:9999/mcp" } } }' |
            Set-Content (Join-Path $Script:Cfg.paths.agentRoot '.mcp.json')
        (Test-GeneratedConfig -Config $Script:Cfg).Detail | Should -BeLike '*unallocated*'
    }

    It 'passes valid config on an allocated loopback port' {
        '{ "mcpServers": { "x": { "type": "http", "url": "http://127.0.0.1:8762/mcp" } } }' |
            Set-Content (Join-Path $Script:Cfg.paths.agentRoot '.mcp.json')
        (Test-GeneratedConfig -Config $Script:Cfg).Status | Should -Be 'pass'
    }

    It 'passes an empty server map rather than throwing on it' {
        # Every server failing to install is a bad run, not a broken verifier.
        '{ "mcpServers": { } }' |
            Set-Content (Join-Path $Script:Cfg.paths.agentRoot '.mcp.json')
        (Test-GeneratedConfig -Config $Script:Cfg).Status | Should -Be 'pass'
    }

    It 'ignores stdio entries, which carry no url' {
        '{ "mcpServers": { "w": { "command": "python.exe", "args": ["-m","mcp_windbg"] } } }' |
            Set-Content (Join-Path $Script:Cfg.paths.agentRoot '.mcp.json')
        (Test-GeneratedConfig -Config $Script:Cfg).Status | Should -Be 'pass'
    }
}

Describe 'Invoke-Verification tiers' {
    BeforeAll {
        $Script:VCfg = [PSCustomObject]@{
            paths      = [PSCustomObject]@{
                agentRoot = (Join-Path $TestDrive 'v-agent')
                stateRoot = (Join-Path $TestDrive 'v-state')
                toolRoot  = (Join-Path $TestDrive 'v-tool')
            }
            mcpServers = @(
                [PSCustomObject]@{ name = 'binaryninja'; requiresHostApp = $true
                    transport = 'http'; bind = '127.0.0.1'; port = 24642; kind = 'gui-builtin-http'
                },
                [PSCustomObject]@{ name = 'ghidramcp'; requiresHostApp = $true
                    transport = 'sse'; bind = '127.0.0.1'; port = 8761; kind = 'gui-plugin-http'
                }
            )
        }
        $Script:VResults = @(
            [PSCustomObject]@{ Name = 'binaryninja'; Installed = $true; Reason = '' },
            [PSCustomObject]@{ Name = 'ghidramcp'; Installed = $false; Reason = 'version gate' }
        )
    }

    BeforeEach {
        Mock -ModuleName ReAgent.Verify Test-ClaudeCli { New-CheckResult -Name 'c' -Status 'pass' }
        Mock -ModuleName ReAgent.Verify Test-ClaudeMcpList {
            New-CheckResult -Name 'm' -Status 'pass'
        }
        Mock -ModuleName ReAgent.Verify Test-GeneratedConfig {
            New-CheckResult -Name 'g' -Status 'pass'
        }
    }

    It 'marks a GUI server not-testable rather than failed without -Attended' {
        $c = Invoke-Verification -Config $Script:VCfg -ServerResults $Script:VResults
        ($c | Where-Object { $_.Name -like 'binaryninja*' }).Status | Should -Be 'not-testable'
    }

    It 'never reports a not-installed server as a failure' {
        $c = Invoke-Verification -Config $Script:VCfg -ServerResults $Script:VResults
        ($c | Where-Object { $_.Name -like 'ghidramcp*' }).Status | Should -Be 'not-testable'
    }

    It 'writes verify-report.json with a summary' {
        Invoke-Verification -Config $Script:VCfg -ServerResults $Script:VResults | Out-Null
        $p = Join-Path $Script:VCfg.paths.stateRoot 'verify-report.json'
        Test-Path $p | Should -BeTrue
        $r = Get-Content $p -Raw | ConvertFrom-Json
        $r.summary.notTestable | Should -BeGreaterThan 0
        $r.tier2Requested | Should -BeFalse
    }

    It 'records that tier 2 was requested when -Attended is given' {
        Invoke-Verification -Config $Script:VCfg -ServerResults $Script:VResults -Attended |
            Out-Null
        (Get-Content (Join-Path $Script:VCfg.paths.stateRoot 'verify-report.json') -Raw |
            ConvertFrom-Json).tier2Requested | Should -BeTrue
    }
}

Describe 'Get-ManualStep' {
    BeforeAll {
        $Script:MCfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ agentRoot = 'C:\re\agent' }
        }
    }

    It 'always tells the operator to accept the trust prompt' {
        (Get-ManualStep -Config $Script:MCfg -ServerResults @()) -join ';' |
            Should -BeLike '*trust prompt*'
    }

    It 'never claims to have handled Claude login' {
        (Get-ManualStep -Config $Script:MCfg -ServerResults @()) -join ';' |
            Should -BeLike '*never writes credentials*'
    }

    It 'warns that Binary Ninja needs starting per session' {
        $r = @([PSCustomObject]@{ Name = 'binaryninja'; Installed = $true; Kind = 'gui-builtin-http' })
        (Get-ManualStep -Config $Script:MCfg -ServerResults $r) -join ';' |
            Should -BeLike '*does NOT autostart*'
    }

    It 'says to open the debugger for an in-process plugin server' {
        $r = @([PSCustomObject]@{ Name = 'x64dbg-x32'; Installed = $true; Kind = 'plugin-inproc' })
        (Get-ManualStep -Config $Script:MCfg -ServerResults $r) -join ';' |
            Should -BeLike '*x64dbg-x32*'
    }

    It 'says nothing extra about a server that was not installed' {
        $r = @([PSCustomObject]@{ Name = 'binaryninja'; Installed = $false; Kind = 'gui-builtin-http' })
        (Get-ManualStep -Config $Script:MCfg -ServerResults $r) -join ';' |
            Should -Not -BeLike '*autostart*'
    }
}

Describe 'Write-Manifest' {
    It 'records servers, verification, manual steps, and the auth exemption' {
        $cfg = [PSCustomObject]@{
            version    = 1
            paths      = [PSCustomObject]@{
                stateRoot = (Join-Path $TestDrive 'm-state'); agentRoot = 'C:\re\agent'
            }
            mcpServers = @(
                [PSCustomObject]@{ name = 'pyghidra-mcp'
                    authExemptReason = 'upstream exposes no auth mechanism'
                }
            )
        }
        $ctx = @{
            Config    = $cfg
            Inventory = [PSCustomObject]@{ TotalRamGb = 8 }
            ServerResults = @([PSCustomObject]@{
                    Name = 'pyghidra-mcp'; Kind = 'venv-http'; Status = 'installed'
                    Version = '0.2.5'; Transport = 'http'; Bind = '127.0.0.1'
                    Port = 8762; Reason = ''; Installed = $true
                })
            VerifyResults = @([PSCustomObject]@{ Name = 'x'; Status = 'pass' })
        }
        $p = Write-Manifest -Context $ctx -PhaseResults @(
            (New-PhaseResult -Id 0 -Name 'Preflight' -Status 'ok' -DurationMs 5))

        $m = Get-Content $p -Raw | ConvertFrom-Json
        $m.servers[0].name | Should -Be 'pyghidra-mcp'
        $m.servers[0].version | Should -Be '0.2.5'
        $m.phases[0].name | Should -Be 'Preflight'
        $m.verification[0].status | Should -Be 'pass'
        $m.authExemptions[0].server | Should -Be 'pyghidra-mcp'
        $m.manualSteps.Count | Should -BeGreaterThan 0
        $m.inventory.TotalRamGb | Should -Be 8
    }
}

Describe 'Invoke-Verification with no install results' {
    BeforeAll {
        $Script:NoResCfg = [PSCustomObject]@{
            paths      = [PSCustomObject]@{
                stateRoot = (Join-Path $TestDrive 'nores-state')
                agentRoot = (Join-Path $TestDrive 'nores-agent')
            }
            mcpServers = @([PSCustomObject]@{
                    name = 'pyghidra-mcp'; enabled = $true; kind = 'venv-http'
                    transport = 'http'; bind = '127.0.0.1'; port = 8762
                    path = '/mcp'; auth = 'none'; requiresHostApp = $false
                })
        }
    }

    It 'reports the install state as unknown rather than claiming not installed' {
        # An empty result set means phase 3 did not run, which is not the same
        # as a server that failed to install. Saying "not installed" of a server
        # that is running and answering is the worst answer available.
        $checks = Invoke-Verification -Config $Script:NoResCfg -ServerResults @()
        $c = $checks | Where-Object { $_.Name -eq 'pyghidra-mcp live call' }
        $c.Status | Should -Be 'not-testable'
        $c.Detail | Should -Not -BeLike '*Not installed on this host*'
        $c.Detail | Should -BeLike '*manifest*'
    }
}

Describe 'Invoke-McpProbe with a call sequence' {
    It 'hands the calls to the probe in a file, not as an inline argument' {
        # PowerShell 5.1 strips the double quotes out of a native command's
        # arguments: '--calls=[{"tool":"x"}]' arrives as '--calls=[{tool:x}]'.
        # Every check that sent a call sequence therefore failed with a
        # JSONDecodeError that read as a broken server.
        Mock -ModuleName ReAgent.Verify Invoke-CommandLine {
            $file = @($Arguments | Where-Object { $_ -like '--calls-file=*' }) |
                Select-Object -First 1
            $Script:SeenArgs = $Arguments
            $Script:SeenCalls = if ($file) {
                Get-Content -LiteralPath ($file -replace '^--calls-file=', '') -Raw
            } else { $null }
            @('{"ok": true}')
        }

        Invoke-McpProbe -PythonPath 'py.exe' -ProbeScript 'p.py' `
            -ProbeArgs @('--transport=http', '--url=http://127.0.0.1:9094/') `
            -Calls @(@{ tool = 'GetDebugState'; args = @{} }) | Out-Null

        ($Script:SeenArgs -join ' ') | Should -Not -BeLike '*--calls=*'
        @($Script:SeenCalls | ConvertFrom-Json)[0].tool | Should -Be 'GetDebugState'
    }

    It 'deletes the call file afterwards' {
        Mock -ModuleName ReAgent.Verify Invoke-CommandLine {
            $Script:SeenFile = (@($Arguments | Where-Object { $_ -like '--calls-file=*' }) |
                    Select-Object -First 1) -replace '^--calls-file=', ''
            @('{"ok": true}')
        }
        Invoke-McpProbe -PythonPath 'py.exe' -ProbeScript 'p.py' -ProbeArgs @() `
            -Calls @(@{ tool = 'Echo'; args = @{} }) | Out-Null
        Test-Path -LiteralPath $Script:SeenFile | Should -BeFalse
    }

    It 'passes no call file when there are no calls' {
        Mock -ModuleName ReAgent.Verify Invoke-CommandLine {
            $Script:SeenArgs = $Arguments
            @('{"ok": true}')
        }
        Invoke-McpProbe -PythonPath 'py.exe' -ProbeScript 'p.py' `
            -ProbeArgs @('--transport=http') | Out-Null
        ($Script:SeenArgs -join ' ') | Should -Not -BeLike '*--calls-file*'
    }
}

Describe 'the probe script' {
    It 'accepts a call sequence from a file' {
        $src = Get-Content (Join-Path $PSScriptRoot '..\tools\mcp_probe.py') -Raw
        $src | Should -BeLike '*--calls-file*'
    }
}

Describe 'Test-PyghidraLive' {
    BeforeAll {
        $Script:PgSrv = [PSCustomObject]@{
            name = 'pyghidra-mcp'; kind = 'venv-http'; transport = 'http'
            bind = '127.0.0.1'; port = 8762; path = '/mcp'; auth = 'none'
        }
        $Script:PgCfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ toolRoot = 'C:\re'; stateRoot = 'C:\re\state' }
        }
        $Script:Listed = '{ "programs": [ { "name": "/winver.exe-e678d1" } ] }'
    }

    It 'fails when the project holds no binaries' {
        Mock -ModuleName ReAgent.Verify Invoke-McpProbe {
            [PSCustomObject]@{ ok = $true
                call = [PSCustomObject]@{ text = '{ "programs": [] }'; length = 18 }
            }
        }
        $r = Test-PyghidraLive -Server $Script:PgSrv -Config $Script:PgCfg
        $r.Status | Should -Be 'fail'
        $r.Detail | Should -BeLike '*no binaries*'
    }

    It 'fails when the decompiler could not find the function' {
        # pyghidra-mcp answers with a JSON envelope carrying an empty 'code' and
        # an 'error' field. Its braces are not C, but a brace-matching heuristic
        # cannot tell the difference - so this reported pass on a dead check.
        $Script:PgCallNo = 0
        Mock -ModuleName ReAgent.Verify Invoke-McpProbe {
            $Script:PgCallNo++
            if ($Script:PgCallNo -eq 1) {
                return [PSCustomObject]@{ ok = $true
                    call = [PSCustomObject]@{ text = $Script:Listed; length = 50 }
                }
            }
            [PSCustomObject]@{ ok = $true
                call = [PSCustomObject]@{
                    text = '{ "name": "entry", "code": "", "error": "Function or symbol ''entry'' not found." }'
                    length = 174
                }
            }
        }
        $r = Test-PyghidraLive -Server $Script:PgSrv -Config $Script:PgCfg
        $r.Status | Should -Be 'fail'
        $r.Detail | Should -BeLike '*not found*'
    }

    It 'passes on real decompiled C' {
        $Script:PgCallNo = 0
        Mock -ModuleName ReAgent.Verify Invoke-McpProbe {
            $Script:PgCallNo++
            if ($Script:PgCallNo -eq 1) {
                return [PSCustomObject]@{ ok = $true
                    call = [PSCustomObject]@{ text = $Script:Listed; length = 50 }
                }
            }
            [PSCustomObject]@{ ok = $true
                call = [PSCustomObject]@{
                    text = '{ "name": "entry", "code": "void entry(void)\n\n{\n  FUN_140001000();\n  return;\n}\n" }'
                    length = 120
                }
            }
        }
        (Test-PyghidraLive -Server $Script:PgSrv -Config $Script:PgCfg).Status |
            Should -Be 'pass'
    }
}

Describe 'Test-PyghidraLive against the configured test binary' {
    BeforeAll {
        $Script:TbSrv = [PSCustomObject]@{
            name = 'pyghidra-mcp'; kind = 'venv-http'; transport = 'http'
            bind = '127.0.0.1'; port = 8762; path = '/mcp'; auth = 'none'
        }
        $Script:TbCfg = [PSCustomObject]@{
            paths      = [PSCustomObject]@{ toolRoot = 'C:\re'; stateRoot = 'C:\re\state' }
            testBinary = 'C:\Windows\System32\winver.exe'
        }
    }

    It 'decompiles the configured test binary, not whatever was imported first' {
        # Otherwise the check reports on whichever binary the analyst happened
        # to add, and passes or fails for reasons that have nothing to do with
        # the install.
        $Script:TbCall = 0
        Mock -ModuleName ReAgent.Verify Invoke-McpProbe {
            $Script:TbCall++
            if ($Script:TbCall -eq 1) {
                return [PSCustomObject]@{ ok = $true; call = [PSCustomObject]@{
                        text = '{ "programs": [ { "name": "/GoogleUpdate.exe-4dd864" }, ' +
                        '{ "name": "/winver.exe-e678d1" } ] }'
                        length = 90
                    }
                }
            }
            $Script:TbBinary = $Calls[0].args.binary_name
            [PSCustomObject]@{ ok = $true; call = [PSCustomObject]@{
                    text = '{ "name": "entry", "code": "void entry(void)\n{\n  return;\n}\n" }'
                    length = 60
                }
            }
        }
        (Test-PyghidraLive -Server $Script:TbSrv -Config $Script:TbCfg).Status | Should -Be 'pass'
        $Script:TbBinary | Should -Be '/winver.exe-e678d1'
    }

    It 'falls back to the first binary when the test binary was never imported' {
        $Script:TbCall = 0
        Mock -ModuleName ReAgent.Verify Invoke-McpProbe {
            $Script:TbCall++
            if ($Script:TbCall -eq 1) {
                return [PSCustomObject]@{ ok = $true; call = [PSCustomObject]@{
                        text = '{ "programs": [ { "name": "/GoogleUpdate.exe-4dd864" } ] }'
                        length = 50
                    }
                }
            }
            $Script:TbBinary = $Calls[0].args.binary_name
            [PSCustomObject]@{ ok = $true; call = [PSCustomObject]@{
                    text = '{ "name": "entry", "code": "void entry(void)\n{\n  return;\n}\n" }'
                    length = 60
                }
            }
        }
        (Test-PyghidraLive -Server $Script:TbSrv -Config $Script:TbCfg).Status | Should -Be 'pass'
        $Script:TbBinary | Should -Be '/GoogleUpdate.exe-4dd864'
    }
}
