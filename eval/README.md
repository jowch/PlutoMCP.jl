# Pluto MCP Agent Eval Harness

Repeatable evaluation of agent MCP tool usage: server-side trace logging, deterministic outcome scoring, and a golden-path reference runner.

## Layout

```
eval/
  PLUTO_WORKFLOW_PREFIX.md   # minimal agent workflow instructions
  fixtures/                  # notebooks with stable cell UUIDs
  scenarios/                 # task specs + rubrics
  golden/                    # optional expert traces (diagnostic only)
  lib/EvalShared.jl          # shared scoring helpers
  score.jl                   # outcome + trace grader
  run_reference.jl           # SWE-bench-style gold runner (no agent)
  results/                   # gitignored run artifacts
```

## Reference runner (CI)

Validates fixtures, HTTP `/call` transport, and scoring without any agent or API key:

```bash
julia --project=. eval/run_reference.jl --all
julia --project=. eval/run_reference.jl --scenario stage_and_run
```

All four v1 scenarios run in CI via `test/runtests.jl`.

## Scoring

```bash
julia --project=. eval/score.jl \
  --scenario stage_and_run \
  --log eval/results/<run_id>/trace.jsonl \
  --mcp-url http://127.0.0.1:<port> \
  [--meta eval/results/<run_id>/meta.json] \
  [--strict-trace]
```

- **Outcome** (strict): claim checks on live notebook state via `/call`
- **Trace** (advisory by default): rubric on server-side jsonl from `eval_log`

## Eval logging

Activate when starting the bridge:

```julia
PlutoMCP.serve(
    notebook = "/path/to/notebook.jl",
    eval_log = "/path/to/trace.jsonl",
    eval_run_id = "my-run",
    launch_browser = false,
)
```

Or via environment: `PLUTOMCP_EVAL_LOG`, `PLUTOMCP_EVAL_RUN_ID`, `PLUTOMCP_EVAL_REDACT_CODE=true`.

## Scenarios (v1)

| ID | Tests |
|----|-------|
| `stage_and_run` | read → edit → submit_changes; reactivity |
| `batch_edit` | edit_cells + single submit |
| `read_guard_recovery` | read_required error then recovery |
| `add_cell_placement` | anchor read + add_cell after anchor |

## Trace rubric rules

- `read_before_first_edit`: `read_notebook_code` covers all cells; `add_cell` requires anchor read
- `must_include_subsequence`: ordered subsequence, not exact match
- `expect_read_required_error`: for guard-recovery scenario

## SDK agent runs

See [Styx eval/README.md](https://github.com/jowch/styx/blob/main/eval/README.md) for Cursor SDK orchestration (`CURSOR_API_KEY` required).

## Phase 1 gate

| Tier | Criterion |
|------|-----------|
| CI | `run_reference.jl --all` passes |
| Manual | SDK `stage_and_run` outcome pass@1 |
| Baseline | SDK trace score recorded (advisory) |

## Data handling

Eval logs and `results/` may contain notebook code. Do not commit `eval/results/` or `*.jsonl`. Use `eval_redact_code=true` / `PLUTOMCP_EVAL_REDACT_CODE=true` when sharing logs.
