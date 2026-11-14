-- varve-coviant-extensions Mistral Vibe CLI adapter.
-- Normalizes Mistral Vibe session logs into the four core tables:
-- stg_sessions, stg_messages, stg_api_calls, and stg_tool_calls.
--
-- Contract: sql/record.sql (ADR-0009).
-- Depends on sql/prelude.sql: _attr_rules, _pricing, varve_harness(), varve_campaign().
-- Variable set by the build:
--   mirror_dir : folder containing mirrored Vibe logs
--
-- Two layouts are ingested (see docs/decisions/DR-0001):
--   legacy   session_<ts>_<id>/{meta.json, messages.jsonl}  (vibe 2.x)
--   unified  unified/<uuid>/{meta.json?, generations/, chunks/, journal/}
--            (vibe 3.x, store_format mistral.vibe.unified-session-store/v1)

CREATE OR REPLACE TABLE _vibe_meta_raw AS
SELECT
  filename,
  regexp_extract(filename, '([^/]+)/meta\.json$', 1)                           AS dir_key,
  coalesce(nullif(session_id::varchar, ''),
           regexp_extract(filename, '([^/]+)/meta\.json$', 1))                 AS session_id,
  nullif(parent_session_id::varchar, '')                                       AS parent_session_id,
  try_cast(regexp_replace(start_time::varchar, '([+-][0-9]{2}:[0-9]{2}|Z)$', '') AS timestamp) AS started_at,
  try_cast(regexp_replace(end_time::varchar, '([+-][0-9]{2}:[0-9]{2}|Z)$', '') AS timestamp)   AS ended_at,
  git_commit::varchar                                                          AS git_commit,
  git_branch::varchar                                                          AS git_branch,
  environment->>'working_directory'                                            AS cwd,
  title::varchar                                                               AS title,
  coalesce(nullif(config->>'active_model', ''), 'mistral-vibe-unknown')        AS model,
  coalesce(try_cast(stats->>'session_prompt_tokens' AS bigint), 0)              AS prompt_tokens,
  coalesce(try_cast(stats->>'session_completion_tokens' AS bigint), 0)          AS completion_tokens,
  try_cast(stats->>'session_cost' AS double)                                   AS inline_cost
FROM read_json(
  getvariable('mirror_dir') || '/**/meta.json',
  format                  = 'auto',
  columns                 = {
    session_id: 'VARCHAR',
    parent_session_id: 'VARCHAR',
    start_time: 'VARCHAR',
    end_time: 'VARCHAR',
    git_commit: 'VARCHAR',
    git_branch: 'VARCHAR',
    environment: 'JSON',
    title: 'VARCHAR',
    config: 'JSON',
    stats: 'JSON'
  },
  filename                = true,
  ignore_errors           = true,
  maximum_object_size     = 100000000,
  map_inference_threshold = -1
)
WHERE regexp_extract(filename, '([^/]+)/meta\.json$', 1) <> '';

CREATE OR REPLACE TABLE _vibe_messages_raw AS
SELECT
  filename,
  regexp_extract(filename, '([^/]+)/messages\.jsonl$', 1)                      AS dir_key,
  row_number() OVER (PARTITION BY filename)                                    AS line_no,
  role::varchar                                                                AS role,
  content::varchar                                                             AS content,
  coalesce(injected::boolean, false)                                            AS injected,
  message_id::varchar                                                          AS message_id,
  reasoning_content::varchar                                                    AS reasoning_content,
  reasoning_message_id::varchar                                                 AS reasoning_message_id,
  tool_calls::json                                                             AS tool_calls,
  name::varchar                                                                AS name,
  tool_call_id::varchar                                                        AS tool_call_id
FROM read_json(
  getvariable('mirror_dir') || '/**/messages.jsonl',
  format                  = 'newline_delimited',
  columns                 = {
    role: 'VARCHAR',
    content: 'VARCHAR',
    injected: 'BOOLEAN',
    message_id: 'VARCHAR',
    reasoning_content: 'VARCHAR',
    reasoning_message_id: 'VARCHAR',
    tool_calls: 'JSON',
    name: 'VARCHAR',
    tool_call_id: 'VARCHAR'
  },
  filename                = true,
  ignore_errors           = true,
  maximum_object_size     = 100000000,
  map_inference_threshold = -1
)
WHERE regexp_extract(filename, '([^/]+)/messages\.jsonl$', 1) <> '';

-- ---------------------------------------------------------------------------
-- vibe 3.x unified session store (DR-0001)
-- ---------------------------------------------------------------------------
-- Sessions live in unified/<uuid>/ with meta.json (sometimes absent),
-- generations/*/projection-state.json (session identity) and chunks/*.json
-- (arrays of activity entries). Chunk files are snapshot segments: the same
-- entry can reappear in several segments, so every consumer deduplicates.
CREATE OR REPLACE TABLE _vibe_unified_chunks_raw AS
SELECT
  regexp_extract(filename, 'unified/([^/]+)/chunks/', 1)                     AS dir_key,
  coalesce(nullif(sessionId::varchar, ''),
           regexp_extract(filename, 'unified/([^/]+)/chunks/', 1))           AS entry_session,
  type::varchar                                                              AS entry_type,
  coalesce(nullif(role::varchar, ''))                                        AS entry_role,
  nullif(id::varchar, '')                                                    AS entry_id,
  nullif(turnId::varchar, '')                                                AS turn_id,
  turn_index::bigint                                                         AS turn_index,
  createdAt::bigint                                                          AS created_ms,
  updatedAt::bigint                                                          AS updated_ms,
  content::json                                                              AS content,
  message::json                                                              AS message,
  text::varchar                                                              AS reasoning_text,
  detail::json                                                               AS detail,
  state::json                                                                AS state
FROM read_json(
  getvariable('mirror_dir') || '/unified/**/chunks/*.json',
  format                  = 'array',
  columns                 = {
    type: 'VARCHAR',
    role: 'VARCHAR',
    id: 'VARCHAR',
    sessionId: 'VARCHAR',
    turnId: 'VARCHAR',
    turn_index: 'BIGINT',
    createdAt: 'BIGINT',
    updatedAt: 'BIGINT',
    content: 'JSON',
    message: 'JSON',
    text: 'VARCHAR',
    detail: 'JSON',
    state: 'JSON'
  },
  filename                = true,
  ignore_errors           = true,
  maximum_object_size     = 100000000,
  map_inference_threshold = -1
)
WHERE regexp_extract(filename, 'unified/([^/]+)/chunks/', 1) <> '';

CREATE OR REPLACE TABLE _vibe_unified_proj AS
SELECT
  regexp_extract(filename, 'unified/([^/]+)/generations/', 1)                AS dir_key,
  nullif(session_id::varchar, '')                                            AS session_id,
  try_cast(snapshot_sequence::varchar AS bigint)                             AS snapshot_sequence
FROM read_json(
  getvariable('mirror_dir') || '/unified/**/generations/*/projection-state.json',
  format                  = 'auto',
  columns                 = {
    session_id: 'VARCHAR',
    snapshot_sequence: 'BIGINT'
  },
  filename                = true,
  ignore_errors           = true,
  maximum_object_size     = 100000000,
  map_inference_threshold = -1
)
WHERE regexp_extract(filename, 'unified/([^/]+)/generations/', 1) <> '';

-- ---------------------------------------------------------------------------
-- stg_sessions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE _vibe_unified_fallback AS
WITH latest_dir AS (
  SELECT dir_key, session_id
  FROM _vibe_unified_proj
  QUALIFY row_number() OVER (PARTITION BY dir_key ORDER BY snapshot_sequence DESC) = 1
),
covered AS (
  SELECT DISTINCT session_id FROM _vibe_meta_raw WHERE session_id IS NOT NULL
),
first_seen AS (
  SELECT coalesce(l.session_id, c.entry_session)                           AS session_id,
         to_timestamp(min(c.created_ms) / 1000.0)                           AS started_at
  FROM _vibe_unified_chunks_raw c
  LEFT JOIN latest_dir l ON l.dir_key = c.dir_key
  WHERE c.created_ms IS NOT NULL
  GROUP BY 1
)
SELECT
  f.session_id,
  f.dir_key,
  NULL::varchar                                                             AS parent_session_id,
  t.started_at,
  'mistral-vibe-unknown'                                                    AS model
FROM latest_dir f
LEFT JOIN first_seen t USING (session_id)
WHERE f.session_id NOT IN (SELECT session_id FROM covered);

CREATE OR REPLACE TABLE _vibe_session_meta AS
WITH meta_agg AS (
  SELECT
    dir_key,
    session_id,
    parent_session_id,
    min(started_at)                                                            AS started_at,
    max(ended_at)                                                              AS ended_at,
    any_value(cwd)                                                             AS cwd,
    any_value(model)                                                           AS model,
    sum(prompt_tokens)                                                         AS prompt_tokens,
    sum(completion_tokens)                                                     AS completion_tokens,
    sum(inline_cost)                                                           AS inline_cost
  FROM _vibe_meta_raw
  WHERE session_id IS NOT NULL AND started_at IS NOT NULL
  GROUP BY dir_key, session_id, parent_session_id
),
unified AS (
  SELECT
    dir_key,
    session_id,
    parent_session_id,
    started_at,
    NULL::timestamp                                                            AS ended_at,
    NULL::varchar                                                              AS cwd,
    model,
    0::bigint                                                                  AS prompt_tokens,
    0::bigint                                                                  AS completion_tokens,
    NULL::double                                                               AS inline_cost
  FROM _vibe_unified_fallback
  WHERE started_at IS NOT NULL
)
SELECT
  m.*,
  strftime(m.started_at, '%Y-%m-%d')                                           AS date
FROM (
  SELECT * FROM meta_agg
  UNION ALL
  SELECT * FROM unified
) m;

CREATE OR REPLACE TABLE stg_sessions AS
WITH matched AS (
  SELECT s.*, r.estate, r.harness AS harness_tok, r.campaign AS campaign_tok
  FROM _vibe_session_meta s
  LEFT JOIN _attr_rules r
    ON coalesce(s.cwd, '') LIKE replace(r.cwd_glob, '*', '%')
  QUALIFY row_number() OVER (PARTITION BY s.session_id ORDER BY r.priority) = 1
)
SELECT
  session_id,
  'vibe'                                                                       AS runtime,
  cwd,
  varve_harness(cwd, harness_tok)                                              AS harness,
  estate,
  varve_campaign(cwd, campaign_tok)                                            AS campaign,
  started_at,
  parent_session_id,
  NULL::varchar                                                                AS cc_version,
  NULL::varchar                                                                AS pi_version,
  NULL::varchar                                                                AS oc_version,
  NULL::varchar                                                                AS agent,
  date
FROM matched;

-- ---------------------------------------------------------------------------
-- stg_messages
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE _vibe_legacy_messages AS
WITH ordered AS (
  SELECT
    s.session_id,
    coalesce(nullif(m.message_id, ''), s.session_id || ':' || m.line_no)       AS message_id,
    CASE WHEN m.line_no = 1 THEN NULL
         ELSE s.session_id || ':' || (m.line_no - 1)
    END                                                                        AS parent_id,
    s.started_at + (m.line_no - 1) * INTERVAL 1 MILLISECOND                    AS timestamp,
    'message'                                                                  AS record_type,
    m.role,
    CASE
      WHEN m.role = 'tool'      THEN 'tool_result'
      WHEN m.role = 'user'      THEN 'operator'
      WHEN m.role = 'assistant' THEN 'model'
      ELSE 'operator'
    END                                                                        AS origin,
    coalesce(
      CASE WHEN m.reasoning_content IS NOT NULL
           THEN m.reasoning_content || '\n' || coalesce(m.content, '')
           ELSE m.content END,
      m.content
    )                                                                          AS text,
    (s.parent_session_id IS NOT NULL)                                          AS is_sidechain,
    m.injected                                                                 AS is_meta,
    NULL::varchar                                                              AS api_message_id,
    false                                                                      AS interrupted,
    s.date,
    m.line_no
  FROM _vibe_messages_raw m
  JOIN _vibe_session_meta s ON s.dir_key = m.dir_key
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
  'vibe'                                                                       AS runtime,
  date
FROM ordered
QUALIFY row_number() OVER (PARTITION BY session_id, message_id ORDER BY line_no) = 1;

-- Unified-store conversations (DR-0001). Entry kinds:
--   type='message'  model reply (role/content), content = [{text,type}]
--   type='reasoning' model thinking (top-level text)
--   type=NULL        history item {message:{role,content}, turn_index}
CREATE OR REPLACE TABLE _vibe_unified_messages AS
WITH session_dir AS (
  SELECT dir_key, session_id
  FROM _vibe_unified_proj
  QUALIFY row_number() OVER (PARTITION BY dir_key ORDER BY snapshot_sequence DESC) = 1
),
entries AS (
  SELECT
    coalesce(c.entry_session, l.session_id)                                   AS session_id,
    c.entry_type,
    c.entry_id,
    c.turn_index,
    c.created_ms,
    c.updated_ms,
    c.entry_role,
    c.content,
    c.message,
    c.reasoning_text,
    s.started_at,
    s.date,
    (s.parent_session_id IS NOT NULL)                                         AS is_sidechain,
    CASE
      WHEN c.entry_type IS NULL AND json_type(c.message) = 'OBJECT'
        THEN json_extract_string(c.message, '$.role')
      WHEN c.entry_type = 'message' THEN coalesce(c.entry_role, 'assistant')
      WHEN c.entry_type IS NOT NULL THEN 'assistant'
    END                                                                       AS role,
    CASE
      WHEN c.entry_type = 'reasoning' THEN c.reasoning_text
      WHEN c.entry_type = 'message' THEN
        array_to_string(list_transform(
          coalesce(json_extract(c.content, '$[*]'), cast([] AS JSON[])),
          lambda x: json_extract_string(x, '$.text')), chr(10))
      WHEN c.entry_type IS NULL AND json_type(c.message) = 'OBJECT' THEN
        array_to_string(list_transform(
          coalesce(json_extract(c.message, '$.content[*]'), cast([] AS JSON[])),
          lambda x: json_extract_string(x, '$.text')), chr(10))
    END                                                                       AS text
  FROM _vibe_unified_chunks_raw c
  LEFT JOIN session_dir l ON l.dir_key = c.dir_key
  LEFT JOIN _vibe_session_meta s
    ON s.session_id = coalesce(c.entry_session, l.session_id)
  WHERE coalesce(c.entry_session, l.session_id) IS NOT NULL
    AND (c.entry_type IN ('message', 'reasoning')
         OR (c.entry_type IS NULL AND json_type(c.message) = 'OBJECT'
             AND json_extract_string(c.message, '$.role') IS NOT NULL))
)
SELECT
  coalesce(nullif(entry_id, ''), session_id || ':h' || coalesce(turn_index::varchar, '')) AS message_id,
  session_id,
  role,
  NULL::varchar                                                               AS parent_id,
  is_sidechain,
  false                                                                       AS is_meta,
  coalesce(
    to_timestamp(created_ms / 1000.0),
    started_at + (coalesce(turn_index, 0) + 1) * INTERVAL 1 MILLISECOND
  )                                                                           AS timestamp,
  'message'                                                                   AS record_type,
  NULL::varchar                                                               AS api_message_id,
  CASE WHEN role = 'user' THEN 'operator' ELSE 'model' END                    AS origin,
  text,
  false                                                                       AS interrupted,
  'vibe'                                                                      AS runtime,
  date
FROM entries
WHERE message_id IS NOT NULL AND role IS NOT NULL
QUALIFY row_number() OVER (PARTITION BY session_id, message_id
                           ORDER BY coalesce(updated_ms, created_ms) DESC NULLS LAST) = 1;

CREATE OR REPLACE TABLE stg_messages AS
SELECT
  message_id,
  session_id,
  role,
  coalesce(
    parent_id,
    lag(message_id) OVER (PARTITION BY session_id
                          ORDER BY timestamp, message_id)
  )                                                                           AS parent_id,
  is_sidechain,
  is_meta,
  timestamp,
  record_type,
  api_message_id,
  origin,
  text,
  interrupted,
  runtime,
  date
FROM (
  SELECT *, 0 AS src FROM _vibe_legacy_messages
  UNION ALL
  SELECT *, 1 AS src FROM _vibe_unified_messages
)
QUALIFY row_number() OVER (PARTITION BY session_id, message_id ORDER BY src) = 1;

-- ---------------------------------------------------------------------------
-- stg_api_calls
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE stg_api_calls AS
SELECT
  s.session_id,
  s.session_id || ':1'                                                         AS message_id,
  NULL::varchar                                                                AS api_message_id,
  NULL::varchar                                                                AS request_id,
  s.started_at                                                                 AS timestamp,
  s.model,
  'mistral'                                                                    AS provider,
  s.prompt_tokens                                                              AS input,
  s.completion_tokens                                                          AS output,
  0::bigint                                                                    AS cache_read,
  0::bigint                                                                    AS cache_write,
  coalesce(
    s.inline_cost,
    CASE WHEN p.model IS NOT NULL
         THEN round(s.prompt_tokens * coalesce(p.input_cost, 0) + s.completion_tokens * coalesce(p.output_cost, 0), 6)
         ELSE 0 END
  )                                                                            AS cost_usd,
  (s.inline_cost IS NULL AND p.model IS NULL)                                  AS unpriced_model,
  'vibe'                                                                       AS runtime,
  s.date
FROM _vibe_session_meta s
LEFT JOIN _pricing p ON s.model = p.model
WHERE s.prompt_tokens > 0 OR s.completion_tokens > 0 OR s.inline_cost IS NOT NULL;

-- ---------------------------------------------------------------------------
-- stg_tool_calls
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE _vibe_legacy_tool_calls AS
WITH unnested AS (
  SELECT
    req.dir_key,
    req.line_no                                                                AS req_line_no,
    req.message_id                                                             AS req_message_id,
    tc_idx,
    tc
  FROM _vibe_messages_raw req,
  LATERAL (
    SELECT unnest(cast(req.tool_calls AS json[]))                             AS tc,
           generate_subscripts(cast(req.tool_calls AS json[]), 1)              AS tc_idx
  )
  WHERE req.role = 'assistant'
    AND req.tool_calls IS NOT NULL
    AND json_type(req.tool_calls) = 'ARRAY'
),
paired AS (
  SELECT
    u.dir_key,
    u.req_line_no,
    u.req_message_id,
    u.tc_idx,
    u.tc,
    res.line_no                                                                AS res_line_no,
    res.message_id                                                             AS res_message_id,
    res.name                                                                   AS res_name,
    res.content                                                                AS res_content
  FROM unnested u
  LEFT JOIN _vibe_messages_raw res
    ON res.dir_key = u.dir_key
   AND res.role = 'tool'
   AND res.tool_call_id = json_extract_string(u.tc, '$.id')
  QUALIFY row_number() OVER (PARTITION BY u.dir_key, u.req_line_no, u.tc_idx ORDER BY res.line_no) = 1
),
timed AS (
  SELECT
    s.session_id,
    coalesce(nullif(p.req_message_id, ''), s.session_id || ':' || p.req_line_no) AS message_id,
    coalesce(json_extract_string(p.tc, '$.id'), s.session_id || ':' || p.req_line_no || ':' || p.tc_idx) AS tool_use_id,
    coalesce(json_extract_string(p.tc, '$.function.name'), p.res_name)         AS tool_name,
    json_extract_string(p.tc, '$.function.arguments')                          AS arguments,
    s.started_at + (p.req_line_no - 1) * INTERVAL 1 MILLISECOND               AS started_at,
    CASE WHEN p.res_line_no IS NOT NULL
         THEN s.started_at + (p.res_line_no - 1) * INTERVAL 1 MILLISECOND
    END                                                                        AS ended_at,
    p.res_line_no,
    p.res_message_id,
    p.res_content,
    s.date
  FROM paired p
  JOIN _vibe_session_meta s ON s.dir_key = p.dir_key
)
SELECT
  session_id,
  message_id,
  tool_use_id,
  tool_name,
  started_at,
  ended_at,
  CASE WHEN ended_at IS NOT NULL AND ended_at >= started_at
       THEN datediff('millisecond', started_at, ended_at)
  END                                                                          AS duration_ms,
  CASE
    WHEN coalesce(res_content, '') ILIKE '%rejected by user%'
      OR coalesce(res_content, '') ILIKE '%user rejected%'
      OR coalesce(res_content, '') ILIKE '%user denied%'
      OR coalesce(res_content, '') ILIKE '%hook denied%'
      OR coalesce(res_content, '') ILIKE '%Tool execution rejected%'           THEN 'denied'
    WHEN regexp_matches(coalesce(res_content, ''), 'returncode:\s*[1-9][0-9]*')
      OR coalesce(res_content, '') ILIKE 'Error:%'                             THEN 'error'
    WHEN res_line_no IS NOT NULL                                               THEN 'ok'
    ELSE 'running'
  END                                                                          AS outcome,
  arguments,
  res_content                                                                  AS result_text,
  CASE WHEN res_line_no IS NOT NULL
       THEN coalesce(nullif(res_message_id, ''), session_id || ':' || res_line_no)
  END                                                                          AS result_message_id,
  'vibe'                                                                       AS runtime,
  date
FROM timed
WHERE tool_name IS NOT NULL
QUALIFY row_number() OVER (PARTITION BY session_id, tool_use_id ORDER BY started_at) = 1;

-- Unified-store tool effects (DR-0001): entries of type='effect' with
-- detail.kind='tool'. state.decision gates execution, state.output carries
-- the settled result.
CREATE OR REPLACE TABLE _vibe_unified_tool_calls AS
WITH session_dir AS (
  SELECT dir_key, session_id
  FROM _vibe_unified_proj
  QUALIFY row_number() OVER (PARTITION BY dir_key ORDER BY snapshot_sequence DESC) = 1
),
entries AS (
  SELECT
    coalesce(c.entry_session, l.session_id)                                   AS session_id,
    c.entry_id,
    c.created_ms,
    c.updated_ms,
    json_extract_string(c.detail, '$.toolName')                               AS tool_name,
    coalesce(nullif(json_extract_string(c.detail, '$.toolCallId'), ''),
             c.entry_id)                                                      AS tool_use_id,
    c.detail->'input'                                                         AS arguments,
    c.state->>'decision'                                                      AS decision,
    try_cast(json_extract_string(c.state, '$.output.structured_content.returncode') AS bigint) AS returncode,
    json_extract_string(c.state, '$.display.success')                         AS display_success,
    coalesce(
      nullif(c.state->'output'->>'structured_content', ''),
      c.state->>'output'
    )                                                                         AS result_text,
    s.date
  FROM _vibe_unified_chunks_raw c
  LEFT JOIN session_dir l ON l.dir_key = c.dir_key
  LEFT JOIN _vibe_session_meta s
    ON s.session_id = coalesce(c.entry_session, l.session_id)
  WHERE c.entry_type = 'effect'
    AND json_extract_string(c.detail, '$.kind') = 'tool'
    AND coalesce(c.entry_session, l.session_id) IS NOT NULL
)
SELECT
  session_id,
  coalesce(nullif(entry_id, ''), session_id || ':' || coalesce(tool_use_id, ''),
           session_id || ':' || created_ms)                                   AS message_id,
  tool_use_id,
  tool_name,
  to_timestamp(created_ms / 1000.0)                                           AS started_at,
  CASE WHEN updated_ms IS NOT NULL AND updated_ms >= created_ms
       THEN to_timestamp(updated_ms / 1000.0)
  END                                                                         AS ended_at,
  CASE WHEN updated_ms IS NOT NULL AND updated_ms >= created_ms
       THEN updated_ms - created_ms
  END                                                                         AS duration_ms,
  CASE
    WHEN decision IN ('deny', 'skip')                                         THEN 'denied'
    WHEN returncode > 0
      OR display_success = 'false'                                            THEN 'error'
    WHEN updated_ms IS NOT NULL OR returncode = 0                             THEN 'ok'
    ELSE 'running'
  END                                                                         AS outcome,
  nullif(arguments::varchar, 'null')                                          AS arguments,
  result_text,
  NULL::varchar                                                               AS result_message_id,
  'vibe'                                                                      AS runtime,
  date
FROM entries
WHERE tool_name IS NOT NULL
QUALIFY row_number() OVER (PARTITION BY session_id, tool_use_id ORDER BY coalesce(updated_ms, created_ms) DESC NULLS LAST) = 1;

CREATE OR REPLACE TABLE stg_tool_calls AS
SELECT * FROM _vibe_legacy_tool_calls
UNION ALL
SELECT * FROM _vibe_unified_tool_calls;

DROP TABLE IF EXISTS _vibe_unified_tool_calls;
DROP TABLE IF EXISTS _vibe_session_meta;
DROP TABLE IF EXISTS _vibe_unified_messages;
DROP TABLE IF EXISTS _vibe_unified_fallback;
DROP TABLE IF EXISTS _vibe_unified_proj;
DROP TABLE IF EXISTS _vibe_unified_chunks_raw;
DROP TABLE IF EXISTS _vibe_messages_raw;
DROP TABLE IF EXISTS _vibe_meta_raw;
