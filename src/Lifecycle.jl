# D15 — deferred Pluto session lifecycle (standalone connect + lifecycle MCP tools).

const LIFECYCLE_TOOLS = Set([
    "pluto_session_status",
    "start_pluto_session",
    "stop_pluto_session",
    "open_notebook",
    "allow_execution",
])

is_lifecycle_tool(name::AbstractString) = name in LIFECYCLE_TOOLS

const _STANDALONE_SESSION = Ref{Any}(nothing)
const _STANDALONE_HTTP_TASK = Ref{Union{Nothing,Task}}(nothing)
const _STANDALONE_HTTP_SERVER = Ref{Any}(nothing)
const _STANDALONE_PLUTO_SERVER = Ref{Any}(nothing)
const _STANDALONE_PLUTO_TASK = Ref{Union{Nothing,Task}}(nothing)
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
    _STANDALONE_PLUTO_TASK[] = @async begin
        try
            server = Pluto.run!(sess)
            _STANDALONE_PLUTO_SERVER[] = server
            wait(server)
        catch e
            isa(e, InterruptException) || @error "Pluto server error" exception=(e, catch_backtrace())
        finally
            _STANDALONE_PLUTO_SERVER[] = nothing
        end
    end
    deadline = time() + 30.0
    while time() < deadline
        _STANDALONE_PLUTO_SERVER[] !== nothing && break
        sleep(0.05)
    end
    _STANDALONE_PLUTO_SERVER[] === nothing &&
        error("Pluto failed to start on port $pluto_port within 30s")
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
        _STANDALONE_HTTP_TASK[] = @async begin
            try
                http_server = _HTTP_BRIDGE_RUNNER[](sess, mcp_port)
                _STANDALONE_HTTP_SERVER[] = http_server
                wait(http_server)
            catch e
                isa(e, InterruptException) || rethrow()
            finally
                _STANDALONE_HTTP_SERVER[] = nothing
            end
        end
    end

    return session_status_dict()
end

function _close_standalone_http!()
    http_server = _STANDALONE_HTTP_SERVER[]
    if http_server !== nothing
        try
            close(http_server)
        catch
        end
        _STANDALONE_HTTP_SERVER[] = nothing
    end
    t = _STANDALONE_HTTP_TASK[]
    if t !== nothing && t !== current_task()
        try
            schedule(t, InterruptException(); error=true)
        catch
        end
        try
            wait(t)
        catch
        end
    end
    _STANDALONE_HTTP_TASK[] = nothing
end

function _close_standalone_pluto!()
    pluto_server = _STANDALONE_PLUTO_SERVER[]
    if pluto_server !== nothing
        try
            close(pluto_server)
        catch
        end
        _STANDALONE_PLUTO_SERVER[] = nothing
    end
    t = _STANDALONE_PLUTO_TASK[]
    if t !== nothing && t !== current_task()
        try
            wait(t)
        catch
        end
    end
    _STANDALONE_PLUTO_TASK[] = nothing
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
    _close_standalone_http!()
    _close_standalone_pluto!()
    reset_staging_state!()
    return session_status_dict()
end

function require_standalone_session!()
    sess = _STANDALONE_SESSION[]
    sess === nothing &&
        throw(ArgumentError("pluto_not_running::Call start_pluto_session first."))
    return sess
end

function _lifecycle_get_notebook!(session, notebook_id_str)
    nid = try
        UUID(notebook_id_str)
    catch
        throw(ArgumentError("invalid_notebook_id::Invalid notebook ID: '$notebook_id_str'"))
    end
    nb = get(session.notebooks, nid, nothing)
    nb === nothing &&
        throw(KeyError("notebook_not_found::No notebook with id '$notebook_id_str' in the current session"))
    return nb
end

function _lifecycle_notify_browser(session, notebook)
    try
        Pluto.send_notebook_changes!(Pluto.ClientRequest(; session, notebook))
    catch
    end
end

"""
    allow_notebook_execution!(session, notebook; run_async=true)

Programmatic equivalent of Glass **Run notebook code** for safe-preview notebooks
(local paths only). Mirrors Pluto `restart_process`.
"""
function allow_notebook_execution!(session, notebook; run_async::Bool=true)
    ps = notebook.process_status
    if ps === Pluto.ProcessStatus.ready
        return Dict{String,Any}(
            "notebook_id"       => string(notebook.notebook_id),
            "execution_allowed" => true,
            "already_allowed"   => true,
            "process_status"    => string(ps),
        )
    end
    if ps !== Pluto.ProcessStatus.waiting_for_permission
        throw(ArgumentError(
            "execution_not_gated::Notebook is not in safe preview (process_status=$ps)",
        ))
    end
    if haskey(notebook.metadata, "risky_file_source")
        throw(ArgumentError(
            "risky_source::Cannot allow execution for risky remote sources via MCP; use Glass UI",
        ))
    end

    notebook.process_status = Pluto.ProcessStatus.waiting_to_restart
    session.options.evaluation.run_notebook_on_load &&
        Pluto._report_business_cells_planned!(notebook)
    _lifecycle_notify_browser(session, notebook)

    Pluto.SessionActions.shutdown(session, notebook; keep_in_session=true, async=true, verbose=false)

    notebook.process_status = Pluto.ProcessStatus.starting
    _lifecycle_notify_browser(session, notebook)

    Pluto.update_save_run!(session, notebook, notebook.cells; run_async=run_async, save=true)
    _lifecycle_notify_browser(session, notebook)

    Dict{String,Any}(
        "notebook_id"       => string(notebook.notebook_id),
        "execution_allowed" => true,
        "already_allowed"   => false,
        "process_status"    => string(notebook.process_status),
    )
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
        "process_status"      => string(nb.process_status),
    )
end

function tool_allow_execution(args)
    sess = require_standalone_session!()
    notebook_id = get(args, "notebook_id", nothing)
    notebook_id === nothing &&
        throw(ArgumentError("invalid_notebook_id::notebook_id is required"))
    nb = _lifecycle_get_notebook!(sess, String(notebook_id))
    run_cells = get(args, "run_notebook", true)
    result = allow_notebook_execution!(sess, nb; run_async=true)
    if run_cells
        run_result = tool_run_all_cells(sess, Dict(
            "notebook_id"         => string(nb.notebook_id),
            "wait_for_completion" => true,
        ))
        result["ran"] = true
        result["run_warnings"] = get(run_result, "warnings", String[])
    else
        result["ran"] = false
    end
    result["process_status"] = string(nb.process_status)
    return result
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
    elseif name == "allow_execution"
        tool_allow_execution(arguments)
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
