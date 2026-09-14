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


function Resolve-PdbPath {
    <#
    .SYNOPSIS
        Resolves a module name to its PDB file inside a symbol-server cache.
    .DESCRIPTION
        A symbol-server cache nests one level deeper than it looks:
        <root>\ntdll.pdb is a DIRECTORY holding <GUID>\ntdll.pdb. Handing the
        directory to a PDB reader fails with HRESULT 0x806D0005, reported as
        'file not found or inaccessible' - an error that names neither the
        directory nor the cause.

        The newest match wins when a cache holds several builds of one module,
        which is what a re-warmed cache looks like.
    .PARAMETER SymbolRoot
        The cache root, e.g. C:\re\symbols.
    .PARAMETER Module
        Module name without extension, e.g. 'ntdll'.
    .OUTPUTS
        [string] Full path to the .pdb file, or $null when absent.
    .EXAMPLE
        Resolve-PdbPath -SymbolRoot 'C:\re\symbols' -Module 'ntdll'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SymbolRoot,
        [Parameter(Mandatory)][string]$Module
    )

    $container = Join-Path $SymbolRoot "$Module.pdb"
    if (-not (Test-Path -LiteralPath $container -PathType Container)) { return $null }
    $match = Get-ChildItem -LiteralPath $container -Filter "$Module.pdb" -File -Recurse `
        -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $match) { return $null }
    return $match.FullName
}

function Test-PdbPathCheck {
    <#
    .SYNOPSIS
        Runs check Q1: a configured pdb module must resolve to a real file.
    .DESCRIPTION
        Reads only the repo's config and the symbol cache, so it runs on every
        verification including -VerifyOnly on a host where nothing is installed.
        A server with no pdb block is not this check's business.
    .PARAMETER Server
        One entry from the config's mcpServers[].
    .PARAMETER SymbolRoot
        The symbol cache root.
    .OUTPUTS
        [array] Zero or one {Check='Q1'; Message} findings.
    .EXAMPLE
        Test-PdbPathCheck -Server $srv -SymbolRoot 'C:\re\symbols'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][string]$SymbolRoot
    )

    if ($Server.PSObject.Properties.Name -notcontains 'pdb') { return @() }
    $module = "$($Server.pdb.module)"
    if (Resolve-PdbPath -SymbolRoot $SymbolRoot -Module $module) { return @() }
    return @([PSCustomObject]@{ Check = 'Q1'; Message = (
                "Server '$($Server.name)' names PDB module '$module', which does not " +
                "resolve to a file under '$SymbolRoot'. Passing the container directory " +
                'fails inside pdbsql with HRESULT 0x806D0005 ("file not found or ' +
                'inaccessible"). Warm the symbol cache for this module first.') })
}

Export-ModuleMember -Function Get-SymbolPathValue, Get-MachineSymbolPath, `
    Test-SymbolsReady, Install-Symbols, Invoke-SymbolPrewarm, Resolve-PdbPath, `
    Test-PdbPathCheck
