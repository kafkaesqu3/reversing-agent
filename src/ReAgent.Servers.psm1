Set-StrictMode -Version Latest

# Depends on functions exported by sibling modules, which Install-REAgent.ps1
# imports into the session before this one: Write-ReAgentLog (Common),
# Invoke-CommandLine (Discovery), Get-SymbolPathValue (Symbols).

$Script:ValidServerStatus = @('installed', 'skipped', 'not-installed', 'failed')

function New-ServerResult {
    <#
    .SYNOPSIS
        Builds the per-server record that Phase 4 and the manifest both consume.
    .DESCRIPTION
        Every server produces one of these whatever happens, so a failure is
        always as visible in the manifest as a success.
    .PARAMETER Server
        The server's config entry.
    .PARAMETER Status
        One of installed, skipped, not-installed, failed.
    .PARAMETER Reason
        Why, for any status other than installed.
    .PARAMETER Version
        The version actually installed, where that is discoverable.
    .PARAMETER Command
        Resolved launch command, for stdio servers.
    .EXAMPLE
        New-ServerResult -Server $s -Status 'installed' -Version '0.2.5'
    #>
    [CmdletBinding()]
    # A pure factory: builds and returns a record, touches nothing else.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][string]$Status,
        [string]$Reason = '',
        [string]$Version = '',
        [object]$Command = $null
    )
    if ($Script:ValidServerStatus -notcontains $Status) {
        throw ("Invalid server status '$Status'. Expected one of: " +
            ($Script:ValidServerStatus -join ', '))
    }

    [PSCustomObject]@{
        Name      = $Server.name
        Kind      = $Server.kind
        Enabled   = [bool]$Server.enabled
        Transport = $Server.transport
        Bind      = $Server.bind
        Port      = $Server.port
        Path      = if ($Server.PSObject.Properties.Name -contains 'path') { $Server.path } else { '' }
        Auth      = $Server.auth
        Installed = ($Status -eq 'installed' -or $Status -eq 'skipped')
        Status    = $Status
        Reason    = $Reason
        Version   = $Version
        Command   = $Command
    }
}

function Get-VenvPython {
    <#
    .SYNOPSIS
        Returns the interpreter path inside a virtual environment.
    .PARAMETER VenvPath
        The venv root directory.
    .EXAMPLE
        Get-VenvPython -VenvPath 'C:\re\mcp\venvs\mcp-windbg'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VenvPath)
    return (Join-Path $VenvPath 'Scripts\python.exe')
}

function Get-VenvPackageVersion {
    <#
    .SYNOPSIS
        Returns the installed version of a package inside a venv, or $null.
    .DESCRIPTION
        Read from importlib.metadata, NOT from the MCP handshake: pyghidra-mcp
        reports its mcp library version in serverInfo, not its own.
    .PARAMETER VenvPath
        The venv root directory.
    .PARAMETER Package
        Distribution name.
    .EXAMPLE
        Get-VenvPackageVersion -VenvPath $v -Package 'pyghidra-mcp'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VenvPath,
        [Parameter(Mandatory)][string]$Package
    )

    $python = Get-VenvPython -VenvPath $VenvPath
    if (-not (Test-Path -LiteralPath $python)) { return $null }
    try {
        $code = "import importlib.metadata as m; print(m.version('$Package'))"
        $out = Invoke-CommandLine -FilePath $python -Arguments @('-c', $code)
        $text = (@($out) -join '').Trim()
        if ($text -match '^\d+\.\d+') { return $text }
        return $null
    } catch {
        return $null
    }
}

function Install-VenvPackage {
    <#
    .SYNOPSIS
        Creates a dedicated venv and installs one pinned package into it.
    .DESCRIPTION
        uv is used for both creation and install: it is what the upstream docs
        recommend, it pins cleanly, and it is far faster than venv + pip. Each
        server gets its own venv; nothing is ever shared, and the system Python
        is never modified.

        Idempotent: an existing venv already carrying the pinned version is left
        alone rather than reinstalled.
    .PARAMETER VenvPath
        Where the venv lives.
    .PARAMETER Package
        Distribution name.
    .PARAMETER Pin
        Exact version to install.
    .PARAMETER UvPath
        Path to uv.exe.
    .EXAMPLE
        Install-VenvPackage -VenvPath $v -Package 'mcp-windbg' -Pin '1.2.1' -UvPath $uv
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$VenvPath,
        [Parameter(Mandatory)][string]$Package,
        [Parameter(Mandatory)][string]$Pin,
        [Parameter(Mandatory)][string]$UvPath
    )

    $current = Get-VenvPackageVersion -VenvPath $VenvPath -Package $Package
    if ($current -eq $Pin) {
        Write-ReAgentLog -Level INFO -Message "$Package $Pin already present in '$VenvPath'."
        return $current
    }

    if (-not $PSCmdlet.ShouldProcess($VenvPath, "Install $Package==$Pin")) { return $current }

    if (-not (Test-Path -LiteralPath (Get-VenvPython -VenvPath $VenvPath))) {
        Write-ReAgentLog -Level INFO -Message "Creating venv at '$VenvPath'."
        $null = Invoke-CommandLine -FilePath $UvPath -Arguments @('venv', $VenvPath)
    }

    Write-ReAgentLog -Level INFO -Message "Installing $Package==$Pin into '$VenvPath'."
    $null = Invoke-CommandLine -FilePath $UvPath -Arguments @(
        'pip', 'install', '--python', (Get-VenvPython -VenvPath $VenvPath), "$Package==$Pin")

    return (Get-VenvPackageVersion -VenvPath $VenvPath -Package $Package)
}

function Write-ServerLauncher {
    <#
    .SYNOPSIS
        Writes a .cmd launcher that sets environment variables then runs a server.
    .DESCRIPTION
        A Windows scheduled task action cannot carry environment variables, and
        pyghidra-mcp will not start without GHIDRA_INSTALL_DIR. A tiny launcher
        script is the least surprising way to bridge that, and it also gives the
        operator something runnable by hand when a server misbehaves.

        Regenerated unconditionally: it is derived state.
    .PARAMETER Path
        Destination .cmd file.
    .PARAMETER Executable
        Program to run.
    .PARAMETER Arguments
        Arguments, already split.
    .PARAMETER Environment
        Environment variables to set first.
    .EXAMPLE
        Write-ServerLauncher -Path $p -Executable $exe -Arguments $a -Environment $e
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Executable,
        [string[]]$Arguments = @(),
        [hashtable]$Environment = @{}
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }

    $lines = @('@echo off',
        'REM Generated by Install-REAgent.ps1 - do not edit; it is rewritten every run.')
    foreach ($k in ($Environment.Keys | Sort-Object)) {
        $lines += "set `"$k=$($Environment[$k])`""
    }
    $quoted = $Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }
    $lines += ('"' + $Executable + '" ' + ($quoted -join ' ')).TrimEnd()

    Set-Content -LiteralPath $Path -Value $lines -Encoding ASCII
    return $Path
}

function Get-ServerVenvPath {
    <#
    .SYNOPSIS
        Returns the dedicated venv directory for a server. Never shared.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Name
        Server name.
    .EXAMPLE
        Get-ServerVenvPath -Config $cfg -Name 'mcp-windbg'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$Name
    )
    return (Join-Path $Config.paths.toolRoot "mcp\venvs\$Name")
}

function Invoke-ChromaPrewarm {
    <#
    .SYNOPSIS
        Downloads chromadb's embedding model ahead of first use. Best-effort.
    .DESCRIPTION
        pyghidra-mcp indexes through chromadb, which fetches an ~80 MB
        all-MiniLM-L6-v2 ONNX model into %USERPROFILE%\.cache\chroma the first
        time it embeds anything. Left to happen on demand, the operator's first
        real tool call stalls on a silent download that looks exactly like a
        hang. Never fails the phase: a slow first call beats a failed install.
    .PARAMETER VenvPath
        The pyghidra-mcp venv.
    .EXAMPLE
        Invoke-ChromaPrewarm -VenvPath $v
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VenvPath)

    $python = Get-VenvPython -VenvPath $VenvPath
    $code = 'from chromadb.utils.embedding_functions.onnx_mini_lm_l6_v2 ' +
    'import ONNXMiniLM_L6_V2; ONNXMiniLM_L6_V2()([chr(119)])'
    Write-ReAgentLog -Level INFO -Message 'Pre-warming the chromadb embedding model (~80 MB).'
    try {
        $null = Invoke-CommandLine -FilePath $python -Arguments @('-c', $code)
    } catch {
        Write-ReAgentLog -Level WARN -Message (
            "chromadb pre-warm failed: $($_.Exception.Message). The model will " +
            'download on the first pyghidra-mcp tool call instead, which will look slow.')
    }
}

function Get-ScheduledTaskActionText {
    <#
    .SYNOPSIS
        Returns a registered task's action as text, or $null. Exists as a mock seam.
    .PARAMETER Name
        Task name.
    .EXAMPLE
        Get-ScheduledTaskActionText -Name 'ReLab-pyghidra-mcp'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    try {
        $task = Get-ScheduledTask -TaskName $Name -ErrorAction Stop
        return (@($task.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ';').Trim()
    } catch {
        return $null
    }
}

function Register-ServerScheduledTask {
    <#
    .SYNOPSIS
        Registers a logon task that keeps an HTTP MCP server listening.
    .DESCRIPTION
        Claude Code spawns stdio servers on demand but cannot start an HTTP one,
        so pyghidra-mcp needs an owner. Registered for the invoking user at
        logon, running the generated launcher so the server's environment is set.

        Idempotent: the existing action is compared first and the task is only
        rewritten when it differs.
    .PARAMETER Name
        Task name.
    .PARAMETER LauncherPath
        The .cmd to run.
    .EXAMPLE
        Register-ServerScheduledTask -Name 'ReLab-pyghidra-mcp' -LauncherPath $p
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$LauncherPath
    )

    $wanted = "$LauncherPath".Trim()
    $current = Get-ScheduledTaskActionText -Name $Name
    if ($current -and $current -eq $wanted) {
        Write-ReAgentLog -Level INFO -Message "Scheduled task '$Name' is already current."
        return $false
    }

    if (-not $PSCmdlet.ShouldProcess($Name, 'Register logon scheduled task')) { return $false }

    Write-ReAgentLog -Level INFO -Message "Registering logon scheduled task '$Name'."
    $action = New-ScheduledTaskAction -Execute $LauncherPath
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    $null = Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger `
        -Settings $settings -Force
    return $true
}

function Install-VenvStdioServer {
    <#
    .SYNOPSIS
        Installs a stdio MCP server into its own venv and resolves its launch command.
    .DESCRIPTION
        Claude Code starts these on demand, so there is no lifecycle to own.
        Currently mcp-windbg; its cdb path and symbol path are resolved here
        rather than trusted to auto-detection, because the WinDbg MSIX package
        that ships cdb.exe is not on PATH.
    .PARAMETER Server
        The server's config entry.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Inventory
        The host inventory.
    .EXAMPLE
        Install-VenvStdioServer -Server $s -Config $cfg -Inventory $inv
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Inventory
    )

    if (-not $Inventory.Cdb) {
        return New-ServerResult -Server $Server -Status 'not-installed' -Reason (
            'cdb.exe was not found. Install WinDbg from the Microsoft Store, then re-run.')
    }

    $venv = Get-ServerVenvPath -Config $Config -Name $Server.name
    $version = Install-VenvPackage -VenvPath $venv -Package $Server.source.package `
        -Pin $Server.source.pin -UvPath $Inventory.Uv

    $symbolPath = Get-SymbolPathValue -CacheDir $Config.paths.symbolCache `
        -Server $Config.symbols.server

    $command = [PSCustomObject]@{
        Executable = Get-VenvPython -VenvPath $venv
        Arguments  = @('-m', 'mcp_windbg',
            '--cdb-path', $Inventory.Cdb,
            '--symbols-path', $symbolPath)
        Env        = @{ _NT_SYMBOL_PATH = $symbolPath }
    }

    return New-ServerResult -Server $Server -Status 'installed' -Version $version `
        -Command $command
}

function Install-VenvHttpServer {
    <#
    .SYNOPSIS
        Installs an HTTP MCP server into its own venv and gives it a lifecycle.
    .DESCRIPTION
        Currently pyghidra-mcp. It runs over streamable-http rather than stdio
        because under stdio its symbol setup prints to stdout - which IS the MCP
        channel - and the analysis dies while the handshake still succeeds.

        HTTP means nothing spawns it on demand, so a logon scheduled task owns
        it, driven by a generated launcher that carries GHIDRA_INSTALL_DIR.
    .PARAMETER Server
        The server's config entry.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Inventory
        The host inventory.
    .EXAMPLE
        Install-VenvHttpServer -Server $s -Config $cfg -Inventory $inv
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Inventory
    )

    if (-not $Inventory.GhidraRoot) {
        return New-ServerResult -Server $Server -Status 'not-installed' -Reason (
            'Ghidra was not found, and pyghidra-mcp cannot run without it.')
    }

    $venv = Get-ServerVenvPath -Config $Config -Name $Server.name
    $version = Install-VenvPackage -VenvPath $venv -Package $Server.source.package `
        -Pin $Server.source.pin -UvPath $Inventory.Uv

    Invoke-ChromaPrewarm -VenvPath $venv

    $projectPath = Join-Path $Config.paths.agentRoot 'cases\ghidra'
    $exe = Join-Path $venv 'Scripts\pyghidra-mcp.exe'
    $serverArgs = @(
        '--transport', 'streamable-http',
        '--host', $Server.bind,
        '--port', "$($Server.port)",
        '--project-path', $projectPath,
        '--project-name', 're-lab')

    $launcher = Write-ServerLauncher `
        -Path (Join-Path $Config.paths.toolRoot "mcp\launch-$($Server.name).cmd") `
        -Executable $exe -Arguments $serverArgs `
        -Environment @{ GHIDRA_INSTALL_DIR = $Inventory.GhidraRoot }

    $null = Register-ServerScheduledTask -Name $Server.scheduledTask -LauncherPath $launcher

    $command = [PSCustomObject]@{
        Executable = $exe
        Arguments  = $serverArgs
        Env        = @{ GHIDRA_INSTALL_DIR = $Inventory.GhidraRoot }
        Launcher   = $launcher
    }

    return New-ServerResult -Server $Server -Status 'installed' -Version $version `
        -Command $command
}

function Install-McpServer {
    <#
    .SYNOPSIS
        Installs one MCP server by dispatching on its kind.
    .DESCRIPTION
        The kind is the whole abstraction: it selects the install strategy and
        keeps this runner generic. A disabled server is still reported, because
        disabling is settings.json's job and the manifest should show it.
    .PARAMETER Server
        The server's config entry.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Inventory
        The host inventory.
    .EXAMPLE
        Install-McpServer -Server $s -Config $cfg -Inventory $inv
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Inventory
    )

    if (-not $Server.enabled) {
        return New-ServerResult -Server $Server -Status 'not-installed' `
            -Reason 'Disabled in re-agent.config.json.'
    }

    try {
        switch ($Server.kind) {
            'venv-stdio' {
                return Install-VenvStdioServer -Server $Server -Config $Config -Inventory $Inventory
            }
            'venv-http' {
                return Install-VenvHttpServer -Server $Server -Config $Config -Inventory $Inventory
            }
            default {
                return New-ServerResult -Server $Server -Status 'failed' -Reason (
                    "No install handler is implemented for kind '$($Server.kind)'.")
            }
        }
    } catch {
        return New-ServerResult -Server $Server -Status 'failed' -Reason $_.Exception.Message
    }
}

function Install-AllMcpServer {
    <#
    .SYNOPSIS
        Installs every configured MCP server, isolating each one's failures.
    .DESCRIPTION
        A broken Binary Ninja must not stop a working x64dbg, so each server is
        installed independently and always yields a result record.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Inventory
        The host inventory.
    .EXAMPLE
        $results = Install-AllMcpServer -Config $cfg -Inventory $inv
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Inventory
    )

    $results = @()
    foreach ($s in $Config.mcpServers) {
        $r = Install-McpServer -Server $s -Config $Config -Inventory $Inventory
        Write-ReAgentLog -Level INFO -Message (
            "Server '$($r.Name)' ($($r.Kind)): $($r.Status)" +
            $(if ($r.Reason) { " - $($r.Reason)" } else { '' }))
        $results += $r
    }
    return $results
}

function New-TestCrashDump {
    <#
    .SYNOPSIS
        Creates the crash dump the mcp-windbg tier-1 check needs.
    .DESCRIPTION
        mcp-windbg exposes no live-process tool and no module-list tool - only
        open_cdb_dump plus run_cdb_command - so verification needs a dump on
        disk. cdb launches a short-lived process, dumps it, and detaches.

        Idempotent: an existing dump is left alone.
    .PARAMETER CdbPath
        Path to cdb.exe.
    .PARAMETER OutputPath
        Destination .dmp file.
    .EXAMPLE
        New-TestCrashDump -CdbPath $inv.Cdb -OutputPath 'C:\re\scratch\test.dmp'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$CdbPath,
        [Parameter(Mandatory)][string]$OutputPath
    )

    if (Test-Path -LiteralPath $OutputPath) {
        Write-ReAgentLog -Level INFO -Message "Test dump already present at '$OutputPath'."
        return $OutputPath
    }
    if (-not $PSCmdlet.ShouldProcess($OutputPath, 'Create verification crash dump')) {
        return $OutputPath
    }

    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }

    $target = Join-Path $env:SystemRoot 'System32\cmd.exe'
    Write-ReAgentLog -Level INFO -Message "Creating verification dump at '$OutputPath'."
    $null = Invoke-CommandLine -FilePath $CdbPath -Arguments @(
        '-c', ".dump /ma `"$OutputPath`";qd", $target)

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        throw ("cdb did not produce a dump at '$OutputPath'. " +
            'Tier-1 WinDbg verification cannot run without one.')
    }
    return $OutputPath
}

Export-ModuleMember -Function New-ServerResult, Get-VenvPython, Get-VenvPackageVersion, `
    Install-VenvPackage, Write-ServerLauncher, Get-ServerVenvPath, Invoke-ChromaPrewarm, `
    Get-ScheduledTaskActionText, Register-ServerScheduledTask, Install-VenvStdioServer, `
    Install-VenvHttpServer, Install-McpServer, Install-AllMcpServer, New-TestCrashDump
