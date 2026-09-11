# Host-local Styx session binding + notebook path leases (C-lite).

# ponytail: fixed dns-style namespace for uuid5 path leases; change only with a migration story
const STYX_NOTEBOOK_NAMESPACE = UUID("6ba7b811-9dad-11d1-80b4-00c04fd430c8")

const STYX_SESSION_HEADER = "X-Styx-Session-ID"

mutable struct SessionBinding
    session_id::String
    runtime_dir::String
    binding_file::String
    cursor_host_pid::Int
    owner_pid::Int
    mcp_port::Union{Nothing,Int}
    pluto_port::Union{Nothing,Int}
    pluto::String
    claim_dir::String
    notebook_leases::Dict{UUID,String}
    lock::ReentrantLock
end

struct NotebookLease
    canonical_path::String
    lease_dir::String
    session_id::String
end

const _SESSION_BINDING = Ref{Union{Nothing,SessionBinding}}(nothing)

function SessionBinding(;
    session_id::AbstractString = string(uuid4()),
    runtime_dir::AbstractString,
    binding_file::AbstractString,
    cursor_host_pid::Integer,
    owner_pid::Integer = getpid(),
)
    runtime_dir = abspath(String(runtime_dir))
    binding_file = abspath(String(binding_file))
    claim_dir = joinpath(runtime_dir, "windows", "$(Int(cursor_host_pid)).claim")
    SessionBinding(
        String(session_id),
        runtime_dir,
        binding_file,
        Int(cursor_host_pid),
        Int(owner_pid),
        nothing,
        nothing,
        "stopped",
        claim_dir,
        Dict{UUID,String}(),
        ReentrantLock(),
    )
end

session_binding() = _SESSION_BINDING[]
is_bound_session() = _SESSION_BINDING[] !== nothing

function configure_session_binding!(binding::SessionBinding)::Nothing
    _SESSION_BINDING[] = binding
    nothing
end

function clear_session_binding_ref!()::Nothing
    _SESSION_BINDING[] = nothing
    nothing
end

function _atomic_write_json(path::AbstractString, obj)::Nothing
    dir = dirname(path)
    mkpath(dir)
    tmp = joinpath(dir, ".$(basename(path)).$(getpid()).$(time_ns()).tmp")
    open(tmp, "w") do io
        JSON.print(io, obj)
    end
    mv(tmp, path; force=true)
    nothing
end

function _read_json_file(path::AbstractString)
    JSON.parse(read(path, String), Dict{String,Any})
end

function _utc_now_iso()::String
    # ponytail: avoid Dates stdlib dep; diagnostic timestamp only
    string(time())
end

function health_payload(binding::SessionBinding)::Dict{String,Any}
    Dict{String,Any}(
        "status"         => "ok",
        "schema_version" => 1,
        "session_id"     => binding.session_id,
        "owner_pid"      => binding.owner_pid,
        "mcp_port"       => binding.mcp_port,
        "pluto_port"     => binding.pluto_port,
        "pluto"          => binding.pluto,
    )
end

function binding_file_payload(binding::SessionBinding)::Dict{String,Any}
    Dict{String,Any}(
        "schema_version"  => 1,
        "session_id"      => binding.session_id,
        "cursor_host_pid" => binding.cursor_host_pid,
        "owner_pid"       => binding.owner_pid,
        "mcp_port"        => binding.mcp_port,
        "pluto_port"      => binding.pluto_port,
        "pluto"           => binding.pluto,
        "updated_at"      => _utc_now_iso(),
    )
end

function write_binding_state!()::Nothing
    binding = session_binding()
    binding === nothing && return nothing
    lock(binding.lock) do
        _atomic_write_json(binding.binding_file, binding_file_payload(binding))
        _atomic_write_json(
            joinpath(binding.claim_dir, "owner.json"),
            Dict{String,Any}(
                "schema_version" => 1,
                "session_id"     => binding.session_id,
                "owner_pid"      => binding.owner_pid,
                "mcp_port"       => binding.mcp_port,
                "acquired_at"    => _utc_now_iso(),
            ),
        )
    end
    nothing
end

function _health_matches(port::Integer, session_id::AbstractString)::Bool
    try
        resp = HTTP.get(
            "http://127.0.0.1:$port/health";
            readtimeout=1,
            connect_timeout=1,
            status_exception=false,
        )
        resp.status != 200 && return false
        body = String(resp.body)
        # legacy plain ok is never our nonce
        startswith(strip(body), "{") || return false
        data = JSON.parse(body, Dict{String,Any})
        return get(data, "session_id", nothing) == session_id
    catch
        return false
    end
end

function _claim_owner_live(claim_dir::AbstractString)::Bool
    owner_path = joinpath(claim_dir, "owner.json")
    isfile(owner_path) || return false
    owner = try
        _read_json_file(owner_path)
    catch
        return false
    end
    port = get(owner, "mcp_port", nothing)
    sid = get(owner, "session_id", nothing)
    port isa Integer && sid isa AbstractString || return false
    return _health_matches(Int(port), String(sid))
end

function _remove_stale_dir!(path::AbstractString)::Nothing
    stale = path * ".stale.$(getpid()).$(time_ns())"
    try
        mv(path, stale; force=true)
        rm(stale; recursive=true, force=true)
    catch e
        throw(ErrorException(
            "stale_binding_unrecoverable::A stale Styx binding could not be replaced at $path; remove it only after confirming its owner process is gone. ($e)",
        ))
    end
    nothing
end

function claim_window_binding!(binding::SessionBinding)::Nothing
    mkpath(joinpath(binding.runtime_dir, "windows"))
    mkpath(joinpath(binding.runtime_dir, "sessions", binding.session_id))
    mkpath(joinpath(binding.runtime_dir, "notebooks"))

    for _ in 1:3
        try
            mkdir(binding.claim_dir)
            write_binding_state!()
            return nothing
        catch e
            isa(e, SystemError) || isa(e, Base.IOError) || rethrow()
            if _claim_owner_live(binding.claim_dir)
                prefix = first(binding.session_id, 8)
                # Prefer the live owner's id for the message when readable
                live_sid = try
                    String(_read_json_file(joinpath(binding.claim_dir, "owner.json"))["session_id"])
                catch
                    prefix
                end
                throw(ErrorException(
                    "styx_binding_in_use::This Cursor window already has a live Styx MCP owner (session $(first(live_sid, 8))).",
                ))
            end
            _remove_stale_dir!(binding.claim_dir)
        end
    end
    throw(ErrorException(
        "stale_binding_unrecoverable::A stale Styx binding could not be replaced at $(binding.claim_dir); remove it only after confirming its owner process is gone.",
    ))
end

function validate_bound_request(http::HTTP.Stream)::Bool
    binding = session_binding()
    binding === nothing && return true
    hdr = HTTP.header(http.message, STYX_SESSION_HEADER, "")
    return hdr == binding.session_id
end

function _lease_dir_for_path(binding::SessionBinding, canonical_path::AbstractString)::String
    joinpath(binding.runtime_dir, "notebooks", string(uuid5(STYX_NOTEBOOK_NAMESPACE, canonical_path)))
end

function _lease_owner_live(lease_dir::AbstractString)::Bool
    owner_path = joinpath(lease_dir, "owner.json")
    isfile(owner_path) || return false
    owner = try
        _read_json_file(owner_path)
    catch
        return false
    end
    port = get(owner, "mcp_port", nothing)
    sid = get(owner, "session_id", nothing)
    port isa Integer && sid isa AbstractString || return false
    return _health_matches(Int(port), String(sid))
end

function acquire_notebook_lease!(path::String)::NotebookLease
    binding = session_binding()
    binding === nothing && throw(ErrorException("session_binding_required::No bound Styx session"))

    ispath(path) || throw(ArgumentError("file_not_found::No file at '$path'"))
    canonical = realpath(path)
    lease_dir = _lease_dir_for_path(binding, canonical)
    mkpath(dirname(lease_dir))

    for _ in 1:3
        owner_path = joinpath(lease_dir, "owner.json")
        if isdir(lease_dir)
            owner = try
                _read_json_file(owner_path)
            catch
                nothing
            end
            if owner !== nothing && get(owner, "session_id", nothing) == binding.session_id
                return NotebookLease(canonical, lease_dir, binding.session_id)
            end
            if _lease_owner_live(lease_dir)
                foreign = try
                    String(owner["session_id"])
                catch
                    "unknown"
                end
                throw(ArgumentError(
                    "notebook_in_use::'$canonical' is open in another Styx session ($(first(foreign, 8))). Close it there before opening it here.",
                ))
            end
            _remove_stale_dir!(lease_dir)
        end

        try
            mkdir(lease_dir)
            _atomic_write_json(
                owner_path,
                Dict{String,Any}(
                    "schema_version"  => 1,
                    "session_id"      => binding.session_id,
                    "owner_pid"       => binding.owner_pid,
                    "mcp_port"        => binding.mcp_port,
                    "canonical_path"  => canonical,
                    "acquired_at"     => _utc_now_iso(),
                ),
            )
            return NotebookLease(canonical, lease_dir, binding.session_id)
        catch e
            isa(e, SystemError) || isa(e, Base.IOError) || rethrow()
            # raced — retry
        end
    end
    throw(ErrorException(
        "stale_binding_unrecoverable::A stale Styx lease could not be replaced at $lease_dir; remove it only after confirming its owner process is gone.",
    ))
end

function track_notebook_lease!(notebook_id::UUID, lease::NotebookLease)::Nothing
    binding = session_binding()
    binding === nothing && return nothing
    lock(binding.lock) do
        binding.notebook_leases[notebook_id] = lease.lease_dir
    end
    nothing
end

function release_notebook_lease!(notebook_id::UUID)::Nothing
    binding = session_binding()
    binding === nothing && return nothing
    lease_dir = lock(binding.lock) do
        pop!(binding.notebook_leases, notebook_id, nothing)
    end
    lease_dir === nothing && return nothing
    _release_lease_dir_if_ours!(binding, lease_dir)
    nothing
end

function _release_lease_dir_if_ours!(binding::SessionBinding, lease_dir::AbstractString)::Nothing
    owner_path = joinpath(lease_dir, "owner.json")
    if isfile(owner_path)
        owner = try
            _read_json_file(owner_path)
        catch
            nothing
        end
        if owner !== nothing && get(owner, "session_id", nothing) != binding.session_id
            return nothing
        end
    end
    try
        rm(lease_dir; recursive=true, force=true)
    catch
    end
    nothing
end

function release_all_notebook_leases!()::Nothing
    binding = session_binding()
    binding === nothing && return nothing
    ids = lock(binding.lock) do
        collect(keys(binding.notebook_leases))
    end
    for id in ids
        release_notebook_lease!(id)
    end
    nothing
end

function cleanup_session_binding!()::Nothing
    binding = session_binding()
    binding === nothing && return nothing
    release_all_notebook_leases!()
    try
        isfile(binding.binding_file) && rm(binding.binding_file; force=true)
    catch
    end
    try
        isdir(binding.claim_dir) && rm(binding.claim_dir; recursive=true, force=true)
    catch
    end
    session_dir = joinpath(binding.runtime_dir, "sessions", binding.session_id)
    try
        isdir(session_dir) && rm(session_dir; recursive=true, force=true)
    catch
    end
    clear_session_binding_ref!()
    nothing
end

# ponytail: depends on Pluto's current open(::AbstractString) signature; move to a
# Pluto-supported pre-open callback if one is added.
function Pluto.SessionActions.open(session::Pluto.ServerSession, path::String; kwargs...)
    binding = session_binding()
    if binding === nothing
        return invoke(
            Pluto.SessionActions.open,
            Tuple{Pluto.ServerSession,AbstractString},
            session,
            path;
            kwargs...,
        )
    end
    lease = acquire_notebook_lease!(path)
    try
        nb = invoke(
            Pluto.SessionActions.open,
            Tuple{Pluto.ServerSession,AbstractString},
            session,
            path;
            kwargs...,
        )
        track_notebook_lease!(nb.notebook_id, lease)
        return nb
    catch e
        # Same-session duplicate: keep our lease; Pluto already owns the notebook.
        if e isa Pluto.SessionActions.NotebookIsRunningException
            track_notebook_lease!(e.notebook.notebook_id, lease)
            rethrow()
        end
        _release_lease_dir_if_ours!(binding, lease.lease_dir)
        rethrow()
    end
end
