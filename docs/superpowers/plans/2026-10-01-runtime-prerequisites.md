# Runtime Prerequisites Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision missing runtime prerequisites before RE Agent configures dependent MCP servers.

**Architecture:** A small declarative catalog manages App Installer/winget, Node/npm, Python, uv, and the compatible JDK. FLARE-owned tools remain discovery-only; phase 1 refreshes inventory and blocks later phases only when a runtime dependency is still absent.

**Tech Stack:** PowerShell 5.1, Pester, winget/App Installer, existing symbol tooling.

**Spec:** `docs/superpowers/specs/2026-10-01-prerequisite-provisioning-design.md`

## Global Constraints

- FLARE owns WinDbg, x64dbg, Binary Ninja, and Ghidra; this installer only verifies them.
- `-VerifyOnly` must remain read-only; `-WhatIf` must not run installers.
- Every external command uses `Invoke-CommandLine`.
- Rediscover a component after installation; fail with actionable remediation if it remains absent.

## Review Focus

- winget is unavailable: report its bootstrap failure before uv installation.
- npm exposes an extensionless shim before `npm.cmd`: select the runnable shim.
- a successful package command leaves its required executable absent: block dependent server setup.
- symbols lack the configured PDB module: do not report `pdbsql` ready.
- FLARE-owned tools are absent: identify them as FLARE prerequisites, never attempt to install them.

---

### Task 1: Bootstrap the runtime package manager

**Files:**
- Modify: `src/ReAgent.Discovery.psm1`
- Modify: `src/ReAgent.Prereqs.psm1`
- Test: `tests/ReAgent.Discovery.Tests.ps1`
- Test: `tests/ReAgent.Prereqs.Tests.ps1`

**Interfaces:**
- Produces: `Find-WingetPath() -> [string|null]` and `Assert-PackageManager() -> [string]`.

- [ ] Write failing tests for installed winget, missing winget restored through App Installer, and a failed rediscovery.
- [ ] Run `Invoke-Pester -Path tests/ReAgent.Discovery.Tests.ps1,tests/ReAgent.Prereqs.Tests.ps1 -Output Detailed` and verify the new tests fail.
- [ ] Implement `Find-WingetPath` and `Assert-PackageManager`; refresh process PATH after bootstrap and throw an App Installer remediation when winget remains unavailable.
- [ ] Run the focused tests and verify they pass.

### Task 2: Catalog runtime dependencies

**Files:**
- Modify: `src/ReAgent.Prereqs.psm1`
- Modify: `tests/ReAgent.Prereqs.Tests.ps1`

**Interfaces:**
- Consumes: `Assert-PackageManager() -> [string]`.
- Produces: `Install-Prereq -Inventory <object>` installs only missing Node/npm, Python, uv, and JDK requirements.

- [ ] Write failing tests for exact package IDs (`OpenJS.NodeJS.LTS`, `Python.Python.3.12`, `astral-sh.uv`, `EclipseAdoptium.Temurin.21.JDK`), idempotency, PATH refresh, and failed post-install rediscovery.
- [ ] Run `Invoke-Pester -Path tests/ReAgent.Prereqs.Tests.ps1 -Output Detailed` and verify failure.
- [ ] Replace the fixed package map with catalog entries that define discovery and validation; make installation abort on unresolved dependencies.
- [ ] Run the prerequisite suite and verify it passes.

### Task 3: Gate symbols and dependent server setup

**Files:**
- Modify: `src/ReAgent.Symbols.psm1`
- Modify: `Install-REAgent.ps1`
- Modify: `src/ReAgent.Servers.psm1`
- Test: `tests/ReAgent.Symbols.Tests.ps1`
- Test: `tests/Integration.Tests.ps1`

**Interfaces:**
- Consumes: refreshed phase-1 inventory and `Test-PdbPathCheck -Server <object> -SymbolRoot <string>`.
- Produces: an actionable block before launching a server whose uv or PDB dependency is unavailable.

- [ ] Write failing tests for missing uv blocking pyghidra/mcp-windbg and a missing configured PDB blocking pdbsql.
- [ ] Run `Invoke-Pester -Path tests/ReAgent.Symbols.Tests.ps1,tests/Integration.Tests.ps1 -Output Detailed` and verify failure.
- [ ] Refresh inventory after phase 1; prevent server setup from proceeding on unresolved runtime prerequisites; make symbol success require the configured PDB module.
- [ ] Run focused suites and verify they pass.

### Task 4: Documentation and full verification

**Files:**
- Modify: `README.md`
- Modify: `docs/mvp/MVP_SPEC.md`

- [ ] Document automatic runtime provisioning and FLARE-owned tool boundaries.
- [ ] Run `Invoke-Pester -Path tests -Output Normal`.
- [ ] Run PSScriptAnalyzer over modified PowerShell files and `git diff --check`.

## Self-review

Tasks 1–3 cover every automated prerequisite and every review-focus failure mode. FLARE-owned tools are explicitly excluded from installation in both the spec and plan.
