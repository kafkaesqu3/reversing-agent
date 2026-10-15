# Kuna decompiler — design

**Status:** design, approved 2026-10-12. Based on `main` (`95da7cc`), which carries the MVP,
skills vendoring, agent topology, the SQL query layer, Codex parity and runtime prerequisites.

Companion to `2026-09-07-agent-topology-design.md` (grants and the A0–A4 gate),
`2026-09-06-skills-vendoring-design.md` (how a third-party skill enters this repo) and
`2026-09-14-codex-parity-design.md` (what Codex can load). This slice adds a **second,
independent decompiler** and the workflows for using its output.

---

## 1. Goal

Install [Kuna](https://github.com/Noelo-Lab/kuna) — an agent-first decompiler written in Rust,
ported from Ghidra's decompiler and reworked toward angr's pipeline — natively on the FLARE VM,
expose it to Claude Code and Codex through a stdio MCP server that lives in this repo, and give
the agents defined workflows for reading what it produces.

### 1.1 Why now

**A second decompiler is the verifier's missing oracle.** Every static read today comes from
Ghidra, through `pyghidra-mcp` or `ghidrasql`, both backed by the same decompiler core. When the
verifier re-reads a function it re-reads the same engine's opinion. Kuna shares Ghidra's
ancestry but has diverged heavily (its `docs/history.md` lists over 140 divergences, many of
them Windows-PE-specific: `peimportcall`, `win32sigs`, `msvcstackguard`, `fastfailnoreturn`,
`rtti`, `pdb`). Where the two disagree, the disagreement itself is the finding: something about
widths, signedness, calling convention or control flow is uncertain and must be settled
against assembly.

**It is built for agents.** Whole-binary export to searchable files, a streaming index with
byte offsets, symptom-indexed options an agent can flip per function, and JSON on every
subcommand. That is the "push filters down, don't pull functions into context" tactic
(BLUEPRINT §5 (d)) that motivated the SQL layer, applied to decompiled text.

**It is fast enough to export everything up front.** `/bin/ls` (154 KB, 136 functions)
exported in 0.54 s wall-clock (§3.3). Upstream reports a 19 MB binary in under three minutes.

### 1.2 Out of scope

- **Kuna as Ghidra's decompiler core** (the `KunaDecompiler` extension). It would silently
  change what `pyghidra-mcp` and `ghidrasql` return and destroy the independence that is the
  point of this slice. The extension is also GUI-plugin-activated, so headless `pyghidra-mcp`
  would not pick it up without an `exepath` reflection hack.
- **`--assert` feedback** (replaying confirmed names and types into later decompiles). Deferred
  by decision; see §11 gap 1.
- **WSL.** Native `kuna.exe` first. WSL1 with the `linux-x86_64-musl` build is the documented
  fallback if native fails verification (§9.3), not something this slice builds.
- **`pwn2dav/kuna_mcp`** (third-party MCP wrapper, 0.1.0). Builds Kuna from source with a Rust
  toolchain, exposes neither `decompile-all` nor `decompile-project`, and its schemas are
  declared unstable. Rejected; see KD1.
- **`kuna install-skill`.** It writes to user-level agent directories and bypasses the vendoring
  review gate. The skill enters through the skills pipeline instead (KD7).
- **`decompile-graph`, `kuna docs`, `kuna specs`, `kuna test`.** Not exposed. `decompile-graph`
  is a single document holding every body — the opposite of what an agent context wants.
- **A dedicated `kuna-analyst` agent.** Decided against; Kuna joins the existing agents (KD6).

### 1.3 Definition of done

1. Both pinned release assets are downloaded, SHA-256-verified, and expanded to
   `C:\re\kuna\v1.808\`; a re-run downloads and rewrites nothing.
2. The `kuna` MCP server answers a real `kuna_triage` call against the test binary
   (`C:\Windows\System32\winver.exe`) with a non-zero function count — unattended, through
   `-VerifyOnly`, with no prior run in the session.
3. The install-time export self-test (§9.2) completes against the test binary with zero failed
   functions at the configured `jobs` value.
4. `static-analyst` and `verifier` are regenerated with their Kuna grants and pass A0–A4; the
   verifier's grant contains no `write` tool.
5. Codex lists the `kuna` server (stdio is a supported transport) and the regenerated
   `.codex/agents` files carry the same grants.
6. The vendored `kuna` skill pack passes the five adaptation checks and carries a human
   sign-off in `PROVENANCE.json`.
7. `Invoke-Pester -Path tests/` passes, zero PSScriptAnalyzer findings; in
   `tools/kuna-mcp/`, `pytest -q`, `ruff check`, `ruff format --check` and `ty check` are clean.

---

## 2. Locked decisions

| # | Decision | Rationale |
|---|---|---|
| KD1 | **Our own stdio MCP wrapper, in this repo, over the pinned native CLI** | Topology §4 forbids `Bash` to every agent, so the CLI-plus-skill model Kuna recommends is unavailable. The only third-party wrapper is immature and lacks export (§1.2). stdio is supported by both Claude Code and Codex, so there is no SSE-style parity gap. |
| KD2 | **A new install `kind`: `native-cli-stdio`** | None of the six existing kinds describes "pinned native binary + local wrapper package, spawned on demand". `Install-VenvStdioServer` is hard-wired to `mcp-windbg`'s `cdb.exe` resolution. The dispatcher stays generic (SQ2's precedent). |
| KD3 | **Pin `v1.808`, both assets hashed; upgrades are deliberate config edits** | Kuna releases almost daily (v1.784, v1.785, v1.808 on three consecutive days). An unpinned "latest" would change decompiler output mid-case. |
| KD4 | **`Get-VerifiedRelease` accepts N assets, verifies all before expanding any** | Kuna ships the engine and the SLEIGH specs as separate assets. The current one-asset rule throws. Fail-closed ordering (skills §4.4) applies: nothing is expanded until every hash matches. |
| KD5 | **Native Windows, not WSL** | The official `windows-x86_64` build exists (MSVC, built on a Windows runner). WSL2 needs nested virtualisation inside the FLARE guest and adds a NAT'd network path to an isolated lab. Native is verified first; WSL1 is a recorded fallback (§9.3). |
| KD6 | **Kuna joins `static-analyst` (all tools) and `verifier` (read tools); no new agent** | Operator decision. The verifier gains an independent decompiler, which is the main reason this slice exists. |
| KD7 | **Kuna's own skill is vendored and adapted, pinned to the release tag's commit** | The skill is written for the CLI (`kuna decompile-project …`); adaptation retargets it to MCP tool names. Pinning to the tag commit keeps skill and binary in lockstep. |
| KD8 | **Export is asynchronous and lands in the case folder** | A 3 MB PE took 445 s upstream (§3.4); an MCP call that blocks that long times out. The export runs detached; agents read the streaming index as it fills. |
| KD9 | **Every path the wrapper touches is checked against configured roots** | The wrapper reads arbitrary paths and writes exports. An unchecked `binary` or `case_dir` argument is path traversal driven by model output, which is driven by binary content (the trust boundary). |
| KD10 | **No `Bash` is added anywhere** | Topology §4 stands. Everything the skill does through a shell maps to an MCP tool or to `Read`/`Grep`/`Glob` over the export. |

---

## 3. The measurement that grounds this

Measured 2026-10-12 on the development Mac with the `macos-arm64` build of the same release.
The FLARE VM measurement is the first implementation task (§12); where Windows could differ, it
is called out.

### 3.1 The release

Tag `v1.808` (published 2026-10-12T14:39Z), commit `ccdf0844750b1dd93e73e3fe6a4353576d0d7da3`.

| Asset | Bytes | SHA-256 |
|---|---:|---|
| `kuna-v1.808-windows-x86_64.zip` | 15,665,701 | `c1ad69e43ee87e36c6ff7be2c917b060308d74a42ecd6820cf6c8998887bb4af` |
| `kuna-v1.808-specs.tar.gz` | 12,982,457 | `33566cb4b574e9252f1de2f12e737953804c7f90a09ced23d074d804f53eb04d` |

The Windows zip holds one directory, `kuna-v1.808-windows-x86_64\`, containing `kuna.exe`
(23.1 MB), `decomp_dbg.exe` (17.4 MB), `slacomp.exe` (1.1 MB), `LICENSE` (Apache-2.0) and
`NOTICE`. The specs archive expands to a `specs\` tree of 28 MB. `kuna` finds `decomp_dbg`
beside itself; it finds the specs through `KUNA_SPECS`.

### 3.2 JSON shapes

`kuna functions <bin> --summary --json` returns `binary`, `count`, `total`, `error`,
`warnings[]` (header repairs, e.g. a clamped PE `NumberOfRvaAndSizes`), and `summary` with
`entry`, `main`, `reachable_from_entry`, `no_callers`, `code_bytes`, `size_buckets[]`,
`largest[]` and — when applicable — `runtime[]` naming a PyInstaller, Nuitka, .NET, UPX,
AutoIt, VB6 or twinBASIC image and the tool to use instead. 0.07 s on `/bin/ls`.

`kuna decompile-all <bin> --json --functions main` returns `binary`, `language`, `count`,
`error`, `functions[]`, `assertions`. Each function carries `name`, `address`, `address_hex`,
`aliases`, `size`, `code`, `error`, `unstructured_gotos`, `variables`, `types` and
**`line_mappings`**. For `/bin/ls`'s `main`, `code` was 11,915 characters; `line_mappings`
added another 11,772 bytes (216 records of decimal addresses) and `variables` 3,777 — the
payload more than doubles for no reading value. **The wrapper must drop `line_mappings`,
`variables` and the decimal `address`** (§6.3).

`kuna catalog --json` returns a list of 291 options, each with `option`, `values`, `default`,
`phase`, `summary`, `use_when` and `example`.

### 3.3 The export layout

`kuna decompile-project /bin/ls --stream --jobs auto -o ls.kuna` took 0.54 s and wrote:

| File | Bytes | Role |
|---|---:|---|
| `index.jsonl` | 14,067 | One record per function: `seq`, `name`, `addr` (hex string), `size`, `c_offset`, `c_len`, `error` |
| `ls.c` | 77,322 | **All** function bodies in one file, each under `// Function: <name> @ <addr>` |
| `ls.h` | 6,165 | Prototypes and recovered types |
| `ls.asm` | 313,046 | Disassembly and data, labelled `<name>:  ; <addr>` |
| `README.md` | 3,734 | Architecture, entry, section table, success/failure counts |

Files are named after the binary's stem, not per function. `c_offset`/`c_len` are **byte**
offsets into the `.c` file; slicing `ls.c` at `main`'s record yields exactly the block starting
`// Function: main @ 0x100000978`. `Grep` for `// Function: main ` finds the same block by line.
A `.streaming` marker file exists while the export runs and is removed on completion.

### 3.4 Scale reference (upstream, not measured here)

Kuna's `docs/modes.md` reports a 3,457,296-byte PE under the default `auto` mode (which selects
`fast` at ≥ 2 MiB): 445.06 s, 1,476 MiB peak RSS, 3,140 bodies, 13 isolated failures. This is
the number that makes KD8 necessary and that sizes the VM's memory expectation.

### 3.5 Windows-specific risk

Upstream CI runs every test suite on Ubuntu. The Windows build receives only a
`kuna --version` smoke test before release. `--jobs` worker pools, `--stream`, the
per-function watchdog and long paths are untested on Windows upstream. The only
`#[cfg(unix)]` code in `kuna-cli` hardens scratch-directory permissions to `0700`; on Windows
the scratch directory inherits `%TEMP%`'s ACL, acceptable on a single-operator VM. The §9.2
self-test exists to catch the rest on this host.

---

## 4. Architecture

```
re-agent.config.json ──► Install-REAgent.ps1
                           │ phase: servers  (kind native-cli-stdio)
                           │   Get-VerifiedRelease (2 assets) ─► C:\re\mcp\downloads\
                           │   Expand-KunaRelease            ─► C:\re\kuna\v1.808\{kuna.exe,…,specs\}
                           │   Install-KunaWrapper (uv venv)  ─► C:\re\mcp\venvs\kuna\
                           │   Test-KunaExport (self-test)   ─► C:\re\scratch\kuna-selftest\
                           │ phase: generate ─► .mcp.json / .codex/config.toml  (stdio + args + env)
                           │ phase: agents   ─► static-analyst, verifier (+ kuna grants)
                           │ phase: skills   ─► vendor/skills/kuna/kuna-decompiler (adapted)
                           ▼
Claude Code / Codex ──stdio──► python -m kuna_mcp --kuna … --specs … --allow-root …
                                  │ subprocess per call (timeout, output cap)
                                  ▼
                               kuna.exe ─► decomp_dbg.exe (+ worker pool)
                                  │ export (detached)
                                  ▼
                               C:\re\agent\cases\<slug>-<hash>\kuna\<binary>\
                                  index.jsonl  <stem>.c  <stem>.h  <stem>.asm  README.md
                                  ▲
               agents: Read / Grep / Glob, and kuna_export_read
```

The wrapper holds no state between calls. Kuna saves no analysis state between invocations
either; every read call re-loads the binary. That is cheap for triage-sized calls (0.07 s on
`/bin/ls`) and is why bulk reading goes through the export, not repeated `kuna_decompile`.

---

## 5. Installer

### 5.1 Config entry

```jsonc
{
  "name": "kuna",
  "enabled": true,
  "kind": "native-cli-stdio",
  "source": {
    "type": "github-release",
    "repo": "Noelo-Lab/kuna",
    "pin": "v1.808",
    "sha256": {
      "kuna-v1.808-windows-x86_64.zip":
        "c1ad69e43ee87e36c6ff7be2c917b060308d74a42ecd6820cf6c8998887bb4af",
      "kuna-v1.808-specs.tar.gz":
        "33566cb4b574e9252f1de2f12e737953804c7f90a09ced23d074d804f53eb04d"
    }
  },
  "wrapper": { "path": "tools/kuna-mcp", "lock": "tools/kuna-mcp/requirements.lock" },
  "transport": "stdio",
  "bind": "127.0.0.1",
  "port": 0,
  "auth": "none",
  "authExemptReason": "stdio child of the client; no listening socket",
  "allowRoots": ["C:\\re\\samples", "C:\\re\\agent\\cases"],
  "allowFiles": ["C:\\Windows\\System32\\winver.exe"],
  "jobs": "auto",
  "callTimeoutSeconds": 300,
  "maxResponseBytes": 48000,
  "requiresHostApp": false,
  "verifyTier": "unattended",
  "verify": {
    "tool": "kuna_triage",
    "args": { "binary": "C:\\Windows\\System32\\winver.exe" },
    "expect": "\"count\":\\s*[1-9]"
  }
}
```

`allowRoots` follows the existing layout: `C:\re\samples` is the ingest store
(DEPLOYMENT_PLAN §"samples"), and `C:\re\agent\cases` is where the operating contract's
relative `cases/<slug>-<shorthash>/` resolves, because both clients run with `C:\re\agent` as
their working directory. `allowFiles` admits the test binary without opening `System32`.
Config validation (`ReAgent.Config`) rejects a `native-cli-stdio` entry with an empty
`allowRoots`, a non-absolute root, a `jobs` value other than `auto` or a positive integer, or
a `sha256` map whose keys do not all start with `kuna-<pin>-`.

### 5.2 `Get-VerifiedRelease` with N assets

The one-asset rule becomes "at least one". The function downloads every missing asset, hashes
every asset, and only then returns a map of asset name → verified path. A mismatch on any
asset throws before any caller expands anything. `PIN-ME` handling (record-the-computed-hash
hint) is unchanged and per asset. Existing single-asset callers (`pdbsql`, `ghidrasql`,
`x64dbg`) receive a one-entry map; they are updated to index it, and their tests are the
regression check.

### 5.3 `Install-NativeCliStdioServer`

1. `Get-VerifiedRelease` → two verified archives.
2. **Expand** to `C:\re\kuna\v1.808\` via a staging directory (`v1.808.partial\`) renamed into
   place only after both archives expand cleanly. The zip's single top-level directory is
   flattened; `specs.tar.gz` is expanded with the in-box `tar.exe`. If `v1.808\` already
   exists and its `kuna.exe --version` prints `kuna 1.808`, expansion is skipped.
3. **Wrapper venv** at `Get-ServerVenvPath -Name kuna`:
   `uv pip install --require-hashes -r tools/kuna-mcp/requirements.lock`, then
   `uv pip install --no-deps tools/kuna-mcp`. Non-editable, so the venv does not depend on the
   repo checkout at runtime. Skipped when the installed `kuna-mcp` version equals the
   `pyproject.toml` version and the lock file's hash matches the one in the manifest.
4. **Self-test** (§9.2).
5. Return `New-ServerResult` with `Status installed`, `Version 1.808`, and `Command`:

```text
C:\re\mcp\venvs\kuna\Scripts\python.exe -m kuna_mcp
  --kuna C:\re\kuna\v1.808\kuna.exe
  --specs C:\re\kuna\v1.808\specs
  --expect-version 1.808
  --allow-root C:\re\samples --allow-root C:\re\agent\cases
  --allow-file C:\Windows\System32\winver.exe
  --cases-root C:\re\agent\cases
  --jobs auto --timeout 300 --max-bytes 48000
```

Arguments, not environment, carry configuration; `KUNA_SPECS` is set in `env` as well because
`kuna.exe` reads it and the wrapper passes it through to every child. `.mcp.json` and Codex's
`config.toml` already render `command`, `args` and `env` (`ReAgent.Generate`,
`ReAgent.CodexAdapter`).

Old version directories (`C:\re\kuna\v1.785\`, …) are not deleted; the manifest records which
one is live. Deleting is the operator's call.

### 5.4 Manifest

The `kuna` server record carries: `pin`, both asset hashes, the expanded root, `kuna --version`
output, the wrapper version, the lock-file hash, the vendored skill's commit and tree hash, and
the self-test result (`jobs` used, function count, failed count, seconds).

---

## 6. The MCP server (`tools/kuna-mcp/`)

### 6.1 Package

Python 3.13, `uv`, `uv_build`. One runtime dependency: `mcp==2.3.0` (current stable on
2026-10-12), locked with hashes in `requirements.lock` (`uv export --format requirements-txt`).
Layout: `src/kuna_mcp/{__main__.py, server.py, runner.py, paths.py, shape.py, export.py}` and
`tests/` mirroring it. `runner.py` is the only module that spawns processes.

### 6.2 Tools

All addresses in and out are hex strings (operating contract). `binary` is an absolute path.
`targets` entries are a function name or a `0x…` address; the wrapper routes `0x…` entries to
`--addr` and names to `--functions`.

| Tool | Level | Wraps | Arguments | Returns |
|---|---|---|---|---|
| `kuna_triage` | read | `functions --summary --json` | `binary` | Summary verbatim, minus decimal addresses; `runtime[]` and `warnings[]` always present |
| `kuna_functions` | read | `functions --json` | `binary`, `filter?`, `min_size?`, `reachable_from?`, `sort?`, `offset=0`, `limit=200` | `name`, `address_hex`, `size`, `aliases` per row; `total`, `next_offset` |
| `kuna_decompile` | read | `decompile-all --json` | `binary`, `targets[1..20]`, `mode?`, `options?{name: value}`, `language?` | Per function `name`, `address_hex`, `code`, `error`, `unstructured_gotos` |
| `kuna_disassemble` | read | `disassemble --json` | `binary`, `target` (name, `0x…` or `0xS-0xE`), `count?`, `follow?` | Instructions |
| `kuna_read` | read | `read --json` | `binary`, `target`, `bytes?`, `as?` | Bytes / typed data |
| `kuna_xrefs` | read | `xrefs --json` | `binary`, exactly one of `to`/`from`, `kind?` | References |
| `kuna_strings` | read | `strings --json` | `binary`, `filter?`, `encoding?`, `min_length?` | Strings with owning functions |
| `kuna_crypto` | read | `crypto --json` | `binary`, `algorithm?` | Constants with using functions |
| `kuna_options` | read | `catalog --json` | `query` (symptom text) | Options whose `option`, `summary` or `use_when` match (case-insensitive substring), at most 15: `option`, `values`, `default`, `summary`, `use_when` |
| `kuna_export` | write | `decompile-project --stream` | `binary`, `case_dir`, `overwrite=false` | `export_dir`, `state` (`started`/`running`/`complete`), and the paths to read |
| `kuna_export_read` | read | — (file slice) | `export_dir`, `function` (name or `0x…`), `part=c\|asm` | That function's block, `error` from the index, or "not yet exported" while streaming |
| `kuna_unpack` | write | `unpack -o` | `binary`, `case_dir` | Unpacked path, written under `case_dir\unpacked\` |

`kuna functions` has `--limit` but no offset, so `kuna_functions` pages by slicing the full
result in the wrapper. `kuna_decompile`'s 20-target cap and `kuna_functions`' paging keep any one response bounded
before the byte cap applies. `options` names are validated by Kuna itself (unknown name → exit
2 with a "did you mean"); the wrapper relays that message verbatim.

### 6.3 Shaping and caps (`shape.py`)

- Drop `line_mappings`, `variables`, `types`, and every decimal `address` field; keep
  `address_hex`.
- Serialise compactly. If the result exceeds `maxResponseBytes`, truncate at a record boundary
  (never mid-function), set `truncated: true`, and add a `hint` naming the narrower call or the
  export (`kuna_export` then `kuna_export_read`).
- Kuna's stderr is returned as `diagnostics[]` (lines), capped at 40, so header-repair and
  build-mismatch warnings reach the agent.

### 6.4 Paths (`paths.py`)

Every `binary`, `case_dir` and `export_dir` argument is resolved (`Path.resolve(strict=True)`,
which also resolves junctions and symlinks) and must equal an `--allow-file` entry or sit
inside an `--allow-root` entry, compared case-insensitively on Windows. `case_dir` and
`export_dir` must additionally be inside `--cases-root`. A rejected path returns an error
naming the argument and the allowed roots, never a partial result. UNC and device paths
(`\\?\`, `\\.\`) are rejected outright.

### 6.5 Running Kuna (`runner.py`)

- `subprocess.run` with an argument list (never a shell), `KUNA_SPECS` in the child
  environment, `cwd` set to a per-call temp directory, and `--timeout` enforced: on expiry the
  process tree is killed (`taskkill /T /F` on Windows) and the tool returns an error naming the
  timeout and the remedy (fewer targets, `mode: fast`, or the export).
- Non-zero exit returns an error carrying the exit code and Kuna's own stderr. Kuna's exit
  codes are documented per subcommand (`0` ok, `1` work failed, `2` usage); the wrapper does not
  reinterpret them.
- Startup check: `kuna --version` must print `kuna <expect-version>`; otherwise the server
  exits non-zero with both versions in the message. A pin edit without a re-install therefore
  fails loudly instead of silently pairing new config with an old binary.

### 6.6 Export (`export.py`)

`kuna_export` resolves `export_dir = <case_dir>\kuna\<binary file name>\`.

| State on disk | Action |
|---|---|
| No `export_dir` | Spawn `kuna decompile-project <binary> --stream --jobs <jobs> -o <export_dir>` detached (`DETACHED_PROCESS \| CREATE_NEW_PROCESS_GROUP`), stdout/stderr to `export_dir\..\<name>.export.log`. Return `started`. |
| `.streaming` present | Return `running` with the indexed-function count so far. Never spawn a second export into the same directory. |
| `index.jsonl` present, no `.streaming` | Return `complete` with ok/failed counts from `index.jsonl`, unless `overwrite=true`. |

The export survives the wrapper exiting — a client may restart the stdio server mid-export.
Whether an export that dies leaves `.streaming` behind is unknown; if it does, `running` would
be reported forever. The wrapper therefore records the child PID in
`<name>.export.pid` and reports `failed` with the log tail when `.streaming` exists but the PID
is gone.

`kuna_export_read` reads only newline-terminated `index.jsonl` records (the last record may be
partial while streaming, per Kuna's skill), finds the function by name or `addr`, and slices
`<stem>.c` by `c_offset`/`c_len`. `part=asm` locates the `<name>:  ; <addr>` label in
`<stem>.asm` and returns through the next label, capped by `maxResponseBytes`.

---

## 7. Tool catalog and classification

`-UpdateToolCatalog` captures the `kuna` server's `tools[]` unattended (stdio is probeable
without a host app). The classification is hand-authored:

```jsonc
"kuna": {
  "pin": "v1.808",
  "toolCount": 12,
  "tools": [ /* captured */ ],
  "classification": {
    "classifiedTools": [ /* all 12 */ ],
    "write": [ "kuna_export", "kuna_unpack" ],
    "destructive": []
  }
}
```

Both `write` tools create files only under `cases\`, and neither changes analysis state, but
they do write to disk, so the verifier must not hold them. A4 makes a future Kuna-wrapper
tool addition stop the gate until it is classified.

---

## 8. Agents, skill and workflows

### 8.1 Grants

| Agent | Adds |
|---|---|
| `static-analyst` (`write`) | `kuna` → all 12 tools |
| `verifier` (`read`) | `kuna` → the 10 `read` tools |
| `dynamic-analyst` | nothing |

`targetServers` gains `kuna` for both. The static-analyst template's "no Bash" limitation
paragraph stays; it gains one line: Kuna is reached through the `kuna_*` tools, and its export
through `Read`/`Grep`/`Glob`.

### 8.2 The vendored skill

```jsonc
{
  "namespace": "kuna",
  "enabled": true,
  "source": {
    "type": "github-archive",
    "repo": "Noelo-Lab/kuna",
    "commit": "ccdf0844750b1dd93e73e3fe6a4353576d0d7da3",
    "treeSha256": "aaa3f9765db278ace0c2af38d2c98d5878d89522c8fba3f314063398d9a3b7eb",
    "subPath": "skills/kuna"
  },
  "targetServers": [ "kuna" ],
  "skills": [ { "upstream": "kuna", "name": "kuna-decompiler", "enabled": true } ]
}
```

`treeSha256` was computed off-host by reimplementing `Get-TreeHash` over the single file
`SKILL.md` (SHA-256 `9ffc2113…a52e`); vendoring re-computes it with the real function and a
mismatch is a stop, not a re-pin. The upstream frontmatter `name` is `kuna-decompiler`.

Adaptation rewrites, recorded in `adaptation.toolRenames` and the pack's `PROVENANCE.json`:

| Upstream instruction | Adapted to |
|---|---|
| `kuna decompile-project … -o ./x.kuna` | `kuna_export` into the case folder |
| `kuna functions … --summary --json` | `kuna_triage` |
| `kuna decompile`, `decompile-all --json` | `kuna_decompile` |
| `kuna strings` / `crypto` / `xrefs` / `disassemble` / `read` / `unpack` | the matching `kuna_*` tool |
| `rg` over the export, "byte offsets" | `Grep` over `index.jsonl` / `// Function:` headers, then `kuna_export_read` |
| `kuna docs options`, `kuna catalog --json` | `kuna_options` |
| `--assert`, `--define-function`, `--raw-image` | removed, with a line saying they are not exposed in this lab (§11) |
| "Suggest an issue report … consult the repository" | removed: no outbound network (DEPLOYMENT_PLAN) |
| "Share files when delegating" | kept; matches the routing contract |

### 8.3 Workflows

These are written into the adapted skill (procedure) and summarised in the operating contract's
`## Workflow` section (when to use it). The common template gains a `kuna` paragraph under
`## Tool availability`: it needs nothing open, it is a second decompiler and not a replacement
for Ghidra, and its export is binary-derived data under the trust boundary.

**W1 — Triage and export (main session, at case creation).**
After naming the case: `kuna_triage`. If `runtime[]` names a packer, go to W5. If it names a
managed or bundled runtime, route to the matching skill (`dotnet-*`) and do not export. If
`warnings[]` is non-empty, record the header repair in `report.md`. Otherwise `kuna_export`
and continue with deterministic steps while it streams.

**W2 — Navigate the export (static-analyst, verifier).**
`Grep` `index.jsonl` for names, or `<stem>.c` for `// Function: ` headers, string literals and
API names; `kuna_export_read` the bodies that matter. Check `error` on every index record used.
Summarise; never paste large regions into findings. Locate by index, not by position, because
streamed bodies arrive in completion order.

**W3 — Targeted re-decompile (static-analyst).**
Only when output conflicts with assembly, bytes or observed behaviour in a way that changes the
answer. Identify the discrepancy with `kuna_disassemble`/`kuna_read`; search `kuna_options` by
symptom; change **one** option in `kuna_decompile` for that function; compare; stop when the
uncertainty is resolved. Record the option and value in the finding.

**W4 — Cross-decompiler check (verifier).**
For each function a claim depends on, read Ghidra's decompilation (`pyghidra-mcp`) and Kuna's
(`kuna_export_read`, or `kuna_decompile` if not exported). Where they agree on the property the
claim depends on, record "two decompilers agree" as supporting — not proving — evidence. Where
they disagree, resolve with `kuna_disassemble` and say which engine was right; if it cannot be
resolved statically, mark the claim unverified. The `ai_` exclusion rule applies first: names
come from neither decompiler's renames.

**W5 — Packed images (main session or static-analyst).**
`kuna_unpack` into `case_dir\unpacked\`, `kuna_triage` the result, then W1 against the unpacked
file. Record the original and unpacked SHA-256s in `report.md`.

---

## 9. Verification

### 9.1 Tier 1 (unattended, every `-VerifyOnly`)

The standard MCP probe (`tools/mcp_probe.py` over stdio) calls `kuna_triage` on
`winver.exe` and matches `"count":\s*[1-9]`. Replays from the manifest with no prior run.

### 9.2 Install-time export self-test

`Test-KunaExport` runs `kuna.exe decompile-project winver.exe --stream --jobs <jobs>` directly
into `C:\re\scratch\kuna-selftest\` with a 300 s limit, then asserts: exit 0, no `.streaming`
left, `index.jsonl` non-empty, and zero records with a non-null `error`. Run once per pin/jobs
combination; the result is cached in the manifest so a re-run does not repeat it.

If it fails with `jobs` = `auto`, the installer re-runs it with `--jobs 1`. If that passes, the
install **fails** with a message stating that the worker pool is broken on this host, that
setting `"jobs": 1` in the `kuna` entry is the fix, and that the operator should re-run. It does
not silently downgrade: a config value that differs from the behaviour would hide the fault.

### 9.3 If native Windows fails

If `--jobs 1` also fails, the install fails naming the WSL1 fallback: enable WSL1 (no nested
virtualisation needed), use the `linux-x86_64-musl` asset, and have the wrapper invoke
`wsl.exe -e` with path translation. That is a new slice with its own spec, opened only on this
evidence.

---

## 10. Testing

**Pester** (`tests/`):
- `Get-VerifiedRelease`: two assets, one mismatched → throws, neither expanded; one `PIN-ME` →
  throws with the computed hash; single-asset callers unchanged.
- `Install-NativeCliStdioServer`: second run with matching version and lock hash performs no
  expand, no venv install, no self-test (idempotency, asserted via mocks on the expand,
  `uv` and self-test seams); a partial staging directory is discarded, never renamed.
- Config validation rejects: empty `allowRoots`, relative root, `jobs: 0`, an asset key not
  prefixed `kuna-<pin>-`.
- Generation: `.mcp.json` and Codex `config.toml` render the exact `command`/`args`/`env`.
- Gate: verifier granted `kuna_export` → **A3**; a new wrapper tool not in `classifiedTools` →
  **A4**.

**pytest** (`tools/kuna-mcp/tests/`), mocking only the `kuna` process boundary:
- A fake `kuna` script records argv and replays captured fixtures (the `/bin/ls` JSON from
  §3.2–3.3 is checked in as fixture data).
- Argument building: `0x…` targets → `--addr`, names → `--functions`; `options` → repeated
  `--option N V`; `to` and `from` both given → error.
- Shaping: `line_mappings`/`variables`/decimal addresses absent; truncation lands on a record
  boundary and sets `truncated`.
- Paths: `..` escape, symlink/junction out of root, UNC path, `case_dir` outside `cases-root`
  → rejected with the argument named.
- Runner: timeout kills the child and returns the remedy; non-zero exit relays stderr;
  version mismatch at startup exits non-zero.
- Export state machine: absent → `started`; `.streaming` → `running`; complete → counts;
  `.streaming` with dead PID → `failed`; partial last index line ignored.
- **Integration** (marked, skipped when `KUNA_BIN` is unset): the real release binary against a
  small checked-in PE fixture compiled with mingw — one triage, one decompile, one export.

---

## 11. Known gaps and deliberate divergences

| # | Gap | Disposition |
|---|---|---|
| 1 | **No `--assert` feedback.** Confirmed names and types do not flow back into Kuna's output, so Kuna keeps printing `sub_…`/`v1` where Ghidra has been annotated. | Deferred by decision. When added, only non-`ai_` facts may be asserted, and `--assert` forces `--jobs 1` and no `--stream`. |
| 2 | **`--define-function` and `--raw-image` are not exposed.** Headerless firmware and missed function entries cannot be fixed through the wrapper. | This lab is Windows-PE-focused. Add as arguments to `kuna_decompile`/`kuna_export` when a case needs them. |
| 3 | **Windows parallel export is unproven upstream.** | §9.2 tests it on this host before the server is reported installed. |
| 4 | **Every read call re-loads the binary.** Large binaries make `kuna_xrefs`/`kuna_strings` slow. | W2 directs bulk reading to the export; the per-call timeout bounds the damage. A persistent `decomp_dbg` session is a later optimisation. |
| 5 | **Pin drift.** Upstream moves daily; this pin will be weeks old quickly. | Upgrade is a config edit of `pin` and both hashes, a matching skill `commit`/`treeSha256`, a tool-catalog refresh, and a re-run. The startup version check catches a half-done upgrade. |
| 6 | **Export disk use.** `.asm` is about 4× the `.c` (§3.3). | Accepted; exports live with the case and are deleted with it. |
| 7 | **`treeSha256` computed off-host** (§8.2). | Re-computed by `Get-TreeHash` during vendoring; a mismatch stops the pack. |

---

## 12. Implementation order

1. **Measure on the VM.** Expand v1.808 by hand; run `functions --summary --json`,
   `decompile-project --stream --jobs auto`, then `--jobs 1`, against `winver.exe` and one
   real sample. Record results in this spec's §3 as an addendum. If native fails, stop (§9.3).
2. `Get-VerifiedRelease` N-asset change and its regression tests.
3. `tools/kuna-mcp` package, tests first, against fixtures.
4. `native-cli-stdio` kind, expansion, venv, self-test, manifest.
5. Generation (`.mcp.json`, Codex), tool-catalog capture and classification.
6. Agent grants and template lines; gate run.
7. Vendor and adapt the skill; workflows into skill and operating contract; human sign-off.
8. Elevated end-to-end run on the VM; `-VerifyOnly`; Codex `/mcp` listing.

---

## 13. References

- Kuna — `github.com/Noelo-Lab/kuna` (Apache-2.0), release `v1.808`;
  `docs/cli.md`, `docs/modes.md`, `docs/ghidra-integration.md`, `skills/kuna/SKILL.md`
- Kuna release post — `noelo.org/blog/kuna-release/`
- `pwn2dav/kuna_mcp` — considered and rejected (§1.2)
- MCP Python SDK — PyPI `mcp` 2.3.0
- This repo: topology §4–§8, skills vendoring §4 and §8, SQL layer SQ2/SQ3, Codex parity spec
