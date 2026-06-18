using PlutoMCP
using Pluto
using Test
using UUIDs
using JSON3

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
            "notebook_id" => string(nb.notebook_id),
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
            "notebook_id" => string(nb.notebook_id),
            "cell_ids"    => [string(cells[2].cell_id)],
            "force"       => true,
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
        write(buf, PlutoMCP.JSON3.write(msg))
        write(buf, '\n')
    end

    # Helper: read one newline-delimited JSON response from a buffer
    function read_resp(buf)
        seekstart(buf)
        PlutoMCP.JSON3.read(readline(buf; keep=false), Dict{String,Any})
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
        data = PlutoMCP.JSON3.read(resp["result"]["content"][1]["text"])
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

            result_y2 = PlutoMCP.tool_read_cell(session,
                Dict("notebook_id" => string(nb.notebook_id), "cell_id" => cell_y_id))
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
            "notebook_id" => string(nb.notebook_id),
            "cell_id"     => string(cells[1].cell_id),
        ))
        @test receipt["applied"] == true
        @test receipt["execution"]["status"] == "completed"
        @test string(cells[1].cell_id) ∈ receipt["affected_cells"]
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
            e1 = JSON3.read(lines[1], Dict{String,Any})
            e2 = JSON3.read(lines[2], Dict{String,Any})
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

    @testset "EvalShared score_trace" begin
        include(joinpath(dirname(@__DIR__), "eval", "lib", "EvalShared.jl"))
        entries = [
            Dict{String,Any}("tool" => "edit_cell", "args" => Dict("run_after" => true)),
        ]
        bad = score_trace(entries, Dict("max_run_after" => 0))
        @test bad["pass"] == false
        @test any(occursin("run_after", d) for d in bad["diagnostics"])

        ok = score_trace(
            [Dict{String,Any}("tool" => "read_cell", "args" => Dict("cell_id" => "a"))],
            Dict("read_before_first_edit" => true, "must_include_subsequence" => ["read_cell"]),
        )
        @test ok["pass"] == true

        err = score_trace(
            [Dict{String,Any}("tool" => "edit_cell", "args" => Dict("cell_id" => "a"), "is_error" => true, "error_type" => "syntax")],
            Dict("expect_read_required_error" => true),
        )
        @test err["pass"] == false
    end

    @testset "eval reference runner" begin
        runner = joinpath(dirname(@__DIR__), "eval", "run_reference.jl")
        proj = dirname(@__DIR__)
        @test isfile(runner)
        # Fresh Julia subprocess avoids precompile races with Pluto already loaded here.
        sleep(2)
        julia = joinpath(Sys.BINDIR, Base.julia_exename())
        stderr_io = IOBuffer()
        cmd = setenv(
            `$julia --project=$proj --startup-file=no $runner --all --strict-trace`,
            "JULIA_PRECOMPILE" => "0",
        )
        proc = run(pipeline(ignorestatus(cmd), stderr=stderr_io), wait=true)
        if proc.exitcode != 0
            @warn "eval reference runner failed" exitcode=proc.exitcode stderr=String(take!(stderr_io))
        end
        @test proc.exitcode == 0
    end

end
