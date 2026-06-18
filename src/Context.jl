# Design Mode / Glass context resolution (Path A, D13).
# Mirrors pluto-cursor-bridge src/dom-resolver.js parseDomPath semantics.

const _RE_CELL_ID = r"pluto-cell#([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"i
const _RE_NOTEBOOK_ID = r"pluto-notebook#([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"i
const _RE_GLASS_NOTEBOOK_PATH = r"(?:localhost|127\.0\.0\.1):1234/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"i
const _RE_GLASS_NOTEBOOK_QUERY = r"(?:localhost|127\.0\.0\.1):1234/\?(?:[^#\s]*&)?id=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"i

function _first_capture(re::Regex, text::AbstractString)
    m = match(re, text)
    m === nothing && return nothing
    return lowercase(m.captures[1])
end

function _extract_dom_path_line(text::AbstractString)
    for line in split(text, '\n')
        stripped = strip(line)
        startswith(stripped, "dom_path:") || continue
        return strip(stripped[length("dom_path:")+1:end])
    end
    return nothing
end

function _infer_click_flags(text::AbstractString)
    lower = lowercase(text)
    in_output = occursin("pluto-output", lower) || occursin("jlerror", lower)
    in_input = occursin("pluto-input", lower)
    return in_output, in_input
end

"""
    resolve_pluto_context_string(text) -> Dict{String,Any}

Parse Design Mode `dom_path`, a Glass notebook URL, or a full `browser_element` block
into `notebook_id` and optional `cell_id`.
"""
function resolve_pluto_context_string(text::AbstractString)
    isempty(strip(text)) && return Dict{String,Any}(
        "ok"     => false,
        "reason" => "invalid_context",
    )

    dom_path = _extract_dom_path_line(text)
    probe = dom_path !== nothing ? dom_path : text

    cell_id = _first_capture(_RE_CELL_ID, probe)
    notebook_id = _first_capture(_RE_NOTEBOOK_ID, probe)

    if notebook_id === nothing
        notebook_id = _first_capture(_RE_GLASS_NOTEBOOK_PATH, text)
    end
    if notebook_id === nothing
        notebook_id = _first_capture(_RE_GLASS_NOTEBOOK_QUERY, text)
    end

    if cell_id === nothing && notebook_id === nothing
        return Dict{String,Any}(
            "ok"     => false,
            "reason" => "no_pluto_cell_in_context",
        )
    end

    in_output, in_input = _infer_click_flags(probe)
    result = Dict{String,Any}(
        "ok"          => true,
        "notebook_id" => notebook_id,
        "cell_id"     => cell_id,
        "in_output"   => in_output,
        "in_input"    => in_input,
    )
    dom_path !== nothing && (result["dom_path"] = dom_path)
    return result
end

function tool_resolve_pluto_context(session, args)
    raw = get(args, "context", get(args, "dom_path", ""))
    raw isa AbstractString || throw(ArgumentError("invalid_context::context must be a string"))
    result = resolve_pluto_context_string(raw)

    if get(result, "ok", false) && get(args, "validate_notebook", true)
        nb_id = get(result, "notebook_id", nothing)
        if nb_id !== nothing
            try
                uuid = UUID(string(nb_id))
                if !haskey(session.notebooks, uuid)
                    result["notebook_open"] = false
                    result["warning"] =
                        "notebook_id resolved but not open in this PlutoMCP session — use list_notebooks or reopen in Glass"
                else
                    result["notebook_open"] = true
                end
            catch
                result["notebook_open"] = false
                result["warning"] = "notebook_id is not a valid UUID"
            end
        end
    end

    return result
end
