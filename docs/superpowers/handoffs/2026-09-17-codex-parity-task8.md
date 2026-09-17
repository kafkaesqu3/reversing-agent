# Codex parity handoff — Task 8 complete

## Stop point

Branch `codex-workspace-execution` is at commit `da06ec4` (`Document Codex workspace parity acceptance`).
Tasks 8 and 9 of `docs/superpowers/plans/2026-09-14-codex-parity.md` are complete. Task 10 is incomplete because its automated and attended acceptance gates did not pass.

## Task 9

- `New-CodexAcceptanceObservation` validates L0-L5 attended records and includes an observation timestamp.
- Any non-empty attended report must contain one evidential `pass` or `fail` record for every L0-L5 ID.
- README and MVP operator documents now cover project trust, `codex --strict-config -C C:\re\agent`, the eleven skills, two enabled specialists, SSE limitation, complete-transport rule, secret boundary, and the L0-L5 checklist.
- Fresh focused verification on 2026-09-17: `ReAgent.CodexVerify.Tests.ps1` (56 passed) plus `Integration.Tests.ps1` (45 passed); analyzer for `src/ReAgent.CodexVerify.psm1` reported 0 findings.

## Task 10 measurements and blockers

- Full suite with the only available compatible-newer runner, Pester 6.1.0: 778 total, 755 passed, 23 failed. Failures are concentrated in older cross-module fixtures (including Pester's escaped `break`/`continue` behavior); Pester 5.x is not installed. Do not record a passing suite from this run.
- Whole-repository PSScriptAnalyzer reported 14 warnings, all in pre-existing test helpers. Do not record zero whole-repository findings.
- Live `Install-REAgent.ps1 -VerifyOnly` initially failed as expected because `C:\re\agent` lacked all Codex project artifacts. The elevated first reconciliation generated those artifacts; its live C0-C8 checks all passed.
- The first and second live reconciliations both exited 1 because `claude mcp list` and the `mcp-windbg` live call failed. GUI host probes were not-testable.
- The second reconciliation skipped all eleven skills and retained C0-C8 pass, but created another `Binary Ninja\settings.json` backup. `Merge-JsonFile` always writes the settings file even when values are unchanged, so Task 10's no-new-backup idempotency requirement is currently not met.
- L0-L5 remain unobserved. They require a human-operated Codex session with Binary Ninja open and its MCP server started, x64dbg open on an x64 target, and x32dbg closed.

## What changed

- `src/ReAgent.Manifest.psm1` serializes and replays the optional, token-free `codexWorkspace` manifest record.
- `install-codex.ps1` reconciles standalone Codex workspace artifacts in `-ConfigureOnly` and keeps `-VerifyOnly` read-only while running registration plus C0–C8.
- The corresponding manifest and standalone integration coverage is in `tests/ReAgent.Manifest.Tests.ps1` and `tests/Integration.Tests.ps1`.

## Fresh verification

Run on 2026-09-17 from this worktree:

```powershell
Invoke-Pester -Path tests/ReAgent.Manifest.Tests.ps1,tests/Integration.Tests.ps1 -Output Detailed
```

Result: 78 passed, 0 failed, 0 skipped (243.47 seconds).

```powershell
$findings = @()
$findings += Invoke-ScriptAnalyzer -Path src/ReAgent.Manifest.psm1 -Settings PSScriptAnalyzerSettings.psd1
$findings += Invoke-ScriptAnalyzer -Path install-codex.ps1 -Settings PSScriptAnalyzerSettings.psd1
if ($findings.Count -gt 0) { throw "$($findings.Count) analyzer finding(s)." }
```

Result: 0 findings. `git diff --check` also returned clean.

## Recovery note

Before Task 8, the worktree contained a partial reverse-application of committed Codex-parity changes. It was saved safely as:

```text
stash@{0}: recovery/pre-task8-reverse-working-tree-2026-09-17
```

The worktree was then restored to `afef8f1`, so the branch and working tree now reflect the committed history. Leave this stash intact unless its contents are deliberately needed for forensic comparison.

## Next task

Resume at Task 9, “Update operator documentation and acceptance recording.” Read its complete task block in the plan before editing. The attended L0–L5 acceptance work and the full-suite/live-install measurement in Task 10 remain unfinished.

## Next work

To complete Task 10: use a Pester 5.x runner or repair the cross-module test compatibility; eliminate unconditional Binary Ninja settings rewrites/backups; restore the two failed live checks; then conduct the human-attended L0-L5 session and update MVP/HANDOFF with the actual successful measurements.

## Process note

The independent Task 8 reviewer could not start because the available review agent hit an account usage limit. The controller performed a scoped diff review instead, followed by the fresh Pester/analyzer verification above.
