"""Step bindings for the end-to-end coverage audit (lake_completeness/core)."""

import json
import os
import subprocess

from behave import given, when, then

from environment import engine_env, engine


@given("the varve environment contract is satisfied")
def step_given_env_contract(context):
    # engine() raises with actionable guidance when VARVE_ENGINE is unusable
    context._engine = engine()


@when("the operator runs the end-to-end coverage audit")
def step_when_run_audit(context):
    proc = subprocess.run(
        ["python3", "tools/coverage_audit.py", "--compact"],
        cwd=context.repo, env=engine_env(), capture_output=True, text=True, timeout=300,
    )
    context.audit_exit = proc.returncode
    context.audit = json.loads(proc.stdout.strip().splitlines()[0])


@then("no runtime reports a coverage gap")
def step_then_no_gaps(context):
    gaps = {k: v for k, v in context.audit.items()
            if v.get("status") in ("GAP",) or v.get("status") == "SKIP"}
    assert not gaps, f"coverage gaps: {json.dumps(gaps, indent=2)[:1200]}"


@then("no runtime has settled units that are absent from the lake")
def step_then_no_settled_lost(context):
    lost = {k: v["settled_not_in_lake"] for k, v in context.audit.items()
            if v.get("settled_not_in_lake")}
    assert not lost, f"settled sessions missing from the lake: {lost}"
