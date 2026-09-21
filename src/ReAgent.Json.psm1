Set-StrictMode -Version Latest

function Merge-JsonFile {
    <#
    .SYNOPSIS
        Merges keys into a JSON file, preserving everything already there.
    .DESCRIPTION
        Used for application settings files owned by someone else - Binary
        Ninja's settings.json above all. Backs the file up before writing and
        refuses to touch a file it cannot parse, because silently replacing an
        operator's settings is worse than failing.

        Keys not named in Values are left exactly as they were.
    .PARAMETER Path
        The JSON file. Created, with its parent directories, if absent.
    .PARAMETER Values
        Keys to set. Existing keys not named here are left untouched.
    .EXAMPLE
        Merge-JsonFile -Path $bnSettings -Values @{ 'ui.mcp.enabled' = $true }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Values
    )

    $existing = @{}
    $fileExists = Test-Path -LiteralPath $Path
    if ($fileExists) {
        $raw = Get-Content -LiteralPath $Path -Raw
        if ($raw -and $raw.Trim()) {
            try {
                $parsed = $raw | ConvertFrom-Json
            } catch {
                throw ("'$Path' is not valid JSON, so it cannot be merged into safely. " +
                    'Fix or move the file, then re-run.')
            }
            foreach ($p in $parsed.PSObject.Properties) { $existing[$p.Name] = $p.Value }
        }
    }

    $changed = -not $fileExists
    foreach ($k in $Values.Keys) {
        $currentJson = if ($existing.ContainsKey($k)) {
            ConvertTo-Json -InputObject $existing[$k] -Depth 12 -Compress
        } else {
            $null
        }
        $requestedJson = ConvertTo-Json -InputObject $Values[$k] -Depth 12 -Compress
        if ($null -eq $currentJson -or $currentJson -cne $requestedJson) {
            $changed = $true
        }
        $existing[$k] = $Values[$k]
    }

    if (-not $changed) {
        Write-ReAgentLog -Level INFO -Message "JSON settings at '$Path' are already current."
        return
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Merge JSON settings')) {
        if ($fileExists) {
            $backup = "$Path.bak-$((Get-Date).ToString('yyyyMMddHHmmss'))"
            Copy-Item -LiteralPath $Path -Destination $backup -Force
            Write-ReAgentLog -Level INFO -Message "Backed up '$Path' to '$backup'."
        } else {
            $dir = Split-Path -Parent $Path
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                $null = New-Item -ItemType Directory -Path $dir -Force
            }
        }
        Write-Utf8NoBomFile -Path $Path `
            -Text (([PSCustomObject]$existing) | ConvertTo-Json -Depth 12)
    }
}

Export-ModuleMember -Function Merge-JsonFile
