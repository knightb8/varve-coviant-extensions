@adr:docs/decisions/DR-0001-vibe-unified-store.md
@covers:adapters/vibe.sql
@covers:features/steps/lake_steps.py
@core
Feature: Vibe unified-store sessions reach the lake
  vibe 3.x records each session in a unified store under
  unified/<uuid>/. Every mirrored unified store should surface as exactly
  one vibe session in the lake, whether or not its directory contains a
  meta.json. See docs/decisions/DR-0001 and docs/BRIEFING.md.

  Background:
    Given a built varve lake
    And the vibe mirror has been synced

  Scenario: Sessions written after the unified-store switch are present
    When the operator collects lake sessions of runtime "vibe" started on or after "2026-10-25"
    Then there is at least one such session for every mirrored unified store

  Scenario: Sessions are identified and timed without meta.json
    When the operator collects lake sessions of runtime "vibe" started on or after "2026-10-25"
    Then every collected session has a session id, a start timestamp and a date

  Scenario: Session metadata survives where meta.json exists
    When the operator collects lake sessions of runtime "vibe" started on or after "2026-10-25"
    Then every collected session whose store carries metadata has a working directory
