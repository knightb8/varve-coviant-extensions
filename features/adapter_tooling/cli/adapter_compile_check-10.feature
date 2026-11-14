@adr:docs/decisions/DR-0002-adapter-compile-check.md
@covers:justfile
@covers:features/steps/tooling_steps.py
@core
Feature: Extension adapters compile against DuckDB
  Operators need a lake-independent check that every shipped adapter SQL is
  syntactically valid and produces the four staging tables, using the same
  environment as a real build (pinned duckdb, shared prelude, mirror
  variable).

  Scenario: Every adapter admits a build run
    When the operator runs the extension adapter compile check
    Then every adapter completes its staging build without error

  Scenario: The staging contract is produced
    When the operator runs the extension adapter compile check
    Then every adapter exposes the staging tables "stg_sessions", "stg_messages", "stg_api_calls" and "stg_tool_calls"
