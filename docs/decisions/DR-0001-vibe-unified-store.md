# DR-0001 — Ingest vibe 3.x unified session store from chunk entries

- **Kind**: AR (Architecture)
- **Status**: accepted (2026-11-14)
- **Decides**: how the vibe adapter captures sessions written by vibe 3.x
  (`store_format: mistral.vibe.unified-session-store/v1`, 2026-10-25 → today),
  which the legacy parser misses entirely (0 of 53 sessions reached the lake).

## Context

A vibe unified session directory contains `meta.json` (may be absent — written
late or never for 2/3 of sessions), `generations/*/projection-state.json`
(contains `session_id` and a thin `tool_calls` id map, no messages, no token
usage), `chunks/*.json` (JSON arrays of activity entries: user/assistant
messages, reasoning, tool effects with input/decision/output), and
`journal/*.jsonl` recovery records. `bin/sync` mirrors everything matching
`*.json` / `*.jsonl` recursively, so all of this except the extension-less
`CURRENT` is already in the mirror. There is **no token usage and no cost data
anywhere in the unified store** (verified by scanning every store in the local mirror).

## Decision

Parse inside `adapters/vibe.sql` (SQL-only, like every other adapter), with:

1. **Session identity fallback**: sessions without `meta.json` get their id
   from `projection-state.json` (`session_id`) and their start timestamp from
   the earliest chunk entry `createdAt` (epoch millis). `meta.json` wins where
   present (cwd, title, model, times).
2. **Messages from `<uuid>/chunks/*.json`**: `type='message'` → operator/model
   text, `type='reasoning'` → reasoning content, history entries
   (`message.role='user'`, no `type`) → operator text. Ordered by `createdAt`.
3. **Tool calls from `type='effect'` + `detail.kind='tool'`** entries:
   tool name from `detail.toolName`, arguments from `detail.input` (JSON),
   timestamps from `createdAt`/`updatedAt`, outcome classified from
   `state.decision` (`deny` → denied), `returncode > 0` / display success →
   error, else `ok`. Result text from `state.output`.
4. **api_calls left empty** for unified sessions (no usage data exists); the
   caveat is recorded here and in the feature files, not papered over.

The legacy `session_*/messages.jsonl` path stays untouched and both paths are
deduplicated by `session_id`.

## Rejected alternatives

- **Python ETL tool next to `tools/`**: breaks the "adapter = one SQL file"
  pattern; harder to install via `just install`.
- **Separate `vibe_unified.sql` runtime**: splits one runtime's history across
  two lake partitions boundaries and duplicates attribution wiring.
- **Journal-based parse** (`journal/*.jsonl`): recovery-oriented, duplicative
  of chunk entries, and its records overlap inconsistently with chunks.
- **Skipping api_calls silently**: would violate the contract's auditability;
  we instead emit a documented empty set (unpriced/absent).

## Consequences

- Unified sessions are queryable in all four staging tables except api_calls.
- Cost/token analytics for post-2026-10-25 vibe sessions are impossible at this
  layer (data simply is not stored by vibe 3.x); a future engine change would
  have to capture per-request telemetry from `~/.vibe/logs` instead.
- Parse must stay defensive: vibe 3.x itself skips drifted stores
  (`RuntimeStateV3` validation failures in `~/.vibe/logs/vibe.log`), so the
  adapter must tolerate absent/partial files via `ignore_errors` and `try_cast`.
