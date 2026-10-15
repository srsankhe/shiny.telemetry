--
-- NAS usage-db -- answer-layer schema (indexes, JSON accessors, reporting views)
--
-- WHAT THIS IS
--   shiny.telemetry (Alamar fork, pinned 0.3.1) writes one row per event to
--   public.event_log(time, app_name, session, type, details) on Azure Postgres
--   16. There is no primary key, no index, and `details` is TEXT holding JSON.
--   This file adds read-side infrastructure only: indexes, JSON accessor
--   functions, rollup tables, the user-class rules table, and reporting
--   views. It does not touch event_log's shape and it does not change what
--   NAS writes.
--
-- TWO JSON SHAPES IN `details` (both must parse correctly, forever)
--   1. Legacy / built-in events (login, logout, navigation, input, error,
--      browser) are written by shiny.telemetry itself using
--      jsonlite::toJSON() WITHOUT auto_unbox, so every value is a one-element
--      JSON array: {"username":["a@b.com"]}.
--   2. New domain events (session_context, analysis_opened, model_run, ...)
--      are written by NAS's own helper_telemetry.R with auto_unbox = TRUE, so
--      values are plain JSON scalars: {"analysis_id":"abc123"}. Arrays only
--      appear for genuinely multi-valued fields (e.g. export.formats).
--   ev_text()/ev_int()/ev_bool() below handle both shapes transparently.
--
-- `app_name` IS THE PER-ROW CONTEXT COLUMN, NOT A NAME
--   This database holds one application, so app_name carries context:
--   New:  "<ENVIRONMENT>/<version>/<pod>"  e.g. "PROD/v2.0/abc123-0"
--   Old:  "App:nulisa-analysis-software; User Session:<pod>"  (pod only)
--   Older: "nulisa-analysis-software", "demo", "NULISA Analysis Software" (nothing)
--   The pod id is what the NAS account dropdown shows the user and what Log
--   Analytics indexes pod logs by; it is the link from a user's report to logs
--   and to these rows. environment/app_version are NULL on old rows.
--
-- HOW TO APPLY
--   No DDL owner or migration tooling exists for this database (same situation
--   as session-data-db; see cloudUtils/inst/sql/README.md for the general
--   pattern). Apply by hand over VPN:
--
--     psql -h <server>.postgres.database.azure.com -U <admin> \
--          -d nas-test-usage-db -f usage-db.schema.sql
--
--   Apply to nas-test-usage-db FIRST. Only apply to nas-prod-usage-db after
--   verifying against test data (swap -d nas-prod-usage-db and the matching
--   admin role once confirmed).
--
--   This script is idempotent and safe to re-run: functions use
--   CREATE OR REPLACE, views use CREATE OR REPLACE VIEW, indexes use
--   CREATE INDEX IF NOT EXISTS. Re-running after a fresh event_log row shape
--   change (e.g. once the new app_name format ships) is expected and safe.
--
-- GRANTS
--   Not included here -- this repo has no confirmed role names for the
--   usage-db server (session-data-db's nas_test/nas_prod roles are a
--   different database and must not be assumed to apply). Whoever applies
--   this should GRANT SELECT on the v_* views to whatever role the analytics
--   dashboard / analysts connect as. See session-data-db.schema.sql's
--   per-role ACL grants for the pattern to follow.
--
-- ATTRIBUTION CAVEAT (read before trusting analysis_id on a feature event)
--   Feature events (model_run, export, heatmap_run, ...) do not carry their
--   own analysis_id. Every view below attributes one via a LATERAL join to
--   the most recent analysis_opened event in the same session at or before
--   the feature event's time. This assumes one analysis is open at a time
--   per session. If a session opens a second analysis, events between the
--   two `analysis_opened` rows still attribute correctly, but this join does
--   not know whether the first analysis was ever closed -- it always
--   attributes to "most recent opened so far", which is the best available
--   signal given the contract.
--
-- Statement separator for ensure_usage_views(): lines that are exactly "-- @@"
-- split this file into single statements (RPostgres refuses multi-statement
-- strings). psql ignores them.

-- =============================================================================
-- INDEXES
-- =============================================================================
-- event_log has no PK and no index today. All three are read-path indexes;
-- none affect the INSERT-only write path meaningfully at current volume.

CREATE INDEX IF NOT EXISTS idx_event_log_time
    ON public.event_log USING btree ("time");

-- @@
CREATE INDEX IF NOT EXISTS idx_event_log_session
    ON public.event_log USING btree (session);

-- @@
CREATE INDEX IF NOT EXISTS idx_event_log_type_time
    ON public.event_log USING btree (type, "time");

-- =============================================================================
-- JSON ACCESSOR FUNCTIONS
-- =============================================================================

-- @@
-- Safe text -> jsonb cast. Returns NULL instead of raising on NULL or
-- malformed input, so a single bad row never aborts a query over event_log.
CREATE OR REPLACE FUNCTION public.safe_jsonb(raw text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF raw IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN raw::jsonb;
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$$;

-- @@
-- Returns the scalar text value of `key` in a details JSON object, whether
-- the value is a bare scalar (new events, auto_unbox = TRUE) or a
-- one-element array (legacy events, shiny.telemetry's own toJSON). Returns
-- NULL if details is not valid JSON, the key is absent, the value is JSON
-- null, or the array is empty.
CREATE OR REPLACE FUNCTION public.ev_text(details text, key text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $$
DECLARE
    j jsonb;
    v jsonb;
BEGIN
    j := public.safe_jsonb(details);
    IF j IS NULL THEN
        RETURN NULL;
    END IF;

    v := j -> key;
    IF v IS NULL THEN
        RETURN NULL;
    END IF;

    IF jsonb_typeof(v) = 'array' THEN
        IF jsonb_array_length(v) = 0 THEN
            RETURN NULL;
        END IF;
        v := v -> 0;
    END IF;

    IF jsonb_typeof(v) = 'null' THEN
        RETURN NULL;
    END IF;

    IF jsonb_typeof(v) = 'string' THEN
        RETURN v #>> '{}';
    END IF;

    RETURN v::text;
END;
$$;

-- @@
-- Integer wrapper over ev_text(). Returns NULL (not an error) if the scalar
-- is not numeric.
CREATE OR REPLACE FUNCTION public.ev_int(details text, key text)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $$
DECLARE
    t text;
BEGIN
    t := public.ev_text(details, key);
    IF t IS NULL OR t = '' THEN
        RETURN NULL;
    END IF;
    RETURN round(t::numeric)::bigint;
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$$;

-- @@
-- Boolean wrapper over ev_text(). Accepts JSON true/false (-> "true"/"false"
-- text) as well as "1"/"0"/"yes"/"no" defensively. Returns NULL (not an
-- error) if unrecognized.
CREATE OR REPLACE FUNCTION public.ev_bool(details text, key text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $$
DECLARE
    t text;
BEGIN
    t := public.ev_text(details, key);
    IF t IS NULL THEN
        RETURN NULL;
    END IF;
    IF lower(t) IN ('true', 't', '1', 'yes') THEN
        RETURN TRUE;
    ELSIF lower(t) IN ('false', 'f', '0', 'no') THEN
        RETURN FALSE;
    ELSE
        RETURN NULL;
    END IF;
EXCEPTION WHEN others THEN
    RETURN NULL;
END;
$$;

-- =============================================================================
-- v_events -- base view, every row plus parsed JSON and parsed app_name
-- =============================================================================

-- @@
CREATE OR REPLACE VIEW public.v_events AS
SELECT
    e."time",
    e.app_name,
    e.session,
    e.type,
    e.details,
    public.safe_jsonb(e.details) AS details_json,
    CASE WHEN e.app_name ~ '^[^/[:space:]:;]+/[^/]+/[^/]+$'
        THEN upper((regexp_match(e.app_name, '^([^/]+)/([^/]+)/([^/]+)$'))[1])
        ELSE NULL
    END AS environment,
    CASE WHEN e.app_name ~ '^[^/[:space:]:;]+/[^/]+/[^/]+$'
        THEN (regexp_match(e.app_name, '^([^/]+)/([^/]+)/([^/]+)$'))[2]
        ELSE NULL
    END AS app_version,
    CASE
        WHEN e.app_name ~ '^[^/[:space:]:;]+/[^/]+/[^/]+$'
            THEN (regexp_match(e.app_name, '^([^/]+)/([^/]+)/([^/]+)$'))[3]
        WHEN e.app_name ~ 'User Session:'
            THEN trim(regexp_replace(e.app_name, '^.*User Session:', ''))
        ELSE NULL
    END AS pod
FROM public.event_log e;

-- =============================================================================
-- ROLLUP TABLES -- usage_sessions / usage_tab_visits behind v_sessions / v_time_on_tab
-- =============================================================================
-- The legacy v_sessions rebuilt every session from all of event_log on every
-- query (cost O(table), independent of the date window). These tables hold
-- the same columns, refreshed incrementally. They start EMPTY: after the first
-- apply, run the backfill once from an admin psql session with
-- SET statement_timeout = 0:
--   SELECT public.usage_refresh_range('-infinity');
-- Then keep them fresh with SELECT public.usage_refresh(); (pg_cron or the
-- dashboard, which calls it only once usage_sessions has rows).

-- @@
-- jsonb accessor with ev_text() semantics; SQL-inlinable, no exception block.
CREATE OR REPLACE FUNCTION public.ev_jtext(j jsonb, k text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE jsonb_typeof(j -> k)
           WHEN 'array' THEN (j -> k) ->> 0
           WHEN 'null'  THEN NULL
           ELSE j ->> k
         END
$$;

-- @@
-- app_name parser: one regex pass per session instead of three per row.
CREATE OR REPLACE FUNCTION public.usage_parse_app_name(a text, OUT environment text, OUT app_version text, OUT pod text)
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT upper(m[1]), m[2],
         COALESCE(m[3], CASE WHEN a ~ 'User Session:' THEN trim(regexp_replace(a, '^.*User Session:', '')) END)
  FROM (SELECT CASE WHEN a ~ '^[^/[:space:]:;]+/[^/]+/[^/]+$'
                    THEN regexp_match(a, '^([^/]+)/([^/]+)/([^/]+)$') END AS m) t
$$;

-- @@
-- One row per session token. Maintained by usage_refresh*(); v_sessions reads it.
CREATE TABLE IF NOT EXISTS public.usage_sessions (
    session          text PRIMARY KEY,
    login_time       timestamp,
    logout_time      timestamp,
    duration_s       numeric,
    username         text,
    environment      text,
    app_version      text,
    pod              text,
    user_id          text,
    org_id           text,
    browser          text,
    n_events         bigint    NOT NULL,
    n_errors         bigint    NOT NULL,
    first_tab        text,
    last_tab         text,
    last_event_time  timestamp NOT NULL,
    refreshed_at     timestamptz NOT NULL DEFAULT now()
);

-- @@
CREATE INDEX IF NOT EXISTS usage_sessions_login_time_idx ON public.usage_sessions (login_time);

-- @@
CREATE INDEX IF NOT EXISTS usage_sessions_last_event_idx ON public.usage_sessions (last_event_time);

-- @@
-- One row per home_tabset navigation. v_time_on_tab reads it.
CREATE TABLE IF NOT EXISTS public.usage_tab_visits (
    session     text      NOT NULL,
    entered_at  timestamp NOT NULL,
    tab         text,
    left_at     timestamp,
    seconds     numeric
);

-- @@
CREATE INDEX IF NOT EXISTS usage_tab_visits_entered_idx ON public.usage_tab_visits (entered_at);

-- @@
CREATE INDEX IF NOT EXISTS usage_tab_visits_session_idx ON public.usage_tab_visits (session);

-- @@
-- Recompute the rollup rows for the given sessions (idempotent).
CREATE OR REPLACE FUNCTION public.usage_refresh_sessions(p_sessions text[]) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  WITH ev AS (
    SELECT e.session, e."time", e.type, e.app_name,
           CASE WHEN e.type IN ('login','session_context','browser','navigation')
                     AND pg_input_is_valid(e.details, 'jsonb') THEN e.details::jsonb END AS j
    FROM public.event_log e
    WHERE e.session = ANY (p_sessions)
  ), x AS (
    SELECT session,
      min("time") FILTER (WHERE type = 'login')  AS login_time,
      max("time") FILTER (WHERE type = 'logout') AS logout_time,
      (array_agg(app_name ORDER BY "time"))[1]   AS first_app_name,
      (array_agg(public.ev_jtext(j,'username')    ORDER BY "time") FILTER (WHERE type = 'login'))[1]           AS username,
      (array_agg(public.ev_jtext(j,'environment') ORDER BY "time") FILTER (WHERE type = 'session_context'))[1] AS ctx_environment,
      (array_agg(public.ev_jtext(j,'app_version') ORDER BY "time") FILTER (WHERE type = 'session_context'))[1] AS ctx_app_version,
      (array_agg(public.ev_jtext(j,'pod')         ORDER BY "time") FILTER (WHERE type = 'session_context'))[1] AS ctx_pod,
      (array_agg(public.ev_jtext(j,'user_id')     ORDER BY "time") FILTER (WHERE type = 'session_context'))[1] AS user_id,
      (array_agg(public.ev_jtext(j,'org_id')      ORDER BY "time") FILTER (WHERE type = 'session_context'))[1] AS org_id,
      (array_agg(public.ev_jtext(j,'value')       ORDER BY "time") FILTER (WHERE type = 'browser'))[1]         AS browser,
      count(*) AS n_events,
      count(*) FILTER (WHERE type = 'error') AS n_errors,
      (array_agg(public.ev_jtext(j,'value') ORDER BY "time")      FILTER (WHERE type = 'navigation' AND public.ev_jtext(j,'id') = 'home_tabset'))[1] AS first_tab,
      (array_agg(public.ev_jtext(j,'value') ORDER BY "time" DESC) FILTER (WHERE type = 'navigation' AND public.ev_jtext(j,'id') = 'home_tabset'))[1] AS last_tab,
      max("time") AS last_event_time
    FROM ev GROUP BY session
  ), up AS (
    INSERT INTO public.usage_sessions AS u
      (session, login_time, logout_time, duration_s, username, environment, app_version, pod,
       user_id, org_id, browser, n_events, n_errors, first_tab, last_tab, last_event_time, refreshed_at)
    SELECT x.session, x.login_time, x.logout_time,
           EXTRACT(EPOCH FROM (x.logout_time - x.login_time)),
           x.username,
           COALESCE(p.environment, x.ctx_environment),
           COALESCE(p.app_version, x.ctx_app_version),
           COALESCE(p.pod, x.ctx_pod),
           x.user_id, x.org_id, x.browser, x.n_events, x.n_errors, x.first_tab, x.last_tab,
           x.last_event_time, now()
    FROM x, LATERAL public.usage_parse_app_name(x.first_app_name) p
    ON CONFLICT (session) DO UPDATE SET
      login_time = EXCLUDED.login_time, logout_time = EXCLUDED.logout_time, duration_s = EXCLUDED.duration_s,
      username = EXCLUDED.username, environment = EXCLUDED.environment, app_version = EXCLUDED.app_version,
      pod = EXCLUDED.pod, user_id = EXCLUDED.user_id, org_id = EXCLUDED.org_id, browser = EXCLUDED.browser,
      n_events = EXCLUDED.n_events, n_errors = EXCLUDED.n_errors, first_tab = EXCLUDED.first_tab,
      last_tab = EXCLUDED.last_tab, last_event_time = EXCLUDED.last_event_time, refreshed_at = now()
    RETURNING 1
  ), del AS (
    DELETE FROM public.usage_tab_visits WHERE session = ANY (p_sessions) RETURNING 1
  ), nav AS (
    SELECT ev.session, ev."time" AS entered_at, public.ev_jtext(ev.j,'value') AS tab
    FROM ev WHERE ev.type = 'navigation' AND public.ev_jtext(ev.j,'id') = 'home_tabset'
  ), v AS (
    SELECT nav.session, nav.tab, nav.entered_at,
           LEAD(nav.entered_at) OVER (PARTITION BY nav.session ORDER BY nav.entered_at) AS next_at,
           x.logout_time
    FROM nav JOIN x ON x.session = nav.session
  ), ins AS (
    INSERT INTO public.usage_tab_visits (session, entered_at, tab, left_at, seconds)
    SELECT session, entered_at, tab, COALESCE(next_at, logout_time),
           EXTRACT(EPOCH FROM (COALESCE(next_at, logout_time) - entered_at))
    FROM v RETURNING 1
  )
  SELECT count(*) INTO n FROM up;
  RETURN n;
END $$;

-- @@
-- Backfill / reconcile: every session with an event in [p_from, p_to), 2000 per batch.
CREATE OR REPLACE FUNCTION public.usage_refresh_range(p_from timestamp, p_to timestamp DEFAULT 'infinity') RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE s text[]; b text[]; n integer := 0; i integer;
BEGIN
  SELECT array_agg(DISTINCT session) INTO s
  FROM public.event_log WHERE "time" >= p_from AND "time" < p_to AND session IS NOT NULL;
  IF s IS NULL THEN RETURN 0; END IF;
  FOR i IN 1 .. array_length(s, 1) BY 2000 LOOP
    n := n + public.usage_refresh_sessions(s[i : i + 1999]);
  END LOOP;
  RETURN n;
END $$;

-- @@
-- Incremental refresh: sessions with events since (newest rolled-up event - lookback).
-- Returns -1 when another refresh holds the lock.
CREATE OR REPLACE FUNCTION public.usage_refresh(p_lookback interval DEFAULT interval '2 hours') RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE wm timestamp; n integer;
BEGIN
  IF NOT pg_try_advisory_xact_lock(7311427001) THEN RETURN -1; END IF;
  -- LEAST(): a future-dated event must not move the watermark past real traffic.
  SELECT LEAST(max(last_event_time), (now() AT TIME ZONE 'UTC')) - p_lookback INTO wm FROM public.usage_sessions;
  RETURN public.usage_refresh_range(COALESCE(wm, '-infinity'));
END $$;

-- =============================================================================
-- USER CLASS -- who is behind a username: automation, internal, external
-- =============================================================================
-- Rules are data, not code. usage_user_class(username) returns the user_class
-- of the lowest-priority matching rule, 'external' when no rule matches, and
-- 'unknown' for a NULL username (a session with no login row). Patterns are
-- case-insensitive POSIX regexes (~*). The seed below uses ON CONFLICT DO
-- NOTHING, so a re-apply never overwrites an edited rule; change or add rules
-- with plain UPDATE / INSERT in psql.
--   automation : plus-addressed Alamar test accounts (name+test@,
--                name+tester@, name+test_01@ ...). The dashboard queries never
--                count these.
--   internal   : any other @alamarbio.com account. The dashboard's "Include
--                Alamar users" toggle keeps or drops these.
-- v_sessions classifies on read, so a rule edit takes effect on the next
-- query without a rollup refresh.

-- @@
CREATE TABLE IF NOT EXISTS public.usage_user_rules (
    pattern    text PRIMARY KEY,
    user_class text    NOT NULL CHECK (user_class IN ('automation', 'internal')),
    priority   integer NOT NULL,
    note       text
);

-- @@
INSERT INTO public.usage_user_rules (pattern, user_class, priority, note) VALUES
    ('\+test[^@]*@alamarbio\.com$', 'automation', 10, 'Cypress / automation accounts: local part contains +test'),
    ('@alamarbio\.com$',             'internal',   20, 'Alamar staff')
ON CONFLICT (pattern) DO NOTHING;

-- @@
CREATE OR REPLACE FUNCTION public.usage_user_class(username text) RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT CASE
           WHEN username IS NULL THEN 'unknown'
           ELSE COALESCE(
             (SELECT r.user_class
              FROM public.usage_user_rules r
              WHERE username ~* r.pattern
              ORDER BY r.priority, r.pattern
              LIMIT 1),
             'external')
         END
$$;

-- =============================================================================
-- v_sessions -- one row per session token
-- =============================================================================
-- user_class is computed per row from usage_user_rules (see USER CLASS above).
-- environment/app_version/pod come from app_name on every row; session_context
-- is the fallback (and the only source of user_id/org_id). Old rows without
-- environment/version stay NULL for those two columns; pod is still parsed.)
-- user_id/org_id only ever come from session_context -- there is no legacy
-- fallback for opaque ACC ids.

-- @@
CREATE OR REPLACE VIEW public.v_sessions AS
SELECT session, login_time, logout_time, duration_s, username, environment, app_version, pod,
       user_id, org_id, browser, n_events, n_errors, first_tab, last_tab,
       public.usage_user_class(username) AS user_class
FROM public.usage_sessions;

-- ROLLBACK (legacy definition, full scan of event_log per query). To restore,
-- uncomment and run it in psql:
-- CREATE OR REPLACE VIEW public.v_sessions AS
-- WITH sess AS (
--     SELECT DISTINCT session
--     FROM public.event_log
--     WHERE session IS NOT NULL
-- ),
-- login_ev AS (
--     SELECT DISTINCT ON (session)
--         session, "time" AS login_time, ev_text(details, 'username') AS username
--     FROM public.event_log
--     WHERE type = 'login'
--     ORDER BY session, "time" ASC
-- ),
-- logout_ev AS (
--     SELECT DISTINCT ON (session)
--         session, "time" AS logout_time
--     FROM public.event_log
--     WHERE type = 'logout'
--     ORDER BY session, "time" DESC
-- ),
-- ctx_ev AS (
--     SELECT DISTINCT ON (session)
--         session,
--         ev_text(details, 'environment') AS ctx_environment,
--         ev_text(details, 'app_version') AS ctx_app_version,
--         ev_text(details, 'pod') AS ctx_pod,
--         ev_text(details, 'user_id') AS ctx_user_id,
--         ev_text(details, 'org_id') AS ctx_org_id
--     FROM public.event_log
--     WHERE type = 'session_context'
--     ORDER BY session, "time" ASC
-- ),
-- appname_ev AS (
--     SELECT DISTINCT ON (session)
--         session,
--         app_name,
--         environment AS parsed_environment,
--         app_version AS parsed_app_version,
--         pod AS parsed_pod
--     FROM public.v_events
--     WHERE session IS NOT NULL
--     ORDER BY session, "time" ASC
-- ),
-- browser_ev AS (
--     SELECT DISTINCT ON (session)
--         session, ev_text(details, 'value') AS browser
--     FROM public.event_log
--     WHERE type = 'browser'
--     ORDER BY session, "time" ASC
-- ),
-- counts_ev AS (
--     SELECT
--         session,
--         count(*) AS n_events,
--         count(*) FILTER (WHERE type = 'error') AS n_errors
--     FROM public.event_log
--     WHERE session IS NOT NULL
--     GROUP BY session
-- ),
-- first_tab_ev AS (
--     SELECT DISTINCT ON (session)
--         session, ev_text(details, 'value') AS first_tab
--     FROM public.event_log
--     WHERE type = 'navigation' AND ev_text(details, 'id') = 'home_tabset'
--     ORDER BY session, "time" ASC
-- ),
-- last_tab_ev AS (
--     SELECT DISTINCT ON (session)
--         session, ev_text(details, 'value') AS last_tab
--     FROM public.event_log
--     WHERE type = 'navigation' AND ev_text(details, 'id') = 'home_tabset'
--     ORDER BY session, "time" DESC
-- )
-- SELECT
--     s.session,
--     l.login_time,
--     lo.logout_time,
--     EXTRACT(EPOCH FROM (lo.logout_time - l.login_time)) AS duration_s,
--     l.username,
--     COALESCE(a.parsed_environment, c.ctx_environment) AS environment,
--     COALESCE(a.parsed_app_version, c.ctx_app_version) AS app_version,
--     COALESCE(a.parsed_pod, c.ctx_pod) AS pod,
--     c.ctx_user_id AS user_id,
--     c.ctx_org_id AS org_id,
--     b.browser,
--     COALESCE(cnt.n_events, 0) AS n_events,
--     COALESCE(cnt.n_errors, 0) AS n_errors,
--     ft.first_tab,
--     lt.last_tab
-- FROM sess s
-- LEFT JOIN login_ev     l   ON l.session = s.session
-- LEFT JOIN logout_ev    lo  ON lo.session = s.session
-- LEFT JOIN ctx_ev       c   ON c.session = s.session
-- LEFT JOIN appname_ev   a   ON a.session = s.session
-- LEFT JOIN browser_ev   b   ON b.session = s.session
-- LEFT JOIN counts_ev    cnt ON cnt.session = s.session
-- LEFT JOIN first_tab_ev ft  ON ft.session = s.session
-- LEFT JOIN last_tab_ev  lt  ON lt.session = s.session;

-- =============================================================================
-- Typed projections -- one view per domain event, joined to v_sessions
-- =============================================================================

-- @@
CREATE OR REPLACE VIEW public.v_analysis_opened AS
SELECT
    e."time",
    e.session,
    ev_text(e.details, 'analysis_id') AS analysis_id,
    ev_text(e.details, 'mode') AS mode,
    ev_text(e.details, 'source') AS source,
    ev_int(e.details, 'n_plates') AS n_plates,
    ev_int(e.details, 'n_samples') AS n_samples,
    ev_int(e.details, 'n_targets') AS n_targets,
    ev_bool(e.details, 'is_aq') AS is_aq,
    ev_int(e.details, 'duration_ms') AS duration_ms,
    ev_text(e.details, 'status') AS status,
    ev_text(e.details, 'error') AS error,
    s.username, s.environment, s.app_version, s.pod, s.user_id, s.org_id, s.user_class
FROM public.event_log e
JOIN public.v_sessions s ON s.session = e.session
WHERE e.type = 'analysis_opened';

-- @@
CREATE OR REPLACE VIEW public.v_model_runs AS
SELECT
    e."time",
    e.session,
    la.analysis_id,
    ev_text(e.details, 'model_type') AS model_type,
    ev_text(e.details, 'data_type') AS data_type,
    ev_int(e.details, 'n_matrices') AS n_matrices,
    ev_int(e.details, 'n_targets') AS n_targets,
    ev_int(e.details, 'n_samples') AS n_samples,
    ev_int(e.details, 'n_covariates') AS n_covariates,
    ev_int(e.details, 'n_categorical') AS n_categorical,
    ev_int(e.details, 'n_continuous') AS n_continuous,
    ev_int(e.details, 'n_interactions') AS n_interactions,
    ev_int(e.details, 'n_ratios') AS n_ratios,
    ev_bool(e.details, 'zero_npq') AS zero_npq,
    ev_int(e.details, 'duration_ms') AS duration_ms,
    ev_text(e.details, 'status') AS status,
    ev_text(e.details, 'error') AS error,
    s.username, s.environment, s.app_version, s.pod, s.user_id, s.org_id, s.user_class
FROM public.event_log e
JOIN public.v_sessions s ON s.session = e.session
LEFT JOIN LATERAL (
    SELECT ev_text(a.details, 'analysis_id') AS analysis_id
    FROM public.event_log a
    WHERE a.session = e.session
      AND a.type = 'analysis_opened'
      AND a."time" <= e."time"
    ORDER BY a."time" DESC
    LIMIT 1
) la ON TRUE
WHERE e.type = 'model_run';

-- @@
CREATE OR REPLACE VIEW public.v_heatmap_runs AS
-- trigger = 'button' (user clicked Run) or 'tab_return' (NAS re-runs the
-- heatmap when the user returns to the tab). Count only 'button' for
-- "how often do users run heatmaps".
SELECT
    e."time",
    e.session,
    la.analysis_id,
    ev_int(e.details, 'n_samples') AS n_samples,
    ev_int(e.details, 'n_targets') AS n_targets,
    ev_text(e.details, 'opt_scale') AS opt_scale,
    ev_text(e.details, 'opt_split_sample') AS opt_split_sample,
    ev_text(e.details, 'opt_row_dist') AS opt_row_dist,
    ev_text(e.details, 'opt_col_dist') AS opt_col_dist,
    ev_text(e.details, 'trigger') AS trigger,
    ev_int(e.details, 'duration_ms') AS duration_ms,
    ev_text(e.details, 'status') AS status,
    ev_text(e.details, 'error') AS error,
    public.safe_jsonb(e.details) AS details_json,
    s.username, s.environment, s.app_version, s.pod, s.user_id, s.org_id, s.user_class
FROM public.event_log e
JOIN public.v_sessions s ON s.session = e.session
LEFT JOIN LATERAL (
    SELECT ev_text(a.details, 'analysis_id') AS analysis_id
    FROM public.event_log a
    WHERE a.session = e.session
      AND a.type = 'analysis_opened'
      AND a."time" <= e."time"
    ORDER BY a."time" DESC
    LIMIT 1
) la ON TRUE
WHERE e.type = 'heatmap_run';

-- @@
CREATE OR REPLACE VIEW public.v_pathway_runs AS
SELECT
    e."time",
    e.session,
    la.analysis_id,
    ev_text(e.details, 'database') AS database,
    ev_text(e.details, 'rank_by') AS rank_by,
    ev_int(e.details, 'n_pathways') AS n_pathways,
    ev_int(e.details, 'n_significant') AS n_significant,
    ev_int(e.details, 'duration_ms') AS duration_ms,
    ev_text(e.details, 'status') AS status,
    ev_text(e.details, 'error') AS error,
    s.username, s.environment, s.app_version, s.pod, s.user_id, s.org_id, s.user_class
FROM public.event_log e
JOIN public.v_sessions s ON s.session = e.session
LEFT JOIN LATERAL (
    SELECT ev_text(a.details, 'analysis_id') AS analysis_id
    FROM public.event_log a
    WHERE a.session = e.session
      AND a.type = 'analysis_opened'
      AND a."time" <= e."time"
    ORDER BY a."time" DESC
    LIMIT 1
) la ON TRUE
WHERE e.type = 'pathway_run';

-- @@
CREATE OR REPLACE VIEW public.v_qc_exclusions AS
SELECT
    e."time",
    e.session,
    la.analysis_id,
    ev_text(e.details, 'kind') AS kind,
    ev_text(e.details, 'method') AS method,
    ev_text(e.details, 'action') AS action,
    ev_int(e.details, 'n_excluded') AS n_excluded,
    ev_int(e.details, 'n_total') AS n_total,
    s.username, s.environment, s.app_version, s.pod, s.user_id, s.org_id, s.user_class
FROM public.event_log e
JOIN public.v_sessions s ON s.session = e.session
LEFT JOIN LATERAL (
    SELECT ev_text(a.details, 'analysis_id') AS analysis_id
    FROM public.event_log a
    WHERE a.session = e.session
      AND a.type = 'analysis_opened'
      AND a."time" <= e."time"
    ORDER BY a."time" DESC
    LIMIT 1
) la ON TRUE
WHERE e.type = 'qc_exclusion';

-- @@
CREATE OR REPLACE VIEW public.v_exports AS
SELECT
    e."time",
    e.session,
    la.analysis_id,
    ARRAY(
        SELECT jsonb_array_elements_text(
            COALESCE(public.safe_jsonb(e.details) -> 'formats', '[]'::jsonb)
        )
    ) AS formats,
    ev_text(e.details, 'ext') AS ext,
    ev_int(e.details, 'n_samples') AS n_samples,
    ev_int(e.details, 'n_targets') AS n_targets,
    ev_bool(e.details, 'has_model') AS has_model,
    ev_int(e.details, 'duration_ms') AS duration_ms,
    ev_text(e.details, 'status') AS status,
    ev_text(e.details, 'error') AS error,
    s.username, s.environment, s.app_version, s.pod, s.user_id, s.org_id, s.user_class
FROM public.event_log e
JOIN public.v_sessions s ON s.session = e.session
LEFT JOIN LATERAL (
    SELECT ev_text(a.details, 'analysis_id') AS analysis_id
    FROM public.event_log a
    WHERE a.session = e.session
      AND a.type = 'analysis_opened'
      AND a."time" <= e."time"
    ORDER BY a."time" DESC
    LIMIT 1
) la ON TRUE
WHERE e.type = 'export';

-- @@
CREATE OR REPLACE VIEW public.v_downloads AS
SELECT
    e."time",
    e.session,
    la.analysis_id,
    ev_text(e.details, 'what') AS what,
    s.username, s.environment, s.app_version, s.pod, s.user_id, s.org_id, s.user_class
FROM public.event_log e
JOIN public.v_sessions s ON s.session = e.session
LEFT JOIN LATERAL (
    SELECT ev_text(a.details, 'analysis_id') AS analysis_id
    FROM public.event_log a
    WHERE a.session = e.session
      AND a.type = 'analysis_opened'
      AND a."time" <= e."time"
    ORDER BY a."time" DESC
    LIMIT 1
) la ON TRUE
WHERE e.type = 'download';

-- @@
CREATE OR REPLACE VIEW public.v_tours AS
SELECT
    e."time",
    e.session,
    la.analysis_id,
    ev_text(e.details, 'tour') AS tour,
    ev_text(e.details, 'action') AS action,
    ev_int(e.details, 'step') AS step,
    s.username, s.environment, s.app_version, s.pod, s.user_id, s.org_id, s.user_class
FROM public.event_log e
JOIN public.v_sessions s ON s.session = e.session
LEFT JOIN LATERAL (
    SELECT ev_text(a.details, 'analysis_id') AS analysis_id
    FROM public.event_log a
    WHERE a.session = e.session
      AND a.type = 'analysis_opened'
      AND a."time" <= e."time"
    ORDER BY a."time" DESC
    LIMIT 1
) la ON TRUE
WHERE e.type = 'tour';

-- =============================================================================
-- v_feature_events -- long table for adoption/funnel queries
-- =============================================================================
-- One row per analytical/product event (not login/logout/navigation/error/
-- browser, which are session mechanics, not product features).
-- analysis_opened/shared/cloned/deleted carry their own analysis_id; every
-- other feature is attributed via the same LATERAL pattern as the typed
-- views above.

-- @@
CREATE OR REPLACE VIEW public.v_feature_events AS
SELECT
    e."time",
    e.session,
    e.type AS feature,
    ev_text(e.details, 'status') AS status,
    ev_int(e.details, 'duration_ms') AS duration_ms,
    CASE
        WHEN e.type IN ('analysis_opened', 'analysis_shared', 'analysis_cloned', 'analysis_deleted')
            THEN ev_text(e.details, 'analysis_id')
        ELSE la.analysis_id
    END AS analysis_id,
    s.username, s.environment, s.app_version, s.pod, s.user_id, s.org_id, s.user_class
FROM public.event_log e
JOIN public.v_sessions s ON s.session = e.session
LEFT JOIN LATERAL (
    SELECT ev_text(a.details, 'analysis_id') AS analysis_id
    FROM public.event_log a
    WHERE a.session = e.session
      AND a.type = 'analysis_opened'
      AND a."time" <= e."time"
    ORDER BY a."time" DESC
    LIMIT 1
) la ON e.type NOT IN ('analysis_opened', 'analysis_shared', 'analysis_cloned', 'analysis_deleted')
WHERE e.type IN (
    'analysis_opened', 'analysis_shared', 'analysis_cloned', 'analysis_deleted',
    'model_run', 'heatmap_run', 'pathway_run', 'export', 'qc_exclusion',
    'kg_opened', 'download', 'tour'
);

-- =============================================================================
-- v_time_on_tab -- dwell time per top-level tab visit
-- =============================================================================
-- Built-in navigation events with id = 'home_tabset' already flow today
-- (this does not require any new event). left_at falls back to session
-- logout_time for the last tab visited in a session; if the session also has
-- no logout (pod killed), seconds is NULL rather than a guessed value.

-- @@
CREATE OR REPLACE VIEW public.v_time_on_tab AS
SELECT session, tab, entered_at, left_at, seconds
FROM public.usage_tab_visits;

-- ROLLBACK (legacy definition). To restore, uncomment and run it in psql:
-- CREATE OR REPLACE VIEW public.v_time_on_tab AS
-- WITH nav AS (
--     SELECT
--         e.session,
--         e."time" AS entered_at,
--         ev_text(e.details, 'value') AS tab
--     FROM public.event_log e
--     WHERE e.type = 'navigation' AND ev_text(e.details, 'id') = 'home_tabset'
-- )
-- SELECT
--     n.session,
--     n.tab,
--     n.entered_at,
--     COALESCE(
--         LEAD(n.entered_at) OVER (PARTITION BY n.session ORDER BY n.entered_at),
--         s.logout_time
--     ) AS left_at,
--     EXTRACT(EPOCH FROM (
--         COALESCE(
--             LEAD(n.entered_at) OVER (PARTITION BY n.session ORDER BY n.entered_at),
--             s.logout_time
--         ) - n.entered_at
--     )) AS seconds
-- FROM nav n
-- JOIN public.v_sessions s ON s.session = n.session;

-- =============================================================================
-- v_daily_active -- daily active users/sessions/orgs
-- =============================================================================
-- One row per date x environment x user_class, so a reader can drop
-- automation / internal rows before summing. n_users and n_sessions sum
-- cleanly across user_class (a username has exactly one class); n_orgs does
-- not (an org can hold users of more than one class), so sum n_orgs only
-- within one class, or count from v_sessions directly as pu_daily_active does.
-- environment is NULL for legacy rows (see header). n_orgs is NULL-safe
-- (COUNT DISTINCT ignores NULL org_id, which is expected until
-- session_context is flowing).

-- @@
CREATE OR REPLACE VIEW public.v_daily_active AS
SELECT
    date_trunc('day', login_time)::date AS date,
    environment,
    user_class,
    count(DISTINCT username) AS n_users,
    count(DISTINCT session) AS n_sessions,
    count(DISTINCT org_id) AS n_orgs
FROM public.v_sessions
WHERE login_time IS NOT NULL
GROUP BY 1, 2, 3;
