Set-StrictMode -Version Latest

# Depends on functions exported by sibling modules, which Install-REAgent.ps1
# imports into the session before this one: Write-ReAgentLog (Common),
# Invoke-CommandLine (Discovery), Get-VenvPython / Get-ServerVenvPath (Servers).

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

        VERIFY the two tool argument names against the installed mcp-windbg the
        first time this runs on a host; upstream documents the tool names but
        not their parameter names.
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
    .PARAMETER Inventory
        The host inventory.
    .PARAMETER Attended
        Include tier-2 checks.
    .EXAMPLE
        Invoke-Verification -Config $c.Config -ServerResults $c.ServerResults -Inventory $c.Inventory
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ServerResults,
        [object]$Inventory = $null,
        [switch]$Attended
    )

    $checks = @()
    $claude = if ($Inventory) { $Inventory.ClaudeCode } else { $null }

    $checks += Test-ClaudeCli -ClaudePath $claude
    $checks += Test-ClaudeMcpList -ClaudePath $claude -WorkingDirectory $Config.paths.agentRoot
    $checks += Test-GeneratedConfig -Config $Config

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
    Test-HttpServerLive, Get-HostAppHint, Get-ProbeInterpreter
