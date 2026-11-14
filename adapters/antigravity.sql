-- varve-coviant-extensions Google Antigravity adapter.
-- Normalizes Antigravity CLI and IDE conversation transcripts into the four
-- core tables: stg_sessions, stg_messages, stg_api_calls, and stg_tool_calls.
--
-- Contract: sql/record.sql (ADR-0009).
-- Depends on sql/prelude.sql: _attr_rules, _pricing, varve_harness(), varve_campaign().
-- Variable set by the build:
--   mirror_dir : folder containing mirrored Antigravity logs

CREATE OR REPLACE TABLE _agy_scan AS
SELECT
  regexp_extract(filename, '([^/]+)/\.system_generated', 1)    AS session_id,
  filename,
  step_index::bigint                                           AS step_index,
  source::varchar                                              AS source,
  type::varchar                                                AS type,
  status::varchar                                              AS status,
  try_cast(replace(created_at::varchar, 'Z', '') AS timestamp) AS ts,
  content::varchar                                             AS content,
  thinking::varchar                                            AS thinking,
  tool_calls::json                                             AS tool_calls,
  input_tokens::bigint                                         AS input_tokens,
  cache_read_tokens::bigint                                    AS cache_read_tokens,
  output_tokens::bigint                                        AS output_tokens,
  exit_code::bigint                                            AS exit_code,
  error::varchar                                               AS error,
  error_code::varchar                                          AS error_code
FROM read_json(
  getvariable('mirror_dir') || '/**/transcript*.jsonl',
  format                  = 'newline_delimited',
  columns                 = {
    step_index: 'BIGINT',
    source: 'VARCHAR',
    type: 'VARCHAR',
    status: 'VARCHAR',
    created_at: 'VARCHAR',
    content: 'VARCHAR',
    thinking: 'VARCHAR',
    tool_calls: 'JSON',
    input_tokens: 'BIGINT',
    cache_read_tokens: 'BIGINT',
    output_tokens: 'BIGINT',
    exit_code: 'BIGINT',
    error: 'VARCHAR',
    error_code: 'VARCHAR'
  },
  filename                = true,
  ignore_errors           = true,
  maximum_object_size     = 100000000,
  map_inference_threshold = -1
)
WHERE regexp_extract(filename, '([^/]+)/\.system_generated', 1) <> '';

-- Prefer transcript_full.jsonl per session when present; fall back to transcript.jsonl.
CREATE OR REPLACE TABLE _agy_raw AS
WITH pref AS (
  SELECT session_id,
         max_by(filename, CASE WHEN filename LIKE '%/transcript_full.jsonl' THEN 2 ELSE 1 END) AS chosen_file
  FROM (SELECT DISTINCT session_id, filename FROM _agy_scan)
  GROUP BY session_id
)
SELECT s.*
FROM _agy_scan s
JOIN pref p ON s.session_id = p.session_id AND s.filename = p.chosen_file
WHERE s.step_index IS NOT NULL AND s.ts IS NOT NULL
QUALIFY row_number() OVER (PARTITION BY s.session_id, s.step_index ORDER BY s.ts) = 1;

-- ---------------------------------------------------------------------------
-- stg_sessions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_sessions AS
WITH first_steps AS (
  SELECT
    session_id,
    min(ts)                                                    AS started_at,
    min_by(content, step_index)                                AS first_content,
    min_by(type, step_index)                                   AS first_type,
    min_by(source, step_index)                                 AS first_source
  FROM _agy_raw
  GROUP BY session_id
),
meta AS (
  SELECT
    session_id,
    started_at,
    -- Extract working directory from prompt wrapper or system context
    coalesce(
      nullif(regexp_extract(first_content, 'Active Workspaces:\n- ([^\n]+)', 1), ''),
      nullif(regexp_extract(first_content, 'Command Working Directory: ([^\n]+)', 1), ''),
      nullif(regexp_extract(first_content, 'cwd: "([^"]+)"', 1), '')
    )                                                          AS cwd,
    -- Subagents record their parent conversation ID in sender=<uuid>
    CASE
      WHEN first_source = 'SYSTEM' AND first_content LIKE '%sender=%'
      THEN nullif(regexp_extract(first_content, 'sender=([0-9a-fA-F-]{36})', 1), '')
    END                                                        AS parent_session_id
  FROM first_steps
),
matched AS (
  SELECT m.*, r.estate, r.harness AS harness_tok, r.campaign AS campaign_tok
  FROM meta m
  LEFT JOIN _attr_rules r
    ON coalesce(m.cwd, '') LIKE replace(r.cwd_glob, '*', '%')
  QUALIFY row_number() OVER (PARTITION BY m.session_id ORDER BY r.priority) = 1
)
SELECT
  session_id,
  'antigravity'                                                AS runtime,
  cwd,
  varve_harness(cwd, harness_tok)                              AS harness,
  estate,
  varve_campaign(cwd, campaign_tok)                            AS campaign,
  started_at,
  parent_session_id,
  NULL::varchar                                                AS cc_version,
  NULL::varchar                                                AS pi_version,
  NULL::varchar                                                AS oc_version,
  NULL::varchar                                                AS agent,
  strftime(started_at, '%Y-%m-%d')                             AS date
FROM matched;

-- ---------------------------------------------------------------------------
-- stg_messages
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_messages AS
WITH parsed AS (
  SELECT
    r.session_id,
    r.session_id || ':' || r.step_index                        AS message_id,
    CASE
      WHEN r.step_index = 0 THEN NULL
      ELSE r.session_id || ':' || (r.step_index - 1)
    END                                                        AS parent_id,
    r.ts                                                       AS timestamp,
    r.type                                                     AS record_type,
    CASE
      WHEN r.source = 'USER_EXPLICIT' THEN 'user'
      WHEN r.source = 'SYSTEM' THEN 'user'
      ELSE 'assistant'
    END                                                        AS role,
    CASE
      WHEN r.source = 'MODEL' AND r.type <> 'PLANNER_RESPONSE' THEN 'tool_result'
      WHEN r.source IN ('USER_EXPLICIT', 'SYSTEM')             THEN 'operator'
      ELSE 'model'
    END                                                        AS origin,
    -- Clean text (strip protocol wrappers from operator request)
    CASE
      WHEN r.content LIKE '%<USER_REQUEST>%'
      THEN regexp_extract(r.content, '<USER_REQUEST>(.*?)</USER_REQUEST>', 1)
      ELSE r.content
    END                                                        AS text,
    (s.parent_session_id IS NOT NULL)                          AS is_sidechain,
    (r.source = 'SYSTEM')                                      AS is_meta,
    NULL::varchar                                              AS api_message_id,
    false                                                      AS interrupted,
    s.date
  FROM _agy_raw r
  JOIN stg_sessions s ON s.session_id = r.session_id
)
SELECT
  message_id,
  session_id,
  role,
  parent_id,
  is_sidechain,
  is_meta,
  timestamp,
  record_type,
  api_message_id,
  origin,
  text,
  interrupted,
  'antigravity'                                                AS runtime,
  date
FROM parsed
QUALIFY row_number() OVER (PARTITION BY session_id, message_id ORDER BY timestamp) = 1;

-- ---------------------------------------------------------------------------
-- stg_api_calls
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_api_calls AS
WITH token_steps AS (
  SELECT
    r.session_id,
    r.session_id || ':' || r.step_index                        AS message_id,
    r.ts                                                       AS timestamp,
    -- Detect selected model from step content / settings change or default
    coalesce(
      nullif(regexp_extract(r.content, 'model: "([^"]+)"', 1), ''),
      nullif(regexp_extract(r.content, 'Model: "([^"]+)"', 1), ''),
      'gemini-2.5-pro'
    )                                                          AS model,
    'google'                                                   AS provider,
    coalesce(r.input_tokens, 0)                                AS input,
    coalesce(r.output_tokens, 0)                               AS output,
    coalesce(r.cache_read_tokens, 0)                           AS cache_read,
    0::bigint                                                  AS cache_write
  FROM _agy_raw r
  WHERE (coalesce(r.input_tokens, 0) + coalesce(r.output_tokens, 0) + coalesce(r.cache_read_tokens, 0)) > 0
     OR r.type = 'PLANNER_RESPONSE'
)
SELECT
  t.session_id,
  t.message_id,
  NULL::varchar                                                AS api_message_id,
  NULL::varchar                                                AS request_id,
  t.timestamp,
  t.model,
  t.provider,
  t.input,
  t.output,
  t.cache_read,
  t.cache_write,
  round(
      t.input       * coalesce(p.input_cost, 0)
    + t.output      * coalesce(p.output_cost, 0)
    + t.cache_read  * coalesce(p.cache_read_cost, 0)
    + t.cache_write * coalesce(p.cache_creation_cost, 0), 6)   AS cost_usd,
  (p.model IS NULL)                                            AS unpriced_model,
  'antigravity'                                                AS runtime,
  s.date
FROM token_steps t
LEFT JOIN _pricing p ON t.model = p.model
JOIN stg_sessions s ON s.session_id = t.session_id
QUALIFY row_number() OVER (PARTITION BY t.session_id, t.message_id ORDER BY t.timestamp) = 1;

-- ---------------------------------------------------------------------------
-- stg_tool_calls
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE _agy_planner_tools AS
SELECT
  r.session_id,
  r.step_index,
  r.ts AS started_at,
  coalesce(
    (SELECT min(r2.step_index) FROM _agy_raw r2
     WHERE r2.session_id = r.session_id
       AND r2.step_index > r.step_index
       AND (r2.type IN ('PLANNER_RESPONSE', 'USER_INPUT') OR r2.source <> 'MODEL')),
    999999999
  ) AS next_turn_step,
  r.tool_calls
FROM _agy_raw r
WHERE r.type = 'PLANNER_RESPONSE'
  AND r.tool_calls IS NOT NULL
  AND json_type(r.tool_calls) = 'ARRAY';

CREATE OR REPLACE TABLE stg_tool_calls AS
WITH unnested AS (
  SELECT
    p.session_id,
    p.step_index,
    p.started_at,
    p.next_turn_step,
    tc_idx,
    tc
  FROM _agy_planner_tools p,
  LATERAL (
    SELECT unnest(cast(p.tool_calls AS json[])) AS tc,
           generate_subscripts(cast(p.tool_calls AS json[]), 1) AS tc_idx
  )
),
paired AS (
  SELECT
    u.session_id,
    u.session_id || ':' || u.step_index                        AS message_id,
    coalesce(u.tc->>'id', u.session_id || ':' || u.step_index || ':' || u.tc_idx) AS tool_use_id,
    coalesce(u.tc->>'name', u.tc->>'tool_name')               AS tool_name,
    coalesce((u.tc->'args')::varchar, (u.tc->'arguments')::varchar) AS arguments,
    u.started_at,
    res.ts                                                     AS ended_at,
    coalesce(res.status, u.tc->>'status')                      AS raw_status,
    res.exit_code                                              AS exit_code,
    coalesce(res.error_code, u.tc->>'error_code')             AS error_code,
    coalesce(res.error, u.tc->>'error')                       AS error_message,
    coalesce(res.content, (u.tc->'result')::varchar)          AS result_text,
    CASE
      WHEN res.step_index IS NOT NULL THEN u.session_id || ':' || res.step_index
    END                                                        AS result_message_id
  FROM unnested u
  LEFT JOIN _agy_raw res
    ON res.session_id = u.session_id
   AND res.step_index = u.step_index + u.tc_idx
   AND res.step_index < u.next_turn_step
   AND res.source = 'MODEL'
   AND res.type <> 'PLANNER_RESPONSE'
)
SELECT
  p.session_id,
  p.message_id,
  p.tool_use_id,
  p.tool_name,
  p.started_at,
  p.ended_at,
  CASE WHEN p.ended_at IS NOT NULL AND p.ended_at >= p.started_at
       THEN datediff('millisecond', p.started_at, p.ended_at) END AS duration_ms,
  CASE
    WHEN lower(coalesce(p.error_code, '')) IN ('denied', 'permission_denied', 'user_denied')
      OR coalesce(p.error_message, '') ILIKE '%denied%'
      OR coalesce(p.error_message, '') ILIKE '%rejected%'
      OR coalesce(p.result_text, '') ILIKE '%user denied%'     THEN 'denied'
    WHEN coalesce(p.raw_status, '') IN ('ERROR', 'INVALID')
      OR coalesce(p.exit_code, 0) <> 0
      OR p.error_message IS NOT NULL                           THEN 'error'
    WHEN coalesce(p.raw_status, '') = 'RUNNING'                THEN 'running'
    ELSE 'ok'
  END                                                          AS outcome,
  p.arguments,
  p.result_text,
  p.result_message_id,
  'antigravity'                                                AS runtime,
  s.date
FROM paired p
JOIN stg_sessions s ON s.session_id = p.session_id
WHERE p.tool_name IS NOT NULL
QUALIFY row_number() OVER (PARTITION BY p.session_id, p.tool_use_id ORDER BY p.started_at) = 1;

DROP TABLE IF EXISTS _agy_planner_tools;
DROP TABLE IF EXISTS _agy_raw;
DROP TABLE IF EXISTS _agy_scan;
