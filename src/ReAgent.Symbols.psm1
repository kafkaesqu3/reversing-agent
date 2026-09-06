Set-StrictMode -Version Latest

function Get-SymbolPathValue {
    <#
    .SYNOPSIS
        Builds the _NT_SYMBOL_PATH value: downstream cache first, server second.
    .PARAMETER CacheDir
        Local symbol cache directory.
    .PARAMETER Server
        Upstream symbol server URL.
    .EXAMPLE
        Get-SymbolPathValue -CacheDir 'C:\re\symbols' -Server $cfg.symbols.server
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CacheDir,
        [Parameter(Mandatory)][string]$Server
    )
    return "SRV*$CacheDir*$Server"
}

function Get-MachineSymbolPath {
    <#
    .SYNOPSIS
        Reads the machine-wide _NT_SYMBOL_PATH. Exists as a mock seam.
    .EXAMPLE
        Get-MachineSymbolPath
    #>
    [CmdletBinding()]
    param()
    return [Environment]::GetEnvironmentVariable('_NT_SYMBOL_PATH', 'Machine')
}

function Test-SymbolsReady {
    <#
    .SYNOPSIS
        True when _NT_SYMBOL_PATH is set machine-wide and the cache exists.
    .DESCRIPTION
        Setting the variable is the part that matters. A populated cache is NOT
        required here: symchk is unavailable on a current FLARE VM, so pre-warm
        is best-effort and an empty cache simply fills on first use.
    .PARAMETER Config
        The parsed configuration object.
    .EXAMPLE
        Test-SymbolsReady -Config $c.Config
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    $want = Get-SymbolPathValue -CacheDir $Config.paths.symbolCache -Server $Config.symbols.server
    $have = Get-MachineSymbolPath
    if ($have -ne $want) { return $false }
    return (Test-Path -LiteralPath $Config.paths.symbolCache)
}

function Install-Symbols {
    <#
    .SYNOPSIS
        Sets _NT_SYMBOL_PATH machine-wide and pre-warms the cache where possible.
    .DESCRIPTION
        Without a symbol path the agent reasons about unnamed addresses, which
        degrades every WinDbg answer.

        Pre-warming needs symchk.exe, which is NOT shipped in the WinDbg MSIX
        package and is absent from a stock FLARE VM. When it is missing this
        warns and moves on rather than failing the phase - the cache fills on
        first use, so the only cost is a slower first answer.

        Any pre-existing _NT_SYMBOL_PATH is logged before being replaced, since
        the operator may have set it deliberately.
    .PARAMETER Config
        The parsed configuration object.
    .EXAMPLE
        Install-Symbols -Config $c.Config
    #>
    [CmdletBinding(SupportsShouldProcess)]
    # The plural is correct and deliberate. This sets the symbol PATH and warms
    # a CACHE of many symbol files; Install-Symbol would describe neither.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    param([Parameter(Mandatory)][object]$Config)

    $existing = Get-MachineSymbolPath
    if ($existing) {
        Write-ReAgentLog -Level WARN -Message "Replacing existing _NT_SYMBOL_PATH: '$existing'"
    }

    $value = Get-SymbolPathValue -CacheDir $Config.paths.symbolCache -Server $Config.symbols.server
    if ($PSCmdlet.ShouldProcess('_NT_SYMBOL_PATH', "Set to $value")) {
        [Environment]::SetEnvironmentVariable('_NT_SYMBOL_PATH', $value, 'Machine')
        $env:_NT_SYMBOL_PATH = $value
    }

    if (-not (Test-Path -LiteralPath $Config.paths.symbolCache)) {
        $null = New-Item -ItemType Directory -Path $Config.paths.symbolCache -Force
    }

    Invoke-SymbolPrewarm -Config $Config -SymbolPath $value
}

function Invoke-SymbolPrewarm {
    <#
    .SYNOPSIS
        Best-effort population of the symbol cache. Never throws.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER SymbolPath
        The _NT_SYMBOL_PATH value to hand symchk.
    .EXAMPLE
        Invoke-SymbolPrewarm -Config $cfg -SymbolPath $value
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$SymbolPath
    )

    $symchk = Find-Executable -Name 'symchk'
    if (-not $symchk) {
        Write-ReAgentLog -Level WARN -Message (
            'symchk.exe not found - it is not shipped in the WinDbg MSIX package. ' +
            'Skipping symbol pre-warm; the cache will fill on first use, so only ' +
            'the first WinDbg answer is slower.')
        return
    }

    foreach ($dll in $Config.symbols.prewarm) {
        $full = Join-Path $env:SystemRoot "System32\$dll"
        if (-not (Test-Path -LiteralPath $full)) { continue }
        Write-ReAgentLog -Level INFO -Message "Pre-warming symbols for $dll."
        try {
            $null = Invoke-CommandLine -FilePath $symchk `
                -Arguments @('/r', $full, '/s', $SymbolPath)
        } catch {
            Write-ReAgentLog -Level WARN -Message (
                "Pre-warm failed for ${dll}: $($_.Exception.Message)")
        }
    }
}

Export-ModuleMember -Function Get-SymbolPathValue, Get-MachineSymbolPath, `
    Test-SymbolsReady, Install-Symbols, Invoke-SymbolPrewarm
