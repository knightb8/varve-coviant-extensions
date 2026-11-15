# DR-0003 — End-to-end coverage audit: every settled source session reaches the lake

- **Kind**: IV (Invariant)
- **Status**: accepted (2026-11-14)
- **Decides**: how this repo guarantees no agent session is lost between the
  runtimes' live log directories, the varve mirror, and the lake.
- **Enforcing feature**: `features/lake_completeness/core/end_to_end_coverage-10.feature`

## Invariant

For every runtime in `$VARVE_DATA/runtimes.toml`: once a source store unit is
settled (it carries a usable identity artifact — a uuid directory name plus a
`meta.json` or unified-store `generations/*/projection-state.json`, or a
mirrored `meta.json` with a `session_id`), it must exist in the mirror and its
session id must exist in `sessions`. Units without identity artifacts are
in-flight and only reported as pending — live agents write stores
continuously, so pending is expected on any audit run.

## Mechanism

`tools/coverage_audit.py` walks source and mirror trees per runtime, resolves
identities, and compares against `sessions` through the engine's `just sql`.
Exit 0 = green (pending allowed); exit 1 = a `just sync` / `just build` gap.
The behave suite runs the tool and fails on a GAP status, so any drifting
runtime shows up the same way adapter regressions do.

## Rejected alternatives

- **Hash-of-everything mirror diff**: exact but meaningless across runtimes
  whose adapters collapse units into sessions; identity resolution is the
  ground truth that matters.
- **Only lake-internal checks** (`no_lost_sessions` in the engine): those
  compare a build against the published lake but cannot see a source store
  that was never mirrored.
- **A cron-launched watch loop**: the audit is intentionally pull-based so any
  agent run can evidence completeness on demand instead of maintaining
  always-on state.
