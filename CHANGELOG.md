# Changelog

All notable changes to this project are documented here.

[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

### Security

- **Control bridge refuses browser requests:** no more `Access-Control-Allow-Origin: *` or `OPTIONS` preflight; any request carrying an `Origin` header, or a `Host` other than `127.0.0.1` / `localhost` / `[::1]` (DNS rebinding), gets `403` with a JSON `{"error":...}` body. Previously a web page open in the user's browser could read the session nonce from `/health` and POST `/call` (arbitrary Julia) through the bridge. MCP clients never send `Origin` and always address loopback, so nothing else changes.

### Added

- **Bound stdio sessions:** `connect(; binding_file, runtime_dir, cursor_host_pid)` owns a loopback control bridge, mints a session nonce, and never proxies to a foreign bridge
- **JSON `/health`:** bound mode returns `{status,session_id,mcp_port,pluto_port,pluto}`; `/call` requires `X-Styx-Session-ID`
- **Dynamic ports:** bound mode allocates Pluto and control ports with `listenany` (no fixed `:1234`/`:2346` requirement)
- **Notebook path leases:** host-local canonical path leases so two bound sessions cannot open the same `.jl` (`notebook_in_use`)
- **SessionBinding module:** binding file I/O, lease acquire/release, health nonce checks

### Changed

- **Safe preview (AGENTS):** agent exits gate via Glass **Run notebook code** / `allow_execution` (align Styx skills; Related to Styx #3)
- **Non-blocking wait defaults:** `submit_changes` / `execute_cell` default `wait_for_completion=false`; `run_after=true`, `allow_execution` / `open_notebook(run_notebook=true)` also queue runs without blocking the MCP call (stdio starvation mitigation for Styx [#3](https://github.com/jowch/styx/issues/3))
- **Stdio stall polish:** `delete_cell` uses `run_async=true`; bound sessions force `wait_for_completion=false` (`wait_forced_async` warning); `open_notebook(run_notebook=true)` / `allow_execution` no longer double-run after Pluto already queued the notebook; `allow_execution(run_notebook=false)` exits safe preview without queuing a full run
- Legacy unbound `connect()` / `serve()` behavior retained for non-Styx clients (plain `/health` `ok`, optional proxy to `:2346`)

## [1.4.1] — prior

See git history / README for the 1.4.1 line (stdio attach to a bridge that appears after `connect()`, JSON.jl, `require_secret_for_access`, etc.).
