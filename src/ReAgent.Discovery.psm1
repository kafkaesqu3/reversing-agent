Set-StrictMode -Version Latest

function Invoke-CommandLine {
    <#
    .SYNOPSIS
        Runs an external command and returns its stdout lines. Exists as a mock seam.
    .DESCRIPTION
        Every external process call in this module goes through here so the tests
        can mock the host away entirely. Do not call external executables directly.
    .PARAMETER FilePath
        The executable to run.
    .PARAMETER Arguments
        Arguments to pass, already split.
    .EXAMPLE
        Invoke-CommandLine -FilePath 'where.exe' -Arguments @('python')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    & $FilePath @Arguments 2>&1
}

function Find-Executable {
    <#
    .SYNOPSIS
        Resolves an executable on PATH, returning its full path or $null.
    .DESCRIPTION
        Absence is not an error here: Phase 0 observes, and Phase 1 decides what
        a missing tool means. Note that where.exe writes its "not found" notice to
        stdout as an INFO: line rather than failing, so that line is filtered out.
    .PARAMETER Name
        The command name to resolve.
    .EXAMPLE
        Find-Executable -Name 'claude'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    try {
        $out = Invoke-CommandLine -FilePath 'where.exe' -Arguments @($Name)
        $first = @($out) | Where-Object { $_ -and $_ -notmatch '^INFO:' } | Select-Object -First 1
        if ($first) { return ([string]$first).Trim() }
        return $null
    } catch {
        return $null
    }
}

function Compare-VersionAtLeast {
    <#
    .SYNOPSIS
        Returns true when Actual is present and at least Minimum.
    .DESCRIPTION
        Both sides are [version], so 3.9 correctly sorts below 3.10. Comparing
        version strings lexically is the classic way to decide 3.9 beats 3.10.
    .PARAMETER Actual
        The discovered version, or $null when the tool is absent.
    .PARAMETER Minimum
        The lowest acceptable version.
    .EXAMPLE
        Compare-VersionAtLeast -Actual $inv.PythonVersion -Minimum ([version]'3.10.0')
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][version]$Actual,
        [Parameter(Mandatory)][version]$Minimum
    )
    if ($null -eq $Actual) { return $false }
    return ($Actual -ge $Minimum)
}

function Get-PythonVersion {
    <#
    .SYNOPSIS
        Returns the version of a Python interpreter, or $null if it cannot be determined.
    .DESCRIPTION
        Accepts both two- and three-component banners, since python.org builds
        report 'Python 3.13' as readily as 'Python 3.13.15'.
    .PARAMETER PythonPath
        Path to the interpreter to interrogate.
    .EXAMPLE
        Get-PythonVersion -PythonPath 'C:\Python313\python.exe'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PythonPath)

    try {
        $out = Invoke-CommandLine -FilePath $PythonPath -Arguments @('--version')
        $text = (@($out) -join ' ')
        if ($text -match 'Python\s+(\d+\.\d+(\.\d+)?)') {
            return [version]$Matches[1]
        }
        return $null
    } catch {
        return $null
    }
}

# where.exe x64dbg resolves the Chocolatey SHIM (C:\ProgramData\chocolatey\bin\
# x64dbg.exe). Deriving a release root from that yields C:\ProgramData\chocolatey,
# which is wrong, so real install paths are probed first and shims are rejected.
$Script:X64dbgCandidates = @(
    'C:\Tools\x64dbg\release\x64\x64dbg.exe',
    'C:\ProgramData\chocolatey\lib\x64dbg.vm\tools\release\x64\x64dbg.exe',
    'C:\ProgramData\chocolatey\lib\x64dbg\tools\release\x64\x64dbg.exe'
)

# FLARE-VM's Chocolatey package unzips one level deeper than a manual install:
# ...\lib\ghidra\tools\ghidra_<version>_PUBLIC.
$Script:GhidraSearchRoots = @(
    'C:\Tools',
    'C:\ProgramData\chocolatey\lib\ghidra\tools',
    'C:\ProgramData\chocolatey\lib\ghidra.vm\tools'
)

function Test-FileContainsAscii {
    <#
    .SYNOPSIS
        True when a file contains the given ASCII string. Exists as a mock seam.
    .DESCRIPTION
        Streams the file in overlapping chunks rather than loading it whole:
        binaryninja.exe is tens of megabytes and this box has 8 GB of RAM.
        The overlap stops a match being missed across a chunk boundary.
    .PARAMETER Path
        File to scan.
    .PARAMETER Value
        ASCII string to look for.
    .EXAMPLE
        Test-FileContainsAscii -Path 'binaryninja.exe' -Value 'ui.mcp.enabled'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Value
    )

    $chunkSize = 1MB
    $overlap = $Value.Length
    $stream = [IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] ($chunkSize + $overlap)
        $carried = 0
        while ($true) {
            $read = $stream.Read($buffer, $carried, $chunkSize)
            if ($read -le 0) { return $false }
            $total = $carried + $read
            if ([Text.Encoding]::ASCII.GetString($buffer, 0, $total).Contains($Value)) {
                return $true
            }
            $carried = [Math]::Min($overlap, $total)
            [Array]::Copy($buffer, $total - $carried, $buffer, 0, $carried)
        }
    } finally {
        $stream.Dispose()
    }
}

function Get-AppxInstallLocation {
    <#
    .SYNOPSIS
        Returns an AppX package's install location, or $null. Exists as a mock seam.
    .PARAMETER Name
        The package name, e.g. Microsoft.WinDbg.
    .EXAMPLE
        Get-AppxInstallLocation -Name 'Microsoft.WinDbg'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    try {
        $pkg = Get-AppxPackage -Name $Name -ErrorAction Stop | Select-Object -First 1
        if ($pkg) { return $pkg.InstallLocation }
        return $null
    } catch {
        return $null
    }
}

function Find-X64dbgRoot {
    <#
    .SYNOPSIS
        Locates the x64dbg 'release' directory containing the x32 and x64 subtrees.
    .DESCRIPTION
        Returns the release root, not the executable, because the MCP plugin must
        be installed into both release\x32\plugins and release\x64\plugins.
    .EXAMPLE
        Find-X64dbgRoot
    #>
    [CmdletBinding()]
    param()

    $exe = $null
    foreach ($c in $Script:X64dbgCandidates) {
        if (Test-Path -LiteralPath $c) { $exe = $c; break }
    }
    if (-not $exe) {
        $found = Find-Executable -Name 'x64dbg'
        if ($found -and $found -notlike '*\chocolatey\bin\*') { $exe = $found }
    }
    if (-not $exe) { return $null }

    # <root>\release\x64\x64dbg.exe -> <root>\release
    return (Split-Path -Parent (Split-Path -Parent $exe))
}

function Find-GhidraRoot {
    <#
    .SYNOPSIS
        Locates the Ghidra installation directory.
    .DESCRIPTION
        GHIDRA_INSTALL_DIR wins when set, but it is not set on a stock FLARE VM,
        so the Chocolatey and Tools layouts are searched as well.
    .EXAMPLE
        Find-GhidraRoot
    #>
    [CmdletBinding()]
    param()

    if ($env:GHIDRA_INSTALL_DIR -and (Test-Path -LiteralPath $env:GHIDRA_INSTALL_DIR)) {
        return $env:GHIDRA_INSTALL_DIR
    }
    foreach ($base in $Script:GhidraSearchRoots) {
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $hit = Get-ChildItem -LiteralPath $base -Directory -Filter 'ghidra_*' `
            -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Get-GhidraVersion {
    <#
    .SYNOPSIS
        Extracts the Ghidra version from its installation directory name.
    .DESCRIPTION
        The version governs extension compatibility, so a null here means the
        GhidraMCP version gate cannot be evaluated and must not be guessed.
    .PARAMETER GhidraRoot
        The Ghidra install directory.
    .EXAMPLE
        Get-GhidraVersion -GhidraRoot 'C:\...\ghidra_12.1.2_PUBLIC'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GhidraRoot)

    if ((Split-Path -Leaf $GhidraRoot) -match 'ghidra_(\d+\.\d+(\.\d+)?)') {
        return [version]$Matches[1]
    }
    return $null
}

function Find-BinaryNinjaRoot {
    <#
    .SYNOPSIS
        Locates the Binary Ninja installation directory.
    .EXAMPLE
        Find-BinaryNinjaRoot
    #>
    [CmdletBinding()]
    param()

    # Program Files first: %LOCALAPPDATA%\Vector35 does not exist on this host,
    # and where.exe resolves the Chocolatey shim rather than the real binary.
    foreach ($c in @("$env:ProgramFiles\Vector35\BinaryNinja",
            "$env:LOCALAPPDATA\Vector35\BinaryNinja")) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $exe = Find-Executable -Name 'binaryninja'
    if ($exe -and $exe -notlike '*\chocolatey\bin\*') { return (Split-Path -Parent $exe) }
    return $null
}

function Get-BinaryNinjaSettingsPath {
    <#
    .SYNOPSIS
        Returns the path to Binary Ninja's user settings.json.
    .DESCRIPTION
        Confirmed on the host (open item O3). The file may not exist yet on a
        fresh install; callers must handle that, and the merge creates it.
    .EXAMPLE
        Get-BinaryNinjaSettingsPath
    #>
    [CmdletBinding()]
    param()
    return (Join-Path $env:APPDATA 'Binary Ninja\settings.json')
}

function Test-BinaryNinjaMcpCapable {
    <#
    .SYNOPSIS
        True when this Binary Ninja build ships the built-in MCP server.
    .DESCRIPTION
        Vector 35 documents no minimum version, so this gates on the capability
        itself: the ui.mcp.enabled setting key is present in the executable.
        A false result means "upgrade Binary Ninja", never "broken server".
    .PARAMETER BinaryNinjaRoot
        The Binary Ninja install directory, or $null when it is not installed.
    .EXAMPLE
        Test-BinaryNinjaMcpCapable -BinaryNinjaRoot $inv.BinaryNinjaRoot
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$BinaryNinjaRoot)

    if (-not $BinaryNinjaRoot) { return $false }
    $exe = Join-Path $BinaryNinjaRoot 'binaryninja.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return $false }
    try {
        return (Test-FileContainsAscii -Path $exe -Value 'ui.mcp.enabled')
    } catch {
        return $false
    }
}

function Find-CdbPath {
    <#
    .SYNOPSIS
        Locates cdb.exe, including inside the WinDbg MSIX package.
    .DESCRIPTION
        On a current FLARE VM, WinDbg installs as an AppX package whose bin
        directory is NOT on PATH, so where.exe alone reports cdb as missing.
        The package path embeds its version and must never be hardcoded.
    .EXAMPLE
        Find-CdbPath
    #>
    [CmdletBinding()]
    param()

    $onPath = Find-Executable -Name 'cdb'
    if ($onPath) { return $onPath }

    $appx = Get-AppxInstallLocation -Name 'Microsoft.WinDbg'
    if ($appx) {
        $candidate = Join-Path $appx 'amd64\cdb.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    $kit = 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe'
    if (Test-Path -LiteralPath $kit) { return $kit }
    return $null
}

function Get-JavaVersion {
    <#
    .SYNOPSIS
        Returns the JDK version, or $null if it cannot be determined.
    .DESCRIPTION
        java -version writes to stderr, which Invoke-CommandLine merges into its
        output. Handles both 'openjdk version "25"' and legacy '1.8.0_xxx'.

        Modern JDKs report a single-component version. [version] requires at
        least major.minor, so a bare '25' is padded to '25.0' rather than being
        thrown away - which is exactly what a bare cast did, silently, via the
        catch below.
    .PARAMETER JavaPath
        Path to java.exe.
    .EXAMPLE
        Get-JavaVersion -JavaPath 'C:\Program Files\OpenJDK\jdk-25\bin\java.exe'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JavaPath)

    try {
        $out = Invoke-CommandLine -FilePath $JavaPath -Arguments @('-version')
        $text = (@($out) -join ' ')
        if ($text -notmatch 'version\s+"(\d+)(\.\d+)?(\.\d+)?') { return $null }

        $parts = @($Matches[1])
        if ($Matches[2]) { $parts += $Matches[2].TrimStart('.') }
        if ($Matches[3]) { $parts += $Matches[3].TrimStart('.') }
        while ($parts.Count -lt 2) { $parts += '0' }
        return [version]($parts -join '.')
    } catch {
        return $null
    }
}

function Get-MachineFact {
    <#
    .SYNOPSIS
        Collects RAM, free disk, VM status, and elevation. Exists as a mock seam.
    .EXAMPLE
        Get-MachineFact
    #>
    [CmdletBinding()]
    param()

    $cs = Get-CimInstance Win32_ComputerSystem
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $vmHints = @('VMware', 'VirtualBox', 'Virtual Machine', 'KVM', 'QEMU', 'Xen')

    [PSCustomObject]@{
        FreeDiskGb       = [math]::Round($disk.FreeSpace / 1GB, 1)
        TotalRamGb       = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        IsVirtualMachine = [bool]($vmHints | Where-Object {
                $cs.Model -like "*$_*" -or $cs.Manufacturer -like "*$_*" })
        IsAdministrator  = $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
}

function Get-HostInventory {
    <#
    .SYNOPSIS
        Builds the complete host inventory consumed by every later phase.
    .DESCRIPTION
        Absent tools are reported as $null, never as an error. Phase 0 decides
        which absences are fatal; this function only observes.
    .EXAMPLE
        Get-HostInventory | Format-List
    #>
    [CmdletBinding()]
    param()

    $python = Find-Executable -Name 'python'
    $java = Find-Executable -Name 'java'
    $ghidra = Find-GhidraRoot
    $bnRoot = Find-BinaryNinjaRoot
    $facts = Get-MachineFact

    [PSCustomObject]@{
        Python                  = $python
        PythonVersion           = if ($python) { Get-PythonVersion -PythonPath $python } else { $null }
        Jdk                     = $java
        JdkVersion              = if ($java) { Get-JavaVersion -JavaPath $java } else { $null }
        Cdb                     = Find-CdbPath
        Uv                      = Find-Executable -Name 'uv'
        X64dbgRoot              = Find-X64dbgRoot
        GhidraRoot              = $ghidra
        GhidraVersion           = if ($ghidra) { Get-GhidraVersion -GhidraRoot $ghidra } else { $null }
        BinaryNinjaRoot         = $bnRoot
        BinaryNinjaSettingsPath = Get-BinaryNinjaSettingsPath
        BinaryNinjaMcpCapable   = Test-BinaryNinjaMcpCapable -BinaryNinjaRoot $bnRoot
        ClaudeCode              = Find-Executable -Name 'claude'
        FreeDiskGb              = $facts.FreeDiskGb
        TotalRamGb              = $facts.TotalRamGb
        IsVirtualMachine        = $facts.IsVirtualMachine
        IsAdministrator         = $facts.IsAdministrator
    }
}

function Test-NetworkReachable {
    <#
    .SYNOPSIS
        True when the symbol server host answers. Exists as a mock seam.
    .DESCRIPTION
        Phase 2 downloads symbols and Phase 3 downloads packages, so a box with
        no egress cannot complete a run. Probing the actual symbol server is a
        better signal than pinging a generic address.
    .PARAMETER HostName
        Host to probe.
    .EXAMPLE
        Test-NetworkReachable
    #>
    [CmdletBinding()]
    param([string]$HostName = 'msdl.microsoft.com')

    try {
        return [bool](Test-NetConnection -ComputerName $HostName -Port 443 `
                -InformationLevel Quiet -WarningAction SilentlyContinue)
    } catch {
        return $false
    }
}

function Test-Preflight {
    <#
    .SYNOPSIS
        Returns the list of hard blockers preventing this run, empty if none.
    .DESCRIPTION
        Every blocker is reported, not just the first, so one run surfaces all
        the remediation the operator needs. Advisory conditions such as low RAM
        belong in Get-PreflightWarning, not here: blocking on them would make
        the installer unusable on the boxes it targets.
    .PARAMETER Inventory
        The host inventory from Get-HostInventory.
    .EXAMPLE
        $blockers = Test-Preflight -Inventory $inv
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Inventory)

    $blockers = @()

    if (-not $Inventory.IsAdministrator) {
        $blockers += ('Not running as Administrator. Re-launch PowerShell with ' +
            '"Run as administrator" and run this script again.')
    }
    if (-not $Inventory.IsVirtualMachine) {
        $blockers += ('This does not look like a virtual machine. RE tooling must not be ' +
            'installed on a host OS. Run this inside the FLARE VM.')
    }
    if (-not $Inventory.ClaudeCode) {
        $blockers += ('Claude Code was not found for the current user. It is a prerequisite, ' +
            'not installed by this script. Install it, confirm "claude --version" works ' +
            'as the analyst user, then re-run.')
    }
    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        $blockers += ("PowerShell $($PSVersionTable.PSVersion) is too old. " +
            'Version 5.1 or later is required; install Windows Management Framework 5.1.')
    }
    if (-not (Test-NetworkReachable)) {
        $blockers += ('No network reachable. This run downloads symbols and pinned packages, ' +
            'so it cannot proceed offline. Restore egress and re-run.')
    }
    return $blockers
}

function Get-PreflightWarning {
    <#
    .SYNOPSIS
        Returns advisory conditions worth reporting but not worth blocking on.
    .DESCRIPTION
        Separated from Test-Preflight so that "uncomfortable" never silently
        becomes "refuses to run".
    .PARAMETER Inventory
        The host inventory from Get-HostInventory.
    .EXAMPLE
        Get-PreflightWarning -Inventory $inv | ForEach-Object { Write-Warning $_ }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Inventory)

    $warnings = @()
    if ($Inventory.TotalRamGb -lt 32) {
        $warnings += ("Only $($Inventory.TotalRamGb) GB RAM. Ghidra, Binary Ninja, a debugger " +
            'and the agent co-resident want 32 GB; expect swapping.')
    }
    if ($Inventory.FreeDiskGb -lt 20) {
        $warnings += ("Only $($Inventory.FreeDiskGb) GB free disk. Symbol caches and Ghidra " +
            'projects grow quickly.')
    }
    return $warnings
}

function Assert-Preflight {
    <#
    .SYNOPSIS
        Throws with a combined, actionable message when preflight blockers exist.
    .PARAMETER Inventory
        The host inventory from Get-HostInventory.
    .EXAMPLE
        Assert-Preflight -Inventory $c.Inventory
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Inventory)

    # @() is load-bearing: PowerShell unrolls an empty array on return, so a
    # healthy host yields $null here and $null.Count throws under StrictMode.
    # Without the wrap, Assert-Preflight fails on exactly the boxes that pass.
    $blockers = @(Test-Preflight -Inventory $Inventory)
    if ($blockers.Count -gt 0) {
        throw ("Preflight failed:`n  - " + ($blockers -join "`n  - "))
    }
}

Export-ModuleMember -Function Invoke-CommandLine, Find-Executable, Compare-VersionAtLeast, `
    Get-PythonVersion, Test-FileContainsAscii, Get-AppxInstallLocation, Find-X64dbgRoot, `
    Find-GhidraRoot, Get-GhidraVersion, Find-BinaryNinjaRoot, Get-BinaryNinjaSettingsPath, `
    Test-BinaryNinjaMcpCapable, Find-CdbPath, Get-JavaVersion, Get-MachineFact, Get-HostInventory, `
    Test-NetworkReachable, Test-Preflight, Get-PreflightWarning, Assert-Preflight
