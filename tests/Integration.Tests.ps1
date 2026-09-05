BeforeAll {
    $Script:Root = Join-Path $PSScriptRoot '..'
    foreach ($m in @('Common', 'Config', 'Discovery', 'Prereqs', 'Symbols',
            'Tokens', 'Json', 'Servers', 'Generate', 'Verify', 'Manifest')) {
        Import-Module (Join-Path $Script:Root "src\ReAgent.$m.psm1") -Force
    }
}

Describe 'the entry point script' {
    It 'parses as valid PowerShell' {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $Script:Root 'Install-REAgent.ps1'), [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'imports every module it names' {
        $text = Get-Content (Join-Path $Script:Root 'Install-REAgent.ps1') -Raw
        if ($text -match "moduleNames = @\(([^)]+)\)") {
            $names = $Matches[1] -split ',' | ForEach-Object { $_.Trim().Trim("'") }
            foreach ($n in $names) {
                Test-Path (Join-Path $Script:Root "src\ReAgent.$n.psm1") | Should -BeTrue
            }
        } else {
            throw 'Could not find the module list in the entry point.'
        }
    }

    It 'calls every phase function it declares' {
        $text = Get-Content (Join-Path $Script:Root 'Install-REAgent.ps1') -Raw
        foreach ($fn in @('Get-HostInventory', 'Assert-Preflight', 'Test-PrereqSatisfied',
                'Install-Prereq', 'Test-SymbolsReady', 'Install-Symbols',
                'Install-AllMcpServer', 'Write-AgentConfiguration',
                'Invoke-Verification', 'Write-Manifest')) {
            $text | Should -BeLike "*$fn*"
            Get-Command $fn -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'the shipped config drives the real modules' {
    BeforeAll {
        $Script:Cfg = Get-ReAgentConfig -Path (Join-Path $Script:Root 're-agent.config.json')
    }

    It 'allocates a distinct port to every HTTP server' {
        $map = Get-ServerPortMap -Config $Script:Cfg
        ($map.Values | Sort-Object -Unique).Count | Should -Be $map.Count
    }

    It 'names a scheduled task for every venv-http server' {
        foreach ($s in $Script:Cfg.mcpServers | Where-Object { $_.kind -eq 'venv-http' }) {
            $s.scheduledTask | Should -Not -BeNullOrEmpty
        }
    }

    It 'gives every server a kind the dispatcher can handle' {
        $handled = @('plugin-inproc', 'venv-stdio', 'venv-http',
            'gui-builtin-http', 'gui-plugin-http')
        foreach ($s in $Script:Cfg.mcpServers) { $handled | Should -Contain $s.kind }
    }

    It 'generates a settings file disabling exactly the disabled servers' {
        $s = New-ClaudeSettingsObject -Config $Script:Cfg
        $s.disabledMcpjsonServers | Should -Contain 'ghidramcp'
        $s.disabledMcpjsonServers.Count | Should -Be 1
    }
}

Describe 'the idempotency contract' {
    BeforeAll {
        $Script:IdemCfg = [PSCustomObject]@{
            version    = 1
            paths      = [PSCustomObject]@{
                toolRoot  = (Join-Path $TestDrive 'idem')
                agentRoot = (Join-Path $TestDrive 'idem\agent')
                stateRoot = (Join-Path $TestDrive 'idem\state')
            }
            mcpServers = @([PSCustomObject]@{ name = 'ghidramcp'; enabled = $false })
        }
        $Script:IdemResults = @([PSCustomObject]@{
                Name    = 'pyghidra-mcp'; Transport = 'http'; Bind = '127.0.0.1'
                Port    = 8762; Path = '/mcp'; Auth = 'none'; Installed = $true
                Command = $null
            })
        $Script:Tpl = Join-Path $Script:Root 'templates'
    }

    It 'regenerates .mcp.json byte-identically' {
        $p = Join-Path $Script:IdemCfg.paths.agentRoot '.mcp.json'
        Write-AgentConfiguration -Config $Script:IdemCfg -ServerResults $Script:IdemResults `
            -TemplateRoot $Script:Tpl | Out-Null
        $a = [IO.File]::ReadAllBytes($p)
        Write-AgentConfiguration -Config $Script:IdemCfg -ServerResults $Script:IdemResults `
            -TemplateRoot $Script:Tpl | Out-Null
        $b = [IO.File]::ReadAllBytes($p)
        [Convert]::ToBase64String($b) | Should -Be ([Convert]::ToBase64String($a))
    }

    It 'regenerates settings.json byte-identically' {
        $p = Join-Path $Script:IdemCfg.paths.agentRoot '.claude\settings.json'
        Write-AgentConfiguration -Config $Script:IdemCfg -ServerResults $Script:IdemResults `
            -TemplateRoot $Script:Tpl | Out-Null
        $a = [IO.File]::ReadAllBytes($p)
        Write-AgentConfiguration -Config $Script:IdemCfg -ServerResults $Script:IdemResults `
            -TemplateRoot $Script:Tpl | Out-Null
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($p)) |
            Should -Be ([Convert]::ToBase64String($a))
    }

    It 'never rotates a token that already exists' {
        # Rotating breaks whatever server is already running with the old value.
        $root = Join-Path $TestDrive 'idem-tokens'
        $first = Get-OrNewServerToken -Name 'binaryninja' -TokenRoot $root
        Get-OrNewServerToken -Name 'binaryninja' -TokenRoot $root | Should -Be $first
        Get-OrNewServerToken -Name 'binaryninja' -TokenRoot $root | Should -Be $first
    }

    It 'leaves an unchanged plugin file alone on a second deploy' {
        $src = Join-Path $TestDrive 'plug-src.dp64'; 'binary' | Set-Content $src
        $dst = Join-Path $TestDrive 'plug-dst.dp64'
        Copy-PluginFile -Source $src -Destination $dst | Should -BeTrue
        Copy-PluginFile -Source $src -Destination $dst | Should -BeFalse
    }

    It 'preserves an x64dbg token across a re-seed' {
        $p = Join-Path $TestDrive 'reseed.json'
        Write-X64dbgPreseed -ConfigPath $p -Bind '127.0.0.1' -Port 9094 `
            -Token 'firsttoken' -Confirm:$false
        $token = Get-X64dbgToken -McpConfigPath $p
        Write-X64dbgPreseed -ConfigPath $p -Bind '127.0.0.1' -Port 9094 `
            -Token $token -Confirm:$false
        Get-X64dbgToken -McpConfigPath $p | Should -Be 'firsttoken'
    }

    It 'reports a satisfied phase as skipped on the second run' {
        $state = @{ Runs = 0 }
        $phase = @{
            Id   = 9; Name = 'Demo'
            Test = { $state.Runs -gt 0 }
            Fn   = { $state.Runs++ }
        }
        (Invoke-Phase -Phase $phase -Context @{}).Status | Should -Be 'ok'
        (Invoke-Phase -Phase $phase -Context @{}).Status | Should -Be 'skipped'
        $state.Runs | Should -Be 1
    }
}

Describe 'the security invariants' {
    BeforeAll {
        $Script:Shipped = Get-ReAgentConfig -Path (Join-Path $Script:Root 're-agent.config.json')
    }

    It 'binds every server to loopback' {
        foreach ($s in $Script:Shipped.mcpServers) { $s.bind | Should -Be '127.0.0.1' }
    }

    It 'documents a reason for every server without authentication' {
        foreach ($s in $Script:Shipped.mcpServers) {
            if ($s.transport -eq 'stdio') { continue }
            if ($s.auth -eq 'none') {
                $s.authExemptReason | Should -Not -BeNullOrEmpty
            }
        }
    }

    It 'refuses to seed a debugger config on a non-loopback address' {
        { Write-X64dbgPreseed -ConfigPath (Join-Path $TestDrive 'bad.json') `
                -Bind '0.0.0.0' -Port 9094 -Token 't' -Confirm:$false } | Should -Throw
    }

    It 'refuses a config that binds a server off loopback' {
        $bad = Get-Content (Join-Path $Script:Root 're-agent.config.json') -Raw | ConvertFrom-Json
        $bad.mcpServers[0].bind = '0.0.0.0'
        { Test-ReAgentConfigSchema -Config $bad } | Should -Throw '*0.0.0.0*'
    }
}
