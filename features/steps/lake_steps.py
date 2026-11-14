"""Step bindings for lake-content features (vibe_ingestion/core)."""

from behave import given, when, then

UNIFIED_SWITCH = "2026-10-25"


@given("a built varve lake")
def step_given_built_lake(context):
    rows = context.run_sql("SELECT count(*) AS n FROM sessions")
    assert rows and rows[0]["n"] > 0, "lake has no sessions; run just sync && just build"


@given("the vibe mirror has been synced")
def step_given_mirror_synced(context):
    stores = context.mirrored_unified_stores()
    assert stores, (
        "no unified stores with projection state in the mirror; "
        "refresh it with `just sync` in $VARVE_ENGINE"
    )


@given("the mirror's legacy vibe stores are counted")
def step_given_count_legacy_stores(context):
    """Count legacy session_<ts>_<id>/ message transcripts in the mirror.

    Machine independent: the suite derives its expectations from whatever the
    local mirror holds, instead of hardcoding this machine's session counts.
    """
    base = context.data_home / "vibe"
    if not base.is_dir():
        context.legacy_stores = set()
        return
    context.legacy_stores = {
        p.parent.name for p in base.glob("*/messages.jsonl")
        if p.parent.is_dir() and p.parent.name not in ("unified", "active")
    }


def _collect(context, table, comparison, date):
    op = ">=" if comparison == "on or after" else "<"
    context.rows = context.run_sql(
        f"SELECT * FROM {table} WHERE runtime = 'vibe' AND date {op} '{date}'"
    )


@when('the operator collects lake sessions of runtime "vibe" started on or after "{date}"')
def step_when_sessions_after(context, date):
    _collect(context, "sessions", "on or after", date)


@when('the operator collects lake sessions of runtime "vibe" started before "{date}"')
def step_when_sessions_before(context, date):
    _collect(context, "sessions", "before", date)


@when('the operator collects lake messages of runtime "vibe" written on or after "{date}"')
def step_when_messages_after(context, date):
    _collect(context, "messages", "on or after", date)


@when('the operator collects lake messages of runtime "vibe" written before "{date}"')
def step_when_messages_before(context, date):
    _collect(context, "messages", "before", date)


@when('the operator collects lake tool calls of runtime "vibe" started on or after "{date}"')
def step_when_tool_calls_after(context, date):
    _collect(context, "tool_calls", "on or after", date)
    context.tool_calls_window = date


@then("there is at least one such session for every mirrored unified store")
def step_then_cover_every_store(context):
    stores = context.mirrored_unified_stores()
    ids = {r["session_id"] for r in context.rows}
    assert len(context.rows) == len(ids), "duplicate session ids in the lake"
    missing = stores - ids
    assert not missing, f"unified stores missing from the lake: {sorted(missing)[:5]}"


@then("every collected session has a session id, a start timestamp and a date")
def step_then_sessions_wellformed(context):
    for r in context.rows:
        assert r["session_id"], "session without session_id"
        assert r["started_at"] is not None, f"session {r['session_id']} without started_at"
        assert r["date"] is not None, f"session {r['session_id']} without date"


@then("every collected session whose store carries metadata has a working directory")
def step_then_metadata_cwd(context):
    for r in context.rows:
        if r["session_id"] in context.stores_with_meta():
            assert r["cwd"], f"session {r['session_id']} has meta.json but no cwd"


@then('at least 90 percent of the sessions started on or after "{date}" carry messages')
def step_then_90pct_messages(context, date):
    with_messages = {r["session_id"] for r in context.rows}
    total = context.run_sql(
        f"SELECT count(DISTINCT session_id) AS n FROM sessions WHERE runtime = 'vibe' AND date >= '{date}'"
    )[0]["n"]
    assert total and len(with_messages) / total >= 0.9, (
        f"only {len(with_messages)} of {total} post-switch sessions carry messages"
    )


@then("the collected messages include both operator and model origins")
def step_then_origins(context):
    origins = {r["origin"] for r in context.rows}
    assert "operator" in origins, "no operator messages"
    assert "model" in origins, "no model messages"


@then("at least one collected message carries reasoning content")
def step_then_reasoning(context):
    reasoning_rows = [r for r in context.rows if (r["message_id"] or "").startswith("reasoning-")]
    assert reasoning_rows, "no reasoning turns captured as messages"


@then('at least 80 percent of the sessions started on or after "{date}" have at least one tool call')
def step_then_80pct_tool_calls(context, date):
    with_calls = {r["session_id"] for r in context.rows}
    total = context.run_sql(
        f"SELECT count(DISTINCT session_id) AS n FROM sessions WHERE runtime = 'vibe' AND date >= '{date}'"
    )[0]["n"]
    assert total and len(with_calls) / total >= 0.8, (
        f"only {len(with_calls)} of {total} post-switch sessions carry tool calls"
    )


@then('every collected tool call carries an outcome among "ok", "error", "denied" and "running"')
def step_then_outcomes(context):
    vocab = {"ok", "error", "denied", "running"}
    bad = {(r.get("outcome") or r.get("decision")) for r in context.rows} - vocab
    assert not bad, f"outcomes outside the contract vocabulary: {bad}"


@then("every collected tool call has a tool name")
def step_then_tool_names(context):
    nameless = [r["tool_use_id"] for r in context.rows if not r["tool_name"]]
    assert not nameless, f"tool calls without a tool name: {nameless[:5]}"


@then("the collection holds one session for every legacy store directory")
def step_then_legacy_sessions_covered(context):
    ids = {r["session_id"] for r in context.rows}
    missing = context.legacy_stores - ids
    assert not missing, f"legacy stores missing from the lake: {sorted(missing)[:5]}"


@then("the collection holds at least one message for every legacy store directory")
def step_then_legacy_messages_covered(context):
    with_messages = {r["session_id"] for r in context.rows}
    missing = context.legacy_stores - with_messages
    assert not missing, f"legacy stores without messages: {sorted(missing)[:5]}"
