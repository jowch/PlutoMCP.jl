# Per-session staging state: cells edited but not yet executed via submit_changes.

const _pending_run = Dict{UUID, Set{UUID}}()

# Read-before-edit receipts: code snapshot at last read_cell / read_notebook_code.
const _read_receipts = Dict{UUID, Dict{UUID, String}}()

function _pending_for(notebook_id::UUID)
    get!(_pending_run, notebook_id) do
        Set{UUID}()
    end
end

function mark_pending!(notebook_id::UUID, cell_id::UUID)
    push!(_pending_for(notebook_id), cell_id)
    return nothing
end

function clear_pending!(notebook_id::UUID, cell_ids)
    pending = get(_pending_run, notebook_id, nothing)
    pending === nothing && return nothing
    for cid in cell_ids
        delete!(pending, cid)
    end
    isempty(pending) && delete!(_pending_run, notebook_id)
    return nothing
end

function pending_run_ids(notebook_id::UUID)
    pending = get(_pending_run, notebook_id, nothing)
    pending === nothing && return UUID[]
    return collect(pending)
end

function is_stale(notebook_id::UUID, cell_id::UUID)
    pending = get(_pending_run, notebook_id, nothing)
    pending === nothing && return false
    return cell_id in pending
end

function _read_receipts_for(notebook_id::UUID)
    get!(_read_receipts, notebook_id) do
        Dict{UUID, String}()
    end
end

function record_read!(notebook_id::UUID, cell_id::UUID, code::String)
    _read_receipts_for(notebook_id)[cell_id] = code
    return nothing
end

function clear_read_receipt!(notebook_id::UUID, cell_id::UUID)
    receipts = get(_read_receipts, notebook_id, nothing)
    receipts === nothing && return nothing
    delete!(receipts, cell_id)
    isempty(receipts) && delete!(_read_receipts, notebook_id)
    return nothing
end

function require_fresh_read!(notebook_id::UUID, cell::Pluto.Cell)
    receipts = get(_read_receipts, notebook_id, nothing)
    if receipts === nothing || !haskey(receipts, cell.cell_id)
        throw(ArgumentError(
            "read_required::Call read_cell or read_notebook_code before editing cell $(cell.cell_id)"
        ))
    end
    if receipts[cell.cell_id] != cell.code
        throw(ArgumentError(
            "stale_read::Cell $(cell.cell_id) changed since last read; call read_cell again"
        ))
    end
    return nothing
end

function _receipt_output_summary(cell)
    _serialize_output(cell)
end

function _execution_status(nb, cell_ids_run)
    isempty(cell_ids_run) && return "completed"
    any_errored = false
    any_running = false
    for cid in cell_ids_run
        cell = get(nb.cells_dict, cid, nothing)
        cell === nothing && continue
        cell.errored && (any_errored = true)
        (cell.running || cell.queued) && (any_running = true)
    end
    any_errored && return "errored"
    any_running && return "running"
    return "completed"
end

function _mutation_receipt(session, nb; applied, mutation, cell_ids_run=UUID[], warnings=String[])
    outputs_changed = Dict{String,Any}[]
    for cid in cell_ids_run
        cell = get(nb.cells_dict, cid, nothing)
        cell === nothing && continue
        summary = _receipt_output_summary(cell)
        isempty(summary) && continue
        entry = Dict{String,Any}(
            "cell_id"        => string(cid),
            "output_summary" => summary,
        )
        err = _cell_output_error(cell)
        err !== nothing && (entry["error"] = err)
        push!(outputs_changed, entry)
    end

    Dict{String,Any}(
        "applied"          => applied,
        "mutation"         => mutation,
        "cell_order"       => [string(id) for id in nb.cell_order],
        "execution_order"  => [string(c.cell_id) for c in collect(Pluto.topological_order(nb))],
        "affected_cells"   => [string(id) for id in cell_ids_run],
        "execution"        => Dict{String,Any}("status" => _execution_status(nb, cell_ids_run)),
        "outputs"          => Dict{String,Any}("changed" => outputs_changed),
        "pending_run"      => [string(id) for id in pending_run_ids(nb.notebook_id)],
        "warnings"         => warnings,
    )
end

function _compact_receipt(session, nb; applied, mutation, cell_ids_run=UUID[], warnings=String[])
    _mutation_receipt(session, nb; applied, mutation, cell_ids_run, warnings)
end
