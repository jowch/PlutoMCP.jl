#!/usr/bin/env julia
# Score a Pluto MCP eval run: outcome (strict) + trace (advisory by default).

using Pkg
Pkg.activate(dirname(@__DIR__))

include(joinpath(@__DIR__, "lib", "EvalShared.jl"))
using JSON3

function main()
    opts = parse_cli_args(Dict(
        "mcp-url" => "http://127.0.0.1:2346",
    ))
    haskey(opts, "scenario") || error("Usage: score.jl --scenario <path|id> [--log trace.jsonl] [--mcp-url URL] [--meta meta.json] [--strict-trace]")
    resolved = scenario_path(opts["scenario"])
    log_path = get(opts, "log", nothing)
    meta_path = get(opts, "meta", nothing)
    strict = haskey(opts, "strict-trace")
    report, exit_code = run_score(
        scenario_path = resolved,
        log_path      = log_path,
        mcp_url       = mcp_url_from_opts(opts),
        meta_path     = meta_path,
        strict_trace  = strict,
    )
    println(JSON3.write(report))
    if !report["trace"]["pass"] && !strict
        for d in report["trace"]["diagnostics"]
            @warn "trace advisory" d
        end
    end
    exit(exit_code)
end

main()
