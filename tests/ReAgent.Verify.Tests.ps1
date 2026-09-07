BeforeAll {
    Import-Module "$PSScriptRoot/../src/ReAgent.Common.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Discovery.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Config.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Symbols.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Servers.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Skills.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Verify.psm1" -Force
    Import-Module "$PSScriptRoot/../src/ReAgent.Manifest.psm1" -Force

    function New-SkillPackFixture {
        # Pure factory: builds and returns an in-memory PSCustomObject, writes nothing.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '')]
        param($Namespace = 'ghidra', $TargetServers = @('pyghidra-mcp'),
              $SkillName = 'ghidra-test')
        [PSCustomObject]@{
            namespace      = $Namespace
            enabled        = $true
            targetServers  = $TargetServers
            adaptation     = [PSCustomObject]@{ toolRenames = [PSCustomObject]@{} }
            scanExceptions = @()
            skills         = @([PSCustomObject]@{ upstream = 'x'; name = $SkillName
                    enabled = $true })
        }
    }

    function New-VendoredSkillFile {
        # Test fixture: writes only under $TestDrive, never touches real system state.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '')]
        param($Root, $Namespace, $SkillName, $Tools = @(), $Body = 'Test skill body.')
        $d = Join-Path $Root "vendor\skills\$Namespace\$SkillName"
        $null = New-Item -ItemType Directory -Path $d -Force
        $lines = @('---', "name: $SkillName", 'description: Test skill.')
        if ($Tools.Count -gt 0) {
            $lines += 'allowed-tools:'
            foreach ($t in $Tools) { $lines += "  - $t" }
        }
        $lines += @('---', $Body)
        ($lines -join "`n") | Set-Content -LiteralPath (Join-Path $d 'SKILL.md')
    }
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

Describe 'Get-ServerCheck' {
    It 'reports a server with no result record as unknown rather than not installed' {
        $cfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ stateRoot = (Join-Path $TestDrive 'gsc-state') }
            mcpServers = @([PSCustomObject]@{ name = 'ghost'; enabled = $true
                    requiresHostApp = $false })
        }
        $checks = @(Get-ServerCheck -Config $cfg -ServerResults @())
        $checks[0].Status | Should -Be 'not-testable'
        $checks[0].Detail | Should -BeLike '*no manifest entry*'
    }

    It 'reports an attended server as not-testable when the run is unattended' {
        $cfg = [PSCustomObject]@{
            paths = [PSCustomObject]@{ stateRoot = (Join-Path $TestDrive 'gsc-state2') }
            mcpServers = @([PSCustomObject]@{ name = 'binaryninja'; enabled = $true
                    requiresHostApp = $true })
        }
        $results = @([PSCustomObject]@{ Name = 'binaryninja'; Installed = $true })
        $checks = @(Get-ServerCheck -Config $cfg -ServerResults $results)
        $checks[0].Status | Should -Be 'not-testable'
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

Describe 'Get-SkillCheck' {
    It 'fails a pack whose skill declares a tool the catalog does not have' {
        # names the server, the tool and the advertised list, so the fix is obvious
        $repo = Join-Path $TestDrive 'gsc-badtool'
        New-VendoredSkillFile -Root $repo -Namespace 'ghidra' -SkillName 'ghidra-test' `
            -Tools @('mcp__pyghidra-mcp__not_a_real_tool')
        $cfg = [PSCustomObject]@{
            mcpServers = @([PSCustomObject]@{ name = 'pyghidra-mcp' })
            skills     = @(New-SkillPackFixture)
        }
        $results = @([PSCustomObject]@{ Namespace = 'ghidra'; Installed = $true; Reason = '' })
        $checks = @(Get-SkillCheck -Config $cfg -SkillResults $results -RepoRoot $repo)
        $c = $checks | Where-Object { $_.Name -eq 'ghidra skill adaptation' }
        $c.Status | Should -Be 'fail'
        $c.Detail | Should -BeLike '*does not advertise*'
    }

    It 'passes a pack whose skills declare no MCP tools' {
        $repo = Join-Path $TestDrive 'gsc-notools'
        New-VendoredSkillFile -Root $repo -Namespace 'ghidra' -SkillName 'ghidra-test'
        $cfg = [PSCustomObject]@{
            mcpServers = @([PSCustomObject]@{ name = 'pyghidra-mcp' })
            skills     = @(New-SkillPackFixture)
        }
        $results = @([PSCustomObject]@{ Namespace = 'ghidra'; Installed = $true; Reason = '' })
        $checks = @(Get-SkillCheck -Config $cfg -SkillResults $results -RepoRoot $repo)
        $c = $checks | Where-Object { $_.Name -eq 'ghidra skill adaptation' }
        $c.Status | Should -Be 'pass'
        $c.Detail | Should -BeLike '*nothing to check*'
    }

    It 'reports a pack with no manifest record as unknown, not as uninstalled' {
        $repo = Join-Path $TestDrive 'gsc-unknown'
        $cfg = [PSCustomObject]@{
            mcpServers = @([PSCustomObject]@{ name = 'pyghidra-mcp' })
            skills     = @(New-SkillPackFixture)
        }
        $checks = @(Get-SkillCheck -Config $cfg -SkillResults @() -RepoRoot $repo)
        $c = $checks | Where-Object { $_.Name -eq 'ghidra skill adaptation' }
        $c.Status | Should -Be 'not-testable'
        $c.Detail | Should -BeLike '*no manifest entry*'
    }

    It 'reports a not-installed pack as not-testable with its recorded reason' {
        $repo = Join-Path $TestDrive 'gsc-notinstalled'
        $cfg = [PSCustomObject]@{
            mcpServers = @([PSCustomObject]@{ name = 'pyghidra-mcp' })
            skills     = @(New-SkillPackFixture)
        }
        $results = @([PSCustomObject]@{ Namespace = 'ghidra'; Installed = $false
                Reason = 'disabled in re-agent.config.json' })
        $checks = @(Get-SkillCheck -Config $cfg -SkillResults $results -RepoRoot $repo)
        $c = $checks | Where-Object { $_.Name -eq 'ghidra skill adaptation' }
        $c.Status | Should -Be 'not-testable'
        $c.Detail | Should -BeLike '*disabled in re-agent.config.json*'
    }

    It 'returns nothing when the config declares no skills key at all' {
        $cfg = [PSCustomObject]@{ mcpServers = @() }
        @(Get-SkillCheck -Config $cfg -SkillResults @() -RepoRoot $TestDrive).Count |
            Should -Be 0
    }
}

Describe 'Test-ToolCatalogPin' {
    BeforeAll { $Script:PinCat = Get-ToolCatalog }

    It 'passes when the catalog pin matches the current config pin' {
        (Test-ToolCatalogPin -Catalog $Script:PinCat -Server 'pyghidra-mcp' `
                -CurrentPin '0.2.5').Status | Should -Be 'pass'
    }

    It 'fails when config has moved on from the recorded pin' {
        $c = Test-ToolCatalogPin -Catalog $Script:PinCat -Server 'pyghidra-mcp' `
            -CurrentPin '0.2.6'
        $c.Status | Should -Be 'fail'
        $c.Detail | Should -BeLike '*0.2.6*'
    }

    It 'is not-testable with the refresh command when the catalog has no entry' {
        $c = Test-ToolCatalogPin -Catalog $Script:PinCat -Server 'binaryninja' `
            -CurrentPin '6.0.10601'
        $c.Status | Should -Be 'not-testable'
        $c.Detail | Should -BeLike '*-UpdateToolCatalog*'
    }
}

Describe 'Test-ToolCatalogLive' {
    BeforeAll { $Script:LiveCat = Get-ToolCatalog }

    It 'reports drift with the count delta and the names that changed' {
        Mock -ModuleName ReAgent.Verify Invoke-McpProbe {
            [PSCustomObject]@{ ok = $true; toolCount = 2
                tools = @('decompile_function', 'brand_new') }
        }
        $c = Test-ToolCatalogLive -PythonPath 'py.exe' `
            -ProbeArgs @('--transport=http', '--url=http://127.0.0.1:8762/mcp') `
            -Server 'pyghidra-mcp' -Catalog $Script:LiveCat
        $c.Status | Should -Be 'fail'
        $c.Detail | Should -BeLike '*brand_new*'
    }

    It 'is not-testable rather than fail when the server is unreachable' {
        # An unreachable attended server is a closed GUI, not an adaptation defect.
        Mock -ModuleName ReAgent.Verify Invoke-McpProbe {
            [PSCustomObject]@{ ok = $false; error = 'ConnectError' }
        }
        $c = Test-ToolCatalogLive -PythonPath 'py.exe' `
            -ProbeArgs @('--transport=http', '--url=http://127.0.0.1:8762/mcp') `
            -Server 'pyghidra-mcp' -Catalog $Script:LiveCat
        $c.Status | Should -Be 'not-testable'
    }

    It 'passes when the live tool list matches the catalog exactly' {
        Mock -ModuleName ReAgent.Verify Invoke-McpProbe {
            [PSCustomObject]@{ ok = $true; toolCount = $Script:LiveCat.servers.'mcp-windbg'.toolCount
                tools = @($Script:LiveCat.servers.'mcp-windbg'.tools) }
        }
        $c = Test-ToolCatalogLive -PythonPath 'py.exe' -ProbeArgs @('--transport=stdio') `
            -Server 'mcp-windbg' -Catalog $Script:LiveCat
        $c.Status | Should -Be 'pass'
    }

    It 'is not-testable rather than fail when a live server has no catalog entry yet' {
        # binaryninja has no entry in data/tool-catalog.json before its first attended
        # capture (design doc SS8.3). Every one of its real tools would otherwise read
        # as 'added' against an empty baseline, misreporting unmeasured as broken.
        Mock -ModuleName ReAgent.Verify Invoke-McpProbe {
            [PSCustomObject]@{ ok = $true; toolCount = 1; tools = @('some_tool') }
        }
        $c = Test-ToolCatalogLive -PythonPath 'py.exe' `
            -ProbeArgs @('--transport=http', '--url=http://127.0.0.1:24642/mcp') `
            -Server 'binaryninja' -Catalog $Script:LiveCat
        $c.Status | Should -Be 'not-testable'
        $c.Detail | Should -BeLike '*-UpdateToolCatalog*'
    }
}

Describe 'Test-SkillDriftCheck' {
    It 'fails when the config pin has moved on from the catalog, with no server needed' {
        $cat = Get-ToolCatalog
        $cfg = [PSCustomObject]@{
            mcpServers = @([PSCustomObject]@{ name = 'pyghidra-mcp'; verifyTier = 'unattended'
                    transport = 'http'; bind = '127.0.0.1'; port = 8762; path = '/mcp'
                    source = [PSCustomObject]@{ pin = '0.2.6' }
                })
        }
        $pack = New-SkillPackFixture -Namespace 'ghidra' -TargetServers @('pyghidra-mcp')
        $c = Test-SkillDriftCheck -Pack $pack -Config $cfg -Catalog $cat
        $c.Name | Should -Be 'ghidra skill drift'
        $c.Status | Should -Be 'fail'
        $c.Detail | Should -BeLike '*0.2.6*'
    }

    It 'is not-testable when an attended target server has no -Attended run behind it' {
        $cat = Get-ToolCatalog
        $cfg = [PSCustomObject]@{
            mcpServers = @([PSCustomObject]@{ name = 'binaryninja'; verifyTier = 'attended'
                    transport = 'http'; bind = '127.0.0.1'; port = 24642; path = '/mcp'
                    source = [PSCustomObject]@{ pin = '6.0.10601' }
                })
        }
        $pack = New-SkillPackFixture -Namespace 'bn' -TargetServers @('binaryninja')
        $c = Test-SkillDriftCheck -Pack $pack -Config $cfg -Catalog $cat
        $c.Status | Should -Be 'not-testable'
    }
}

Describe 'Save-ToolCatalog' {
    BeforeAll {
        function New-CatalogProbeConfig {
            # Pure factory: builds and returns an in-memory PSCustomObject, writes nothing.
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
                'PSUseShouldProcessForStateChangingFunctions', '')]
            param($ToolRoot)
            [PSCustomObject]@{
                mcpServers = @([PSCustomObject]@{
                        name = 'pyghidra-mcp'; enabled = $true; verifyTier = 'unattended'
                        transport = 'http'; bind = '127.0.0.1'; port = 8762; path = '/mcp'
                        source = [PSCustomObject]@{ pin = '0.2.6' }
                    })
                paths      = [PSCustomObject]@{ toolRoot = $ToolRoot }
            }
        }
    }

    It 'leaves an unreachable server entry untouched rather than erasing it' {
        # A closed GUI must never silently wipe a good catalog entry.
        $path = Join-Path $TestDrive 'stc-untouched.json'
        $before = [ordered]@{
            capturedAt = '2026-01-01T00:00:00.0000000Z'; capturedBy = 'previous-run'
            servers    = [ordered]@{
                'pyghidra-mcp' = [ordered]@{ pin = '0.2.5'; toolCount = 20
                    tools = @('decompile_function') }
            }
        }
        ($before | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path

        # No server venv exists under this ToolRoot, so the probe cannot even
        # start - the same "unreachable" outcome a closed GUI produces.
        $noServerRoot = Join-Path $TestDrive 'stc-noserver'
        Save-ToolCatalog -Config (New-CatalogProbeConfig -ToolRoot $noServerRoot) -Path $path `
            -Confirm:$false | Out-Null

        $after = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $after.servers.'pyghidra-mcp'.pin | Should -Be '0.2.5'
        $after.servers.'pyghidra-mcp'.tools | Should -Contain 'decompile_function'
    }

    It 'merges a reachable server''s live tools into the catalog' {
        # Get-ProbeInterpreter needs a real interpreter file to find before the
        # mocked Invoke-McpProbe is ever reached.
        $toolRoot = Join-Path $TestDrive 'stc-merge-root'
        $venvScripts = Join-Path $toolRoot 'mcp\venvs\pyghidra-mcp\Scripts'
        $null = New-Item -ItemType Directory -Path $venvScripts -Force
        $null = New-Item -ItemType File -Path (Join-Path $venvScripts 'python.exe') -Force

        Mock -ModuleName ReAgent.Verify Invoke-McpProbe {
            [PSCustomObject]@{ ok = $true; toolCount = 3
                tools = @('a', 'b', 'c') }
        }
        $path = Join-Path $TestDrive 'stc-merge.json'
        Save-ToolCatalog -Config (New-CatalogProbeConfig -ToolRoot $toolRoot) -Path $path `
            -Confirm:$false | Out-Null

        $after = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $after.servers.'pyghidra-mcp'.pin | Should -Be '0.2.6'
        $after.servers.'pyghidra-mcp'.tools | Should -Contain 'b'
    }

    It 'is never called without the explicit switch' {
        # A baseline that updates itself to match what it observes cannot fail.
        $src = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Install-REAgent.ps1') -Raw
        $callSites = @($src -split "`n" | Select-String -SimpleMatch 'Save-ToolCatalog')
        $callSites.Count | Should -Be 1
        $src -match '(?s)if\s*\(\s*\$UpdateToolCatalog\s*\)\s*\{[^}]*Save-ToolCatalog' |
            Should -BeTrue
    }
}
