using PlutoMCP
using Pluto
using Test
using UUIDs
using JSON
using HTTP
using Sockets
using SHA

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function make_session_with_notebook(cells...)
    session  = Pluto.ServerSession()
    nb_cells = [Pluto.Cell(; code=c) for c in cells]
    nb       = Pluto.Notebook(collect(nb_cells), tempname() * ".jl")
    session.notebooks[nb.notebook_id] = nb
    session, nb, nb_cells
end

function read_cells!(session, nb, cells...)
    for cell in cells
        PlutoMCP.tool_read_cell(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cell.cell_id),
        ))
    end
end

# ---------------------------------------------------------------------------
# Unit tests — no Pluto web server required
# ---------------------------------------------------------------------------

@testset "PlutoMCP.jl" begin

    PlutoMCP.reset_staging_state!()

    @testset "list_notebooks" begin
        session, nb, _ = make_session_with_notebook("x = 1")
        result = PlutoMCP.tool_list_notebooks(session, Dict())
        @test length(result) == 1
        @test result[1]["notebook_id"] == string(nb.notebook_id)
        @test result[1]["cell_count"] == 1
    end

    @testset "read_cell" begin
        session, nb, cells = make_session_with_notebook("z = 99")
        args   = Dict("notebook_id" => string(nb.notebook_id), "cell_id" => string(cells[1].cell_id))
        result = PlutoMCP.tool_read_cell(session, args)
        @test result["cell_id"] == string(cells[1].cell_id)
        @test result["code"] == "z = 99"
        @test result["stale"] == false
    end

    @testset "error on unknown notebook_id" begin
        session, _, _ = make_session_with_notebook("x = 1")
        fake_id = string(uuid4())
        @test_throws Exception PlutoMCP.tool_read_cell(session,
            Dict("notebook_id" => fake_id, "cell_id" => string(uuid4())))
    end

    @testset "error on unknown cell_id" begin
        session, nb, _ = make_session_with_notebook("x = 1")
        fake_cell_id = string(uuid4())
        @test_throws Exception PlutoMCP.tool_read_cell(session,
            Dict("notebook_id" => string(nb.notebook_id), "cell_id" => fake_cell_id))
    end

    @testset "add_cell appended on empty notebook" begin
        session  = Pluto.ServerSession()
        nb       = Pluto.Notebook(Pluto.Cell[], tempname() * ".jl")
        session.notebooks[nb.notebook_id] = nb
        args = Dict(
            "notebook_id" => string(nb.notebook_id),
            "code"        => "new_var = 42",
            "run_after"   => false,
        )
        result = PlutoMCP.tool_add_cell(session, args)
        @test haskey(result, "cell_id")
        @test result["code"] == "new_var = 42"
        @test length(nb.cell_order) == 1
        @test nb.cell_order[1] == UUID(result["cell_id"])
    end

    @testset "add_cell rejects missing placement on non-empty notebook" begin
        session, nb, _ = make_session_with_notebook("x = 1")
        args = Dict(
            "notebook_id" => string(nb.notebook_id),
            "code"        => "new_var = 42",
        )
        @test_throws Exception PlutoMCP.tool_add_cell(session, args)
    end

    @testset "add_cell after_cell_id" begin
        session, nb, cells = make_session_with_notebook("first", "last")
        read_cells!(session, nb, cells[1])
        args = Dict(
            "notebook_id"   => string(nb.notebook_id),
            "code"          => "middle",
            "after_cell_id" => string(cells[1].cell_id),
            "run_after"     => false,
        )
        result = PlutoMCP.tool_add_cell(session, args)
        @test length(nb.cell_order) == 3
        @test nb.cell_order[2] == UUID(result["cell_id"])
    end

    @testset "add_cell assigns new cell_order vector" begin
        session, nb, cells = make_session_with_notebook("first", "last")
        read_cells!(session, nb, cells[2])
        order_before = nb.cell_order
        args = Dict(
            "notebook_id"   => string(nb.notebook_id),
            "code"          => "tail",
            "after_cell_id" => string(cells[2].cell_id),
            "run_after"     => false,
        )
        PlutoMCP.tool_add_cell(session, args)
        @test nb.cell_order !== order_before
    end

    @testset "edit_cell default does not execute" begin
        session, nb, cells = make_session_with_notebook("x = 1", "y = x")
        Pluto.update_save_run!(session, nb, nb.cells; run_async=false, save=true)

        cell_y = cells[2]
        @test PlutoMCP._serialize_output(cell_y) == "1"

        read_cells!(session, nb, cells[1])
        result = PlutoMCP.tool_edit_cell(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cells[1].cell_id),
            "code"        => "x = 10",
        ))
        @test result["stale"] == true
        @test PlutoMCP._serialize_output(cell_y) == "1"
        @test result["pending_run"] == [string(cells[1].cell_id)]
    end

    @testset "submit_changes runs staged cells" begin
        session, nb, cells = make_session_with_notebook("x = 1", "y = x")
        Pluto.update_save_run!(session, nb, nb.cells; run_async=false, save=true)

        read_cells!(session, nb, cells[1])
        PlutoMCP.tool_edit_cell(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cells[1].cell_id),
            "code"        => "x = 10",
        ))

        receipt = PlutoMCP.tool_submit_changes(session, Dict(
            "notebook_id"         => string(nb.notebook_id),
            "wait_for_completion" => true,
        ))
        @test receipt["applied"] == true
        @test string(cells[1].cell_id) ∈ receipt["affected_cells"]
        @test isempty(receipt["pending_run"])

        cell_y = cells[2]
        @test PlutoMCP._serialize_output(cell_y) == "10"
    end

    @testset "submit_changes noop when nothing pending" begin
        session, nb, _ = make_session_with_notebook("x = 1")
        Pluto.update_save_run!(session, nb, nb.cells; run_async=false, save=true)
        receipt = PlutoMCP.tool_submit_changes(session, Dict(
            "notebook_id" => string(nb.notebook_id),
        ))
        @test receipt["execution"]["status"] == "completed"
        @test isempty(receipt["pending_run"])
    end

    @testset "submit_changes not_staged and force" begin
        session, nb, cells = make_session_with_notebook("x = 1", "y = x")
        Pluto.update_save_run!(session, nb, nb.cells; run_async=false, save=true)
        read_cells!(session, nb, cells[1])
        @test_throws Exception PlutoMCP.tool_submit_changes(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_ids"    => [string(cells[2].cell_id)],
        ))
        receipt = PlutoMCP.tool_submit_changes(session, Dict(
            "notebook_id"         => string(nb.notebook_id),
            "cell_ids"            => [string(cells[2].cell_id)],
            "force"               => true,
            "wait_for_completion" => true,
        ))
        @test receipt["applied"] == true
        @test string(cells[2].cell_id) ∈ receipt["affected_cells"]
    end

    @testset "read-before-edit guard" begin
        session, nb, cells = make_session_with_notebook("x = 1", "y = x")

        @test_throws Exception PlutoMCP.tool_edit_cell(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cells[1].cell_id),
            "code"        => "x = 2",
        ))

        read_cells!(session, nb, cells[1])
        result = PlutoMCP.tool_edit_cell(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cells[1].cell_id),
            "code"        => "x = 2",
        ))
        @test result["code"] == "x = 2"

        cells[1].code = "x = 99"
        @test_throws Exception PlutoMCP.tool_edit_cell(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cells[1].cell_id),
            "code"        => "x = 3",
        ))

        PlutoMCP.tool_read_notebook_code(session,
            Dict("notebook_id" => string(nb.notebook_id)))
        result2 = PlutoMCP.tool_edit_cell(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cells[1].cell_id),
            "code"        => "x = 3",
        ))
        @test result2["code"] == "x = 3"

        session2, nb2, cells2 = make_session_with_notebook("a = 1")
        @test_throws Exception PlutoMCP.tool_add_cell(session2, Dict(
            "notebook_id"   => string(nb2.notebook_id),
            "code"          => "b = 2",
            "after_cell_id" => string(cells2[1].cell_id),
        ))
        read_cells!(session2, nb2, cells2[1])
        add_result = PlutoMCP.tool_add_cell(session2, Dict(
            "notebook_id"   => string(nb2.notebook_id),
            "code"          => "b = 2",
            "after_cell_id" => string(cells2[1].cell_id),
        ))
        @test add_result["code"] == "b = 2"
    end

    @testset "delete_cell" begin
        session, nb, cells = make_session_with_notebook("x = 1", "y = 2")
        args = Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cells[1].cell_id),
        )
        result = PlutoMCP.tool_delete_cell(session, args)
        @test result["applied"] == true
        @test length(nb.cell_order) == 1
        @test !haskey(nb.cells_dict, cells[1].cell_id)
    end

    @testset "move_cell to top" begin
        session, nb, cells = make_session_with_notebook("first", "second", "third")
        args = Dict(
            "notebook_id"   => string(nb.notebook_id),
            "cell_id"       => string(cells[3].cell_id),
            "after_cell_id" => "",
        )
        PlutoMCP.tool_move_cell(session, args)
        @test nb.cell_order[1] == cells[3].cell_id
        @test nb.cell_order[2] == cells[1].cell_id
        @test nb.cell_order[3] == cells[2].cell_id
    end

    @testset "move_cell after target" begin
        session, nb, cells = make_session_with_notebook("first", "second", "third")
        args = Dict(
            "notebook_id"   => string(nb.notebook_id),
            "cell_id"       => string(cells[1].cell_id),
            "after_cell_id" => string(cells[3].cell_id),
        )
        PlutoMCP.tool_move_cell(session, args)
        @test nb.cell_order[1] == cells[2].cell_id
        @test nb.cell_order[2] == cells[3].cell_id
        @test nb.cell_order[3] == cells[1].cell_id
    end

    @testset "_serialize_output plain text" begin
        cell = Pluto.Cell(; code="1 + 1")
        cell.output = Pluto.CellOutput(body="2", mime=MIME("text/plain"))
        @test PlutoMCP._serialize_output(cell) == "2"
    end

    @testset "_serialize_output errored" begin
        cell = Pluto.Cell(; code="error(\"boom\")")
        cell.errored = true
        cell.output  = Pluto.CellOutput(body="boom", mime=MIME("text/plain"))
        @test PlutoMCP._serialize_output(cell) == "boom"
    end

    @testset "_structure_error multi_expression" begin
        body = Dict{Symbol,Any}(
            :msg => "syntax: extra token after end of expression\n\nBoundaries: [13, 30]",
        )
        err = PlutoMCP._structure_error(body)
        @test err["kind"] == "pluto_multi_expression"
        @test err["boundaries"] == [13, 30]
        @test err["split_count"] == 2
        @test err["fixes"] == ["wrap_begin_end", "split_cells"]
        @test occursin("begin ... end block (preferred)", err["hint"])
    end

    @testset "read_cell structured error" begin
        session, nb, cells = make_session_with_notebook("using Plots\nplot(sin, 0, 2pi)")
        cell = cells[1]
        cell.code = "using Plots\nplot(sin, 0, 2pi)"
        Pluto.update_save_run!(session, nb, [cell]; run_async=false, save=true)
        result = PlutoMCP.tool_read_cell(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cell.cell_id),
        ))
        @test result["errored"] == true
        @test haskey(result, "error")
        @test result["error"]["kind"] == "pluto_multi_expression"
        @test occursin("begin ... end", result["output"])
    end

    @testset "_serialize_output HTML" begin
        cell = Pluto.Cell(; code="html\"<b>hi</b>\"")
        cell.output = Pluto.CellOutput(body="<b>hi</b>", mime=MIME("text/html"))
        out = PlutoMCP._serialize_output(cell)
        @test startswith(out, "[text/html output,")
    end

    # ---------------------------------------------------------------------------
    # MCP protocol round-trip tests (no network, no Pluto web server)
    # ---------------------------------------------------------------------------

    # Helper: write a newline-delimited JSON message to a buffer
    function write_msg(buf, msg)
        write(buf, PlutoMCP.JSON.json(msg))
        write(buf, '\n')
    end

    # Helper: read one newline-delimited JSON response from a buffer
    function read_resp(buf)
        seekstart(buf)
        PlutoMCP.JSON.parse(readline(buf; keep=false), Dict{String,Any})
    end

    @testset "MCP protocol: initialize" begin
        session, nb, _ = make_session_with_notebook("x = 7")

        buf_in  = IOBuffer()
        buf_out = IOBuffer()

        write_msg(buf_in, Dict("jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => Dict()))
        seekstart(buf_in)

        PlutoMCP.run_mcp_server(session, buf_in, buf_out)

        resp = read_resp(buf_out)
        @test resp["result"]["protocolVersion"] == PlutoMCP.MCP_PROTOCOL_VERSION
        @test resp["result"]["serverInfo"]["name"] == "PlutoMCP"
        @test resp["result"]["serverInfo"]["version"] == PlutoMCP.MCP_SERVER_VERSION
    end

    @testset "serverInfo.version tracks Project.toml" begin
        # Regression: MCP_SERVER_VERSION was hardcoded to "1.0.0" and silently
        # drifted from the released version for several releases.
        toml = read(joinpath(pkgdir(PlutoMCP), "Project.toml"), String)
        m    = match(r"(?m)^version\s*=\s*\"([^\"]+)\"", toml)
        @test m !== nothing
        @test PlutoMCP.MCP_SERVER_VERSION == m.captures[1]
    end

    @testset "MCP protocol: tools/list" begin
        session, _, _ = make_session_with_notebook("x = 1")

        buf_in  = IOBuffer()
        buf_out = IOBuffer()

        write_msg(buf_in, Dict("jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => Dict()))
        seekstart(buf_in)

        PlutoMCP.run_mcp_server(session, buf_in, buf_out)

        resp  = read_resp(buf_out)
        names = [t["name"] for t in resp["result"]["tools"]]

        @test "list_notebooks"  ∈ names
        @test "read_cell"       ∈ names
        @test "edit_cell"       ∈ names
        @test "edit_cells"      ∈ names
        @test "submit_changes"  ∈ names
        @test "execute_cell"    ∈ names
        @test "add_cell"        ∈ names
        @test "delete_cell"     ∈ names
        @test "run_all_cells"   ∈ names
        @test "move_cell"       ∈ names
        @test !("get_notebook_state" ∈ names)
        @test !("get_cell" ∈ names)
        @test !("set_cell_code" ∈ names)
        @test !("run_cell" ∈ names)
    end

    @testset "MCP protocol: tools/call list_notebooks" begin
        session, nb, _ = make_session_with_notebook("x = 1")

        buf_in  = IOBuffer()
        buf_out = IOBuffer()

        write_msg(buf_in, Dict("jsonrpc" => "2.0", "id" => 3, "method" => "tools/call",
            "params" => Dict("name" => "list_notebooks", "arguments" => Dict{String,Any}())))
        seekstart(buf_in)

        PlutoMCP.run_mcp_server(session, buf_in, buf_out)

        resp = read_resp(buf_out)
        @test resp["result"]["isError"] == false
        data = PlutoMCP.JSON.parse(resp["result"]["content"][1]["text"])
        @test length(data) == 1
        @test data[1]["notebook_id"] == string(nb.notebook_id)
    end

    @testset "MCP protocol: unknown method returns error" begin
        session, _, _ = make_session_with_notebook("x = 1")

        buf_in  = IOBuffer()
        buf_out = IOBuffer()

        write_msg(buf_in, Dict("jsonrpc" => "2.0", "id" => 4, "method" => "nonexistent", "params" => Dict()))
        seekstart(buf_in)

        PlutoMCP.run_mcp_server(session, buf_in, buf_out)

        resp = read_resp(buf_out)
        @test haskey(resp, "error")
        @test resp["error"]["code"] == -32601
    end

    # ---------------------------------------------------------------------------
    # Integration test — real Pluto session, Julia API only (no MCP stdio)
    # ---------------------------------------------------------------------------

    @testset "Integration: edit_cell run_after triggers reactivity" begin
        fixture = joinpath(@__DIR__, "fixtures", "test_notebook.jl")
        @test isfile(fixture)

        tmp = tempname() * ".jl"
        cp(fixture, tmp)

        session = Pluto.ServerSession(;
            options = Pluto.Configuration.from_flat_kwargs(launch_browser = false),
        )
        pluto_task = @async Pluto.run!(session)
        try
            deadline = time() + 30.0
            while time() < deadline && isempty(session.notebooks)
                sleep(0.1)
            end

            nb = Pluto.SessionActions.open(session, tmp; run_async=false)

            cell_x_id = "11111111-1111-1111-1111-111111111111"
            cell_y_id = "22222222-2222-2222-2222-222222222222"

            result_y = PlutoMCP.tool_read_cell(session,
                Dict("notebook_id" => string(nb.notebook_id), "cell_id" => cell_y_id))
            @test result_y["output"] == "42"

            PlutoMCP.tool_read_cell(session,
                Dict("notebook_id" => string(nb.notebook_id), "cell_id" => cell_x_id))
            PlutoMCP.tool_edit_cell(session, Dict(
                "notebook_id" => string(nb.notebook_id),
                "cell_id"     => cell_x_id,
                "code"        => "x = 10",
                "run_after"   => true,
            ))

            # run_after is non-blocking; poll until reactive output updates.
            result_y2 = nothing
            deadline = time() + 30.0
            while time() < deadline
                result_y2 = PlutoMCP.tool_read_cell(session,
                    Dict("notebook_id" => string(nb.notebook_id), "cell_id" => cell_y_id))
                result_y2["output"] == "70" && !result_y2["running"] && !result_y2["queued"] && break
                sleep(0.05)
            end
            @test result_y2["output"] == "70"

            Pluto.SessionActions.shutdown(session, nb; async=false, verbose=false)
            sleep(1.0)
        finally
            rm(tmp; force=true)
            try; schedule(pluto_task, InterruptException(); error=true); catch; end
            sleep(0.5)
        end
    end

    @testset "edit_cells stages multiple cells without executing" begin
        session, nb, cells = make_session_with_notebook("a = 1", "b = 2", "c = a + b")
        Pluto.update_save_run!(session, nb, nb.cells; run_async=false, save=true)

        cell_c = cells[3]
        @test PlutoMCP._serialize_output(cell_c) == "3"

        read_cells!(session, nb, cells[1], cells[2])
        receipt = PlutoMCP.tool_edit_cells(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cells"       => [
                Dict("cell_id" => string(cells[1].cell_id), "code" => "a = 10"),
                Dict("cell_id" => string(cells[2].cell_id), "code" => "b = 20"),
            ],
        ))
        @test receipt["applied"] == true
        @test receipt["mutation"]["type"] == "edit_cells"
        @test length(receipt["pending_run"]) == 2
        @test PlutoMCP._serialize_output(cell_c) == "3"
        @test receipt["execution"]["status"] == "staged"
    end

    @testset "delete_cell returns mutation receipt" begin
        session, nb, cells = make_session_with_notebook("x = 1", "y = 2")
        result = PlutoMCP.tool_delete_cell(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cells[1].cell_id),
        ))
        @test result["applied"] == true
        @test result["mutation"]["type"] == "delete_cell"
        @test haskey(result, "cell_order")
        @test any(startswith(w, "async_execution::") for w in result["warnings"])
    end

    @testset "move_cell receipt includes cell_order" begin
        session, nb, cells = make_session_with_notebook("first", "second", "third")
        receipt = PlutoMCP.tool_move_cell(session, Dict(
            "notebook_id"   => string(nb.notebook_id),
            "cell_id"       => string(cells[3].cell_id),
            "after_cell_id" => "",
        ))
        @test receipt["applied"] == true
        @test receipt["cell_order"] == [string(id) for id in nb.cell_order]
        @test receipt["mutation"]["old_index"] == 3
        @test receipt["mutation"]["new_index"] == 1
    end

    @testset "execute_cell receipt has execution status" begin
        session, nb, cells = make_session_with_notebook("x = 1")
        Pluto.update_save_run!(session, nb, nb.cells; run_async=false, save=true)

        receipt = PlutoMCP.tool_execute_cell(session, Dict(
            "notebook_id"         => string(nb.notebook_id),
            "cell_id"             => string(cells[1].cell_id),
            "wait_for_completion" => true,
        ))
        @test receipt["applied"] == true
        @test receipt["execution"]["status"] == "completed"
        @test string(cells[1].cell_id) ∈ receipt["affected_cells"]
    end

    @testset "execute_cell default is non-blocking" begin
        session, nb, cells = make_session_with_notebook("x = 1")
        Pluto.update_save_run!(session, nb, nb.cells; run_async=false, save=true)

        receipt = PlutoMCP.tool_execute_cell(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cells[1].cell_id),
        ))
        @test receipt["applied"] == true
        @test receipt["execution"]["status"] == "running"
        @test any(startswith(w, "async_execution::") for w in receipt["warnings"])
    end

    @testset "submit_changes default is non-blocking" begin
        session, nb, cells = make_session_with_notebook("x = 1", "y = x")
        Pluto.update_save_run!(session, nb, nb.cells; run_async=false, save=true)

        read_cells!(session, nb, cells[1])
        PlutoMCP.tool_edit_cell(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cells[1].cell_id),
            "code"        => "x = 10",
        ))

        receipt = PlutoMCP.tool_submit_changes(session, Dict(
            "notebook_id" => string(nb.notebook_id),
        ))
        @test receipt["applied"] == true
        @test receipt["execution"]["status"] == "running"
        @test any(startswith(w, "async_execution::") for w in receipt["warnings"])
    end

    @testset "read_notebook_code execution order" begin
        fixture = joinpath(@__DIR__, "fixtures", "test_notebook.jl")
        session = Pluto.ServerSession()
        nb      = Pluto.load_notebook_nobackup(fixture)
        session.notebooks[nb.notebook_id] = nb
        Pluto.update_dependency_cache!(nb)

        result = PlutoMCP.tool_read_notebook_code(session,
            Dict("notebook_id" => string(nb.notebook_id)))

        @test result["order"] == "execution"
        @test result["cell_ids"] == [
            "11111111-1111-1111-1111-111111111111",
            "22222222-2222-2222-2222-222222222222",
        ]
        @test occursin("# ╔═╡ 11111111-1111-1111-1111-111111111111", result["code"])
        @test occursin("x = 6", result["code"])
        @test occursin("y = x * 7", result["code"])
    end

    @testset "read_notebook_code empty cell" begin
        session, nb, cells = make_session_with_notebook("x = 1", "")
        Pluto.update_dependency_cache!(nb)

        result = PlutoMCP.tool_read_notebook_code(session,
            Dict("notebook_id" => string(nb.notebook_id)))

        @test string(cells[2].cell_id) ∈ result["cell_ids"]
        @test occursin("# ╔═╡ $(cells[2].cell_id)", result["code"])
        @test occursin("# (empty)", result["code"])
    end

    @testset "get_cell_order vs get_execution_order" begin
        cell_z = Pluto.Cell(; cell_id=UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"), code="z = 10")
        cell_w = Pluto.Cell(; cell_id=UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"), code="w = z + 1")
        session = Pluto.ServerSession()
        nb      = Pluto.Notebook([cell_z, cell_w], tempname() * ".jl")
        nb.cell_order = [cell_w.cell_id, cell_z.cell_id]
        session.notebooks[nb.notebook_id] = nb
        Pluto.update_dependency_cache!(nb)

        visual = PlutoMCP.tool_get_cell_order(session,
            Dict("notebook_id" => string(nb.notebook_id)))
        exec = PlutoMCP.tool_get_execution_order(session,
            Dict("notebook_id" => string(nb.notebook_id)))

        @test visual["cell_ids"] == [
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
        ]
        @test exec["cell_ids"] == [
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
        ]
    end

    @testset "MCP protocol: tools/list projection tools" begin
        session, _, _ = make_session_with_notebook("x = 1")

        buf_in  = IOBuffer()
        buf_out = IOBuffer()

        write_msg(buf_in, Dict("jsonrpc" => "2.0", "id" => 5, "method" => "tools/list", "params" => Dict()))
        seekstart(buf_in)

        PlutoMCP.run_mcp_server(session, buf_in, buf_out)

        resp  = read_resp(buf_out)
        names = [t["name"] for t in resp["result"]["tools"]]

        @test "read_notebook_code"  ∈ names
        @test "get_cell_order"      ∈ names
        @test "get_execution_order" ∈ names
    end

    @testset "graph tools on reactive chain" begin
        session, nb, cells = make_session_with_notebook("x = 1", "y = x * 7")
        Pluto.update_save_run!(session, nb, nb.cells; run_async=false, save=true)

        cell_x, cell_y = cells[1], cells[2]

        deps = PlutoMCP.tool_get_cell_dependencies(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cell_y.cell_id),
        ))
        @test string(cell_x.cell_id) ∈ deps["upstream"]
        @test "x" ∈ deps["symbols"]

        upstream_x = PlutoMCP.tool_get_cell_dependencies(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cell_x.cell_id),
        ))
        @test isempty(upstream_x["upstream"])

        dependents = PlutoMCP.tool_get_cell_dependents(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cell_x.cell_id),
        ))
        @test dependents["downstream"] == [string(cell_y.cell_id)]

        leaf_dependents = PlutoMCP.tool_get_cell_dependents(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cell_y.cell_id),
        ))
        @test isempty(leaf_dependents["downstream"])
    end

    @testset "find_symbol_definitions and references" begin
        session, nb, cells = make_session_with_notebook("x = 1", "y = x * 7")
        Pluto.update_save_run!(session, nb, nb.cells; run_async=false, save=true)

        defs_x = PlutoMCP.tool_find_symbol_definitions(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "symbol"      => "x",
        ))
        @test length(defs_x) == 1
        @test defs_x[1]["cell_id"] == string(cells[1].cell_id)
        @test defs_x[1]["line_hint"] == 1

        refs_x = PlutoMCP.tool_find_symbol_references(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "symbol"      => "x",
        ))
        ref_ids = [r["cell_id"] for r in refs_x]
        @test string(cells[2].cell_id) ∈ ref_ids
        @test string(cells[1].cell_id) ∉ ref_ids

        defs_y = PlutoMCP.tool_find_symbol_definitions(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "symbol"      => "y",
        ))
        @test length(defs_y) == 1
        @test defs_y[1]["cell_id"] == string(cells[2].cell_id)
    end

    @testset "validate_cell rejects multi-expression" begin
        session, nb, cells = make_session_with_notebook("x = 1")
        Pluto.update_save_run!(session, nb, nb.cells; run_async=false, save=true)

        result = PlutoMCP.tool_validate_cell(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cells[1].cell_id),
            "code"        => "a = 1\nb = 2",
        ))
        @test result["valid"] == false
        @test any(e -> e["type"] == "pluto_multi_expression", result["errors"])

        ok = PlutoMCP.tool_validate_cell(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cells[1].cell_id),
            "code"        => "x = 42",
        ))
        @test ok["valid"] == true
        @test isempty(ok["errors"])
    end

    @testset "search_code finds text symbol tools miss" begin
        session, nb, cells = make_session_with_notebook(
            "x = 1",
            "# comment mentions x but does not reference it",
            "y = x * 7",
        )
        Pluto.update_save_run!(session, nb, nb.cells; run_async=false, save=true)

        hits = PlutoMCP.tool_search_code(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "query"       => "mentions x",
        ))
        @test length(hits) == 1
        @test hits[1]["cell_id"] == string(cells[2].cell_id)

        refs_x = PlutoMCP.tool_find_symbol_references(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "symbol"      => "x",
        ))
        ref_ids = Set(r["cell_id"] for r in refs_x)
        @test string(cells[2].cell_id) ∉ ref_ids
    end

    @testset "MCP protocol: tools/list graph tools" begin
        session, _, _ = make_session_with_notebook("x = 1")

        buf_in  = IOBuffer()
        buf_out = IOBuffer()

        write_msg(buf_in, Dict("jsonrpc" => "2.0", "id" => 6, "method" => "tools/list", "params" => Dict()))
        seekstart(buf_in)

        PlutoMCP.run_mcp_server(session, buf_in, buf_out)

        resp  = read_resp(buf_out)
        names = [t["name"] for t in resp["result"]["tools"]]

        @test "resolve_pluto_context"    ∈ names
        @test "get_cell_dependencies"    ∈ names
        @test "get_cell_dependents"      ∈ names
        @test "find_symbol_definitions"  ∈ names
        @test "find_symbol_references"   ∈ names
        @test "validate_cell"            ∈ names
        @test "search_code"              ∈ names
    end

    @testset "resolve_pluto_context" begin
        dom = "div > pluto-notebook#456d9a62-6ae3-11f1-83e9-0de6400360b8 > pluto-cell#ac0fafc6-6ade-11f1-afe2-0f49ca84a4fb > pluto-output > img"
        r = PlutoMCP.resolve_pluto_context_string(dom)
        @test r["ok"] == true
        @test r["notebook_id"] == "456d9a62-6ae3-11f1-83e9-0de6400360b8"
        @test r["cell_id"] == "ac0fafc6-6ade-11f1-afe2-0f49ca84a4fb"
        @test r["in_output"] == true
        @test r["in_input"] == false

        block = """
        ```browser_element
        dom_path: $dom
        visible_text: b = 2
        ```
        """
        r2 = PlutoMCP.resolve_pluto_context_string(block)
        @test r2["ok"] == true
        @test r2["cell_id"] == r["cell_id"]

        url = "http://127.0.0.1:1234/45546158-6ae5-11f1-a279-f9f46f728fee"
        r3 = PlutoMCP.resolve_pluto_context_string(url)
        @test r3["ok"] == true
        @test r3["notebook_id"] == "45546158-6ae5-11f1-a279-f9f46f728fee"
        @test r3["cell_id"] === nothing

        custom_port = "http://127.0.0.1:8765/45546158-6ae5-11f1-a279-f9f46f728fee"
        r4 = PlutoMCP.resolve_pluto_context_string(custom_port)
        @test r4["ok"] == true
        @test r4["notebook_id"] == "45546158-6ae5-11f1-a279-f9f46f728fee"

        cell_only = "pluto-cell#ac0fafc6-6ade-11f1-afe2-0f49ca84a4fb"
        r5 = PlutoMCP.resolve_pluto_context_string(cell_only)
        @test r5["ok"] == false
        @test r5["reason"] == "notebook_id_missing"

        @test PlutoMCP.resolve_pluto_context_string("main > header")["ok"] == false
        @test PlutoMCP.resolve_pluto_context_string("")["reason"] == "invalid_context"

        session, nb, cells = make_session_with_notebook("x = 1")
        tool = PlutoMCP.tool_resolve_pluto_context(session, Dict(
            "context" => "pluto-notebook#$(nb.notebook_id) > pluto-cell#$(cells[1].cell_id) > pluto-input",
        ))
        @test tool["ok"] == true
        @test tool["notebook_open"] == true
        @test tool["in_input"] == true
    end

    @testset "read_notebook_code excludes manifest cells" begin
        fixture = joinpath(@__DIR__, "fixtures", "test_notebook.jl")
        session = Pluto.ServerSession()
        nb      = Pluto.load_notebook_nobackup(fixture)
        session.notebooks[nb.notebook_id] = nb
        Pluto.update_dependency_cache!(nb)

        result = PlutoMCP.tool_read_notebook_code(session,
            Dict("notebook_id" => string(nb.notebook_id)))

        @test !occursin("PLUTO_PROJECT_TOML_CONTENTS", result["code"])
        @test !occursin("PLUTO_MANIFEST_TOML_CONTENTS", result["code"])
        @test !("00000000-0000-0000-0000-000000000001" in result["cell_ids"])
    end

    @testset "add_cell records read receipt for immediate edit" begin
        session, nb, cells = make_session_with_notebook("x = 1")
        read_cells!(session, nb, cells[1])
        added = PlutoMCP.tool_add_cell(session, Dict(
            "notebook_id"   => string(nb.notebook_id),
            "code"          => "y = 2",
            "after_cell_id" => string(cells[1].cell_id),
        ))
        receipt = PlutoMCP.tool_edit_cell(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => added["cell_id"],
            "code"        => "y = 3",
        ))
        @test receipt["applied"] == true
    end

    @testset "run_all_cells clears pending_run" begin
        session, nb, cells = make_session_with_notebook("x = 1", "y = x + 1")
        Pluto.update_save_run!(session, nb, nb.cells; run_async=false, save=true)
        read_cells!(session, nb, cells[1])
        PlutoMCP.tool_edit_cell(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cells[1].cell_id),
            "code"        => "x = 10",
        ))
        @test !isempty(PlutoMCP.pending_run_ids(nb.notebook_id))

        receipt = PlutoMCP.tool_run_all_cells(session, Dict(
            "notebook_id"       => string(nb.notebook_id),
            "wait_for_completion" => true,
        ))
        @test receipt["mutation"]["type"] == "run_all_cells"
        @test isempty(receipt["pending_run"])
    end

    @testset "run_all_cells async reports running when cells dispatched" begin
        session, nb, _ = make_session_with_notebook("x = 1", "y = x + 1")
        Pluto.update_save_run!(session, nb, nb.cells; run_async=false, save=true)
        receipt = PlutoMCP.tool_run_all_cells(session, Dict(
            "notebook_id"         => string(nb.notebook_id),
            "wait_for_completion" => false,
        ))
        @test length(receipt["affected_cells"]) == 2
        @test receipt["execution"]["status"] == "running"
    end

    @testset "edit_cells is atomic on read guard failure" begin
        session, nb, cells = make_session_with_notebook("a = 1", "b = 2")
        read_cells!(session, nb, cells[1])
        @test_throws Exception PlutoMCP.tool_edit_cells(session, Dict(
            "notebook_id" => string(nb.notebook_id),
            "cells"       => [
                Dict("cell_id" => string(cells[1].cell_id), "code" => "a = 10"),
                Dict("cell_id" => string(cells[2].cell_id), "code" => "b = 20"),
            ],
        ))
        @test cells[1].code == "a = 1"
        @test isempty(PlutoMCP.pending_run_ids(nb.notebook_id))
    end

    @testset "EvalLog records tool calls" begin
        log_path = tempname() * ".jsonl"
        try
            PlutoMCP.configure_eval_log!(path=log_path, run_id="test-run", redact_code=false)
            session, nb, cells = make_session_with_notebook("x = 1")
            err_result = PlutoMCP._logged_handle_tool_call(session, "edit_cell", Dict{String,Any}(
                "notebook_id" => string(nb.notebook_id),
                "cell_id"     => string(cells[1].cell_id),
                "code"        => "x = 2",
            ))
            @test err_result["isError"] == true
            PlutoMCP._logged_handle_tool_call(session, "read_cell", Dict{String,Any}(
                "notebook_id" => string(nb.notebook_id),
                "cell_id"     => string(cells[1].cell_id),
            ))
            lines = filter(!isempty, split(read(log_path, String), '\n'))
            @test length(lines) == 2
            e1 = JSON.parse(lines[1], Dict{String,Any})
            e2 = JSON.parse(lines[2], Dict{String,Any})
            @test e1["tool"] == "edit_cell"
            @test e1["is_error"] == true
            @test e1["error_type"] == "read_required"
            @test e2["tool"] == "read_cell"
            @test e2["is_error"] == false
        finally
            PlutoMCP.configure_eval_log!(path=nothing)
            rm(log_path; force=true)
        end
    end

    # ---------------------------------------------------------------------------
    # D15 lifecycle — deferred standalone session
    # ---------------------------------------------------------------------------

    @testset "lifecycle: pluto_session_status when stopped" begin
        PlutoMCP.stop_pluto_stack!()
        status = PlutoMCP.tool_pluto_session_status(Dict{String,Any}())
        @test status["pluto"] == "stopped"
        @test status["pluto_port"] == 1234
        @test isempty(status["notebooks"])
    end

    @testset "lifecycle: open_notebook loads file without run" begin
        PlutoMCP.stop_pluto_stack!()
        fixture = joinpath(@__DIR__, "fixtures", "test_notebook.jl")
        session = Pluto.ServerSession()
        PlutoMCP.bind_standalone_session!(session)
        try
            result = PlutoMCP.tool_open_notebook(Dict(
                "path"         => fixture,
                "run_notebook" => false,
            ))
            @test isfile(fixture)
            @test haskey(result, "notebook_id")
            @test result["path"] == abspath(fixture)
            @test result["execution_allowed"] == false
            @test result["ran"] == false
            @test haskey(session.notebooks, UUID(result["notebook_id"]))
        finally
            PlutoMCP.stop_pluto_stack!()
        end
    end

    @testset "lifecycle: open_notebook file_not_found" begin
        PlutoMCP.stop_pluto_stack!()
        session = Pluto.ServerSession()
        PlutoMCP.bind_standalone_session!(session)
        try
            @test_throws Exception PlutoMCP.tool_open_notebook(Dict("path" => "/no/such/notebook.jl"))
        finally
            PlutoMCP.stop_pluto_stack!()
        end
    end

    @testset "lifecycle: allow_execution exits safe preview" begin
        PlutoMCP.stop_pluto_stack!()
        fixture = joinpath(@__DIR__, "fixtures", "test_notebook.jl")
        pluto_port = 1250 + rand(0:99)
        mcp_port = 2450 + rand(0:99)
        PlutoMCP.start_pluto_stack!(; pluto_port, mcp_port, launch_browser=false, http_async=true)
        try
            open_result = PlutoMCP.tool_open_notebook(Dict(
                "path"         => fixture,
                "run_notebook" => false,
            ))
            nid = open_result["notebook_id"]
            @test open_result["execution_allowed"] == false

            allow_result = PlutoMCP.tool_allow_execution(Dict(
                "notebook_id"  => nid,
                "run_notebook" => true,
            ))
            @test allow_result["execution_allowed"] == true
            @test allow_result["ran"] == true
            @test allow_result["already_allowed"] == false
            @test any(startswith(w, "async_execution::") for w in get(allow_result, "run_warnings", String[]))

            sess = PlutoMCP.standalone_session()
            nb = sess.notebooks[UUID(nid)]
            @test Pluto.will_run_code(nb)
        finally
            PlutoMCP.stop_pluto_stack!()
        end
    end

    @testset "lifecycle: allow_execution run_notebook=false exits gate without full run" begin
        PlutoMCP.stop_pluto_stack!()
        fixture = joinpath(@__DIR__, "fixtures", "test_notebook.jl")
        pluto_port = 1250 + rand(0:99)
        mcp_port = 2450 + rand(0:99)
        PlutoMCP.start_pluto_stack!(; pluto_port, mcp_port, launch_browser=false, http_async=true)
        try
            open_result = PlutoMCP.tool_open_notebook(Dict(
                "path"         => fixture,
                "run_notebook" => false,
            ))
            nid = open_result["notebook_id"]
            allow_result = PlutoMCP.tool_allow_execution(Dict(
                "notebook_id"  => nid,
                "run_notebook" => false,
            ))
            @test allow_result["execution_allowed"] == true
            @test allow_result["ran"] == false
            @test allow_result["already_allowed"] == false
            sess = PlutoMCP.standalone_session()
            nb = sess.notebooks[UUID(nid)]
            @test nb.process_status === Pluto.ProcessStatus.ready
            @test Pluto.will_run_code(nb)
        finally
            PlutoMCP.stop_pluto_stack!()
        end
    end

    @testset "lifecycle: allow_execution idempotent when already allowed" begin
        PlutoMCP.stop_pluto_stack!()
        fixture = joinpath(@__DIR__, "fixtures", "test_notebook.jl")
        pluto_port = 1250 + rand(0:99)
        mcp_port = 2450 + rand(0:99)
        PlutoMCP.start_pluto_stack!(; pluto_port, mcp_port, launch_browser=false, http_async=true)
        try
            open_result = PlutoMCP.tool_open_notebook(Dict(
                "path"         => fixture,
                "run_notebook" => true,
            ))
            nid = open_result["notebook_id"]
            sess = PlutoMCP.standalone_session()
            nb = sess.notebooks[UUID(nid)]
            # open_notebook(run_notebook=true) queues a non-blocking run; wait until ready.
            deadline = time() + 60.0
            while time() < deadline && nb.process_status !== Pluto.ProcessStatus.ready
                sleep(0.05)
            end
            @test nb.process_status === Pluto.ProcessStatus.ready

            again = PlutoMCP.tool_allow_execution(Dict(
                "notebook_id"  => nid,
                "run_notebook" => false,
            ))
            @test again["already_allowed"] == true
            @test again["execution_allowed"] == true
        finally
            PlutoMCP.stop_pluto_stack!()
        end
    end

    @testset "lifecycle: call_tool_with_session without Pluto" begin
        PlutoMCP.stop_pluto_stack!()
        @test_throws Exception PlutoMCP.call_tool_with_session(
            nothing, "read_cell", Dict("notebook_id" => "x", "cell_id" => "y"),
        )
    end

    @testset "MCP protocol: deferred read_cell returns pluto_not_running" begin
        PlutoMCP.stop_pluto_stack!()

        buf_in  = IOBuffer()
        buf_out = IOBuffer()

        write_msg(buf_in, Dict("jsonrpc" => "2.0", "id" => 7, "method" => "tools/call",
            "params" => Dict(
                "name" => "read_cell",
                "arguments" => Dict(
                    "notebook_id" => string(uuid4()),
                    "cell_id"     => string(uuid4()),
                ),
            )))
        seekstart(buf_in)

        PlutoMCP.run_mcp_server(nothing, buf_in, buf_out)

        resp = read_resp(buf_out)
        @test resp["result"]["isError"] == true
        err = JSON.parse(resp["result"]["content"][1]["text"])
        @test err["error"] == "pluto_not_running"
    end

    @testset "lifecycle: stop releases HTTP and Pluto ports" begin
        PlutoMCP.stop_pluto_stack!()
        pluto_port = 1250 + rand(0:99)
        mcp_port = 2450 + rand(0:99)
        port_up(url) = try
            HTTP.get(url; readtimeout=1, connect_timeout=1, status_exception=false).status == 200
        catch
            false
        end
        try
            PlutoMCP.start_pluto_stack!(; pluto_port, mcp_port, launch_browser=false, http_async=true)
            @test PlutoMCP.tool_pluto_session_status(Dict{String,Any}())["pluto"] == "running"
            @test port_up("http://127.0.0.1:$mcp_port/health")
            @test port_up("http://127.0.0.1:$pluto_port/ping")
            PlutoMCP.stop_pluto_stack!()
            sleep(0.5)
            @test !port_up("http://127.0.0.1:$mcp_port/health")
            @test !port_up("http://127.0.0.1:$pluto_port/ping")
        finally
            PlutoMCP.stop_pluto_stack!()
        end
    end

    @testset "MCP protocol: deferred pluto_session_status" begin
        PlutoMCP.stop_pluto_stack!()

        buf_in  = IOBuffer()
        buf_out = IOBuffer()

        write_msg(buf_in, Dict("jsonrpc" => "2.0", "id" => 8, "method" => "tools/call",
            "params" => Dict("name" => "pluto_session_status", "arguments" => Dict{String,Any}())))
        seekstart(buf_in)

        PlutoMCP.run_mcp_server(nothing, buf_in, buf_out)

        resp = read_resp(buf_out)
        @test resp["result"]["isError"] == false
        status = JSON.parse(resp["result"]["content"][1]["text"])
        @test status["pluto"] == "stopped"
    end

    @testset "MCP protocol: tools/list lifecycle tools" begin
        session, _, _ = make_session_with_notebook("x = 1")

        buf_in  = IOBuffer()
        buf_out = IOBuffer()

        write_msg(buf_in, Dict("jsonrpc" => "2.0", "id" => 9, "method" => "tools/list", "params" => Dict()))
        seekstart(buf_in)

        PlutoMCP.run_mcp_server(session, buf_in, buf_out)

        resp  = read_resp(buf_out)
        names = [t["name"] for t in resp["result"]["tools"]]

        @test "pluto_session_status" ∈ names
        @test "start_pluto_session" ∈ names
        @test "stop_pluto_session"  ∈ names
        @test "open_notebook"       ∈ names
        @test "allow_execution"     ∈ names
    end

    @testset "dispatch_stdio_message lazy-attaches to a later bridge (legacy unbound)" begin
        PlutoMCP.stop_pluto_stack!(; close_control_bridge=true)
        PlutoMCP.clear_session_binding_ref!()
        mcp_port = 2700 + rand(0:99)
        status_msg = Dict{String,Any}(
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/call",
            "params" => Dict{String,Any}(
                "name" => "pluto_session_status",
                "arguments" => Dict{String,Any}(),
            ),
        )

        local_resp = PlutoMCP.dispatch_stdio_message(status_msg; mcp_port)
        local_status = JSON.parse(local_resp["result"]["content"][1]["text"])
        @test local_status["pluto"] == "stopped"

        server = HTTP.serve!(function (http::HTTP.Stream)
            method = http.message.method
            target = http.message.target
            if method == "GET" && target == "/health"
                HTTP.setstatus(http, 200)
                HTTP.startwrite(http)
                write(http, "ok")
            elseif method == "POST" && startswith(target, "/call")
                read(http)
                HTTP.setstatus(http, 200)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(http, JSON.json(Dict{String,Any}(
                    "jsonrpc" => "2.0",
                    "id" => 1,
                    "result" => Dict{String,Any}("from" => "bridge"),
                )))
            else
                HTTP.setstatus(http, 404)
                HTTP.startwrite(http)
            end
        end, "127.0.0.1", Int(mcp_port); stream=true, verbose=false)
        try
            deadline = time() + 5.0
            while time() < deadline && !PlutoMCP.bridge_running(mcp_port)
                sleep(0.05)
            end
            @test PlutoMCP.bridge_running(mcp_port)
            proxied = PlutoMCP.dispatch_stdio_message(status_msg; mcp_port)
            @test proxied["result"]["from"] == "bridge"

            session = Pluto.ServerSession()
            PlutoMCP.bind_standalone_session!(session)
            owned = PlutoMCP.dispatch_stdio_message(status_msg; mcp_port)
            owned_status = JSON.parse(owned["result"]["content"][1]["text"])
            @test owned_status["pluto"] == "running"
            @test !haskey(owned["result"], "from")
        finally
            PlutoMCP.stop_pluto_stack!(; close_control_bridge=true)
            close(server)
        end
    end

    # ---------------------------------------------------------------------------
    # Bound Styx sessions — owned control bridges + notebook leases
    # ---------------------------------------------------------------------------

    function bound_runtime_setup(; host_pid=getpid() + rand(1000:9999))
        runtime = mktempdir()
        binding_file = joinpath(runtime, "windows", "$(host_pid).json")
        binding = PlutoMCP.SessionBinding(;
            runtime_dir = runtime,
            binding_file = binding_file,
            cursor_host_pid = host_pid,
        )
        PlutoMCP.configure_session_binding!(binding)
        PlutoMCP.claim_window_binding!(binding)
        hint = 28000 + rand(0:999)
        PlutoMCP.configure_standalone!(;
            pluto_port_hint = hint + 1000,
            mcp_port_hint = hint,
            require_secret_for_access = false,
        )
        port = PlutoMCP.start_control_bridge!(; mcp_port_hint = hint, listenany = true)
        return runtime, binding, Int(port)
    end

    function bound_runtime_teardown!()
        PlutoMCP.stop_pluto_stack!(; close_control_bridge = true)
        PlutoMCP.cleanup_session_binding!()
        PlutoMCP.configure_standalone!(; pluto_port=1234, mcp_port=2346, require_secret_for_access=true)
    end

    @testset "bound: wait_for_completion forced async" begin
        PlutoMCP.stop_pluto_stack!(; close_control_bridge=true)
        PlutoMCP.clear_session_binding_ref!()
        runtime = mktempdir()
        try
            binding = PlutoMCP.SessionBinding(;
                runtime_dir = runtime,
                binding_file = joinpath(runtime, "windows", "force-wait.json"),
                cursor_host_pid = getpid() + 4242,
            )
            PlutoMCP.configure_session_binding!(binding)
            @test PlutoMCP.is_bound_session()
            wait_for, warnings = PlutoMCP._effective_wait(true)
            @test wait_for == false
            @test any(startswith(w, "wait_forced_async::") for w in warnings)
            wait_ok, empty_w = PlutoMCP._effective_wait(false)
            @test wait_ok == false
            @test isempty(empty_w)

            session, nb, cells = make_session_with_notebook("x = 1")
            Pluto.update_save_run!(session, nb, nb.cells; run_async=false, save=true)
            receipt = PlutoMCP.tool_execute_cell(session, Dict(
                "notebook_id"         => string(nb.notebook_id),
                "cell_id"             => string(cells[1].cell_id),
                "wait_for_completion" => true,
            ))
            @test any(startswith(w, "wait_forced_async::") for w in receipt["warnings"])
            @test any(startswith(w, "async_execution::") for w in receipt["warnings"])
            @test receipt["execution"]["status"] == "running"
        finally
            PlutoMCP.clear_session_binding_ref!()
            rm(runtime; recursive=true, force=true)
        end
    end

    @testset "bound: JSON health and session header" begin
        PlutoMCP.stop_pluto_stack!(; close_control_bridge=true)
        PlutoMCP.clear_session_binding_ref!()
        runtime, binding, port = bound_runtime_setup()
        try
            resp = HTTP.get("http://127.0.0.1:$port/health"; readtimeout=2, connect_timeout=1)
            @test resp.status == 200
            health = JSON.parse(String(resp.body), Dict{String,Any})
            @test health["status"] == "ok"
            @test health["session_id"] == binding.session_id
            @test health["mcp_port"] == port
            @test health["pluto"] == "stopped"

            bad = HTTP.post(
                "http://127.0.0.1:$port/call";
                body = JSON.json(Dict("jsonrpc"=>"2.0","id"=>1,"method"=>"tools/call",
                    "params"=>Dict("name"=>"pluto_session_status","arguments"=>Dict()))),
                headers = ["Content-Type" => "application/json"],
                status_exception = false,
                readtimeout = 5,
            )
            @test bad.status == 409
            @test occursin("foreign_session", String(bad.body))

            good = HTTP.post(
                "http://127.0.0.1:$port/call";
                body = JSON.json(Dict("jsonrpc"=>"2.0","id"=>1,"method"=>"tools/call",
                    "params"=>Dict("name"=>"pluto_session_status","arguments"=>Dict()))),
                headers = [
                    "Content-Type" => "application/json",
                    PlutoMCP.STYX_SESSION_HEADER => binding.session_id,
                ],
                readtimeout = 5,
            )
            @test good.status == 200
            payload = JSON.parse(String(good.body), Dict{String,Any})
            status = JSON.parse(payload["result"]["content"][1]["text"], Dict{String,Any})
            @test status["managed"] == true
            @test status["session_id"] == binding.session_id
            @test isfile(binding.binding_file)
        finally
            bound_runtime_teardown!()
            rm(runtime; recursive=true, force=true)
        end
    end

    @testset "bound: two concurrent control bridges" begin
        PlutoMCP.stop_pluto_stack!(; close_control_bridge=true)
        PlutoMCP.clear_session_binding_ref!()
        runtime_a, binding_a, port_a = bound_runtime_setup(; host_pid = 910001)
        # Second binding in the same process replaces the module binding ref — use raw HTTP servers.
        # Exercise listenany by starting a second owned bridge via a fresh HTTP serve! with JSON health.
        port_b_hint = port_a
        server_b = HTTP.serve!(function (http::HTTP.Stream)
            if http.message.method == "GET" && startswith(http.message.target, "/health")
                HTTP.setstatus(http, 200)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(http, JSON.json(Dict("status"=>"ok","session_id"=>"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","mcp_port"=>0)))
            else
                HTTP.setstatus(http, 404)
                HTTP.startwrite(http)
            end
        end, "127.0.0.1", port_b_hint; stream=true, verbose=false, listenany=true)
        try
            port_b = HTTP.port(server_b)
            @test port_a != port_b
            ha = JSON.parse(String(HTTP.get("http://127.0.0.1:$port_a/health").body))
            hb = JSON.parse(String(HTTP.get("http://127.0.0.1:$port_b/health").body))
            @test ha["session_id"] == binding_a.session_id
            @test hb["session_id"] != ha["session_id"]
        finally
            close(server_b)
            bound_runtime_teardown!()
            rm(runtime_a; recursive=true, force=true)
        end
    end

    @testset "bound: refuses foreign bridge proxy adoption" begin
        PlutoMCP.stop_pluto_stack!(; close_control_bridge=true)
        PlutoMCP.clear_session_binding_ref!()
        runtime, binding, port = bound_runtime_setup()
        foreign_port = port + 50
        foreign = HTTP.serve!(function (http::HTTP.Stream)
            if http.message.method == "GET" && startswith(http.message.target, "/health")
                HTTP.setstatus(http, 200)
                HTTP.startwrite(http)
                write(http, "ok")
            elseif http.message.method == "POST"
                read(http)
                HTTP.setstatus(http, 200)
                HTTP.setheader(http, "Content-Type" => "application/json")
                HTTP.startwrite(http)
                write(http, JSON.json(Dict("jsonrpc"=>"2.0","id"=>1,"result"=>Dict("from"=>"foreign"))))
            else
                HTTP.setstatus(http, 404)
                HTTP.startwrite(http)
            end
        end, "127.0.0.1", Int(foreign_port); stream=true, verbose=false)
        try
            @test PlutoMCP.bridge_running(foreign_port)
            msg = Dict{String,Any}(
                "jsonrpc" => "2.0",
                "id" => 1,
                "method" => "tools/call",
                "params" => Dict{String,Any}(
                    "name" => "pluto_session_status",
                    "arguments" => Dict{String,Any}(),
                ),
            )
            resp = PlutoMCP.dispatch_stdio_message(msg; mcp_port = foreign_port)
            status = JSON.parse(resp["result"]["content"][1]["text"])
            @test status["session_id"] == binding.session_id
            @test !haskey(resp["result"], "from")
        finally
            close(foreign)
            bound_runtime_teardown!()
            rm(runtime; recursive=true, force=true)
        end
    end

    @testset "bound: occupied pluto_port_hint selects free port" begin
        PlutoMCP.stop_pluto_stack!(; close_control_bridge=true)
        PlutoMCP.clear_session_binding_ref!()
        runtime, binding, mcp_port = bound_runtime_setup()
        occupied_hint = 41000 + rand(0:500)
        blocker = Sockets.listen(Sockets.ip"127.0.0.1", occupied_hint)
        try
            PlutoMCP.configure_standalone!(;
                pluto_port_hint = occupied_hint,
                mcp_port_hint = mcp_port,
                require_secret_for_access = false,
            )
            status = PlutoMCP.start_pluto_stack!()
            @test status["pluto"] == "running"
            @test status["pluto_port"] != occupied_hint
            @test status["pluto_url"] == "http://127.0.0.1:$(status["pluto_port"])"
            @test HTTP.get("http://127.0.0.1:$(status["pluto_port"])/ping"; readtimeout=2).status == 200

            stopped = PlutoMCP.tool_stop_pluto_session(Dict{String,Any}())
            @test stopped["pluto"] == "stopped"
            @test stopped["pluto_url"] === nothing
            # Control bridge still alive
            health = JSON.parse(String(HTTP.get("http://127.0.0.1:$mcp_port/health").body))
            @test health["session_id"] == binding.session_id
            @test health["pluto"] == "stopped"
        finally
            close(blocker)
            bound_runtime_teardown!()
            rm(runtime; recursive=true, force=true)
        end
    end

    @testset "bound: optional client_url from sidecar (omit when unset)" begin
        PlutoMCP.stop_pluto_stack!(; close_control_bridge=true)
        PlutoMCP.clear_session_binding_ref!()
        runtime, binding, mcp_port = bound_runtime_setup()
        try
            status = PlutoMCP.start_pluto_stack!()
            @test status["pluto"] == "running"
            @test !haskey(status, "client_url")

            host = status["pluto_url"]
            sidecar = joinpath(dirname(binding.binding_file), "$(binding.cursor_host_pid).client.json")
            open(sidecar, "w") do io
                JSON.print(io, Dict(
                    "schema_version" => 1,
                    "host_url" => host,
                    "client_url" => "http://127.0.0.1:59999/",
                ))
            end
            with_sidecar = PlutoMCP.session_status_dict()
            @test with_sidecar["client_url"] == "http://127.0.0.1:59999/"

            # Stale sidecar (host mismatch) → omit, never invent
            open(sidecar, "w") do io
                JSON.print(io, Dict(
                    "schema_version" => 1,
                    "host_url" => "http://127.0.0.1:1",
                    "client_url" => "http://127.0.0.1:58888/",
                ))
            end
            stale = PlutoMCP.session_status_dict()
            @test !haskey(stale, "client_url")
        finally
            bound_runtime_teardown!()
            rm(runtime; recursive=true, force=true)
        end
    end

    @testset "bound: notebook path lease conflict and stale recovery" begin
        PlutoMCP.stop_pluto_stack!(; close_control_bridge=true)
        PlutoMCP.clear_session_binding_ref!()
        fixture_src = joinpath(@__DIR__, "fixtures", "test_notebook.jl")
        fixture_hash = bytes2hex(open(sha256, fixture_src))
        copy_a = joinpath(mktempdir(), "nb.jl")
        cp(fixture_src, copy_a)

        # Same host runtime_dir — notebook leases are shared across sessions.
        runtime = mktempdir()
        binding_a = PlutoMCP.SessionBinding(;
            runtime_dir = runtime,
            binding_file = joinpath(runtime, "windows", "920001.json"),
            cursor_host_pid = 920001,
        )
        PlutoMCP.configure_session_binding!(binding_a)
        PlutoMCP.claim_window_binding!(binding_a)
        hint = 28000 + rand(0:999)
        PlutoMCP.configure_standalone!(;
            pluto_port_hint = hint + 1000,
            mcp_port_hint = hint,
            require_secret_for_access = false,
        )
        port_a = Int(PlutoMCP.start_control_bridge!(; mcp_port_hint = hint, listenany = true))
        try
            PlutoMCP.start_pluto_stack!()
            opened = PlutoMCP.tool_open_notebook(Dict("path" => copy_a, "run_notebook" => false))
            @test haskey(opened, "notebook_id")

            binding_b = PlutoMCP.SessionBinding(;
                runtime_dir = runtime,
                binding_file = joinpath(runtime, "windows", "920002.json"),
                cursor_host_pid = 920002,
            )
            PlutoMCP.configure_session_binding!(binding_b)
            ha = JSON.parse(String(HTTP.get("http://127.0.0.1:$port_a/health").body))
            @test ha["session_id"] == binding_a.session_id

            err = try
                PlutoMCP.acquire_notebook_lease!(copy_a)
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin("notebook_in_use", sprint(showerror, err))

            # Stop A so its lease becomes stale; B can then acquire.
            PlutoMCP.configure_session_binding!(binding_a)
            PlutoMCP.stop_pluto_stack!(; close_control_bridge = true)
            PlutoMCP.cleanup_session_binding!()

            PlutoMCP.configure_session_binding!(binding_b)
            PlutoMCP.claim_window_binding!(binding_b)
            binding_b.mcp_port = 1
            lease = PlutoMCP.acquire_notebook_lease!(copy_a)
            @test lease.canonical_path == realpath(copy_a)
            PlutoMCP._release_lease_dir_if_ours!(binding_b, lease.lease_dir)
            PlutoMCP.cleanup_session_binding!()
        finally
            bound_runtime_teardown!()
            rm(runtime; recursive=true, force=true)
            rm(dirname(copy_a); recursive=true, force=true)
            @test bytes2hex(open(sha256, fixture_src)) == fixture_hash
        end
    end

    @testset "bound: same-session duplicate open keeps Pluto behavior" begin
        PlutoMCP.stop_pluto_stack!(; close_control_bridge=true)
        PlutoMCP.clear_session_binding_ref!()
        fixture_src = joinpath(@__DIR__, "fixtures", "test_notebook.jl")
        copy_path = joinpath(mktempdir(), "dup.jl")
        cp(fixture_src, copy_path)
        runtime, _, _ = bound_runtime_setup()
        try
            PlutoMCP.start_pluto_stack!()
            first = PlutoMCP.tool_open_notebook(Dict("path" => copy_path, "run_notebook" => false))
            @test haskey(first, "notebook_id")
            @test_throws Pluto.SessionActions.NotebookIsRunningException begin
                PlutoMCP.tool_open_notebook(Dict("path" => copy_path, "run_notebook" => false))
            end
        finally
            bound_runtime_teardown!()
            rm(runtime; recursive=true, force=true)
            rm(dirname(copy_path); recursive=true, force=true)
        end
    end

    @testset "bound: binding cleanup removes window files" begin
        PlutoMCP.stop_pluto_stack!(; close_control_bridge=true)
        PlutoMCP.clear_session_binding_ref!()
        runtime, binding, port = bound_runtime_setup()
        @test isfile(binding.binding_file)
        @test isdir(binding.claim_dir)
        bound_runtime_teardown!()
        @test !isfile(binding.binding_file)
        @test !isdir(binding.claim_dir)
        @test_throws Exception HTTP.get("http://127.0.0.1:$port/health"; readtimeout=1, connect_timeout=1)
        rm(runtime; recursive=true, force=true)
    end

end
