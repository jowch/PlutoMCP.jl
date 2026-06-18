# Shared helpers for eval/score.jl and eval/run_reference.jl

using JSON3
using HTTP
using UUIDs

const EVAL_ROOT = normpath(@__DIR__, "..")

function parse_cli_args(defaults=Dict{String,String}())
    opts = copy(defaults)
    args = copy(ARGS)
    i = 1
    while i <= length(args)
        a = args[i]
        if startswith(a, "--")
            key = strip(a[3:end], '-')
            if i + 1 <= length(args) && !startswith(args[i + 1], "--")
                opts[key] = args[i + 1]
                i += 2
            else
                opts[key] = "true"
                i += 1
            end
        else
            i += 1
        end
    end
    return opts
end

function load_scenario(path::String)
    JSON3.read(read(path, String), Dict{String,Any})
end

function scenario_path(id_or_path::String)
    isfile(id_or_path) && return id_or_path
    candidate = joinpath(EVAL_ROOT, "scenarios", id_or_path * ".json")
    isfile(candidate) || error("Scenario not found: $id_or_path")
    return candidate
end

function mcp_url_from_opts(opts)
    get(opts, "mcp-url", get(opts, "mcp_url", "http://127.0.0.1:2346"))
end

function mcp_call(base_url::String, name::String, arguments::Dict{String,Any}; id=1)
    msg = Dict{String,Any}(
        "jsonrpc" => "2.0",
        "id"      => id,
        "method"  => "tools/call",
        "params"  => Dict{String,Any}("name" => name, "arguments" => arguments),
    )
    r = HTTP.post(
        string(rstrip(base_url, '/'), "/call");
        body    = JSON3.write(msg),
        headers = ["Content-Type" => "application/json"],
        readtimeout = 120,
        connect_timeout = 5,
    )
    resp = JSON3.read(String(r.body), Dict{String,Any})
    haskey(resp, "error") && error("MCP error: $(resp["error"])")
    result = resp["result"]
    is_error = get(result, "isError", false)
    content = result["content"]
    text = content[1]["text"]
    parsed = JSON3.read(text)
    return result, parsed, is_error
end

function tool_result_data(parsed, is_error::Bool)
    if is_error && parsed isa Dict
        return parsed
    end
    return parsed
end

function wait_health(base_url::String; timeout_sec=30.0)
    deadline = time() + timeout_sec
    while time() < deadline
        try
            r = HTTP.get(string(rstrip(base_url, '/'), "/health");
                readtimeout=2, connect_timeout=2)
            r.status == 200 && return true
        catch
        end
        sleep(0.5)
    end
    return false
end

function discover_notebook_id(base_url::String; expect=1)
    _, parsed, is_error = mcp_call(base_url, "list_notebooks", Dict{String,Any}())
    is_error && error("list_notebooks failed: $parsed")
    length(parsed) == expect ||
        error("Expected $expect notebook(s), got $(length(parsed))")
    return string(parsed[1]["notebook_id"])
end

function wait_readiness(base_url::String, scenario::Dict{String,Any})
    readiness = get(scenario, "readiness", nothing)
    readiness === nothing && return discover_notebook_id(base_url)
    cell_id = string(readiness["cell_id"])
    expected = string(readiness["output_equals"])
    timeout = get(readiness, "timeout_sec", 90.0)
    deadline = time() + timeout
    notebook_id = nothing
    while time() < deadline
        notebook_id = discover_notebook_id(base_url)
        _, parsed, is_error = mcp_call(base_url, "read_cell", Dict{String,Any}(
            "notebook_id" => notebook_id,
            "cell_id"     => cell_id,
        ))
        if !is_error && get(parsed, "output", nothing) == expected
            return notebook_id
        end
        sleep(0.5)
    end
    error("Readiness timeout: cell $cell_id output != $expected")
end

function substitute_notebook_id(obj, notebook_id::String)
    if obj isa Dict
        return Dict{String,Any}(k => substitute_notebook_id(v, notebook_id) for (k, v) in obj)
    elseif obj isa AbstractVector
        return [substitute_notebook_id(x, notebook_id) for x in obj]
    elseif obj isa AbstractString && obj == "\$notebook_id"
        return notebook_id
    else
        return obj
    end
end

function load_trace_entries(log_path::Union{String,Nothing})
    log_path === nothing || !isfile(log_path) && return Dict{String,Any}[]
    lines = filter(!isempty, split(read(log_path, String), '\n'))
    return [JSON3.read(line, Dict{String,Any}) for line in lines]
end

function check_claim(base_url::String, notebook_id::String, claim::Dict{String,Any})
    ctype = string(claim["type"])
    weight = get(claim, "weight", 1.0)
    if ctype == "cell_output"
        _, parsed, err = mcp_call(base_url, "read_cell", Dict{String,Any}(
            "notebook_id" => notebook_id,
            "cell_id"     => string(claim["cell_id"]),
        ))
        ok = !err && string(get(parsed, "output", "")) == string(claim["equals"])
        return ok, weight, "cell_output $(claim["cell_id"]) == $(claim["equals"])"
    elseif ctype == "cell_code_contains"
        _, parsed, err = mcp_call(base_url, "read_cell", Dict{String,Any}(
            "notebook_id" => notebook_id,
            "cell_id"     => string(claim["cell_id"]),
        ))
        code = err ? "" : string(get(parsed, "code", ""))
        sub = string(claim["substring"])
        ok = occursin(sub, code)
        return ok, weight, "cell_code_contains $(claim["cell_id"]) ∋ $sub"
    elseif ctype == "pending_run_empty"
        _, parsed, err = mcp_call(base_url, "read_notebook_code", Dict{String,Any}(
            "notebook_id" => notebook_id,
        ))
        pending = err ? ["error"] : get(parsed, "pending_run", String[])
        ok = isempty(pending)
        return ok, weight, "pending_run_empty"
    elseif ctype == "projection_contains"
        _, parsed, err = mcp_call(base_url, "read_notebook_code", Dict{String,Any}(
            "notebook_id" => notebook_id,
        ))
        code = err ? "" : string(get(parsed, "code", ""))
        sub = string(claim["substring"])
        ok = occursin(sub, code)
        return ok, weight, "projection_contains ∋ $sub"
    elseif ctype == "cell_order_after"
        anchor = string(claim["anchor_cell_id"])
        needle = string(claim["new_code_contains"])
        _, order_parsed, err1 = mcp_call(base_url, "get_cell_order", Dict{String,Any}("notebook_id" => notebook_id))
        err1 && return false, weight, "cell_order_after get_cell_order failed"
        ids = [string(x) for x in get(order_parsed, "cell_ids", order_parsed)]
        anchor_idx = findfirst(==(anchor), ids)
        anchor_idx === nothing && return false, weight, "anchor $anchor not in cell_order"
        ok = false
        if anchor_idx < length(ids)
            next_id = ids[anchor_idx + 1]
            _, cell_parsed, err2 = mcp_call(base_url, "read_cell", Dict{String,Any}(
                "notebook_id" => notebook_id,
                "cell_id"     => next_id,
            ))
            if !err2
                ok = occursin(needle, string(get(cell_parsed, "code", "")))
            end
        end
        return ok, weight, "cell_order_after anchor $anchor then code ∋ $needle"
    else
        return false, weight, "unknown claim type: $ctype"
    end
end

function score_outcome(base_url::String, scenario::Dict{String,Any}; notebook_id::Union{String,Nothing}=nothing)
    outcome = scenario["outcome"]
    expect = get(outcome, "expect_notebooks", 1)
    nb_id = something(notebook_id, discover_notebook_id(base_url; expect=expect))
    claims = outcome["claims"]
    threshold = get(outcome, "pass_threshold", 1.0)
    results = Dict{String,Any}[]
    earned = 0.0
    total = 0.0
    for claim in claims
        ok, weight, desc = check_claim(base_url, nb_id, claim)
        push!(results, Dict("claim" => desc, "pass" => ok, "weight" => weight))
        total += weight
        ok && (earned += weight)
    end
    score = total > 0 ? earned / total : 0.0
    pass = score >= threshold
    return Dict(
        "pass"       => pass,
        "score"      => score,
        "notebook_id"=> nb_id,
        "claims"     => results,
    )
end

const _MUTATING = Set(["edit_cell", "edit_cells", "add_cell", "delete_cell", "move_cell"])
const _READS = Set(["read_cell", "read_notebook_code"])

function _tool_matches(pattern::String, tool::String)
    for part in split(pattern, '|')
        strip(part) == tool && return true
    end
    return false
end

function _subsequence_match(entries, patterns)
    pi = 1
    for entry in entries
        tool = string(entry["tool"])
        pi <= length(patterns) || break
        _tool_matches(string(patterns[pi]), tool) && (pi += 1)
    end
    return pi > length(patterns)
end

function _cells_read_by(entries, upto_idx)
    read_cells = Set{String}()
    notebook_read = false
    for (i, entry) in enumerate(entries)
        i > upto_idx && break
        tool = string(entry["tool"])
        if tool == "read_notebook_code"
            notebook_read = true
        elseif tool == "read_cell"
            args = get(entry, "args", Dict())
            haskey(args, "cell_id") && push!(read_cells, string(args["cell_id"]))
        end
    end
    return read_cells, notebook_read
end

function score_trace(entries, trace::Union{Dict,Nothing}; strict_read_guard=false)
    trace === nothing && return Dict("pass" => true, "advisory" => true, "diagnostics" => String[])
    diagnostics = String[]
    pass = true

    tools = [string(e["tool"]) for e in entries]

    for forbidden in get(trace, "must_not_include", String[])
        any(t -> t == forbidden, tools) && begin
            push!(diagnostics, "forbidden tool used: $forbidden")
            pass = false
        end
    end

    max_exec = get(trace, "max_execute_cell", nothing)
    if max_exec !== nothing
        n = count(==( "execute_cell"), tools)
        n > max_exec && begin
            push!(diagnostics, "execute_cell count $n > max $max_exec")
            pass = false
        end
    end

    subseq = get(trace, "must_include_subsequence", nothing)
    if subseq !== nothing
        patterns = [string(p) for p in subseq]
        _subsequence_match(entries, patterns) || begin
            push!(diagnostics, "missing subsequence: $(join(patterns, " → "))")
            pass = false
        end
    end

    if get(trace, "read_before_first_edit", false)
        first_mut_idx = findfirst(e -> string(e["tool"]) in _MUTATING, entries)
        if first_mut_idx !== nothing
            entry = entries[first_mut_idx]
            tool = string(entry["tool"])
            args = get(entry, "args", Dict())
            read_cells, notebook_read = _cells_read_by(entries, first_mut_idx - 1)
            ok = false
            if tool == "add_cell"
                anchor = get(args, "after_cell_id", nothing)
                anchor !== nothing && (ok = notebook_read || string(anchor) in read_cells)
            elseif tool == "edit_cells"
                cells = get(args, "cells", [])
                if notebook_read
                    ok = true
                else
                    needed = Set(string(get(c, "cell_id", "")) for c in cells)
                    ok = needed ⊆ read_cells
                end
            else
                cid = get(args, "cell_id", nothing)
                ok = notebook_read || (cid !== nothing && string(cid) in read_cells)
            end
            ok || begin
                push!(diagnostics, "read_before_first_edit failed at tool $tool")
                pass = false
            end
        end
    end

    if get(trace, "expect_read_required_error", false)
        found = any(e -> get(e, "is_error", false) && string(get(e, "error_type", "")) == "read_required", entries)
        found || begin
            push!(diagnostics, "expected read_required error not logged")
            pass = false
        end
    end

    return Dict(
        "pass"         => pass,
        "advisory"     => !strict_read_guard,
        "diagnostics"  => diagnostics,
        "tool_calls"   => length(entries),
    )
end

function run_score(; scenario_path, log_path=nothing, mcp_url, meta_path=nothing, strict_trace=false)
    scenario = load_scenario(scenario_path)
    meta = meta_path !== nothing && isfile(meta_path) ?
        JSON3.read(read(meta_path, String), Dict{String,Any}) : Dict{String,Any}()
    notebook_id = get(meta, "notebook_id", nothing)
    entries = load_trace_entries(log_path)
    outcome = score_outcome(mcp_url, scenario; notebook_id=notebook_id)
    trace = score_trace(entries, get(scenario, "trace", nothing); strict_read_guard=strict_trace)
    report = Dict{String,Any}(
        "scenario"  => string(scenario["id"]),
        "run_id"    => get(meta, "run_id", get(ENV, "PLUTOMCP_EVAL_RUN_ID", "")),
        "model"     => get(meta, "model", nothing),
        "outcome"   => outcome,
        "trace"     => trace,
        "efficiency"=> Dict("tool_calls" => length(entries)),
    )
    outcome_pass = outcome["pass"]
    trace_pass = trace["pass"]
    exit_code = outcome_pass ? 0 : 1
    if strict_trace && !trace_pass
        exit_code = 1
    end
    return report, exit_code
end

function free_port()
    listener = listen(IPv4(0), 0)
    port = Int(getsockname(listener)[2])
    close(listener)
    return port
end
