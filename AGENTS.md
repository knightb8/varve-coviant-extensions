# varve-coviant-extensions — Project Rules

> Rules for AI agents and contributors working in this addon repo.

## 1. Project Identity

**varve-coviant-extensions** — composable runtime adapters, ingestion
contracts, and operator tooling for the [Varve](https://gitlab.com/dunn.dev/varve)
agent-session data lake. This repo is the addon; it uses any varve engine
checkout as a library; all data lives in `$VARVE_DATA`
(`~/.local/share/varve/` by default) — never in any repo.

Environment contract:
- `VARVE_ENGINE` — path to a varve engine checkout (ships `bin/duck`,
  `bin/sync`, `sql/prelude.sql`). Required; there is no hardcoded location.
- `VARVE_DATA` — varve data home; defaults to `~/.local/share/varve`.

Orientation for agents working on THIS machine lives in untracked,
machine-specific artifacts: `docs/BRIEFING.md` (repo + lake state) and
`docs/BOARD.md` (task board). Both are gitignored — never commit them; they
describe one machine's checkout and data.

## 2. Development Cycle

Work follows the **BDD Chem** development cycle
(`~/coding/bdd_chem/DEVELOPMENT_CYCLE.md` — the portable contract):

1. **Plan & align** before non-trivial work; write a Decision Record under
   `docs/decisions/` for significant decisions, using the kinds from
   `~/coding/bdd_chem/DECISION_RECORDS.md`.
2. **Specify first.** No implementation without a `.feature` file:
   `features/<domain>/<layer>/<aspect>-<counter>.feature`
3. **Red → green → refactor.** Run the suite with behave; no unimplemented
   step stubs may remain.
4. **Close** only when every step passes, the feature index is regenerated,
   and there is a findable closing commit.

## 3. Project Mechanics

- **Engine tooling**: everything lake-side runs from the engine checkout
  (`cd "$VARVE_ENGINE"`); lake queries go through `just sql`, which is
  `bin/duck sql` (version-pinned `duckdb` via the engine's `bin/tool`).
- **BDD runner note**: `behave` must resolve against the environment's
  python; step definitions shell out to the engine's `just`, so only the
  `VARVE_*` environment contract matters, not interpreter locations.
- **Safe vs unsafe**: read-only `just sql` is always safe. `just build` swaps
  the lake atomically (failed runtime keeps its previous partitions, failed
  check leaves the lake untouched). `just sync` only grows the mirror.
- **Ground truth for columns** is `DESCRIBE <table>` through `just sql`; the
  fork's live schema can differ from upstream `sql/record.sql`.
- **Adapter test loop** (no lake rebuild needed): the extension adapters can be
  compiled against the mirror in a throwaway in-memory DuckDB:
  `just test` (sets `mirror_dir`, runs each adapter, reports failures).
- **BDD runner**: `python3 -m behave features/<path>/<file>.feature` from this
  repo's root (behave via pyenv). Lake-dependent scenarios call `just sql`
  through the engine repo. `./bdd_utils.sh lint features` and
  `./bdd_utils.sh index features features/INDEX.md` validate layout and
  regenerate the feature index (never edit `features/INDEX.md` manually).
- **Board**: `docs/BOARD.md` tracks tasks (columns: todo / active / done).
- **Lake-relative queries** must go through the engine's `just sql` runner,
  never a bare `duckdb` binary on `varve.duckdb` (lock + resource caps).

## 4. Adapter Contract

Every adapter SQL writes only the four staging tables
(`stg_sessions`, `stg_messages`, `stg_api_calls`, `stg_tool_calls`) and cleans
up its helper tables. It must parse defensively (`ignore_errors = true`,
`try_cast`) — source logs are written by live agents and may be malformed or
mid-flight. Runtimes are declared in `runtimes.extension.toml`; `just install`
copies adapters into `$VARVE_DATA/adapters/`.
