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

    # mcp-windbg has no live-process tool, so its tier-1 check needs a dump on
    # disk. The server is installed and usable without one; only verification
    # suffers, so a failure here warns rather than failing the install.
    try {
        $null = New-TestCrashDump -CdbPath $Inventory.Cdb `
            -OutputPath (Join-Path $Config.paths.toolRoot 'scratch\test.dmp')
    } catch {
        Write-ReAgentLog -Level WARN -Message (
            "Could not create the verification dump: $($_.Exception.Message) " +
            'mcp-windbg is installed; its tier-1 check will report not-testable.')
    }

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
            'gui-builtin-http' {
                return Install-GuiBuiltinHttpServer -Server $Server -Config $Config `
                    -Inventory $Inventory
            }
            'gui-plugin-http' {
                return Install-GuiPluginHttpServer -Server $Server -Config $Config `
                    -Inventory $Inventory
            }
            'plugin-inproc' {
                return Install-PluginInprocServer -Server $Server -Config $Config `
                    -Inventory $Inventory
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

function Invoke-Download {
    <#
    .SYNOPSIS
        Downloads a URL to a file. Exists as a mock seam.
    .PARAMETER Uri
        Source URL.
    .PARAMETER OutFile
        Destination path.
    .EXAMPLE
        Invoke-Download -Uri $u -OutFile $p
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
}

function Get-VerifiedRelease {
    <#
    .SYNOPSIS
        Downloads a pinned GitHub release asset and verifies its SHA-256.
    .DESCRIPTION
        This ecosystem is full of near-identical forks, so an unpinned or
        unverified source is a supply-chain hole. A hash mismatch aborts that
        server's install; unverified code is never executed.

        A config hash still set to the PIN-ME placeholder is also refused, but
        the error carries the hash that was actually computed so the operator
        can record it and re-run. That makes the first run a deliberate
        trust-on-first-use decision rather than an accidental one.
    .PARAMETER Server
        The server's config entry, carrying source.repo, source.pin, source.sha256.
    .PARAMETER Config
        The parsed configuration object.
    .EXAMPLE
        Get-VerifiedRelease -Server $s -Config $cfg
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Config
    )

    $assetNames = @($Server.source.sha256.PSObject.Properties.Name)
    if ($assetNames.Count -ne 1) {
        throw ("Server '$($Server.name)' must pin exactly one release asset in " +
            "source.sha256; found $($assetNames.Count).")
    }
    $asset = $assetNames[0]
    $expected = $Server.source.sha256.$asset

    $dir = Join-Path $Config.paths.toolRoot 'mcp\downloads'
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }
    $target = Join-Path $dir $asset

    if (-not (Test-Path -LiteralPath $target)) {
        $uri = "https://github.com/$($Server.source.repo)/releases/download/" +
        "$($Server.source.pin)/$asset"
        Write-ReAgentLog -Level INFO -Message "Downloading $asset from $uri"
        Invoke-Download -Uri $uri -OutFile $target
    }

    $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($expected -eq 'PIN-ME') {
        throw ("'$asset' is not pinned to a hash yet. Its SHA-256 is $actual - record " +
            "that under mcpServers[$($Server.name)].source.sha256 in " +
            're-agent.config.json and re-run. Nothing is installed unverified.')
    }
    if ($actual -ne $expected.ToLowerInvariant()) {
        throw ("SHA-256 mismatch for '$asset'. Expected $expected, got $actual. " +
            'Refusing to install; delete the download and re-run, or investigate the source.')
    }

    Write-ReAgentLog -Level INFO -Message "Verified $asset ($actual)."
    return $target
}

function Expand-X64dbgPlugin {
    <#
    .SYNOPSIS
        Deploys the x64dbg MCP plugin into both architecture plugin directories.
    .DESCRIPTION
        The release ships a dist/ tree carrying x32 and x64 plugins. Both are
        installed unconditionally: a 32-bit target loads x32dbg, and a plugin
        present in only one architecture is an intermittent failure that looks
        like a bug elsewhere.
    .PARAMETER ArchivePath
        The verified release zip.
    .PARAMETER ReleaseRoot
        The x64dbg release directory holding x32\ and x64\.
    .EXAMPLE
        Expand-X64dbgPlugin -ArchivePath $z -ReleaseRoot 'C:\Tools\x64dbg\release'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$ReleaseRoot
    )

    if (-not $PSCmdlet.ShouldProcess($ReleaseRoot, 'Deploy x64dbg MCP plugin')) { return }

    $staging = Join-Path ([IO.Path]::GetTempPath()) ("reagent-x64dbg-" + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $staging -Force
    try {
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $staging -Force

        foreach ($arch in @('x32', 'x64')) {
            $source = Get-ChildItem -LiteralPath $staging -Recurse -Directory `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match "\\$arch\\plugins$" } |
                Select-Object -First 1
            if (-not $source) {
                throw ("The release archive has no $arch\plugins directory. " +
                    'The upstream layout has changed; re-check the pinned release.')
            }
            $dest = Join-Path $ReleaseRoot "$arch\plugins"
            if (-not (Test-Path -LiteralPath $dest)) {
                $null = New-Item -ItemType Directory -Path $dest -Force
            }
            foreach ($f in Get-ChildItem -LiteralPath $source.FullName -File) {
                $null = Copy-PluginFile -Source $f.FullName -Destination (Join-Path $dest $f.Name)
            }
        }
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Copy-PluginFile {
    <#
    .SYNOPSIS
        Copies a plugin file only when it differs, backing up what it replaces.
    .DESCRIPTION
        Idempotency: an unchanged file is left alone so a re-run reports no
        change. Anything overwritten is backed up first, because this script
        never destroys something it did not create.
    .PARAMETER Source
        File to copy.
    .PARAMETER Destination
        Where it goes.
    .EXAMPLE
        Copy-PluginFile -Source $a -Destination $b
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        $a = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
        $b = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
        if ($a -eq $b) {
            Write-ReAgentLog -Level INFO -Message "Unchanged: '$Destination'."
            return $false
        }
        $backup = "$Destination.bak-$((Get-Date).ToString('yyyyMMddHHmmss'))"
        Copy-Item -LiteralPath $Destination -Destination $backup -Force
        Write-ReAgentLog -Level WARN -Message "Replacing '$Destination' (backed up to '$backup')."
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    return $true
}

function Get-X64dbgConfigPath {
    <#
    .SYNOPSIS
        Returns the candidate mcp_config.json paths for one x64dbg architecture.
    .DESCRIPTION
        Upstream disagrees with itself about where this file lives: the README
        says "next to the x64dbg executable", the source says "next to the
        loading module", which would be the plugins directory. Pre-seeding the
        wrong one fails silently, so both are returned - the first is written,
        and a token is read back from whichever actually exists.
    .PARAMETER ReleaseRoot
        The x64dbg release directory.
    .PARAMETER Arch
        x64 or x32.
    .EXAMPLE
        Get-X64dbgConfigPath -ReleaseRoot 'C:\Tools\x64dbg\release' -Arch 'x64'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReleaseRoot,
        [Parameter(Mandatory)][ValidateSet('x64', 'x32')][string]$Arch
    )
    $archRoot = Join-Path $ReleaseRoot $Arch
    return @(
        (Join-Path $archRoot 'mcp_config.json'),
        (Join-Path $archRoot 'plugins\mcp_config.json')
    )
}

function Write-X64dbgPreseed {
    <#
    .SYNOPSIS
        Pre-seeds the x64dbg MCP plugin's config so it never picks its own values.
    .DESCRIPTION
        The plugin reads an existing mcp_config.json and preserves it, generating
        a token only when the field is missing. Writing this before x64dbg first
        runs is therefore the whole token bootstrap - no launching the GUI, no
        prompting the operator.

        The token is 32 hex chars, matching the plugin's own 16-byte format, and
        an existing token is always reused rather than rotated.
    .PARAMETER ConfigPath
        Where to write mcp_config.json.
    .PARAMETER Bind
        Bind address. Never 0.0.0.0.
    .PARAMETER Port
        Listening port, compiled in per architecture upstream.
    .PARAMETER Token
        The bearer token to seed.
    .EXAMPLE
        Write-X64dbgPreseed -ConfigPath $p -Bind '127.0.0.1' -Port 9094 -Token $t
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Bind,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Token
    )

    if ($Bind -ne '127.0.0.1') {
        throw "Refusing to seed x64dbg with bind '$Bind'. Only 127.0.0.1 is permitted."
    }
    if (-not $PSCmdlet.ShouldProcess($ConfigPath, 'Pre-seed x64dbg MCP config')) { return }

    $dir = Split-Path -Parent $ConfigPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
    }

    # Field names and casing verified against src/core/config.zig upstream.
    $payload = [ordered]@{
        IpAddress = $Bind
        Port      = $Port
        AutoStart = $true
        AuthToken = $Token
    }
    Write-Utf8NoBomFile -Path $ConfigPath `
        -Text (([PSCustomObject]$payload) | ConvertTo-Json -Depth 4)
}

function Install-GuiBuiltinHttpServer {
    <#
    .SYNOPSIS
        Configures Binary Ninja's vendor-built-in MCP server. Downloads nothing.
    .DESCRIPTION
        Vector 35 ships this server inside every GUI edition, so there is no
        source to pin, no hash to verify and no supply-chain surface at all. The
        install is four settings merged into Binary Ninja's own settings.json.

        Gated on capability rather than version number: Vector 35 documents no
        minimum, so Phase 0 probes the executable for the ui.mcp.enabled key. An
        older build is reported as "upgrade Binary Ninja", never as a failure.
    .PARAMETER Server
        The server's config entry.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Inventory
        The host inventory.
    .EXAMPLE
        Install-GuiBuiltinHttpServer -Server $s -Config $cfg -Inventory $inv
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Inventory
    )

    if (-not $Inventory.BinaryNinjaRoot) {
        return New-ServerResult -Server $Server -Status 'not-installed' `
            -Reason 'Binary Ninja was not found on this host.'
    }
    if (-not $Inventory.BinaryNinjaMcpCapable) {
        return New-ServerResult -Server $Server -Status 'not-installed' -Reason (
            'This Binary Ninja build has no ui.mcp.* settings. Upgrade Binary Ninja; ' +
            'the MCP server is built in from a recent version onward.')
    }

    $token = Get-OrNewServerToken -Name $Server.name `
        -TokenRoot (Join-Path $Config.paths.toolRoot 'mcp\tokens')

    Merge-JsonFile -Path $Inventory.BinaryNinjaSettingsPath -Values @{
        'ui.mcp.enabled'  = $true
        'ui.mcp.port'     = [int]$Server.port
        'ui.mcp.endpoint' = $Server.path
        'ui.mcp.token'    = $token
    }

    return New-ServerResult -Server $Server -Status 'installed' -Reason (
        'Requires a Binary Ninja restart, then Plugins > MCP > Start Server ' +
        'ONCE PER SESSION - it does not autostart.')
}

function Install-GuiPluginHttpServer {
    <#
    .SYNOPSIS
        Installs the GhidraMCP extension, when the installed Ghidra can load it.
    .DESCRIPTION
        Ghidra enforces extension version compatibility. GhidraMCP 1.4 targets
        Ghidra 11.3.2, so a newer Ghidra will reject it outright. That is an
        expected outcome, not a failure: the server ships disabled anyway, so it
        is recorded as not-installed with the version mismatch as the reason
        rather than polluting the run's exit code.
    .PARAMETER Server
        The server's config entry.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Inventory
        The host inventory.
    .EXAMPLE
        Install-GuiPluginHttpServer -Server $s -Config $cfg -Inventory $inv
    #>
    [CmdletBinding()]
    # Config is part of the uniform handler signature the dispatcher calls with.
    # This handler does not need it yet because the version gate rejects every
    # host tested so far before an install path is reached.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Inventory
    )

    if (-not $Inventory.GhidraRoot) {
        return New-ServerResult -Server $Server -Status 'not-installed' `
            -Reason 'Ghidra was not found on this host.'
    }

    $maxName = 'maxGhidraVersion'
    if ($Server.PSObject.Properties.Name -contains $maxName -and $Inventory.GhidraVersion) {
        $max = [version]$Server.$maxName
        if ($Inventory.GhidraVersion -gt $max) {
            return New-ServerResult -Server $Server -Status 'not-installed' -Reason (
                "GhidraMCP $($Server.source.pin) targets Ghidra $max, but this host runs " +
                "$($Inventory.GhidraVersion); Ghidra would reject the extension. " +
                'This server is disabled by default, so nothing else is affected.')
        }
    }

    return New-ServerResult -Server $Server -Status 'not-installed' -Reason (
        'Extension install is not implemented: on every host tested so far the ' +
        'version gate above rejects it first. Implement when a matching Ghidra appears.')
}

function Install-PluginInprocServer {
    <#
    .SYNOPSIS
        Installs the x64dbg MCP plugin and pre-seeds its config.
    .DESCRIPTION
        One server per architecture: the plugin compiles its port in from
        pointer width (9094 for x64dbg, 9095 for x32dbg) and each process reads
        its own mcp_config.json. Both architectures get the plugin regardless,
        because a plugin present in only one is an intermittent failure that
        looks like a bug somewhere else entirely.
    .PARAMETER Server
        The server's config entry.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Inventory
        The host inventory.
    .EXAMPLE
        Install-PluginInprocServer -Server $s -Config $cfg -Inventory $inv
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Inventory
    )

    if (-not $Inventory.X64dbgRoot) {
        return New-ServerResult -Server $Server -Status 'not-installed' `
            -Reason 'x64dbg was not found on this host.'
    }

    $payload = Get-VerifiedRelease -Server $Server -Config $Config
    Expand-X64dbgPlugin -ArchivePath $payload -ReleaseRoot $Inventory.X64dbgRoot

    $tokenRoot = Join-Path $Config.paths.toolRoot 'mcp\tokens'
    $candidates = Get-X64dbgConfigPath -ReleaseRoot $Inventory.X64dbgRoot -Arch $Server.arch

    # If the plugin has already run it owns a token; never invent one over it.
    $existing = $null
    foreach ($c in $candidates) {
        $existing = Get-X64dbgToken -McpConfigPath $c
        if ($existing) { break }
    }
    $token = if ($existing) {
        $existing
    } else {
        Get-OrNewServerToken -Name $Server.name -TokenRoot $tokenRoot -ByteCount 16
    }
    Save-ServerToken -Name $Server.name -Token $token -TokenRoot $tokenRoot

    Write-X64dbgPreseed -ConfigPath $candidates[0] -Bind $Server.bind `
        -Port ([int]$Server.port) -Token $token

    return New-ServerResult -Server $Server -Status 'installed' -Version $Server.source.pin `
        -Reason 'Requires x64dbg to be open with the target loaded before it answers.'
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
    Install-VenvHttpServer, Install-McpServer, Install-AllMcpServer, New-TestCrashDump, `
    Get-X64dbgConfigPath, Write-X64dbgPreseed, Install-GuiBuiltinHttpServer, `
    Install-GuiPluginHttpServer, Install-PluginInprocServer, Get-VerifiedRelease, `
    Expand-X64dbgPlugin, Invoke-Download, Copy-PluginFile
