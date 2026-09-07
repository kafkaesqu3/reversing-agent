Set-StrictMode -Version Latest

# Depends on functions exported by sibling modules, which Install-REAgent.ps1
# imports into the session before this one: Write-ReAgentLog, Write-Utf8NoBomFile
# (Common), Invoke-CommandLine (Discovery), Get-VenvPython / Get-ServerVenvPath /
# Get-WindbgLaunchCommand (Servers), Get-ToolCatalog / Get-CatalogServerTool /
# Compare-ToolCatalog / Test-SkillAdaptation / Get-SkillFrontmatter /
# Get-SkillToolReference (Skills).

$Script:ValidCheckStatus = @('pass', 'fail', 'not-testable')

function New-CheckResult {
    <#
    .SYNOPSIS
        Builds one verification check result.
    .DESCRIPTION
        not-testable is a first-class outcome, not a soft failure. A server
        whose GUI is not open has told us nothing about whether it works, and
        recording that as 'fail' sends the operator debugging the wrong thing.
    .PARAMETER Name
        Check name.
    .PARAMETER Status
        pass, fail, or not-testable.
    .PARAMETER Detail
        Evidence, or the reason it could not be tested.
    .EXAMPLE
        New-CheckResult -Name 'pyghidra-mcp live call' -Status 'pass' -Detail $d
    #>
    [CmdletBinding()]
    # Pure factory: builds and returns an object, writes nothing.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        [string]$Detail = ''
    )
    if ($Script:ValidCheckStatus -notcontains $Status) {
        throw ("Invalid check status '$Status'. Expected one of: " +
            ($Script:ValidCheckStatus -join ', '))
    }
    [PSCustomObject]@{ Name = $Name; Status = $Status; Detail = $Detail }
}

function Invoke-McpProbe {
    <#
    .SYNOPSIS
        Runs tools\mcp_probe.py against one server and returns its parsed report.
    .DESCRIPTION
        The probe runs under the server's OWN venv interpreter, which already
        carries the mcp client library, so the probe always speaks the same
        protocol version as the server it is testing and nothing extra is
        installed to test anything.

        Arguments use the --opt=value form throughout: a bare '--arg --no-symbols'
        is parsed by argparse as a missing value.
    .PARAMETER PythonPath
        Interpreter from the server's venv.
    .PARAMETER ProbeScript
        Path to tools\mcp_probe.py.
    .PARAMETER ProbeArgs
        Already-formed probe arguments.
    .PARAMETER Calls
        A sequence of {tool, args} to make in one session. Written to a temp
        file rather than passed inline: PowerShell 5.1 strips the double quotes
        out of a native command's arguments, so '--calls=[{"tool":"x"}]' arrives
        as '--calls=[{tool:x}]' and the probe dies on a JSONDecodeError that
        reads as a broken server.
    .EXAMPLE
        Invoke-McpProbe -PythonPath $py -ProbeScript $p -ProbeArgs $a
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PythonPath,
        [Parameter(Mandatory)][string]$ProbeScript,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ProbeArgs,
        [AllowEmptyCollection()][array]$Calls = @()
    )

    $callFile = $null
    if ($Calls.Count -gt 0) {
        $callFile = [IO.Path]::GetTempFileName()
        Write-Utf8NoBomFile -Path $callFile -Text (ConvertTo-Json @($Calls) -Depth 6 -Compress)
        $ProbeArgs = @($ProbeArgs) + "--calls-file=$callFile"
    }

    try {
        $out = Invoke-CommandLine -FilePath $PythonPath -Arguments (@($ProbeScript) + $ProbeArgs)
        $line = @($out) | Where-Object { "$_".TrimStart().StartsWith('{') } |
            Select-Object -Last 1
        if (-not $line) {
            return [PSCustomObject]@{ ok = $false; error = 'The probe produced no JSON report.' }
        }
        return ($line | ConvertFrom-Json)
    } catch {
        return [PSCustomObject]@{ ok = $false; error = $_.Exception.Message }
    } finally {
        if ($callFile) { Remove-Item -LiteralPath $callFile -Force -ErrorAction SilentlyContinue }
    }
}

function Test-ClaudeCli {
    <#
    .SYNOPSIS
        Checks that Claude Code itself is present and healthy.
    .PARAMETER ClaudePath
        Resolved path to claude.exe.
    .EXAMPLE
        Test-ClaudeCli -ClaudePath $inv.ClaudeCode
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$ClaudePath)

    if (-not $ClaudePath) {
        return New-CheckResult -Name 'claude --version' -Status 'fail' `
            -Detail 'Claude Code was not found for the current user.'
    }
    try {
        $out = (@(Invoke-CommandLine -FilePath $ClaudePath -Arguments @('--version')) -join ' ')
        if ($out -match '\d+\.\d+') {
            return New-CheckResult -Name 'claude --version' -Status 'pass' -Detail $out.Trim()
        }
        return New-CheckResult -Name 'claude --version' -Status 'fail' -Detail $out.Trim()
    } catch {
        return New-CheckResult -Name 'claude --version' -Status 'fail' `
            -Detail $_.Exception.Message
    }
}

function Test-ClaudeMcpList {
    <#
    .SYNOPSIS
        Checks that every enabled server shows as connected to Claude Code.
    .DESCRIPTION
        Distinguishes "pending approval" from a real connection failure. Project
        .mcp.json servers stay pending until claude has been run interactively
        once in the project directory and the trust prompt accepted - reporting
        that as a broken server would send the operator after the wrong thing.
    .PARAMETER ClaudePath
        Resolved path to claude.exe.
    .PARAMETER WorkingDirectory
        The agent root, where .mcp.json lives.
    .EXAMPLE
        Test-ClaudeMcpList -ClaudePath $c -WorkingDirectory $cfg.paths.agentRoot
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$ClaudePath,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    if (-not $ClaudePath) {
        return New-CheckResult -Name 'claude mcp list' -Status 'fail' `
            -Detail 'Claude Code was not found.'
    }

    $previous = Get-Location
    try {
        Set-Location -LiteralPath $WorkingDirectory
        $text = (@(Invoke-CommandLine -FilePath $ClaudePath -Arguments @('mcp', 'list')) -join "`n")
    } catch {
        return New-CheckResult -Name 'claude mcp list' -Status 'fail' -Detail $_.Exception.Message
    } finally {
        Set-Location -LiteralPath $previous
    }

    if ($text -match 'Pending|not trusted|trust') {
        return New-CheckResult -Name 'claude mcp list' -Status 'not-testable' -Detail (
            "Servers are pending approval. Run 'claude' once in $WorkingDirectory and " +
            "accept the trust prompt, then re-run with -VerifyOnly.`n$text")
    }
    if ($text -match 'Failed|failed to connect') {
        return New-CheckResult -Name 'claude mcp list' -Status 'fail' -Detail $text
    }
    return New-CheckResult -Name 'claude mcp list' -Status 'pass' -Detail $text
}

function Test-GeneratedConfig {
    <#
    .SYNOPSIS
        Checks that the generated agent config parses and matches allocated ports.
    .PARAMETER Config
        The parsed configuration object.
    .EXAMPLE
        Test-GeneratedConfig -Config $cfg
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    $mcpPath = Join-Path $Config.paths.agentRoot '.mcp.json'
    $setPath = Join-Path $Config.paths.agentRoot '.claude\settings.json'

    foreach ($p in @($mcpPath, $setPath)) {
        if (-not (Test-Path -LiteralPath $p)) {
            return New-CheckResult -Name 'generated config' -Status 'fail' `
                -Detail "Missing '$p'."
        }
        try {
            $null = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        } catch {
            return New-CheckResult -Name 'generated config' -Status 'fail' `
                -Detail "'$p' is not valid JSON: $($_.Exception.Message)"
        }
    }

    $allocated = @(Get-ServerPortMap -Config $Config).Values
    $mcp = Get-Content -LiteralPath $mcpPath -Raw | ConvertFrom-Json
    # Enumerated one property at a time: '.Properties.Name' on an object with
    # no properties throws under StrictMode, and an empty mcpServers is the
    # normal shape when every server failed to install.
    foreach ($prop in @($mcp.mcpServers.PSObject.Properties)) {
        $name = $prop.Name
        $entry = $mcp.mcpServers.$name
        if ($entry.PSObject.Properties.Name -notcontains 'url') { continue }
        if ($entry.url -notmatch '^http://127\.0\.0\.1:(\d+)') {
            return New-CheckResult -Name 'generated config' -Status 'fail' `
                -Detail "Server '$name' is not bound to loopback: $($entry.url)"
        }
        if ($allocated -notcontains [int]$Matches[1]) {
            return New-CheckResult -Name 'generated config' -Status 'fail' `
                -Detail "Server '$name' uses unallocated port $($Matches[1])."
        }
    }
    return New-CheckResult -Name 'generated config' -Status 'pass' `
        -Detail 'Both files parse; every HTTP server is on loopback and an allocated port.'
}

function Test-ServerNotTestable {
    <#
    .SYNOPSIS
        Returns a not-testable result for a server whose host app is not running.
    .PARAMETER ServerName
        The server name.
    .PARAMETER Reason
        Why it cannot be tested now.
    .EXAMPLE
        Test-ServerNotTestable -ServerName 'binaryninja' -Reason '...'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$Reason
    )
    return New-CheckResult -Name "$ServerName live call" -Status 'not-testable' -Detail $Reason
}

function Get-ProbeScriptPath {
    <#
    .SYNOPSIS
        Returns the path to tools\mcp_probe.py.
    .EXAMPLE
        Get-ProbeScriptPath
    #>
    [CmdletBinding()]
    param()
    return (Join-Path (Join-Path $PSScriptRoot '..') 'tools\mcp_probe.py')
}

function Test-PyghidraLive {
    <#
    .SYNOPSIS
        Tier-1 live call against pyghidra-mcp: list a binary, then decompile one.
    .DESCRIPTION
        The strongest unattended signal in the suite - it exercises a full
        Ghidra analysis run rather than a handshake.

        Two probe runs, deliberately: the binary name is only known after
        list_project_binaries, and pyghidra-mcp keeps its state server-side so
        a second session sees the same project. Names are Ghidra program paths
        such as /winver.exe-e678d1, never the file name.

        The configured testBinary is preferred over whatever happens to be
        first: an analyst's own imports would otherwise decide what this check
        reports on, and it would pass or fail for reasons unrelated to the
        install.
    .PARAMETER Server
        The server's config entry.
    .PARAMETER Config
        The parsed configuration object.
    .EXAMPLE
        Test-PyghidraLive -Server $s -Config $cfg
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Config
    )

    $name = 'pyghidra-mcp live call'
    $python = Get-VenvPython -VenvPath (Get-ServerVenvPath -Config $Config -Name $Server.name)
    $probe = Get-ProbeScriptPath
    $url = "http://$($Server.bind):$($Server.port)$($Server.path)"

    $listed = Invoke-McpProbe -PythonPath $python -ProbeScript $probe -ProbeArgs @(
        '--transport=http', "--url=$url", '--tool=list_project_binaries')

    if (-not $listed.ok) {
        $why = if ($listed.PSObject.Properties.Name -contains 'error') { $listed.error } else { 'tool call failed' }
        return New-CheckResult -Name $name -Status 'not-testable' -Detail (
            "Could not reach $url ($why). pyghidra-mcp runs from the " +
            "'$($Server.scheduledTask)' logon task; start it and re-run with -VerifyOnly.")
    }

    $binary = $null
    try {
        $programs = @(($listed.call.text | ConvertFrom-Json).programs)
        $binary = $programs[0].name
        if ($Config.PSObject.Properties.Name -contains 'testBinary' -and $Config.testBinary) {
            $leaf = Split-Path -Leaf $Config.testBinary
            $preferred = $programs | Where-Object { $_.name -like "*/$leaf-*" } |
                Select-Object -First 1
            if ($preferred) { $binary = $preferred.name }
        }
    } catch {
        $binary = $null
    }
    if (-not $binary) {
        return New-CheckResult -Name $name -Status 'fail' `
            -Detail "The server listed no binaries: $($listed.call.text)"
    }

    $calls = @{ tool = 'decompile_function'
        args        = @{ binary_name = $binary; name_or_address = 'entry' }
    }
    $decompiled = Invoke-McpProbe -PythonPath $python -ProbeScript $probe `
        -ProbeArgs @('--transport=http', "--url=$url") -Calls @($calls)

    if (-not $decompiled.ok) {
        return New-CheckResult -Name $name -Status 'fail' -Detail (
            "Decompiling 'entry' in '$binary' failed: " +
            "$($decompiled | ConvertTo-Json -Depth 6 -Compress)")
    }
    # The reply is a JSON envelope, and a failed decompilation is a successful
    # tool call carrying an 'error' field and an empty 'code'. Matching braces
    # against the envelope passes on exactly the failure worth catching.
    $payload = $null
    try { $payload = $decompiled.call.text | ConvertFrom-Json } catch { $payload = $null }
    if (-not $payload) {
        return New-CheckResult -Name $name -Status 'fail' -Detail (
            "Decompiling 'entry' in '$binary' returned no JSON envelope: " +
            "$($decompiled.call.text)")
    }

    $fields = $payload.PSObject.Properties.Name
    if ($fields -contains 'error' -and $payload.error) {
        return New-CheckResult -Name $name -Status 'fail' -Detail (
            "Decompiling 'entry' in '$binary' returned an error: $($payload.error)")
    }
    $code = if ($fields -contains 'code') { [string]$payload.code } else { '' }
    if (-not $code.Trim() -or $code -notmatch '\{|\(') {
        return New-CheckResult -Name $name -Status 'fail' -Detail (
            "Decompiling 'entry' in '$binary' produced no C: $($decompiled.call.text)")
    }
    return New-CheckResult -Name $name -Status 'pass' -Detail (
        "Decompiled 'entry' in '$binary' ($($code.Length) chars of C).")
}

function Test-WindbgLive {
    <#
    .SYNOPSIS
        Tier-1 live call against mcp-windbg: open a dump, list modules with symbols.
    .DESCRIPTION
        mcp-windbg exposes no module-list tool and no live-process tool, so the
        check opens the dump Phase 3 created and runs 'lm' through
        run_cdb_command. Asserting that ntdll resolves with symbols doubles as
        proof that Phase 2 actually worked.

        Both calls share ONE probe session: open_cdb_dump establishes the state
        that run_cdb_command then uses.
    .PARAMETER Server
        The server's config entry.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Result
        The install result, carrying the resolved launch command.
    .EXAMPLE
        Test-WindbgLive -Server $s -Config $cfg -Result $r
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Result
    )

    $name = "$($Server.name) live call"
    $dump = Join-Path $Config.paths.toolRoot 'scratch\test.dmp'
    if (-not (Test-Path -LiteralPath $dump)) {
        return New-CheckResult -Name $name -Status 'not-testable' -Detail (
            "No verification dump at '$dump'. Phase 3 creates it; re-run phase 3.")
    }

    # open_cdb_dump mints a session id and run_cdb_command requires it, so the
    # id is captured out of the first call's text and substituted into the
    # second. Both calls share one probe session; the server holds the state.
    $calls = @(
        @{ tool = 'open_cdb_dump'; args = @{ dump_path = $dump }
            capture = @{ session_id = 'session_id:\s*(\S+)' }
        },
        @{ tool = 'run_cdb_command'
            args = @{ session_id = '{{session_id}}'; command = 'lm' }
        }
    )
    $probeArgs = @('--transport=stdio', "--command=$($Result.Command.Executable)")
    foreach ($a in $Result.Command.Arguments) { $probeArgs += "--arg=$a" }
    foreach ($k in $Result.Command.Env.Keys) { $probeArgs += "--env=$k=$($Result.Command.Env[$k])" }

    $r = Invoke-McpProbe -PythonPath $Result.Command.Executable -ProbeScript (Get-ProbeScriptPath) `
        -ProbeArgs $probeArgs -Calls @($calls)

    if (-not $r.ok) {
        return New-CheckResult -Name $name -Status 'fail' `
            -Detail ($r | ConvertTo-Json -Depth 6 -Compress)
    }
    $text = (@($r.calls | ForEach-Object { $_.text }) -join "`n")
    # Judged on ntdll's own line, not the whole listing: cdb defers modules
    # nothing has touched yet, and an unrelated '(deferred)' says nothing about
    # whether the symbol path works.
    $ntdll = @($text -split "`n" | Where-Object { $_ -match '\bntdll\b' }) -join ' '
    if (-not $ntdll) {
        return New-CheckResult -Name $name -Status 'fail' `
            -Detail "Module list does not mention ntdll: $text"
    }
    if ($ntdll -match 'no symbols|deferred') {
        return New-CheckResult -Name $name -Status 'fail' -Detail (
            'ntdll is present but its symbols did not resolve, so Phase 2 has not ' +
            "taken effect: $ntdll")
    }
    return New-CheckResult -Name $name -Status 'pass' `
        -Detail 'ntdll listed with symbols resolved.'
}

function Get-ProbeInterpreter {
    <#
    .SYNOPSIS
        Returns an interpreter that has the mcp client library available.
    .DESCRIPTION
        Any server venv will do - they all depend on the mcp package - so the
        pyghidra-mcp venv is reused rather than creating a venv just to test.
    .PARAMETER Config
        The parsed configuration object.
    .EXAMPLE
        Get-ProbeInterpreter -Config $cfg
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    foreach ($name in @('pyghidra-mcp', 'mcp-windbg')) {
        $python = Get-VenvPython -VenvPath (Get-ServerVenvPath -Config $Config -Name $name)
        if (Test-Path -LiteralPath $python) { return $python }
    }
    throw ('No server venv is available to run the MCP probe. Install at least one ' +
        'Python-based server (phase 3) before running attended verification.')
}

function Test-HttpServerLive {
    <#
    .SYNOPSIS
        Tier-2 live check for an HTTP server whose host application must be open.
    .DESCRIPTION
        Handshake first, then a real tool call - a server that connects and then
        errors on first use is the normal failure mode, and a handshake alone
        would report it healthy.

        The tool to call is DATA, from the server's optional 'verify' block in
        re-agent.config.json:

            "verify": { "tool": "<name>", "args": { ... }, "expect": "<regex>" }

        Without one this reports not-testable rather than inventing a tool name.
        Guessing here would produce a confident false failure, which is worse
        than an honest "not checked": confirm a real tool name against the
        running server, record it in config, and the check becomes live.
    .PARAMETER Server
        The server's config entry.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER PythonPath
        Any interpreter with the mcp client library - a server venv will do.
    .EXAMPLE
        Test-HttpServerLive -Server $s -Config $cfg -PythonPath $py
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$PythonPath
    )

    $name = "$($Server.name) live call"
    $url = "http://$($Server.bind):$($Server.port)$($Server.path)"
    $probeArgs = @('--transport=http', "--url=$url")

    if ($Server.auth -ne 'none') {
        $token = Get-ServerToken -Name $Server.name `
            -TokenRoot (Join-Path $Config.paths.toolRoot 'mcp\tokens')
        if ($token) { $probeArgs += "--header=Authorization=Bearer $token" }
    }

    $hasVerify = $Server.PSObject.Properties.Name -contains 'verify'
    $calls = @()
    if ($hasVerify -and $Server.verify.tool) {
        $call = @{ tool = $Server.verify.tool; args = @{} }
        if ($Server.verify.PSObject.Properties.Name -contains 'args') {
            foreach ($p in $Server.verify.args.PSObject.Properties) {
                $call.args[$p.Name] = $p.Value
            }
        }
        $calls = @($call)
    }

    $r = Invoke-McpProbe -PythonPath $PythonPath -ProbeScript (Get-ProbeScriptPath) `
        -ProbeArgs $probeArgs -Calls $calls

    if (-not $r.ok -and $r.PSObject.Properties.Name -contains 'error') {
        return New-CheckResult -Name $name -Status 'not-testable' -Detail (
            "Could not reach $url ($($r.error)). " + (Get-HostAppHint -Server $Server))
    }
    if (-not $r.ok) {
        return New-CheckResult -Name $name -Status 'fail' `
            -Detail ($r | ConvertTo-Json -Depth 6 -Compress)
    }
    if ($r.toolCount -le 0) {
        return New-CheckResult -Name $name -Status 'fail' `
            -Detail 'The server connected but advertises no tools.'
    }

    if (-not ($hasVerify -and $Server.verify.tool)) {
        return New-CheckResult -Name $name -Status 'not-testable' -Detail (
            "Connected and advertising $($r.toolCount) tools, but no live call was made: " +
            "no verify.tool is configured for '$($Server.name)'. A handshake alone does " +
            'not prove the server works. Pick a tool from ' +
            "[$($r.tools -join ', ')], record it under mcpServers[$($Server.name)].verify " +
            'in re-agent.config.json, and re-run with -VerifyOnly -Attended.')
    }

    $text = $r.call.text
    if ($hasVerify -and $Server.verify.PSObject.Properties.Name -contains 'expect' -and
        $Server.verify.expect -and $text -notmatch $Server.verify.expect) {
        return New-CheckResult -Name $name -Status 'fail' -Detail (
            "Tool '$($Server.verify.tool)' returned output not matching " +
            "/$($Server.verify.expect)/: $text")
    }
    return New-CheckResult -Name $name -Status 'pass' -Detail (
        "$($r.toolCount) tools; '$($Server.verify.tool)' returned $($r.call.length) chars.")
}

function Get-HostAppHint {
    <#
    .SYNOPSIS
        Returns the operator instruction for an unreachable GUI-hosted server.
    .PARAMETER Server
        The server's config entry.
    .EXAMPLE
        Get-HostAppHint -Server $s
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Server)

    if ($Server.PSObject.Properties.Name -contains 'perSessionStart' -and
        $Server.perSessionStart) {
        return ("Open the application, then run '$($Server.perSessionStart)' - it does not " +
            'autostart, and this is needed once per session.')
    }
    if ($Server.kind -eq 'plugin-inproc') {
        $exe = if ($Server.arch -eq 'x32') { 'x32dbg' } else { 'x64dbg' }
        return "Open $exe with the target binary loaded, then re-run."
    }
    return 'Open the host application, then re-run.'
}

function Get-ServerCheck {
    <#
    .SYNOPSIS
        Builds one verification check per configured MCP server.
    .DESCRIPTION
        Extracted from Invoke-Verification so a second loop (skills) can be
        added without pushing that function past 100 lines and complexity 8.
        The branch order is unchanged and load-bearing: unknown, then not
        installed, then needs-attended - each a different not-testable reason.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER ServerResults
        Results from Install-AllMcpServer, or replayed from the manifest.
    .PARAMETER Attended
        Whether the operator has the GUI applications open.
    .EXAMPLE
        Get-ServerCheck -Config $cfg -ServerResults $r -Attended
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ServerResults,
        [switch]$Attended
    )

    $checks = @()
    foreach ($s in $Config.mcpServers) {
        $result = $ServerResults | Where-Object { $_.Name -eq $s.name } | Select-Object -First 1
        if (-not $result) {
            # No record at all is not the same as a failed install: it means no
            # run has reported on this server. Saying "not installed" of a
            # server that is up and answering is the worst answer available.
            $checks += Test-ServerNotTestable -ServerName $s.name -Reason (
                'Install state unknown - no manifest entry for it. Run the ' +
                'installer without -VerifyOnly, then verify again.')
            continue
        }
        if (-not $result.Installed) {
            $checks += Test-ServerNotTestable -ServerName $s.name -Reason (
                "Not installed on this host: $($result.Reason)")
            continue
        }

        if ($s.requiresHostApp -and -not $Attended) {
            $checks += Test-ServerNotTestable -ServerName $s.name -Reason (
                'Needs its application open with the target loaded. Re-run with ' +
                '-Attended once it is.')
            continue
        }

        # One check blowing up must not take the suite with it: the whole point
        # of this phase is to report on every server, including broken ones.
        try {
            switch ($s.name) {
                'pyghidra-mcp' { $checks += Test-PyghidraLive -Server $s -Config $Config }
                'mcp-windbg' {
                    $checks += Test-WindbgLive -Server $s -Config $Config -Result $result
                }
                default {
                    if ($s.transport -eq 'stdio') {
                        $checks += Test-ServerNotTestable -ServerName $s.name `
                            -Reason 'No live check is implemented for this server yet.'
                    } else {
                        $checks += Test-HttpServerLive -Server $s -Config $Config `
                            -PythonPath (Get-ProbeInterpreter -Config $Config)
                    }
                }
            }
        } catch {
            $checks += Test-ServerNotTestable -ServerName $s.name `
                -Reason "The check could not run: $($_.Exception.Message)"
        }
    }
    return $checks
}

function Get-ServerProbeContext {
    <#
    .SYNOPSIS
        Resolves the interpreter and probe arguments needed to reach a server live.
    .DESCRIPTION
        Shared between the skill-drift G3 check and the tool-catalog refresh, so a
        second caller never invents its own probe-argument dialect. HTTP servers
        need only Config; a stdio server (mcp-windbg) also needs Inventory to
        resolve its cdb path, so a missing Inventory - or a transport this probe
        does not yet support - reports Ok = $false rather than throwing.
    .PARAMETER Server
        The server's config entry.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Inventory
        The host inventory, for a stdio server's launch command. May be $null.
    .OUTPUTS
        A {Ok; PythonPath; ProbeArgs; Reason} object.
    .EXAMPLE
        Get-ServerProbeContext -Server $s -Config $cfg -Inventory $inv
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Config,
        [AllowNull()][object]$Inventory = $null
    )

    if ($Server.transport -eq 'http') {
        $url = "http://$($Server.bind):$($Server.port)$($Server.path)"
        return [PSCustomObject]@{ Ok = $true; Reason = ''
            PythonPath = (Get-ProbeInterpreter -Config $Config)
            ProbeArgs  = @('--transport=http', "--url=$url")
        }
    }
    if ($Server.transport -eq 'stdio' -and $Inventory) {
        $cmd = Get-WindbgLaunchCommand -Config $Config -Inventory $Inventory
        if ($cmd) {
            $probeArgs = @('--transport=stdio', "--command=$($cmd.Executable)")
            foreach ($a in $cmd.Arguments) { $probeArgs += "--arg=$a" }
            foreach ($k in $cmd.Env.Keys) { $probeArgs += "--env=$k=$($cmd.Env[$k])" }
            return [PSCustomObject]@{ Ok = $true; Reason = ''
                PythonPath = $cmd.Executable; ProbeArgs = $probeArgs
            }
        }
    }
    return [PSCustomObject]@{ Ok = $false; PythonPath = ''; ProbeArgs = @()
        Reason = ("No live probe is available for '$($Server.name)' " +
            "(transport '$($Server.transport)').")
    }
}

function Get-SkillPackFile {
    <#
    .SYNOPSIS
        Reads one skill's vendored SKILL.md, or throws naming the missing path.
    .DESCRIPTION
        Reads straight from the repo's vendored tree rather than the installed
        copy under agentRoot, so the adaptation gate runs under -VerifyOnly on a
        host where phase 5 has never written a file.
    .PARAMETER RepoRoot
        Repository root holding vendor\skills.
    .PARAMETER Namespace
        The pack's namespace.
    .PARAMETER SkillName
        The skill's install directory name.
    .EXAMPLE
        Get-SkillPackFile -RepoRoot $r -Namespace 'windbg' -SkillName 'windbg-crash'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$SkillName
    )
    $path = Join-Path $RepoRoot "vendor\skills\$Namespace\$SkillName\SKILL.md"
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Vendored skill file '$path' is missing."
    }
    return (Get-Content -LiteralPath $path -Raw)
}

function Merge-CheckStatus {
    <#
    .SYNOPSIS
        Reduces several check results into one status: fail beats not-testable beats pass.
    .DESCRIPTION
        Used to combine G3 and G4 sub-results, one pair per target server, into
        the single "<ns> skill drift" check Get-SkillCheck reports. A fail
        anywhere is real drift; a not-testable anywhere means at least one
        target told us nothing, and that must not be reported as a clean pass.
    .PARAMETER Results
        New-CheckResult-shaped objects to combine.
    .OUTPUTS
        [string] 'fail', 'not-testable', or 'pass'.
    .EXAMPLE
        Merge-CheckStatus -Results @($pinCheck, $liveCheck)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Results)

    if (@($Results | Where-Object { $_.Status -eq 'fail' }).Count -gt 0) { return 'fail' }
    if (@($Results | Where-Object { $_.Status -eq 'not-testable' }).Count -gt 0) {
        return 'not-testable'
    }
    return 'pass'
}

function Test-SkillAdaptationCheck {
    <#
    .SYNOPSIS
        Runs checks G0, CATALOG, G1 and G2 over every enabled skill in one pack.
    .DESCRIPTION
        Reads each skill's vendored SKILL.md directly via Get-SkillPackFile and
        delegates the actual checks to Test-SkillAdaptation (Skills.psm1) - this
        function's job is only to loop the pack's skills and turn the combined
        findings into one "<ns> skill adaptation" check.

        A pack whose skills declare no MCP tools at all passes with "nothing to
        check": it is correctly adapted by definition, and not-testable here
        would be noise the operator learns to ignore.
    .PARAMETER Pack
        The pack's config entry.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER RepoRoot
        Repository root holding vendor\skills.
    .EXAMPLE
        Test-SkillAdaptationCheck -Pack $p -Catalog $c -RepoRoot $root
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $name = "$($Pack.namespace) skill adaptation"
    $renames = @{}
    if ($Pack.PSObject.Properties.Name -contains 'adaptation') {
        foreach ($p in $Pack.adaptation.toolRenames.PSObject.Properties) {
            $renames[$p.Name] = $p.Value
        }
    }

    $findings = @()
    $toolCount = 0
    foreach ($skill in ($Pack.skills | Where-Object { $_.enabled })) {
        $text = Get-SkillPackFile -RepoRoot $RepoRoot -Namespace $Pack.namespace `
            -SkillName $skill.name
        $toolCount += @(Get-SkillToolReference -Frontmatter (Get-SkillFrontmatter -Text $text)).Count
        $findings += Test-SkillAdaptation -Text $text -DirectoryName $skill.name -Catalog $Catalog `
            -TargetServers @($Pack.targetServers) -ToolRenames $renames
    }

    if ($findings.Count -gt 0) {
        $detail = ($findings | ForEach-Object { $_.Message }) -join ' | '
        return New-CheckResult -Name $name -Status 'fail' -Detail $detail
    }
    if ($toolCount -eq 0) {
        return New-CheckResult -Name $name -Status 'pass' `
            -Detail 'Declares no MCP tools; nothing to check.'
    }
    return New-CheckResult -Name $name -Status 'pass' `
        -Detail "$toolCount declared tool(s) all correctly adapted."
}

function Test-ToolCatalogPin {
    <#
    .SYNOPSIS
        Runs check G4: the catalog's recorded server pin must match config's current pin.
    .DESCRIPTION
        Needs no live server - catches what an operator will actually hit:
        bumping a server's version in config without refreshing the catalog.
        A server with no catalog entry is not-testable, naming the exact
        refresh command, never a silent pass.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER Server
        Server name.
    .PARAMETER CurrentPin
        The server's pin as configured right now (mcpServers[].source.pin).
    .EXAMPLE
        Test-ToolCatalogPin -Catalog $c -Server 'pyghidra-mcp' -CurrentPin '0.2.5'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentPin
    )

    $name = "$Server tool catalog pin"
    $entry = Get-CatalogServerTool -Catalog $Catalog -Server $Server
    if (-not $entry.Known) {
        return New-CheckResult -Name $name -Status 'not-testable' -Detail (
            "No tool catalog entry for '$Server'. Open the application, start its MCP " +
            'server, then run: .\Install-REAgent.ps1 -Attended -UpdateToolCatalog')
    }
    if ($entry.Pin -ne $CurrentPin) {
        return New-CheckResult -Name $name -Status 'fail' -Detail (
            "Catalog recorded pin '$($entry.Pin)' for '$Server', but config now pins " +
            "'$CurrentPin'. Refresh with: .\Install-REAgent.ps1 -Attended -UpdateToolCatalog")
    }
    return New-CheckResult -Name $name -Status 'pass' `
        -Detail "Catalog pin '$CurrentPin' matches config."
}

function Test-ToolCatalogLive {
    <#
    .SYNOPSIS
        Runs check G3: the live tool list must match the catalog.
    .DESCRIPTION
        Reports the count delta and the added/removed names, not just
        "differs" - a tool-count drop after an upgrade is a useful regression
        signal (docs/mvp/HANDOFF.md). An unreachable server is not-testable,
        never fail: a closed GUI has told us nothing about an adaptation defect.
    .PARAMETER PythonPath
        Interpreter to run the probe with.
    .PARAMETER ProbeArgs
        Already-formed transport arguments for Invoke-McpProbe.
    .PARAMETER Server
        Server name, used to look up the catalog entry and name the check.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .EXAMPLE
        Test-ToolCatalogLive -PythonPath $py -ProbeArgs $a -Server 'pyghidra-mcp' -Catalog $c
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PythonPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ProbeArgs,
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][object]$Catalog
    )

    $name = "$Server tool catalog"
    $r = Invoke-McpProbe -PythonPath $PythonPath -ProbeScript (Get-ProbeScriptPath) `
        -ProbeArgs $ProbeArgs
    if (-not $r.ok) {
        $why = if ($r.PSObject.Properties.Name -contains 'error') { $r.error } else { 'tool call failed' }
        return New-CheckResult -Name $name -Status 'not-testable' -Detail (
            "Could not reach '$Server' to compare its live tools against the catalog ($why).")
    }

    $diff = Compare-ToolCatalog -Catalog $Catalog -Server $Server -LiveTools @($r.tools)
    if ($diff.Added.Count -gt 0 -or $diff.Removed.Count -gt 0) {
        return New-CheckResult -Name $name -Status 'fail' -Detail (
            "Live tool list differs from the catalog by $($diff.CountDelta): " +
            "added [$($diff.Added -join ', ')], removed [$($diff.Removed -join ', ')].")
    }
    return New-CheckResult -Name $name -Status 'pass' -Detail (
        "Live tool list matches the catalog ($($r.toolCount) tools).")
}

function Get-SkillDriftLiveCheck {
    <#
    .SYNOPSIS
        Runs G3 for one target server, honoring the attended gate.
    .DESCRIPTION
        Mirrors Get-ServerCheck's own gate: an attended-tier server without
        -Attended has told us nothing, so it is not-testable rather than
        silently skipped.
    .PARAMETER Server
        The server's config entry.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER Inventory
        The host inventory, for a stdio server's launch command. May be $null.
    .PARAMETER Attended
        Whether the operator has GUI host apps open.
    .EXAMPLE
        Get-SkillDriftLiveCheck -Server $s -Config $cfg -Catalog $c -Attended
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Catalog,
        [AllowNull()][object]$Inventory = $null,
        [switch]$Attended
    )

    $name = "$($Server.name) tool catalog"
    if ($Server.verifyTier -eq 'attended' -and -not $Attended) {
        return New-CheckResult -Name $name -Status 'not-testable' -Detail (
            'Needs its application open with the target loaded. Re-run with -Attended ' +
            'once it is.')
    }
    # One target server's probe blowing up (e.g. no venv resolvable yet) must
    # not take the rest of the pack's drift check down with it.
    try {
        $ctx = Get-ServerProbeContext -Server $Server -Config $Config -Inventory $Inventory
        if (-not $ctx.Ok) {
            return New-CheckResult -Name $name -Status 'not-testable' -Detail $ctx.Reason
        }
        return Test-ToolCatalogLive -PythonPath $ctx.PythonPath -ProbeArgs $ctx.ProbeArgs `
            -Server $Server.name -Catalog $Catalog
    } catch {
        return New-CheckResult -Name $name -Status 'not-testable' `
            -Detail "The check could not run: $($_.Exception.Message)"
    }
}

function Test-SkillDriftCheck {
    <#
    .SYNOPSIS
        Runs checks G3 and G4 over one pack's declared target servers.
    .DESCRIPTION
        G4 (catalog vs pin) needs no server and always runs. G3 (catalog vs
        live) is gated per server by Get-SkillDriftLiveCheck. The two
        sub-results per server are combined into the single "<ns> skill
        drift" check via Merge-CheckStatus: a fail anywhere is real drift, a
        not-testable anywhere means at least one target told us nothing.
    .PARAMETER Pack
        The pack's config entry.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER Inventory
        The host inventory, for a stdio target server's launch command.
    .PARAMETER Attended
        Whether the operator has GUI host apps open.
    .EXAMPLE
        Test-SkillDriftCheck -Pack $p -Config $cfg -Catalog $c -Attended
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Catalog,
        [AllowNull()][object]$Inventory = $null,
        [switch]$Attended
    )

    $name = "$($Pack.namespace) skill drift"
    $subChecks = @()
    foreach ($serverName in @($Pack.targetServers)) {
        $server = $Config.mcpServers | Where-Object { $_.name -eq $serverName } |
            Select-Object -First 1
        if (-not $server) {
            $subChecks += New-CheckResult -Name "$serverName tool catalog pin" `
                -Status 'not-testable' `
                -Detail "'$serverName' is not a declared mcpServers entry."
            continue
        }
        $subChecks += Test-ToolCatalogPin -Catalog $Catalog -Server $serverName `
            -CurrentPin $server.source.pin
        $subChecks += Get-SkillDriftLiveCheck -Server $server -Config $Config -Catalog $Catalog `
            -Inventory $Inventory -Attended:$Attended
    }

    $detail = ($subChecks | ForEach-Object { $_.Detail }) -join ' | '
    return New-CheckResult -Name $name -Status (Merge-CheckStatus -Results $subChecks) `
        -Detail $detail
}

function Get-InstalledPackCheck {
    <#
    .SYNOPSIS
        Runs one installed pack's adaptation and drift checks, each isolated by try/catch.
    .DESCRIPTION
        Split out of Get-SkillCheck so one broken pack's two checks cannot take
        the rest of the suite down, and so Get-SkillCheck's own guard cascade
        stays readable at a glance.
    .PARAMETER Pack
        The pack's config entry.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER RepoRoot
        Repository root holding vendor\skills.
    .PARAMETER Inventory
        The host inventory, for a stdio target server's live launch command.
    .PARAMETER Attended
        Whether the operator has GUI host apps open.
    .OUTPUTS
        [array] The pack's "<ns> skill adaptation" and "<ns> skill drift" checks.
    .EXAMPLE
        Get-InstalledPackCheck -Pack $p -Config $cfg -Catalog $c -RepoRoot $root
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RepoRoot,
        [AllowNull()][object]$Inventory = $null,
        [switch]$Attended
    )

    $checks = @()
    try {
        $checks += Test-SkillAdaptationCheck -Pack $Pack -Catalog $Catalog -RepoRoot $RepoRoot
    } catch {
        $checks += New-CheckResult -Name "$($Pack.namespace) skill adaptation" `
            -Status 'not-testable' -Detail "The check could not run: $($_.Exception.Message)"
    }
    try {
        $checks += Test-SkillDriftCheck -Pack $Pack -Config $Config -Catalog $Catalog `
            -Inventory $Inventory -Attended:$Attended
    } catch {
        $checks += New-CheckResult -Name "$($Pack.namespace) skill drift" `
            -Status 'not-testable' -Detail "The check could not run: $($_.Exception.Message)"
    }
    return $checks
}

function Get-SkillCheck {
    <#
    .SYNOPSIS
        Builds the adaptation and drift verification checks for every configured skill pack.
    .DESCRIPTION
        Mirrors Get-ServerCheck's guard cascade: a pack with no manifest record
        is unknown, not uninstalled; a pack the last run marked not installed
        is not-testable with its recorded reason. Only an installed pack's
        vendored files are actually read, via Get-InstalledPackCheck.

        G0-G2 and G4 need no server at all - they read the repo's vendored
        files and the checked-in catalog directly, so a bad adaptation fails
        verification even under -VerifyOnly on a host where phase 5 has never
        run. G3's live half is gated per target server inside
        Test-SkillDriftCheck.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER SkillResults
        Results from Install-AllSkill, or replayed from the manifest.
    .PARAMETER RepoRoot
        Repository root holding vendor\skills.
    .PARAMETER Inventory
        The host inventory, for a stdio target server's live launch command.
    .PARAMETER Attended
        Whether the operator has GUI host apps open.
    .EXAMPLE
        Get-SkillCheck -Config $cfg -SkillResults $r -RepoRoot $root
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$SkillResults,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RepoRoot,
        [AllowNull()][object]$Inventory = $null,
        [switch]$Attended
    )

    if ($Config.PSObject.Properties.Name -notcontains 'skills') { return @() }

    try {
        $catalog = Get-ToolCatalog
    } catch {
        return @(New-CheckResult -Name 'tool catalog' -Status 'not-testable' `
                -Detail $_.Exception.Message)
    }

    $checks = @()
    foreach ($pack in $Config.skills) {
        $result = $SkillResults | Where-Object { $_.Namespace -eq $pack.namespace } |
            Select-Object -First 1
        if (-not $result) {
            $checks += New-CheckResult -Name "$($pack.namespace) skill adaptation" `
                -Status 'not-testable' -Detail (
                    'Install state unknown - no manifest entry for it. Run the installer ' +
                    'without -VerifyOnly, then verify again.')
            continue
        }
        if (-not $result.Installed) {
            $checks += New-CheckResult -Name "$($pack.namespace) skill adaptation" `
                -Status 'not-testable' -Detail "Not installed on this host: $($result.Reason)"
            continue
        }
        $checks += Get-InstalledPackCheck -Pack $pack -Config $Config -Catalog $catalog `
            -RepoRoot $RepoRoot -Inventory $Inventory -Attended:$Attended
    }
    return $checks
}

function ConvertFrom-CatalogServerMap {
    <#
    .SYNOPSIS
        Converts a catalog's .servers object into a plain hashtable, keyed by server name.
    .PARAMETER Catalog
        A tool-catalog document, or $null to start from an empty catalog.
    .EXAMPLE
        ConvertFrom-CatalogServerMap -Catalog $existing
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$Catalog)

    $map = @{}
    if ($Catalog -and $Catalog.PSObject.Properties.Name -contains 'servers') {
        foreach ($p in $Catalog.servers.PSObject.Properties) { $map[$p.Name] = $p.Value }
    }
    return $map
}

function Update-CatalogServerEntry {
    <#
    .SYNOPSIS
        Refreshes one server's catalog entry in place, or leaves it untouched.
    .DESCRIPTION
        Never removes an entry. A disabled server, an attended-tier server
        without -Attended, a server whose launch command cannot be resolved,
        or a server that does not answer, is skipped with a WARN and its
        previous entry (if any) survives unchanged - a closed GUI must never
        silently erase a good catalog entry (S9).
    .PARAMETER Servers
        The accumulator hashtable, mutated in place.
    .PARAMETER Server
        The server's config entry.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Inventory
        The host inventory, for a stdio server's launch command.
    .PARAMETER Attended
        Whether the operator has GUI host apps open.
    .EXAMPLE
        Update-CatalogServerEntry -Servers $map -Server $s -Config $cfg -Attended
    #>
    [CmdletBinding()]
    # Mutates only the in-memory accumulator passed in by reference; the actual
    # file write is gated by Save-ToolCatalog's own ShouldProcess check.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [Parameter(Mandatory)][hashtable]$Servers,
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][object]$Config,
        [AllowNull()][object]$Inventory = $null,
        [switch]$Attended
    )

    if (-not $Server.enabled) { return }
    if ($Server.verifyTier -eq 'attended' -and -not $Attended) {
        Write-ReAgentLog -Level WARN -Message (
            "Leaving the catalog entry for '$($Server.name)' untouched: needs -Attended.")
        return
    }

    try {
        $ctx = Get-ServerProbeContext -Server $Server -Config $Config -Inventory $Inventory
        $r = if ($ctx.Ok) {
            Invoke-McpProbe -PythonPath $ctx.PythonPath -ProbeScript (Get-ProbeScriptPath) `
                -ProbeArgs $ctx.ProbeArgs
        } else {
            [PSCustomObject]@{ ok = $false; error = $ctx.Reason }
        }
    } catch {
        $r = [PSCustomObject]@{ ok = $false; error = $_.Exception.Message }
    }
    if (-not $r.ok) {
        Write-ReAgentLog -Level WARN -Message (
            "Leaving the catalog entry for '$($Server.name)' untouched: it did not answer " +
            "($($r.error)).")
        return
    }

    $Servers[$Server.name] = [PSCustomObject]@{
        pin = $Server.source.pin; toolCount = $r.toolCount; tools = @($r.tools)
    }
}

function Save-ToolCatalog {
    <#
    .SYNOPSIS
        Refreshes data/tool-catalog.json by probing every reachable server.
    .DESCRIPTION
        Only ever runs behind the explicit -UpdateToolCatalog switch (S9): a
        baseline that updates itself to match what it observes cannot fail.
        The installer must never call this on its own. An unreachable
        server's existing entry is left untouched with a WARN, never erased.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Inventory
        The host inventory, for a stdio server's launch command.
    .PARAMETER CapturedBy
        Recorded in the catalog for provenance.
    .PARAMETER Attended
        Whether the operator has GUI host apps open.
    .PARAMETER Path
        Catalog file. Defaults to data/tool-catalog.json beside the module.
    .EXAMPLE
        Save-ToolCatalog -Config $cfg -Inventory $inv -Attended
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][object]$Config,
        [AllowNull()][object]$Inventory = $null,
        [string]$CapturedBy = $env:USERNAME,
        [switch]$Attended,
        [string]$Path = ''
    )

    if (-not $Path) { $Path = Join-Path (Join-Path $PSScriptRoot '..') 'data\tool-catalog.json' }
    $existing = if (Test-Path -LiteralPath $Path) {
        Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } else { $null }
    $servers = ConvertFrom-CatalogServerMap -Catalog $existing

    foreach ($server in $Config.mcpServers) {
        Update-CatalogServerEntry -Servers $servers -Server $server -Config $Config `
            -Inventory $Inventory -Attended:$Attended
    }

    $ordered = [ordered]@{}
    foreach ($k in ($servers.Keys | Sort-Object)) { $ordered[$k] = $servers[$k] }
    $catalog = [ordered]@{
        capturedAt = (Get-Date).ToString('o'); capturedBy = $CapturedBy; servers = $ordered
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Refresh tool catalog')) {
        Write-Utf8NoBomFile -Path $Path -Text ($catalog | ConvertTo-Json -Depth 8)
    }
    return [PSCustomObject]$catalog
}

function Invoke-Verification {
    <#
    .SYNOPSIS
        Runs the verification suite and writes verify-report.json.
    .DESCRIPTION
        Tier 1 always runs and needs no GUI. Tier 2 needs x64dbg and Binary
        Ninja open with the test binary loaded, so without -Attended those
        servers report not-testable rather than fail. A server that needs an
        application nobody opened has told us nothing.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER ServerResults
        Results from Install-AllMcpServer.
    .PARAMETER SkillResults
        Results from Install-AllSkill, or replayed from the manifest.
    .PARAMETER Inventory
        The host inventory.
    .PARAMETER RepoRoot
        Repository root holding vendor\skills, for the skill adaptation gate.
    .PARAMETER Attended
        Include tier-2 checks.
    .EXAMPLE
        Invoke-Verification -Config $c.Config -ServerResults $c.ServerResults -Inventory $c.Inventory
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ServerResults,
        [AllowEmptyCollection()][array]$SkillResults = @(),
        [object]$Inventory = $null,
        [string]$RepoRoot = '',
        [switch]$Attended
    )

    $checks = @()
    $claude = if ($Inventory) { $Inventory.ClaudeCode } else { $null }

    $checks += Test-ClaudeCli -ClaudePath $claude
    $checks += Test-ClaudeMcpList -ClaudePath $claude -WorkingDirectory $Config.paths.agentRoot
    $checks += Test-GeneratedConfig -Config $Config

    $checks += Get-ServerCheck -Config $Config -ServerResults $ServerResults -Attended:$Attended
    $checks += Get-SkillCheck -Config $Config -SkillResults $SkillResults -RepoRoot $RepoRoot `
        -Inventory $Inventory -Attended:$Attended

    $report = [ordered]@{
        tier2Requested = [bool]$Attended
        checks         = @($checks | ForEach-Object {
                [ordered]@{ name = $_.Name; status = $_.Status; detail = $_.Detail }
            })
        summary        = [ordered]@{
            pass        = @($checks | Where-Object { $_.Status -eq 'pass' }).Count
            fail        = @($checks | Where-Object { $_.Status -eq 'fail' }).Count
            notTestable = @($checks | Where-Object { $_.Status -eq 'not-testable' }).Count
        }
    }

    $path = Join-Path $Config.paths.stateRoot 'verify-report.json'
    $null = New-Item -ItemType Directory -Path $Config.paths.stateRoot -Force
    Write-Utf8NoBomFile -Path $path -Text ($report | ConvertTo-Json -Depth 8)

    foreach ($c in $checks) {
        $level = if ($c.Status -eq 'fail') { 'ERROR' } elseif ($c.Status -eq 'pass') { 'INFO' } else { 'WARN' }
        Write-ReAgentLog -Level $level -Message "[$($c.Status)] $($c.Name)"
    }
    return $checks
}

Export-ModuleMember -Function New-CheckResult, Invoke-McpProbe, Test-ClaudeCli, `
    Test-ClaudeMcpList, Test-GeneratedConfig, Test-ServerNotTestable, `
    Get-ProbeScriptPath, Test-PyghidraLive, Test-WindbgLive, Invoke-Verification, `
    Test-HttpServerLive, Get-HostAppHint, Get-ProbeInterpreter, Get-ServerCheck, `
    Get-ServerProbeContext, Get-SkillPackFile, Merge-CheckStatus, `
    Test-SkillAdaptationCheck, Test-ToolCatalogPin, Test-ToolCatalogLive, `
    Get-SkillDriftLiveCheck, Test-SkillDriftCheck, Get-InstalledPackCheck, Get-SkillCheck, `
    ConvertFrom-CatalogServerMap, Update-CatalogServerEntry, Save-ToolCatalog
