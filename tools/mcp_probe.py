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

Note: pass arguments as --opt=value. A bare '--arg --no-symbols' is parsed by
argparse as a missing value, because the value itself starts with a dash.
"""

import argparse
import asyncio
import json
import os
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


async def probe_http(args):
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    headers = parse_pairs(args.header)
    async with streamablehttp_client(args.url, headers=headers) as (read, write, _):
        async with ClientSession(read, write) as session:
            return await run_checks(session, args)


def planned_calls(args):
    """Return the list of {tool, args} to make, from --calls or --tool."""
    if args.calls:
        return json.loads(args.calls)
    if args.tool:
        return [{"tool": args.tool, "args": parse_pairs(args.tool_arg)}]
    return []


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

    for planned in planned_calls(args):
        response = await session.call_tool(planned["tool"], planned.get("args", {}))
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
        # A tool that errors is exactly the "connected but broken" case a bare
        # handshake would have reported as healthy.
        if record["isError"] or not text.strip():
            result["ok"] = False
            break

    # Kept for single-call callers that read .call directly.
    result["call"] = result["calls"][0] if result["calls"] else None
    return result


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
        result = {"ok": False, "error": "%s: %s" % (type(exc).__name__, exc)}

    json.dump(result, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
