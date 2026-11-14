@adr:docs/decisions/DR-0001-vibe-unified-store.md
@covers:adapters/vibe.sql
@covers:features/steps/lake_steps.py
@core
Feature: Tool activity of unified stores is classified
  Every tool effect vibe 3.x performs lands as a tool call with a classified
  outcome, so denials and failures stay auditable.

  Background:
    Given a built varve lake

  Scenario: Tool effects land as tool calls
    When the operator collects lake tool calls of runtime "vibe" started on or after "2026-10-25"
    Then at least 80 percent of the sessions started on or after "2026-10-25" have at least one tool call

  Scenario: Outcomes stay within the contract vocabulary
    When the operator collects lake tool calls of runtime "vibe" started on or after "2026-10-25"
    Then every collected tool call carries an outcome among "ok", "error", "denied" and "running"

  Scenario: Tool names survive
    When the operator collects lake tool calls of runtime "vibe" started on or after "2026-10-25"
    Then every collected tool call has a tool name
