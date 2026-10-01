Set-StrictMode -Version Latest

$Script:MinPython = [version]'3.10.0'
$Script:DefaultJavaMinimum = [version]'21.0'

# winget package ids, kept as data so a version bump is an edit in one place.
$Script:WingetIds = @{
    python = 'Python.Python.3.12'
    uv     = 'astral-sh.uv'
    jdk    = 'EclipseAdoptium.Temurin.21.JDK'
}

$Script:AgentCliPackages = [ordered]@{
    codex  = '@openai/codex@latest'
    claude = '@anthropic-ai/claude-code@latest'
}

function Update-ProcessPath {
    <#
    .SYNOPSIS
        Refreshes this PowerShell process from the persisted Windows PATH values.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$AdditionalPath = @())

    $entries = [Collections.Generic.List[string]]::new()
    foreach ($value in @(
            $env:Path,
            [Environment]::GetEnvironmentVariable('Path', 'Machine'),
            [Environment]::GetEnvironmentVariable('Path', 'User')) + $AdditionalPath) {
        foreach ($entry in @([string]$value -split ';')) {
            $entry = $entry.Trim()
            if ($entry -and -not ($entries | Where-Object { $_ -eq $entry })) {
                $entries.Add($entry)
            }
        }
    }
    if ($PSCmdlet.ShouldProcess('current PowerShell process', 'Refresh PATH')) {
        $env:Path = $entries -join ';'
    }
}

function Add-UserPathEntry {
    <#
    .SYNOPSIS
        Adds one executable directory to the current user's PATH and this session.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PathEntry)

    $PathEntry = $PathEntry.Trim()
    if (-not $PathEntry) { throw 'A PATH entry cannot be empty.' }

    $userEntries = @([Environment]::GetEnvironmentVariable('Path', 'User') -split ';') |
        ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if (-not ($userEntries | Where-Object { $_ -eq $PathEntry })) {
        [Environment]::SetEnvironmentVariable('Path', (@($userEntries) + $PathEntry) -join ';', 'User')
    }
    Update-ProcessPath -AdditionalPath @($PathEntry)
}

function Install-AgentCli {
    <#
    .SYNOPSIS
        Installs missing Codex and Claude Code CLIs for the invoking user.
    .DESCRIPTION
        Both CLIs are globally installed through npm. Node.js LTS is provisioned
        through winget only if npm is absent. The npm global prefix is persisted
        on the user PATH and merged into this process before commands are
        resolved again, so the remainder of the installer can use them now.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $missing = @($Script:AgentCliPackages.Keys | Where-Object {
            -not (Find-Executable -Name $_)
        })
    if ($missing.Count -eq 0) { return }

    $npm = Find-Executable -Name 'npm'
    if (-not $npm) {
        if (-not $PSCmdlet.ShouldProcess('Node.js LTS', 'Install prerequisite for Codex and Claude Code')) {
            return
        }
        Write-ReAgentLog -Level INFO -Message 'Installing Node.js LTS for the agent CLIs via winget.'
        Invoke-CommandLine -FilePath 'winget' -Arguments @(
            'install', '--id', 'OpenJS.NodeJS.LTS', '--silent',
            '--accept-package-agreements', '--accept-source-agreements')
        Update-ProcessPath
        $npm = Find-Executable -Name 'npm'
        if (-not $npm) { throw 'Node.js installation completed, but npm is still unavailable on PATH.' }
    }

    $prefix = (@(Invoke-CommandLine -FilePath $npm -Arguments @('prefix', '-g')) |
        Where-Object { $_ -and $_ -notmatch '^npm error' } | Select-Object -First 1)
    if (-not $prefix) { throw 'Could not determine npm''s global install prefix.' }
    Add-UserPathEntry -PathEntry ([string]$prefix)

    $installed = @()
    foreach ($name in $missing) {
        if (-not $PSCmdlet.ShouldProcess($name, "Install $($Script:AgentCliPackages[$name])")) { continue }
        Write-ReAgentLog -Level INFO -Message "Installing '$name' via npm."
        Invoke-CommandLine -FilePath $npm -Arguments @('install', '-g', $Script:AgentCliPackages[$name])
        Update-ProcessPath -AdditionalPath @([string]$prefix)
        if (-not (Find-Executable -Name $name)) {
            throw "'$name' was installed but is not available on PATH."
        }
        $installed += $name
    }
    return $installed
}

function Get-GhidraJavaMinimum {
    <#
    .SYNOPSIS
        Returns the minimum JDK version the installed Ghidra demands.
    .DESCRIPTION
        Ghidra's own requirement governs, not pyghidra-mcp's, which specifies
        none. Read from Ghidra\application.properties rather than assuming a
        number, because the value moves between major releases.
    .PARAMETER GhidraRoot
        The Ghidra install directory.
    .EXAMPLE
        Get-GhidraJavaMinimum -GhidraRoot $inv.GhidraRoot
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GhidraRoot)

    $props = Join-Path $GhidraRoot 'Ghidra\application.properties'
    if (-not (Test-Path -LiteralPath $props)) { return $Script:DefaultJavaMinimum }
    try {
        $line = Get-Content -LiteralPath $props |
            Where-Object { $_ -match '^application\.java\.min\s*=\s*(\d+)' } |
            Select-Object -First 1
        if ($line -and $line -match '=\s*(\d+)') { return [version]"$($Matches[1]).0" }
        return $Script:DefaultJavaMinimum
    } catch {
        return $Script:DefaultJavaMinimum
    }
}

function Get-MissingPrereq {
    <#
    .SYNOPSIS
        Returns the names of prerequisites this host is missing.
    .DESCRIPTION
        Node.js is deliberately absent from this list. Nothing in this build
        needs it - not any of the six MCP servers, not Claude Code. Zig is
        absent too: the x64dbg plugin ships prebuilt, so nothing is compiled.

        A JDK is required only when Ghidra is installed, since both Ghidra MCP
        servers run on it and nothing else here does. Ghidra sets a minimum but
        no maximum, so a newer JDK is fine.
    .PARAMETER Inventory
        The host inventory from Get-HostInventory.
    .EXAMPLE
        Get-MissingPrereq -Inventory $inv
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Inventory)

    $missing = @()

    if (-not $Inventory.Python -or
        -not (Compare-VersionAtLeast -Actual $Inventory.PythonVersion -Minimum $Script:MinPython)) {
        $missing += 'python'
    }
    if ($Inventory.GhidraRoot) {
        $needed = Get-GhidraJavaMinimum -GhidraRoot $Inventory.GhidraRoot
        if (-not $Inventory.Jdk -or
            -not (Compare-VersionAtLeast -Actual $Inventory.JdkVersion -Minimum $needed)) {
            $missing += 'jdk'
        }
    }
    if (-not $Inventory.Cdb) { $missing += 'cdb' }
    if (-not $Inventory.Uv) { $missing += 'uv' }

    return $missing
}

function Test-PrereqSatisfied {
    <#
    .SYNOPSIS
        True when no prerequisite is missing.
    .PARAMETER Inventory
        The host inventory from Get-HostInventory.
    .EXAMPLE
        Test-PrereqSatisfied -Inventory $c.Inventory
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Inventory)
    # @() guards the empty-array unroll; without it a satisfied host throws.
    return (@(Get-MissingPrereq -Inventory $Inventory).Count -eq 0)
}

function Install-Prereq {
    <#
    .SYNOPSIS
        Installs only the prerequisites the host is missing.
    .DESCRIPTION
        Never modifies an existing interpreter's global site-packages; each MCP
        server gets its own virtual environment in a later phase.

        cdb is not installable unattended and throws with both routes spelled
        out, because guessing at an SDK feature id would fail silently later.
    .PARAMETER Inventory
        The host inventory from Get-HostInventory.
    .EXAMPLE
        Install-Prereq -Inventory $c.Inventory
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object]$Inventory)

    foreach ($item in @(Get-MissingPrereq -Inventory $Inventory)) {
        if ($item -eq 'cdb') {
            throw @'
cdb.exe was not found and cannot be installed unattended by this script.
Install WinDbg from the Microsoft Store (it ships cdb.exe at
<package>\amd64\cdb.exe), or install the Windows SDK Debugging Tools:
  winsdksetup.exe /features OptionId.WindowsDesktopDebuggers /quiet /norestart
Then re-run. Note that the Store package is NOT on PATH; this script finds it
via Get-AppxPackage, so no PATH edit is needed.
'@
        }
        if (-not $PSCmdlet.ShouldProcess($item, 'Install prerequisite')) { continue }
        if (-not $Script:WingetIds.ContainsKey($item)) {
            throw "No install route is defined for prerequisite '$item'."
        }
        $id = $Script:WingetIds[$item]
        Write-ReAgentLog -Level INFO -Message "Installing '$item' ($id) via winget."
        Invoke-CommandLine -FilePath 'winget' -Arguments @(
            'install', '--id', $id, '--silent',
            '--accept-package-agreements', '--accept-source-agreements')
    }
}

Export-ModuleMember -Function Get-GhidraJavaMinimum, Get-MissingPrereq, `
    Test-PrereqSatisfied, Install-Prereq, Install-AgentCli, Add-UserPathEntry, Update-ProcessPath
