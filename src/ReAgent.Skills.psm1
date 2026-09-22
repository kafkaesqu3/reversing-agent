Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ReAgent.CodexWorkspace.psm1')

# Depends on functions exported by sibling modules, which Install-REAgent.ps1
# imports into the session before this one: Write-ReAgentLog,
# Write-FileIfChanged, Assert-FileHash (Common).

$Script:ValidSkillStatus = @('installed', 'skipped', 'not-installed', 'failed')

function Get-SkillEntry {
    <#
    .SYNOPSIS
        Every skill a pack declares, enabled or not, with the reason it is off.
    .DESCRIPTION
        SkillNames carries only the skills a run actually installed, which is
        what the orphan sweep needs and nothing else. Design spec section 1.3.5
        asks the manifest to record every pack and skill "including which
        shipped disabled and why", and a disabledReason otherwise lives only in
        re-agent.config.json, where nothing reading the manifest can reach it.

        Built from the pack's config entry rather than from the install result,
        so it is recorded for a pack that refused at the human review gate and
        installed nothing - which is every pack in the shipped state.
    .PARAMETER Pack
        The pack's config entry.
    .OUTPUTS
        [array] {Name; Enabled; DisabledReason} per declared skill.
    .EXAMPLE
        Get-SkillEntry -Pack $pack
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Pack)

    if ($Pack.PSObject.Properties.Name -notcontains 'skills') { return @() }
    return @($Pack.skills | ForEach-Object {
            $reason = ''
            if ($_.PSObject.Properties.Name -contains 'disabledReason') {
                $reason = [string]$_.disabledReason
            }
            [PSCustomObject]@{ Name = $_.name; Enabled = [bool]$_.enabled
                DisabledReason = $reason
            }
        })
}

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
        The skill directory names this pack installed. SkillEntries, which
        every result carries, lists what the pack declares - installed or not.
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
        CodexSkillNames = @()
        CodexSkillRecords = @()
        PreserveSkillNames = @()
        SkillEntries = @(Get-SkillEntry -Pack $Pack)
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
        Reads allowed-tools. Measured on Claude Code 2.1.263 (see MVP.md, the
        2026-09-07 allowed-tools row): the key is accepted without warning but
        has NO runtime effect. A project skill declaring only Read still drove
        Bash; one declaring Bash was still denied it when the session denied it.
        It neither grants nor restricts, so what it feeds this gate is a
        DECLARATION OF INTENT, not a permission grant. That is still worth
        checking - a tool the body drives but does not declare passes G1
        vacuously - but the runtime fence is session permissions plus the human
        read of the body.

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

function Get-SkillRelativePath {
    <#
    .SYNOPSIS
        The path of a file inside a skill directory, as forward slashes.
    .DESCRIPTION
        A finding that names only 'symbols.md' does not say which of a pack's
        fifteen reference files it came from.
    .PARAMETER Root
        The skill directory the path is relative to.
    .PARAMETER File
        A FileInfo under Root.
    .OUTPUTS
        [string] e.g. 'references/symbols.md'.
    .EXAMPLE
        Get-SkillRelativePath -Root $dir -File $f
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][object]$File
    )

    return $File.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
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

function Test-SkillTreeRename {
    <#
    .SYNOPSIS
        Runs check G2 across every file in a vendored skill except its SKILL.md.
    .DESCRIPTION
        G2 turns "did we finish the rewrite?" into a mechanical assertion over
        text, and the half-adaptation it exists to catch hides in the reference
        files a skill loads at runtime every bit as readily as in SKILL.md - a
        pack can carry six renames and fifteen reference files. SKILL.md itself
        is skipped here because Test-SkillAdaptation already covers it, and one
        finding reported twice trains the reader to skim.
    .PARAMETER Directory
        The vendored skill directory.
    .PARAMETER ToolRenames
        Upstream-to-adapted tool name map, from the pack's adaptation block.
    .OUTPUTS
        [array] {Check='G2'; File; Message} findings, each naming its file.
    .EXAMPLE
        Test-SkillTreeRename -Directory $dir -ToolRenames @{ 'old' = 'New' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][hashtable]$ToolRenames
    )

    $findings = @()
    if ($ToolRenames.Count -eq 0) { return $findings }
    foreach ($f in (Get-ChildItem -LiteralPath $Directory -Recurse -File)) {
        if ($f.Name -eq 'SKILL.md') { continue }
        $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
        if (-not $text) { continue }
        $rel = Get-SkillRelativePath -Root $Directory -File $f
        foreach ($a in (Test-SkillRenameCompletenessCheck -Text $text `
                    -ToolRenames $ToolRenames)) {
            $findings += [PSCustomObject]@{ Check = 'G2'; File = $rel
                Message = "$rel : $($a.Message)"
            }
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

function Get-SkillOwnershipMap {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Packs,
        [ValidateSet('Claude', 'Codex')][string]$Client = 'Claude'
    )

    $markers = @{}
    $prefix = if ($Client -eq 'Codex') { 'codex:' } else { '' }
    foreach ($pack in $Packs) {
        foreach ($skill in $pack.skills) {
            $markers[$skill.name] = "$prefix$($pack.namespace)/$($skill.upstream)"
        }
    }
    return $markers
}

function Test-SkillOwnershipMarker {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Claude', 'Codex')][string]$Client = 'Claude',
        [string]$ExpectedMarker = ''
    )

    if ($ExpectedMarker) {
        return Test-ReAgentOwnershipMarker -Path $Path -Marker $ExpectedMarker
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $prefix = if ($Client -eq 'Codex') { 'codex:' } else { '' }
    $pattern = '\A' + $prefix + '[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*(\r?\n)?\z'
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) -cmatch $pattern
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
    .PARAMETER Client
        Client whose ownership marker syntax applies to this root.
    .PARAMETER ExpectedMarkers
        Exact identities for configured names, including disabled skills.
    .EXAMPLE
        Remove-OrphanedSkill -SkillRoot $r -Wanted @('windbg-crash')
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SkillRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Wanted,
        [ValidateSet('Claude', 'Codex')][string]$Client = 'Claude',
        [hashtable]$ExpectedMarkers = @{}
    )

    if (-not (Test-Path -LiteralPath $SkillRoot)) { return 0 }

    $removed = 0
    foreach ($d in (Get-ChildItem -LiteralPath $SkillRoot -Directory)) {
        if ($d.Name -match '^\.re-agent-(stage|previous)-.+-[a-f0-9]{32}$') { continue }
        if ($Wanted -contains $d.Name) { continue }
        $marker = Join-Path $d.FullName '.re-agent-managed'
        if (-not (Test-SkillOwnershipMarker -Path $marker -Client $Client `
                -ExpectedMarker ([string]$ExpectedMarkers[$d.Name]))) {
            Write-ReAgentLog -Level WARN -Message (
                "Leaving '$($d.Name)' alone: its ownership marker does not match, so it is not " +
                'ours to remove.')
            continue
        }
        if ($PSCmdlet.ShouldProcess($d.FullName, 'Remove orphaned skill')) {
            $safe = Assert-SkillTreePath -Root $SkillRoot -Path $d.FullName
            Assert-SkillCleanupTree -Directory $safe -SkillRoot $SkillRoot
            Remove-Item -LiteralPath $safe -Recurse -Force
            Write-ReAgentLog -Level INFO -Message "Removed orphaned skill '$($d.Name)'."
            $removed++
        }
    }
    return $removed
}

function Remove-PackSkill {
    <#
    .SYNOPSIS
        Removes one pack's own installed skill directories, and nothing else.
    .DESCRIPTION
        Fail-closed cleanup for Install-SkillPack: a newly-detected red flag, or
        a pack the operator switched off, must not leave its skills live on disk
        or the refusal is cosmetic.

        Scoped to the names passed in, never to everything under SkillRoot.
        .claude\skills is shared by every pack, so a whole-root sweep from inside
        one pack's handling deletes the skills a sibling pack installed moments
        earlier in the same run - and because each run reinstalls them and then
        deletes them again, it never converges. Only a directory carrying our
        marker is touched, the same rule Remove-OrphanedSkill enforces, so this
        never reaches into a directory the installer did not create.
    .PARAMETER SkillRoot
        The .claude\skills directory.
    .PARAMETER Names
        This pack's own skill directory names.
    .PARAMETER Reason
        Why they are going, recorded verbatim on the WARN line.
    .PARAMETER ExpectedMarkers
        Exact client and pack ownership markers for every removable name.
    .EXAMPLE
        Remove-PackSkill -SkillRoot $skillRoot -Names $wanted `
            -Reason 'its pack now fails the security scan' -ExpectedMarkers $markers
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SkillRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Names,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][hashtable]$ExpectedMarkers
    )

    foreach ($n in $Names) {
        $d = Join-Path $SkillRoot $n
        if (-not $ExpectedMarkers.ContainsKey($n)) { continue }
        if (-not (Test-SkillOwnershipMarker -Path (Join-Path $d '.re-agent-managed') `
                -ExpectedMarker $ExpectedMarkers[$n])) { continue }
        if ($PSCmdlet.ShouldProcess($d, "Remove skill: $Reason")) {
            $safe = Assert-SkillTreePath -Root $SkillRoot -Path $d
            Assert-SkillCleanupTree -Directory $safe -SkillRoot $SkillRoot
            Remove-Item -LiteralPath $safe -Recurse -Force
            Write-ReAgentLog -Level WARN -Message "Removed '$n': $Reason."
        }
    }
}

function Assert-SkillCleanupTree {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$SkillRoot
    )

    foreach ($item in Get-ChildItem -LiteralPath $Directory -Recurse -Force) {
        $null = Assert-SkillTreePath -Root $SkillRoot -Path $item.FullName
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
        Files are compared and copied as bytes, so scripts and binary assets
        remain identical and a second run preserves LastWriteTimeUtc.
        The marker is written last: it is what lets Remove-OrphanedSkill
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
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$PackRoot,
        [Parameter(Mandatory)][string]$SkillRoot,
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][object]$Skill
    )

    $src = Join-Path $PackRoot $Skill.name
    $dst = Join-Path $SkillRoot $Skill.name

    $null = Assert-SkillTreePath -Root $SkillRoot -Path $dst
    $marker = Join-Path $dst '.re-agent-managed'
    if ((Test-Path -LiteralPath $dst) -and
        -not (Test-ReAgentOwnershipMarker -Path $marker -Marker "$Namespace/$($Skill.upstream)")) {
        throw "Refusing to replace unmanaged skill '$dst'."
    }
    if (-not $PSCmdlet.ShouldProcess($dst, 'Copy reviewed Claude skill bytes')) { return $false }

    $wrote = $false
    foreach ($f in (Get-ChildItem -LiteralPath $src -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($src.Length).TrimStart('\')
        $out = Join-Path $dst $rel
        $null = Assert-SkillTreePath -Root $SkillRoot -Path $out
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        if (Test-Path -LiteralPath $out) {
            $same = [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals(
                [IO.File]::ReadAllBytes($out), $bytes)
            if ($same) { continue }
        }
        $null = New-Item -ItemType Directory -Path (Split-Path $out) -Force
        [IO.File]::WriteAllBytes($out, $bytes)
        $wrote = $true
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
    .PARAMETER CodexSkillRoot
        Codex skill destination parent; defaults to agentRoot/.agents/skills.
    .EXAMPLE
        Install-SkillPack -Pack $p -Config $cfg -RepoRoot $r -Catalog $c
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][object]$Catalog,
        [string]$CodexSkillRoot = ''
    )

    $skillRoot = Join-Path $Config.paths.agentRoot '.claude\skills'
    if (-not $CodexSkillRoot) {
        $CodexSkillRoot = Join-Path $Config.paths.agentRoot '.agents\skills'
    }
    $packRoot = Join-Path $RepoRoot "vendor\skills\$($Pack.namespace)"

    $refusal = Get-SkillPackRefusal -Pack $Pack -SkillRoot $skillRoot -PackRoot $packRoot `
        -CodexSkillRoot $CodexSkillRoot
    if ($refusal) { return $refusal }

    $enabled = @($Pack.skills | Where-Object { $_.enabled })
    $wanted = @($enabled | ForEach-Object { $_.name })
    $gate = Test-SkillPackGate -Pack $Pack -PackRoot $packRoot -Catalog $Catalog
    if ($gate.Findings.Count -gt 0) {
        Remove-PackSkill -SkillRoot $skillRoot -Names $wanted -Confirm:$false `
            -Reason 'its pack now fails the security scan' `
            -ExpectedMarkers (Get-SkillOwnershipMap -Packs @($Pack))
        return New-SkillResult -Pack $Pack -Status 'failed' -Findings $gate.Findings `
            -Reason $gate.Summary
    }

    try {
        $candidates = @($enabled | ForEach-Object {
            New-CodexSkillCandidate -Source (Join-Path $packRoot $_.name) `
                -Destination (Join-Path $CodexSkillRoot $_.name) -Pack $Pack -Skill $_ `
                -Catalog $Catalog -Config $Config
        })
    } catch {
        $failure = New-SkillResult -Pack $Pack -Status 'failed' -Reason $_.Exception.Message
        $failure.PreserveSkillNames = $wanted
        return $failure
    }

    $changes = @()
    $records = @()
    foreach ($skill in $enabled) {
        $changes += Write-SkillPackFile -PackRoot $packRoot -SkillRoot $skillRoot `
            -Namespace $Pack.namespace -Skill $skill -WhatIf:$WhatIfPreference
        $candidate = $candidates | Where-Object { $_.Name -eq $skill.name }
        $record = Install-CodexSkillDirectory -Candidate $candidate -SkillRoot $CodexSkillRoot `
            -WhatIf:$WhatIfPreference -Confirm:$false
        $records += $record
        $changes += $record.Changed
    }

    $status = if ($changes -contains $true) { 'installed' } else { 'skipped' }
    $result = New-SkillResult -Pack $Pack -Status $status -SkillNames $wanted
    $result.CodexSkillNames = $wanted
    $result.CodexSkillRecords = $records
    return $result
}

function Get-SkillPackRefusal {
    <#
    .SYNOPSIS
        The result to report when a pack must not be installed at all, or $null.
    .DESCRIPTION
        The three pre-flight refusals - switched off, never vendored, never
        signed off - are grouped here so Install-SkillPack reads as scan, gate,
        write rather than as a guard cascade with the pipeline buried in it.

        Switching a pack off also takes its skills off disk, including any that
        are individually disabled, because leaving them behind would make
        'enabled: false' mean nothing until the next orphan sweep.
    .PARAMETER Pack
        The pack's config entry.
    .PARAMETER SkillRoot
        The .claude\skills directory.
    .PARAMETER PackRoot
        The pack's vendored tree.
    .PARAMETER CodexSkillRoot
        Optional Codex root whose marked skills are also removed for a disabled pack.
    .OUTPUTS
        A New-SkillResult record, or $null when the pack should be installed.
    .EXAMPLE
        Get-SkillPackRefusal -Pack $p -SkillRoot $skillRoot -PackRoot $packRoot
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][string]$SkillRoot,
        [Parameter(Mandatory)][string]$PackRoot,
        [string]$CodexSkillRoot = ''
    )

    if (-not $Pack.enabled) {
        if ($CodexSkillRoot) {
            Remove-PackSkill -SkillRoot $CodexSkillRoot -Confirm:$false `
                -Names @($Pack.skills | ForEach-Object { $_.name }) `
                -Reason 'its pack is disabled' `
                -ExpectedMarkers (Get-SkillOwnershipMap -Packs @($Pack) -Client Codex)
        }
        Remove-PackSkill -SkillRoot $SkillRoot -Confirm:$false `
            -Names @($Pack.skills | ForEach-Object { $_.name }) `
            -Reason 'its pack is disabled in re-agent.config.json' `
            -ExpectedMarkers (Get-SkillOwnershipMap -Packs @($Pack))
        return New-SkillResult -Pack $Pack -Status 'not-installed' `
            -Reason 'disabled in re-agent.config.json'
    }

    if (-not (Test-Path -LiteralPath $PackRoot)) {
        return New-SkillResult -Pack $Pack -Status 'not-installed' -Reason (
            "not vendored yet; run tools\Update-VendoredSkill.ps1 -Namespace " +
            "$($Pack.namespace)")
    }

    if (-not (Test-SkillPackReviewed -Pack $Pack)) {
        return New-SkillResult -Pack $Pack -Status 'failed' -Reason (
            'human review gate: no sign-off recorded. Read every SKILL.md by hand, then ' +
            "record reviewedBy and reviewedAt under skills[$($Pack.namespace)].review.")
    }

    return $null
}

function Test-SkillPackGate {
    <#
    .SYNOPSIS
        Runs the scanner and the adaptation gate over a vendored pack.
    .DESCRIPTION
        The red-flag scan covers every skill the pack declares, per design spec
        section 1.3.2. Only an enabled skill can block the pack: a disabled one
        is never written to disk, so a finding in it warns instead - see
        Write-DisabledSkillScanWarning. The adaptation gate stays on the enabled
        skills, which are the only ones an agent can load.
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
    foreach ($skill in $Pack.skills) {
        $dir = Join-Path $PackRoot $skill.name
        if (-not $skill.enabled) {
            Write-DisabledSkillScanWarning -Namespace $Pack.namespace -Skill $skill `
                -Directory $dir -Rules $rules -Exceptions @($Pack.scanExceptions)
            continue
        }
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'SKILL.md'))) {
            $findings += [PSCustomObject]@{ RuleId = 'missing-skill'; Severity = 'block'
                File = $skill.name; Line = 0
                Text = ("Declared skill '$($skill.name)' has no SKILL.md in the " +
                    'vendored tree.') }
            continue
        }
        $findings += Get-SkillGateFinding -Skill $skill -Directory $dir -Rules $rules `
            -Exceptions @($Pack.scanExceptions) -Catalog $Catalog `
            -TargetServers @($Pack.targetServers) -ToolRenames $renames
    }

    $summary = if ($findings.Count -gt 0) {
        "$($findings.Count) blocking finding(s): " +
        (@($findings | ForEach-Object { $_.RuleId } | Select-Object -Unique) -join ', ')
    } else { '' }
    return @{ Findings = $findings; Summary = $summary }
}

function Get-SkillScanFinding {
    <#
    .SYNOPSIS
        Runs the red-flag scan over every file in one vendored skill directory.
    .DESCRIPTION
        The scan half of the gate, separated from the adaptation half so it can
        also run over a skill that ships disabled. Design spec section 1.3.2
        requires every vendored file to pass the scan on every install run, and
        a disabled skill is still a file a maintainer edits and a reviewer signs
        off - Update-VendoredSkill.ps1 scans the whole tree, but at vendor time
        over the pristine import, before the adaptation commit.

        Findings come back at their declared severity. The caller decides what
        blocks: an enabled skill fails its pack, a disabled one warns.
    .PARAMETER Skill
        One entry from $Pack.skills, carrying .upstream and .name.
    .PARAMETER Directory
        The skill's vendored directory.
    .PARAMETER Rules
        Rules from Get-SkillScanRule.
    .PARAMETER Exceptions
        The pack's scanExceptions entries.
    .OUTPUTS
        [array] Unwaived scanner findings, empty when the skill is clean.
    .EXAMPLE
        Get-SkillScanFinding -Skill $s -Directory $d -Rules $r -Exceptions @()
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Skill,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][array]$Rules,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Exceptions
    )

    $findings = @()
    foreach ($f in (Get-ChildItem -LiteralPath $Directory -Recurse -File)) {
        $rel = Get-SkillRelativePath -Root $Directory -File $f
        $raw = @(Test-SkillContent -Text (
                Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8) `
                -Rules $Rules -File "$($Skill.name)/$rel")
        $findings += @(Select-UnwaivedFinding -Findings $raw -Exceptions $Exceptions `
                -Skill $Skill.upstream)
    }
    return $findings
}

function Write-DisabledSkillScanWarning {
    <#
    .SYNOPSIS
        Scans a skill that ships disabled and logs anything it finds as a warning.
    .DESCRIPTION
        A disabled skill is never written to .claude\skills, so a finding in one
        must not fail its pack - that would take working skills off the host over
        a file no agent can reach. But it must not be invisible either: the only
        other scan of these files runs in Update-VendoredSkill.ps1, over the
        pristine upstream import, before the adaptation commit. A red flag
        introduced BY an adaptation edit into a disabled skill was caught by
        nothing at all.

        A declared skill with no vendored directory warns rather than throwing:
        it cannot be scanned and cannot be installed, and the enabled path
        already reports that case as a blocking missing-skill finding.
    .PARAMETER Namespace
        The pack's namespace, for the log line.
    .PARAMETER Skill
        One entry from $Pack.skills, carrying .upstream and .name.
    .PARAMETER Directory
        The skill's vendored directory.
    .PARAMETER Rules
        Rules from Get-SkillScanRule.
    .PARAMETER Exceptions
        The pack's scanExceptions entries.
    .EXAMPLE
        Write-DisabledSkillScanWarning -Namespace 'reva' -Skill $s -Directory $d `
            -Rules $r -Exceptions @()
    #>
    [CmdletBinding()]
    # Logs and returns nothing; it changes no state a ShouldProcess prompt could guard.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][object]$Skill,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][array]$Rules,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Exceptions
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        Write-ReAgentLog -Level WARN -Message (
            "Disabled skill '$($Skill.name)' in pack '$Namespace' has no vendored " +
            'directory, so nothing was scanned. Vendor it, or drop it from the config.')
        return
    }
    $findings = @(Get-SkillScanFinding -Skill $Skill -Directory $Directory -Rules $Rules `
            -Exceptions $Exceptions) | Where-Object { $_.Severity -eq 'block' }
    foreach ($f in $findings) {
        Write-ReAgentLog -Level WARN -Message (
            "Scan rule '$($f.RuleId)' fired in disabled skill '$($f.File)' of pack " +
            "'$Namespace', line $($f.Line). It is not installed, so the pack is not " +
            'blocked - fix it before enabling the skill.')
    }
}

function Get-SkillGateFinding {
    <#
    .SYNOPSIS
        Scans and gates one vendored skill, in scanner finding shape.
    .DESCRIPTION
        Split out of Test-SkillPackGate so that function stays a thin loop over
        the pack's skills. The red-flag scan and the adaptation gate both emit
        the same {RuleId, Severity, File, Line, Text} record: a caller deciding
        whether to install does not care which control refused, only that one
        did.
    .PARAMETER Skill
        One entry from $Pack.skills, carrying .upstream and .name.
    .PARAMETER Directory
        The skill's vendored directory.
    .PARAMETER Rules
        Rules from Get-SkillScanRule.
    .PARAMETER Exceptions
        The pack's scanExceptions entries.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER TargetServers
        Servers the pack declares it drives.
    .PARAMETER ToolRenames
        Upstream-to-adapted tool name map, from the pack's adaptation block.
    .OUTPUTS
        [array] Blocking findings, empty when the skill is clean.
    .EXAMPLE
        Get-SkillGateFinding -Skill $s -Directory $d -Rules $r -Exceptions @() `
            -Catalog $c -TargetServers @('mcp-windbg') -ToolRenames @{}
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Skill,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][array]$Rules,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Exceptions,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$TargetServers,
        [Parameter(Mandatory)][hashtable]$ToolRenames
    )

    $findings = @(Get-SkillScanFinding -Skill $Skill -Directory $Directory -Rules $Rules `
            -Exceptions $Exceptions) | Where-Object { $_.Severity -eq 'block' }

    $md = Join-Path $Directory 'SKILL.md'
    $mdText = Get-Content -LiteralPath $md -Raw -Encoding UTF8
    foreach ($a in @(Test-SkillAdaptation -Text $mdText `
                -DirectoryName $Skill.name -Catalog $Catalog `
                -TargetServers $TargetServers -ToolRenames $ToolRenames)) {
        $findings += [PSCustomObject]@{ RuleId = $a.Check; Severity = 'block'
            File = "$($Skill.name)/SKILL.md"; Line = 0; Text = $a.Message }
    }
    foreach ($a in @(Test-SkillTreeRename -Directory $Directory `
                -ToolRenames $ToolRenames)) {
        $findings += [PSCustomObject]@{ RuleId = $a.Check; Severity = 'block'
            File = "$($Skill.name)/$($a.File)"; Line = 0; Text = $a.Message }
    }
    return $findings
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
    .PARAMETER CodexSkillRoot
        Codex skill destination parent; defaults to agentRoot/.agents/skills.
    .EXAMPLE
        Install-AllSkill -Config $cfg -RepoRoot $PSScriptRoot
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$CodexSkillRoot = ''
    )

    if ($Config.PSObject.Properties.Name -notcontains 'skills') { return @() }
    if (-not $CodexSkillRoot) {
        $CodexSkillRoot = Join-Path $Config.paths.agentRoot '.agents\skills'
    }

    $catalog = Get-ToolCatalog
    $results = @()
    foreach ($pack in $Config.skills) {
        try {
            $results += Install-SkillPack -Pack $pack -Config $Config -RepoRoot $RepoRoot `
                -Catalog $catalog -CodexSkillRoot $CodexSkillRoot -Confirm:$false `
                -WhatIf:$WhatIfPreference
        } catch {
            $failure = New-SkillResult -Pack $pack -Status 'failed' `
                -Reason $_.Exception.Message
            $failure.PreserveSkillNames = @($pack.skills | Where-Object enabled |
                ForEach-Object { $_.name })
            $results += $failure
        }
    }

    $wanted = @($results | Where-Object { $_.Installed } |
            ForEach-Object { $_.SkillNames } | Where-Object { $_ })
    $preserved = @($results | ForEach-Object { $_.PreserveSkillNames } | Where-Object { $_ })
    $null = Remove-OrphanedSkill -SkillRoot (
        Join-Path $Config.paths.agentRoot '.claude\skills') -Wanted @($wanted + $preserved) `
        -Confirm:$false -WhatIf:$WhatIfPreference `
        -ExpectedMarkers (Get-SkillOwnershipMap -Packs @($Config.skills))
    $codexWanted = @($Config.skills | Where-Object enabled | ForEach-Object { $_.skills } |
        Where-Object enabled | ForEach-Object { $_.name })
    $null = Remove-OrphanedSkill -SkillRoot $CodexSkillRoot -Wanted $codexWanted `
        -Confirm:$false -WhatIf:$WhatIfPreference -Client Codex `
        -ExpectedMarkers (Get-SkillOwnershipMap -Packs @($Config.skills) -Client Codex)

    foreach ($r in $results) {
        $level = if ($r.Status -eq 'failed') { 'ERROR' }
        elseif ($r.Installed) { 'INFO' } else { 'WARN' }
        Write-ReAgentLog -Level $level -Message "[$($r.Status)] skill pack $($r.Namespace)"
    }
    return $results
}

Export-ModuleMember -Function New-SkillResult, Get-SkillEntry, Get-SkillScanRule, `
    Get-SkillScanFinding, Write-DisabledSkillScanWarning, `
    Test-SkillContent, `
    Select-UnwaivedFinding, Get-ToolCatalog, Get-CatalogServerTool, `
    Compare-ToolCatalog, Find-FrontmatterEnd, ConvertFrom-FrontmatterLine, `
    Get-SkillFrontmatter, Get-SkillToolReference, Get-SkillRelativePath, `
    Test-SkillNameCheck, Test-SkillCatalogCheck, Test-SkillToolExistenceCheck, `
    Test-SkillRenameCompletenessCheck, Test-SkillTreeRename, Test-SkillAdaptation, `
    Remove-OrphanedSkill, Remove-PackSkill, Test-SkillPackReviewed, `
    Write-SkillPackFile, Get-SkillPackRefusal, Install-SkillPack, `
    Get-SkillGateFinding, Test-SkillPackGate, Install-AllSkill
