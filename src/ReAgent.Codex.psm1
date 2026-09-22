Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ReAgent.Verify.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ReAgent.CodexVerify.psm1') -Force

function Invoke-CodexConfigurationCommand {
    <# .SYNOPSIS
        Runs Codex against an explicit home, capturing output without logging secrets.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CodexPath,
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $previousHome = $env:CODEX_HOME
    $previousPreference = $ErrorActionPreference
    try {
        $env:CODEX_HOME = $CodexHome
        Push-Location -LiteralPath $CodexHome
        try {
            # Native stderr is an ErrorRecord in Windows PowerShell. Capture it,
            # check the exit code, and never include TOML excerpts in an error.
            $ErrorActionPreference = 'Continue'
            $output = @(& $CodexPath @Arguments 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw 'Codex configuration command failed. Check config.toml syntax and Codex installation; output withheld because it may contain tokens.'
            }
            return ($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) -join "`n"
        } finally { Pop-Location }
    } finally {
        $env:CODEX_HOME = $previousHome
        $ErrorActionPreference = $previousPreference
    }
}

function ConvertTo-CodexTomlString {
    <# .SYNOPSIS
        Encodes a TOML basic string, including Windows paths and control characters.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return (ConvertTo-Json -InputObject $Value -Compress)
}

function New-CodexServerTable {
    <# .SYNOPSIS
        Builds a Codex table from an installed MVP server; pure, no writes.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([Parameter(Mandatory)][object]$Result, [Parameter(Mandatory)][string]$TokenRoot)
    if ($Result.Transport -eq 'sse') {
        throw "Legacy SSE server '$($Result.Name)' requires a stdio bridge; it cannot be registered as streamable HTTP. Keep ghidramcp disabled."
    }
    $table = 'mcp_servers.' + (ConvertTo-CodexTomlString $Result.Name)
    $lines = @("[$table]", ('enabled = ' + ([string][bool]$Result.Enabled).ToLowerInvariant()),
        'startup_timeout_sec = 60', 'tool_timeout_sec = 300')
    if ($Result.Transport -eq 'stdio') {
        if (-not $Result.Command -or -not $Result.Command.Executable) { throw "Missing launch command for '$($Result.Name)'." }
        $lines += 'command = ' + (ConvertTo-CodexTomlString $Result.Command.Executable)
        $values = @($Result.Command.Arguments | ForEach-Object { ConvertTo-CodexTomlString ([string]$_) })
        $lines += 'args = [' + ($values -join ', ') + ']'
        if ($Result.Command.Env) {
            $lines += "[$table.env]"
            foreach ($key in ($Result.Command.Env.Keys | Sort-Object)) {
                $lines += (ConvertTo-CodexTomlString $key) + ' = ' + (ConvertTo-CodexTomlString $Result.Command.Env[$key])
            }
        }
    } elseif ($Result.Transport -eq 'http') {
        $lines += 'url = ' + (ConvertTo-CodexTomlString "http://$($Result.Bind):$($Result.Port)$($Result.Path)")
        if ($Result.Auth -ne 'none') {
            $token = Get-ServerToken -Name $Result.Name -TokenRoot $TokenRoot
            if (-not $token) { throw "Missing bearer token for '$($Result.Name)'. Run server installation first." }
            $lines += "[$table.http_headers]"
            $lines += 'Authorization = ' + (ConvertTo-CodexTomlString "Bearer $token")
        }
    } else { throw "Unsupported transport '$($Result.Transport)'." }
    return $lines -join "`n"
}

function Write-CodexConfiguration {
    <# .SYNOPSIS
        Stages, validates and backs up a merge using Codex's own TOML parser.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$CodexPath,
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ServerResults,
        [Parameter(Mandatory)][string[]]$ManagedNames,
        [Parameter(Mandatory)][string]$TokenRoot
    )
    $path = Join-Path $CodexHome 'config.toml'
    if (-not $PSCmdlet.ShouldProcess($path, 'Merge RE Lab MCP servers')) { return }
    $unsupported = @($ServerResults | Where-Object {
        $_.Installed -and $_.Transport -notin @('http', 'stdio')
    })
    foreach ($result in $unsupported | Where-Object { $_.Enabled }) {
        Write-ReAgentLog -Level WARN -Message (
            "Skipping '$($result.Name)' in Codex: legacy $($result.Transport.ToUpperInvariant()) " +
            'is not a supported Codex MCP transport. The installed server remains available to Claude.')
    }
    $tables = @($ServerResults | Where-Object {
        $_.Installed -and $_.Transport -in @('http', 'stdio')
    } | Sort-Object Name | ForEach-Object {
        New-CodexServerTable -Result $_ -TokenRoot $TokenRoot
    })
    $original = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { '' }
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('reagent-codex-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $stage
    try {
        # The staged TOML contains bearer tokens. Only this user may read it.
        $acl = Get-Acl -LiteralPath $stage
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            [Security.Principal.WindowsIdentity]::GetCurrent().User,
            'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $stage -AclObject $acl
        $stagePath = Join-Path $stage 'config.toml'
        [IO.File]::WriteAllText($stagePath, $original)
        $invoke = @{ CodexPath = $CodexPath; CodexHome = $stage }
        $null = Invoke-CodexConfigurationCommand @invoke -Arguments @('mcp', 'list', '--json')
        $begin = '# BEGIN RE LAB MCP - managed by install-codex.ps1'
        $end = '# END RE LAB MCP'
        $pattern = '(?ms)^' + [regex]::Escape($begin) + '\r?\n.*?^' + [regex]::Escape($end) + '\r?\n?'
        $base = [regex]::Replace($original, $pattern, '')
        [IO.File]::WriteAllText($stagePath, $base)
        $existing = Invoke-CodexConfigurationCommand @invoke -Arguments @('mcp', 'list', '--json') | ConvertFrom-Json
        foreach ($entry in $existing) {
            if ($entry.name -in $ManagedNames) {
                $null = Invoke-CodexConfigurationCommand @invoke -Arguments @('mcp', 'remove', $entry.name)
            }
        }
        $base = [IO.File]::ReadAllText($stagePath).TrimEnd()
        $candidate = $base + "`n`n" + $begin + "`n" + ($tables -join "`n`n") + "`n" + $end + "`n"
        [IO.File]::WriteAllText($stagePath, $candidate)
        $null = Invoke-CodexConfigurationCommand @invoke -Arguments @('mcp', 'list', '--json')
        if ($candidate -ceq $original) {
            Write-ReAgentLog -Level INFO -Message 'Codex MCP configuration is already current.'
            return
        }
        $null = New-Item -ItemType Directory -Path $CodexHome -Force
        # Refuse to overwrite changes made while the candidate was being validated.
        $current = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { '' }
        if ($current -cne $original) { throw 'Codex config changed during installation. Re-run to merge the new settings.' }
        $pending = Join-Path $CodexHome ('config.' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllText($pending, $candidate)
            if (Test-Path -LiteralPath $path) {
                $backup = $path + '.' + [guid]::NewGuid().ToString('N') + '.bak'
                [IO.File]::Replace($pending, $path, $backup)
            } else { [IO.File]::Move($pending, $path) }
        } finally {
            if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -Force }
        }
        Write-ReAgentLog -Level INFO -Message "Configured Codex MCP servers in '$path'."
    } finally {
        # stage is a freshly created direct child of TEMP with a fixed prefix.
        $resolvedStage = [IO.Path]::GetFullPath($stage)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if ($resolvedStage.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedStage -Recurse -Force
        }
    }
}

function Get-CodexRegistrationCheck {
    <# .SYNOPSIS
        Checks every Codex-compatible enabled server registration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ServerResults,
        [Parameter(Mandatory)][string]$CodexPath,
        [Parameter(Mandatory)][string]$CodexHome
    )
    try {
        $invoke = @{ CodexPath = $CodexPath; CodexHome = $CodexHome }
        $null = Invoke-CodexConfigurationCommand @invoke -Arguments @('--version')
        $registered = Invoke-CodexConfigurationCommand @invoke -Arguments @('mcp', 'list', '--json') | ConvertFrom-Json
        $compatible = @($Config.mcpServers | Where-Object {
            $_.enabled -and $_.transport -in @('http', 'stdio')
        })
        foreach ($server in $compatible) {
            $entry = @($registered | Where-Object { $_.name -eq $server.name -and $_.enabled })
            if ($entry.Count -ne 1) { throw "Enabled server '$($server.name)' is missing from Codex configuration." }
            $transport = $entry[0].transport
            if ($server.transport -eq 'http') {
                $expectedUrl = "http://$($server.bind):$($server.port)$($server.path)"
                if ($transport.type -ne 'streamable_http' -or $transport.url -ne $expectedUrl) {
                    throw "Codex endpoint for '$($server.name)' differs from the MVP configuration. Re-run the installer."
                }
                if ($server.auth -ne 'none') {
                    $tokenRoot = Join-Path $Config.paths.toolRoot 'mcp\tokens'
                    $expectedToken = Get-ServerToken -Name $server.name -TokenRoot $tokenRoot
                    $headers = $transport.http_headers
                    if (-not $expectedToken -or -not $headers -or
                        $headers.PSObject.Properties.Name -notcontains 'Authorization' -or
                        $headers.Authorization -cne "Bearer $expectedToken" -or
                        $transport.bearer_token_env_var) {
                        throw "Codex bearer settings for '$($server.name)' differ from the installed token. Re-run the installer."
                    }
                }
            } elseif ($server.transport -eq 'stdio') {
                $result = $ServerResults | Where-Object { $_.Name -eq $server.name } | Select-Object -First 1
                if (-not $result -or -not $result.Command -or $transport.type -ne 'stdio' -or
                    $transport.command -ne $result.Command.Executable -or
                    (ConvertTo-Json -InputObject @($transport.args) -Compress) -cne
                    (ConvertTo-Json -InputObject @($result.Command.Arguments) -Compress)) {
                    throw "Codex launch command for '$($server.name)' differs from the installed server. Re-run the installer."
                }
                if ($result.Command.Env) {
                    foreach ($key in $result.Command.Env.Keys) {
                        if (-not $transport.env -or $transport.env.PSObject.Properties.Name -notcontains $key -or
                            $transport.env.$key -cne $result.Command.Env[$key]) {
                            throw "Codex environment for '$($server.name)' differs from the installed server. Re-run the installer."
                        }
                    }
                }
            }
        }
        $unsupportedServers = @($Config.mcpServers | Where-Object {
            $_.enabled -and $_.transport -notin @('http', 'stdio')
        })
        foreach ($server in $unsupportedServers) {
            $stale = @($registered | Where-Object { $_.name -eq $server.name -and $_.enabled })
            if ($stale.Count -gt 0) {
                throw "Unsupported legacy SSE server '$($server.name)' is still enabled in Codex configuration. Re-run the installer."
            }
        }
        $unsupported = @($unsupportedServers | Select-Object -ExpandProperty name | Sort-Object)
        $detail = "Codex reads all $($compatible.Count) enabled compatible server entries."
        if ($unsupported.Count) {
            $detail += " Skipped unsupported legacy SSE: $($unsupported -join ', ')."
        }
        return New-CheckResult -Name 'codex registration' -Status pass -Detail $detail
    } catch {
        return New-CheckResult -Name 'codex registration' -Status fail -Detail $_.Exception.Message
    }
}

function Invoke-CodexVerification {
    <# .SYNOPSIS
        Checks Codex registration and performs the existing real MCP tool probes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ServerResults,
        [Parameter(Mandatory)][string]$CodexPath,
        [Parameter(Mandatory)][string]$CodexHome,
        [switch]$Attended
    )
    $checks = @()
    $checks += Get-CodexRegistrationCheck -Config $Config -ServerResults $ServerResults `
        -CodexPath $CodexPath -CodexHome $CodexHome
    $checks += Get-ServerCheck -Config $Config -ServerResults $ServerResults -Attended:$Attended
    $null = Write-CodexVerificationReport -Config $Config -Checks $checks -Observations @()
    foreach ($check in $checks) {
        Write-ReAgentLog -Level INFO -Message "[$($check.Status)] $($check.Name): $($check.Detail)"
    }
    return $checks
}

Export-ModuleMember -Function Invoke-CodexConfigurationCommand, ConvertTo-CodexTomlString, `
    New-CodexServerTable, Write-CodexConfiguration, Get-CodexRegistrationCheck, `
    Invoke-CodexVerification
