## Learned User Preferences

- One canonical MCP tool name per operation; avoid near-duplicate aliases (they confuse agents more than unfamiliar names).
- MCP cell tools: `read_cell`, `edit_cell`, `execute_cell` — not parallel `get_cell`/`set_cell_code`/`run_cell` registrations.
- Stage-first editing: `run_after=false` default on `edit_cell`/`add_cell`; batch run via `submit_changes` (Pluto Cmd+S semantics).
- Server-side dirty tracking (`pending_run`, `stale_cell_ids`); do not rely on curated instructions alone.
- Read-before-edit enforced in MCP tools (`edit_cell`/`add_cell`), not agent rules alone — reject or require fresh read receipt.
- `read_notebook_code` defaults to execution/dependency order, not visual cell order.
- Include empty code cells in `read_notebook_code` projection.
- `read_notebook_code` returns `code` plus `cell_ids` and `stale_cell_ids`/`pending_run`; not a duplicate `cells[]` array.
- Remove `get_notebook_state` from the agent-facing MCP surface.
- Omit markdown, manifest blobs, and `@bind` scaffolding from default `read_notebook_code` projection.
- Ground Pluto projection rules on real notebook artifacts in a gitignored `reference/` directory.
- `@bind` must be last expression in cell (widget in output); show bound value in a separate cell.
- **Commit hygiene:** commit at logical boundaries as you go — modules → wiring → tests → docs when possible; split unrelated work (e.g. eval harness vs Phase 2 graph tools). Ask before pushing.

## Learned Workspace Facts

- Extend this fork (jowch/PlutoMCP.jl) in-process; not a greenfield MCP server.
- Agents mutate live `Pluto.Notebook` via MCP; Pluto owns persistence, reactivity, and browser sync.
- Primary identity primitive: `notebook_id` plus `cell_id` (matches `<pluto-cell id="...">` in the browser).
- MCP writes server notebook state directly; the browser editor has a separate draft buffer (last-write-wins on server).
- Visual cell order matters for `add_cell`/`move_cell` placement; execution order for code reasoning in `read_notebook_code`.
- Structural MCP edits (`add_cell`, `delete_cell`, `move_cell`) must assign a new `cell_order` vector before `_notify_browser` — in-place mutation skips `cell_order` WebSocket patches (see pluto-cursor-bridge `docs/known-issues/plutomcp-cell-order-sync.md`).
- `serve()` starts full Pluto frontend (HTTP + MCP); not headless.
- `serve()` / standalone `connect()` forward `require_secret_for_access` to Pluto `Options` (default `true`); plugin uses `false` on loopback.
- Cursor plugin spawns bridge via `mcp.json` launcher → `connect()` proxy (D12).
- Layer 2 graph/validation MCP tools ship here after Phase 1 validates.
