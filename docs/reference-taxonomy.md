# Reference taxonomy

> Phase 0 artifact for `read_notebook_code` projection (Phase 1A). Ground truth: gitignored `reference/` notebooks in this repo.

## Purpose

Pluto notebooks on disk are not a flat Julia script. Agents need a **file-shaped code projection** from live `Pluto.Notebook` state. This doc classifies on-disk and in-memory cell kinds so Phase 1A can implement projection via Pluto internals (not raw-file regex).

**Spec:** [pluto-cursor-bridge `mcp-phase-1.md` § 1A](https://github.com/jowch/pluto-cursor-bridge/blob/main/docs/specs/mcp-phase-1.md) (projection rules).

---

## Reference artifacts

| File | Source | What it exercises |
|------|--------|-----------------|
| `reference/basic_deps.jl` | Copy of `test/fixtures/test_notebook.jl` | Minimal two-cell dependency chain; cell markers; cell-order footer |
| `reference/projection_edge_cases.jl` | Authored for Phase 0 | Markdown, `@bind`, empty cell, manifest blobs, visual ≠ execution order |

`reference/` is gitignored. If missing locally, copy `basic_deps.jl` from `test/fixtures/test_notebook.jl` and recreate `projection_edge_cases.jl` from this doc.

Open in Pluto (`PlutoMCP.serve()` → load file) to inspect live `cell_order`, topology, and outputs.

---

## On-disk notebook layout

Every `.jl` notebook file has these regions (top to bottom):

```text
### A Pluto.jl notebook ###     ← header (ignore in projection)
# v<pluto-version>                ← version line (ignore)
#> <toml>                        ← optional notebook metadata (ignore)
using Markdown                    ← boilerplate imports (ignore)
using InteractiveUtils
[optional @bind shim macro]       ← header shim (ignore)
# ╔═╡ <uuid>                      ← cell marker (keep in projection)
<cell body>
… repeat per cell …
# ╔═╡ 00000000-…000001            ← PLUTO_PROJECT_TOML (exclude)
# ╔═╡ 00000000-…000002            ← PLUTO_MANIFEST_TOML (exclude)
# ╔═╡ Cell order:                 ← footer start (exclude entire footer)
# ╠═<uuid>                        ← visual order entries (exclude)
# ╟─<uuid>                        ← folded cells in footer (exclude)
```

**Delimiter constants** (from Pluto `saving and loading.jl`):

| Constant | Line prefix | Role |
|----------|-------------|------|
| `_cell_id_delimiter` | `# ╔═╡ ` | Starts a cell block in file body |
| `_cell_metadata_prefix` | `# ╠═╡ ` | Per-cell TOML metadata (ignore in projection) |
| `_order_delimiter` | `# ╠═` | Code cell in visual-order footer |
| `_order_delimiter_folded` | `# ╟─` | Folded / markdown / pkg cells in footer |

---

## Cell types

### Code cells (include)

Normal Julia source. Projection **includes** body with preceding marker:

```julia
# ╔═╡ a0000000-0000-0000-0000-0000000000b1
z = 10
```

**Empty code cells** (whitespace-only body) are included as:

```julia
# ╔═╡ a0000000-0000-0000-0000-0000000000f1
# (empty)
```

See `projection_edge_cases.jl` cell `…000f1`.

### Markdown cells (exclude default)

Cells whose source is `md"""…"""` (or `md"…"`). Rendered as HTML in UI; not agent-editable code in default projection.

| Mode | Behavior |
|------|----------|
| Default (`include_markdown=false`) | Omit from `code` string and `cell_ids` |
| Opt-in (`include_markdown=true`) | Emit as `# md:\n<raw md source>` after marker |

Footer marks markdown as folded: `# ╟─<uuid>` (see `…000a1` in `projection_edge_cases.jl`).

### `@bind` cells (include body; exclude header shim)

Two distinct artifacts:

| Artifact | Location | Projection |
|----------|----------|------------|
| **Header shim** | Between imports and first `# ╔═╡` | Exclude — `macro bind(def, element) … end` plus comment |
| **Bind usage cell** | Normal cell, `@bind` must be **last expression** | Include — agent needs the binding source |

Pattern (from `projection_edge_cases.jl`):

```julia
# ╔═╡ …000d1
@bind level html"<input type=range min=0 max=100 value=50>"

# ╔═╡ …000e1
level
```

Bound value display lives in a **separate** downstream cell (`level`), not in the bind cell output.

### Manifest blob cells (exclude)

When the notebook has a package environment, Pluto appends two synthetic cells with **fixed UUIDs**:

| UUID | Variable | Content |
|------|----------|---------|
| `00000000-0000-0000-0000-000000000001` | `PLUTO_PROJECT_TOML_CONTENTS` | Embedded `Project.toml` |
| `00000000-0000-0000-0000-000000000002` | `PLUTO_MANIFEST_TOML_CONTENTS` | Embedded `Manifest.toml` |

Never include in `read_notebook_code` projection. Footer lists them as `# ╟─` entries. See `projection_edge_cases.jl` tail.

Agents manage packages via Pluto UI / `Pkg` workflow, not by editing these blobs.

### Disabled / skipped cells

Cells wrapped in file as `#=╠═╡ … ╠═╡ =#` when disabled or skipped-as-script. Live session tracks `is_disabled` / skip flags — projection should use **live cell state**, not re-parse disabled wrappers from disk.

Phase 1A: confirm Pluto API for disabled cells; default is likely exclude or emit `# (disabled)` (defer if no fixture yet).

---

## Cell-order footer vs execution order

Two orderings matter:

| Order | Source | Used for |
|-------|--------|----------|
| **Visual** (`cell_order`) | `# ╔═╡ Cell order:` footer + `notebook.cell_order` | `add_cell`, `move_cell`, `get_cell_order` |
| **Execution** (topological) | Dependency graph / `_cached_topological_order` | `read_notebook_code` default, `get_execution_order` |

### `basic_deps.jl`

Visual and execution order agree:

```text
11111111-… → x = 6
22222222-… → y = x * 7
```

### `projection_edge_cases.jl`

Visual order (footer):

```text
…000a1 (md, folded)
…000d1 (@bind level)
…000e1 (level)
…000f1 (empty)
…000c1 (w = z + 1)    ← before z in UI
…000b1 (z = 10)
…000001, …000002 (pkg, folded)
```

Execution order (after `updated_topology` + `update_dependency_cache!` on live session):

```text
…000a1 (md)
…000d1 (@bind level)
…000e1 (level)
…000f1 (empty)
…000b1 (z = 10)
…000c1 (w = z + 1)
```

The **z / w swap** is the teaching point: `w` appears above `z` in the UI footer, but `z` must run before `w`.

Markdown `…000a1` is in topology but omitted from default projection. `@bind` / `level` cells precede `z` because `level` is defined by the bind cell before `z` is referenced.

**Implementer note:** freshly loaded notebooks may mirror visual order until Pluto resolves syntax dependencies; `read_notebook_code` must use `_cached_topological_order` from a live `ServerSession`, not the cell-order footer.

**Rule:** `read_notebook_code` default `order=execution` walks topological order, not `cell_order`. Optional `order=visual` for placement-aware reads.

---

## Projection checklist (Phase 1A)

Parse from **live session** (`Pluto.Notebook` + topology), not by regexing `.jl` files.

| Include | Exclude (default) |
|---------|-------------------|
| Code cells, including empty → `# (empty)` | Header, version, `#>` metadata, boilerplate imports |
| Marker `# ╔═╡ <cell_id>` before each included cell | `@bind` header shim macro |
| `cell_ids` parallel to included cells | `PLUTO_PROJECT_TOML_CONTENTS` / `PLUTO_MANIFEST_TOML_CONTENTS` cells |
| | Cell-order footer (`# ╔═╡ Cell order:` through EOF) |
| | Markdown cells (unless `include_markdown=true`) |

### Response shape (reminder)

```json
{
  "notebook_id": "...",
  "path": "...",
  "order": "execution",
  "cell_ids": ["...", "..."],
  "stale_cell_ids": ["..."],
  "pending_run": ["..."],
  "code": "# ╔═╡ …\nz = 10\n\n# ╔═╡ …\n..."
}
```

No duplicate `cells[]` array in default response.

---

## Gaps for Phase 1A implementer

1. **Disabled / skipped cells** — no reference fixture yet; decide include/exclude via `Cell` flags when implementing.
2. **Per-cell metadata** (`# ╠═╡` TOML lines) — exclude from projection; confirm no agent use case in Phase 1.
3. **Notebook-level metadata** (`#>` lines) — exclude; optional future `read_notebook_metadata` tool out of scope.
4. **Richer real-world notebook** — `turtles.jl` (JuliaPluto/featured) not vendored; edge-case fixture is minimal by design.
5. **`include_markdown=true` format** — spec says `# md:\n...`; exact escaping of multiline `md"""` TBD in implementation.
6. **Stale / pending_run** — projection doc only; dirty tracking is Phase 1B.
7. **Topology freshness** — execution order requires resolved notebook topology; confirm session has analyzed cells before projecting (see note under `projection_edge_cases.jl`).
