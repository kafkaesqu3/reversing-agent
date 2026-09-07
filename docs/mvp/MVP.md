# MVP — Agent-Wired FLARE VM

**Codex extension:** `install-codex.ps1` now reuses these MCP services for Codex.
See [CODEX.md](CODEX.md) for installation, configuration, and verification commands.
The Claude MVP history below remains the baseline.

**Goal:** one script, run on an existing FLARE VM, that leaves you with Claude Code able to drive **x64dbg, Ghidra, Binary Ninja, and WinDbg** through MCP.

Nothing else. `../../BLUEPRINT.md`, `../../DEPLOYMENT_PLAN.md`, and `../../GAP_ANALYSIS.md` describe the full system; this file tracks only the first shippable slice of it and what still blocks that slice.

**Status:** implemented and merged to `main` (`abbad02`). **All open items O1–O7 resolved**, and
the last small one — x64dbg's `mcp_config.json` path — resolved on the host on 2026-09-06. See
`MVP_FINDINGS.md`, which carries measured host inventory and nine deviations that override this file
and `MVP_SPEC.md` wherever they conflict.

**All five items of the definition of done are met**, including item 3 — every enabled server
answering a real tool call, which this file calls the only one that matters. `-VerifyOnly -Attended`
reports **8 pass, 0 fail, 1 not-testable**, the last being `ghidramcp`, disabled by design.
The idempotency contract is proven too: a full elevated run reports phases 1 and 2 skipped,
everything in phase 3 already present, and no server restart. **Nothing is open** — `HANDOFF.md`
records the closing evidence and what is worth doing next.

---

## What this repo delivers

The installer script is written **by an agent running on the FLARE host**, where live inventory — installed tools, versions, paths, Windows and PowerShell versions — is discoverable rather than guessed.

So the deliverable here is not `Deploy-RELab.ps1`. It is the **build spec that agent works from**: locked decisions, component picks with their gotchas, the config schema, the verification contract, and the failure modes to design around. Anything in this file that depends on the host's actual state is written as *"discover this, then branch"* rather than a hardcoded path or version.

Practical consequence: the spec must carry enough context to survive being handed to an agent with no memory of this conversation. Reasons for each decision travel with the decision.

---

## Definition of done

A single command on a FLARE VM produces a box where:

1. `claude --version` and `claude doctor` succeed.
2. `claude mcp list` shows the enabled servers, all **connected**.
3. Each server answers one real tool call against a known test binary — not just a handshake.
4. Re-running the script changes nothing and reports so (idempotent).
5. A `manifest.json` records every component, version, source, and hash actually installed.

Item 3 is the one that matters. A connected server that errors on first use is the normal failure mode, and presence checks will not catch it.

---

## Decisions locked

| # | Decision | Rationale |
|---|---|---|
| L1 | **Profile A** — Claude Code runs inside the VM | Self-contained box; simplest wiring. Implies trusted/licensed binaries and CTF work, **not live malware** — the VM needs egress and holds credentials. |
| L2 | **All MCP servers run locally**, bound to `127.0.0.1` | An MCP server is a plugin or wrapper pinned to its tool, not an independently placeable service. Three of four tools are Windows-bound outright. See `../../DEPLOYMENT_PLAN.md` §D4. |
| L3 | **Inference is the only thing that leaves the box** | MVP uses Claude auth against the Anthropic API. Spark/LiteLLM routing is a later phase — no `ANTHROPIC_BASE_URL` plumbing now. |
| L4 | **Adopt-and-reconcile, not greenfield install** | The target is an existing FLARE VM. The script inventories and fills gaps; it never assumes a clean baseline. |
| L5 | Binary Ninja uses its **official built-in MCP server** | Vendor-maintained, ships with every GUI edition including Free, enabled by a setting rather than a plugin install. The Personal license is not a constraint. Headless is Commercial+ **and absent from native Windows packages**, so the GUI server is the only option here regardless. |
| L6 | `.mcp.json` is **generated from config data**, never hand-written | The single change that makes the later Profile-B / remote-Ghidra move a config edit rather than a rewrite. |
| L7 | **Claude Code is a prerequisite, not an install target** | It is already on the box. The script discovers and verifies it; absence is a hard preflight blocker. Auth stays interactive and manual — no credentials are ever written by the script. |
| L8 | **pyghidra-mcp is the default Ghidra backend.** GhidraMCP is installed but disabled | Headless, project-wide across EXE→DLLs, no GUI dependency. GhidraMCP ships alongside as an opt-in alternative — see "Enabling GhidraMCP" below. |
| L9 | **The golden-template hygiene phase is dropped** | This is your working box, not a template. Revisit if that changes. |
| L10 | **pyghidra-mcp runs over streamable-http on `127.0.0.1:8762`, not stdio** | Under stdio, `ghidrecomp` prints to stdout — which *is* the MCP channel — and symbol setup kills the analysis while `initialize` still succeeds. HTTP makes symbols work. Cost: a logon Scheduled Task owns the process, and the server has **no auth mechanism at all**, a documented exception to the bearer-token rule. |
| L11 | **x64dbg is modelled as two servers, `x64dbg-x64` and `x64dbg-x32`** | The plugin compiles its port in from pointer width (9094/9095) and each process reads its own `mcp_config.json`. Modelling one server would leave 32-bit targets unreachable — the exact intermittent failure the spec warned about. |

---

## Component plan

Picks are recommendations; verify against upstream during implementation.

| Tool | MCP server | Transport | Enabled | Notes |
|---|---|---|---|---|
| **x64dbg (x64)** | `duty1g/x64dbg-mcp-server` v1.3 | HTTP + SSE, bearer, **:9094**, path `/` | ✅ | **Prebuilt** — no Zig build. Zero runtime deps, drops into `plugins\`. **Pre-seed `mcp_config.json`**: the plugin preserves an existing file, so the installer writes bind/port/token first and never launches the GUI. |
| **x64dbg (x32)** | same plugin, second server | HTTP + SSE, bearer, **:9095**, path `/` | ✅ | ⚠️ **One server per architecture.** The port is compiled in from pointer width and each process reads its own config file. A 32-bit target loads x32dbg, so omitting this leaves half the debugging surface unreachable. |
| **WinDbg** | `svnscha/mcp-windbg` 1.2.1 | stdio | ✅ | Python venv wrapping `cdb.exe`. ⚠️ `cdb.exe` here ships in the **WinDbg MSIX package** and is *not* on PATH — pass `--cdb-path` explicitly. No module-list tool; use `run_cdb_command lm` against a crash dump. |
| **Ghidra** | `clearbluejar/pyghidra-mcp` 0.2.5 | **streamable-http, :8762** | ✅ | Default. Headless; opens the project itself. ⚠️ **HTTP, not stdio** — stdio breaks symbol loading (see L10). Runs from a logon Scheduled Task, since Claude Code cannot spawn an HTTP server. |
| **Ghidra (alt)** | `LaurieWired/GhidraMCP` 1.4 | SSE | ⛔ installed, disabled | Java plugin + Python bridge. Minimal tool set, floods context on large binaries — an escape hatch, not a default. ⚠️ Release 1.4 targets **Ghidra 11.3.2**; this host runs **12.1.2**, so the extension will be rejected. Record `not-installed`, do not fail. |
| **Binary Ninja** | **official built-in server** (Vector 35) | HTTP, `:24642/mcp` | ✅ | Nothing to install — enabled via `ui.mcp.enabled` in Binary Ninja's own settings. Ships with every GUI edition, Free upward. ⚠️ **Does not autostart**: `Plugins > MCP > Start Server`, every session. |

**Enabling GhidraMCP:** both Ghidra servers get entries in `.mcp.json`; GhidraMCP is listed in `disabledMcpjsonServers` in `.claude/settings.json`, so it is present but not loaded into a session. Enable it per-session via `/mcp`, or permanently by removing it from that list. ⚠️ Verify the exact settings key against current Claude Code docs during implementation.

**Also in MVP scope:**

- Static port allocation from the config file into `ports.json` — servers do not pick their own ports.
- Bearer token generation for every HTTP-transport server.
- A minimal `CLAUDE.md` carrying the trust-boundary contract lines from `../../DEPLOYMENT_PLAN.md` Phase 7. ~30 lines, and the cheapest safety win available.
- `_NT_SYMBOL_PATH` set machine-wide plus a pre-warmed symbol cache (R7). Without it, WinDbg gives the agent unnamed addresses forever.
- `manifest.json` recording what was found and what was installed.

---

## Attended vs unattended servers

A consequence of L5 and of how debugger plugins work: **four of six servers require their host
application to be running already**, and a fifth needs a scheduled task alive. The agent cannot
bootstrap its own tools.

| Server | Needs its app open? | Unattended? |
|---|---|---|
| pyghidra-mcp | No — headless, opens the Ghidra project itself | ✅ via a **logon Scheduled Task** — it serves HTTP, so Claude Code cannot spawn it on demand |
| svnscha/mcp-windbg | No — spawns `cdb.exe` on demand | ✅ — the only true spawn-on-demand server in the set |
| x64dbg MCP (x64, :9094) | **Yes** — the plugin lives in x64dbg's process | ❌ |
| x64dbg MCP (x32, :9095) | **Yes** — same plugin loaded by x32dbg | ❌ |
| GhidraMCP | **Yes** — Ghidra GUI | ❌ |
| Binary Ninja MCP | **Yes** — BN GUI, binary loaded, **and `MCP > Start Server` run this session** | ❌ |

Two consequences:

1. **Verification splits into two tiers.** The unattended tier runs in CI or on every script run. The attended tier needs a human to open x64dbg and Binary Ninja with a test binary loaded first, and the script must prompt for that rather than reporting a false failure.
2. **The operating model is human-opens, agent-drives.** Worth stating explicitly in `CLAUDE.md` so the agent reports "Binary Ninja is not running" rather than inventing an explanation for a dead server.

---


## Resolved defaults

| # | Item | Default |
|---|---|---|
| R1 | Script language and target | PowerShell 5.1 (the FLARE-VM baseline), single `.ps1` plus a JSON config |
| R2 | Structure | Reuse `../../DEPLOYMENT_PLAN.md`'s declarative phase table and `Invoke-Phase` wrapper, cut down to the phases the MVP needs |
| R3 | Python for the venv-based servers | **3.10+** (both mcp-windbg and pyghidra-mcp require it). Discover an existing interpreter first, install only if absent; one venv per server, never shared. **No Node.js is needed anywhere in this build** |
| R4 | Elevation | Script runs elevated, but Phase 0 must resolve `claude` **as the analyst user** — Claude Code installs per-user to `%USERPROFILE%\.local\bin`, so checking under elevation can miss it or find the wrong one |
| R5 | Reboots | Assume none needed; no state machine or resume logic in the MVP |
| R6 | Failure behaviour | Fail fast and loud per component; a broken Binary Ninja does not block a working x64dbg |
| R7 | Symbols | `_NT_SYMBOL_PATH` set machine-wide, cache pre-warmed against the common system DLLs — **in scope** |

---

## Out of scope for the MVP

Deferred, tracked in the companion docs, listed here so the boundary is a decision rather than an oversight:

- **Skills and agents** — `dariushoule/x64dbg-skills`, ReVa skills, subagent topology (static-analyst / dynamic-analyst / verifier)
- **Hooks** — VM snapshot before dynamic tools, output redaction, untrusted-data tagging, write approval
- **Audit trail** (C2) and the **verification oracle** (C6 — evaluate `2akouwu/reverify` before building)
- **Cost caps** (C4) and **kill switch / resource containment** (C5)
- **Build-your-own wrappers** — capa, PE/format — and the secure-wrapper contract they need (C3)
- **Docker / container isolation** — only pyghidra-mcp of the five could be containerized at all, and nothing in the MVP needs it. It earns its place alongside the wrappers above, where sandboxing untrusted tooling is the actual point
- **Profile B**: sealing, egress lockdown, host-only networking, snapshot lifecycle
- **Spark integration**: LiteLLM routing, `ANTHROPIC_BASE_URL`, tailnet ACLs, MCP gateway
- **Other tools**: Frida, IDA, radare2, TTD depth, angr
- Additional agent runtimes — Codex CLI, opencode

---

## Build order

1. **Inventory and preflight** — what is already on the box, what versions, what is missing (Claude Code included, as a prerequisite check)
2. **Config schema + `.mcp.json` generator** — build this first; everything downstream emits through it
3. **One server end-to-end: pyghidra-mcp** — prove the whole chain (install → generate config → connected → live tool call) on a single tool before scaling out
4. **WinDbg** + symbols
5. **Binary Ninja**
6. **x64dbg**, then GhidraMCP installed-and-disabled
7. **Verification suite** (both tiers) **+ manifest**
8. **Idempotency pass** — re-run clean

Step 3 is the real milestone. Once one server is genuinely driving a tool from Claude Code, the other three are repetition of a proven pattern.

**Why pyghidra-mcp rather than x64dbg for step 3** (this reverses the original order): x64dbg can only be verified attended, with a GUI open, so its end-to-end milestone cannot be proven by an automated test. pyghidra-mcp is unattended, so the full chain closes inside a test run. x64dbg still lands before the rest of the tail.

---

## Open items

✅ **All seven resolved.** Evidence and method are in `MVP_FINDINGS.md`; `MVP_SPEC.md` §13 carries the
section each one touched.

| # | Item | Resolution |
|---|---|---|
| O1 | `disabledMcpjsonServers` settings key | ✅ Correct and current. **New risk surfaced:** `.mcp.json` servers sit at ⏸ Pending until `claude` is run interactively once and the trust prompt accepted — emit `enableAllProjectMcpServers` and document the manual step |
| O2 | Prebuilt x64dbg plugins, or a Zig build? | ✅ **Prebuilt.** Release v1.3 ships a `dist/` tree covering x32 and x64. **Zig dropped from prerequisites entirely** |
| O3 | Binary Ninja settings path, safe to merge? | ✅ `%APPDATA%\Binary Ninja\settings.json`, exists, currently `{}`. Merge with backup; refuse to write what will not parse |
| O4 | Test binary | ✅ `C:\Windows\System32\winver.exe` — no download, present everywhere, and verified decompiling end-to-end |
| O5 | x64dbg token bootstrap | ✅ **Pre-seed** — the cleanest of the three options. The plugin reads and preserves an existing `mcp_config.json`; the token is generated only when missing |
| O6 | Does BN autostart its server? | ❌ **No.** `Plugins > MCP > Start Server` is required **every session**. Belongs in `CLAUDE.md` and the tier-2 prompt |
| O7 | Minimum BN version for `ui.mcp.*` | ✅ Undocumented by the vendor — so gate on the capability instead: probe `binaryninja.exe` for the `ui.mcp.enabled` literal. 6.0.10601.0 has it |

✅ **The last small item is resolved.** x64dbg's `mcp_config.json` is written **beside
`x64dbg.exe`**, in the release directory — `C:\tools\x64dbg\release\{x64,x32}\mcp_config.json` — and
not in `plugins\`, which holds no such file. The plugin honoured the pre-seeded token: the live
server on :9094 authenticates with exactly the token the installer generated. `Get-X64dbgConfigPath`
is correct as written.

---

## Log

> **Resuming this work? Start at `HANDOFF.md`.** It carries current state, the exact next
> steps, and the environment gotchas that are not derivable from the code.

| Date | Entry |
|---|---|
| 2026-09-04 | MVP scoped. `../../BLUEPRINT.md` §6/§8 and `../../DEPLOYMENT_PLAN.md` §D4 + Part 1 updated: all MCP servers local, inference remote, three-plane model documented. |
| 2026-09-04 | B1–B5 resolved → L7–L9. Claude auth interactive, Spark deferred. pyghidra-mcp default / GhidraMCP opt-in. Template hygiene phase dropped. BN Personal confirmed GUI-plugin-only. Docker scoped as an off-by-default switch. Attended/unattended server split identified. |
| 2026-09-04 | Build spec written to `MVP_SPEC.md`. O1–O5 carried forward, O6 added (host-side nested virt). |
| 2026-09-04 | Docker dropped from the MVP entirely (was spec §10 / `-WithDocker`) — only pyghidra-mcp could ever be containerized, and nothing in the MVP needs it. Spec renumbered to 14 sections, phases to 0–6. Prerequisites pinned from upstream: **Python 3.10+**, a JDK matched to the installed Ghidra, `cdb.exe`, and **no Node.js**. x64dbg and Binary Ninja MCPs have zero runtime dependencies. |
| 2026-09-04 | Binary Ninja switched to Vector 35's **official built-in MCP server** (`ui.mcp.*`, HTTP on `:24642/mcp`) — supersedes `fosdickio/binary_ninja_mcp`. Removes a pinned third-party source, its hash, and a bridge venv; resolves the Personal-license question entirely. New `gui-builtin-http` kind. O3 repurposed, O7/O8 added. Confirmed Ghidra and x64dbg have **no** official equivalent — community picks stand. |
| 2026-09-04 | Claude Code install phase dropped — it is already present on the target, so it becomes a Phase 0 prerequisite check (hard blocker if absent) and stays in tier-1 verification. Spec phases renumbered 0–7. Both MVP docs moved to `docs/mvp/`. |
| 2026-09-04 | **O1–O7 all resolved** against the live host and upstream sources; findings recorded in `MVP_FINDINGS.md`. Host inventory measured: **nothing needs installing** — Python 3.13.15, OpenJDK 25, uv, cdb (MSIX), Ghidra 12.1.2, x64dbg, Binary Ninja 6.0.10601, Claude Code 2.1.261 all present; 8 GB RAM, below the 32 GB advisory. |
| 2026-09-04 | **The full chain was proven end-to-end before writing installer code**: `uv` venv → pyghidra 3.1.0 on Ghidra 12.1.2 under JDK 25 → MCP `initialize` (20 tools) → `decompile_function` returning real C for `winver.exe`'s entry point. Build risk is packaging and idempotency, not tool compatibility. |
| 2026-09-04 | Nine deviations from the spec recorded and folded in. New decisions **L10** (pyghidra-mcp over streamable-http, accepting no-auth and a logon Scheduled Task, to keep symbols) and **L11** (x64dbg modelled as two servers on 9094/9095). Zig dropped; `symchk` found unavailable, so symbol pre-warm becomes best-effort. |
| 2026-09-04 | **Tasks 1–16 implemented**: 11 modules, the entry point, a `tools/mcp_probe.py` MCP client, and 254 Pester tests with zero PSScriptAnalyzer findings. Four real bugs in the plan's own code were caught by its tests: `Assert-Preflight` threw on healthy hosts (empty-array unroll), `Get-X64dbgToken` read a `token` field that upstream calls `AuthToken`, `Get-JavaVersion` silently returned null for single-component JDK versions, and 3-argument `Join-Path` is PowerShell 6+ only. |
| 2026-09-04 | Verification runs live tool calls through `mcp_probe.py` under each server's own venv rather than hand-rolled JSON-RPC. Proven against pyghidra-mcp: 20 tools, `decompile_function` returning real C for `winver.exe`, and a correct `ok:false` on a tool error — the 'connected but broken' case tier-1 exists to catch. **Not yet done:** an elevated end-to-end run, and `verify.tool` names for x64dbg and Binary Ninja, which are left unset rather than guessed. |
| 2026-09-05 | **First elevated end-to-end run.** Produced `C:\re\agent\.mcp.json`, `.claude\settings.json`, `CLAUDE.md`, and `C:\ProgramData\re-lab\{install.log,manifest.json,verify-report.json}`. `claude mcp list` showed **binaryninja, mcp-windbg, pyghidra-mcp and x64dbg-x64 connected**; x64dbg-x32 refused, correctly, with x32dbg not running. The trust prompt was accepted, settling the O1 ⏸-Pending risk. x64dbg's real SHA-256 pinned for v1.3. |
| 2026-09-06 | Branch merged to `main` (`abbad02`, 25 commits, `--no-ff`). **x64dbg's config path resolved** — beside `x64dbg.exe`, not `plugins\`. **Tier-2 tool names read off the live servers** while both apps were open: x64dbg advertises 80 tools, Binary Ninja 75; `verify` blocks added for `GetDebugState` and `bn_binary_view_list`, both proven by hand through `mcp_probe.py`. **Three new defects found**: `-VerifyOnly` skips phase 0 so every check degrades to a false negative and the run throws on a null inventory; pyghidra-mcp's Ghidra project is empty despite the launcher passing `winver.exe`, so the default Ghidra backend has nothing to decompile; and `$PSScriptRoot` comes back empty in the `-ConfigPath` param default on this host. |
| 2026-09-06 | **Four defects found and fixed, verification now passes for real.** `-VerifyOnly` had been producing a report of pure false negatives: it skipped phase 0, so with no inventory and no install results every server read `not-installed` and the run threw on a null inventory. Phase selection moved into `Select-Phase`, `Get-RecordedServerResult` replays the last run's states from `manifest.json`, `Test-Preflight -VerifyOnly` drops the install-only blockers, and verification now separates *unknown* from *not installed*. `$PSScriptRoot` was empty in the `-ConfigPath` default because **`[CmdletBinding()]` on a script empties it inside the param block** — bisected, not an SMB artefact. **PowerShell 5.1 strips double quotes from a native command's arguments**, so every inline `--calls=` JSON reached `mcp_probe.py` mangled and three healthy servers were reported unreachable; calls now travel through `--calls-file`. And `Test-PyghidraLive` was passing on a failed decompilation, matching the JSON envelope's own braces instead of the C inside it. Result: 7 pass, 1 fail, 2 not-testable, with **mcp-windbg's tool argument names confirmed** and **L11's two-server x64dbg model proven on the x32 side**. 294 tests, zero analyzer findings. |
| 2026-09-06 | **Every enabled server now answers a real tool call: 8 pass, 0 fail, 1 not-testable.** Two more defects closed the gap. A rewritten launcher never reached the running server — `Register-ServerScheduledTask` compares the task's action, the launcher *path*, which never changes — so pyghidra-mcp had served an empty project since 2026-09-05: process started 19:04:26, launcher naming `winver.exe` written 19:47:57. `Test-ServerRestartNeeded` now compares the task's `LastRunTime` against the launcher's `LastWriteTime`. `Stop-ScheduledTask` alone was not enough — it only reaches instances started this session, and the orphan from the previous logon held the Ghidra project lock, killing the replacement with `LockException` — so the restart also stops the server by executable path. And `Test-PyghidraLive` now decompiles the configured `testBinary` rather than `programs[0]`, so an analyst's own imports no longer decide what the installer's own verification asserts. `Grant-PathFullControl` gives `stateRoot` an inheritable ace so an unelevated `-VerifyOnly` can write its manifest. 310 tests, zero analyzer findings. |
| 2026-09-06 | **Two regressions from the restart fix, caught by an elevated run and fixed.** `Write-ServerLauncher` rewrote the launcher unconditionally, so its `LastWriteTime` always beat the task's `LastRunTime` and the new staleness check restarted pyghidra-mcp on *every* run; it now writes only when the content differs. And phase 5 probed the server phase 3 had restarted eight seconds earlier — pyghidra-mcp imports and analyses before it binds the port — which reported it unreachable and failed `claude mcp list` with it; `Wait-ServerListening` now blocks until the port answers. `Grant-PathFullControl` landed on the state directory, so an unelevated `-VerifyOnly -Attended` now completes **all six phases, manifest included: 8 pass, 0 fail, 1 not-testable**. 314 tests, zero analyzer findings. |
| 2026-09-06 | **MVP complete.** A full elevated run on the current code reports phases 1 and 2 skipped, everything in phase 3 already present, **no restart line**, and phases 4–6 ok — the idempotency contract, proven. `-VerifyOnly -Attended` immediately after, unelevated, with all three GUI applications open: **8 pass, 0 fail, 1 not-testable**, the last being `ghidramcp`, disabled by design. All five definition-of-done items are met. |
| 2026-09-06 | **Skills-vendoring Task 0 — Claude Code's skill contract measured on this host (Claude Code 2.1.263).** A throwaway `.claude/skills/zz-probe/SKILL.md` (with an `allowed-tools` frontmatter key) dropped into `C:/re/agent` was auto-discovered with **no settings.json opt-in** — debug logs show `Loading skills from: ... project=[C:/re/agent/.claude/skills]` and `Loaded ... project: 1`, and a `claude -p` session listed `zz-probe` among its available skills and successfully invoked it via the `Skill` tool. **`allowed-tools` was accepted with no warning or error** in either the discovery or invocation debug logs — no "unknown key" / "unparseable frontmatter" message appeared. Spec §8.1's `allowed-tools` frontmatter approach stands; the sidecar `tools.json` fallback is **not** needed. Confirmed via non-interactive `claude -p --debug` sessions rather than a live interactive TUI (Bash cannot drive the TUI to type `/` and watch autocomplete) — see `task-0-report.md` for the full method and confidence caveat. |
