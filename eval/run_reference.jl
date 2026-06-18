#!/usr/bin/env julia
# Golden-path reference runner: executes canonical tool sequences via HTTP /call.

using Pkg
Pkg.activate(dirname(@__DIR__))

include(joinpath(@__DIR__, "lib", "EvalShared.jl"))
using JSON3
using Sockets

function spawn_serve!(fixture_path::String; pluto_port, mcp_port, eval_log, run_id, setup)
    req_secret = get(setup, "require_secret_for_access", false)
    launch_browser = get(setup, "launch_browser", false)
    proj = dirname(@__DIR__)
    code = """
    using PlutoMCP
    PlutoMCP.serve(
        pluto_port = $pluto_port,
        mcp_port = $mcp_port,
        notebook = $(repr(fixture_path)),
        launch_browser = $launch_browser,
        require_secret_for_access = $req_secret,
        eval_log = $(repr(eval_log)),
        eval_run_id = $(repr(run_id)),
    )
    """
    cmd = `julia --project=$proj -e $code`
    return run(pipeline(cmd, stdout=devnull, stderr=devnull), wait=false)
end

function kill_proc!(proc)
    proc === nothing && return
    try
        kill(proc, 15)
        wait(proc)
    catch
        try kill(proc, 9) catch end
    end
end

function execute_reference_sequence(base_url::String, notebook_id::String, sequence)
    id = 1
    for step in sequence
        tool = string(step["tool"])
        args = substitute_notebook_id(step["arguments"], notebook_id)
        result, parsed, is_error = mcp_call(base_url, tool, args; id=id)
        id += 1
        expect = get(step, "expect_error", nothing)
        if expect !== nothing
            is_error || error("Expected error $expect for $tool but call succeeded")
            et = parsed isa Dict ? get(parsed, "error", nothing) : nothing
            et_str = et === nothing ? string(parsed) : string(et)
            occursin(string(expect), et_str) ||
                error("Expected error_type $expect, got $et_str for $tool")
        else
            is_error && error("Unexpected error on $tool: $parsed")
        end
        sleep(0.05)
    end
end

function run_one_scenario(scenario_file::String; strict_trace=false)
    scenario = load_scenario(scenario_file)
    sid = string(scenario["id"])
    fixture_name = string(scenario["fixture"])
    fixture_src = joinpath(EVAL_ROOT, "fixtures", fixture_name)
    isfile(fixture_src) || error("Missing fixture: $fixture_src")

    tmp = tempname() * ".jl"
    cp(fixture_src, tmp)

    pluto_port = free_port()
    mcp_port = free_port()
    run_id = "ref-$sid-$(uuid4())"
    results_dir = joinpath(EVAL_ROOT, "results", run_id)
    mkpath(results_dir)
    eval_log = joinpath(results_dir, "trace.jsonl")

    setup = get(scenario, "setup", Dict{String,Any}())
    mcp_url = "http://127.0.0.1:$mcp_port"

    proc = spawn_serve!(tmp; pluto_port, mcp_port, eval_log, run_id, setup)
    try
        wait_health(mcp_url; timeout_sec=60) || error("Health check failed for $sid")
        notebook_id = wait_readiness(mcp_url, scenario)

        sequence = get(scenario, "reference_sequence", nothing)
        sequence === nothing && error("Scenario $sid missing reference_sequence")
        execute_reference_sequence(mcp_url, notebook_id, sequence)

        meta_path = joinpath(results_dir, "meta.json")
        open(meta_path, "w") do io
            write(io, JSON3.write(Dict(
                "notebook_id" => notebook_id,
                "run_id"      => run_id,
                "mcp_port"    => mcp_port,
                "scenario_id" => sid,
            )))
        end

        report, exit_code = run_score(
            scenario_path = scenario_file,
            log_path      = eval_log,
            mcp_url       = mcp_url,
            meta_path     = meta_path,
            strict_trace  = strict_trace,
        )
        summary_path = joinpath(results_dir, "summary.json")
        open(summary_path, "w") do io
            write(io, JSON3.write(report))
        end
        println("[$sid] outcome=$(report["outcome"]["pass"]) trace=$(report["trace"]["pass"]) → $summary_path")
        return exit_code == 0
    finally
        kill_proc!(proc)
        rm(tmp; force=true)
    end
end

function all_scenario_files()
    dir = joinpath(EVAL_ROOT, "scenarios")
    files = filter(f -> endswith(f, ".json") && f != "schema.json", readdir(dir))
    sort([joinpath(dir, f) for f in files])
end

function main()
    opts = parse_cli_args()
    strict = haskey(opts, "strict-trace")
    if haskey(opts, "all")
        files = all_scenario_files()
        failed = String[]
        for f in files
            ok = run_one_scenario(f; strict_trace=strict)
            ok || push!(failed, basename(f))
        end
        isempty(failed) || begin
            error("Reference runner failed: $(join(failed, ", "))")
        end
        println("All $(length(files)) reference scenarios passed.")
        return
    end
    scenario_arg = get(opts, "scenario", "stage_and_run")
    path = scenario_path(scenario_arg)
    ok = run_one_scenario(path; strict_trace=strict)
    ok || exit(1)
end

main()
