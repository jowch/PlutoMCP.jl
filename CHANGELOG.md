# Changelog

All notable changes to this project are documented here.

[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) · [Semantic Versioning](https://semver.org/spec/v2.0.0.html)

## [Unreleased]

### Added

- **Bound stdio sessions:** `connect(; binding_file, runtime_dir, cursor_host_pid)` owns a loopback control bridge, mints a session nonce, and never proxies to a foreign bridge
- **JSON `/health`:** bound mode returns `{status,session_id,mcp_port,pluto_port,pluto}`; `/call` requires `X-Styx-Session-ID`
- **Dynamic ports:** bound mode allocates Pluto and control ports with `listenany` (no fixed `:1234`/`:2346` requirement)
- **Notebook path leases:** host-local canonical path leases so two bound sessions cannot open the same `.jl` (`notebook_in_use`)
- **SessionBinding module:** binding file I/O, lease acquire/release, health nonce checks

### Changed

- Legacy unbound `connect()` / `serve()` behavior retained for non-Styx clients (plain `/health` `ok`, optional proxy to `:2346`)

## [1.4.1] — prior

See git history / README for the 1.4.1 line (stdio attach to a bridge that appears after `connect()`, JSON.jl, `require_secret_for_access`, etc.).
