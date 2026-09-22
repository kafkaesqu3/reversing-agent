# Codex workspace parity - design

**Status:** approved with measured MCP-layer amendment, 2026-09-14.

Companion to the skills-vendoring, agent-topology, SQL-query-layer, and Codex MCP
designs. The MCP registration slice is complete. This design brings the remaining
Claude Code workspace behavior to Codex without copying Claude-specific syntax into
Codex files.

---

## 1. Goal

After one elevated run of `Install-REAgent.ps1`, launching Codex in
`C:\re\agent` must provide the same supported RE operating model as Claude Code:

1. The trust boundary and analysis discipline load before work begins.
2. Every enabled, reviewed RE skill is discoverable.
3. The enabled static analyst and verifier specialists are discoverable and have
   grants derived from `data/tool-catalog.json`.
4. The five MCP servers whose transports Codex supports remain registered and
   usable.
5. Unsupported legacy SSE capability is reported precisely and never disguised as
   Streamable HTTP.

Parity means equivalent behavior on the capability surfaces both clients support.
It does not mean byte-identical files or pretending that a Claude-only feature exists
in Codex.

### 1.1 Definition of done

1. Phase 4 emits `C:\re\agent\AGENTS.md` and the enabled Codex custom-agent TOML
   files under `C:\re\agent\.codex\agents\`.
2. Phase 5 emits the same set of enabled skill names to both `.claude\skills\`
   and `.agents\skills\`, with client-specific syntax in each tree.
3. No generated Codex artifact contains a Claude-only path, invocation form, builtin
   tool name, or MCP identifier.
4. Codex specialist MCP allowlists are derived from the catalog and exclude every
   tool above the configured agent level.
5. `-VerifyOnly` checks instructions, skills, custom agents, MCP registration, and
   managed-file drift. Any failed check makes the process exit nonzero.
6. A live Codex acceptance run discovers the operating contract, all enabled skills,
   both enabled specialists, and successfully calls a read-only MCP tool.
7. A second install is byte-idempotent and leaves unmanaged Codex files untouched.

### 1.2 Out of scope

- Adding a Streamable HTTP or stdio bridge for `pdbsql`, `ghidrasql`, or
  `ghidramcp`.
- Installing global RE instructions or skills for every Codex workspace.
- Changing the analyst's model, reasoning effort, sandbox, approval policy, login,
  memories, or plugin configuration.
- Adding hooks. The current Claude configuration has no hooks to translate.
- Enabling `dynamic-analyst`; it remains disabled by the existing catalog decision.
- Converting the local skill set into a distributable Codex plugin.

---

## 2. Measured baseline

Measured on 2026-09-14 with Codex CLI 0.153.4 after the MCP integration fix.

| Surface | Claude Code | Codex | Gap |
|---|---|---|---|
| MCP servers | `.mcp.json` plus settings | Five compatible entries in `config.toml` | Closed |
| Project instructions | `C:\re\agent\CLAUDE.md` | No `AGENTS.md` | Open |
| Reviewed skills | Eleven directories in `.claude\skills` | No `.agents\skills` | Open |
| Enabled specialists | `static-analyst`, `verifier` in `.claude\agents` | No `.codex\agents` | Open |
| Disabled specialist | `dynamic-analyst` recorded but not emitted | Not emitted | Equivalent |
| Hooks | None | None | Equivalent |
| Runtime policy | Claude project settings | Existing Codex user policy | Intentionally client-specific |

Official Codex behavior used by this design:

- Codex reads `AGENTS.md` once when a run starts and layers it by directory.
- Repository skills are discovered from `.agents/skills` between the current
  directory and repository root.
- Project custom agents are standalone TOML files under `.codex/agents`.
- Custom agents may override `sandbox_mode`, `mcp_servers`, and `skills.config`.
- MCP server tables support `enabled_tools`, `disabled_tools`, `enabled`, and
  `required`.

Sources:

- <https://developers.openai.com/codex/guides/agents-md>
- <https://developers.openai.com/codex/skills>
- <https://developers.openai.com/codex/multi-agent>
- <https://developers.openai.com/codex/config-reference>

---

## 3. Locked decisions

| ID | Decision | Rationale |
|---|---|---|
| CP1 | Generate Claude and Codex artifacts from the same reviewed semantic source. | Copying the installed Claude tree would preserve Claude paths and tool names; maintaining two independent hand-edited trees would drift. |
| CP2 | Install Codex artifacts at project scope under `C:\re\agent`. | The RE contract should apply when analysing binaries, not in every unrelated Codex workspace. |
| CP3 | Keep the primary MCP registration in user `config.toml`. Custom-agent files repeat only the deterministic, non-secret transport fields Codex requires to parse a standalone agent layer; they never contain bearer values, authorization headers, or token-bearing environment values. | Codex CLI 0.153.4 rejects partial custom-agent MCP tables before parent-layer inheritance. Complete transport tables are therefore required, but secrets still remain in the protected user configuration. |
| CP4 | Use direct repository skills, not a plugin, for this slice. | The skills are local, already pinned and reviewed, and Codex officially discovers `.agents/skills`. Plugin packaging adds distribution concerns without improving this host. |
| CP5 | Convert syntax through explicit adapters and gates, never broad search-and-replace. | Words such as `Read`, `Agent`, and `Bash` can occur as prose or quoted upstream material. Context determines the correct Codex wording. |
| CP6 | Derive Codex custom-agent MCP allowlists from the same catalog classification as Claude grants. | The verifier boundary must remain mechanical. Hand-maintained allowlists would immediately become a second source of truth. |
| CP7 | Omit incompatible SSE servers from Codex agents and report the reduction in their instructions and manifest. | Codex supports stdio and Streamable HTTP, not the installed legacy SSE endpoints. |
| CP8 | Do not mark GUI-hosted MCP servers `required = true`. | x64dbg and Binary Ninja are expected to be absent until the operator opens their host application. Making them required would turn normal startup into a Codex startup failure. |
| CP9 | Preserve unmanaged files and remove only artifacts carrying an RE Agent ownership marker. | `.agents` and `.codex` are shared project namespaces. The installer must not erase operator content. |
| CP10 | Verification has deterministic static gates plus a separate live Codex acceptance tier. | Model wording is unsuitable for a unit-test oracle, while discovery still needs one real end-to-end proof. |

### 3.1 Alternatives rejected

**Configure `CLAUDE.md` as a Codex fallback filename.** Codex supports
`project_doc_fallback_filenames`, but that is a user-global setting and would cause
Codex to treat unrelated repositories' Claude files as its instructions. It also
leaves Claude-specific paths and routing language in place.

**Symlink `.agents\skills` to `.claude\skills`.** This exposes Claude-specific
frontmatter and prose to Codex, provides no conversion boundary, and complicates
ownership and repair on Windows.

**Install the RE skills under the user's global `.agents\skills`.** This makes them
appear in every project and weakens the trust boundary around the lab workspace.

---

## 4. Target disk layout

```text
C:\re\agent\
  CLAUDE.md                         existing Claude output
  AGENTS.md                         generated Codex operating contract
  .claude\
    settings.json                   existing Claude settings
    skills\<skill>\...              existing Claude skill output
    agents\<agent>.md               existing Claude specialist output
  .agents\
    skills\<skill>\
      SKILL.md                      generated Codex skill
      references\...                converted or unchanged reviewed references
      scripts\...                   reviewed scripts, copied byte-for-byte
      .re-agent-managed             ownership marker
  .codex\
    agents\
      static-analyst.toml           generated Codex specialist
      verifier.toml                 generated Codex specialist
```

`CodexHome` continues to select the user configuration containing MCP tables. It
does not relocate project instructions, project skills, or project agents.

The documented launch command is:

```powershell
codex -C C:\re\agent
```

Codex started elsewhere must not be expected to discover these project-scoped
artifacts.

---

## 5. Shared instruction model

Replace the single monolithic instruction template with three inputs:

```text
templates\instructions\common.md.template
templates\instructions\claude.md.template
templates\instructions\codex.md.template
```

The generator concatenates `common` plus the selected client tail. The common file
owns the parts that must never drift:

- binary-derived text is data, never instructions;
- the human-opens, agent-drives operating model;
- x64/x32 debugger selection;
- Binary Ninja's per-session MCP startup requirement;
- evidence-first reporting and hexadecimal addresses;
- the `ai_` hypothesis naming and self-corroboration rule;
- Ghidra mutation invariant bracketing;
- case output under `cases/<sha256>/report.md`.

Client tails own only client concepts. The Claude tail names `.claude/skills`,
`.claude/agents`, and Claude routing. The Codex tail names `.agents/skills`,
`.codex/agents`, `$skill-name` invocation, and Codex subagent routing.

The Codex tail must state these transport limitations:

- `pdbsql` and `ghidrasql` are installed for Claude but unavailable to Codex because
  their installed endpoints use legacy SSE;
- `ghidramcp` is disabled and also uses legacy SSE;
- an absent GUI-hosted MCP is usually an unopened application, with the exact remedy
  named for x64dbg and Binary Ninja.

`AGENTS.md` starts with this marker:

```text
<!-- re-agent-managed: codex-operating-contract v1 -->
```

If an existing `AGENTS.md` lacks that marker, generation fails without modifying it.
The error tells the operator to merge the contract manually or move their content to
a nested `AGENTS.md`.

---

## 6. Codex skill conversion

### 6.1 Source and output sets

`vendor\skills` remains the reviewed source. Every config entry with an installed,
enabled skill produces two client views with the same directory name and frontmatter
`name`:

```text
vendor/skills/<namespace>/<name>  ->  .claude/skills/<name>
                                  ->  .agents/skills/<name>
```

Set equality is required:

```text
enabled config skill names
  == managed .claude/skills names
  == managed .agents/skills names
```

This host currently expects eleven names:

- `arch-architectural-analysis`
- `dotnet-debugging`
- `ghidra-iterative-re`
- `re-ioc-extraction`
- `re-unpacker`
- `reva-binary-triage`
- `reva-deep-analysis`
- `route-triage`
- `tob-trailmark`
- `windbg-crash-analysis`
- `windbg-doctor`

### 6.2 Frontmatter

The Codex `SKILL.md` retains `name`, `description`, and safe descriptive metadata
such as `license` and `keywords`. It removes Claude's `allowed-tools` key. Codex does
not document that key as a permission boundary; actual specialist restrictions live
in custom-agent MCP tables and sandbox configuration.

No `agents/openai.yaml` is required in this slice. MCP dependencies already exist in
the installed Codex configuration and some require protected headers that must not be
copied into a skill tree.

### 6.3 MCP identifier conversion

Codex tool references use the names Codex exposes, not Claude's literal server names.
Add one pure converter and use it everywhere Codex artifacts are generated:

```text
ConvertTo-CodexMcpNamespace('pyghidra-mcp') -> 'pyghidra_mcp'
ConvertTo-CodexMcpNamespace('mcp-windbg')   -> 'mcp_windbg'
ConvertTo-CodexMcpNamespace('x64dbg-x64')   -> 'x64dbg_x64'
ConvertTo-CodexMcpNamespace('x64dbg-x32')   -> 'x64dbg_x32'
```

The rule replaces every non-alphanumeric character with `_`, collapses consecutive
underscores, and lowercases for comparison. Before writing anything, the generator
asserts that all configured server names map injectively. A collision is a hard
failure.

Exact references of the form `mcp__<server>__<tool>` are parsed structurally and
rewritten with the mapped namespace. Free prose mentioning a server by its configured
name remains unchanged.

References to `pdbsql`, `ghidrasql`, or any other incompatible transport are rejected
from a Codex skill. The current eleven enabled skills do not require either SQL server,
so this gate is expected to pass.

### 6.4 Builtin and workflow conversion

The converter operates on known syntactic references and reviewed phrases. The
generated Codex tree must not instruct Codex to call a nonexistent Claude builtin.

| Claude construct | Codex rendering |
|---|---|
| `Bash` tool | the Codex shell, using PowerShell on this Windows host |
| `Read`, `Glob`, `Grep` tools | file reading plus `rg`/`rg --files` through the Codex shell |
| `Write` or `Edit` tools | Codex file-editing tools, preferring `apply_patch` for repository edits |
| `Agent` or `Task` tool | Codex subagent collaboration, only where the skill is allowed to delegate |
| `TodoWrite` | a concise Codex task or plan list; never a literal tool call |
| `/skill-name` | `$skill-name` or `/skills` discovery |
| `.claude/skills` | `.agents/skills` |
| `CLAUDE.md` precedence | `AGENTS.md` precedence |

This table is not permission elevation. A converted skill describes a workflow; the
session and custom-agent configuration decide which tools are actually present.

### 6.5 Scripts and references

Supporting files are copied byte-for-byte unless they contain a gated client-specific
reference. Executable scripts are never mechanically translated. If a script requires
a shell unavailable on Windows, its Codex skill must describe the limitation and fail
clearly rather than silently substituting a command.

Every changed prose or reference file receives the same static content scan already
used for vendored skills, plus the Codex compatibility gate in section 9.

---

## 7. Codex custom agents

### 7.1 Output schema

Each enabled config agent becomes `.codex\agents\<name>.toml` with:

```toml
name = "static-analyst"
description = "Reverse-engineers a binary without running it."
sandbox_mode = "workspace-write"
developer_instructions = """
...rendered client-neutral agent body plus Codex limitations...
"""

[mcp_servers.'pyghidra-mcp']
url = "http://127.0.0.1:8762/mcp"
enabled = true
enabled_tools = ["decompile_function", "disassemble"]

[mcp_servers.'mcp-windbg']
command = "C:\\re\\mcp\\venvs\\mcp-windbg\\Scripts\\python.exe"
args = ["-m", "mcp_windbg.server"]
enabled = false
```

The actual `enabled_tools` array is complete and derived; the short example above is
illustrative only. Every managed, installed Codex-compatible server receives a complete
transport table because Codex parses the custom-agent file independently before layering it
over the parent configuration. HTTP `url` values and stdio `command`, `args`, `cwd`, and
non-secret environment values are derived from `ServerResults`, never copied by parsing the
user's `config.toml`. Agent files contain no bearer value, authorization header, token, or
token-bearing environment value.

An enabled target whose transport needs authentication is a hard generation failure. The two
enabled specialists in this design target only unauthenticated `pyghidra-mcp` and local stdio
`mcp-windbg`; Binary Ninja and x64dbg are emitted as complete but disabled URL tables and need
no credentials. Adding an authenticated target later requires a separately reviewed credential
indirection design. Secret duplication is never an automatic workaround.

### 7.1.1 Measured custom-agent layering behavior

Measured on 2026-09-14 with Codex CLI 0.153.4 in an isolated Codex home. The parent
`config.toml` contained the complete working `mcp-windbg` stdio registration. A custom-agent
file contained only:

```toml
[mcp_servers.'mcp-windbg']
enabled = true
enabled_tools = ["list_dumps"]
```

Codex ignored the agent with:

```text
Ignoring malformed agent role definition: failed to deserialize agent role file ...:
invalid transport
```

The subsequent spawn failed with `unknown agent_type`. This proves the partial table does not
inherit the parent's transport soon enough to become valid. The implementation therefore emits
complete, token-free transport tables as described above and statically verifies them against
the same installed server results used for user registration.

### 7.2 Server reach

Every Codex agent explicitly disables every managed compatible server it does not
target. Each disabled entry still carries its complete non-secret transport because the custom
agent file must parse independently. This prevents an inherited broad MCP configuration from
defeating the agent boundary.

| Agent | Emitted | Sandbox | Enabled MCP servers | Deliberately unavailable |
|---|---|---|---|---|
| `static-analyst` | Yes | `workspace-write` | `pyghidra-mcp` | `pdbsql`, `ghidrasql` require unsupported SSE |
| `verifier` | Yes | `read-only` | `pyghidra-mcp`, `mcp-windbg` | `pdbsql` requires unsupported SSE |
| `dynamic-analyst` | No | - | - | Existing config keeps it disabled |

The static analyst's pyghidra allowlist contains catalog `read` and `write` tools, but
never `destructive`. The verifier's allowlists contain catalog `read` tools only.

Codex cannot reproduce Claude's exact builtin-tool list. `sandbox_mode = "read-only"`
provides the verifier's filesystem boundary, while `enabled_tools` provides its MCP
boundary. The verifier instructions retain the `ai_` exclusion and forbid modifying
analysis state. This is behavioral parity with a documented platform difference.

### 7.3 TOML generation

TOML is generated by dedicated escaping functions; no JSON serializer or ad-hoc quote
replacement is used. Multiline instructions must handle `"""` safely by choosing a
literal form or escaping content before emission.

Each file begins with:

```text
# re-agent-managed: codex-custom-agent v1
```

An existing file with the same name and no marker is never overwritten. Disabled or
removed config agents delete only their marked Codex file. Transport renderers fail if an
enabled target requires a bearer value, authorization header, or token-bearing environment
value; disabled authenticated HTTP servers retain only their URL and `enabled = false`.

---

## 8. Installer integration

### 8.1 Main installer

Keep the existing phase numbers.

**Phase 4 - AgentConfig**

1. Generate Claude `.mcp.json`, settings, `CLAUDE.md`, and Claude agents.
2. Reconcile Codex MCP `config.toml` as today.
3. Generate Codex `AGENTS.md`.
4. Generate Codex custom agents.

**Phase 5 - Skills**

1. Run the existing review and adaptation gates once against the reviewed source.
2. Generate the Claude skill tree.
3. Generate the Codex skill tree through the explicit adapter.
4. Remove marked orphans independently from each client root.

**Phase 6 - Verify**

Add Codex workspace checks to `AdditionalChecks`. `Assert-VerificationPassed` already
makes any failure fail the phase and process while preserving results for the manifest.

### 8.2 Standalone Codex installer

`install-codex.ps1 -ConfigureOnly` also reconciles `AGENTS.md`, Codex skills, and Codex
custom agents. It may copy and convert already-vendored repository content, but it does
not download packages, install Claude files, or start services.

`install-codex.ps1 -VerifyOnly` runs both registration and workspace-artifact checks.

### 8.3 WhatIf

`-WhatIf` reports every intended Codex path and changes nothing. Conversion and static
validation may run in memory; no destination directory, marker, backup, or temporary
file may remain under `C:\re\agent` or `CodexHome`.

---

## 9. Verification gates

Add a Codex workspace check group with stable IDs.

| ID | Check | Failure condition |
|---|---|---|
| C0 | Instruction ownership | `AGENTS.md` missing, unmarked, malformed, or different from the deterministic render |
| C1 | Skill set equality | Enabled config names differ from marked `.agents\skills` directories |
| C2 | Skill identity | Directory name, frontmatter `name`, or expected config name disagree |
| C3 | Skill MCP compatibility | A referenced server is missing, unsupported by Codex, or maps to a nonexistent catalog tool |
| C4 | Claude residue | Generated Codex content retains a banned Claude-only construct outside an explicit quoted-history exception |
| C5 | Agent identity/TOML | Custom-agent TOML does not parse, required fields are absent, or name/file/config disagree |
| C6 | Agent grant | A target is enabled unintentionally, a catalog tool is absent/stale, or a grant exceeds the configured level |
| C7 | Secret isolation and transport provenance | A Codex project artifact contains an Authorization value, generated token, token-bearing environment value, an enabled authenticated target, or a transport field that differs from its deterministic `ServerResults` render |
| C8 | Ownership/idempotency | A second render changes bytes or an unmanaged artifact was modified/removed |

### 9.1 Claude-residue rules

At minimum C4 flags these in generated Codex instructions and active workflow prose:

```text
.claude/skills
.claude/agents
CLAUDE.md wins
TodoWrite
Task tool
Agent tool
Skill tool
mcp__<namespace-containing-a-hyphen>__
```

Mentions in provenance notes or quoted upstream history may be waived by an exact
file/rule exception in `re-agent.config.json`, following the existing scan-exception
model. Blanket waivers are forbidden.

### 9.2 Runtime validation

Unattended verification remains deterministic and does not ask a model to grade its
own configuration. It performs:

- current Codex registration validation;
- strict parse of generated custom-agent TOML;
- static discovery-path, identity, grant, and content checks;
- existing direct SDK probes for non-GUI MCP servers.

Attended acceptance starts a fresh Codex process in `C:\re\agent` after required host
applications are open. It must demonstrate:

1. the session names `AGENTS.md` as an instruction source;
2. `/skills` shows all eleven expected skill names;
3. `static-analyst` and `verifier` appear as custom agents;
4. the verifier cannot see pyghidra write/destructive tools;
5. a read-only pyghidra or mcp-windbg call succeeds from a specialist;
6. no startup failure is caused by closed x32dbg or another optional GUI host.

The live evidence is recorded in `codex-verify-report.json` as attended observations,
not folded into unit-test assertions about model prose.

---

## 10. Manifest

Add a `codexWorkspace` object:

```jsonc
{
  "root": "C:\\re\\agent",
  "instructions": {
    "path": "C:\\re\\agent\\AGENTS.md",
    "status": "installed",
    "sha256": "..."
  },
  "skills": [
    { "name": "windbg-doctor", "status": "installed", "sha256": "..." }
  ],
  "agents": [
    {
      "name": "verifier",
      "status": "installed",
      "level": "read",
      "servers": ["pyghidra-mcp", "mcp-windbg"],
      "toolCount": 16
    }
  ],
  "omittedServers": [
    { "name": "pdbsql", "reason": "legacy SSE is unsupported by Codex" }
  ]
}
```

Hashes cover generated output, not source directories. No token, header, full Codex
configuration, or analyst-specific model preference enters the manifest.

---

## 11. Security and ownership

1. Binary, decompiler, debugger, and MCP output remain untrusted data under both
   clients.
2. The same reviewed vendor pin and content scan gate both client outputs. Codex
   conversion does not create a second supply-chain intake.
3. Bearer values remain only in the protected Codex user configuration and existing
   token store. Project custom-agent files may carry deterministic local URLs and stdio launch
   settings derived from `ServerResults`, but never authorization headers, tokens, or
   token-bearing environment values.
4. `AGENTS.md`, agent TOML files, and skill directories require ownership markers.
5. Removal functions resolve and verify their absolute targets under the expected
   `C:\re\agent\.agents\skills` or `.codex\agents` root before recursive deletion.
6. The verifier uses a read-only sandbox and read-only MCP allowlists. No Codex agent
   receives catalog `destructive` tools.
7. Skills may describe writing reports, but a skill declaration never grants a tool.
8. No SessionStart hook is added to compensate for discovery. Codex already performs
   native instruction, skill, and custom-agent discovery.

---

## 12. Idempotency and migration

The first parity run creates new Codex project paths. Subsequent runs compare the
candidate bytes before writing.

- Unchanged files keep timestamps and create no backup.
- A changed marked `AGENTS.md` receives a unique backup before atomic replacement.
- Changed marked agent TOML files use atomic replacement.
- Skill directories stage into a sibling temporary directory, pass all gates, then
  replace the marked destination.
- An interrupted conversion leaves the last complete destination intact.
- Unmarked collisions fail the owning phase without changing the collision.
- Orphan cleanup removes only marked artifacts whose names were previously managed by
  this installer.

The existing Claude output remains in place throughout migration. Codex parity failure
must not roll back or delete a healthy Claude configuration.

---

## 13. Test requirements

### 13.1 Unit tests

- MCP namespace conversion for hyphens, underscores, case, repeated punctuation, and
  collision rejection.
- Structured MCP tool-reference conversion without changing free prose.
- Frontmatter conversion removes `allowed-tools` and preserves required metadata.
- Builtin/workflow phrase conversions for every row in section 6.4.
- C0-C8 pass and fail fixtures.
- TOML escaping for quotes, apostrophes, Windows paths, Unicode, and multiline bodies.
- Complete token-free HTTP and stdio custom-agent transport rendering, including disabled
  authenticated HTTP servers and refusal of an enabled authenticated target.
- Catalog-derived static and verifier allowlists.
- Unsupported SSE targets are omitted with the exact recorded reason.
- Ownership-marker refusal and scoped orphan removal.

### 13.2 Integration tests

- Phase 4 names and calls both Claude and Codex generators.
- Phase 5 produces set-equal Claude and Codex skill names from a mixed enabled/disabled
  fixture.
- A second complete run is byte-idempotent.
- `-WhatIf` creates no Codex artifact.
- `-VerifyOnly` fails when `AGENTS.md`, one skill, or one custom agent is missing.
- `-VerifyOnly` fails when a verifier TOML file grants a write tool.
- Main and standalone installers use the same Codex workspace functions.
- Existing MCP-only Codex configuration upgrades without losing unrelated user TOML.
- An unmanaged `.agents` skill or custom agent survives install and cleanup.

### 13.3 Live acceptance

- `codex --strict-config -C C:\re\agent` starts without a configuration error.
- A fresh session discovers the contract, skills, and custom agents listed in section
  9.2.
- Direct calls still succeed for Binary Ninja, pyghidra, mcp-windbg, and an open
  x64dbg host.
- Closing x32dbg does not prevent Codex startup.

The full existing Pester suite and PSScriptAnalyzer error/warning pass remain required.

---

## 14. Implementation sequence

1. Preserve the recorded failed partial-table measurement and implement complete, token-free
   custom-agent transport rendering from `ServerResults`.
2. Add pure namespace, frontmatter, prose, and TOML conversion helpers with failing
   tests first.
3. Split the instruction template into common and client tails; prove the existing
   Claude behavioral contract is preserved.
4. Generate and gate `AGENTS.md`.
5. Extend skill installation to stage and atomically install the Codex view.
6. Generate Codex custom-agent TOML from config plus catalog classification.
7. Add C0-C8 to shared verification and process-exit handling.
8. Add manifest reporting and standalone `install-codex.ps1` support.
9. Update README, MVP, Codex, and operator handoff documentation.
10. Run unit, integration, idempotency, `WhatIf`, static-analysis, and live attended
    acceptance checks.

No implementation step may weaken an existing Claude gate to make dual generation
easier. Client-specific failures are reported separately so one client cannot falsely
make the other appear healthy.

---

## 15. Final parity boundary

When this design is complete, instructions, the eleven reviewed skills, the two
enabled specialist roles, supported MCP access, verification, and manifest reporting
will have Codex equivalents.

Two platform differences remain explicit:

1. Codex specialists use `sandbox_mode` plus per-server `enabled_tools`; Claude agents
   use their `tools:` frontmatter. The mechanisms differ, but both grants are derived
   from the same catalog and checked against the same classification.
2. Claude can still reach `pdbsql` and `ghidrasql` through their installed legacy SSE
   transports. Codex cannot reach them until those servers add Streamable HTTP/stdio or
   the project installs a reviewed bridge.

Those are recorded capability differences, not silent parity failures.
