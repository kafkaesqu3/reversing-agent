"""Probe an MCP server and report the result as JSON on stdout.

Run with the interpreter from the server's own venv: those venvs already carry
the `mcp` client library as a dependency, so nothing extra is installed and the
probe always speaks the same protocol version as the server it is testing.

Exit code is 0 whether the probe passes or fails - the caller reads `ok` from
the JSON. A non-zero exit means the probe itself broke, which is a different
problem and must not be reported as a server failure.

Usage
-----
  mcp_probe.py --transport stdio --command <exe> [--arg A]... [--env K=V]...
               [--tool NAME] [--tool-arg K=V]...
  mcp_probe.py --transport http --url http://127.0.0.1:8762/mcp
               [--header K=V]... [--tool NAME] [--tool-arg K=V]...

For several calls that must share one session, pass --calls with a JSON array
of {"tool": NAME, "args": {...}} instead of --tool.

A call may also carry {"capture": {"NAME": "REGEX"}}: the first capturing group
of REGEX is matched against that call's text and stored, and any later argument
written as "{{NAME}}" is replaced with it. mcp-windbg needs this - open_cdb_dump
mints a session_id that run_cdb_command then requires.

Note: pass arguments as --opt=value. A bare '--arg --no-symbols' is parsed by
argparse as a missing value, because the value itself starts with a dash.
"""

import argparse
import asyncio
import json
import os
import re
import sys


def parse_pairs(values):
    """Parse repeated K=V arguments into a dict."""
    out = {}
    for item in values or []:
        if "=" not in item:
            raise ValueError("expected KEY=VALUE, got %r" % item)
        key, value = item.split("=", 1)
        out[key] = value
    return out


async def probe_stdio(args):
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    env = dict(os.environ)
    env.update(parse_pairs(args.env))
    params = StdioServerParameters(
        command=args.command, args=list(args.arg or []), env=env
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            return await run_checks(session, args)


def http_transport(url, headers):
    """Open a streamable-http transport across both mcp client generations.

    mcp 1.x exposes streamablehttp_client(url, headers=...) and yields three
    streams; mcp 2.x renamed it, moved headers onto a pre-built http client,
    and yields two. Both live on this host - one per server venv - so the probe
    has to speak either.
    """
    try:
        from mcp.client.streamable_http import streamablehttp_client

        return streamablehttp_client(url, headers=headers)
    except ImportError:
        import httpx2
        from mcp.client.streamable_http import streamable_http_client

        return streamable_http_client(
            url, http_client=httpx2.AsyncClient(headers=headers)
        )


async def probe_http(args):
    from mcp import ClientSession

    async with http_transport(args.url, parse_pairs(args.header)) as streams:
        async with ClientSession(streams[0], streams[1]) as session:
            return await run_checks(session, args)


def planned_calls(args):
    """Return the list of {tool, args} to make, from --calls or --tool."""
    if args.calls:
        return json.loads(args.calls)
    if args.tool:
        return [{"tool": args.tool, "args": parse_pairs(args.tool_arg)}]
    return []


def resolve(value, captured):
    """Replace every {{name}} placeholder in a string with a captured value."""
    if not isinstance(value, str):
        return value
    for key, found in captured.items():
        value = value.replace("{{%s}}" % key, found)
    return value


async def run_checks(session, args):
    """Initialize, list tools, then make each planned call in ONE session.

    Sequential calls share a session deliberately: mcp-windbg's open_cdb_dump
    establishes state that run_cdb_command then uses, so probing them in
    separate sessions would test nothing.
    """
    await session.initialize()
    tools = await session.list_tools()
    result = {
        "ok": True,
        "toolCount": len(tools.tools),
        "tools": sorted(t.name for t in tools.tools),
        "calls": [],
    }

    captured = {}
    for planned in planned_calls(args):
        call_args = {
            k: resolve(v, captured) for k, v in planned.get("args", {}).items()
        }
        response = await session.call_tool(planned["tool"], call_args)
        text = ""
        for block in response.content:
            text += getattr(block, "text", "") or ""
        record = {
            "tool": planned["tool"],
            "isError": bool(getattr(response, "isError", False)),
            "text": text[: args.max_chars],
            "length": len(text),
        }
        result["calls"].append(record)
        capture_failed = False
        for key, pattern in (planned.get("capture") or {}).items():
            match = re.search(pattern, text)
            if not match:
                record["captureFailed"] = key
                result["ok"] = False
                capture_failed = True
                break
            captured[key] = match.group(1)
        if capture_failed:
            break
        # A tool that errors is exactly the "connected but broken" case a bare
        # handshake would have reported as healthy.
        if record["isError"] or not text.strip():
            result["ok"] = False
            break

    # Kept for single-call callers that read .call directly.
    result["call"] = result["calls"][0] if result["calls"] else None
    return result


def describe(exc):
    """Render an exception, flattening ExceptionGroup into its causes.

    anyio wraps everything a TaskGroup raises, so the default text is always
    'unhandled errors in a TaskGroup (1 sub-exception)' - which names neither
    the server nor the fault.
    """
    subs = getattr(exc, "exceptions", None)
    if subs:
        return "%s: [%s]" % (type(exc).__name__, "; ".join(describe(s) for s in subs))
    return "%s: %s" % (type(exc).__name__, exc)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transport", required=True, choices=["stdio", "http"])
    parser.add_argument("--command")
    parser.add_argument("--arg", action="append")
    parser.add_argument("--env", action="append")
    parser.add_argument("--url")
    parser.add_argument("--header", action="append")
    parser.add_argument("--tool")
    parser.add_argument("--tool-arg", action="append")
    parser.add_argument(
        "--calls",
        help='JSON array of {"tool": NAME, "args": {...}} made in one session',
    )
    parser.add_argument("--timeout", type=float, default=600.0)
    parser.add_argument("--max-chars", type=int, default=4000)
    args = parser.parse_args()

    if args.transport == "stdio" and not args.command:
        parser.error("--command is required for stdio")
    if args.transport == "http" and not args.url:
        parser.error("--url is required for http")

    coroutine = probe_stdio(args) if args.transport == "stdio" else probe_http(args)
    try:
        result = asyncio.run(asyncio.wait_for(coroutine, timeout=args.timeout))
    except asyncio.TimeoutError:
        result = {"ok": False, "error": "timed out after %ss" % args.timeout}
    except Exception as exc:  # noqa: BLE001 - report any failure as data
        result = {"ok": False, "error": describe(exc)}

    json.dump(result, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
