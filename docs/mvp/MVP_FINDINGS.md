# MVP Findings — Host Inventory and Resolved Open Items

**Date:** 2026-09-04 · **Host:** the target FLARE VM itself (VMware20,1)

Everything below was measured on the host or fetched from upstream, not assumed.
It supersedes the ⚠️ **VERIFY** and **DISCOVER** placeholders in `MVP_SPEC.md`.
Items marked **DEVIATION** contradict the spec and need a decision before coding.

---

## 1. Host inventory (measured)

| Component | Found | Notes |
|---|---|---|
| OS / PowerShell | Windows 11, **PS 5.1.26100.9168** | Meets the 5.1 baseline |
| Virtual machine | **Yes** — `VMware20,1` / `VMware, Inc.` | `Win32_ComputerSystem.Model` detection works |
| RAM | **8 GB** | ⚠️ Spec warns under 32 GB. Ghidra + BN + debugger + agent co-resident on 8 GB is tight |
| Free disk (C:) | 60.1 GB | Fine |
| Elevation | **Not elevated** in the current shell | Script must be re-launched elevated |
| Python | `C:\Python313\python.exe` — **3.13.15** | Chocolatey shim at `C:\ProgramData\chocolatey\bin\python.exe` resolves first on PATH. `py -0p` lists only 3.13 |
| JDK | `C:\Program Files\OpenJDK\jdk-25` — **OpenJDK 25**, `JAVA_HOME` set | Ghidra 12.1.2 wants `application.java.min=21`, `application.java.max=` (unbounded) → **25 is fine, verified working** |
| Ghidra | **12.1.2 PUBLIC** at `C:\ProgramData\chocolatey\lib\ghidra\tools\ghidra_12.1.2_PUBLIC` | `GHIDRA_INSTALL_DIR` **not set**; `ghidraRun` **not on PATH**. `Ghidra\Extensions` exists and is empty |
| x64dbg | release root `C:\Tools\x64dbg\release` (`x32\plugins`, `x64\plugins` both exist) | Commit `9c8ca1cae0b6d5…`, file version `0.0.2.5`. Existing plugins: ScyllaHide, OllyDumpEx, dbgchild, x64dbgpy |
| Binary Ninja | `C:\Program Files\Vector35\BinaryNinja` — **6.0.10601.0** | Settings file **exists** at `%APPDATA%\Binary Ninja\settings.json`, currently `{}`. User plugins dir empty |
| WinDbg / cdb | **MSIX AppX** `Microsoft.WinDbg` 1.2606.22001.0 | `cdb.exe` **is** present, version 10.0.29617.1000, and runs |
| symchk | **ABSENT** | Not shipped in the WinDbg MSIX. `dbghelp.dll` + `symsrv.dll` are |
| Windows SDK | `C:\Program Files (x86)\Windows Kits\10` present, **no `Debuggers` directory** | SDK is installed without the debuggers feature |
| uv | `…\WinGet\Packages\astral-sh.uv_…\uv.exe` | Present |
| Claude Code | `C:\Users\user\.local\bin\claude.exe` — **2.1.261** | Per-user install, as the spec predicted |
| Zig | **Absent** | Not needed — see O2 |
| Node.js | Present (`C:\Program Files\nodejs`) | Not needed; leave alone |
| `_NT_SYMBOL_PATH` (Machine) | **Unset** | Nothing to preserve |

**Discovery consequences**

- `Find-GhidraRoot` must add `C:\ProgramData\chocolatey\lib\ghidra\tools\ghidra_*` — the plan's
  candidate list (`C:\Tools`, `…\lib\ghidra\tools`) misses the extra `ghidra_<ver>_PUBLIC` level.
- `Find-X64dbgRoot` via `where.exe x64dbg` returns the **Chocolatey shim**
  (`C:\ProgramData\chocolatey\bin\x64dbg.exe`), not the real executable. Taking two
  `Split-Path -Parent` off the shim yields `C:\ProgramData\chocolatey` — **wrong**.
  Resolve the shim, or probe `C:\Tools\x64dbg\release\x64\x64dbg.exe` first.
- `Find-BinaryNinjaRoot` must include `C:\Program Files\Vector35\BinaryNinja`
  (the plan only checks `%LOCALAPPDATA%\Vector35` and `$env:ProgramFiles\Vector35\BinaryNinja` —
  the latter matches, but `%LOCALAPPDATA%\Vector35` does not exist here).
- **cdb discovery must not use `where.exe`.** Use
  `(Get-AppxPackage -Name Microsoft.WinDbg).InstallLocation` + `amd64\cdb.exe`.
  The path embeds the package version, so it must never be hardcoded.

---

## 2. Open items — resolved

### O1 — `disabledMcpjsonServers` ✅ correct key

`.claude/settings.json` → `disabledMcpjsonServers: ["ghidramcp"]` is current and correct.
Names are the exact keys from `.mcp.json`'s `mcpServers` object. Deny wins over any enable.

**New risk found, not in the spec:** project `.mcp.json` servers sit at **⏸ Pending approval**
until someone runs `claude` interactively in the workspace and accepts the trust dialog.
Until then `claude mcp list` will **not** show them connected — which breaks acceptance
criterion 3 and the tier-1 `claude mcp list` check on a fresh box.
Mitigation: also emit `"enableAllProjectMcpServers": true`, and have the manifest's
manual-steps section tell the operator to run `claude` once in `C:\re\agent` first.
Do not confuse these keys with `enabledMcpServers` / `disabledMcpServers`, which are the
`/mcp` panel toggles stored in `~/.claude.json`.

### O2 — x64dbg plugin binaries ✅ prebuilt, no Zig needed

`duty1g/x64dbg-mcp-server` ships prebuilt releases. Latest **v1.3** (2026-09-02),
asset `x64dbg-MCP-Server-v1.3.zip`, 1,482,614 bytes. Layout is a `dist/` tree
(`dist/x64/plugins/x64dbg-MCP-Server.dp64`, `dist/x32/plugins/x64dbg-MCP-Server.dp32`)
that is copied over the x64dbg root, deploying both architectures in one step.
Zig 0.16-dev is only needed to build from source — **drop Zig from the prerequisite list.**

### O3 — Binary Ninja settings file ✅ path confirmed, safe to merge

`C:\Users\user\AppData\Roaming\Binary Ninja\settings.json` exists and contains `{}`.
Nothing of the operator's to clobber today, but `Merge-JsonFile` with backup stays correct.
Note `%LOCALAPPDATA%\Vector35` does **not** exist on this host; drop it as a candidate.

### O4 — test binary ✅ `C:\Windows\System32\winver.exe`

Confirmed working end-to-end (see §4). Ghidra finds `entry` at `0x1400013c0` and decompiles it.
Do not assert an exact function count — assert a non-empty list plus a decompiled `entry`.

### O5 — x64dbg token bootstrap ✅ **pre-seed works** (option 1, the preferred one)

From `src/core/config.zig`: an existing `mcp_config.json` is **read and its values preserved**;
the token is generated only when missing. So the installer writes the file first and never
needs to launch x64dbg or prompt.

```jsonc
{ "IpAddress": "127.0.0.1", "Port": 9094, "AutoStart": true, "AuthToken": "<32 hex chars>" }
```

Token format is 16 random bytes → 32 lowercase hex chars (`SystemFunction036`).
`Save-ServerToken` / `New-BearerToken` produce 64 hex chars; either the plugin accepts a
longer token or the installer must emit 32 for this one server — **verify by connecting**,
and if unsure, pre-seed a 32-char token to match the plugin's own format.

### O6 — Binary Ninja autostart ❌ **it does not autostart**

Vendor docs: after setting `ui.mcp.enabled` you must *"Restart Binary Ninja"* and then
*"Start the server with `Plugins > MCP > Start Server`."* **Per-session manual step.**
This belongs in the tier-2 prompt and in the generated `CLAUDE.md`.
`MCP\Copy Connection Info` is the manual cross-check.

### O7 — minimum Binary Ninja version ✅ installed version has it

Vector 35 does not document a minimum. Verified directly instead: `binaryninja.exe` on this
host contains the literals `ui.mcp.enabled`, `ui.mcp.endpoint`, `ui.mcp.port`, `ui.mcp.token`.
**BN 6.0.10601.0 supports it.** Use that string probe as the version gate rather than a
version number — it is the property that actually matters.

---

## 3. Deviations from `MVP_SPEC.md`

**DEVIATION 1 — x64dbg is two servers on two ports, not one.**
The plugin defaults to port **9094 for x64dbg and 9095 for x32dbg**, chosen at compile time
from pointer width. The config file lives next to the loading module, so x32 and x64 get
**separate `mcp_config.json` files**. The spec's single `x64dbg` entry on port 8760 is wrong.
Emit two entries (`x64dbg-x64`, `x64dbg-x32`) or one entry plus a documented decision to run
only the 64-bit debugger. ⚠️ VERIFY on the host whether the config lands beside
`x64dbg.exe` or beside the plugin `.dp64` — the README and the source disagree.

**DEVIATION 2 — the x64dbg HTTP endpoint is `/`, not `/mcp`.**
Streamable HTTP at `/`, legacy SSE at `/sse`. The config's `"path": "/mcp"` is wrong.

**DEVIATION 3 — README says the default bind is `0.0.0.0`; the source struct defaults to
`127.0.0.1`.** Either way, pre-seeding `IpAddress` explicitly is mandatory, not optional.

**DEVIATION 4 — pyghidra-mcp over stdio crashes during analysis when symbols are enabled.**
Reproduced. `ghidrecomp.utility.setup_symbol_server` calls bare `print()` from a background
analysis thread; under stdio transport stdout is the MCP channel and the call raises
`ValueError: I/O operation on closed file`. Analysis aborts and `analysis_complete` stays
`false`, while `initialize` and `tools/list` still succeed — **exactly the "connected but
broken" failure the spec's tier-1 live call exists to catch.**
Two workarounds, both verified:

| Option | Result | Cost |
|---|---|---|
| `--transport streamable-http --host 127.0.0.1` | ✅ Symbols download, PDB loads, analysis completes, indexing completes | pyghidra-mcp has **no auth option at all** — breaks §11 "every HTTP server requires a bearer token" |
| stdio + `--no-symbols` | ✅ Analysis completes, `entry` decompiles | No PDB symbols for Windows binaries; worse answers on system code |

Recommendation: **streamable-http on loopback**, and amend §11 to "bearer token where the
server supports one; loopback-only otherwise", recording the exception in the manifest.
Report the `print()` bug upstream to `clearbluejar/pyghidra-mcp`.

**DEVIATION 5 — `mcp-windbg` has no module-list tool.**
Actual tools: `list_dumps`, `open_cdb_dump`, `open_cdb_remote`, `open_kd_session`,
`run_cdb_command`, `run_kd_command`, `close_cdb_session`, `close_kd_session`,
`send_ctrl_break`, `wait_for_break`. The tier-1 check must be
`open_cdb_dump` → `run_cdb_command lm` → assert `ntdll` with resolved symbols.
That needs a **crash dump in `C:\re\scratch`** — the installer must create one, e.g.
`cdb.exe -pn <proc> -c ".dump /ma C:\re\scratch\test.dmp;q"`. There is no live-process tool.

**DEVIATION 6 — symbol pre-warming cannot use `symchk`.**
`symchk.exe` is absent and is not in the WinDbg MSIX. Options: install the SDK debuggers
feature just for `symchk`, or pre-warm with `cdb.exe -z <dump> -c ".reload /f;q"`, or drop
pre-warming and only set `_NT_SYMBOL_PATH` (the cache fills on first use).
Setting the variable is the part that matters; treat pre-warm as best-effort and never fail
the phase on it.

**DEVIATION 7 — GhidraMCP 1.4 will not load in Ghidra 12.1.2.**
Latest release is **1.4, June 2025, built for Ghidra 11.3.2** (`GhidraMCP-release-1-4.zip`,
31,180 bytes). Ghidra enforces the extension version. Since it is installed-and-disabled
anyway, either skip it with a recorded `not-installed` reason or install it and expect
Ghidra to reject it. Do not treat this as a failure.

**DEVIATION 8 — chromadb downloads an 80 MB ONNX model on first pyghidra-mcp run.**
`all-MiniLM-L6-v2` into `%USERPROFILE%\.cache\chroma`. Silent, slow, and network-dependent.
Pre-warm it in Phase 3 or the first real tool call looks like a hang.

**DEVIATION 9 — `serverInfo.version` from pyghidra-mcp reports the MCP library version
(`1.29.1`), not the package version (`0.2.5`).** Read versions from `pip`/`importlib.metadata`
for the manifest, not from the MCP handshake.

---

## 4. End-to-end proof (the MVP's step-3 milestone, already demonstrated)

Ran on this host, outside the installer:

- venv via `uv`, Python 3.13.15, `uv pip install pyghidra-mcp`
- `pyghidra.start()` → `Application.getApplicationVersion()` = **12.1.2** (JDK 25, JPype OK)
- `pyghidra-mcp` over stdio with `--no-symbols --wait-for-analysis C:\Windows\System32\winver.exe`
- MCP `initialize` → **20 tools**
- `search_symbols_by_name` → `entry` at `1400013c0`
- `decompile_function` → `void entry(void) { FUN_140001604(); FUN_140001140(); return; }`
- Over `streamable-http` with symbols on: `winver.pdb` downloaded, analysis complete,
  89 strings indexed

**The chain works.** The build risk is packaging and idempotency, not tool compatibility.

**API corrections for the verification suite:**
- Binary names are Ghidra program paths, e.g. `/winver.exe-e678d1` — **not** `winver.exe`.
  Every `binary_name` argument must use the name returned by `list_project_binaries`.
- `decompile_function` takes `name_or_address`, **not** `name`.

---

## 5. Pins to write into `re-agent.config.json`

| Server | Pin | Source |
|---|---|---|
| x64dbg MCP | `v1.3`, asset `x64dbg-MCP-Server-v1.3.zip` (1,482,614 B) | GitHub release — hash to be computed at download |
| pyghidra-mcp | **0.2.5** (2026-08-06) | PyPI. Pulls `pyghidra` **3.1.0**, `ghidrecomp` 0.5.9, `mcp` 1.29.1, `chromadb` 1.5.9 |
| mcp-windbg | **1.2.1** (2026-08-27) | PyPI. `python -m mcp_windbg`; flags `--cdb-path`, `--kd-path`, `--symbols-path`, `--filter-script`, `--timeout`, `--transport` |
| GhidraMCP | `1.4`, `GhidraMCP-release-1-4.zip` (31,180 B) | GitHub release — Ghidra 11.3.2 only, see Deviation 7 |
| Binary Ninja | no source | Built in; `ui.mcp.*` on port 24642, endpoint `/mcp` |

`pyghidra >= 3.0.0` **requires Ghidra 12.0+**, and this host runs 12.1.2 — compatible, but
pin `pyghidra-mcp` exactly so a future `pyghidra` bump cannot silently break the pairing.

---

## 6. Prerequisites — what actually needs installing here

**Nothing.** Python 3.13.15, JDK 25, `uv`, `cdb.exe`, Ghidra, x64dbg, Binary Ninja and
Claude Code are all present. `Get-MissingPrereqs` must return empty on this host — if it
does not, the discovery logic is wrong, not the host.

Drop **Zig** from the prerequisite list entirely (O2). Keep the `cdb` install path in the
code for other hosts, but make discovery AppX-aware first so it is not triggered here.
