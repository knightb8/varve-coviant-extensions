@adr:docs/decisions/DR-0003-end-to-end-coverage.md
@covers:tools/coverage_audit.py
@covers:features/steps/coverage_steps.py
@core
Feature: End-to-end coverage of the session lake
  No settled agent session may be lost between the runtimes' live log
  directories, the varve mirror, and the lake; in-flight stores stay pending
  and never fail the audit.

  Background:
    Given the varve environment contract is satisfied
    And a built varve lake

  Scenario: All runtimes are covered end to end
    When the operator runs the end-to-end coverage audit
    Then no runtime reports a coverage gap

  Scenario: The lake never trails the source for settled sessions
    When the operator runs the end-to-end coverage audit
    Then no runtime has settled units that are absent from the lake
