# Optional MCP tool-call logging for agent eval harnesses.
# Activated via serve(eval_log=...) or PLUTOMCP_EVAL_LOG env var.

const _EVAL_LOG_LOCK = ReentrantLock()
const _EVAL_SEQ      = Ref(0)

mutable struct EvalLogConfig
    path::Union{String,Nothing}
    run_id::String
    redact_code::Bool
end

const _EVAL_CONFIG = Ref(EvalLogConfig(nothing, "", false))

function configure_eval_log!(;
    path::Union{String,Nothing,Missing}=missing,
    run_id::Union{String,Nothing,Missing}=missing,
    redact_code::Bool=false,
)
    log_path = if path === missing
        get(ENV, "PLUTOMCP_EVAL_LOG", nothing)
    else
        path
    end
    rid = if run_id === missing
        get(ENV, "PLUTOMCP_EVAL_RUN_ID", "")
    elseif run_id === nothing
        ""
    else
        run_id
    end
    redact = redact_code || lowercase(get(ENV, "PLUTOMCP_EVAL_REDACT_CODE", "false")) == "true"
    lock(_EVAL_LOG_LOCK) do
        _EVAL_CONFIG[] = EvalLogConfig(log_path, rid, redact)
        _EVAL_SEQ[] = 0
    end
    return nothing
end

function eval_log_enabled()
    cfg = _EVAL_CONFIG[]
    cfg.path !== nothing && !isempty(cfg.path)
end

function _truncate_code(s::AbstractString, max_len=500)
    s = string(s)
    length(s) <= max_len && return s
    return s[1:max_len] * "…"
end

function _sanitize_args(args::Dict{String,Any}, redact_code::Bool)
    out = Dict{String,Any}()
    for (k, v) in args
        if redact_code && k == "code"
            out[k] = "[redacted]"
        elseif redact_code && k == "cells" && v isa AbstractVector
            out[k] = [
                Dict{String,Any}(
                    "cell_id" => get(c, "cell_id", nothing),
                    "code"    => "[redacted]",
                ) for c in v
            ]
        elseif k == "code" && v isa AbstractString
            out[k] = _truncate_code(v)
        elseif k == "cells" && v isa AbstractVector
            out[k] = [
                begin
                    d = Dict{String,Any}()
                    for (ck, cv) in c
                        d[ck] = ck == "code" && cv isa AbstractString ? _truncate_code(cv) : cv
                    end
                    d
                end for c in v
            ]
        else
            out[k] = v
        end
    end
    return out
end

function _parse_tool_error(result::Dict{String,Any})
    get(result, "isError", false) || return (false, nothing, nothing)
    content = get(result, "content", nothing)
    content === nothing && return (true, "tool_error", nothing)
    items = content isa AbstractVector ? content : [content]
    for item in items
        text = get(item, "text", nothing)
        text === nothing && continue
        parsed = try
            JSON3.read(text, Dict{String,Any})
        catch
            nothing
        end
        parsed === nothing && continue
        et = get(parsed, "error", nothing)
        em = get(parsed, "message", nothing)
        return (true, et === nothing ? "tool_error" : string(et), em === nothing ? nothing : string(em))
    end
    return (true, "tool_error", nothing)
end

function log_tool_call(name::String, arguments::Dict{String,Any}, result::Dict{String,Any}, duration_ms::Int)
    eval_log_enabled() || return nothing
    cfg = _EVAL_CONFIG[]
    is_error, error_type, error_message = _parse_tool_error(result)
    entry = lock(_EVAL_LOG_LOCK) do
        _EVAL_SEQ[] += 1
        seq = _EVAL_SEQ[]
        Dict{String,Any}(
            "ts"            => time(),
            "run_id"        => cfg.run_id,
            "seq"           => seq,
            "tool"          => name,
            "args"          => _sanitize_args(arguments, cfg.redact_code),
            "is_error"      => is_error,
            "error_type"    => error_type,
            "error_message" => error_message,
            "duration_ms"   => duration_ms,
        )
    end
    line = JSON3.write(entry) * "\n"
    open(cfg.path, "a") do io
        write(io, line)
    end
    return nothing
end
