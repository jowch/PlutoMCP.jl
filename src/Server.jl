# ---------------------------------------------------------------------------
# URL query-string parser (avoids HTTP.URIs API uncertainty)
# ---------------------------------------------------------------------------

function _query_params(target::String)
    d   = Dict{String,String}()
    idx = findfirst('?', target)
    idx === nothing && return d
    for pair in split(target[idx+1:end], '&')
        kv = split(pair, '='; limit=2)
        length(kv) == 2 && (d[kv[1]] = kv[2])
    end
    d
end

# ---------------------------------------------------------------------------
# SSE session state
# ---------------------------------------------------------------------------

const _SSE_SESSIONS      = Dict{String,Channel{String}}()
const _SSE_SESSIONS_LOCK = ReentrantLock()

# ---------------------------------------------------------------------------
# Internal HTTP/SSE endpoint handlers
# ---------------------------------------------------------------------------

function _handle_sse(http::HTTP.Stream)
    sid = string(uuid4())
    ch  = Channel{String}(64)

    lock(_SSE_SESSIONS_LOCK) do
        _SSE_SESSIONS[sid] = ch
    end

    HTTP.setheader(http, "Content-Type"  => "text/event-stream")
    HTTP.setheader(http, "Cache-Control" => "no-cache")
    HTTP.setheader(http, "Connection"    => "keep-alive")
    HTTP.startwrite(http)

    # Tell the client where to POST messages
    write(http, "event: endpoint\ndata: /message?sessionId=$sid\n\n")
    flush(http)

    # Background keepalive so proxies don't close idle connections
    keepalive = @async while isopen(ch)
        sleep(15)
        try
            write(http, ": keepalive\n\n")
            flush(http)
        catch
            break
        end
    end

    try
        for msg_json in ch
            write(http, "event: message\ndata: $msg_json\n\n")
            flush(http)
        end
    catch
        # Client disconnected
    finally
        lock(_SSE_SESSIONS_LOCK) do
            delete!(_SSE_SESSIONS, sid)
        end
        isopen(ch) && close(ch)
        try schedule(keepalive, InterruptException(); error=true) catch end
    end
end

function _handle_post(http::HTTP.Stream, pluto_session)
    params = _query_params(http.message.target)
    sid    = get(params, "sessionId", "")

    ch = lock(_SSE_SESSIONS_LOCK) do
        get(_SSE_SESSIONS, sid, nothing)
    end

    if ch === nothing
        HTTP.setstatus(http, 404)
        HTTP.startwrite(http)
        write(http, """{"error":"Session not found"}""")
        return
    end

    body = String(read(http))
    msg  = try
        JSON.parse(body, Dict{String,Any})
    catch
        HTTP.setstatus(http, 400)
        HTTP.startwrite(http)
        write(http, """{"error":"Invalid JSON"}""")
        return
    end

    resp = _dispatch_mcp(pluto_session, msg)
    isopen(ch) && resp !== nothing && put!(ch, JSON.json(resp))

    HTTP.setstatus(http, 202)
    HTTP.startwrite(http)
end

# ---------------------------------------------------------------------------
# HTTP/SSE MCP server
# ---------------------------------------------------------------------------

function _run_http_mcp_server(pluto_session, port::Int; listenany::Bool=false)
    # Capture identity at bind time so /health never follows a later global swap.
    bound_snapshot = session_binding()
    bound = bound_snapshot !== nothing

    function handler(http::HTTP.Stream)
        # CORS on every response
        HTTP.setheader(http, "Access-Control-Allow-Origin" => "*")

        method = http.message.method
        target = http.message.target

        if method == "OPTIONS"
            HTTP.setheader(http, "Access-Control-Allow-Methods" => "GET, POST, OPTIONS")
            allow = bound ? "Content-Type, $STYX_SESSION_HEADER" : "Content-Type"
            HTTP.setheader(http, "Access-Control-Allow-Headers" => allow)
            HTTP.setstatus(http, 200)
            HTTP.startwrite(http)

        elseif !bound && method == "GET" && startswith(target, "/sse")
            _handle_sse(http)

        elseif !bound && method == "POST" && startswith(target, "/message")
            _handle_post(http, pluto_session)

        elseif method == "POST" && startswith(target, "/call")
            # Must read the body before responding (HTTP.jl stream contract).
            body = String(read(http))
            if bound
                hdr = HTTP.header(http.message, STYX_SESSION_HEADER, "")
                if hdr != bound_snapshot.session_id
                    HTTP.setstatus(http, 409)
                    HTTP.setheader(http, "Content-Type" => "application/json")
                    HTTP.startwrite(http)
                    write(http, """{"error":"foreign_session","message":"The loopback bridge does not match this Cursor window's Styx session."}""")
                    return
                end
            end
            msg  = try
                JSON.parse(body, Dict{String,Any})
            catch
                HTTP.setstatus(http, 400)
                HTTP.startwrite(http)
                write(http, """{"error":"Invalid JSON"}""")
                return
            end
            active   = standalone_session()
            sess     = active !== nothing ? active : pluto_session
            resp     = _dispatch_mcp(sess, msg)
            resp_json = resp !== nothing ? JSON.json(resp) : "{}"
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/json")
            HTTP.startwrite(http)
            write(http, resp_json)

        elseif method == "GET" && (target == "/health" || startswith(target, "/health?"))
            HTTP.setstatus(http, 200)
            if bound
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(http, JSON.json(health_payload(bound_snapshot)))
            else
                HTTP.startwrite(http)
                write(http, "ok")
            end

        else
            HTTP.setstatus(http, 404)
            HTTP.startwrite(http)
        end
    end

    return HTTP.serve!(
        handler, "127.0.0.1", port;
        stream=true, verbose=false, listenany=listenany,
    )
end

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

"""
    serve(; pluto_port=1234, mcp_port=2346, notebook=nothing, launch_browser=true,
           require_secret_for_access=true, eval_log=nothing, eval_run_id=nothing,
           eval_redact_code=missing)

Start a Pluto server and expose it via an MCP HTTP/SSE interface.

Forwards `require_secret_for_access` to Pluto `Options` (default `true`). Pass `false`
to serve `http://localhost:PORT/` without a `?secret=` URL.

!!! warning
    The secret is Pluto's only access control. With `require_secret_for_access=false`,
    anything that can reach the port can execute arbitrary Julia code as you — including
    other users of a shared machine. Only turn it off on a single-user machine or a
    trusted port-forward.

## Workflow

Run this once (e.g. from a terminal or startup script) when you want Claude to have access:

```julia
using PlutoMCP
PlutoMCP.serve()          # Pluto on :1234, MCP bridge on :2346
```

Then configure your MCP client **once**:

### Claude Desktop — HTTP (preferred)

```json
{
  "mcpServers": {
    "pluto": { "url": "http://localhost:2346/sse" }
  }
}
```

### Claude Desktop — stdio fallback (if HTTP MCP not yet supported)

```json
{
  "mcpServers": {
    "pluto": {
      "command": "julia",
      "args": ["-e", "using PlutoMCP; PlutoMCP.connect()"]
    }
  }
}
```

The bridge must be running before an HTTP/SSE client connects.
For stdio clients, use `connect()` instead — call `start_pluto_session` before notebook tools (D15 deferred mode).
"""
function serve(;
    pluto_port=1234,
    mcp_port=2346,
    notebook=nothing,
    launch_browser=true,
    require_secret_for_access=true,
    eval_log=nothing,
    eval_run_id=nothing,
    eval_redact_code=missing,
)
    configure_eval_log!(path=eval_log, run_id=eval_run_id, redact_code=eval_redact_code)

    configure_standalone!(;
        pluto_port = pluto_port,
        mcp_port = mcp_port,
        require_secret_for_access = require_secret_for_access,
    )
    start_pluto_stack!(;
        pluto_port,
        mcp_port,
        require_secret_for_access,
        launch_browser,
        notebook,
        http_async = false,
    )
    pluto_session = standalone_session()

    @info "PlutoMCP ready"
    @info "  Pluto UI       → http://localhost:$pluto_port"
    @info "  MCP bridge     → http://localhost:$mcp_port/sse"
    @info "  stdio fallback → julia -e 'using PlutoMCP; PlutoMCP.connect(mcp_port=$mcp_port)'"

    http_server = _run_http_mcp_server(pluto_session, mcp_port)
    try
        wait(http_server)
    finally
        stop_pluto_stack!()
    end
end

# ---------------------------------------------------------------------------
# Public API (continued)
# ---------------------------------------------------------------------------

"""
    connect(; pluto_port=1234, mcp_port=2346, require_secret_for_access=true,
              binding_file=nothing, runtime_dir=nothing, cursor_host_pid=nothing,
              pluto_port_hint=nothing, mcp_port_hint=nothing)

Self-contained stdio MCP server for clients that require a stdio subprocess
(e.g. Claude Desktop, Cursor). Forwards `require_secret_for_access` when starting
its own Pluto session (default `true`) — see the warning in [`serve`](@ref)
before setting it to `false`.

**Bound mode (Styx):** pass `binding_file`, `runtime_dir`, and `cursor_host_pid`.
Owns a loopback control bridge immediately, publishes a JSON `/health` nonce, and
never proxies to a foreign bridge. Ports are allocated with `listenany` from the
hint values (`pluto_port_hint` / `mcp_port_hint`, falling back to `pluto_port` /
`mcp_port`).

**Legacy unbound mode:** if this process has not started Pluto, and an HTTP
bridge answers `GET /health` on `mcp_port`, the call is proxied to that bridge.
If no bridge is running, deferred mode: call `start_pluto_session` before notebook
tools (D15).

## Claude Desktop config (legacy)

```json
{
  "mcpServers": {
    "pluto": {
      "command": "julia",
      "args": ["-e", "using PlutoMCP; PlutoMCP.connect()"]
    }
  }
}
```
"""
function connect(;
    pluto_port=1234,
    mcp_port=2346,
    require_secret_for_access=true,
    binding_file=nothing,
    runtime_dir=nothing,
    cursor_host_pid=nothing,
    pluto_port_hint=nothing,
    mcp_port_hint=nothing,
)
    _run_standalone_stdio(
        pluto_port,
        mcp_port;
        require_secret_for_access,
        binding_file,
        runtime_dir,
        cursor_host_pid,
        pluto_port_hint,
        mcp_port_hint,
    )
end

function bridge_running(mcp_port::Integer)
    try
        resp = HTTP.get("http://127.0.0.1:$mcp_port/health";
                        readtimeout=2, connect_timeout=1)
        resp.status == 200
    catch
        false
    end
end

function _proxy_mcp_message(mcp_port::Integer, msg::Dict{String,Any})
    id = get(msg, "id", nothing)
    try
        r = HTTP.post(
            "http://127.0.0.1:$mcp_port/call";
            body    = JSON.json(msg),
            headers = ["Content-Type" => "application/json"],
            readtimeout = 120,
        )
        JSON.parse(String(r.body), Dict{String,Any})
    catch e
        id === nothing && return nothing
        _err(id, -32603, "Bridge proxy error: $(sprint(showerror, e))")
    end
end

"""
Dispatch one stdio JSON-RPC message.

Bound mode always dispatches in-process (never proxies).
Legacy mode uses an in-process session when this process owns Pluto; otherwise
proxies to a live HTTP bridge on `mcp_port` when `/health` is up.
"""
function dispatch_stdio_message(msg::Dict{String,Any}; mcp_port::Union{Integer,Nothing} = _STANDALONE_MCP_PORT[])
    get(msg, "id", nothing) === nothing && return nothing

    local_sess = standalone_session()
    if local_sess !== nothing || is_bound_session()
        return _dispatch_mcp(local_sess, msg)
    end
    if mcp_port !== nothing && bridge_running(mcp_port)
        return _proxy_mcp_message(mcp_port, msg)
    end
    return _dispatch_mcp(nothing, msg)
end

# ---------------------------------------------------------------------------
# Standalone mode: deferred Pluto (D15) — lifecycle tools start the session
# ---------------------------------------------------------------------------

function _run_standalone_stdio(
    pluto_port::Int,
    mcp_port::Int;
    require_secret_for_access=true,
    binding_file=nothing,
    runtime_dir=nothing,
    cursor_host_pid=nothing,
    pluto_port_hint=nothing,
    mcp_port_hint=nothing,
)
    bound = binding_file !== nothing || runtime_dir !== nothing || cursor_host_pid !== nothing
    if bound
        (binding_file === nothing || runtime_dir === nothing || cursor_host_pid === nothing) &&
            error("styx_identity_unavailable::bound connect() requires binding_file, runtime_dir, and cursor_host_pid")
        configure_session_binding!(SessionBinding(;
            runtime_dir = String(runtime_dir),
            binding_file = String(binding_file),
            cursor_host_pid = Int(cursor_host_pid),
        ))
        claim_window_binding!(session_binding())
    end

    hint_pluto = pluto_port_hint === nothing ? pluto_port : Int(pluto_port_hint)
    hint_mcp = mcp_port_hint === nothing ? mcp_port : Int(mcp_port_hint)
    configure_standalone!(;
        pluto_port = pluto_port,
        mcp_port = mcp_port,
        pluto_port_hint = hint_pluto,
        mcp_port_hint = hint_mcp,
        require_secret_for_access = require_secret_for_access,
    )

    try
        if bound
            start_control_bridge!(; mcp_port_hint = hint_mcp, listenany = true)
        end

        if get(ENV, "PLUTOMCP_AUTO_SERVE", "0") == "1"
            start_pluto_stack!()
        end

        while !eof(stdin)
            msg = _read_message(stdin)
            msg === nothing && break

            port = _STANDALONE_MCP_PORT[]
            resp = dispatch_stdio_message(msg; mcp_port = port === nothing ? mcp_port : port)
            resp === nothing && continue
            _write_message(stdout, resp)
        end
    finally
        stop_pluto_stack!(; close_control_bridge = true)
        cleanup_session_binding!()
    end
end
