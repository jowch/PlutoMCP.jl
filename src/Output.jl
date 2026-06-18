# Structured cell output for MCP agents (mirrors Pluto frontend ErrorMessage.js where useful).

function _dict_get(d::AbstractDict, key::AbstractString)
    if haskey(d, key)
        return d[key]
    end
    sym = Symbol(key)
    return haskey(d, sym) ? d[sym] : nothing
end

function _error_msg(body)
    body === nothing && return ""
    body isa AbstractString && return body
    body isa AbstractDict || return sprint(show, body)
    msg = _dict_get(body, "msg")
    msg === nothing && (msg = _dict_get(body, "plain_error"))
    msg === nothing && return sprint(show, body)
    msg isa AbstractString ? msg : string(msg)
end

function _parse_boundaries(msg::AbstractString)
    m = match(r"Boundaries:\s*(\[[^\]]*\])", msg)
    m === nothing && return Int[]
    try
        b = Meta.parse(strip(m.captures[1]))
        b isa Vector{Int} && return b
        b isa Vector && return Int[b...]
        if b isa Expr && b.head == :vect
            return Int[b.args...]
        end
    catch
    end
    return Int[]
end

"""
    _structure_error(body) -> Union{Dict{String,Any}, Nothing}

Turn Pluto runner error bodies into agent-friendly structured errors.
"""
function _structure_error(body)
    msg = _error_msg(body)
    isempty(msg) && return nothing

    if occursin("extra token after end of expression", msg)
        boundaries = _parse_boundaries(msg)
        n = max(length(boundaries), 1)
        hint = if isempty(boundaries)
            "Multiple expressions in one cell. Wrap all code in a begin ... end block."
        else
            "Multiple expressions in one cell. Wrap all code in a begin ... end block (preferred), or split into $n cells."
        end
        core = strip(split(msg, "\n\nBoundaries:")[1])
        d = Dict{String,Any}(
            "kind"        => "pluto_multi_expression",
            "msg"         => core,
            "hint"        => hint,
            "fixes"       => ["wrap_begin_end", "split_cells"],
        )
        isempty(boundaries) || (d["boundaries"] = boundaries)
        isempty(boundaries) || (d["split_count"] = n)
        return d
    end

    d = Dict{String,Any}("kind" => "runtime", "msg" => msg)
    if body isa AbstractDict
        plain = _dict_get(body, "plain_error")
        plain !== nothing && plain != msg && (d["plain_error"] = plain)
    end
    return d
end

function _serialize_output(cell)
    if cell.errored
        body = cell.output.body
        structured = _structure_error(body)
        structured !== nothing && haskey(structured, "hint") && return structured["hint"]
        msg = _error_msg(body)
        return isempty(msg) ? "" : msg
    end
    body = cell.output.body
    body === nothing && return ""
    mime = cell.output.mime
    if mime == MIME("text/plain") && body isa AbstractString
        return body
    elseif body isa AbstractString
        return "[$(string(mime)) output, $(sizeof(body)) bytes]"
    elseif body isa Vector{UInt8}
        return "[$(string(mime)) output, $(length(body)) bytes]"
    else
        return "[$(string(mime)) output]"
    end
end

function _cell_output_error(cell)
    cell.errored || return nothing
    return _structure_error(cell.output.body)
end
