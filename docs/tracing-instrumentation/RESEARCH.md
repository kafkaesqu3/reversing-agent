# Agentic Reverse Engineering with Execution Traces: Capture, Understanding, and Use

_2026-09-09 — default-tier research: "agentic reverse engineering blogs, tools, skills, MCPs specifically for running program tracing, capturing traces, understanding traces, and using traces when reverse engineering a binary."_

**Summary:** Execution tracing is where agentic RE is currently strongest, because a trace gives an LLM *ground truth* to replace speculation — the failure mode that otherwise dominates. The clearest evidence is SpecterOps's June 2026 A/B test: the same Codex model solved a flattened FLARE-ON challenge **correctly** with Time-Travel-Debugging traces (16.4M tokens, 50 min) and produced a **wrong** answer without them (69.5M tokens, 1h51m) [1]. Two trace families dominate: **Windows TTD** (record-replay, queryable, now wrapped by several MCP servers) and **Frida/DBI** (lightweight, cross-platform, scriptable). The connective tissue for "understanding" traces is **Tenet**, the trace-explorer format that most tracers now emit [2]. For an agentic framework, the ready-made building blocks are TTD-over-MCP (`TTDObjectsPy`, `windbg-mcp`), Frida-over-MCP (many), and a taint/data-flow layer — with Pin and DynamoRIO being the notable gap (no MCP servers yet) [7].

## Findings

- **[confirmed] Traces convert RE from inference into data extraction — and that is exactly what LLMs need.** SpecterOps ran the identical Codex model twice on FLARE-ON 12 `FlareAuthenticator`: TTD-disabled, it forced a success-looking path and inferred a *wrong* flag; TTD-enabled, it queried the trace, found the real state comparison (`window+0x78` vs `0x0bc42d5779fec401`), extracted the per-digit delta table, and solved it — correct flag, 4× fewer tokens [1]. The framing that matters: "when the important behavior is runtime-dependent, giving [the agent] queryable execution history can keep it grounded and prevent long speculative detours" [1].

- **[confirmed] Time Travel Debugging is the highest-leverage trace type for agents.** TTD records all threads into a trace you replay forward *and backward* deterministically, and — critically for agents — it is queryable: `dx @$cursession.TTD.Calls(...)`, `TTD.Memory`, `TTD.Events` via the WinDbg data model / LINQ [1][8][windbg-mcp]. Microsoft, Google Cloud/Mandiant, and eShard all document it as the modern malware-triage workflow: "shift focus from manual code stepping to execution data analysis" [Google Cloud][MSRC][eShard].

- **[confirmed] The agentic TTD path is real and packaged.** `TTDObjectsPy` (kiwids0220) talks directly to `TTDReplay.dll` via ctypes — no WinDbg process to babysit — and exposes trace open, navigation, register/memory read, call tracing, **data-flow/taint** (`ttd_trace_register_origin`, `ttd_trace_register_taint`), watchpoints, and event queries as MCP tools for Codex [1][3]. It is the server behind the SpecterOps result.

- **[confirmed] For capture, the split is Windows-TTD vs cross-platform-Frida.** Trace *capture* options: `TTD.exe`/`tttracer`/WinDbg "record with TTD" on Windows [3][8]; Frida `Stalker`/`Interceptor` for lightweight, scoped, cross-platform tracing [4][6]; QEMU/gdbstub for firmware and non-native arch [nebuloss/re-dyn-mcp]. Frida's advantage is scope control — eShard traced a single JNI function in ~1000 instructions in under a minute on a real Android device [eShard]; TTD's is completeness and reverse-replay.

- **[confirmed] "Understanding" traces has a de-facto standard: Tenet's format.** Tenet (gaasedelen, IDA Pro plugin) visualizes execution traces — bidirectional flow painting, memory/register "seek to who-set-this", timeline zoom [2]. It matters here because the tracer ecosystem converged on emitting Tenet-compatible traces: Synacktiv's **Frinet** uses Frida to produce them [5], eShard's esReverse consumes them [eShard], and **TheCodexRebirth** builds a taint engine on Tenet's base [firida/CodexRebirth]. Tenet is inspired by QIRA and Microsoft TTD [2].

- **[probable] "Data-flow over the trace" is the feature that most helps an agent, more than raw stepping.** Both TTDObjectsPy's taint tools [3] and TheCodexRebirth's taint engine [CodexRebirth] target the same question — "which instruction produced this value?" — which is Tenet's headline navigation too [2]. Single strongest recurring capability across independent projects, so probably the right thing to expose to an agent first; not yet A/B-proven in isolation.

- **[probable] Frida is the most MCP-saturated tracing tool; TTD is catching up; Pin/DynamoRIO are unserved.** Exa/Brave surfaced ~7 distinct Frida MCP servers (beekamai/mcp-frida, neeetman/frida-mcp, fuzzmind/frida-mcp, majimboo/rexd-frida-mcp, rabbanyhmm/Frida-MCP, and the Android-focused ones) [4][6], 3+ WinDbg/TTD MCPs [3][8][Devolutions], but the curated `Awesome-RE-MCP` explicitly records "Intel Pin: No MCP server" and "DynamoRIO: Missing MCP integration for code coverage" [7]. Counts are from search, not an exhaustive registry.

- **[probable] Trace persistence to disk is becoming a standard MCP design pattern.** `neeetman/frida-mcp` streams hook events to `traces/*.jsonl` + `db.sqlite` so state survives context compaction [neeetman]; beekamai addresses sessions/scripts/traces by stable id for the same reason [6]. This maps directly onto your just-added "always save to ./research/" convention — trace artifacts want the same treatment.

- **[speculative] "RE Skills" (not just MCPs) are the emerging layer for encoding trace workflows.** SpecterOps published "SpecterOps Skills," a public repo of reusable agent workflows for security work (Sep 2026) [1-sidebar]; `glslang/windbg-mcp` ships a `windbg-debugging` skill with TTD playbooks [8]; `memoryforensics1/windbg-mcp` embeds `umd_frida_skill`/`umd_dbgsrv_skill` as in-tool guidance [windbg-mcp]. Direction is clear but the specific "trace-capture-and-analyze skill" is something you'd assemble, not adopt off-the-shelf.

## GitHub / prior art in code

- `kiwids0220/TTDObjectsPy` — MCP server for Microsoft TTD; ctypes to TTDReplay.dll; navigation, call tracing, taint/data-flow, watchpoints. https://github.com/kiwids0220/TTDObjectsPy [3]
- `gaasedelen/tenet` — IDA Pro execution-trace explorer; the de-facto trace format. https://github.com/gaasedelen/tenet [2]
- `memoryforensics1/windbg-mcp` — C# DbgEng COM MCP, 29 tools: kernel, Frida, TTD, VM control. https://github.com/memoryforensics1/windbg-mcp
- `glslang/windbg-mcp` — WinDbg/DbgEng MCP over stdio; TTD nav (`step_back`, `ttd_calls`, `ttd_memory`, `ttd_events`) + ships a `windbg-debugging` skill. https://github.com/glslang/windbg-mcp [8]
- `Devolutions/windbg-tool` — CLI + MCP for TTD replay/record with stable JSON output for agents. https://github.com/Devolutions/windbg-tool
- `beekamai/mcp-frida` — Frida MCP; `trace-start`=frida-trace in one tool, `dump-module`, stable session/trace ids. https://github.com/beekamai/mcp-frida [6]
- `neeetman/frida-mcp` — Frida MCP; `trace_api` with backtraces streamed to `traces/*.jsonl`, persistent sessions. https://github.com/neeetman/frida-mcp
- `Synacktiv Frinet` — Frida tracer producing Tenet-compatible traces. https://github.com/synacktiv/frinet [5]
- `AntoineBlaud/TheCodexRebirth` — taint-analysis + trace exploration built on Tenet. https://github.com/AntoineBlaud/TheCodexRebirth
- `nebuloss/re-dyn-mcp` — gdb-over-QEMU dynamic-analysis MCP (GDB/MI) for firmware RE. https://github.com/nebuloss/re-dyn-mcp
- `crowdere/Awesome-RE-MCP` — curated RE-MCP list; documents the Pin/DynamoRIO gap. https://github.com/crowdere/Awesome-RE-MCP [7]
- `cyberkaida/reverse-engineering-assistant` (ReVa) — Ghidra MCP with tool-driven design philosophy. https://github.com/cyberkaida/reverse-engineering-assistant

## Blogs worth reading

- SpecterOps, "Time Travel Debugging with Codex" — the A/B result; the single best primary source. https://specterops.io/blog/2026/06/26/time-travel-debugging-with-codex/ [1]
- RET2, "Tenet: A Trace Explorer for Reverse Engineers" — the foundational "understanding traces" piece. https://blog.ret2.io/2021/04/20/tenet-trace-explorer/ [2]
- Synacktiv, "Frinet: reverse-engineering made easier" — Frida→Tenet trace capture. https://www.synacktiv.com/en/publications/frinet-reverse-engineering-made-easier [5]
- eShard, "Malware analysis with Time Travel Analysis" + "Lightweight Time Travel Analysis with Frida." https://www.eshard.com/blog/malware-analysis-with-time-travel-analysis-reverse-engineering
- Google Cloud/Mandiant, "Time Travel Triage" (.NET process hollowing, LINQ querying of traces). https://cloud.google.com/blog/topics/threat-intelligence/time-travel-debugging-using-net-process-hollowing
- Talos, "Using LLMs as a reverse engineering sidekick" (MCP + IDA/Ghidra). https://blog.talosintelligence.com/using-llm-as-a-reverse-engineering-sidekick/
- MCP.Directory, "Frida MCP: Complete Guide (2026)." https://mcp.directory/blog/frida-mcp-complete-guide-2026

## Skills

- `glslang/windbg-mcp`'s bundled `windbg-debugging` skill (TTD/crash-dump/kernel playbooks) [8].
- mcp.directory `reverse-engineering-tools` agent skill — DBI roster (Frida, DynamoRIO, Pin, TinyInst, QBDI) + a trace-execution workflow [mcp.directory].
- In-tool skills embedded as MCP tools: `umd_frida_skill`, `umd_dbgsrv_skill` in `memoryforensics1/windbg-mcp`.
- SpecterOps Skills — public repo of reusable security agent workflows (referenced from [1], not read in full).

## Contradictions & gaps

- **The SpecterOps numbers are one case study, and they say so** — one challenge, one machine, token counts include cached input; not a benchmark [1]. Treat the *direction* (traces ground the agent) as well-supported by the mechanism and the corroborating TTD-triage literature, but not the *magnitude* (4× tokens) as general.
- **Platform asymmetry:** the strongest agentic-trace tooling is Windows/TTD-bound. TTD is user-mode only [windbg-mcp], and the richest MCPs are Windows-first. Cross-platform agentic tracing leans on Frida (great for scoped capture, not full record-replay) and gdb/QEMU for firmware. A framework wanting Linux/macOS parity has thinner options.
- **Pin and DynamoRIO have no MCP servers** [7] — a real gap if your targets need instruction-level coverage or custom DBI clients rather than Frida's JS agent model.
- **Could not establish** whether any published tool packages the *full* agentic loop (capture → Tenet-format → agent-queryable → data-flow) end-to-end for non-Windows targets; the pieces exist separately.

**Coverage:** lanes run — **keyword web** (Brave, 2 queries: Frida/DBI-MCP, TTD/Tenet); **semantic web** (Exa, 2 queries: agentic trace blogs, dynamic-analysis MCP); **GitHub** — attempted via the gateway's `firecrawl_research_search_github`, which **404'd (same as last run — that Firecrawl sub-tool is not wired on this gateway)**, so GitHub coverage came from Exa's `site:github.com`-style semantic results, i.e. repo-level discovery without indexed issue/PR search — a degraded lane; **page reads** — 2 in full (SpecterOps, Tenet/RET2). Lanes skipped — **Context7 docs** (subject is niche security tooling, not library docs it indexes); **papers** (subject is engineering/tooling, not academic — no papers lane run). Sources read in full: 2; distinct sources cited: 15+.
