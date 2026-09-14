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
import io
import json
import os
import re
import socket
import sys
import time


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


class _SocketLineReader:
    """Buffers bytes off a blocking socket for line- and length-based reads."""

    def __init__(self, sock):
        self._sock = sock
        self._buf = b""

    def _fill(self):
        chunk = self._sock.recv(4096)
        if not chunk:
            raise ConnectionError("connection closed before the expected data arrived")
        self._buf += chunk

    def read_line(self):
        while b"\r\n" not in self._buf:
            self._fill()
        line, self._buf = self._buf.split(b"\r\n", 1)
        return line

    def read_exact(self, size):
        while len(self._buf) < size:
            self._fill()
        data, self._buf = self._buf[:size], self._buf[size:]
        return data


def _read_headers(reader):
    """Read a status line and headers, tolerating repeated header names.

    pdbsql sends a duplicate Content-Type on its SSE handshake - collect every
    (name, value) pair instead of assuming one value per name.
    """
    status_line = reader.read_line().decode("latin-1")
    headers = []
    while True:
        line = reader.read_line()
        if not line:
            break
        name, _, value = line.decode("latin-1").partition(":")
        headers.append((name.strip().lower(), value.strip()))
    return status_line, headers


def _status_code(status_line):
    """Parse the numeric status code out of an HTTP status line."""
    parts = status_line.split(" ", 2)
    if len(parts) < 2:
        raise RuntimeError("malformed HTTP status line: %r" % status_line)
    return int(parts[1])


def _read_sse_endpoint(reader):
    """Chunk-decode the SSE handshake body until the endpoint event arrives.

    Only the handshake is read here - after the endpoint path is captured,
    nothing reads this socket again. Reading further chunks from the SSE
    stream under async I/O is exactly what hangs against pdbsql; a blocking
    socket does not hang, but there is no reason to lean on it past the
    handshake when every JSON-RPC answer is available from its own POST.
    """
    body = b""
    while True:
        size_line = reader.read_line()
        size = int(size_line.split(b";", 1)[0], 16)
        if size == 0:
            break
        body += reader.read_exact(size)
        reader.read_exact(2)  # the chunk's trailing CRLF
        match = re.search(rb"event:\s*endpoint\s*\ndata:\s*(\S+)", body)
        if match:
            return match.group(1).decode("utf-8")
    raise RuntimeError("SSE handshake ended without an endpoint event")


def _post_json_rpc(host, port, path, payload, timeout):
    """POST one JSON-RPC message and return the response's own JSON body.

    pdbsql answers a POST directly with the JSON-RPC result (it also echoes
    the same result onto the original GET/SSE stream, but the POST response
    alone is proven sufficient - see the task-7fix brief). A fresh connection
    per POST is deliberate: this is proven to work and pipelining/reuse is not.
    """
    body = json.dumps(payload).encode("utf-8")
    request = (
        "POST %s HTTP/1.1\r\n"
        "Host: %s:%d\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n"
        "\r\n"
    ) % (path, host, port, len(body))
    sock = socket.create_connection((host, port), timeout=timeout)
    try:
        sock.sendall(request.encode("latin-1") + body)
        reader = _SocketLineReader(sock)
        status_line, headers = _read_headers(reader)
        code = _status_code(status_line)
        if code < 200 or code >= 300:
            raise RuntimeError("POST %s got HTTP %d" % (path, code))
        length_value = next((v for k, v in headers if k == "content-length"), None)
        if length_value is None:
            raise RuntimeError("POST %s response had no Content-Length header" % path)
        response_body = reader.read_exact(int(length_value))
    finally:
        sock.close()
    return json.loads(response_body.decode("utf-8"))


def _post_notification(host, port, path, payload, timeout):
    """POST a fire-and-forget JSON-RPC notification; ignore whatever comes back.

    notifications/initialized has no id and expects no JSON-RPC reply, so
    whatever HTTP response arrives (a body, an empty 202, a missing
    Content-Length) is read best-effort and discarded rather than treated
    as a protocol violation.
    """
    try:
        _post_json_rpc(host, port, path, payload, timeout)
    except Exception:
        pass


class _BlockingSSESession:
    """An MCP session over pdbsql's SSE transport, using blocking sockets.

    Every async Python HTTP client tested hangs reading pdbsql's SSE stream
    (see the sql-query-layer plan's task-7fix brief for the full diagnosis);
    blocking sockets read the same stream instantly. The methods below do
    blocking socket I/O directly in their bodies rather than via
    asyncio.to_thread - this is a single-purpose CLI probe with nothing else
    running concurrently, so briefly blocking the event loop costs nothing,
    and it keeps the socket handling simple to follow.
    """

    def __init__(self, url, headers, timeout):
        import urllib.parse

        parsed = urllib.parse.urlsplit(url)
        self._host = parsed.hostname
        self._port = parsed.port or 80
        self._headers = headers
        self._timeout = timeout
        # A wall-clock deadline, not a per-call timeout: every socket op below
        # asks for only what's left of it, so a session with several
        # round-trips (init + notification + list_tools + each planned call)
        # is bounded by args.timeout total, matching stdio/http instead of
        # letting each op claim a fresh full timeout of its own.
        self._deadline = time.monotonic() + timeout
        self._next_id = 0
        self._sse_sock = None
        try:
            self._endpoint_path = self._handshake(parsed.path or "/")
        except Exception:
            if self._sse_sock is not None:
                self._sse_sock.close()
            raise

    def _remaining(self):
        remaining = self._deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("timed out after %ss" % self._timeout)
        return remaining

    def _handshake(self, path):
        # pdbsql ties the session to this connection: closing it invalidates
        # the session almost immediately, so it is kept open (and unread)
        # for the session's whole lifetime rather than closed once the
        # endpoint path is captured - see the task-7fix-report's live-test
        # finding for how this was discovered.
        self._sse_sock = socket.create_connection(
            (self._host, self._port), timeout=self._remaining()
        )
        lines = [
            "GET %s HTTP/1.1" % path,
            "Host: %s:%d" % (self._host, self._port),
            "Accept: text/event-stream",
        ]
        for name, value in self._headers.items():
            lines.append("%s: %s" % (name, value))
        lines.append("")
        lines.append("")
        self._sse_sock.sendall("\r\n".join(lines).encode("latin-1"))
        reader = _SocketLineReader(self._sse_sock)
        _read_headers(reader)
        return _read_sse_endpoint(reader)

    def close(self):
        if self._sse_sock is not None:
            self._sse_sock.close()

    def _request(self, method, params):
        self._next_id += 1
        payload = {"jsonrpc": "2.0", "id": self._next_id, "method": method, "params": params}
        return _post_json_rpc(
            self._host, self._port, self._endpoint_path, payload, self._remaining()
        )

    async def initialize(self):
        response = self._request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "mcp", "version": "0.1.0"},
            },
        )
        if "error" in response:
            raise RuntimeError("initialize failed: %s" % response["error"])
        _post_notification(
            self._host,
            self._port,
            self._endpoint_path,
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            self._remaining(),
        )
        return response.get("result")

    async def list_tools(self):
        from types import SimpleNamespace

        response = self._request("tools/list", {})
        if "error" in response:
            raise RuntimeError("tools/list failed: %s" % response["error"])
        tools = [SimpleNamespace(name=tool["name"]) for tool in response["result"]["tools"]]
        return SimpleNamespace(tools=tools)

    async def call_tool(self, name, args):
        from types import SimpleNamespace

        response = self._request("tools/call", {"name": name, "arguments": args})
        if "error" in response:
            text = response["error"].get("message", str(response["error"]))
            return SimpleNamespace(content=[SimpleNamespace(text=text)], isError=True)
        result = response["result"]
        content = [
            SimpleNamespace(text=block.get("text", "")) for block in result.get("content", [])
        ]
        return SimpleNamespace(content=content, isError=bool(result.get("isError", False)))


async def probe_sse(args):
    """Probe an SSE server with the blocking-socket session (see above).

    mcp.client.sse.sse_client hangs indefinitely reading pdbsql's SSE stream
    under every async I/O client tested; _BlockingSSESession is this repo's
    own fix, not a workaround inside the third-party mcp SDK.
    """
    session = _BlockingSSESession(args.url, parse_pairs(args.header), args.timeout)
    try:
        return await run_checks(session, args)
    finally:
        session.close()


async def probe_http(args):
    from mcp import ClientSession

    async with http_transport(args.url, parse_pairs(args.header)) as streams:
        async with ClientSession(streams[0], streams[1]) as session:
            return await run_checks(session, args)


def planned_calls(args):
    """Return the list of {tool, args} to make, from --calls* or --tool."""
    if args.calls_file:
        with io.open(args.calls_file, encoding="utf-8") as handle:
            return json.loads(handle.read())
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
    parser.add_argument("--transport", required=True,
                        choices=["stdio", "http", "sse"])
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
    parser.add_argument(
        "--calls-file",
        help="File holding the same JSON array as --calls. Callers on Windows "
        "PowerShell 5.1 must use this: it strips the double quotes out of a "
        "native command's arguments, so inline JSON never survives the call.",
    )
    parser.add_argument("--timeout", type=float, default=600.0)
    parser.add_argument("--max-chars", type=int, default=4000)
    args = parser.parse_args()

    if args.transport == "stdio" and not args.command:
        parser.error("--command is required for stdio")
    if args.transport in ("http", "sse") and not args.url:
        parser.error("--url is required for http")

    if args.transport == "stdio":
        coroutine = probe_stdio(args)
    elif args.transport == "sse":
        coroutine = probe_sse(args)
    else:
        coroutine = probe_http(args)
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
