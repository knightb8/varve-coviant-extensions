"""Step bindings for the adapter compile-check feature (adapter_tooling/cli)."""

import re
import subprocess

from behave import when, then

from environment import REPO, engine_env


@when("the operator runs the extension adapter compile check")
def step_when_compile_check(context):
    context.compile = subprocess.run(
        ["just", "test"],
        cwd=REPO, env=engine_env(), capture_output=True, text=True, timeout=1200,
    )
    assert context.compile.returncode in (0, 1), (
        f"just test crashed: {context.compile.stderr.strip()[:400]}"
    )


@then("every adapter completes its staging build without error")
def step_then_no_compile_errors(context):
    out = context.compile.stdout + context.compile.stderr
    assert "FAIL" not in out, f"adapter compile failures:\n{out[:1500]}"
    assert context.compile.returncode == 0, f"just test failed:\n{out[:1500]}"


@then('every adapter exposes the staging tables "stg_sessions", "stg_messages", "stg_api_calls" and "stg_tool_calls"')
def step_then_staging_tables(context):
    out = context.compile.stdout + context.compile.stderr
    ok_tables = set(re.findall(r"table=(\w+)", out))
    assert ok_tables == {"stg_sessions", "stg_messages", "stg_api_calls", "stg_tool_calls"}, (
        f"staging tables not reported for every adapter, saw {sorted(ok_tables)}"
    )
