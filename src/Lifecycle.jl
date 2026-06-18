# D15 — deferred Pluto session lifecycle (standalone connect + lifecycle MCP tools).

const LIFECYCLE_TOOLS = Set([
    "pluto_session_status",
    "start_pluto_session",
    "stop_pluto_session",
    "open_notebook",
])

is_lifecycle_tool(name::AbstractString) = name in LIFECYCLE_TOOLS

const _STANDALONE_SESSION = Ref{Any}(nothing)
const _STANDALONE_HTTP_TASK = Ref{Union{Nothing,Task}}(nothing)
const _STANDALONE_PLUTO_PORT = Ref(1234)
const _STANDALONE_MCP_PORT = Ref(2346)
const _STANDALONE_REQUIRE_SECRET = Ref(true)
const _HTTP_BRIDGE_RUNNER = Ref{Function}(
    (session, port) -> error("HTTP bridge not registered"),
)

function register_http_bridge!(f::Function)
    _HTTP_BRIDGE_RUNNER[] = f
end

function configure_standalone!(; pluto_port=1234, mcp_port=2346, require_secret_for_access=true)
    _STANDALONE_PLUTO_PORT[] = pluto_port
    _STANDALONE_MCP_PORT[] = mcp_port
    _STANDALONE_REQUIRE_SECRET[] = require_secret_for_access
end

function standalone_session()
    _STANDALONE_SESSION[]
end

function pluto_running_standalone()
    _STANDALONE_SESSION[] !== nothing
end

function _notebook_summaries(session)
    [
        Dict{String,Any}(
            "notebook_id" => string(nb.notebook_id),
            "path"        => nb.path,
            "cell_count"  => length(nb.cell_order),
        )
        for nb in values(session.notebooks)
    ]
end

function session_status_dict()
    sess = _STANDALONE_SESSION[]
    Dict{String,Any}(
        "pluto"      => sess === nothing ? "stopped" : "running",
        "pluto_port" => _STANDALONE_PLUTO_PORT[],
        "mcp_port"   => _STANDALONE_MCP_PORT[],
        "notebooks"  => sess === nothing ? [] : _notebook_summaries(sess),
    )
end

function _init_pluto_session!(; pluto_port, launch_browser, require_secret_for_access, notebook)
    opts = Pluto.Configuration.from_flat_kwargs(
        port                      = pluto_port,
        launch_browser            = launch_browser,
        require_secret_for_access = require_secret_for_access,
    )
    sess = Pluto.ServerSession(; options = opts)
    if notebook !== nothing
        Pluto.SessionActions.open(sess, notebook; run_async = true)
    end
    @async try
        Pluto.run!(sess)
    catch e
        @error "Pluto server error" exception=(e, catch_backtrace())
    end
    sleep(1.0)
    sess
end

"""
    start_pluto_stack!(; pluto_port, mcp_port, require_secret_for_access, launch_browser, notebook, http_async)

Start Pluto.run! and the MCP HTTP bridge. Idempotent when already running.
"""
function start_pluto_stack!(;
    pluto_port::Int = _STANDALONE_PLUTO_PORT[],
    mcp_port::Int = _STANDALONE_MCP_PORT[],
    require_secret_for_access::Bool = _STANDALONE_REQUIRE_SECRET[],
    launch_browser::Bool = false,
    notebook = nothing,
    http_async::Bool = true,
)
    if _STANDALONE_SESSION[] !== nothing
        return session_status_dict()
    end

    _STANDALONE_PLUTO_PORT[] = pluto_port
    _STANDALONE_MCP_PORT[] = mcp_port
    _STANDALONE_REQUIRE_SECRET[] = require_secret_for_access

    sess = _init_pluto_session!(;
        pluto_port,
        launch_browser,
        require_secret_for_access,
        notebook,
    )
    _STANDALONE_SESSION[] = sess

    if http_async
        _STANDALONE_HTTP_TASK[] = @async _HTTP_BRIDGE_RUNNER[](sess, mcp_port)
    end

    return session_status_dict()
end

function stop_pluto_stack!()
    sess = _STANDALONE_SESSION[]
    if sess !== nothing
        for nb in collect(values(sess.notebooks))
            try
                Pluto.SessionActions.shutdown(sess, nb; async = false, verbose = false)
            catch
            end
        end
    end
    _STANDALONE_SESSION[] = nothing
    _STANDALONE_HTTP_TASK[] = nothing
    reset_staging_state!()
    return session_status_dict()
end

function require_standalone_session!()
    sess = _STANDALONE_SESSION[]
    sess === nothing &&
        throw(ArgumentError("pluto_not_running::Call start_pluto_session first."))
    return sess
end

# ---------------------------------------------------------------------------
# Lifecycle tool implementations
# ---------------------------------------------------------------------------

function tool_pluto_session_status(_args)
    session_status_dict()
end

function tool_start_pluto_session(args)
    pluto_port = get(args, "pluto_port", _STANDALONE_PLUTO_PORT[])
    mcp_port = get(args, "mcp_port", _STANDALONE_MCP_PORT[])
    start_pluto_stack!(; pluto_port = Int(pluto_port), mcp_port = Int(mcp_port))
end

function tool_stop_pluto_session(_args)
    stop_pluto_stack!()
end

function tool_open_notebook(args)
    sess = require_standalone_session!()
    path = get(args, "path", nothing)
    path === nothing && throw(ArgumentError("invalid_path::path is required"))
    path = String(path)
    ispath(path) || throw(ArgumentError("file_not_found::No file at '$path'"))
    run_nb = get(args, "run_notebook", false)

    nb = Pluto.SessionActions.open(sess, path; run_async = true, execution_allowed = run_nb)

    if run_nb
        tool_run_all_cells(sess, Dict(
            "notebook_id"         => string(nb.notebook_id),
            "wait_for_completion" => true,
        ))
    end

    Dict{String,Any}(
        "notebook_id"         => string(nb.notebook_id),
        "path"                => nb.path,
        "execution_allowed"   => run_nb,
        "ran"                 => run_nb,
    )
end

function call_lifecycle_tool(name::AbstractString, arguments)
    if name == "pluto_session_status"
        tool_pluto_session_status(arguments)
    elseif name == "start_pluto_session"
        tool_start_pluto_session(arguments)
    elseif name == "stop_pluto_session"
        tool_stop_pluto_session(arguments)
    elseif name == "open_notebook"
        tool_open_notebook(arguments)
    else
        throw(ArgumentError("unknown_tool::Unknown lifecycle tool: '$name'"))
    end
end

function call_tool_with_session(session, name::AbstractString, arguments)
    if is_lifecycle_tool(name)
        return call_lifecycle_tool(name, arguments)
    end
    sess = session === nothing ? standalone_session() : session
    sess === nothing &&
        throw(ArgumentError("pluto_not_running::Call start_pluto_session first."))
    return call_tool(sess, name, arguments)
end

"""Test helper: bind an in-memory session as the standalone Pluto session."""
function bind_standalone_session!(sess)
    _STANDALONE_SESSION[] = sess
end
