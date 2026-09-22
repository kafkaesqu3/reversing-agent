Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ReAgent.Agents.psm1') -Force

# Depends on functions exported by sibling modules, which Install-REAgent.ps1
# imports into the session before this one: Write-ReAgentLog, Write-Utf8NoBomFile
# (Common), Invoke-CommandLine (Discovery), Test-PdbPathCheck (Symbols),
# Get-VenvPython / Get-ServerVenvPath / Get-WindbgLaunchCommand (Servers),
# Get-ToolCatalog / Get-CatalogServerTool / Compare-ToolCatalog / Test-SkillAdaptation /
# Get-SkillFrontmatter / Get-SkillToolReference (Skills).

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
    $transport = 'http'
    if ($Server.PSObject.Properties.Name -contains 'transport' -and
        "$($Server.transport)" -eq 'sse') { $transport = 'sse' }
    $probeArgs = @("--transport=$transport", "--url=$url")

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
    if ($Server.kind -eq 'native-sse') {
        return ("Start-ScheduledTask -TaskName '$($Server.scheduledTask)' - it is a " +
            'background service, not a GUI application, and does not autostart until ' +
            'next logon.')
    }
    return 'Open the host application, then re-run.'
}

function Test-ReadOnlyLaunchCheck {
    <#
    .SYNOPSIS
        Runs check Q0: a read-only server's launcher must carry --readonly.
    .DESCRIPTION
        The SQL layer collapses many operations into one tool, but the agent
        gate classifies per tool. ghidrasql_query reads or writes depending on
        the text of the SQL, and A3 cannot see the SQL. What makes the tool
        genuinely read-only is the server flag, so the flag is what gets
        checked - the classification is a consequence of it, not a control.

        Sub-classifying by parsing SQL would be a denylist, and a denylist gets
        bypassed. See spec section 7.3.
    .PARAMETER Server
        One entry from the config's mcpServers[].
    .PARAMETER LauncherPath
        The generated launcher for that server.
    .OUTPUTS
        [array] Zero or one {Check='Q0'; Message} findings.
    .EXAMPLE
        Test-ReadOnlyLaunchCheck -Server $srv -LauncherPath $p
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Server,
        [Parameter(Mandatory)][string]$LauncherPath
    )

    if ($Server.PSObject.Properties.Name -notcontains 'readonly') { return @() }
    if (-not $Server.readonly) { return @() }

    $reason = ''
    if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
        $reason = "its launcher '$LauncherPath' does not exist"
    } else {
        $text = Get-Content -LiteralPath $LauncherPath -Raw
        if ($text -notmatch '(?m)--readonly\b') {
            $reason = "its launcher does not pass --readonly"
        }
    }
    if (-not $reason) { return @() }
    return @([PSCustomObject]@{ Check = 'Q0'; Message = (
                "Server '$($Server.name)' is declared read-only but $reason. Its " +
                '*_query tool is classified read on the strength of that flag; without ' +
                'it the tool can write and the agent gate will not notice.') })
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

    if ($Server.transport -eq 'http' -or $Server.transport -eq 'sse') {
        $url = "http://$($Server.bind):$($Server.port)$($Server.path)"
        return [PSCustomObject]@{ Ok = $true; Reason = ''
            PythonPath = (Get-ProbeInterpreter -Config $Config)
            ProbeArgs  = @("--transport=$($Server.transport)", "--url=$url")
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

function Get-SkillPackDirectory {
    <#
    .SYNOPSIS
        The repo path of one vendored skill.
    .DESCRIPTION
        Points at the repo's vendored tree rather than the installed copy under
        agentRoot, so the adaptation gate runs under -VerifyOnly on a host where
        phase 5 has never written a file.
    .PARAMETER RepoRoot
        Repository root holding vendor\skills.
    .PARAMETER Namespace
        The pack's namespace.
    .PARAMETER SkillName
        The skill's install directory name.
    .EXAMPLE
        Get-SkillPackDirectory -RepoRoot $r -Namespace 'windbg' -SkillName 'windbg-crash'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$SkillName
    )
    return (Join-Path $RepoRoot "vendor\skills\$Namespace\$SkillName")
}

function Get-SkillPackFile {
    <#
    .SYNOPSIS
        Reads one skill's vendored SKILL.md, or throws naming the missing path.
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
    $path = Join-Path (Get-SkillPackDirectory -RepoRoot $RepoRoot -Namespace $Namespace `
            -SkillName $SkillName) 'SKILL.md'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Vendored skill file '$path' is missing."
    }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8)
}

function Merge-CheckStatus {
    <#
    .SYNOPSIS
        Reduces several check results into one status: fail beats not-testable beats pass.
    .DESCRIPTION
        Used to fold a pack's sub-results into the single check Get-SkillCheck
        reports: G0-G2 plus one G4 per target server for "<ns> skill
        adaptation", one G3 per target server for "<ns> skill drift". A fail
        anywhere is a real defect; a not-testable anywhere means at least one
        sub-check told us nothing, and that must not be reported as a clean pass.
    .PARAMETER Results
        New-CheckResult-shaped objects to combine.
    .OUTPUTS
        [string] 'fail', 'not-testable', or 'pass'.
    .EXAMPLE
        Merge-CheckStatus -Results @($adaptationCheck, $pinCheck)
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Results)

    if (@($Results | Where-Object { $_.Status -eq 'fail' }).Count -gt 0) { return 'fail' }
    if (@($Results | Where-Object { $_.Status -eq 'not-testable' }).Count -gt 0) {
        return 'not-testable'
    }
    return 'pass'
}

function Get-ServerSourcePin {
    <#
    .SYNOPSIS
        One server's configured source.pin, or an empty string when it has none.
    .DESCRIPTION
        Not every declared server is pinned: binaryninja is a host application
        this installer does not fetch, so its source is null. Reading through
        that under Set-StrictMode throws, and a throw inside the adaptation
        check is caught upstream and reported not-testable - which would let a
        G0-G2 failure hide behind an unrelated missing key.
    .PARAMETER Server
        A mcpServers entry, or $null.
    .OUTPUTS
        [string] The pin, or '' when the server declares none.
    .EXAMPLE
        Get-ServerSourcePin -Server $server
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$Server)

    if (-not $Server -or $Server.PSObject.Properties.Name -notcontains 'source' -or
        -not $Server.source) { return '' }
    if ($Server.source.PSObject.Properties.Name -notcontains 'pin') { return '' }
    return [string]$Server.source.pin
}

function Get-PackPinCheck {
    <#
    .SYNOPSIS
        Runs check G4 for every target server one skill pack declares.
    .DESCRIPTION
        G4 compares the catalog's recorded pin against the pin config carries
        right now. It reads the config and the checked-in catalog and nothing
        else, so it belongs beside the adaptation checks rather than behind the
        drift check's install-state guard. Behind that guard it was unreachable
        in the shipped state - every pack held at the human review gate, nothing
        installed, no manifest - which is exactly the state design spec section
        11.3's negative test 4 has to fail in.

        A target server the config does not declare, or declares with no pin of
        its own, is not-testable naming the server: there is nothing to compare
        the catalog against, and that is not a clean pass.
    .PARAMETER Pack
        The pack's config entry.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .OUTPUTS
        [array] One "<server> tool catalog pin" check per declared target server.
    .EXAMPLE
        Get-PackPinCheck -Pack $p -Config $cfg -Catalog $c
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Catalog
    )

    $checks = @()
    foreach ($serverName in @($Pack.targetServers)) {
        $server = $Config.mcpServers | Where-Object { $_.name -eq $serverName } |
            Select-Object -First 1
        $name = "$serverName tool catalog pin"
        $pin = Get-ServerSourcePin -Server $server
        if (-not $server) {
            $checks += New-CheckResult -Name $name -Status 'not-testable' `
                -Detail "'$serverName' is not a declared mcpServers entry."
        } elseif (-not $pin) {
            $checks += New-CheckResult -Name $name -Status 'not-testable' -Detail (
                "Config records no source.pin for '$serverName', so there is " +
                'nothing to compare the catalog against.')
        } else {
            $checks += Test-ToolCatalogPin -Catalog $Catalog -Server $serverName `
                -CurrentPin $pin
        }
    }
    return $checks
}

function Test-SkillAdaptationCheck {
    <#
    .SYNOPSIS
        Runs checks G0, CATALOG, G1, G2 and G4 over one pack, installed or not.
    .DESCRIPTION
        Reads each skill's vendored SKILL.md directly via Get-SkillPackFile and
        delegates the actual checks to Test-SkillAdaptation (Skills.psm1) - this
        function's job is only to loop the pack's skills, add G4 for the pack's
        target servers, and turn the combined findings into one "<ns> skill
        adaptation" check.

        G4 sits here rather than with the drift checks because it needs no
        running server: it compares the catalog's recorded pin against config's
        current one, which is what an operator actually hits. Behind the drift
        check's install-state guard it never ran in the shipped state at all.

        A pack whose skills declare no MCP tools at all passes with "nothing to
        check": it is correctly adapted by definition, and not-testable here
        would be noise the operator learns to ignore.

        G2 runs over the whole vendored skill directory, not only SKILL.md: a
        pack can carry six tool renames and fifteen reference files, and a
        half-adaptation left in one of those reference files is exactly the
        failure G2 exists to catch.
    .PARAMETER Pack
        The pack's config entry.
    .PARAMETER Config
        The parsed configuration object, for G4's current pins.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER RepoRoot
        Repository root holding vendor\skills.
    .EXAMPLE
        Test-SkillAdaptationCheck -Pack $p -Config $cfg -Catalog $c -RepoRoot $root
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][object]$Config,
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
        $findings += Test-SkillTreeRename -ToolRenames $renames -Directory (
            Get-SkillPackDirectory -RepoRoot $RepoRoot -Namespace $Pack.namespace `
                -SkillName $skill.name)
    }

    $subChecks = @()
    if ($findings.Count -gt 0) {
        $subChecks += New-CheckResult -Name $name -Status 'fail' `
            -Detail (($findings | ForEach-Object { $_.Message }) -join ' | ')
    } elseif ($toolCount -eq 0) {
        $subChecks += New-CheckResult -Name $name -Status 'pass' `
            -Detail 'Declares no MCP tools; nothing to check.'
    } else {
        $subChecks += New-CheckResult -Name $name -Status 'pass' `
            -Detail "$toolCount declared tool(s) all correctly adapted."
    }
    $subChecks += Get-PackPinCheck -Pack $Pack -Config $Config -Catalog $Catalog

    return New-CheckResult -Name $name -Status (Merge-CheckStatus -Results $subChecks) `
        -Detail (($subChecks | ForEach-Object { $_.Detail }) -join ' | ')
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
        A server with no catalog entry is also not-testable, naming the exact
        refresh command: with no baseline recorded, every live tool would
        otherwise read as "added", turning an unmeasured server into a false
        drift failure.
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

    $entry = Get-CatalogServerTool -Catalog $Catalog -Server $Server
    if (-not $entry.Known) {
        return New-CheckResult -Name $name -Status 'not-testable' -Detail (
            "No tool catalog entry for '$Server'. Open the application, start its MCP " +
            'server, then run: .\Install-REAgent.ps1 -Attended -UpdateToolCatalog')
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
        Runs check G3 over one pack's declared target servers.
    .DESCRIPTION
        G3 (catalog vs live) is the only check here that is genuinely about
        install state, because it needs the server running. G4 moved to
        Test-SkillAdaptationCheck: it reads only config and the catalog, so
        gating it on install state switched it off in the one state that
        matters. The per-server sub-results are combined into the single
        "<ns> skill drift" check via Merge-CheckStatus: a fail anywhere is
        real drift, a not-testable anywhere means at least one target told us
        nothing.
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
            $subChecks += New-CheckResult -Name "$serverName tool catalog" `
                -Status 'not-testable' `
                -Detail "'$serverName' is not a declared mcpServers entry."
            continue
        }
        $subChecks += Get-SkillDriftLiveCheck -Server $server -Config $Config -Catalog $Catalog `
            -Inventory $Inventory -Attended:$Attended
    }

    $detail = ($subChecks | ForEach-Object { $_.Detail }) -join ' | '
    return New-CheckResult -Name $name -Status (Merge-CheckStatus -Results $subChecks) `
        -Detail $detail
}

function Get-PackAdaptationCheck {
    <#
    .SYNOPSIS
        Runs one pack's adaptation check, whether or not the pack is installed.
    .DESCRIPTION
        G0, CATALOG, G1, G2 and G4 read the repo's vendored files, the config
        and the checked-in catalog and nothing else, so install state has no
        bearing on whether they can run - and gating them behind it would
        switch the centrepiece control off in exactly the states where it
        matters most: a pack held at the human review gate, or a host where
        phase 5 has never run at all.
        Design spec section 10.2 requires this to hold under -VerifyOnly.

        A pack switched off in re-agent.config.json is the one exception: it is
        out of service by operator decision, Install-SkillPack already removes
        its files and reports not-installed, so the gate has nothing to say
        about it. Reporting 'fail' every run for a deliberately parked pack is
        the same wrong answer as calling a disabled server broken.

        Wrapped in its own try/catch so one pack with an unreadable vendored
        tree cannot take the rest of the suite down.
    .PARAMETER Pack
        The pack's config entry.
    .PARAMETER Config
        The parsed configuration object, for G4's current pins.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER RepoRoot
        Repository root holding vendor\skills.
    .OUTPUTS
        The pack's "<ns> skill adaptation" check.
    .EXAMPLE
        Get-PackAdaptationCheck -Pack $p -Config $cfg -Catalog $c -RepoRoot $root
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RepoRoot
    )

    if (-not $Pack.enabled) {
        return New-CheckResult -Name "$($Pack.namespace) skill adaptation" `
            -Status 'not-testable' -Detail 'disabled in re-agent.config.json'
    }

    try {
        return Test-SkillAdaptationCheck -Pack $Pack -Config $Config -Catalog $Catalog `
            -RepoRoot $RepoRoot
    } catch {
        return New-CheckResult -Name "$($Pack.namespace) skill adaptation" `
            -Status 'not-testable' -Detail "The check could not run: $($_.Exception.Message)"
    }
}

function Get-PackDriftCheck {
    <#
    .SYNOPSIS
        Runs one pack's drift check, or says why install state rules it out.
    .DESCRIPTION
        Unlike the adaptation gate, drift is a statement about what is installed
        here, so it keeps the guard cascade Get-ServerCheck uses: a pack with no
        manifest record is unknown rather than uninstalled, and a pack the last
        run did not install is not-testable with its recorded reason.
    .PARAMETER Pack
        The pack's config entry.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER SkillResults
        Results from Install-AllSkill, or replayed from the manifest.
    .PARAMETER Inventory
        The host inventory, for a stdio target server's live launch command.
    .PARAMETER Attended
        Whether the operator has GUI host apps open.
    .OUTPUTS
        The pack's "<ns> skill drift" check.
    .EXAMPLE
        Get-PackDriftCheck -Pack $p -Config $cfg -Catalog $c -SkillResults $r
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Pack,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$SkillResults,
        [AllowNull()][object]$Inventory = $null,
        [switch]$Attended
    )

    $name = "$($Pack.namespace) skill drift"
    $result = $SkillResults | Where-Object { $_.Namespace -eq $Pack.namespace } |
        Select-Object -First 1
    if (-not $result) {
        return New-CheckResult -Name $name -Status 'not-testable' -Detail (
            'Install state unknown - no manifest entry for it. Run the installer ' +
            'without -VerifyOnly, then verify again.')
    }
    if (-not $result.Installed) {
        return New-CheckResult -Name $name -Status 'not-testable' `
            -Detail "Not installed on this host: $($result.Reason)"
    }
    try {
        return Test-SkillDriftCheck -Pack $Pack -Config $Config -Catalog $Catalog `
            -Inventory $Inventory -Attended:$Attended
    } catch {
        return New-CheckResult -Name $name -Status 'not-testable' `
            -Detail "The check could not run: $($_.Exception.Message)"
    }
}

function Get-SkillCheck {
    <#
    .SYNOPSIS
        Builds the adaptation and drift verification checks for every configured skill pack.
    .DESCRIPTION
        Each pack yields two checks with deliberately different gating. The
        adaptation check always runs: G0-G2 and G4 read the repo's vendored
        files, the config and the checked-in catalog and need no server, so a
        bad adaptation or a stale catalog pin fails verification even under
        -VerifyOnly on a host where phase 5 has never run. The drift check keeps
        Get-ServerCheck's guard cascade, because G3 is a claim about what is
        installed and running here: a pack with no manifest record is unknown,
        not uninstalled. G3 is additionally gated per target server inside
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
        $checks += Get-PackAdaptationCheck -Pack $pack -Config $Config -Catalog $catalog `
            -RepoRoot $RepoRoot
        $checks += Get-PackDriftCheck -Pack $pack -Config $Config -Catalog $catalog `
            -SkillResults $SkillResults -Inventory $Inventory -Attended:$Attended
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
        Never removes an entry. A disabled server is skipped silently - that
        is simply not a defect condition. An attended-tier server without
        -Attended, a server whose launch command cannot be resolved, or a
        server that does not answer, is skipped with a WARN, and its
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

function Invoke-AgentVerification {
    <#
    .SYNOPSIS
        Runs the A0-A4 gate over every enabled agent.
    .DESCRIPTION
        Reads only the repo and the generated files, so all five checks run on
        every verification including -VerifyOnly on a host where the generation
        phase has never run (spec 8). A missing agent file is not itself a
        failure here - the gate judges the grant the config and catalog imply,
        which is what would be generated.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER Catalog
        From Get-ToolCatalog.
    .PARAMETER AgentDir
        Where generated agent files live. May not exist.
    .OUTPUTS
        [PSCustomObject] Name, Status, Findings, and a Reason on the not-testable
        branch where the config declares no agents.
    .EXAMPLE
        Invoke-AgentVerification -Config $cfg -Catalog $cat -AgentDir $d
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][object]$Catalog,
        [Parameter(Mandatory)][string]$AgentDir
    )

    # Indexer form: '.Properties.Name -notcontains' throws PropertyNotFoundStrict
    # of its own when Properties is completely empty.
    if ($null -eq $Config.PSObject.Properties['agents']) {
        return [PSCustomObject]@{ Name = 'agents'; Status = 'not-testable'
            Findings = @(); Reason = 'This config declares no agents.' }
    }

    $findings = @()
    foreach ($agent in @($Config.agents | Where-Object { $_.enabled })) {
        $path = Join-Path $AgentDir "$($agent.name).md"
        # No file yet means nothing has been generated; judge the grant the
        # config implies, using the name the generator would write.
        $fm = @{ name = "$($agent.name)" }
        if (Test-Path -LiteralPath $path) {
            $fm = Get-SkillFrontmatter -Text (Get-Content -LiteralPath $path -Raw)
        }
        $findings += Invoke-AgentGate -Agent $agent -Catalog $Catalog `
            -Frontmatter $fm -FileBaseName "$($agent.name)"
    }

    return [PSCustomObject]@{
        Name     = 'agents'
        Status   = $(if ($findings.Count) { 'failed' } else { 'pass' })
        Findings = $findings
    }
}

function Get-AgentCheck {
    <#
    .SYNOPSIS
        Runs the A0-A4 gate over every configured agent and reports it as one check.
    .DESCRIPTION
        Delegates to Invoke-AgentVerification, which reads only the repo and any
        generated agent files (spec 8), so this runs under -VerifyOnly on a host
        where phase 4 has never generated anything. AgentResults does not gate
        the outcome - the same over-grant is a defect whether or not this run
        regenerated the files - it only sizes the passing detail message.
    .PARAMETER Config
        The parsed configuration object.
    .PARAMETER AgentResults
        Results from Write-AgentConfiguration, or replayed from the manifest.
    .OUTPUTS
        [array] Empty when the config declares no agents, else one 'agents' check.
    .EXAMPLE
        Get-AgentCheck -Config $cfg -AgentResults $r
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$AgentResults
    )

    if ($null -eq $Config.PSObject.Properties['agents']) { return @() }

    try {
        $catalog = Get-ToolCatalog
    } catch {
        return @(New-CheckResult -Name 'agents' -Status 'not-testable' `
                -Detail $_.Exception.Message)
    }

    $agentDir = Join-Path $Config.paths.agentRoot '.claude\agents'
    $result = Invoke-AgentVerification -Config $Config -Catalog $catalog -AgentDir $agentDir
    if ($result.Findings.Count -gt 0) {
        $detail = ($result.Findings | ForEach-Object { "[$($_.Check)] $($_.Message)" }) -join ' | '
        return @(New-CheckResult -Name 'agents' -Status 'fail' -Detail $detail)
    }
    return @(New-CheckResult -Name 'agents' -Status 'pass' -Detail (
            "$($AgentResults.Count) agent(s) on record; the A0-A4 gate found no over-grant."))
}

function Get-SqlCheck {
    <#
    .SYNOPSIS
        Runs checks Q0 and Q1 over every enabled native-sse server.
    .DESCRIPTION
        Both read only the repo's config and the generated launchers, so they
        run on every verification including -VerifyOnly on a host where
        nothing is installed (spec 7.3, 5.1). The findings from every target
        server are folded into one "sql" check, mirroring how Get-AgentCheck
        folds the A0-A4 findings into one "agents" check.
    .PARAMETER Config
        The parsed configuration object.
    .OUTPUTS
        [array] Empty when the config declares no native-sse servers, else one
        'sql' check.
    .EXAMPLE
        Get-SqlCheck -Config $cfg
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Config)

    $servers = @($Config.mcpServers | Where-Object {
            ($_.PSObject.Properties.Name -contains 'kind') -and $_.kind -eq 'native-sse' -and
            $_.enabled
        })
    if ($servers.Count -eq 0) { return @() }

    $findings = @()
    foreach ($server in $servers) {
        $installDir = Join-Path (Join-Path $Config.paths.toolRoot 'mcp') $server.name
        $launcher = Join-Path $installDir "launch-$($server.name).cmd"
        $findings += Test-ReadOnlyLaunchCheck -Server $server -LauncherPath $launcher
        $findings += Test-PdbPathCheck -Server $server -SymbolRoot $Config.paths.symbolCache
    }

    if ($findings.Count -gt 0) {
        $detail = ($findings | ForEach-Object { "[$($_.Check)] $($_.Message)" }) -join ' | '
        return @(New-CheckResult -Name 'sql' -Status 'fail' -Detail $detail)
    }
    return @(New-CheckResult -Name 'sql' -Status 'pass' -Detail (
            "$($servers.Count) native-sse server(s) on record; Q0/Q1 found no issues."))
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
    .PARAMETER AgentResults
        Results from Write-AgentConfiguration, or replayed from the manifest.
    .PARAMETER Inventory
        The host inventory.
    .PARAMETER RepoRoot
        Repository root holding vendor\skills, for the skill adaptation gate.
    .PARAMETER Attended
        Include tier-2 checks.
    .PARAMETER AdditionalChecks
        Checks from another configured agent client, such as Codex registration
        and its project-workspace C0-C8 verification group.
    .EXAMPLE
        Invoke-Verification -Config $c.Config -ServerResults $c.ServerResults -Inventory $c.Inventory
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ServerResults,
        [AllowEmptyCollection()][array]$SkillResults = @(),
        [AllowEmptyCollection()][array]$AgentResults = @(),
        [object]$Inventory = $null,
        [string]$RepoRoot = '',
        [switch]$Attended,
        [AllowEmptyCollection()][array]$AdditionalChecks = @()
    )

    $checks = @()
    $claude = if ($Inventory) { $Inventory.ClaudeCode } else { $null }

    $checks += Test-ClaudeCli -ClaudePath $claude
    $checks += Test-ClaudeMcpList -ClaudePath $claude -WorkingDirectory $Config.paths.agentRoot
    $checks += Test-GeneratedConfig -Config $Config
    $checks += $AdditionalChecks

    $checks += Get-ServerCheck -Config $Config -ServerResults $ServerResults -Attended:$Attended
    $checks += Get-SkillCheck -Config $Config -SkillResults $SkillResults -RepoRoot $RepoRoot `
        -Inventory $Inventory -Attended:$Attended
    $checks += Get-AgentCheck -Config $Config -AgentResults $AgentResults
    $checks += Get-SqlCheck -Config $Config

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

function Assert-VerificationPassed {
    <# .SYNOPSIS
        Throws when one or more verification checks failed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Checks
    )

    $failed = @($Checks | Where-Object { $_.Status -eq 'fail' })
    if ($failed.Count -gt 0) {
        $names = @($failed | ForEach-Object { $_.Name }) -join ', '
        throw "$($failed.Count) verification check(s) failed: $names"
    }
}

Export-ModuleMember -Function New-CheckResult, Invoke-McpProbe, Test-ClaudeCli, `
    Test-ClaudeMcpList, Test-GeneratedConfig, Test-ServerNotTestable, `
    Get-ProbeScriptPath, Test-PyghidraLive, Test-WindbgLive, Invoke-Verification, `
    Test-HttpServerLive, Get-HostAppHint, Get-ProbeInterpreter, Get-ServerCheck, `
    Get-ServerProbeContext, Get-SkillPackDirectory, Get-SkillPackFile, Merge-CheckStatus, `
    Test-SkillAdaptationCheck, Test-ToolCatalogPin, Test-ToolCatalogLive, `
    Get-SkillDriftLiveCheck, Test-SkillDriftCheck, Get-ServerSourcePin, `
    Get-PackPinCheck, `
    Get-PackAdaptationCheck, Get-PackDriftCheck, Get-SkillCheck, `
    ConvertFrom-CatalogServerMap, Update-CatalogServerEntry, Save-ToolCatalog, `
    Invoke-AgentVerification, Get-AgentCheck, Test-ReadOnlyLaunchCheck, Get-SqlCheck, `
    Assert-VerificationPassed
