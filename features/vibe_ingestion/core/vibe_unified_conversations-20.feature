@adr:docs/decisions/DR-0001-vibe-unified-store.md
@covers:adapters/vibe.sql
@covers:features/steps/lake_steps.py
@core
Feature: Conversations from unified stores are captured
  Operator prompts, model replies and reasoning written by vibe 3.x are
  recovered from the store's chunk entries and land as messages, with their
  origin preserved.

  Background:
    Given a built varve lake

  Scenario: Unified sessions carry conversation messages
    When the operator collects lake messages of runtime "vibe" written on or after "2026-10-25"
    Then at least 90 percent of the sessions started on or after "2026-10-25" carry messages

  Scenario: Operator prompts are distinguishable from model replies
    When the operator collects lake messages of runtime "vibe" written on or after "2026-10-25"
    Then the collected messages include both operator and model origins

  Scenario: Reasoning content is retained for reasoning turns
    When the operator collects lake messages of runtime "vibe" written on or after "2026-10-25"
    Then at least one collected message carries reasoning content
