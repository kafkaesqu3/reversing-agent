# Prerequisite Provisioning Design

## Goal

Make `Install-REAgent.ps1` provision every supported prerequisite that is absent
on an existing FLARE VM, before dependent MCP-server and verification phases run.
Failures must identify the missing installer or manual dependency before later
phases can emit cascading errors.

## Scope

The prerequisite phase will manage the package-manager bootstrap, Node/npm,
Python, uv, and the Ghidra-compatible JDK. FLARE provisioning owns WinDbg,
x64dbg, Binary Ninja, and Ghidra; this installer only discovers and verifies
those tools. It will also ensure the symbol capability needed by `pdbsql` is
present before that server is enabled.

Authentication, Binary Ninja licensing, Claude/Codex sign-in, running GUI tools,
and building the LibGhidraHost extension remain manual steps. They cannot be
provisioned safely or unattended by this installer.

## Architecture

Add a declarative runtime-prerequisite catalog with, for each component:
discovery predicate, package-manager package identifier or bootstrap route,
verification predicate, and dependent phases. The catalog replaces the current
fixed `$WingetIds` map. FLARE-owned tools remain discovery-only facts.

Phase 0 will discover the package manager and all prerequisite capabilities.
Phase 1 will bootstrap Windows App Installer when winget is absent, refresh the
current process PATH, then install the catalog's missing unattended components
in dependency order. Each install is followed by rediscovery; a component that
remains unavailable is a phase-1 failure with its exact remediation.

Server installation will consume the refreshed inventory only after phase 1.
`pdbsql` will be reported as unavailable until the configured PDB module is
present; a missing `symchk` is not a successful symbol prerequisite.

## Error handling

The installer does not silently continue after an unavailable package manager or
a failed mandatory dependency install. `-VerifyOnly` remains read-only and
reports missing capabilities without trying to provision them. `-WhatIf` shows
the catalog actions without invoking external installers.

## Testing

Pester coverage will prove package-manager bootstrap, PATH refresh, every
catalog discovery/install route, idempotent no-op behavior, failed post-install
rediscovery, and the prevention of server installation when its prerequisite is
absent. Existing integration tests will confirm the phase order and verification
behavior.
