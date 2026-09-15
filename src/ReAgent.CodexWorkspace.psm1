Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ReAgent.CodexAdapter.psm1') -Force

$script:CodexInstructionMarker =
    '<!-- re-agent-managed: codex-operating-contract v1 -->'

function ConvertTo-InstructionNewline {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    return ([regex]::Replace($Text, '\r?\n', "`n")).TrimEnd([char[]]@("`r", "`n"))
}

function Get-ManagedTextByte {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $content = if ($Text.EndsWith("`n")) { $Text } else { $Text + "`r`n" }
    $encoding = New-Object Text.UTF8Encoding($false)
    return $encoding.GetBytes($content)
}

function Get-ManagedByteHash {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '')
    } finally {
        $algorithm.Dispose()
    }
}

function New-ManagedTextResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][bool]$Changed,
        [AllowEmptyString()][string]$BackupPath = ''
    )

    return [PSCustomObject]@{
        Path = $Path; Status = $Status; Sha256 = $Sha256
        Changed = $Changed; BackupPath = $BackupPath
    }
}

function Invoke-ManagedTextReplace {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PendingPath,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][bool]$DestinationExists,
        [AllowEmptyString()][string]$BackupPath = ''
    )

    try {
        [IO.File]::WriteAllBytes($PendingPath, $Bytes)
        if (-not $DestinationExists) {
            [IO.File]::Move($PendingPath, $Path)
        } else {
            $backup = if ($BackupPath) { $BackupPath } else { $null }
            [IO.File]::Replace($PendingPath, $Path, $backup)
        }
    } finally {
        if (Test-Path -LiteralPath $PendingPath) {
            Remove-Item -LiteralPath $PendingPath -Force
        }
    }
}

function New-ClientInstructionText {
    <#
    .SYNOPSIS
        Renders the shared operating contract for Claude or Codex.
    .PARAMETER TemplateRoot
        Directory containing the instructions template directory.
    .PARAMETER Client
        Client whose instruction tail is selected.
    .OUTPUTS
        [string] Deterministic Markdown with LF newlines and one final newline.
    .EXAMPLE
        New-ClientInstructionText -TemplateRoot '.\templates' -Client Codex
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][string]$TemplateRoot,
        [Parameter(Mandatory)][ValidateSet('Claude', 'Codex')][string]$Client
    )

    $instructionRoot = Join-Path $TemplateRoot 'instructions'
    $commonPath = Join-Path $instructionRoot 'common.md.template'
    $tailPath = Join-Path $instructionRoot ($Client.ToLowerInvariant() + '.md.template')
    foreach ($path in @($commonPath, $tailPath)) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Instruction template not found at '$path'."
        }
    }

    $common = ConvertTo-InstructionNewline -Text (
        Get-Content -LiteralPath $commonPath -Raw -Encoding UTF8)
    $tail = ConvertTo-InstructionNewline -Text (
        Get-Content -LiteralPath $tailPath -Raw -Encoding UTF8)
    $body = $common + "`n`n" + $tail + "`n"
    if ($Client -eq 'Claude') { return $body }

    $body = ConvertTo-CodexWorkflowText -Text $body -SkillNames @()
    return $script:CodexInstructionMarker + "`n`n" + $body
}

function Test-ReAgentOwnershipMarker {
    <#
    .SYNOPSIS
        Tests whether a text file starts with an exact RE Agent marker.
    .PARAMETER Path
        Existing text file to inspect.
    .PARAMETER Marker
        Exact first-line ownership marker.
    .OUTPUTS
        [bool] True only when the marker is the complete first line.
    .EXAMPLE
        Test-ReAgentOwnershipMarker -Path '.\AGENTS.md' -Marker '<!-- managed -->'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Marker
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($null -eq $text) { return $false }
    $comparison = [StringComparison]::Ordinal
    return [string]::Equals($text, $Marker, $comparison) -or
        $text.StartsWith($Marker + "`n", $comparison) -or
        $text.StartsWith($Marker + "`r`n", $comparison)
}

function Set-ManagedTextFile {
    <#
    .SYNOPSIS
        Reconciles one ownership-marked UTF-8 text file safely.
    .DESCRIPTION
        Refuses unmanaged collisions before ShouldProcess, preserves unchanged
        files, and replaces changed files from a same-directory pending file.
    .PARAMETER Path
        Managed destination path.
    .PARAMETER Text
        Complete candidate text.
    .PARAMETER Marker
        Exact marker required at the start of an existing file.
    .PARAMETER BackupOnChange
        Whether a changed destination receives a unique backup.
    .OUTPUTS
        [pscustomobject] Path, status, hash, changed flag, and backup path.
    .EXAMPLE
        Set-ManagedTextFile -Path '.\AGENTS.md' -Text $text `
            -Marker '<!-- managed -->' -BackupOnChange $true
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][bool]$BackupOnChange
    )

    $fullPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    $wanted = Get-ManagedTextByte -Text $Text
    $hash = Get-ManagedByteHash -Bytes $wanted
    $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
    if ($exists -and -not (Test-ReAgentOwnershipMarker -Path $fullPath -Marker $Marker)) {
        throw "Refusing to replace unmanaged file '$fullPath'."
    }
    if ($exists) {
        $current = [IO.File]::ReadAllBytes($fullPath)
        if ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                $current, $wanted)) {
            return New-ManagedTextResult -Path $fullPath -Status 'unchanged' `
                -Sha256 $hash -Changed $false
        }
    }
    if (-not $PSCmdlet.ShouldProcess($fullPath, 'Write managed text')) {
        return New-ManagedTextResult -Path $fullPath -Status 'what-if' `
            -Sha256 $hash -Changed $true
    }

    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    $leaf = Split-Path -Leaf $fullPath
    $id = [guid]::NewGuid().ToString('N')
    $pending = Join-Path $parent "$leaf.$id.pending"
    $backup = if ($BackupOnChange -and $exists) {
        Join-Path $parent "$leaf.$id.bak"
    } else { '' }
    Invoke-ManagedTextReplace -Path $fullPath -PendingPath $pending `
        -Bytes $wanted -DestinationExists $exists -BackupPath $backup
    $status = if ($exists) { 'updated' } else { 'created' }
    return New-ManagedTextResult -Path $fullPath -Status $status `
        -Sha256 $hash -Changed $true -BackupPath $backup
}

function Write-CodexInstruction {
    <#
    .SYNOPSIS
        Reconciles the project-scoped Codex AGENTS.md contract.
    .PARAMETER Config
        Configuration containing paths.agentRoot.
    .PARAMETER TemplateRoot
        Directory containing instruction templates.
    .OUTPUTS
        [pscustomobject] Managed-file reconciliation record.
    .EXAMPLE
        Write-CodexInstruction -Config $config -TemplateRoot '.\templates'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$TemplateRoot
    )

    $path = Join-Path $Config.paths.agentRoot 'AGENTS.md'
    $text = New-ClientInstructionText -TemplateRoot $TemplateRoot -Client Codex
    return Set-ManagedTextFile -Path $path -Text $text `
        -Marker $script:CodexInstructionMarker -BackupOnChange $true `
        -WhatIf:$WhatIfPreference
}

Export-ModuleMember -Function New-ClientInstructionText, Write-CodexInstruction, `
    Test-ReAgentOwnershipMarker, Set-ManagedTextFile
