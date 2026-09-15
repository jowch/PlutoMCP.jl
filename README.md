# PlutoMCP.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://mthelm85.github.io/PlutoMCP.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://mthelm85.github.io/PlutoMCP.jl/dev/)
[![Build Status](https://github.com/mthelm85/PlutoMCP.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/mthelm85/PlutoMCP.jl/actions/workflows/CI.yml?query=branch%3Amain)

**PlutoMCP.jl** exposes a [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server that lets MCP-compatible AI tools — Claude Desktop, Cursor, and others — inspect and manipulate live [Pluto.jl](https://plutojl.org) notebooks in real time.

```
You (terminal)            AI Tool (Claude Desktop, …)
      │                             │
      │ PlutoMCP.serve()            │  stdio → proxies only in legacy unbound mode
      ▼                             ▼
PlutoMCP bridge  ◄────────── connect() (legacy) may proxy to :2346
      │                   OR Styx bound connect() owns its own bridge
      │  direct Julia API calls
      ▼
Pluto.ServerSession / Pluto.Notebook  (port 1234, or dynamic in bound mode)
      │
      │  WebSocket push
      ▼
Browser  (live view — notebooks you open here are visible to AI tools)
```

You start the bridge once when you want Claude to have access. It starts a fresh Pluto session; open notebooks through the Pluto browser UI that `serve()` prints. Claude Desktop configured with legacy `connect()` (stdio) **automatically detects the running bridge** and proxies through it — no reconfiguration needed.

**Styx / bound mode:** embedding clients pass `binding_file`, `runtime_dir`, and `cursor_host_pid` to `connect()`. Bound mode binds a loopback control bridge immediately, publishes a JSON `/health` with a session nonce, never proxies to a foreign bridge, allocates ports with `listenany`, and leases canonical notebook paths so two bound sessions cannot open the same file.

---

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/mthelm85/PlutoMCP.jl")
```

---

## Quick start

### Step 1 — Start the bridge (whenever you want Claude access)

```julia
using PlutoMCP

PlutoMCP.serve()                              # Pluto on :1234, MCP bridge on :2346
PlutoMCP.serve(pluto_port=4321)              # custom Pluto port
PlutoMCP.serve(notebook="my_nb.jl")         # open a notebook on start
PlutoMCP.serve(pluto_port=1234, mcp_port=3000)  # custom MCP port
PlutoMCP.serve(notebook="my_nb.jl", eval_log="/tmp/trace.jsonl")  # agent eval logging
```

`serve()` starts Pluto in the background and blocks, running the MCP HTTP/SSE server. Open the printed Pluto URL in your browser as usual. **Any notebooks you open in the browser are immediately visible to Claude.**

> **`require_secret_for_access`:** forwarded to Pluto `Options` (default `true`). Pass `false` to open
> `http://localhost:PORT/` without a `?secret=` URL — useful for MCP clients that cannot navigate to a
> secret URL, or over a trusted SSH port-forward.
>
> :warning: **The secret is Pluto's only access control.** With `require_secret_for_access=false`, anything
> that can reach the port can execute arbitrary Julia code as you — including other users of a shared
> machine. Only turn it off on a single-user machine or a trusted port-forward.

> **Important**: open your notebooks through the Pluto UI started by `serve()`, not through a separately-started `Pluto.run()`. The MCP bridge owns its own Pluto session; notebooks from other Pluto processes are not shared.

### Step 2 — Configure your MCP client (one-time)

#### Claude Desktop — stdio

`claude_desktop_config.json` supports **stdio servers only** (`command` / `args` / `env`).
It has no `url` field, so this is the way to wire up Claude Desktop:

```json
{
  "mcpServers": {
    "pluto": {
      "command": "julia",
      "args": ["-e", "using PlutoMCP; PlutoMCP.connect()"]
    }
  }
}
```

`connect()` in **legacy unbound** mode checks `GET /health` on `:2346` **on each tool call** (not only at process start):

- **Bridge running** (e.g. `serve()`, including one started later on a Remote SSH host):
  proxies tool calls through the bridge so clients see that Pluto session.
- **This process already started Pluto:** uses the in-process session (does not proxy).
- **No bridge (D15 deferred mode):** MCP stdio stays up; call `start_pluto_session` before notebook
  tools. Pluto and the HTTP bridge start together on demand.

**Bound mode** (Styx): never proxies. The control bridge is owned by this process; `/health` returns JSON including `session_id`, and `/call` requires `X-Styx-Session-ID`.

In both cases the MCP client starts up without waiting for Pluto. The stdio process still loads
Julia/PlutoMCP (~13 s / ~800 MB resident while idle). If that bothers you, use the `mcp-remote`
setup below and start the bridge only when you want it.

#### Claude Desktop — HTTP via `mcp-remote`

Claude Desktop cannot talk to `http://localhost:2346/sse` directly. Its config file is stdio-only,
and custom connectors (Settings → Connectors) reach the server from Anthropic's cloud, so they
require a public HTTPS endpoint — a localhost address is unreachable that way.

To use the HTTP bridge, bridge stdio to it with [`mcp-remote`](https://www.npmjs.com/package/mcp-remote):

```json
{
  "mcpServers": {
    "pluto": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://localhost:2346/sse"]
    }
  }
}
```

This spawns a small Node process (~38 MB) instead of a Julia one, and starts no Pluto session of
its own — all tool calls go to the `serve()` bridge. If the bridge is not running, the server
fails to connect and its tools are simply unavailable until you start it.

#### Claude Code — HTTP (native)

Claude Code speaks HTTP/SSE directly, so it needs **no local process at all**:

```bash
claude mcp add --transport sse pluto http://localhost:2346/sse
```

Nothing runs when the bridge is down; Claude Code reports the server as failed to connect and
everything else keeps working. Start `serve()` and the tools appear.

#### Cursor — HTTP

```json
{
  "mcpServers": {
    "pluto": {
      "url": "http://localhost:2346/sse"
    }
  }
}
```

---

## Available MCP tools

### Session lifecycle (D15)

| Tool | Description |
|---|---|
| `pluto_session_status` | Whether Pluto is running; open notebooks; ports |
| `start_pluto_session` | Start Pluto + MCP HTTP bridge on demand (idempotent) |
| `stop_pluto_session` | Shut down notebooks and clear session state |
| `open_notebook` | Load a `.jl` file server-side; safe preview by default (`run_notebook=false`) |
| `allow_execution` | Exit safe preview on an open notebook (Glass **Run notebook code** equivalent); optional `run_notebook` (default true, non-blocking; false exits gate without a full run) |

### Notebook read/write

| Tool | Description |
|---|---|
| `list_notebooks` | List all notebooks open in the session |
| `read_notebook_code` | Whole notebook as execution-order code projection |
| `read_cell` | Code, output, and stale flag of a single cell |
| `edit_cell` | Replace a cell's code; stages by default (`run_after=false`) |
| `edit_cells` | Batch stage `{cell_id, code}[]`; never runs |
| `add_cell` | Insert a new cell (`after_cell_id` required when notebook is non-empty) |
| `delete_cell` | Delete a cell (async reactive cleanup; non-blocking on MCP) |
| `submit_changes` | Run all staged cells (Cmd+S semantics) |
| `execute_cell` | Run one cell (Shift+Enter) |
| `run_all_cells` | Re-run all cells in dependency order |
| `move_cell` | Reorder a cell relative to another |
| `fold_cell` | Hide or show a cell's code (Pluto fold); output stays visible |
| `get_cell_order` | Visual cell order |
| `get_execution_order` | Dependency / execution order |

**Phase 2 — graph & validation (debugging, not default workflow):**

| Tool | Description |
|---|---|
| `get_cell_dependencies` | Upstream cells and referenced symbols for a cell |
| `get_cell_dependents` | Transitive downstream cells that would re-run on change |
| `find_symbol_definitions` | Cells where a symbol is defined (semantic) |
| `find_symbol_references` | Cells that reference a symbol (semantic) |
| `validate_cell` | Parse + single-expression check on proposed code |
| `search_code` | Plain-text search across cell codes |

Write tools return a **mutation receipt** with `applied`, `mutation`, `cell_order`, `execution_order`, `affected_cells`, `execution.status`, `outputs.changed`, `pending_run`, and `warnings`.

`execution.status` is one of `staged` (nothing ran), `running`, `completed`, `errored`, `timeout`, or `blocked`. `blocked` means the notebook is not running code (safe preview / no process): nothing ran, `pending_run` is kept, `outputs.changed` is empty, and `warnings` carries `execution_blocked::` with the remedy (`allow_execution` in safe preview).

### Tool details

#### `list_notebooks`

No inputs. Returns an array of notebook objects:

```json
[
  {
    "notebook_id": "abc123",
    "path": "/home/user/analysis.jl",
    "cell_count": 12
  }
]
```

#### `read_notebook_code`

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `notebook_id` | string | yes | — | Notebook UUID |
| `order` | string | no | `execution` | `execution` or `visual` |

Returns a linear `code` string with embedded cell markers, plus `cell_ids`, `stale_cell_ids`, and `pending_run`.

#### `read_cell`

| Parameter | Type | Required | Description |
|---|---|---|---|
| `notebook_id` | string | yes | Notebook UUID |
| `cell_id` | string | yes | Cell UUID |

Returns a single cell object:

```json
{
  "cell_id": "cell-uuid",
  "code": "x = 1 + 1",
  "output": "2",
  "errored": false,
  "running": false,
  "queued": false,
  "stale": false,
  "code_folded": false
}
```

#### `edit_cell`

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `notebook_id` | string | yes | — | Notebook UUID |
| `cell_id` | string | yes | — | Cell UUID |
| `code` | string | yes | — | New cell code |
| `run_after` | boolean | no | `false` | Run the cell after updating |

Returns a mutation receipt (plus cell fields when staging).

#### `edit_cells`

| Parameter | Type | Required | Description |
|---|---|---|---|---|
| `notebook_id` | string | yes | Notebook UUID |
| `cells` | array | yes | `[{cell_id, code}, ...]` to stage |

Never runs cells. Call `submit_changes` to execute staged edits.

#### `add_cell`

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `notebook_id` | string | yes | — | Notebook UUID |
| `code` | string | yes | — | Initial cell code |
| `after_cell_id` | string | no* | — | Insert after this cell; required when notebook is non-empty |
| `run_after` | boolean | no | `false` | Run the new cell after inserting |
| `folded` | boolean | no | `false` | Hide the new cell's code (fold); use for markdown/prose cells |

#### `delete_cell`

| Parameter | Type | Required | Description |
|---|---|---|---|
| `notebook_id` | string | yes | Notebook UUID |
| `cell_id` | string | yes | Cell UUID to delete |

Returns a mutation receipt. Irreversible within the session.

#### `submit_changes`

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `notebook_id` | string | yes | — | Notebook UUID |
| `cell_ids` | array | no | all pending | Subset of staged cell IDs to run |
| `wait_for_completion` | boolean | no | `false` | Block until cells finish (prefer false on stdio-bound sessions) |

Runs staged cells and reactive dependents (Pluto Cmd+S semantics). Default is non-blocking; poll `read_cell` / `read_notebook_code` for completion.

#### `execute_cell`

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `notebook_id` | string | yes | — | Notebook UUID |
| `cell_id` | string | yes | — | Cell UUID |
| `wait_for_completion` | boolean | no | `false` | Block until the cell finishes (prefer false on stdio-bound sessions) |

#### `run_all_cells`

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `notebook_id` | string | yes | — | Notebook UUID |
| `wait_for_completion` | boolean | no | `false` | Block until all cells finish (can be slow) |

#### `move_cell`

| Parameter | Type | Required | Description |
|---|---|---|---|
| `notebook_id` | string | yes | Notebook UUID |
| `cell_id` | string | yes | Cell UUID to move |
| `after_cell_id` | string | yes | Move after this cell UUID; pass `""` to move to the top |

Returns a mutation receipt with `old_index` / `new_index` in `mutation`.

#### `fold_cell`

| Parameter | Type | Required | Description |
|---|---|---|---|
| `notebook_id` | string | yes | Notebook UUID |
| `cell_id` | string | yes | Cell UUID |
| `folded` | boolean | yes | `true` hides the code editor (output stays visible); `false` shows it |

Metadata only: nothing runs, and the state is persisted in the notebook file's cell-order markers. `read_cell` reports the current value as `code_folded`.

### Error responses

When a tool call fails, the result has `"isError": true` and a structured body:

```json
{
  "error": "notebook_not_found",
  "message": "No notebook with id 'abc123' in the current session"
}
```

---

## How it works

PlutoMCP runs **inside the same Julia process as Pluto**. It holds a reference to the live `Pluto.ServerSession` and manipulates `Pluto.Notebook` objects directly via Pluto's internal Julia API — the same functions the Pluto frontend calls, but invoked in-process.

This means:
- Cell edits trigger Pluto's full reactive scheduler — dependent cells re-run automatically
- The browser stays in sync via Pluto's normal WebSocket push mechanism

The MCP transport is **HTTP/SSE** (Server-Sent Events). The bridge exposes three endpoints:

| Endpoint | Purpose |
|---|---|
| `GET /sse` | Establishes the SSE stream; returns a `sessionId` (legacy `serve()` only) |
| `POST /message?sessionId=...` | Receives JSON-RPC 2.0 requests (legacy `serve()` only) |
| `GET /health` | Legacy: plain `ok`. Bound: JSON `{status,session_id,mcp_port,pluto_port,pluto}` |
| `POST /call` | JSON-RPC tools/call. Bound mode requires `X-Styx-Session-ID` |

The bridge is loopback-only and not a web API: it sends no CORS headers, and any request carrying an `Origin` header or a non-loopback `Host` (a browser page, including via DNS rebinding) gets `403`.

The `connect()` stdio server reads and writes newline-delimited JSON-RPC 2.0 on stdin/stdout. Legacy unbound mode may proxy to a running `serve()` bridge. Bound mode always dispatches in-process against its owned control bridge and deferred Pluto session.

---

## Cell output serialization

MCP tool results are plain text, so rich cell outputs are serialized as follows:

| Output type | Serialized as |
|---|---|
| `text/plain` | the text directly |
| `text/html`, etc. | `[text/html output, 1.2KB]` |
| Binary (images, etc.) | `[image/png output, 48KB]` |
| Error | the error message string; `"errored": true` |
| No output | empty string |

---

## Optional eval trace logging

For agent eval harnesses (see [Styx `eval/`](https://github.com/jowch/styx/tree/main/eval)), enable server-side tool-call tracing:

```julia
PlutoMCP.serve(notebook="my_nb.jl", eval_log="/tmp/trace.jsonl", eval_run_id="run-1")
```

Kwargs: `eval_log`, `eval_run_id`, `eval_redact_code`. Or env vars `PLUTOMCP_EVAL_LOG`, `PLUTOMCP_EVAL_RUN_ID`, `PLUTOMCP_EVAL_REDACT_CODE`.

Scenarios, fixtures, reference runner, and SDK orchestration live in the Styx plugin repo — not here — to keep the MCP server surface minimal for upstream.

---

## License

MIT
