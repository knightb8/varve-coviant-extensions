@adr:docs/decisions/DR-0001-vibe-unified-store.md
@covers:adapters/vibe.sql
@covers:features/steps/lake_steps.py
@core
Feature: Legacy vibe sessions are unaffected
  The legacy session_*/ layout written by vibe 2.x must keep flowing into the
  lake through the unchanged messages.jsonl path while the unified-store
  branch is added alongside it (see docs/decisions/DR-0001). Expectations are
  derived from the live legacy mirror instead of fixed counts, so the suite
  stays valid on any machine.

  Background:
    Given a built varve lake
    And the mirror's legacy vibe stores are counted

  Scenario: Pre-switch sessions remain present
    When the operator collects lake sessions of runtime "vibe" started before "2026-09-16"
    Then the collection holds one session for every legacy store directory

  Scenario: Legacy transcripts remain intact
    When the operator collects lake messages of runtime "vibe" written before "2026-09-16"
    Then the collection holds at least one message for every legacy store directory
