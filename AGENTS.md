## Learned User Preferences

- One canonical MCP tool name per operation; avoid near-duplicate aliases (they confuse agents more than unfamiliar names).
- MCP cell tools: `read_cell`, `edit_cell`, `execute_cell` — not parallel `get_cell`/`set_cell_code`/`run_cell` registrations.
- Stage-first editing: `run_after=false` default on `edit_cell`/`add_cell`; batch run via `submit_changes` (Pluto Cmd+S semantics).
- Server-side dirty tracking (`pending_run`, `stale_cell_ids`); do not rely on curated instructions alone.
- Read-before-edit enforced in MCP tools (`edit_cell`/`add_cell`), not agent rules alone — reject or require fresh read receipt.
- `read_notebook_code`: execution/dependency order; include empty cells; returns `code`, `cell_ids`, `stale_cell_ids`/`pending_run` (not `cells[]`).
- `resolve_pluto_context` maps Design Mode `dom_path`, Glass URL, or `browser_element` block → `notebook_id` + `cell_id`.
- Remove `get_notebook_state` from the agent-facing MCP surface.
- Omit markdown, manifest blobs, and `@bind` scaffolding from default `read_notebook_code` projection.
- Ground Pluto projection rules on real notebook artifacts in a gitignored `reference/` directory.
- Pluto cell grammar: single-expression cells; `@bind` last in cell; default `begin`/`end` for `pluto_multi_expression` (Styx `docs/pluto-agent-primer.md`).
- **Commit hygiene:** commit at logical boundaries as you go — modules → wiring → tests → docs when possible; split unrelated work (e.g. eval harness vs Phase 2 graph tools). Ask before pushing.

## Learned Workspace Facts

- Extend **jowch/PlutoMCP.jl** in-process; hold upstream PRs until existing upstream PRs are addressed; ship on fork `main` first; keep fork diffs minimal — core staging/read guards/receipts are upstream-worthy.
- Agents mutate live `Pluto.Notebook` via MCP; Pluto owns persistence, reactivity, and browser sync.
- Primary identity primitive: `notebook_id` plus `cell_id` (matches `<pluto-cell id="...">` in the browser).
- MCP writes server notebook state directly; the browser editor has a separate draft buffer (last-write-wins on server).
- Visual cell order matters for `add_cell`/`move_cell` placement; execution order for code reasoning in `read_notebook_code`.
- Structural MCP edits (`add_cell`, `delete_cell`, `move_cell`) must assign a new `cell_order` vector before `_notify_browser` — in-place mutation skips `cell_order` WebSocket patches (see Styx `docs/known-issues/plutomcp-cell-order-sync.md`).
- `serve()` starts full Pluto frontend (HTTP + MCP), not headless; `serve()` / standalone `connect()` forward `require_secret_for_access` to Pluto `Options` (default `true`); plugin uses `false` on loopback.
- **D15 lifecycle:** `pluto_session_status`, `start_pluto_session`, `stop_pluto_session`, `open_notebook`, **`allow_execution`** implemented; deferred standalone `connect()` (no lazy-start on first tool); `start_pluto_session` starts Pluto + HTTP bridge on `:2346`; `stop_pluto_stack!` tears down `:1234`/`:2346` listeners; lifecycle tools on HTTP bridge — not always exposed in Cursor stdio MCP tool picker.
- **Safe preview:** `open_notebook` default → **remind** user outputs/widgets won't update until **Run notebook code** in Glass (not a hard edit gate); if user asks to run, use **`allow_execution`** or direct to Glass; **`allow_execution`** on risky remote sources still requires Glass UI.
- Cursor **Styx** plugin spawns deferred `connect()` via `mcp.json` launcher (D15); proxy mode when `:2346/health` already up; **`scripts/pluto-serve.sh` dev-only**.
- **CI.yml** push trigger is **`main`** (was `master` — tests were not running on push).
- Deterministic eval gate lives in [Styx `eval/`](https://github.com/jowch/styx/tree/main/eval) (`run_reference.jl --all`); PlutoMCP keeps optional `EvalLog.jl` hook only.
