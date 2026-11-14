# DR-0002 — Compile-check adapter SQL through the engine's in-memory runner

- **Kind**: TC (Technical)
- **Status**: accepted (2026-11-14)
- **Decides**: how `just test` verifies extension adapter SQL without a lake build.

## Context

The previous `test` recipe only launched a DuckDB binary and echoed "OK" — it
could not detect invalid adapter SQL (and indeed a binder bug had drifted into
the shipped vibe adapter unnoticed). A real `just build` is the honest check,
but it is slow, mutates `$VARVE_DATA`, and runs all runtimes plus checks.

## Decision

`just test` compiles each `adapters/*.sql` the exact way `bin/build` would —
pinned DuckDB via the engine's `bin/duck` runner, shared `sql/prelude.sql`,
`mirror_dir` pointed at that runtime's live mirror — which is in-memory, so
staging tables are written to a discarded throwaway database and the published
lake is never touched. After compile, it counts rows of all four staging
tables; any failure fails the recipe. Runtimes without a mirror are skipped.
The default memory limit is raised to 8GB to match what a full build needs
here (the opencode adapter floors the engine's 4GB default).

## Alternatives rejected

- **Behave-only SQL fixtures with synthetic JSON corpora**: better isolation,
  but fixtures drift from the real mirror; the compile check plus the live-lake
  feature files give both ends. Synthetic fixtures remain an option for
  edge-case catalogs later.
- **Bare `duckdb :memory:` loading adapters directly**: skips `bin/duck`'s
  version pin, resource caps, and the data-home toml views, so it would not be
  the same environment a real build sees.
- **Always running `just build` as the test**: too slow and too mutating for a
  red/green inner loop.
