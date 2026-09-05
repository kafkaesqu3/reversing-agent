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

Export-ModuleMember -Function Invoke-CommandLine, Find-Executable, `
    Compare-VersionAtLeast, Get-PythonVersion
