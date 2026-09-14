# SQL query layer — design

**Status:** design, approved 2026-09-09. Branch `feat/sql-query-layer`, based on `main`
(`a734f37`), which now carries the MVP, the skills-vendoring slice and the agent topology.

Companion to `docs/superpowers/specs/2026-09-06-skills-vendoring-design.md` (which vendors
*instructions*) and `docs/superpowers/specs/2026-09-07-agent-topology-design.md` (which authors
*actors*). This slice adds a *query surface*: two servers that answer SQL over binary analysis
data, so the agent pushes filters down instead of pulling functions into context.

---

## 1. Goal

Install and wire two MCP servers from 0xeb's `libxsql` family, each exposing a small tool
surface over SQL:

| Server | Queries | Stage |
|---|---|---|
| `pdbsql` | Windows PDB symbol files — functions, publics, UDT layouts, enums, line numbers | 1 |
| `ghidrasql` | A Ghidra program database — functions, xrefs, strings, types, decompilation | 2 |

### 1.1 Why now

`docs/BLUEPRINT.md` gives this family its own section (§2) — the only tool family that gets
one — because it is a different architecture from "expose N bespoke MCP tools", and it attacks
the two failure modes this lab will hit hardest.

**Context bloat.** §2's own example: *"give me the ten largest functions that call
`VirtualAlloc` and contain a loop, ordered by cyclomatic complexity"* is one query returning a
handful of rows, not fifty decompilations. The blueprint calls that "the difference between a
session that works and one that dies of context exhaustion" on a 50MB binary. §5's context
budget list names pushing filters down as tactic (d).

**Invented structure.** §2 singles out `pdbsql` as "a sleeper hit for Windows work — querying
PDB symbol data as SQL is exactly the symbol/type grounding that stops the model from inventing
structure layouts." §3's failure mode 1 is hallucinated semantics; failure mode 5 is decompiler
noise cascading through type recovery. Real PDB field offsets are the deterministic answer to
both.

**Tool-schema learning cost.** SQL is the one query language every model already speaks. Two
tools replace a bespoke schema the model has to learn.

The MVP put the query layer out of scope. The skills slice vendored instructions for servers
that already existed. This slice adds the servers.

### 1.2 Out of scope

- **`idasql`** — no IDA licence on this host, and IDA is x86-64 only. Not applicable.
- **`bnsql`** — Binary Ninja's SQL layer. Deferred with the rest of the Binary Ninja work,
  which is blocked on the attended tool-catalog capture recorded in `docs/mvp/HANDOFF.md`.
- **`dwarfsql`** — DWARF debug info. This install is Windows-PE-focused.
- **libghidra's "local backend"** — the 166MB self-contained decompiler archive. It needs
  Ghidra source at or after GP-7063, which landed *after* the 12.1.3 release, and `ghidrasql`
  does not consume it: the CLI offers only `--ghidra <path>` (headless host) and `--url`
  (running host). Named here so nobody re-evaluates it blind.
- **Writing annotations through SQL.** The layer supports it; this slice runs read-only. See
  §7.3.
- **Replacing `pyghidra-mcp`.** `ghidrasql` is a second, differently-shaped view of Ghidra
  data, not a replacement. `pyghidra-mcp` remains the primary static backend (L8).

### 1.3 Definition of done

1. `pdbsql` answers a real MCP tool call returning rows from the warmed symbol cache — the
   check that `MVP.md` calls the only one that matters, applied to this server.
2. `ghidrasql` answers a real MCP tool call returning rows from a Ghidra program database
   built on this host.
3. Both servers survive a re-run untouched: no launcher rewrite, no restart, no timestamp
   change (the idempotency contract, and defect 7's fix).
4. `-VerifyOnly` reports both servers correctly with no prior run in the session, replaying
   from the manifest.
5. The `verifier` agent's grant includes `pdbsql` and passes A0–A4 unchanged.
6. `Invoke-Pester -Path tests/` passes with zero PSScriptAnalyzer findings.

---

## 2. Locked decisions

| # | Decision | Rationale |
|---|---|---|
| SQ1 | **Staged: `pdbsql` first, `ghidrasql` second** | Stage 1 is measured working end to end (§3). Stage 2 needs a vendor-time build whose outcome is specified but unproven. Staging keeps the risky half off the critical path. |
| SQ2 | **A new install `kind`: `native-sse`** | Both are pinned native binaries serving MCP over SSE. None of the five existing kinds (`plugin-inproc`, `venv-stdio`, `venv-http`, `gui-builtin-http`, `gui-plugin-http`) describes that. The dispatcher stays generic. |
| SQ3 | **Both run under a logon Scheduled Task** | Long-running servers Claude Code cannot spawn — the same constraint that produced L10 for `pyghidra-mcp`. Reuses the launcher and restart machinery already hardened by defects 5, 7 and 8. |
| SQ4 | **The MCP endpoint is unauthenticated, and that is accepted** | `--mcp` has no auth; `--token` covers only the REST mode. Fronting with REST would mean giving up MCP. Bound to `127.0.0.1` and recorded in the manifest's `authExemptions`, exactly as `pyghidra-mcp` is. |
| SQ5 | **Both servers run read-only** | The SQL surface is writable by design. `ghidrasql` takes `--readonly`; a PDB is a read-only artifact. See §7.3 below — this is what makes the single `*_query` tool classifiable at all. |
| SQ6 | **The `LibGhidraHost` extension is built against this host's Ghidra, never installed from a release zip** | The prebuilt zips are version-locked to whatever distribution the author built them against. The source stamps the version from your own install. See §5.2. |
| SQ7 | **`pdbsql`'s PDB is a launcher parameter, not a server-per-PDB fan-out** | `pdbsql` binds one PDB per process at launch. One server per PDB would burn a port each. The launcher already carries a per-target path for `pyghidra-mcp` and is rewritten only when it changes. |

---

## 3. The measurement that grounds this

Everything below was measured on this host on 2026-09-09, not read off the blueprint. The
blueprint's own §2 is a snapshot from an earlier research pass and is wrong in two places,
noted inline.

### 3.1 `pdbsql` works, end to end

Release `v0.0.7` (2026-08-30), asset `pdbsql-windows-x64.zip`,
SHA-256 `bdfc1328397d4329ed3a2d8dc647e16e77709b077efb8075b1fd740fbe03a8e8`. The archive holds
`pdbsql.exe` and `zlib.dll` — no build, no runtime, no disassembler dependency.

Pointed at the symbol cache the MVP already warmed, it loaded `ntdll.pdb` and reported
**430 functions, 6,910 public symbols, 772 UDTs, 137 enums, 556 compilands.**

A full MCP handshake succeeded over SSE: `serverInfo` `pdbsql 0.0.7`, protocol `2024-11-05`,
tools `pdbsql_query` and `pdbsql_help`. A live `tools/call` of `pdbsql_query` with

```sql
SELECT name, offset, type FROM udt_fields WHERE udt_name='_PEB' LIMIT 5
```

returned the real `_PEB` layout, including `BeingDebugged` at offset 2 — the canonical
anti-debug field, with its true offset, from a deterministic source.

### 3.2 The transport is SSE, and it is undocumented

`pdbsql --mcp` serves **SSE**, not streamable HTTP. Neither the README nor `--help` says so;
it was found by sweeping paths. `GET /sse` returns

```
: SSE connection established

event: endpoint
data: /messages?session_id=<hex>
```

`GET /` and `POST /mcp` both return 404. `ghidrasql --help` documents its own `--mcp` as an
"MCP (Model Context Protocol) SSE server", so both servers share one transport.

**`tools/mcp_probe.py` cannot probe either of them.** It implements `streamablehttp_client`
and stdio only; `POST /sse` answers `405 Method Not Allowed`. This is required work, and it
is reusable — `x64dbg-mcp-server` advertises SSE alongside streamable HTTP.

### 3.3 Four undocumented constraints

| Constraint | Consequence |
|---|---|
| **One PDB per process** — the PDB is a launch-time positional argument | Drives SQ7: the launcher carries it, and switching PDBs is a launcher rewrite plus a restart |
| **`--mcp` default port is random, 9000–9999** | Must pass an explicit port. Static ports are allocated from config, never chosen by the server |
| **`--token` applies to `--http` REST mode only**; the MCP endpoint is unauthenticated | Drives SQ4 |
| **`--warm-file-index` costs 10–18s on a large PDB**, paid on first query otherwise | `Wait-ServerListening` already covers slow starts; warm-up flags are config-exposed |

### 3.4 The symbol-cache path trap

`C:\re\symbols` is a two-level symbol-server tree. The real file is

```
C:\re\symbols\ntdll.pdb\1DF9DB46D55D6B869568C9F6E9287DE41\ntdll.pdb
```

Passing `C:\re\symbols\ntdll.pdb` — which *looks* like the file and is a directory — fails
with `HRESULT 0x806D0005`, reported as "file not found or inaccessible". Resolution must walk
the GUID directory. The cache currently holds `ntdll`, `kernel32`, `kernelbase` and `cmd`.

### 3.5 `ghidrasql` needs the extension, on every path

Release `v0.0.6` (2026-09-08), asset `ghidrasql-cli-windows-v0.0.6.zip`,
SHA-256 `d646e49f1373846decdbc869722e3861b45cb84714fcd1a439f346c9816caff5`. It requires
`libghidra` v0.0.7 specifically — the versions move in lockstep.

The prebuilt binary **does** carry MCP: `--mcp`, `ghidrasql_query`, `/sse` and
`event: endpoint` are all present in the image, so the Windows build was made with
`-DGHIDRASQL_WITH_MCP=ON`.

The headless path is *not* extension-free, contrary to a reasonable reading of BLUEPRINT §2.
Run against Ghidra 12.1.2 with `--ghidra … --binary … --project …`, it exits with:

```
Launching Ghidra headless API host
LibGhidraHost extension not installed at
  C:\ProgramData\chocolatey\lib\ghidra\tools\ghidra_12.1.2_PUBLIC\Ghidra\Extensions\LibGhidraHost
```

**The project-lock collision is not a blocker.** The headless path takes its own
`--project <dir>`, so it need never touch the project `pyghidra-mcp` holds open at
`C:\re\agent\cases\ghidra\re-lab`. This was the risk that looked largest before measurement,
and it is avoidable by configuration.

### 3.6 The extension version lock, and why it does not bind

Prebuilt `libghidra-extension-*.zip` assets declare a single exact Ghidra version:
v0.0.4/v0.0.5/v0.0.6 say `version=12.0.4`; v0.0.7 says `version=12.1.3`. This host runs
**12.1.2** and falls in the gap. Ghidra matches that string exactly and rejects mismatches —
the same failure that keeps `GhidraMCP 1.4` disabled in this repo for targeting 11.3.2.

That lock is an artifact of the prebuilt zips only. The source at tag `v0.0.7` carries a
placeholder:

```
name=LibGhidraHost
version=@extversion@
```

and Ghidra's own `support/buildExtension.gradle`, present in this 12.1.2 install, substitutes
it from the distribution being built against:

```groovy
project.ext.ghidra_version = ghidraProps.getProperty('application.version')   // line 33
File propFile = new File(project.projectDir, "extension.properties")          // line 108
String version = "${ghidra_version}"
filter (ReplaceTokens, tokens: [extversion: version])                          // line 112
```

Building against this host stamps `version=12.1.2`. libghidra's extension README states
support as a range — **"Ghidra 12.0.4+"** — not a pinned version.

**No Ghidra change is needed, in either direction.** Recorded explicitly because the opposite
conclusion is the natural one to reach from the release assets alone, and because
Chocolatey offers only 12.1.2 anyway (12.1.3 exists upstream, released 2026-08-18).

### 3.7 Every build prerequisite is already satisfiable

| Requirement | Source | This host |
|---|---|---|
| Ghidra 12.0.4+ | extension README | **12.1.2** ✅ |
| JDK 21+ | `application.java.min=21`, `application.java.max=` empty | **OpenJDK 25** ✅ |
| Gradle 8.5+ | `application.gradle.min=8.5`, no max | **absent**; `choco search gradle` → 9.7.1 |
| `protoc` | — | **not needed**: protobuf stubs are committed; regeneration is opt-in via `-PREGEN_PROTO=true` and a `protoc` on PATH is ignored |
| Network | Maven Central: `protobuf-java:4.29.3`, `junit:4.13.2` | **vendor-time only** — matches the "only vendoring has a network" rule |

### 3.8 What was not measured

The extension build itself was not executed: it needs Gradle installed, and the decision was
to specify rather than prove. **The failure mode is safe** — the build compiles against
12.1.2's own jars, so genuine API drift fails loudly at vendor time rather than misbehaving at
runtime. Recorded again in §12.

---

## 4. Ports and disk layout

Static allocation from config, as always. Both chosen outside 9000–9999 so a stray
default-port instance can never collide.

| Server | Port | Bind | Path |
|---|---|---|---|
| `pdbsql` | 8770 | `127.0.0.1` | `/sse` |
| `ghidrasql` | 8771 | `127.0.0.1` | `/sse` |

```
C:\re\mcp\
  pdbsql\
    pdbsql.exe, zlib.dll          <- extracted from the pinned release
    launch-pdbsql.cmd             <- generated; carries the resolved PDB path
  ghidrasql\
    ghidrasql.exe
    launch-ghidrasql.cmd          <- generated; carries --readonly and the project
    projects\                     <- ghidrasql's OWN project root, never pyghidra's
```

---

## 5. Installation

### 5.1 `native-sse`

A new `kind` handled by the phase 3 dispatcher:

1. `Get-VerifiedRelease` downloads the pinned asset and checks its SHA-256 — existing code,
   unchanged.
2. Extract to `C:\re\mcp\<server>\`.
3. `Write-ServerLauncher` renders the launcher, **writing only when the content differs**
   (defect 7).
4. `Register-ServerScheduledTask` registers or updates the logon task.
5. `Test-ServerRestartNeeded` compares the task's `LastRunTime` against the launcher's
   `LastWriteTime`; `Restart-StaleServerTask` acts on it, stopping by executable path as well
   as by task (defect 5).
6. `Wait-ServerListening` blocks until the port answers before phase 5 probes it (defect 8).

Steps 3–6 are existing, hardened code. This slice adds only step 2 and the `kind` branch.

### 5.2 The extension build — a vendor-time step

Runs on the maintainer path, with a network, never during an install. Added to
`tools/` as `Build-LibGhidraExtension.ps1`:

1. Require Gradle 8.5+ on PATH; fail with the `choco install gradle` remedy if absent.
2. Fetch `0xeb/libghidra` at the pinned commit for tag `v0.0.7` into the vendor cache.
3. `gradle buildExtension -PGHIDRA_INSTALL_DIR=<the host's Ghidra>` in `ghidra-extension/`.
4. **Assert the stamped `extension.properties` reads `version=12.1.2`.** If it does not, the
   substitution did not happen and the build must not be trusted — throw.
5. Record the built zip's SHA-256 in `re-agent.config.json` beside the pinned commit.

The built extension is committed, so the installer path stays offline. It is a build artifact
derived from a pinned source commit, exactly as vendored skills are content derived from one.

Installation copies it to `<ghidra>\Ghidra\Extensions\LibGhidraHost\`. That directory is the
uninstall: removing it reverts the change.

---

## 6. Config schema

```jsonc
{ "name": "pdbsql", "enabled": true, "kind": "native-sse",
  "transport": "sse", "bind": "127.0.0.1", "port": 8770, "path": "/sse",
  "authExempt": true,
  "source": { "repo": "0xeb/pdbsql", "release": "v0.0.7",
              "asset": "pdbsql-windows-x64.zip",
              "sha256": "bdfc1328397d4329ed3a2d8dc647e16e77709b077efb8075b1fd740fbe03a8e8" },
  "pdb": { "module": "ntdll", "warmTables": ["functions", "publics", "udts"] },
  "verify": { "tool": "pdbsql_query",
              "args": { "query": "SELECT COUNT(*) AS n FROM publics" },
              "expect": "\"n\":\\s*[1-9]" } }
```

Three schema additions, each validated at load:

- **`transport`** — `streamable-http` (the default, preserving every existing entry) or `sse`.
- **`authExempt`** — a boolean that must be `true` for any HTTP-transport server carrying no
  bearer token, and must be accompanied by a manifest `authExemptions` entry. A server that is
  neither authenticated nor explicitly exempt fails schema validation, so the exemption is a
  decision rather than an omission.
- **`pdb.module`** — resolved against the symbol cache through the GUID directory (§3.4). A
  path that resolves to a directory is a schema error naming `0x806D0005`.

`ghidrasql`'s entry adds `"readonly": true` and its own `projectRoot`.

---

## 7. The tool catalog, classification, and the gate

### 7.1 A tiny tool surface

Each server advertises two tools: `<name>_query` and `<name>_help`. Catalog entries are
correspondingly small, and G1/A1 have almost nothing to check — which is the point of the
pattern, not a weakness in it.

Both servers are unattended, so `-UpdateToolCatalog` captures them without a GUI open. That
matters: three of the existing four capture targets need a GUI, which is why the catalog is
checked into the repo at all.

### 7.2 Classification

| Tool | Level |
|---|---|
| `pdbsql_help`, `ghidrasql_help` | `read` |
| `pdbsql_query` | `read` — see the caveat below |
| `ghidrasql_query` | `read` — **only because the server runs `--readonly`** |

### 7.3 The tension the SQL pattern creates, stated plainly

The agent gate classifies **per tool**. The SQL layer's whole virtue is collapsing fifty
operations into one. Those two facts are in direct conflict: `ghidrasql_query` reads or writes
depending on the *text of the SQL*, and A3 cannot see the text.

Sub-classifying by parsing SQL is a denylist, and a denylist will be bypassed. This is
structurally the same problem as OQ1's `run_cdb_command` — and the same ruling would give the
same bad outcome.

**The resolution is at the server, not the classification.** `ghidrasql --readonly` refuses
writes for the life of the process, so `ghidrasql_query` is genuinely read-only and A3's
guarantee holds for real rather than by assertion. `pdbsql` needs no flag: a PDB is a
read-only artifact. Its one caveat is `runtime_settings`, which accepts `UPDATE` — that
mutates query timeouts within the server process, reaches no analysis data, and is recorded
here rather than left to be discovered.

**A3 cannot see a launcher flag**, so a new check covers it:

| id | Fails when |
|---|---|
| **Q0** | the `ghidrasql` launcher does not carry `--readonly` |
| **Q1** | the configured `pdb.module` resolves to a directory rather than a file (§3.4) |

Q0 and Q1 read only the repo and the generated launchers, so they run on every verification,
including `-VerifyOnly` on a host where nothing is installed.

### 7.4 Grants

| Agent | Gains | Why |
|---|---|---|
| `verifier` | `pdbsql` | Deterministic ground truth with no write path to any analysis database — the oracle-shaped grant the verifier has been missing. Real field offsets refute an invented struct layout. |
| `static-analyst` | `pdbsql`, `ghidrasql` | Push filters down during the first pass |
| `dynamic-analyst` | neither | Still ships disabled; unchanged by this slice |

The verifier gaining `pdbsql` narrows the agent-topology spec's §12 gap 1 ("the verifier has no oracle") without
closing it: a PDB grounds symbols and types, not behaviour. Emulation and differential testing
remain the unbuilt half.

---

## 8. Skills

A `sql-query` skill teaching the push-down discipline: filter, aggregate and join in SQL, then
pull only the rows that survive. It carries the contract lines from BLUEPRINT §5 already used
across this repo's skills, plus one specific to this layer — **a row count is evidence; an
empty result set is also evidence, and neither is a conclusion.**

The upstream packs `0xeb/ghidrasql-skills` (12 skills: `connect`, `analysis`, `annotations`,
`decompiler`, `disassembly`, `data`, `debugger`, `grep`, `re-source`, `xrefs`, `types`,
`functions`) are candidates for vendoring through the existing G0–G4 gate, in stage 2 or later.

Two things must be settled before they are:

1. **The licence is `LicenseRef-Human-Origin-Source-1.0`**, not MPL-2.0 as `docs/BLUEPRINT.md`
   §2 and its reference list both record. `ghidrasql`'s own `build.gradle` carries the SPDX
   identifier. BLUEPRINT should be corrected, and the licence read before vendoring.
2. Several skill names (`data`, `types`, `xrefs`, `functions`, `grep`) are exactly the
   collision-prone generics BLUEPRINT §2 warns about. This repo's namespacing rule already
   handles it, and the G0 check enforces it.

---

## 9. Manifest, phases and idempotency

Both servers appear in the manifest's `servers` block with their pinned release, SHA-256,
resolved port and captured tool count — a drop in tool count after an upgrade is the
regression signal the existing code already looks for.

`authExemptions` gains an entry per server, naming the reason: *the MCP endpoint accepts no
credential; bound to 127.0.0.1.*

Phases are unchanged. Install is phase 3, generation phase 4, verification phase 5, manifest
phase 6. `Get-RecordedServerResult` replays both from the manifest so `-VerifyOnly` works with
no prior run in the session (§1.3 item 4).

A steady-state re-run must touch nothing: the launcher content is identical, so its timestamp
does not move, so `Test-ServerRestartNeeded` returns `$false` and the servers are not
restarted. That is defect 7's fix applied to two new servers rather than re-litigated.

---

## 10. Testing

**Unit (Pester, host mocked):** schema validation for `transport`, `authExempt` and
`pdb.module`, including the directory-not-file rejection; launcher rendering for both servers,
asserting `--readonly` is present for `ghidrasql`; the `native-sse` dispatcher branch;
`Get-VerifiedRelease` hash-mismatch refusal; Q0 and Q1 in both directions; classification of
all four tools; and the `verifier`'s grant still passing A0–A4 with `pdbsql` added.

**SSE probe:** `mcp_probe.py` gains `--transport=sse` with tests over a stub SSE server
covering the endpoint-event handshake, a `tools/list`, a `tools/call`, and a server that
accepts the connection but never emits `event: endpoint` — the hang observed during the spike,
which must surface as a timeout with a clear message rather than blocking a phase.

**Live (attended, this host):** the §3.1 query re-run through the installed server, and for
stage 2 a `ghidrasql` query against a project built from `winver.exe`.

**Negative tests**, in the style the skills-vendoring spec's §11 established:

1. A config with an HTTP transport, no token and no `authExempt` → schema refuses to load.
2. A `ghidrasql` launcher with `--readonly` stripped → **Q0 fails**.
3. `pdb.module` pointing at the SRV directory instead of the file → **Q1 fails**, naming
   `0x806D0005`.
4. A catalog refresh adding a tool nobody classified → **A4 fails**, unchanged from the agent
   slice but now covering these servers.

---

## 11. Risks

| Risk | Disposition |
|---|---|
| **Both tools are 0.0.x and ship weekly.** `ghidrasql` went v0.0.3 → v0.0.6 between 2026-08-02 and 2026-09-08. `pdbsql` is on v0.0.7 | Standing re-pin cost, accepted. Pinning is what makes it survivable: the installed bytes never move under you. BLUEPRINT §2's own caveat — "the pattern is more valuable than the current implementation maturity" — is the reason to adopt anyway |
| **`ghidrasql` and `libghidra` version in lockstep** | Both pinned in one config block; bumping one without the other is a schema error |
| **The 12.1.2 extension build is unproven** | Fails loudly at vendor time if the API drifted (§3.8). Stage 2 does not start until the build succeeds |
| **Ghidra could be upgraded out from under the built extension** | The extension is stamped with the version it was built against. A Ghidra upgrade requires a rebuild — recorded as a manual step in the manifest |
| **Two consumers of one Ghidra install** | `ghidrasql` uses its own project root (§3.5), so they share the distribution but never a project. The distribution is read-only at run time |

---

## 12. Known gaps and deliberate divergences

| # | Gap | Disposition |
|---|---|---|
| 1 | **The MCP endpoints accept no credential.** Anything that can reach `127.0.0.1:8770` can query symbols | Accepted, SQ4. Same class as `pyghidra-mcp` under L10, and recorded the same way — in `authExemptions`, where it is auditable rather than forgotten. Closing it needs upstream auth on the MCP endpoint, not a local workaround |
| 2 | **`pdbsql_query` can `UPDATE runtime_settings`** | Recorded, not gated. It reaches query timeouts inside the process, never analysis data. Classifying the tool `write` for this would cost the verifier its only deterministic grounding source and buy nothing |
| 3 | **A3's read-only guarantee for `ghidrasql_query` rests on a launcher flag, not on the classification** | Q0 checks the flag, which is the honest mechanism. Stated so no reader mistakes the classification for the control |
| 4 | **The extension build has not been executed on 12.1.2** | §3.8. Safe failure direction; stage 2 is gated on it |
| 5 | **`bnsql` is absent**, so the Binary Ninja half of the SQL story is missing | Blocked behind the same attended capture as every other Binary Ninja item. Additive when it lands: a config entry, not a redesign |
| 6 | **One `pdbsql` process serves one PDB.** Cross-module questions need a restart | SQ7. A per-PDB fan-out is expressible later as extra config entries if the restart cost proves annoying in practice |
| 7 | **The verifier's oracle is still only half-built** | §7.4. Symbols and types are grounded; behaviour is not. Emulation and differential testing remain GAP C6, which the 2026-09-09 prioritisation kept live |

---

## 13. References

- `docs/BLUEPRINT.md` §2 (the SQL query-layer pattern), §3 (failure modes), §5 (context
  management), §9 (build-your-own gaps)
- `docs/GAP_ANALYSIS.md` — the 2026-09-09 prioritisation table
- `docs/mvp/MVP.md` — L8, L10; the definition of done
- `docs/mvp/HANDOFF.md` — defects 5, 7, 8; the launcher and restart machinery
- `docs/superpowers/specs/2026-09-07-agent-topology-design.md` — OQ1, §8 the A-checks, §12
  gaps 1 and 8
- `0xeb/pdbsql` v0.0.7, `0xeb/ghidrasql` v0.0.6, `0xeb/libghidra` v0.0.7
- RECON 2026 — *SELECT \* FROM binary: Vibe Reversing Across IDA, Ghidra, and Binary Ninja*
