# PlutoMCP.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://mthelm85.github.io/PlutoMCP.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://mthelm85.github.io/PlutoMCP.jl/dev/)
[![Build Status](https://github.com/mthelm85/PlutoMCP.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/mthelm85/PlutoMCP.jl/actions/workflows/CI.yml?query=branch%3Amain)

**PlutoMCP.jl** exposes a [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server that lets MCP-compatible AI tools — Claude Desktop, Cursor, and others — inspect and manipulate live [Pluto.jl](https://plutojl.org) notebooks in real time.

```
You (terminal)            AI Tool (Claude Desktop, …)
      │                             │
      │ PlutoMCP.serve()            │  stdio → auto-proxies to bridge
      ▼                             ▼
PlutoMCP bridge  ◄────────── connect() detects :2346 and proxies
      │                   OR connects directly via HTTP/SSE
      │  direct Julia API calls
      ▼
Pluto.ServerSession / Pluto.Notebook  (port 1234)
      │
      │  WebSocket push
      ▼
Browser  (live view — notebooks you open here are visible to AI tools)
```

You start the bridge once when you want Claude to have access. It starts a fresh Pluto session; open notebooks through the Pluto browser UI that `serve()` prints. Claude Desktop configured with `connect()` (stdio) **automatically detects the running bridge** and proxies through it — no reconfiguration needed.

---

## Installation

```julia
using Pkg
Pkg.add("PlutoMCP")
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

> **`require_secret_for_access`:** forwarded to Pluto `Options` (default `true`). Pass `false` to open `http://localhost:PORT/` without a `?secret=` URL.

> **Important**: open your notebooks through the Pluto UI started by `serve()`, not through a separately-started `Pluto.run()`. The MCP bridge owns its own Pluto session; notebooks from other Pluto processes are not shared.

### Step 2 — Configure your MCP client (one-time)

#### Claude Desktop — HTTP (preferred)

Add to `claude_desktop_config.json`
(`~/Library/Application Support/Claude/` on macOS, `%APPDATA%\Claude\` on Windows):

```json
{
  "mcpServers": {
    "pluto": {
      "url": "http://localhost:2346/sse"
    }
  }
}
```

Claude Desktop connects to the running bridge. **No Pluto process is started by Claude Desktop.** If the bridge is not running, tool calls return a clear error message.

#### Claude Desktop — stdio (recommended for most users)

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

`connect()` automatically detects whether a `PlutoMCP.serve()` bridge is running:

- **Bridge running** (recommended): proxies all tool calls through the bridge, so Claude sees the live Pluto session and any notebooks you have open.
- **No bridge**: starts its own isolated Pluto session lazily on the first tool call.

In both cases Claude Desktop starts up instantly — no waiting for Julia at launch time.

#### Cursor

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

| Tool | Description |
|---|---|
| `list_notebooks` | List all notebooks open in the session |
| `read_notebook_code` | Whole notebook as execution-order code projection |
| `read_cell` | Code, output, and stale flag of a single cell |
| `edit_cell` | Replace a cell's code; stages by default (`run_after=false`) |
| `edit_cells` | Batch stage `{cell_id, code}[]`; never runs |
| `add_cell` | Insert a new cell (`after_cell_id` required when notebook is non-empty) |
| `delete_cell` | Delete a cell (immediate reactive cleanup) |
| `submit_changes` | Run all staged cells (Cmd+S semantics) |
| `execute_cell` | Run one cell (Shift+Enter) |
| `run_all_cells` | Re-run all cells in dependency order |
| `move_cell` | Reorder a cell relative to another |
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
  "stale": false
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
| `wait_for_completion` | boolean | no | `true` | Block until cells finish |

Runs staged cells and reactive dependents (Pluto Cmd+S semantics).

#### `execute_cell`

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `notebook_id` | string | yes | — | Notebook UUID |
| `cell_id` | string | yes | — | Cell UUID |
| `wait_for_completion` | boolean | no | `true` | Block until the cell finishes |

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
| `GET /sse` | Establishes the SSE stream; returns a `sessionId` |
| `POST /message?sessionId=...` | Receives JSON-RPC 2.0 requests |
| `GET /health` | Returns `ok` (used by `connect()` to probe the bridge) |

The `connect()` stdio server reads and writes newline-delimited JSON-RPC 2.0 on stdin/stdout, dispatching MCP calls directly without going through the HTTP/SSE bridge. It starts its own Pluto session lazily on first use, so clients that require a subprocess get a fast startup.

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

## Agent eval harness

See [`eval/README.md`](eval/README.md) for the full harness.

- **Reference runner (CI):** `julia --project=. eval/run_reference.jl --all` — golden-path tool sequences via HTTP `/call`, no API key
- **Scoring:** `eval/score.jl` — outcome (strict) + trace (advisory) from server-side `eval_log` jsonl
- **SDK runs:** [pluto-cursor-bridge/eval](../pluto-cursor-bridge/eval/) — Cursor SDK orchestrator (`CURSOR_API_KEY`)

Eval kwargs on `serve()`: `eval_log`, `eval_run_id`, `eval_redact_code`. Or env vars `PLUTOMCP_EVAL_LOG`, `PLUTOMCP_EVAL_RUN_ID`.

---

## License

MIT
