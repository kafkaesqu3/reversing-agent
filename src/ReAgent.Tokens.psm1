Set-StrictMode -Version Latest

function New-BearerToken {
    <#
    .SYNOPSIS
        Generates a cryptographically random bearer token as lowercase hex.
    .DESCRIPTION
        Defaults to 32 bytes (64 hex chars). x64dbg's plugin generates its own
        tokens as 16 bytes (32 hex chars) via SystemFunction036, so pre-seeded
        values for that server pass -ByteCount 16 to match the format the plugin
        would otherwise have produced itself.
    .PARAMETER ByteCount
        Number of random bytes. The hex string is twice this long.
    .EXAMPLE
        New-BearerToken
    .EXAMPLE
        New-BearerToken -ByteCount 16
    #>
    [CmdletBinding()]
    # A pure generator: it returns a string and writes nothing. ShouldProcess
    # would be noise on a call that cannot be declined into a useful no-op.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param([ValidateRange(16, 64)][int]$ByteCount = 32)

    $bytes = New-Object byte[] $ByteCount
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Save-ServerToken {
    <#
    .SYNOPSIS
        Persists a server's bearer token with an ACL restricted to the current user.
    .DESCRIPTION
        DPAPI is deliberately not used: its blobs are machine and user bound and
        would not survive the VM being cloned or the file being read by another
        account.
    .PARAMETER Name
        The server name, used as the file name.
    .PARAMETER Token
        The token text.
    .PARAMETER TokenRoot
        Directory holding token files.
    .EXAMPLE
        Save-ServerToken -Name 'binaryninja' -Token $t -TokenRoot 'C:\re\mcp\tokens'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$TokenRoot
    )

    if (-not (Test-Path -LiteralPath $TokenRoot)) {
        $null = New-Item -ItemType Directory -Path $TokenRoot -Force
    }
    $path = Join-Path $TokenRoot "$Name.token"
    Set-Content -LiteralPath $path -Value $Token -Encoding ASCII -NoNewline

    try {
        $acl = Get-Acl -LiteralPath $path
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
            'FullControl', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $path -AclObject $acl
    } catch {
        # A token readable by more accounts than intended is worth shouting
        # about, but it must not abort an otherwise good install.
        Write-ReAgentLog -Level WARN -Message (
            "Could not restrict the ACL on '$path': $($_.Exception.Message)")
    }
}

function Get-ServerToken {
    <#
    .SYNOPSIS
        Reads a previously stored bearer token, or $null if there is none.
    .PARAMETER Name
        The server name.
    .PARAMETER TokenRoot
        Directory holding token files.
    .EXAMPLE
        Get-ServerToken -Name 'binaryninja' -TokenRoot 'C:\re\mcp\tokens'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TokenRoot
    )

    $path = Join-Path $TokenRoot "$Name.token"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -LiteralPath $path -Raw).Trim()
}

function Get-OrNewServerToken {
    <#
    .SYNOPSIS
        Returns the stored token for a server, generating and saving one only if absent.
    .DESCRIPTION
        Idempotency: regenerating a token breaks the server that is already
        running with the old one, so an existing token is always reused.
    .PARAMETER Name
        The server name.
    .PARAMETER TokenRoot
        Directory holding token files.
    .PARAMETER ByteCount
        Random bytes for a newly generated token.
    .EXAMPLE
        Get-OrNewServerToken -Name 'binaryninja' -TokenRoot $root
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TokenRoot,
        [ValidateRange(16, 64)][int]$ByteCount = 32
    )

    $existing = Get-ServerToken -Name $Name -TokenRoot $TokenRoot
    if ($existing) { return $existing }

    $token = New-BearerToken -ByteCount $ByteCount
    Save-ServerToken -Name $Name -Token $token -TokenRoot $TokenRoot
    return $token
}

function Get-X64dbgToken {
    <#
    .SYNOPSIS
        Reads the bearer token from an x64dbg MCP plugin config.
    .DESCRIPTION
        The field is 'AuthToken' - verified against src/core/config.zig upstream,
        alongside IpAddress, Port and AutoStart. Returns $null when the file does
        not exist or carries no token, which is how a pre-seed decides whether it
        has anything to preserve.
    .PARAMETER McpConfigPath
        Path to the plugin's mcp_config.json.
    .EXAMPLE
        Get-X64dbgToken -McpConfigPath 'C:\Tools\x64dbg\release\x64\mcp_config.json'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$McpConfigPath)

    if (-not (Test-Path -LiteralPath $McpConfigPath)) { return $null }
    try {
        $cfg = Get-Content -LiteralPath $McpConfigPath -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
    if ($cfg.PSObject.Properties.Name -contains 'AuthToken') { return $cfg.AuthToken }
    return $null
}

Export-ModuleMember -Function New-BearerToken, Save-ServerToken, Get-ServerToken, `
    Get-OrNewServerToken, Get-X64dbgToken
