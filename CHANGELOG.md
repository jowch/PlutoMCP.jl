# Changelog

All notable changes to this project are documented here.

[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

### Added

- **Optional `client_url` on session status (Styx [#15](https://github.com/jowch/styx/issues/15)):** `session_status_dict` passes through a matching Styx Ports sidecar (`windows/<key>.client.json` from `asExternalUri`); omits the field when unset or host URL mismatched — never invents remaps

### Changed

- **Safe preview (AGENTS):** agent exits gate via Glass **Run notebook code** / `allow_execution` (align Styx skills; Related to Styx #3)
- **Non-blocking wait defaults:** `submit_changes` / `execute_cell` default `wait_for_completion=false`; `run_after=true`, `allow_execution` / `open_notebook(run_notebook=true)` also queue runs without blocking the MCP call (stdio starvation mitigation for Styx [#3](https://github.com/jowch/styx/issues/3))
- **Stdio stall polish:** `delete_cell` uses `run_async=true`; bound sessions force `wait_for_completion=false` (`wait_forced_async` warning); `open_notebook(run_notebook=true)` / `allow_execution` no longer double-run after Pluto already queued the notebook; `allow_execution(run_notebook=false)` exits safe preview without queuing a full run
- Legacy unbound `connect()` / `serve()` behavior retained for non-Styx clients (plain `/health` `ok`, optional proxy to `:2346`)

## [1.4.1] — prior

See git history / README for the 1.4.1 line (stdio attach to a bridge that appears after `connect()`, JSON.jl, `require_secret_for_access`, etc.).
