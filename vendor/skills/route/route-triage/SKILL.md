---
name: route-triage
description: Route a reverse-engineering task to the right tool on this install and apply general binary-native RE technique (static/dynamic triage, anti-analysis, packer/VM/obfuscation patterns) while doing it. Declares no MCP tools: it decides which server or skill (windbg, ghidra, x64dbg-x64/x64dbg-x32, binaryninja, re) to reach for, then hands off. Use at the start of an unfamiliar RE task, before committing to a specific tool.
license: MIT
compatibility: Requires filesystem-based agent (Claude Code) with Bash. This install provides RE tooling exclusively through the five pinned MCP servers in re-agent.config.json; no additional tool installation is expected or supported.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Task
---

# Reverse-Engineering Triage and Routing

Quick reference for starting an unfamiliar RE task on this install: decide which real tool to
reach for, then apply general binary-native technique while using it. For detailed technique
notes, see the supporting files below.

**Scope note:** this skill is adapted from a CTF competition RE cheat-sheet
(`ljagiello/ctf-skills`' `ctf-reverse`). Its own sibling skills for pwn/web/crypto/forensics/
OSINT/AI-ML/malware categories were **not** vendored into this install and do not exist here -
only this reverse-engineering slice was pulled in. The routing and tool-reference sections below
were rewritten for this install's real servers (`x64dbg-x64`, `x64dbg-x32`, `binaryninja`,
`pyghidra-mcp`, `mcp-windbg`); the technique sections and the ~19 reference files still carry
upstream's original CTF framing and its `radare2`/`IDA`/`GDB`/`Frida`/`angr`/`Qiling` assumptions
- see `## Limitations` at the end before treating anything in them as directly runnable.

## Tool availability on this install (important)

This repository provides RE tooling exclusively through the five pinned MCP servers declared in
`re-agent.config.json`: `x64dbg-x64` / `x64dbg-x32` (live Windows dynamic debugging), `binaryninja`
(GUI-driven static analysis), `pyghidra-mcp` (headless static analysis and decompilation), and
`mcp-windbg` (crash dump and live process triage). It does not vendor or install `gdb`, `radare2`,
`Ghidra` (the desktop app or its `analyzeHeadless` CLI), `IDA`, `frida-tools`, `angr`, `qiling`,
`uncompyle6`, `pycdc`, `capstone`, `lief`, `z3-solver`, or `pwndbg` - upstream's Prerequisites
section assumed a Linux/macOS CTF-competition environment where installing this stack ad hoc is
normal, but that is not this install. **Do not install new tools during a session.** Route to the
skill or server that already exists instead (see `## Routing` below).

## Additional Resources

- [tools.md](tools.md) - Static analysis tools (GDB, Ghidra, radare2, IDA, Binary Ninja, dogbolt.org, RISC-V with Capstone, Unicorn emulation, Python bytecode, WASM, Android APK, .NET, packed binaries)
- [tools-dynamic.md](tools-dynamic.md) - Dynamic analysis tools: Frida (hooking, anti-debug bypass, memory scanning, Android/iOS), angr symbolic execution (path exploration, constraints, CFG), lldb (macOS/LLVM debugger), x64dbg (Windows)
- [tools-emulation.md](tools-emulation.md) - Emulation frameworks and side-channel tooling: Qiling (cross-platform OS-level emulation), Triton (DSE), Intel Pin instruction-counting + genetic algorithm side channel, opcode-only trace reconstruction, LD_PRELOAD time freeze and memcmp side-channel for byte-by-byte bruteforce
- [tools-advanced.md](tools-advanced.md) - Advanced tools (Part 1): VMProtect/Themida analysis, binary diffing (BinDiff, Diaphora), deobfuscation frameworks (D-810, GOOMBA, Miasm), Qiling framework, Triton DSE, Manticore, Rizin/Cutter, RetDec, custom VM bytecode lifting to LLVM IR
- [tools-advanced-2.md](tools-advanced-2.md) - Advanced tools (Part 2): advanced GDB (Python scripting, brute-force, conditional breakpoints, watchpoints, reverse debugging with rr, pwndbg/GEF), advanced Ghidra scripting, patching (Binary Ninja API, LIEF), GDB constraint extraction + ILP solver (BackdoorCTF 2017), GDB position-encoded input zero flag monitoring (EKOPARTY 2017), LD_PRELOAD execute-only binary dump (BackdoorCTF 2017), PEDA current_inst bit-by-bit flag scraper (CONFidence CTF 2019 Teaser)
- [anti-analysis.md](anti-analysis.md) - Anti-analysis taxonomy: Linux anti-debug (ptrace, /proc, timing, signals, direct syscalls), Windows anti-debug (PEB, NtQueryInformationProcess, heap flags, TLS callbacks, HW/SW breakpoint detection, exception-based, thread hiding), anti-VM/sandbox (CPUID, MAC, timing, artifacts, resources), anti-DBI (Frida detection/bypass), code integrity/self-hashing, anti-disassembly (opaque predicates, junk bytes), MBA identification/simplification, comprehensive bypass strategies
- [anti-analysis-ctf.md](anti-analysis-ctf.md) - CTF writeup techniques: SIGILL handler for execution mode switching (Hack.lu 2015), SIGFPE signal handler side-channel via strace counting (PlaidCTF 2017), instruction trace inversion with Keystone and Unicorn (MeePwn 2017), call-less function chaining via stack frame manipulation (THC 2018), parent-patched child binary dump via `process_vm_writev` (Google CTF Quals 2018)
- [patterns.md](patterns.md) - Foundational binary patterns: custom VMs, anti-debugging, nanomites, self-modifying code, XOR ciphers, mixed-mode stagers, LLVM obfuscation, S-box/keystream, SECCOMP/BPF, exception handlers, memory dumps, byte-wise transforms, x86-64 gotchas, custom mangle reversing, position-based transforms, hex-encoded string comparison, signal-based binary exploration
- [patterns-runtime.md](patterns-runtime.md) - Runtime patching and oracle techniques: malware anti-analysis bypass, multi-stage shellcode loaders, timing side-channel attacks, multi-thread anti-debug with decoy + signal handler MBA (ApoorvCTF 2026), INT3 patch + coredump brute-force oracle (Pwn2Win 2016), signal handler chain + LD_PRELOAD oracle (Nuit du Hack 2016), printf format string VM decompilation to Z3 (SECCON 2017), quadtree recursive image format parser (Google CTF Quals 2018)
- [patterns-ctf.md](patterns-ctf.md) - Competition-specific patterns (Part 1): hidden emulator opcodes, LD_PRELOAD key extraction, SPN static extraction, image XOR smoothness, byte-at-a-time cipher, mathematical convergence bitmap, Windows PE XOR bitmap OCR, two-stage RC4+VM loaders, GBA ROM meet-in-the-middle, Sprague-Grundy game theory, kernel module maze solving, multi-threaded VM channels, backdoored shared library detection via string diffing, custom binfmt kernel module with RC4 flat binaries, hash-resolved imports / no-import ransomware, ELF section header corruption for anti-analysis
- [patterns-ctf-2.md](patterns-ctf-2.md) - Competition-specific patterns (Part 2): multi-layer self-decrypting brute-force, embedded ZIP+XOR license, stack string deobfuscation, prefix hash brute-force, CVP/LLL lattice for integer validation, decision tree function obfuscation, GF(2^8) Gaussian elimination, ROP chain obfuscation analysis (ROPfuscation)
- [patterns-ctf-3.md](patterns-ctf-3.md) - Competition-specific patterns (Part 3): Z3 single-line Python circuit, sliding window popcount, keyboard LED Morse code via ioctl, C++ destructor-hidden validation, syscall side-effect memory corruption, MFC dialog event handlers, VM sequential key-chain brute-force, Burrows-Wheeler transform inversion, OpenType font ligature exploitation, GLSL shader VM with self-modifying code, instruction counter as cryptographic state, batch crackme automation via objdump, fork+pipe+dead branch anti-analysis, TensorFlow DNN inversion via sigmoid layer inversion, BPF filter analysis via kernel JIT to x64 assembly
- [languages.md](languages.md) - Language-specific: Python bytecode & opcode remapping, Python version-specific bytecode, Pyarmor static unpack, DOS stubs, Unity IL2CPP, HarmonyOS HAP/ABC, Brainfuck/esolangs (+ BF character-by-character static analysis, BF side-channel read count oracle, BF comparison idiom detection), UEFI, transpilation to C, code coverage side-channel, OPAL functional reversing, non-bijective substitution, FRACTRAN program inversion
- [languages-platforms.md](languages-platforms.md) - Platform/framework-specific: Roblox place file analysis, Godot game asset extraction, Rust serde_json schema recovery, Android JNI RegisterNatives obfuscation, Android DEX runtime bytecode patching via /proc/self/maps, Android native .so loading bypass via new project, Frida Firebase Cloud Functions bypass, Verilog/hardware RE, prefix-by-prefix hash reversal, Ruby/Perl polyglot constraint satisfaction, Electron ASAR extraction + native binary analysis, Node.js npm runtime introspection
- [languages-compiled.md](languages-compiled.md) - Go binary reversing (GoReSym, goroutines, memory layout, channel ops, embed.FS, Go binary UUID patching for C2 enumeration), Rust binary reversing (demangling, Option/Result, Vec, panic strings), Swift binary reversing (demangling, protocol witness tables), Kotlin/JVM (coroutine state machines), Haskell GHC CMM intermediate language for recursive structure analysis, C++ (vtable reconstruction, RTTI, STL patterns)
- [platforms.md](platforms.md) - Platform-specific RE: macOS/iOS (Mach-O, code signing, Objective-C runtime, Swift, dyld, jailbreak bypass), embedded/IoT firmware (binwalk, UART/JTAG/SPI extraction, ARM/MIPS, RTOS), kernel drivers (Linux .ko, eBPF, Windows .sys), game engines (Unreal Engine, Unity, anti-cheat, Lua), automotive CAN bus
- [platforms-hardware.md](platforms-hardware.md) - Hardware and advanced architecture RE: HD44780 LCD controller GPIO reconstruction, RISC-V advanced (custom extensions, privileged modes, debugging), ARM64/AArch64 reversing and exploitation (calling convention, ROP gadgets, qemu-aarch64-static emulation)
- [field-notes.md](field-notes.md) - Quick reference notes: binary types, anti-debugging bypass, specialized patterns, CTF case notes

---

## Routing

Upstream routed to sibling CTF-category skills (`/ctf-pwn`, `/ctf-web`, `/ctf-crypto`,
`/ctf-forensics`, `/ctf-ai-ml`, `/ctf-misc`, `/ctf-malware`) that were never vendored into this
install and do not exist here. Route to a real tool or skill on this host instead:

- **Windows crash dump, hang, or live-process triage** -> the `windbg` skills
  (`windbg-crash-analysis`, `windbg-doctor`), which drive `mcp-windbg`.
- **A dump from a .NET/CLR or mixed-mode process** -> the `dotnet-debugging` skill, not
  `windbg-crash-analysis`. It drives the same `mcp-windbg` server but works the dump through
  SOS (`!clrstack`, `!dumpheap`, `!gcroot`, `!syncblk`), which is what a managed stack needs;
  a native-only triage of a managed dump reports frames nobody can act on.
- **A binary you do not understand yet** -> the `reva-binary-triage` skill: a breadth-first
  survey over `pyghidra-mcp` (strings, imports/exports, symbols, entry-point decompile) that
  flags suspicious areas and ends with a task list of what to investigate next.
- **A specific question about a binary** ("what does this function do", "is this crypto",
  "what is the C2 address", "fix the types here") -> the `reva-deep-analysis` skill:
  depth-first investigation over `pyghidra-mcp`, one thread followed to the end, each answer
  returned with its evidence. Run it after `reva-binary-triage`, or straight away when the
  question is already sharp.
- **A sustained rename/retype campaign on one binary** - iterative decompile, apply, re-read,
  under the `ai_`-prefix trust model and invariant bracketing -> the `ghidra-iterative-re`
  skill, which also drives `pyghidra-mcp`. Binary Ninja (`binaryninja` MCP server) is also
  available for GUI-driven static analysis; there is no dedicated skill for it yet, so drive
  its `bn_*` tools directly.
- **The deliverable is diagrams** - "diagram this binary", "map what it talks to", control
  flow, data flow, failure modes, or imported/exported-API integration points, written up
  with address citations -> the `arch-architectural-analysis` skill. Its own description
  draws the boundary: not for a one-off prose explanation (`reva-deep-analysis`) and not for
  a first-pass survey of an unfamiliar binary (`reva-binary-triage`).
- **You already have a function set and need graph-level structure over it** - blast radius,
  taint propagation, privilege boundaries, entry-point reachability -> the `tob-trailmark`
  skill, which assembles a Trailmark binary graph from `pyghidra-mcp` output. It comes after
  triage or deep analysis has chosen the functions, not before.
- **Live x86/x64 dynamic debugging** (breakpoints, stepping, memory/register inspection) ->
  the `x64dbg-x64` / `x64dbg-x32` MCP servers directly. Both are attended (`requiresHostApp`):
  x64dbg must already be running with its plugin loaded. There is no dedicated skill for x64dbg
  yet (deferred; see the project plan's Task 19).
- **You already have static triage output (file/strings/sections/imports) and need a packing
  assessment or unpacking plan, or you already have strings/log output and need normalized
  IOCs** -> the `re` pack's `re-unpacker` or `re-ioc-extraction` skills. Both are evidence-only:
  they consume output you already produced with one of the tools above; they do not drive a
  server themselves.
- **The task turns out to be exploitation (ROP, heap, kernel), a web app, a standalone crypto
  problem, disk/network forensics, OSINT, or an ML-model attack** -> outside this install's
  scope. Say so plainly rather than reaching for a CTF-category skill that was never vendored.

## Problem-Solving Workflow

1. **Start with strings extraction** - many easy challenges have plaintext flags
2. **Try ltrace/strace** - dynamic analysis often reveals flags without reversing
3. **Try Frida hooking** - hook strcmp/memcmp to capture expected values without reversing
4. **Try angr** - symbolic execution solves many flag-checkers automatically
5. **Try Qiling** - emulate foreign-arch binaries or bypass heavy anti-debug without artifacts
6. **Map control flow** before modifying execution
7. **Automate manual processes** via scripting (r2pipe, Frida, angr, Python)
8. **Validate assumptions** by comparing decompiler outputs (dogbolt.org for side-by-side)

## Quick Wins (Try First!)

```bash
# Plaintext flag extraction
strings binary | grep -E "flag\{|CTF\{|pico"
strings binary | grep -iE "flag|secret|password"
rabin2 -z binary | grep -i "flag"

# Dynamic analysis - often captures flag directly
ltrace ./binary
strace -f -s 500 ./binary

# Hex dump search
xxd binary | grep -i flag

# Run with test inputs
./binary AAAA
echo "test" | ./binary
```

## Initial Analysis

```bash
file binary           # Type, architecture
checksec --file=binary # Security features (for pwn)
chmod +x binary       # Make executable
```

## Memory Dumping Strategy

**Key insight:** Let the program compute the answer, then dump it. Break at final comparison (`b *main+OFFSET`), enter any input of correct length, then `x/s $rsi` to dump computed flag.

## Decoy Flag Detection

**Pattern:** Multiple fake targets before real check. Look for multiple comparison targets in sequence with different success messages. Set breakpoint at FINAL comparison, not earlier ones.

## GDB PIE Debugging

PIE binaries randomize base address. Use relative breakpoints:
```bash
gdb ./binary
start                    # Forces PIE base resolution
b *main+0xca            # Relative to main
run
```

## Comparison Direction (Critical!)

Two patterns: (1) `transform(flag) == stored_target` — reverse the transform. (2) `transform(stored_target) == flag` — flag IS the transformed data, just apply transform to stored target.

## Common Encryption Patterns

- XOR with single byte - try all 256 values
- XOR with known plaintext (`flag{`, `CTF{`)
- RC4 with hardcoded key
- Custom permutation + XOR
- XOR with position index (`^ i` or `^ (i & 0xff)`) layered with a repeating key

## Quick Tool Reference

Upstream's Radare2 and IDA command blocks are removed here - neither is a server on this install.
For static disassembly/decompilation, use the `ghidra-iterative-re` skill's `pyghidra-mcp` tool
calls (import, decompile, search, rename, retype, comment) instead of a raw `analyzeHeadless`
invocation; there is no Ghidra desktop or headless CLI installed, only the `pyghidra-mcp` server.

## Deep-Dive Notes

Use [field-notes.md](field-notes.md) after the first round of triage when you know what kind of target you have.

- Target formats: Python bytecode, WASM, Android, Flutter, .NET, UPX, Tauri
- Technique notes: anti-debug bypass, VM analysis, x86-64 gotchas, iterative solvers, Unicorn, timing side channels
- Platform notes: Godot, Roblox, macOS/iOS, embedded firmware, kernel drivers, game engines, Swift, Kotlin, Go, Rust, D
- Case notes: modern CTF-specific reversing patterns and older classic challenge patterns


## Limitations

This is a bounded adaptation, not a line-by-line rewrite of the whole pack. The frontmatter,
`## Tool availability on this install`, `## Routing`, and `## Quick Tool Reference` sections above
are adapted for this install's real servers. The remaining sections (`Problem-Solving Workflow`
through `Common Encryption Patterns`) and every file under `## Additional Resources` (`tools.md`,
`tools-dynamic.md`, `tools-emulation.md`, `tools-advanced.md`, `tools-advanced-2.md`,
`anti-analysis.md`, `anti-analysis-ctf.md`, `patterns*.md`, `languages*.md`, `platforms*.md`,
`field-notes.md`) are vendored as-authored and still describe `radare2`, `IDA`, `GDB`, `Frida`,
`angr`, `Qiling`, `Triton`, and similar tools this install does not provide. Read them as
background technique literature - the underlying binary-analysis reasoning (how a custom VM's
opcode dispatch works, how a timing side channel leaks a comparison, how a packer's stub
transitions to payload) transfers to this install's real tools even where the exact command does
not. Map the *intent* onto `pyghidra-mcp` / `binaryninja` / `x64dbg-x64` / `x64dbg-x32` /
`mcp-windbg` tool calls rather than attempting to run a `radare2` or `IDA` command verbatim -
`allowed-tools` above does not grant this skill any MCP tool, so it cannot invoke one directly in
any case.
