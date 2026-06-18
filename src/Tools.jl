const TOOL_TIMEOUT_SECONDS = 60.0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function _get_notebook(session, notebook_id_str)
    nid = try
        UUID(notebook_id_str)
    catch
        throw(ArgumentError("invalid_notebook_id::Invalid notebook ID: '$notebook_id_str'"))
    end
    nb = get(session.notebooks, nid, nothing)
    nb === nothing && throw(KeyError("notebook_not_found::No notebook with id '$notebook_id_str' in the current session"))
    return nb
end

function _get_cell(notebook, cell_id_str)
    cid = try
        UUID(cell_id_str)
    catch
        throw(ArgumentError("invalid_cell_id::Invalid cell ID: '$cell_id_str'"))
    end
    cell = get(notebook.cells_dict, cid, nothing)
    cell === nothing && throw(KeyError("cell_not_found::No cell with id '$cell_id_str' in notebook"))
    return cell
end

function _serialize_output(cell)
    if cell.errored
        body = cell.output.body
        body === nothing && return ""
        body isa String && return body
        body isa Dict && return get(body, "msg", sprint(show, body))
        return sprint(show, body)
    end
    body = cell.output.body
    body === nothing && return ""
    mime = cell.output.mime
    if mime == MIME("text/plain") && body isa String
        return body
    elseif body isa String
        return "[$(string(mime)) output, $(sizeof(body)) bytes]"
    elseif body isa Vector{UInt8}
        return "[$(string(mime)) output, $(length(body)) bytes]"
    else
        return "[$(string(mime)) output]"
    end
end

function _cell_to_dict(cell; notebook_id=nothing)
    d = Dict{String,Any}(
        "cell_id" => string(cell.cell_id),
        "code"    => cell.code,
        "output"  => _serialize_output(cell),
        "errored" => cell.errored,
        "running" => cell.running,
        "queued"  => cell.queued,
    )
    if notebook_id !== nothing
        d["stale"] = is_stale(notebook_id, cell.cell_id)
    end
    return d
end

function _wait_for_cell(cell; timeout=TOOL_TIMEOUT_SECONDS)
    t = time()
    while cell.running || cell.queued
        time() - t > timeout && return false
        sleep(0.05)
    end
    return true
end

function _notify_browser(session, notebook)
    try
        Pluto.send_notebook_changes!(Pluto.ClientRequest(; session, notebook))
    catch
        # Best-effort: no connected clients is fine
    end
end

# Assign a new cell_order vector instead of mutating in place. Pluto's Firebasey
# diff caches cell_order by reference; in-place push!/insert!/deleteat! updates
# the cached snapshot too, so no cell_order patch reaches connected browsers.
function _set_cell_order!(notebook, new_order::Vector{UUID})
    notebook.cell_order = new_order
    return notebook
end

function _insert_cell_after!(notebook, after_id::UUID, new_id::UUID)
    target_idx = findfirst(==(after_id), notebook.cell_order)
    target_idx === nothing &&
        throw(KeyError("cell_not_found::Cell '$after_id' not found in notebook"))
    _set_cell_order!(notebook, [
        notebook.cell_order[1:target_idx]...,
        new_id,
        notebook.cell_order[target_idx+1:end]...,
    ])
end

function _append_cell!(notebook, new_id::UUID)
    _set_cell_order!(notebook, [notebook.cell_order..., new_id])
end

function _remove_cell_from_order!(notebook, cell_id::UUID)
    _set_cell_order!(notebook, filter(!=(cell_id), notebook.cell_order))
end

function _move_cell_in_order!(notebook, cell_id::UUID, after_cell_id)
    order = collect(notebook.cell_order)
    old_idx = findfirst(==(cell_id), order)
    old_idx === nothing && throw(KeyError("cell_not_found::Cell not found in cell_order"))
    deleteat!(order, old_idx)

    if after_cell_id == ""
        insert!(order, 1, cell_id)
    else
        target_id = try
            UUID(after_cell_id)
        catch
            throw(ArgumentError("invalid_cell_id::Invalid cell ID: '$after_cell_id'"))
        end
        new_idx = findfirst(==(target_id), order)
        new_idx === nothing &&
            throw(KeyError("cell_not_found::Target cell '$after_cell_id' not found"))
        insert!(order, new_idx + 1, cell_id)
    end

    _set_cell_order!(notebook, order)
end

function _stage_cell!(session, nb, cell)
    mark_pending!(nb.notebook_id, cell.cell_id)
    nb.topology = Pluto.updated_topology(nb.topology, nb, [cell])
    Pluto.save_notebook(session, nb)
    _notify_browser(session, nb)
end

function _run_cells!(session, nb, cells; wait_for_completion=true)
    Pluto.update_save_run!(session, nb, cells; run_async=!wait_for_completion, save=true)
    if wait_for_completion
        for cell in cells
            _wait_for_cell(cell; timeout=TOOL_TIMEOUT_SECONDS)
        end
    end
    clear_pending!(nb.notebook_id, [c.cell_id for c in cells])
    _notify_browser(session, nb)
end

# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------

function tool_list_notebooks(session, _args)
    [
        Dict{String,Any}(
            "notebook_id" => string(nb.notebook_id),
            "path"        => nb.path,
            "cell_count"  => length(nb.cell_order),
        )
        for nb in values(session.notebooks)
    ]
end

function tool_read_cell(session, args)
    nb   = _get_notebook(session, args["notebook_id"])
    cell = _get_cell(nb, args["cell_id"])
    record_read!(nb.notebook_id, cell.cell_id, cell.code)
    _cell_to_dict(cell; notebook_id=nb.notebook_id)
end

function tool_edit_cell(session, args)
    nb        = _get_notebook(session, args["notebook_id"])
    cell      = _get_cell(nb, args["cell_id"])
    code      = args["code"]
    run_after = get(args, "run_after", false)

    require_fresh_read!(nb.notebook_id, cell)

    cell.code = code
    record_read!(nb.notebook_id, cell.cell_id, code)

    if run_after
        _run_cells!(session, nb, [cell]; wait_for_completion=true)
    else
        _stage_cell!(session, nb, cell)
    end

    receipt = _mutation_receipt(session, nb;
        applied=true,
        mutation=Dict{String,Any}("type" => "edit_cell", "cell_id" => string(cell.cell_id)),
        cell_ids_run=run_after ? [cell.cell_id] : UUID[],
    )
    merge!(receipt, _cell_to_dict(cell; notebook_id=nb.notebook_id))
    return receipt
end

function tool_edit_cells(session, args)
    nb    = _get_notebook(session, args["notebook_id"])
    edits = args["cells"]

    edited_ids = UUID[]
    for edit in edits
        cell = _get_cell(nb, edit["cell_id"])
        require_fresh_read!(nb.notebook_id, cell)
        cell.code = edit["code"]
        record_read!(nb.notebook_id, cell.cell_id, edit["code"])
        _stage_cell!(session, nb, cell)
        push!(edited_ids, cell.cell_id)
    end

    return _mutation_receipt(session, nb;
        applied=true,
        mutation=Dict{String,Any}(
            "type"     => "edit_cells",
            "cell_ids" => [string(id) for id in edited_ids],
        ),
        cell_ids_run=UUID[],
    )
end

function tool_add_cell(session, args)
    nb            = _get_notebook(session, args["notebook_id"])
    code          = get(args, "code", "")
    after_cell_id = get(args, "after_cell_id", nothing)
    run_after     = get(args, "run_after", false)

    if !isempty(nb.cell_order) && (after_cell_id === nothing || after_cell_id == "")
        throw(ArgumentError(
            "placement_required::after_cell_id is required when the notebook is not empty"
        ))
    end

    if !isempty(nb.cell_order)
        anchor = _get_cell(nb, after_cell_id)
        require_fresh_read!(nb.notebook_id, anchor)
    end

    new_cell = Pluto.Cell(; code=string(code))
    nb.cells_dict[new_cell.cell_id] = new_cell

    if after_cell_id === nothing || after_cell_id == ""
        _append_cell!(nb, new_cell.cell_id)
    else
        target_id = try
            UUID(after_cell_id)
        catch
            throw(ArgumentError("invalid_cell_id::Invalid cell ID: '$after_cell_id'"))
        end
        _insert_cell_after!(nb, target_id, new_cell.cell_id)
    end

    if run_after
        _run_cells!(session, nb, [new_cell]; wait_for_completion=true)
    else
        _stage_cell!(session, nb, new_cell)
    end

    receipt = _mutation_receipt(session, nb;
        applied=true,
        mutation=Dict{String,Any}("type" => "add_cell", "cell_id" => string(new_cell.cell_id)),
        cell_ids_run=run_after ? [new_cell.cell_id] : UUID[],
    )
    merge!(receipt, _cell_to_dict(new_cell; notebook_id=nb.notebook_id))
    return receipt
end

function tool_delete_cell(session, args)
    nb   = _get_notebook(session, args["notebook_id"])
    cell = _get_cell(nb, args["cell_id"])

    cell_id_str = string(cell.cell_id)

    _remove_cell_from_order!(nb, cell.cell_id)
    delete!(nb.cells_dict, cell.cell_id)
    clear_pending!(nb.notebook_id, [cell.cell_id])
    clear_read_receipt!(nb.notebook_id, cell.cell_id)

    # Passing no cells lets run_reactive detect the removed cell and clean up
    Pluto.update_save_run!(session, nb, Pluto.Cell[]; run_async=false, save=true)
    _notify_browser(session, nb)

    return _mutation_receipt(session, nb;
        applied=true,
        mutation=Dict{String,Any}("type" => "delete_cell", "cell_id" => cell_id_str),
        cell_ids_run=UUID[],
    )
end

function tool_execute_cell(session, args)
    nb       = _get_notebook(session, args["notebook_id"])
    cell     = _get_cell(nb, args["cell_id"])
    wait_for = get(args, "wait_for_completion", true)

    _run_cells!(session, nb, [cell]; wait_for_completion=wait_for)

    return _mutation_receipt(session, nb;
        applied=true,
        mutation=Dict{String,Any}("type" => "execute_cell", "cell_id" => string(cell.cell_id)),
        cell_ids_run=[cell.cell_id],
    )
end

function tool_submit_changes(session, args)
    nb       = _get_notebook(session, args["notebook_id"])
    wait_for = get(args, "wait_for_completion", true)

    target_ids = if haskey(args, "cell_ids")
        [try
            UUID(cid)
        catch
            throw(ArgumentError("invalid_cell_id::Invalid cell ID: '$cid'"))
        end for cid in args["cell_ids"]]
    else
        pending_run_ids(nb.notebook_id)
    end

    if isempty(target_ids)
        return _mutation_receipt(session, nb;
            applied=true,
            mutation=Dict{String,Any}("type" => "submit_changes"),
            cell_ids_run=UUID[],
        )
    end

    cells = [_get_cell(nb, string(cid)) for cid in target_ids]
    _run_cells!(session, nb, cells; wait_for_completion=wait_for)

    return _mutation_receipt(session, nb;
        applied=true,
        mutation=Dict{String,Any}("type" => "submit_changes"),
        cell_ids_run=target_ids,
    )
end

function tool_run_all_cells(session, args)
    nb       = _get_notebook(session, args["notebook_id"])
    wait_for = get(args, "wait_for_completion", false)

    Pluto.update_save_run!(session, nb, nb.cells; run_async=!wait_for, save=true)
    _notify_browser(session, nb)

    Dict{String,Any}(
        "notebook_id" => string(nb.notebook_id),
        "status"      => wait_for ? "completed" : "queued",
    )
end

function tool_move_cell(session, args)
    nb            = _get_notebook(session, args["notebook_id"])
    cell          = _get_cell(nb, args["cell_id"])
    after_cell_id = args["after_cell_id"]

    old_idx = findfirst(==(cell.cell_id), nb.cell_order)
    _move_cell_in_order!(nb, cell.cell_id, after_cell_id)
    new_idx = findfirst(==(cell.cell_id), nb.cell_order)

    Pluto.save_notebook(session, nb)
    _notify_browser(session, nb)

    return _mutation_receipt(session, nb;
        applied=true,
        mutation=Dict{String,Any}(
            "type"      => "move_cell",
            "cell_id"   => string(cell.cell_id),
            "old_index" => old_idx,
            "new_index" => new_idx,
        ),
        cell_ids_run=UUID[],
    )
end

# ---------------------------------------------------------------------------
# Dispatch table
# ---------------------------------------------------------------------------

function call_tool(session, name, arguments)
    if name == "list_notebooks"
        tool_list_notebooks(session, arguments)
    elseif name == "read_cell"
        tool_read_cell(session, arguments)
    elseif name == "edit_cell"
        tool_edit_cell(session, arguments)
    elseif name == "edit_cells"
        tool_edit_cells(session, arguments)
    elseif name == "add_cell"
        tool_add_cell(session, arguments)
    elseif name == "delete_cell"
        tool_delete_cell(session, arguments)
    elseif name == "execute_cell"
        tool_execute_cell(session, arguments)
    elseif name == "submit_changes"
        tool_submit_changes(session, arguments)
    elseif name == "run_all_cells"
        tool_run_all_cells(session, arguments)
    elseif name == "move_cell"
        tool_move_cell(session, arguments)
    elseif name == "read_notebook_code"
        tool_read_notebook_code(session, arguments)
    elseif name == "get_cell_order"
        tool_get_cell_order(session, arguments)
    elseif name == "get_execution_order"
        tool_get_execution_order(session, arguments)
    elseif name == "get_cell_dependencies"
        tool_get_cell_dependencies(session, arguments)
    elseif name == "get_cell_dependents"
        tool_get_cell_dependents(session, arguments)
    elseif name == "find_symbol_definitions"
        tool_find_symbol_definitions(session, arguments)
    elseif name == "find_symbol_references"
        tool_find_symbol_references(session, arguments)
    elseif name == "validate_cell"
        tool_validate_cell(session, arguments)
    elseif name == "search_code"
        tool_search_code(session, arguments)
    else
        throw(ArgumentError("unknown_tool::Unknown tool: '$name'"))
    end
end
