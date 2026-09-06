Set-StrictMode -Version Latest

$Script:ValidPhaseStatus = @('ok', 'skipped', 'failed', 'aborted')

function Write-ReAgentLog {
    <#
    .SYNOPSIS
        Writes a timestamped, levelled log line to the host and the transcript.
    .PARAMETER Level
        One of INFO, WARN, ERROR.
    .PARAMETER Message
        The text to log.
    .EXAMPLE
        Write-ReAgentLog -Level INFO -Message 'Phase 0 (Preflight): starting.'
    #>
    [CmdletBinding()]
    # Write-Host is deliberate: this is operator-facing installer progress that must
    # land in the Start-Transcript log. Write-Verbose is suppressed by default and
    # Write-Information is not reliably transcribed on PowerShell 5.1.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $stamp = (Get-Date).ToString('o')
    Write-Host "[$stamp] [$Level] $Message"
}

function New-PhaseResult {
    <#
    .SYNOPSIS
        Builds the result record for a single phase.
    .DESCRIPTION
        Validation lives here rather than on the parameter so the error names the
        offending value and lists the valid set, which a ValidateSet failure does
        not do as clearly for a caller reading a transcript.
    .PARAMETER Id
        The phase number from the phase table.
    .PARAMETER Name
        The phase name from the phase table.
    .PARAMETER Status
        One of ok, skipped, failed, aborted.
    .PARAMETER DurationMs
        Wall-clock duration of the phase, in milliseconds.
    .PARAMETER ErrorMessage
        The failure text, when Status is failed or aborted.
    .EXAMPLE
        New-PhaseResult -Id 3 -Name 'McpServers' -Status 'ok' -DurationMs 1200
    #>
    [CmdletBinding()]
    # New-PhaseResult is a pure factory: it builds and returns an object and
    # touches nothing outside itself. ShouldProcess would be noise on a call
    # that cannot be declined into a meaningful no-op.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][int]$DurationMs,
        [string]$ErrorMessage = ''
    )
    if ($Script:ValidPhaseStatus -notcontains $Status) {
        throw "Invalid phase status '$Status'. Expected one of: $($Script:ValidPhaseStatus -join ', ')"
    }
    [PSCustomObject]@{
        Id           = $Id
        Name         = $Name
        Status       = $Status
        DurationMs   = $DurationMs
        ErrorMessage = $ErrorMessage
    }
}

function Get-ReAgentExitCode {
    <#
    .SYNOPSIS
        Maps a set of phase results to the script's process exit code.
    .DESCRIPTION
        0 = all good, 1 = completed with non-fatal failures, 2 = aborted on a hard blocker.
        Aborted outranks failed: a hard blocker is the more actionable signal.
    .PARAMETER PhaseResults
        The phase result objects from this run. An empty run is a clean run.
    .EXAMPLE
        exit (Get-ReAgentExitCode -PhaseResults $results)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$PhaseResults)

    if ($PhaseResults | Where-Object { $_.Status -eq 'aborted' }) { return 2 }
    if ($PhaseResults | Where-Object { $_.Status -eq 'failed' }) { return 1 }
    return 0
}

function Invoke-Phase {
    <#
    .SYNOPSIS
        Runs one phase with logging, idempotency, timing, and failure isolation.
    .DESCRIPTION
        Calls the phase's Test block first; when it returns true and -Force was
        not given, the phase is skipped. A throwing phase is recorded as failed
        and does not stop the run - the caller decides what is a hard dependency.

        A Test block that throws is treated as "cannot confirm, so run it",
        never as a failure: an idempotency probe that errors must not be able to
        abort an install.
    .PARAMETER Phase
        Hashtable with keys Id, Name, Test (scriptblock), Fn (scriptblock).
    .PARAMETER Context
        Shared state passed to both blocks. Mutated by phases to publish results.
    .PARAMETER Force
        Run the phase even when its Test reports it already satisfied.
    .EXAMPLE
        Invoke-Phase -Phase $p -Context $context -Force:$Force
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Phase,
        [Parameter(Mandatory)][hashtable]$Context,
        [switch]$Force
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $already = & $Phase.Test $Context
    } catch {
        $already = $false
    }

    if ($already -and -not $Force) {
        $sw.Stop()
        Write-ReAgentLog -Level INFO `
            -Message "Phase $($Phase.Id) ($($Phase.Name)): already satisfied, skipping."
        return New-PhaseResult -Id $Phase.Id -Name $Phase.Name -Status 'skipped' `
            -DurationMs ([int]$sw.ElapsedMilliseconds)
    }

    Write-ReAgentLog -Level INFO -Message "Phase $($Phase.Id) ($($Phase.Name)): starting."
    try {
        $null = & $Phase.Fn $Context
        $sw.Stop()
        Write-ReAgentLog -Level INFO `
            -Message "Phase $($Phase.Id) ($($Phase.Name)): ok in $($sw.ElapsedMilliseconds)ms."
        return New-PhaseResult -Id $Phase.Id -Name $Phase.Name -Status 'ok' `
            -DurationMs ([int]$sw.ElapsedMilliseconds)
    } catch {
        $sw.Stop()
        $msg = $_.Exception.Message
        Write-ReAgentLog -Level ERROR `
            -Message "Phase $($Phase.Id) ($($Phase.Name)): FAILED - $msg"
        # Without the frame, a strict-mode property error names no file and no
        # line, and the phase that reports it is rarely the one at fault.
        if ($_.ScriptStackTrace) {
            Write-ReAgentLog -Level ERROR -Message (
                '  ' + (($_.ScriptStackTrace -split "`r?`n")[0]).Trim())
        }
        return New-PhaseResult -Id $Phase.Id -Name $Phase.Name -Status 'failed' `
            -DurationMs ([int]$sw.ElapsedMilliseconds) -ErrorMessage $msg
    }
}

function Write-Utf8NoBomFile {
    <#
    .SYNOPSIS
        Writes text as UTF-8 with no byte order mark.
    .DESCRIPTION
        PowerShell 5.1's 'Set-Content -Encoding UTF8' always emits a BOM.
        Binary Ninja refuses to load a settings.json that starts with one -
        "Parse exception in JSON value at offset (0)" - and nothing that reads
        these files needs it, so every generated file goes out without one.
    .PARAMETER Path
        Destination file. Created or overwritten.
    .PARAMETER Text
        The content. A trailing newline is added when it is missing.
    .EXAMPLE
        Write-Utf8NoBomFile -Path 'C:\re\agent\.mcp.json' -Text $json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    $full = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
    $content = if ($Text.EndsWith("`n")) { $Text } else { $Text + "`r`n" }
    [System.IO.File]::WriteAllText($full, $content,
        (New-Object System.Text.UTF8Encoding($false)))
}

function Write-FileIfChanged {
    <#
    .SYNOPSIS
        Writes text only when it differs from what is already on disk.
    .DESCRIPTION
        Derived files are rewritten on every run, and an unconditional write
        changes LastWriteTime even when the content is identical. That is what
        made a healthy pyghidra-mcp restart on every run (docs/mvp/MVP.md:204).

        The comparison recomputes what the disk should contain from $Text using
        the same trailing-newline rule Write-Utf8NoBomFile applies on write, then
        compares that against what is actually on disk. An asymmetric comparison
        would never converge: the writer appends a newline the next compare
        misses, so every run would rewrite.
    .PARAMETER Path
        Destination file. Parent directories are created.
    .PARAMETER Text
        The content.
    .OUTPUTS
        [bool] True when the file was written, false when it was already current.
    .EXAMPLE
        Write-FileIfChanged -Path $skill -Text $markdown
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    $wanted = if ($Text.EndsWith("`n")) { $Text } else { $Text + "`r`n" }

    if (Test-Path -LiteralPath $Path) {
        $current = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($null -ne $current -and $current -eq $wanted) {
            Write-ReAgentLog -Level INFO -Message "Unchanged: '$Path'."
            return $false
        }
    } else {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -ItemType Directory -Path $dir -Force
        }
    }

    Write-Utf8NoBomFile -Path $Path -Text $wanted
    return $true
}


function Select-Phase {
    <#
    .SYNOPSIS
        Chooses which phases a run executes.
    .DESCRIPTION
        -VerifyOnly deliberately keeps phase 0. Verification decides almost
        everything from the host inventory, so running it without one turns
        every check into a confident false negative - which is worse than no
        report at all. It does not run phase 3: verifying must not install.
    .PARAMETER PhaseTable
        The full phase table, in execution order.
    .PARAMETER Phases
        Run only these phase ids.
    .PARAMETER VerifyOnly
        Run preflight, verification and the manifest. Wins over -Phases.
    .EXAMPLE
        Select-Phase -PhaseTable $phaseTable -VerifyOnly
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$PhaseTable,
        [int[]]$Phases,
        [switch]$VerifyOnly
    )

    if ($VerifyOnly) { return @($PhaseTable | Where-Object { $_.Id -in @(0, 5, 6) }) }
    if ($Phases) { return @($PhaseTable | Where-Object { $_.Id -in $Phases }) }
    return @($PhaseTable)
}


function Grant-PathFullControl {
    <#
    .SYNOPSIS
        Gives an identity inheritable full control of a directory.
    .DESCRIPTION
        The installer runs elevated, so everything it creates under
        C:\ProgramData inherits that key's defaults - BUILTIN\Users gets
        ReadAndExecute and nothing more. The analyst then cannot rewrite
        manifest.json, and an unelevated -VerifyOnly dies on its last phase.

        The ace is written with both inheritance flags so files created later
        pick it up; existing children are covered by the same inheritance once
        it is set. Failure warns rather than throwing: a run that cannot re-acl
        its state directory is degraded, not broken.
    .PARAMETER Path
        Directory to grant on.
    .PARAMETER Identity
        User to grant to, typically $env:USERNAME.
    .EXAMPLE
        Grant-PathFullControl -Path $config.paths.stateRoot -Identity $env:USERNAME
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Identity
    )

    if (-not $PSCmdlet.ShouldProcess($Path, "Grant $Identity full control")) { return $false }

    try {
        $acl = Get-Acl -Path $Path
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $Identity, 'FullControl',
            'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl -Path $Path -AclObject $acl
        return $true
    } catch {
        Write-Warning ("Could not grant '$Identity' full control of '$Path': " +
            "$($_.Exception.Message) An unelevated -VerifyOnly may fail to write its manifest.")
        return $false
    }
}

Export-ModuleMember -Function Write-ReAgentLog, New-PhaseResult, Get-ReAgentExitCode, `
    Invoke-Phase, Select-Phase, Write-Utf8NoBomFile, Write-FileIfChanged, `
    Grant-PathFullControl
