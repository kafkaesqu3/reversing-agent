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
