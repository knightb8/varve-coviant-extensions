-- varve-coviant-extensions OpenCode dual-schema adapter.
-- Normalizes both OpenCode V1 (session, message, part) and V2 (session_v2,
-- session_message) into the four core tables: stg_sessions, stg_messages,
-- stg_api_calls, and stg_tool_calls.
--
-- Contract: sql/record.sql (ADR-0009).
-- Depends on sql/prelude.sql: _attr_rules, _pricing, varve_harness(), varve_campaign().
-- Variable set by the build:
--   mirror_dir : folder containing mirrored opencode.db

INSTALL sqlite;
LOAD sqlite;

-- ---------------------------------------------------------------------------
-- Safe SQLite scans for V1 and V2 tables
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW oc_session AS
SELECT * FROM sqlite_scan(getvariable('mirror_dir') || '/opencode.db', 'session');

CREATE OR REPLACE VIEW oc_message AS
SELECT * FROM sqlite_scan(getvariable('mirror_dir') || '/opencode.db', 'message');

CREATE OR REPLACE VIEW oc_part AS
SELECT * FROM sqlite_scan(getvariable('mirror_dir') || '/opencode.db', 'part');

-- Optional V2 tables (stubbed if database does not contain V2 tables)
CREATE OR REPLACE VIEW oc_session_v2 AS
SELECT * FROM (
  SELECT id::varchar AS id, parent_id::varchar AS parent_id, directory::varchar AS directory,
         version::varchar AS version, agent::varchar AS agent, time_created::bigint AS time_created
  FROM sqlite_scan(getvariable('mirror_dir') || '/opencode.db', 'session_v2')
) WHERE true;

CREATE OR REPLACE VIEW oc_session_message AS
SELECT * FROM (
  SELECT id::varchar AS id, session_id::varchar AS session_id, time_created::bigint AS time_created,
         data::varchar AS data, type::varchar AS type
  FROM sqlite_scan(getvariable('mirror_dir') || '/opencode.db', 'session_message')
) WHERE true;

-- ---------------------------------------------------------------------------
-- stg_sessions: Union session_v2 with session for older sessions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_sessions AS
WITH raw_v2 AS (
  SELECT id::varchar                       AS session_id,
         directory                         AS cwd,
         to_timestamp(time_created/1000.0) AS started_at,
         parent_id::varchar                AS parent_session_id,
         version                           AS oc_version,
         agent                             AS agent
  FROM oc_session_v2
  WHERE time_created IS NOT NULL
),
raw_v1 AS (
  SELECT id::varchar                       AS session_id,
         directory                         AS cwd,
         to_timestamp(time_created/1000.0) AS started_at,
         parent_id::varchar                AS parent_session_id,
         version                           AS oc_version,
         agent                             AS agent
  FROM oc_session
  WHERE time_created IS NOT NULL
    AND id::varchar NOT IN (SELECT session_id FROM raw_v2)
),
base AS (
  SELECT * FROM raw_v2
  UNION ALL
  SELECT * FROM raw_v1
),
matched AS (
  SELECT b.*, r.estate, r.harness AS harness_tok, r.campaign AS campaign_tok
  FROM base b
  LEFT JOIN _attr_rules r
    ON coalesce(b.cwd,'') LIKE replace(r.cwd_glob, '*', '%')
  QUALIFY row_number() OVER (PARTITION BY b.session_id ORDER BY r.priority) = 1
)
SELECT
  session_id,
  'opencode'                            AS runtime,
  cwd,
  varve_harness(cwd, harness_tok)       AS harness,
  estate,
  varve_campaign(cwd, campaign_tok)     AS campaign,
  started_at::timestamp                 AS started_at,
  parent_session_id,
  NULL::varchar                         AS cc_version,
  NULL::varchar                         AS pi_version,
  oc_version,
  agent,
  strftime(started_at, '%Y-%m-%d')      AS date
FROM matched;

-- ---------------------------------------------------------------------------
-- stg_messages: V1 message+part + V2 session_message
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_messages AS
WITH txt_v1 AS (
  SELECT message_id,
         string_agg(json_extract_string(data, '$.text'), '\n' ORDER BY time_created, id) AS txt,
         bool_and(coalesce(json_extract(data, '$.synthetic')::boolean, false))           AS all_synthetic
  FROM oc_part
  WHERE json_extract_string(data, '$.type') IN ('text', 'reasoning')
  GROUP BY message_id
),
has_tool_v1 AS (
  SELECT DISTINCT message_id
  FROM oc_part
  WHERE json_extract_string(data, '$.type') = 'tool'
),
msgs_v1 AS (
  SELECT
    m.id::varchar                                        AS message_id,
    m.session_id::varchar                                AS session_id,
    json_extract_string(m.data, '$.role')                AS role,
    NULL::varchar                                        AS parent_id,
    (s.parent_session_id IS NOT NULL)                    AS is_sidechain,
    coalesce(t.all_synthetic, false)                     AS is_meta,
    to_timestamp(m.time_created/1000.0)::timestamp       AS timestamp,
    'message'                                            AS record_type,
    NULL::varchar                                        AS api_message_id,
    CASE
      WHEN h.message_id IS NOT NULL THEN 'tool_result'
      WHEN json_extract_string(m.data, '$.role') = 'user' THEN 'operator'
      WHEN json_extract_string(m.data, '$.role') = 'assistant' THEN 'model'
      ELSE 'operator'
    END                                                  AS origin,
    t.txt                                                AS text,
    NULL::boolean                                        AS interrupted,
    s.date
  FROM oc_message m
  JOIN stg_sessions s ON m.session_id::varchar = s.session_id
  LEFT JOIN txt_v1 t ON m.id = t.message_id
  LEFT JOIN has_tool_v1 h ON m.id = h.message_id
),
txt_v2 AS (
  SELECT
    sm.id                                                AS message_id,
    string_agg(
      coalesce(json_extract_string(elem.value, '$.text'), json_extract_string(elem.value, '$.content')),
      '\n'
    )                                                    AS txt,
    bool_and(coalesce(json_extract(elem.value, '$.synthetic')::boolean, false)) AS all_synthetic,
    bool_or(json_extract_string(elem.value, '$.type') = 'tool') AS has_tool
  FROM oc_session_message sm,
       json_each(json_extract(sm.data, '$.content')) elem
  WHERE sm.session_id NOT IN (SELECT DISTINCT session_id FROM oc_message)
    AND json_extract_string(elem.value, '$.type') IN ('text', 'reasoning', 'tool')
  GROUP BY sm.id
),
msgs_v2 AS (
  SELECT
    sm.id                                                AS message_id,
    sm.session_id                                        AS session_id,
    sm.type                                              AS role,
    NULL::varchar                                        AS parent_id,
    (s.parent_session_id IS NOT NULL)                    AS is_sidechain,
    coalesce(t.all_synthetic, false)                     AS is_meta,
    to_timestamp(sm.time_created/1000.0)::timestamp      AS timestamp,
    'session_message'                                    AS record_type,
    NULL::varchar                                        AS api_message_id,
    CASE
      WHEN coalesce(t.has_tool, false) THEN 'tool_result'
      WHEN sm.type = 'user' THEN 'operator'
      WHEN sm.type = 'assistant' THEN 'model'
      ELSE 'operator'
    END                                                  AS origin,
    t.txt                                                AS text,
    NULL::boolean                                        AS interrupted,
    s.date
  FROM oc_session_message sm
  JOIN stg_sessions s ON sm.session_id = s.session_id
  LEFT JOIN txt_v2 t ON sm.id = t.message_id
  WHERE sm.session_id NOT IN (SELECT DISTINCT session_id FROM oc_message)
),
unioned AS (
  SELECT * FROM msgs_v1
  UNION ALL
  SELECT * FROM msgs_v2
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
  'opencode'                                             AS runtime,
  date
FROM unioned;

-- ---------------------------------------------------------------------------
-- stg_api_calls: V1 message + V2 session_message assistant records
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_api_calls AS
WITH asst_v1 AS (
  SELECT
    m.session_id::varchar                                        AS session_id,
    m.id::varchar                                                AS message_id,
    to_timestamp(json_extract(m.data,'$.time.created')::bigint/1000.0)::timestamp AS timestamp,
    json_extract_string(m.data,'$.modelID')                      AS model,
    json_extract_string(m.data,'$.providerID')                   AS provider,
    coalesce(json_extract(m.data,'$.tokens.input')::bigint,0)        AS input,
    coalesce(json_extract(m.data,'$.tokens.output')::bigint,0)       AS output,
    coalesce(json_extract(m.data,'$.tokens.cache.read')::bigint,0)   AS cache_read,
    coalesce(json_extract(m.data,'$.tokens.cache.write')::bigint,0)  AS cache_write,
    try_cast(json_extract(m.data,'$.cost') AS double)            AS inline_cost
  FROM oc_message m
  WHERE json_extract_string(m.data,'$.role') = 'assistant'
),
asst_v2 AS (
  SELECT
    sm.session_id                                                AS session_id,
    sm.id                                                        AS message_id,
    to_timestamp(coalesce(
      json_extract(sm.data,'$.time.created')::bigint,
      sm.time_created
    )/1000.0)::timestamp                                         AS timestamp,
    coalesce(json_extract_string(sm.data,'$.model.id'), json_extract_string(sm.data,'$.modelID')) AS model,
    coalesce(json_extract_string(sm.data,'$.model.providerID'), json_extract_string(sm.data,'$.providerID')) AS provider,
    coalesce(json_extract(sm.data,'$.tokens.input')::bigint,0)        AS input,
    coalesce(json_extract(sm.data,'$.tokens.output')::bigint,0)       AS output,
    coalesce(json_extract(sm.data,'$.tokens.cache.read')::bigint,0)   AS cache_read,
    coalesce(json_extract(sm.data,'$.tokens.cache.write')::bigint,0)  AS cache_write,
    try_cast(json_extract(sm.data,'$.cost') AS double)            AS inline_cost
  FROM oc_session_message sm
  WHERE sm.type = 'assistant'
    AND sm.session_id NOT IN (SELECT DISTINCT session_id FROM oc_message)
),
asst AS (
  SELECT * FROM asst_v1
  UNION ALL
  SELECT * FROM asst_v2
)
SELECT
  a.session_id,
  a.message_id,
  NULL::varchar                              AS api_message_id,
  NULL::varchar                              AS request_id,
  a.timestamp,
  a.model,
  a.provider,
  a.input, a.output, a.cache_read, a.cache_write,
  CASE
    WHEN a.inline_cost IS NOT NULL AND a.inline_cost > 0 THEN a.inline_cost
    WHEN p.model IS NOT NULL THEN round(
        a.input       * coalesce(p.input_cost,0)
      + a.output      * coalesce(p.output_cost,0)
      + a.cache_read  * coalesce(p.cache_read_cost,0)
      + a.cache_write * coalesce(p.cache_creation_cost,0), 6)
    ELSE coalesce(a.inline_cost, 0)
  END                                        AS cost_usd,
  (p.model IS NULL)                          AS unpriced_model,
  'opencode'                                 AS runtime,
  ss.date                                    AS date
FROM asst a
LEFT JOIN _pricing p    ON a.model = p.model
JOIN stg_sessions ss    ON a.session_id = ss.session_id;

-- ---------------------------------------------------------------------------
-- stg_tool_calls: V1 part + V2 session_message assistant content elements
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_tool_calls AS
WITH tool_v1 AS (
  SELECT
    session_id::varchar                                    AS session_id,
    message_id::varchar                                    AS message_id,
    json_extract_string(data,'$.callID')                   AS tool_use_id,
    json_extract_string(data,'$.tool')                     AS tool_name,
    json_extract(data,'$.state.time.start')::bigint        AS t_start,
    json_extract(data,'$.state.time.end')::bigint          AS t_end,
    CASE lower(json_extract_string(data,'$.state.status'))
      WHEN 'completed' THEN 'ok'
      WHEN 'error' THEN 'error'
      WHEN 'running' THEN 'running'
      WHEN 'pending' THEN 'running'
      WHEN 'rejected' THEN 'denied'
      WHEN 'denied' THEN 'denied'
      WHEN 'declined' THEN 'denied'
      WHEN 'reject' THEN 'denied'
      WHEN 'deny' THEN 'denied'
    END                                                    AS outcome,
    json_extract(data,'$.state.input')::varchar            AS arguments,
    coalesce(json_extract_string(data,'$.state.output'),
             json_extract_string(data,'$.state.error'))    AS result_text
  FROM oc_part
  WHERE json_extract_string(data,'$.type') = 'tool'
),
tool_v2 AS (
  SELECT
    sm.session_id                                          AS session_id,
    sm.id                                                  AS message_id,
    coalesce(json_extract_string(elem.value,'$.id'), json_extract_string(elem.value,'$.callID')) AS tool_use_id,
    coalesce(json_extract_string(elem.value,'$.name'), json_extract_string(elem.value,'$.tool')) AS tool_name,
    json_extract(elem.value,'$.state.time.start')::bigint  AS t_start,
    json_extract(elem.value,'$.state.time.end')::bigint    AS t_end,
    CASE lower(coalesce(json_extract_string(elem.value,'$.state.status'), json_extract_string(elem.value,'$.status')))
      WHEN 'completed' THEN 'ok'
      WHEN 'error' THEN 'error'
      WHEN 'running' THEN 'running'
      WHEN 'pending' THEN 'running'
      WHEN 'rejected' THEN 'denied'
      WHEN 'denied' THEN 'denied'
      WHEN 'declined' THEN 'denied'
      WHEN 'reject' THEN 'denied'
      WHEN 'deny' THEN 'denied'
      ELSE 'ok'
    END                                                    AS outcome,
    coalesce(json_extract(elem.value,'$.state.input')::varchar, json_extract(elem.value,'$.input')::varchar) AS arguments,
    coalesce(json_extract_string(elem.value,'$.state.output'), json_extract_string(elem.value,'$.output'),
             json_extract_string(elem.value,'$.state.error'), json_extract_string(elem.value,'$.error'))   AS result_text
  FROM oc_session_message sm,
       json_each(json_extract(sm.data, '$.content')) elem
  WHERE sm.type = 'assistant'
    AND json_extract_string(elem.value, '$.type') = 'tool'
    AND sm.session_id NOT IN (SELECT DISTINCT session_id FROM oc_message)
),
tool AS (
  SELECT * FROM tool_v1
  UNION ALL
  SELECT * FROM tool_v2
)
SELECT
  t.session_id,
  t.message_id,
  t.tool_use_id,
  t.tool_name,
  to_timestamp(t.t_start/1000.0)::timestamp                AS started_at,
  to_timestamp(t.t_end/1000.0)::timestamp                  AS ended_at,
  CASE WHEN t.t_start IS NOT NULL AND t.t_end IS NOT NULL
       THEN (t.t_end - t.t_start)::bigint END              AS duration_ms,
  t.outcome,
  t.arguments,
  t.result_text,
  CASE WHEN t.outcome IS NOT NULL AND t.outcome <> 'running' THEN t.message_id END AS result_message_id,
  'opencode'                                               AS runtime,
  ss.date                                                  AS date
FROM tool t
JOIN stg_sessions ss ON t.session_id = ss.session_id;

DROP VIEW IF EXISTS oc_session_message;
DROP VIEW IF EXISTS oc_session_v2;
DROP VIEW IF EXISTS oc_part;
DROP VIEW IF EXISTS oc_message;
DROP VIEW IF EXISTS oc_session;
