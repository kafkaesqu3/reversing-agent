Set-StrictMode -Version Latest

# Depends on functions exported by sibling modules, which Install-REAgent.ps1
# imports into the session before this one: Write-ReAgentLog,
# Write-FileIfChanged, Assert-FileHash (Common).

$Script:ValidSkillStatus = @('installed', 'skipped', 'not-installed', 'failed')

function New-SkillResult {
    <#
    .SYNOPSIS
        Builds the result record for one skill pack.
    .DESCRIPTION
        Mirrors New-ServerResult deliberately: same four statuses, same
        Installed derivation. A scan refusal is 'failed' with findings on the
        record - inventing a fifth status would mean every consumer grows a
        branch it does not need.
    .PARAMETER Pack
        The pack's config entry.
    .PARAMETER Status
        One of installed, skipped, not-installed, failed.
    .PARAMETER SkillNames
        The skill directory names this pack installed.
    .PARAMETER Reason
        Why, for any status that is not 'installed'.
    .PARAMETER Findings
        Scanner findings, when the pack failed its scan.
    .EXAMPLE
        New-SkillResult -Pack $p -Status 'installed' -SkillNames @('windbg-crash')
    #>
    [CmdletBinding()]
    # Pure factory: builds and returns an object, writes nothing.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][string]$Status,
        [string[]]$SkillNames = @(),
        [string]$Reason = '',
        [array]$Findings = @()
    )

    if ($Script:ValidSkillStatus -notcontains $Status) {
        throw ("Invalid skill pack status '$Status'. Expected one of: " +
            ($Script:ValidSkillStatus -join ', '))
    }

    [PSCustomObject]@{
        Namespace  = $Pack.namespace
        Status     = $Status
        Installed  = ($Status -eq 'installed' -or $Status -eq 'skipped')
        SkillNames = @($SkillNames)
        Repo       = $Pack.source.repo
        Commit     = $Pack.source.commit
        TreeSha256 = $Pack.source.treeSha256
        ReviewedBy = $Pack.review.reviewedBy
        ReviewedAt = $Pack.review.reviewedAt
        Reason     = $Reason
        Findings   = @($Findings)
    }
}

function Get-SkillScanRule {
    <#
    .SYNOPSIS
        Loads the red-flag scanner rules.
    .DESCRIPTION
        Rules are data, not code: they are a threat-intelligence artifact that
        changes on a different cadence from the installer, and a reviewer who
        does not read PowerShell can still audit them.

        A missing, unparseable or empty rule file THROWS. It must never read as
        'the scan passed'.
    .PARAMETER Path
        Rule file. Defaults to data/skill-scan-rules.json beside the module.
    .EXAMPLE
        Get-SkillScanRule
    #>
    [CmdletBinding()]
    param([string]$Path = '')

    if (-not $Path) {
        $root = Join-Path $PSScriptRoot '..'
        $Path = Join-Path $root 'data\skill-scan-rules.json'
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("Skill scan rules not found at '$Path'. Refusing to scan: a missing rule " +
            'file must never read as a clean scan.')
    }
    $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $rules = @($doc.rules)
    if ($rules.Count -eq 0) {
        throw "Skill scan rules at '$Path' contain no rules. Refusing to scan."
    }
    return $rules
}

function Test-SkillContent {
    <#
    .SYNOPSIS
        Scans skill text for red flags.
    .DESCRIPTION
        Pure: text in, findings out, no filesystem. One loop over the rule
        table rather than a switch, which keeps complexity flat as rules grow.
    .PARAMETER Text
        The file's content.
    .PARAMETER Rules
        Rules from Get-SkillScanRule.
    .PARAMETER File
        Path recorded on each finding.
    .EXAMPLE
        Test-SkillContent -Text $md -Rules $rules -File 'SKILL.md'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][array]$Rules,
        [string]$File = ''
    )

    $findings = @()
    $lines = $Text -split "`r?`n"
    foreach ($rule in $Rules) {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $rule.pattern) {
                $findings += [PSCustomObject]@{
                    RuleId   = $rule.id
                    Severity = $rule.severity
                    File     = $File
                    Line     = $i + 1
                    Text     = $lines[$i].Trim()
                }
            }
        }
    }
    return $findings
}

function Select-UnwaivedFinding {
    <#
    .SYNOPSIS
        Removes findings covered by a recorded, justified exception.
    .DESCRIPTION
        Exceptions are per-skill and per-rule, never global. A global
        loosening of the rule file would be invisible; an exception is
        recorded in the manifest with its justification and gets reviewed.
    .PARAMETER Findings
        Findings from Test-SkillContent.
    .PARAMETER Exceptions
        The pack's scanExceptions entries.
    .PARAMETER Skill
        The upstream skill name the findings came from.
    .EXAMPLE
        Select-UnwaivedFinding -Findings $f -Exceptions $p.scanExceptions -Skill 'crash'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Findings,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Exceptions,
        [Parameter(Mandatory)][string]$Skill
    )

    $waived = @($Exceptions | Where-Object { $_.skill -eq $Skill } |
            ForEach-Object { $_.ruleId })
    return @($Findings | Where-Object { $waived -notcontains $_.RuleId })
}

function Get-ToolCatalog {
    <#
    .SYNOPSIS
        Loads the pinned per-server tool surface.
    .DESCRIPTION
        Checked into the repo, not stateRoot: stateRoot holds per-machine
        derived state, while the catalog is the EXPECTED surface, versioned
        alongside the skills that depend on it.

        This is what lets the adaptation gate run unattended. Three of four
        target servers need a GUI open, so a live-only gate would sit at
        not-testable on almost every run - the false-confidence failure of
        HANDOFF defect 1.
    .PARAMETER Path
        Catalog file. Defaults to data/tool-catalog.json beside the module.
    .EXAMPLE
        Get-ToolCatalog
    #>
    [CmdletBinding()]
    param([string]$Path = '')

    if (-not $Path) {
        $root = Join-Path $PSScriptRoot '..'
        $Path = Join-Path $root 'data\tool-catalog.json'
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("Tool catalog not found at '$Path'. Capture one with " +
            '.\Install-REAgent.ps1 -Attended -UpdateToolCatalog.')
    }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Get-CatalogServerTool {
    <#
    .SYNOPSIS
        Reads one server's entry out of the catalog.
    .DESCRIPTION
        Distinguishes 'no entry' from 'an entry with no tools'. Collapsing
        those would let a missing entry read as a server that advertises
        nothing, which is a silent pass.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER Server
        Server name.
    .EXAMPLE
        Get-CatalogServerTool -Catalog $c -Server 'pyghidra-mcp'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][string]$Server
    )

    if ($Catalog.servers.PSObject.Properties.Name -notcontains $Server) {
        return @{ Known = $false; Tools = @(); Pin = '' }
    }
    $e = $Catalog.servers.$Server
    return @{ Known = $true; Tools = @($e.tools); Pin = $e.pin }
}

function Compare-ToolCatalog {
    <#
    .SYNOPSIS
        Diffs a live tool list against the catalog.
    .DESCRIPTION
        Returns names, not just a boolean. A drop in tool count after an
        upgrade is a useful regression signal (docs/mvp/HANDOFF.md), and it is
        only actionable if the message says which tools went.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER Server
        Server name.
    .PARAMETER LiveTools
        Names the server advertised just now.
    .EXAMPLE
        Compare-ToolCatalog -Catalog $c -Server 'pyghidra-mcp' -LiveTools $t
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$LiveTools
    )

    $known = Get-CatalogServerTool -Catalog $Catalog -Server $Server
    return @{
        Added      = @($LiveTools | Where-Object { $known.Tools -notcontains $_ })
        Removed    = @($known.Tools | Where-Object { $LiveTools -notcontains $_ })
        CountDelta = ($LiveTools.Count - $known.Tools.Count)
    }
}

function Get-SkillFrontmatter {
    <#
    .SYNOPSIS
        Parses a SKILL.md's --- delimited frontmatter.
    .DESCRIPTION
        A minimal reader for 'key: value' and 'key:' followed by '  - item'.
        No YAML dependency: PowerShell 5.1 ships none, and adding one to read
        four keys is not justified.

        It THROWS on anything it cannot parse. Returning an empty hashtable
        would make every downstream check vacuously true.
    .PARAMETER Text
        The file's full content.
    .EXAMPLE
        Get-SkillFrontmatter -Text (Get-Content $p -Raw)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $lines = $Text -split "`r?`n"
    if ($lines.Count -eq 0 -or $lines[0].Trim() -ne '---') {
        throw 'Skill has no frontmatter block; the first line must be ---.'
    }
    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') { $end = $i; break }
    }
    if ($end -lt 0) { throw 'Skill has an unterminated frontmatter block.' }

    $fm = @{}
    $currentKey = ''
    for ($i = 1; $i -lt $end; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*$') { continue }
        if ($line -match '^\s+-\s*(.+?)\s*$') {
            if (-not $currentKey) {
                throw "Frontmatter list item on line $($i + 1) has no key above it."
            }
            $fm[$currentKey] = @($fm[$currentKey]) + $Matches[1]
            continue
        }
        if ($line -match '^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$') {
            $currentKey = $Matches[1]
            $value = $Matches[2].Trim()
            if ($value) { $fm[$currentKey] = $value } else { $fm[$currentKey] = @() }
            continue
        }
        throw "Frontmatter line $($i + 1) could not be parsed: '$line'."
    }
    return $fm
}

function Get-SkillToolReference {
    <#
    .SYNOPSIS
        Extracts MCP tool references from parsed frontmatter.
    .DESCRIPTION
        Reads allowed-tools, which is Claude Code's real permission mechanism -
        so the declaration both feeds this gate and restricts the skill at
        runtime. A declaration that also grants access cannot drift from what
        the skill can actually do.

        Server names contain hyphens (mcp-windbg, x64dbg-x64), so the split is
        on the literal '__' separator, not on a character class.
    .PARAMETER Frontmatter
        From Get-SkillFrontmatter.
    .EXAMPLE
        Get-SkillToolReference -Frontmatter $fm
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Frontmatter)

    if (-not $Frontmatter.ContainsKey('allowed-tools')) { return @() }

    $refs = @()
    foreach ($entry in @($Frontmatter['allowed-tools'])) {
        if ("$entry" -notlike 'mcp__*') { continue }
        $parts = "$entry".Substring(5) -split '__', 2
        if ($parts.Count -ne 2 -or -not $parts[0] -or -not $parts[1]) {
            throw ("Malformed MCP tool reference '$entry'. Expected " +
                'mcp__<server>__<tool>.')
        }
        $refs += [PSCustomObject]@{ Server = $parts[0]; Tool = $parts[1] }
    }
    return $refs
}

Export-ModuleMember -Function New-SkillResult, Get-SkillScanRule, Test-SkillContent, `
    Select-UnwaivedFinding, Get-ToolCatalog, Get-CatalogServerTool, `
    Compare-ToolCatalog, Get-SkillFrontmatter, Get-SkillToolReference
