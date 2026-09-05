Set-StrictMode -Version Latest

$Script:MinPython = [version]'3.10.0'
$Script:DefaultJavaMinimum = [version]'21.0'

# winget package ids, kept as data so a version bump is an edit in one place.
$Script:WingetIds = @{
    python = 'Python.Python.3.12'
    uv     = 'astral-sh.uv'
    jdk    = 'EclipseAdoptium.Temurin.21.JDK'
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
    Test-PrereqSatisfied, Install-Prereq
