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

function Find-FrontmatterEnd {
    <#
    .SYNOPSIS
        Finds the index of the closing --- fence in a frontmatter block.
    .PARAMETER Lines
        The full text split into lines; searched starting at index 1.
    .OUTPUTS
        [int] The index of the closing fence, or -1 if none found.
    .EXAMPLE
        Find-FrontmatterEnd -Lines $lines
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Lines)

    for ($i = 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -eq '---') { return $i }
    }
    return -1
}

function ConvertFrom-FrontmatterLine {
    <#
    .SYNOPSIS
        Parses one frontmatter line into the accumulator hashtable.
    .DESCRIPTION
        Mutates Fm in place (hashtables are reference types). Returns the
        current key, which may be unchanged (blank line, list item) or
        newly set (a key: value line), so the caller's loop can track it
        across iterations.
    .PARAMETER Fm
        The accumulator hashtable, mutated in place.
    .PARAMETER CurrentKey
        The key most recently seen, for list items that continue it.
    .PARAMETER LineNumber
        1-based line number, for error messages.
    .PARAMETER Line
        The raw line text.
    .OUTPUTS
        [string] The current key after processing this line.
    .EXAMPLE
        $currentKey = ConvertFrom-FrontmatterLine -Fm $fm -CurrentKey $currentKey `
            -LineNumber ($i + 1) -Line $lines[$i]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Fm,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentKey,
        [Parameter(Mandatory)][int]$LineNumber,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line
    )

    if ($Line -match '^\s*$') { return $CurrentKey }
    if ($Line -match '^\s+-\s*(.+?)\s*$') {
        if (-not $CurrentKey) {
            throw "Frontmatter list item on line $LineNumber has no key above it."
        }
        $Fm[$CurrentKey] = @($Fm[$CurrentKey]) + $Matches[1]
        return $CurrentKey
    }
    if ($Line -match '^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$') {
        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if ($value) { $Fm[$key] = $value } else { $Fm[$key] = @() }
        return $key
    }
    throw "Frontmatter line $LineNumber could not be parsed: '$Line'."
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
    $end = Find-FrontmatterEnd -Lines $lines
    if ($end -lt 0) { throw 'Skill has an unterminated frontmatter block.' }

    $fm = @{}
    $currentKey = ''
    for ($i = 1; $i -lt $end; $i++) {
        $currentKey = ConvertFrom-FrontmatterLine -Fm $fm -CurrentKey $currentKey `
            -LineNumber ($i + 1) -Line $lines[$i]
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

function Test-SkillNameCheck {
    <#
    .SYNOPSIS
        Runs check G0: the frontmatter name must match the install directory.
    .DESCRIPTION
        Claude Code keys a skill's identity off its directory name, not its
        frontmatter. A mismatch here means the skill will not load at all, so
        this is checked ahead of anything about the tools it declares.
    .PARAMETER Frontmatter
        From Get-SkillFrontmatter.
    .PARAMETER DirectoryName
        The directory the skill will be installed into.
    .OUTPUTS
        [array] Zero or one {Check='G0'; Message} findings.
    .EXAMPLE
        Test-SkillNameCheck -Frontmatter $fm -DirectoryName 'windbg-crash'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Frontmatter,
        [Parameter(Mandatory)][string]$DirectoryName
    )

    $findings = @()
    if ("$($Frontmatter['name'])" -ne $DirectoryName) {
        $findings += [PSCustomObject]@{ Check = 'G0'; Message = (
                "Frontmatter name '$($Frontmatter['name'])' does not match directory " +
                "'$DirectoryName'. Claude Code will not load this skill.") }
    }
    return $findings
}

function Test-SkillCatalogCheck {
    <#
    .SYNOPSIS
        Runs check CATALOG: every target server must have a catalog entry.
    .DESCRIPTION
        A skill targeting a server the catalog has never measured cannot be
        checked by G1 at all, so that gap is reported on its own rather than
        silently skipped.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER TargetServers
        Servers this pack declares it drives.
    .OUTPUTS
        [array] One {Check='CATALOG'; Message} finding per unknown server.
    .EXAMPLE
        Test-SkillCatalogCheck -Catalog $c -TargetServers @('pyghidra-mcp')
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$TargetServers
    )

    $findings = @()
    foreach ($server in $TargetServers) {
        $entry = Get-CatalogServerTool -Catalog $Catalog -Server $server
        if (-not $entry.Known) {
            $findings += [PSCustomObject]@{ Check = 'CATALOG'; Message = (
                    "No tool catalog entry for '$server'. Skills targeting it cannot be " +
                    'checked. Open the application, start its MCP server, then run: ' +
                    '.\Install-REAgent.ps1 -Attended -UpdateToolCatalog') }
        }
    }
    return $findings
}

function Test-SkillToolExistenceCheck {
    <#
    .SYNOPSIS
        Runs check G1: every declared tool must exist on its server.
    .DESCRIPTION
        Skips references to a server with no catalog entry, since
        Test-SkillCatalogCheck already flags that gap and a second finding
        here would be redundant noise.
    .PARAMETER ToolReferences
        From Get-SkillToolReference.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .OUTPUTS
        [array] One {Check='G1'; Message} finding per tool the server does not advertise.
    .EXAMPLE
        Test-SkillToolExistenceCheck -ToolReferences $refs -Catalog $c
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ToolReferences,
        [Parameter(Mandatory)][object]$Catalog
    )

    $findings = @()
    foreach ($ref in $ToolReferences) {
        $entry = Get-CatalogServerTool -Catalog $Catalog -Server $ref.Server
        if (-not $entry.Known) { continue }
        if ($entry.Tools -notcontains $ref.Tool) {
            $findings += [PSCustomObject]@{ Check = 'G1'; Message = (
                    "Declares tool '$($ref.Tool)', which '$($ref.Server)' does not " +
                    "advertise. Advertised: [$($entry.Tools -join ', ')]. The adaptation " +
                    'is wrong or upstream drifted.') }
        }
    }
    return $findings
}

function Test-SkillRenameCompletenessCheck {
    <#
    .SYNOPSIS
        Runs check G2: no upstream tool name may survive in the skill's body.
    .DESCRIPTION
        Asserts over the file's whole text, not just frontmatter. That is
        what catches the half-adaptation where allowed-tools was renamed but
        the prose still names the old API.
    .PARAMETER Text
        The skill file's content.
    .PARAMETER ToolRenames
        Upstream-to-adapted tool name map, from the pack's adaptation block.
    .OUTPUTS
        [array] One {Check='G2'; Message} finding per upstream name still present.
    .EXAMPLE
        Test-SkillRenameCompletenessCheck -Text $md -ToolRenames @{ 'old' = 'New' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][hashtable]$ToolRenames
    )

    $findings = @()
    foreach ($old in $ToolRenames.Keys) {
        if ($Text -like "*$old*") {
            $findings += [PSCustomObject]@{ Check = 'G2'; Message = (
                    "Upstream name '$old' still appears in the body. The adaptation is " +
                    "incomplete; it should now read '$($ToolRenames[$old])'.") }
        }
    }
    return $findings
}

function Test-SkillAdaptation {
    <#
    .SYNOPSIS
        Runs the static adaptation checks G0, CATALOG, G1 and G2 over one skill.
    .DESCRIPTION
        None of these needs a running server: they read the vendored file and
        the checked-in catalog. That is what lets the gate run on every
        installer run rather than only when a GUI happens to be open.

        A skill declaring no MCP tools passes. It is correctly adapted by
        definition, and a not-testable here would be noise.
    .PARAMETER Text
        The skill file's content.
    .PARAMETER DirectoryName
        The directory the skill will be installed into.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER TargetServers
        Servers this pack declares it drives.
    .PARAMETER ToolRenames
        Upstream-to-adapted tool name map, from the pack's adaptation block.
    .OUTPUTS
        [array] Combined {Check; Message} findings from all four checks.
    .EXAMPLE
        Test-SkillAdaptation -Text $md -DirectoryName 'windbg-crash' -Catalog $c `
            -TargetServers @('mcp-windbg') -ToolRenames @{}
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$DirectoryName,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$TargetServers,
        [Parameter(Mandatory)][hashtable]$ToolRenames
    )

    $fm = Get-SkillFrontmatter -Text $Text
    $refs = @(Get-SkillToolReference -Frontmatter $fm)

    $findings = @()
    $findings += Test-SkillNameCheck -Frontmatter $fm -DirectoryName $DirectoryName
    $findings += Test-SkillCatalogCheck -Catalog $Catalog -TargetServers $TargetServers
    $findings += Test-SkillToolExistenceCheck -ToolReferences $refs -Catalog $Catalog
    $findings += Test-SkillRenameCompletenessCheck -Text $Text -ToolRenames $ToolRenames
    return $findings
}

function Remove-OrphanedSkill {
    <#
    .SYNOPSIS
        Removes managed skill directories that are no longer wanted.
    .DESCRIPTION
        Only touches directories carrying our marker file. An operator's own
        skill directory is never ours to delete - the installer must never
        destroy something it did not create.
    .PARAMETER SkillRoot
        The .claude\skills directory.
    .PARAMETER Wanted
        Skill directory names that should survive.
    .EXAMPLE
        Remove-OrphanedSkill -SkillRoot $r -Wanted @('windbg-crash')
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SkillRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Wanted
    )

    if (-not (Test-Path -LiteralPath $SkillRoot)) { return 0 }

    $removed = 0
    foreach ($d in (Get-ChildItem -LiteralPath $SkillRoot -Directory)) {
        if ($Wanted -contains $d.Name) { continue }
        $marker = Join-Path $d.FullName '.re-agent-managed'
        if (-not (Test-Path -LiteralPath $marker)) {
            Write-ReAgentLog -Level WARN -Message (
                "Leaving '$($d.Name)' alone: it carries no re-agent marker, so it is not " +
                'ours to remove.')
            continue
        }
        if ($PSCmdlet.ShouldProcess($d.FullName, 'Remove orphaned skill')) {
            Remove-Item -LiteralPath $d.FullName -Recurse -Force
            Write-ReAgentLog -Level INFO -Message "Removed orphaned skill '$($d.Name)'."
            $removed++
        }
    }
    return $removed
}

function Remove-FailedPackSkill {
    <#
    .SYNOPSIS
        Removes any installed copy of a skill whose pack now fails the gate.
    .DESCRIPTION
        Fail-closed cleanup for Install-SkillPack: a newly-detected red flag
        must not leave the bad skill live on disk, or the failing check is
        cosmetic. Only a directory carrying our marker is touched - the same
        rule Remove-OrphanedSkill enforces - so this never reaches into a
        directory the installer did not create.
    .PARAMETER SkillRoot
        The .claude\skills directory.
    .PARAMETER Wanted
        The pack's enabled skill directory names.
    .EXAMPLE
        Remove-FailedPackSkill -SkillRoot $skillRoot -Wanted $wanted
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SkillRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Wanted
    )

    foreach ($n in $Wanted) {
        $d = Join-Path $SkillRoot $n
        if (-not (Test-Path -LiteralPath (Join-Path $d '.re-agent-managed'))) { continue }
        if ($PSCmdlet.ShouldProcess($d, 'Remove skill that now fails the security scan')) {
            Remove-Item -LiteralPath $d -Recurse -Force
            Write-ReAgentLog -Level WARN -Message (
                "Removed '$n': its pack now fails the security scan.")
        }
    }
}

function Test-SkillPackReviewed {
    <#
    .SYNOPSIS
        Reports whether a pack's human review sign-off has been recorded.
    .DESCRIPTION
        A treeSha256 pin proves the vendored bytes did not change underneath
        the operator; it says nothing about whether a human ever read them.
        Both reviewedBy and reviewedAt must be present, or the pack is not
        considered reviewed.
    .PARAMETER Pack
        The pack's config entry.
    .OUTPUTS
        [bool] True when both review fields are recorded.
    .EXAMPLE
        Test-SkillPackReviewed -Pack $pack
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Pack)

    return -not ([string]::IsNullOrWhiteSpace($Pack.review.reviewedBy) -or
        [string]::IsNullOrWhiteSpace($Pack.review.reviewedAt))
}

function Write-SkillPackFile {
    <#
    .SYNOPSIS
        Copies one skill's files into place and writes its management marker.
    .DESCRIPTION
        Every file is routed through Write-FileIfChanged, so a second
        identical run touches nothing on disk and LastWriteTimeUtc holds
        still. The marker is written last: it is what lets Remove-OrphanedSkill
        later tell an installed skill apart from an operator's own
        hand-written directory.
    .PARAMETER PackRoot
        The vendored pack's root, holding one directory per upstream skill.
    .PARAMETER SkillRoot
        The .claude\skills directory skills are installed into.
    .PARAMETER Namespace
        The pack's namespace, recorded in the marker.
    .PARAMETER Skill
        One entry from $Pack.skills, carrying .upstream and .name.
    .OUTPUTS
        [bool] True when any file or the marker was actually written.
    .EXAMPLE
        Write-SkillPackFile -PackRoot $packRoot -SkillRoot $skillRoot `
            -Namespace 'windbg' -Skill $skill
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackRoot,
        [Parameter(Mandatory)][string]$SkillRoot,
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][object]$Skill
    )

    $src = Join-Path $PackRoot $Skill.name
    $dst = Join-Path $SkillRoot $Skill.name

    $wrote = $false
    foreach ($f in (Get-ChildItem -LiteralPath $src -Recurse -File)) {
        $rel = $f.FullName.Substring($src.Length).TrimStart('\')
        $out = Join-Path $dst $rel
        if (Write-FileIfChanged -Path $out -Text (Get-Content -LiteralPath $f.FullName -Raw)) {
            $wrote = $true
        }
    }
    $marker = Join-Path $dst '.re-agent-managed'
    if (Write-FileIfChanged -Path $marker -Text "$Namespace/$($Skill.upstream)") {
        $wrote = $true
    }
    return $wrote
}

function Install-SkillPack {
    <#
    .SYNOPSIS
        Scans, gates and installs one vendored skill pack.
    .DESCRIPTION
        Fail-closed: the scan and the adaptation gate run BEFORE any write, and
        a pack that trips a block rule has any previously-installed copy
        removed. A newly-detected red flag must not leave the bad skill live.
    .PARAMETER Pack
        The pack's config entry.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER RepoRoot
        Repository root holding vendor\skills.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .EXAMPLE
        Install-SkillPack -Pack $p -Config $cfg -RepoRoot $r -Catalog $c
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][object]$Catalog
    )

    $skillRoot = Join-Path $Config.paths.agentRoot '.claude\skills'
    $wanted = @($Pack.skills | Where-Object { $_.enabled } | ForEach-Object { $_.name })

    if (-not $Pack.enabled) {
        $null = Remove-OrphanedSkill -SkillRoot $skillRoot -Wanted @() -Confirm:$false
        return New-SkillResult -Pack $Pack -Status 'not-installed' `
            -Reason 'disabled in re-agent.config.json'
    }

    $packRoot = Join-Path $RepoRoot "vendor\skills\$($Pack.namespace)"
    if (-not (Test-Path -LiteralPath $packRoot)) {
        return New-SkillResult -Pack $Pack -Status 'not-installed' -Reason (
            "not vendored yet; run tools\Update-VendoredSkill.ps1 -Namespace " +
            "$($Pack.namespace)")
    }

    if (-not (Test-SkillPackReviewed -Pack $Pack)) {
        return New-SkillResult -Pack $Pack -Status 'failed' -Reason (
            'human review gate: no sign-off recorded. Read every SKILL.md by hand, then ' +
            "record reviewedBy and reviewedAt under skills[$($Pack.namespace)].review.")
    }

    $gate = Test-SkillPackGate -Pack $Pack -PackRoot $packRoot -Catalog $Catalog
    if ($gate.Findings.Count -gt 0) {
        Remove-FailedPackSkill -SkillRoot $skillRoot -Wanted $wanted -Confirm:$false
        return New-SkillResult -Pack $Pack -Status 'failed' -Findings $gate.Findings `
            -Reason $gate.Summary
    }

    $wrote = $false
    foreach ($skill in ($Pack.skills | Where-Object { $_.enabled })) {
        $wrote = $wrote -or (Write-SkillPackFile -PackRoot $packRoot -SkillRoot $skillRoot `
                -Namespace $Pack.namespace -Skill $skill)
    }

    $status = if ($wrote) { 'installed' } else { 'skipped' }
    return New-SkillResult -Pack $Pack -Status $status -SkillNames $wanted
}

function Test-SkillPackGate {
    <#
    .SYNOPSIS
        Runs the scanner and the adaptation gate over a vendored pack.
    .PARAMETER Pack
        The pack's config entry.
    .PARAMETER PackRoot
        The vendored tree.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .EXAMPLE
        Test-SkillPackGate -Pack $p -PackRoot $r -Catalog $c
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][string]$PackRoot,
        [Parameter(Mandatory)][object]$Catalog
    )

    $rules = Get-SkillScanRule
    $renames = @{}
    if ($Pack.PSObject.Properties.Name -contains 'adaptation') {
        foreach ($p in $Pack.adaptation.toolRenames.PSObject.Properties) {
            $renames[$p.Name] = $p.Value
        }
    }

    $findings = @()
    foreach ($skill in ($Pack.skills | Where-Object { $_.enabled })) {
        $dir = Join-Path $PackRoot $skill.name
        if (-not (Test-Path -LiteralPath $dir)) {
            $findings += [PSCustomObject]@{ RuleId = 'missing-skill'; Severity = 'block'
                File = $skill.name; Line = 0
                Text = "Declared skill '$($skill.name)' is not in the vendored tree." }
            continue
        }
        foreach ($f in (Get-ChildItem -LiteralPath $dir -Recurse -File)) {
            $text = Get-Content -LiteralPath $f.FullName -Raw
            $raw = @(Test-SkillContent -Text $text -Rules $rules -File $f.Name)
            $findings += @(Select-UnwaivedFinding -Findings $raw `
                    -Exceptions @($Pack.scanExceptions) -Skill $skill.upstream) |
                Where-Object { $_.Severity -eq 'block' }
        }
        $md = Join-Path $dir 'SKILL.md'
        foreach ($a in @(Test-SkillAdaptation -Text (Get-Content -LiteralPath $md -Raw) `
                    -DirectoryName $skill.name -Catalog $Catalog `
                    -TargetServers @($Pack.targetServers) -ToolRenames $renames)) {
            $findings += [PSCustomObject]@{ RuleId = $a.Check; Severity = 'block'
                File = "$($skill.upstream)/SKILL.md"; Line = 0; Text = $a.Message }
        }
    }

    $summary = if ($findings.Count -gt 0) {
        "$($findings.Count) blocking finding(s): " +
        (@($findings | ForEach-Object { $_.RuleId } | Select-Object -Unique) -join ', ')
    } else { '' }
    return @{ Findings = $findings; Summary = $summary }
}

function Install-AllSkill {
    <#
    .SYNOPSIS
        Installs every configured skill pack.
    .DESCRIPTION
        Mirrors Install-AllMcpServer: one pack failing does not stop the rest,
        and each outcome becomes a record the manifest carries.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER RepoRoot
        Repository root.
    .EXAMPLE
        Install-AllSkill -Config $cfg -RepoRoot $PSScriptRoot
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    if ($Config.PSObject.Properties.Name -notcontains 'skills') { return @() }

    $catalog = Get-ToolCatalog
    $results = @()
    foreach ($pack in $Config.skills) {
        try {
            $results += Install-SkillPack -Pack $pack -Config $Config -RepoRoot $RepoRoot `
                -Catalog $catalog -Confirm:$false
        } catch {
            $results += New-SkillResult -Pack $pack -Status 'failed' `
                -Reason $_.Exception.Message
        }
    }

    $wanted = @($results | Where-Object { $_.Installed } |
            ForEach-Object { $_.SkillNames } | Where-Object { $_ })
    $null = Remove-OrphanedSkill -SkillRoot (
        Join-Path $Config.paths.agentRoot '.claude\skills') -Wanted $wanted -Confirm:$false

    foreach ($r in $results) {
        $level = if ($r.Status -eq 'failed') { 'ERROR' }
        elseif ($r.Installed) { 'INFO' } else { 'WARN' }
        Write-ReAgentLog -Level $level -Message "[$($r.Status)] skill pack $($r.Namespace)"
    }
    return $results
}

Export-ModuleMember -Function New-SkillResult, Get-SkillScanRule, Test-SkillContent, `
    Select-UnwaivedFinding, Get-ToolCatalog, Get-CatalogServerTool, `
    Compare-ToolCatalog, Find-FrontmatterEnd, ConvertFrom-FrontmatterLine, `
    Get-SkillFrontmatter, Get-SkillToolReference, Test-SkillNameCheck, `
    Test-SkillCatalogCheck, Test-SkillToolExistenceCheck, `
    Test-SkillRenameCompletenessCheck, Test-SkillAdaptation, Remove-OrphanedSkill, `
    Remove-FailedPackSkill, Test-SkillPackReviewed, Write-SkillPackFile, `
    Install-SkillPack, Test-SkillPackGate, Install-AllSkill
