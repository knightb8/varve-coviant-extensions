# varve-coviant-extensions

[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**Composable runtime adapters, ingestion contracts, and operator tooling for the [Varve](https://gitlab.com/dunn.dev/varve) agent-session data lake.**

---

## What is this?

[Varve](https://gitlab.com/dunn.dev/varve) (mirrored at [andrewdunndev/varve](https://github.com/andrewdunndev/varve)) is a local data lake engine that normalizes AI coding agent session logs into Parquet partitions queried with DuckDB. 

Following Varve's core modularization, the upstream core keeps a minimal, pristine footprint with three example adapters (`claude-code`, `pi`, and `opencode`). All other runtimes live cleanly in your own data home (`$VARVE_DATA/adapters/`) and `runtimes.toml`, requiring **zero modifications to the core repository**.

`varve-coviant-extensions` is the companion ecosystem repository providing battle-tested, plug-and-play runtime adapters and operator forensics tools adhering strictly to Varve's contract (`sql/record.sql`).

```
                    ┌─────────────────────────────────────┐
                    │       Upstream Varve Engine         │
                    │  (andrewdunndev/varve, dunn.dev)   │
                    │   • bin/sync (file mirror)          │
                    │   • bin/build (lake compiler)       │
                    │   • bin/duck (resource caps)        │
                    │   • checks/ (ADR-0009 verification) │
                    └──────────────────┬──────────────────┘
                                       │ loads
                                       ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      varve-coviant-extensions                           │
│  ~/.local/share/varve/adapters/                                         │
│                                                                         │
│  ├─ antigravity.sql  (Google Antigravity CLI & IDE multi-agent traces) │
│  ├─ vibe.sql         (Mistral Vibe CLI sessions & tool rejections)      │
│  ├─ copilot.sql      (GitHub Copilot CLI events & session-store.db)     │
│  └─ opencode.sql     (OpenCode dual-schema: v1 + v2 session_v2)        │
│                                                                         │
│  tools/                                                                 │
│  ├─ evidence_pack.py (forensic session capture & verification)          │
│  ├─ backup_copilot.sh (hot SQLite WAL checkpoint replication)           │
│  └─ resume_pack.py   (context replay packaging)                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Included Adapters

Every adapter is an isolated SQL transformation that writes the four core contract tables graded by `bin/check`:
- `stg_sessions`
- `stg_messages`
- `stg_api_calls`
- `stg_tool_calls`

| Adapter | Source Runtimes | Ingestion Highlights |
| :--- | :--- | :--- |
| **`antigravity.sql`** | Google Antigravity CLI & IDE | Ingests `.system_generated/logs/transcript*.jsonl`. Parses multi-agent subagent DAGs (`is_sidechain`), unrolls planner `tool_calls` arrays paired with model execution steps, maps tool outcomes (`ok`, `error`, `denied`, `cancelled`, `running`), and tracks token usage. |
| **`vibe.sql`** | Mistral Vibe CLI | **Dual-layout**: legacy `session_*/meta.json` + `messages.jsonl` and the 3.x unified session store (`unified/<uuid>/` chunks + projections — sessions without `meta.json` get their identity from the projection state; note the unified store carries no usage/cost data, so `api_calls` stay empty for it, see `docs/decisions/DR-0001`). Unrolls tool call arrays, captures non-zero returncode failures, operator tool permission rejections, and model pricing for legacy sessions. |
| **`copilot.sql`** | GitHub Copilot CLI | Dual-source normalization from `session-state/<id>/events.jsonl` and SQLite `session-store.db`. Captures model usage events, permission verifications, and tool outcomes. |
| **`opencode.sql`** | OpenCode CLI & Desktop | **Dual-schema engine**: seamlessly unifies older OpenCode V1 tables (`session`, `message`, `part`) with modern OpenCode V2 tables (`session_v2`, `session_message`, content arrays) so historical sessions are never lost. |

---

## Companion Operator Tools

Located in [`tools/`](tools/):

* **`backup_copilot.sh`**: Creates consistent, atomic SQLite snapshots of Copilot CLI's `session-store.db` (and `-wal`/`-shm`) using copy-on-write or safe transaction locks, preventing database corruption during active coding sessions.
* **`evidence_pack.py`**: Extracts self-contained JSON/Markdown evidence bundles for specific session chains, enabling leak-free bug reproductions and benchmark synthesis.
* **`resume_pack.py`**: Reconstructs prompt context, tool execution chains, and operator interventions to evaluate context engineering saturation.

---

## Installation & Setup

### 1. Install Extension Adapters

Clone this repository and run `just install` (or copy the SQL files manually):

```bash
git clone https://github.com/knightb8/varve-coviant-extensions.git
cd varve-coviant-extensions
just install
```

This copies the adapters to `~/.local/share/varve/adapters/` (or `$VARVE_DATA/adapters/`).

### 2. Configure `runtimes.toml`

Add the extension runtime definitions to `~/.local/share/varve/runtimes.toml` (see [`runtimes.extension.toml`](runtimes.extension.toml)):

```toml
[[row]]
name = "antigravity"
adapter = "antigravity.sql"
source = "~/.gemini/antigravity-cli/brain"
include = ["*.jsonl"]

[[row]]
name = "vibe"
adapter = "vibe.sql"
source = "~/.vibe/logs/session"
include = ["*.json", "*.jsonl"]

[[row]]
name = "copilot"
adapter = "copilot.sql"
source = "~/.copilot"
include = ["*.jsonl", "*.db", "*.db-wal"]
replace = ["session-store.db", "session-store.db-wal"]

[[row]]
name = "opencode"
adapter = "opencode.sql"
source = "~/.local/share/opencode"
include = ["opencode.db", "opencode.db-wal"]
replace = ["opencode.db", "opencode.db-wal"]
```

### 3. Build with Varve Core

In your Varve directory:

```bash
just sync && just build
```

Varve's `bin/check` will automatically validate the ingested tables against `sql/record.sql`.

---

## License

MIT License. See [LICENSE](LICENSE) for details.
