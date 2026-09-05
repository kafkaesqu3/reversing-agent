<#
.SYNOPSIS
    Wires Claude Code to x64dbg, Ghidra, Binary Ninja, and WinDbg via MCP on an existing FLARE VM.
.DESCRIPTION
    Adopt-and-reconcile: inventories the host, installs only what is missing, and
    generates all agent configuration from re-agent.config.json. Idempotent.

    STUB. Task 6 replaces this file wholesale with the real entry point: the
    parameter block (-ConfigPath, -Phases, -Force, -VerifyOnly, -Attended), the
    module imports, the declarative phase table, and the Invoke-Phase dispatch
    loop. Those parameters are deliberately NOT declared yet - a param block no
    code reads is an unused-parameter warning, and this project runs a
    zero-warnings policy.
.NOTES
    RUN ONLY ON A VIRTUAL MACHINE. Requires Administrator.
    Plan: docs/mvp/MVP_PLAN.md - Spec: docs/mvp/MVP_SPEC.md
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

throw 'Install-REAgent.ps1 is not implemented yet. See docs/mvp/MVP_PLAN.md Task 6.'
