-- varve-coviant-extensions GitHub Copilot CLI adapter.
-- Normalizes GitHub Copilot CLI event streams and session-store.db into the
-- four core tables: stg_sessions, stg_messages, stg_api_calls, and stg_tool_calls.
--
-- Contract: sql/record.sql (ADR-0009).
-- Depends on sql/prelude.sql: _attr_rules, _pricing, varve_harness(), varve_campaign().
-- Variable set by the build:
--   mirror_dir : folder containing mirrored Copilot logs and SQLite database

INSTALL sqlite;
LOAD sqlite;

-- ---------------------------------------------------------------------------
-- Raw events stream from session-state/**/events.jsonl
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE _cp_ev AS
SELECT
  regexp_extract(filename, '([^/]+)/events\.jsonl$', 1)                  AS session_id,
  filename,
  type,
  CASE WHEN type = 'session.binary_asset'
       THEN json_merge_patch(data, '{"data":null}') ELSE data END        AS data,
  id                                                                      AS event_id,
  parentId                                                                AS parent_event_id,
  try_cast(replace(timestamp, 'Z', '') AS timestamp)                      AS ts,
  row_number() OVER (PARTITION BY filename)                               AS line_no
FROM read_json(
  getvariable('mirror_dir') || '/**/events.jsonl',
  format                  = 'newline_delimited',
  columns                 = {type: 'VARCHAR', data: 'JSON', id: 'VARCHAR', timestamp: 'VARCHAR', parentId: 'VARCHAR'},
  filename                = true,
  ignore_errors           = true,
  maximum_object_size     = 100000000,
  map_inference_threshold = -1
);

-- Fallback SQLite scans (stubbed if file is absent)
CREATE OR REPLACE VIEW _cp_raw_db_sessions AS
SELECT * FROM (
  SELECT id::varchar AS id, cwd::varchar AS cwd, summary::varchar AS summary, created_at::varchar AS created_at
  FROM sqlite_scan(getvariable('mirror_dir') || '/session-store.db', 'sessions')
) WHERE true;

CREATE OR REPLACE VIEW _cp_raw_db_turns AS
SELECT * FROM (
  SELECT session_id::varchar AS session_id, turn_index::integer AS turn_index,
         user_message::varchar AS user_message, assistant_response::varchar AS assistant_response,
         timestamp::varchar AS timestamp
  FROM sqlite_scan(getvariable('mirror_dir') || '/session-store.db', 'turns')
) WHERE true;

CREATE OR REPLACE VIEW _cp_raw_db_usage AS
SELECT * FROM (
  SELECT id::bigint AS id, session_id::varchar AS session_id, agent_id::varchar AS agent_id,
         model::varchar AS model, input_tokens::bigint AS input_tokens, output_tokens::bigint AS output_tokens,
         cache_read_tokens::bigint AS cache_read_tokens, cache_write_tokens::bigint AS cache_write_tokens,
         total_nano_aiu::bigint AS total_nano_aiu, request_multiplier::double AS request_multiplier,
         duration_ms::bigint AS duration_ms, initiator::varchar AS initiator,
         finish_reason::varchar AS finish_reason, created_at::varchar AS created_at
  FROM sqlite_scan(getvariable('mirror_dir') || '/session-store.db', 'assistant_usage_events')
) WHERE true;

-- ---------------------------------------------------------------------------
-- stg_sessions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_sessions AS
WITH ev_sess AS (
  SELECT session_id,
         any_value(data->'context'->>'cwd')  FILTER (WHERE type = 'session.start') AS cwd,
         any_value(data->>'copilotVersion')  FILTER (WHERE type = 'session.start') AS cp_version,
         min(ts)                                                                   AS started_at
  FROM _cp_ev
  GROUP BY session_id
),
db_sess AS (
  SELECT id AS session_id, cwd,
         NULL::varchar AS cp_version,
         try_cast(replace(created_at, 'Z', '') AS timestamp) AS started_at
  FROM _cp_raw_db_sessions
  WHERE id NOT IN (SELECT session_id FROM ev_sess)
),
base AS (
  SELECT * FROM ev_sess UNION ALL BY NAME SELECT * FROM db_sess
),
matched AS (
  SELECT b.*, r.estate, r.harness AS harness_tok, r.campaign AS campaign_tok
  FROM base b
  LEFT JOIN _attr_rules r
    ON coalesce(b.cwd, '') LIKE replace(r.cwd_glob, '*', '%')
  WHERE b.started_at IS NOT NULL
  QUALIFY row_number() OVER (PARTITION BY b.session_id ORDER BY r.priority) = 1
)
SELECT
  session_id,
  'copilot'                                                               AS runtime,
  cwd,
  varve_harness(cwd, harness_tok)                                         AS harness,
  estate,
  varve_campaign(cwd, campaign_tok)                                       AS campaign,
  started_at,
  NULL::varchar                                                           AS parent_session_id,
  NULL::varchar                                                           AS cc_version,
  NULL::varchar                                                           AS pi_version,
  NULL::varchar                                                           AS oc_version,
  NULL::varchar                                                           AS agent,
  strftime(started_at, '%Y-%m-%d')                                        AS date
FROM matched;

-- ---------------------------------------------------------------------------
-- stg_messages
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_messages AS
WITH ev_msgs AS (
  SELECT
    e.event_id                                                            AS message_id,
    e.session_id,
    CASE e.type WHEN 'assistant.message' THEN 'assistant' ELSE 'user' END AS role,
    e.parent_event_id                                                     AS parent_id,
    (e.data->>'parentToolCallId') IS NOT NULL                             AS is_sidechain,
    e.ts                                                                  AS timestamp,
    e.type                                                                AS record_type,
    e.data->>'apiCallId'                                                  AS api_message_id,
    CASE
      WHEN e.type = 'assistant.message' THEN 'model'
      WHEN e.type = 'user.message'      THEN 'operator'
      ELSE 'operator'
    END                                                                   AS origin,
    CASE WHEN e.type = 'abort' THEN NULL
         ELSE nullif(e.data->>'content', '') END                          AS text,
    (e.type = 'abort')                                                    AS interrupted
  FROM _cp_ev e
  WHERE e.type IN ('user.message', 'assistant.message', 'abort')
),
db_turns AS (
  SELECT t.session_id, t.turn_index,
         try_cast(replace(t.timestamp, 'Z', '') AS timestamp)            AS ts,
         t.user_message, t.assistant_response
  FROM _cp_raw_db_turns t
  WHERE t.session_id NOT IN (SELECT DISTINCT session_id FROM ev_msgs)
),
db_msgs AS (
  SELECT session_id || ':t' || turn_index || ':u'                        AS message_id,
         session_id, 'user' AS role, NULL::varchar AS parent_id,
         false AS is_sidechain, ts AS timestamp, 'db.turn.user' AS record_type,
         NULL::varchar AS api_message_id, 'operator' AS origin,
         nullif(user_message, '') AS text, false AS interrupted
  FROM db_turns
  UNION ALL
  SELECT session_id || ':t' || turn_index || ':a',
         session_id, 'assistant', session_id || ':t' || turn_index || ':u',
         false, ts + INTERVAL 1 MILLISECOND, 'db.turn.assistant',
         NULL, 'model', nullif(assistant_response, '') AS text, false
  FROM db_turns
),
unioned AS (
  SELECT * FROM ev_msgs UNION ALL BY NAME SELECT * FROM db_msgs
)
SELECT
  u.message_id,
  u.session_id,
  u.role,
  u.parent_id,
  u.is_sidechain,
  false                                                                   AS is_meta,
  u.timestamp,
  u.record_type,
  u.api_message_id,
  u.origin,
  u.text,
  u.interrupted,
  'copilot'                                                               AS runtime,
  s.date
FROM unioned u
JOIN stg_sessions s ON s.session_id = u.session_id;

-- ---------------------------------------------------------------------------
-- stg_api_calls
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_api_calls AS
WITH u AS (
  SELECT
    a.session_id,
    'cp-usage-' || a.id                                                   AS message_id,
    try_cast(replace(a.created_at, 'Z', '') AS timestamp)                 AS timestamp,
    a.model,
    coalesce(a.cache_read_tokens, 0)::bigint                              AS cache_read,
    coalesce(a.cache_write_tokens, 0)::bigint                             AS cache_write,
    greatest(coalesce(a.input_tokens, 0) - coalesce(a.cache_read_tokens, 0)
             - coalesce(a.cache_write_tokens, 0), 0)::bigint              AS input,
    coalesce(a.output_tokens, 0)::bigint                                  AS output
  FROM _cp_raw_db_usage a
)
SELECT
  u.session_id,
  u.message_id,
  NULL::varchar                                                           AS api_message_id,
  NULL::varchar                                                           AS request_id,
  u.timestamp,
  u.model,
  'copilot'                                                               AS provider,
  u.input,
  u.output,
  u.cache_read,
  u.cache_write,
  CASE WHEN p.model IS NOT NULL THEN round(
        u.input       * coalesce(p.input_cost, 0)
      + u.output      * coalesce(p.output_cost, 0)
      + u.cache_read  * coalesce(p.cache_read_cost, 0)
      + u.cache_write * coalesce(p.cache_creation_cost, 0), 6)
       ELSE 0 END                                                         AS cost_usd,
  (p.model IS NULL)                                                       AS unpriced_model,
  'copilot'                                                               AS runtime,
  s.date
FROM u
LEFT JOIN _pricing p ON replace(u.model, '.', '-') = p.model
JOIN stg_sessions s  ON s.session_id = u.session_id
WHERE u.timestamp IS NOT NULL;

-- ---------------------------------------------------------------------------
-- stg_tool_calls
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_tool_calls AS
WITH st AS (
  SELECT session_id, event_id, ts,
         data->>'toolCallId'                                              AS tool_use_id,
         data->>'toolName'                                                AS tool_name,
         (data->'arguments')::varchar                                     AS arguments
  FROM _cp_ev WHERE type = 'tool.execution_start'
),
co AS (
  SELECT session_id, ts,
         data->>'toolCallId'                                              AS tool_use_id,
         try_cast(data->>'success' AS boolean)                            AS success,
         data->'error'->>'code'                                           AS error_code,
         data->'error'->>'message'                                        AS error_message,
         data->'result'->>'content'                                       AS result_text
  FROM _cp_ev WHERE type = 'tool.execution_complete'
  QUALIFY row_number() OVER (PARTITION BY session_id, data->>'toolCallId' ORDER BY ts DESC) = 1
),
pe AS (
  SELECT session_id, data->>'toolCallId'                                  AS tool_use_id,
         data->'result'->>'kind'                                          AS permission
  FROM _cp_ev WHERE type = 'permission.completed'
  QUALIFY row_number() OVER (PARTITION BY session_id, data->>'toolCallId' ORDER BY ts DESC) = 1
),
req_all AS (
  SELECT session_id, event_id AS message_id, ts,
         unnest(json_extract_string(data, '$.toolRequests[*].toolCallId')) AS tool_use_id
  FROM _cp_ev WHERE type = 'assistant.message'
),
req AS (
  SELECT * FROM req_all
  QUALIFY row_number() OVER (PARTITION BY session_id, tool_use_id ORDER BY ts) = 1
)
SELECT
  st.session_id,
  coalesce(req.message_id, st.event_id)                                    AS message_id,
  st.tool_use_id,
  st.tool_name,
  st.ts                                                                    AS started_at,
  co.ts                                                                    AS ended_at,
  CASE WHEN co.ts IS NOT NULL
       THEN datediff('millisecond', st.ts, co.ts) END                      AS duration_ms,
  CASE
    WHEN pe.permission LIKE 'denied%' OR co.error_code = 'denied'          THEN 'denied'
    WHEN pe.permission = 'cancelled'                                       THEN 'cancelled'
    WHEN co.success = false                                                THEN 'error'
    WHEN co.success = true                                                 THEN 'ok'
    ELSE 'running'
  END                                                                      AS outcome,
  st.arguments,
  co.result_text,
  NULL::varchar                                                            AS result_message_id,
  'copilot'                                                                AS runtime,
  s.date
FROM st
LEFT JOIN co  ON co.session_id = st.session_id AND co.tool_use_id = st.tool_use_id
LEFT JOIN pe  ON pe.session_id = st.session_id AND pe.tool_use_id = st.tool_use_id
LEFT JOIN req ON req.session_id = st.session_id AND req.tool_use_id = st.tool_use_id
JOIN stg_sessions s ON s.session_id = st.session_id;

DROP VIEW IF EXISTS _cp_raw_db_usage;
DROP VIEW IF EXISTS _cp_raw_db_turns;
DROP VIEW IF EXISTS _cp_raw_db_sessions;
DROP TABLE IF EXISTS _cp_ev;
