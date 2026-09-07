<#
.SYNOPSIS
    Vendors one upstream skill pack into vendor\skills. Maintainer use only.
.DESCRIPTION
    The only path in this repo that touches the network. Installer runs work
    offline from the vendored tree, because a phase that needs egress after
    seal is a documented top failure mode.

    It deliberately does NOT record treeSha256 into re-agent.config.json. The
    human does that, after reading every SKILL.md. That is the review gate.
.PARAMETER Namespace
    The pack's namespace, as declared in re-agent.config.json.
.PARAMETER ConfigPath
    Configuration file. Defaults to re-agent.config.json beside the repo root.
.EXAMPLE
    .\tools\Update-VendoredSkill.ps1 -Namespace windbg
#>
# Write-Host is deliberate: this is a maintainer-run console tool, and its output -
# the tree hash, scan findings, and the review checklist - is the point of running it.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
param(
    [Parameter(Mandatory)][string]$Namespace,
    [string]$ConfigPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $repoRoot 're-agent.config.json' }

foreach ($m in @('Common', 'Servers', 'Skills')) {
    Import-Module (Join-Path $repoRoot "src\ReAgent.$m.psm1") -Force
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$pack = $config.skills | Where-Object { $_.namespace -eq $Namespace }
if (-not $pack) { throw "No skill pack with namespace '$Namespace' in $ConfigPath." }

$zip = Get-VerifiedGitHubArchive -Pack $pack -CacheRoot (Join-Path $repoRoot '.vendor-cache')
$dirs = Expand-SkillPack -ArchivePath $zip -SubPath $pack.source.subPath
$staging = $dirs[0].Parent.FullName

$actual = Get-TreeHash -Root $staging
Assert-FileHash -Actual $actual -Expected $pack.source.treeSha256 `
    -Label "$Namespace upstream tree" `
    -RecordHint "skills[$Namespace].source.treeSha256"

$rules = Get-SkillScanRule
$findings = @()
foreach ($d in $dirs) {
    foreach ($f in (Get-ChildItem -LiteralPath $d.FullName -Recurse -File)) {
        $findings += @(Test-SkillContent -Text (Get-Content -LiteralPath $f.FullName -Raw) `
                -Rules $rules -File "$($d.Name)/$($f.Name)")
    }
}

$dest = Join-Path $repoRoot "vendor\skills\$Namespace"
if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
$null = New-Item -ItemType Directory -Path $dest -Force
foreach ($d in $dirs) { Copy-Item -LiteralPath $d.FullName -Destination $dest -Recurse }

@{
    repo = $pack.source.repo; commit = $pack.source.commit
    treeSha256 = $actual; importedAt = (Get-Date).ToString('o')
} | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $dest 'PROVENANCE.json')

Write-Host ''
Write-Host "Vendored $Namespace at $($pack.source.commit)"
Write-Host "Tree SHA-256: $actual"
Write-Host ''
if ($findings.Count -gt 0) {
    Write-Host "SCAN FINDINGS ($($findings.Count)):"
    $findings | Format-Table RuleId, File, Line, Text -AutoSize
} else {
    Write-Host 'Scan clean.'
}
Write-Host ''
Write-Host 'REVIEW CHECKLIST - do all of this before recording the sign-off:'
Write-Host '  1. Read every SKILL.md in full. The scanner is a backstop, not the control.'
Write-Host '  2. Confirm the repo is the intended upstream, not a near-identical fork.'
Write-Host '  3. Adapt tool names, frontmatter name, and description in a SECOND commit.'
Write-Host "  4. Record treeSha256, reviewedBy, reviewedAt and reviewedCommit under"
Write-Host "     skills[$Namespace] in re-agent.config.json."
