--
-- NAS usage-db -- answer-layer schema (indexes, JSON accessors, reporting views)
--
-- WHAT THIS IS
--   shiny.telemetry (Alamar fork, pinned 0.3.1) writes one row per event to
--   public.event_log(time, app_name, session, type, details) on Azure Postgres
--   16. There is no primary key, no index, and `details` is TEXT holding JSON.
--   This file adds read-side infrastructure only: indexes, JSON accessor
--   functions, and reporting views. It does not touch event_log's shape and
--   it does not change what NAS writes.
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
-- v_sessions -- one row per session token
-- =============================================================================
-- environment/app_version/pod come from app_name on every row; session_context
-- is the fallback (and the only source of user_id/org_id). Old rows without
-- environment/version stay NULL for those two columns; pod is still parsed.)
-- user_id/org_id only ever come from session_context -- there is no legacy
-- fallback for opaque ACC ids.

-- @@
CREATE OR REPLACE VIEW public.v_sessions AS
WITH sess AS (
    SELECT DISTINCT session
    FROM public.event_log
    WHERE session IS NOT NULL
),
login_ev AS (
    SELECT DISTINCT ON (session)
        session, "time" AS login_time, ev_text(details, 'username') AS username
    FROM public.event_log
    WHERE type = 'login'
    ORDER BY session, "time" ASC
),
logout_ev AS (
    SELECT DISTINCT ON (session)
        session, "time" AS logout_time
    FROM public.event_log
    WHERE type = 'logout'
    ORDER BY session, "time" DESC
),
ctx_ev AS (
    SELECT DISTINCT ON (session)
        session,
        ev_text(details, 'environment') AS ctx_environment,
        ev_text(details, 'app_version') AS ctx_app_version,
        ev_text(details, 'pod') AS ctx_pod,
        ev_text(details, 'user_id') AS ctx_user_id,
        ev_text(details, 'org_id') AS ctx_org_id
    FROM public.event_log
    WHERE type = 'session_context'
    ORDER BY session, "time" ASC
),
appname_ev AS (
    SELECT DISTINCT ON (session)
        session,
        app_name,
        environment AS parsed_environment,
        app_version AS parsed_app_version,
        pod AS parsed_pod
    FROM public.v_events
    WHERE session IS NOT NULL
    ORDER BY session, "time" ASC
),
browser_ev AS (
    SELECT DISTINCT ON (session)
        session, ev_text(details, 'value') AS browser
    FROM public.event_log
    WHERE type = 'browser'
    ORDER BY session, "time" ASC
),
counts_ev AS (
    SELECT
        session,
        count(*) AS n_events,
        count(*) FILTER (WHERE type = 'error') AS n_errors
    FROM public.event_log
    WHERE session IS NOT NULL
    GROUP BY session
),
first_tab_ev AS (
    SELECT DISTINCT ON (session)
        session, ev_text(details, 'value') AS first_tab
    FROM public.event_log
    WHERE type = 'navigation' AND ev_text(details, 'id') = 'home_tabset'
    ORDER BY session, "time" ASC
),
last_tab_ev AS (
    SELECT DISTINCT ON (session)
        session, ev_text(details, 'value') AS last_tab
    FROM public.event_log
    WHERE type = 'navigation' AND ev_text(details, 'id') = 'home_tabset'
    ORDER BY session, "time" DESC
)
SELECT
    s.session,
    l.login_time,
    lo.logout_time,
    EXTRACT(EPOCH FROM (lo.logout_time - l.login_time)) AS duration_s,
    l.username,
    COALESCE(a.parsed_environment, c.ctx_environment) AS environment,
    COALESCE(a.parsed_app_version, c.ctx_app_version) AS app_version,
    COALESCE(a.parsed_pod, c.ctx_pod) AS pod,
    c.ctx_user_id AS user_id,
    c.ctx_org_id AS org_id,
    b.browser,
    COALESCE(cnt.n_events, 0) AS n_events,
    COALESCE(cnt.n_errors, 0) AS n_errors,
    ft.first_tab,
    lt.last_tab
FROM sess s
LEFT JOIN login_ev     l   ON l.session = s.session
LEFT JOIN logout_ev    lo  ON lo.session = s.session
LEFT JOIN ctx_ev       c   ON c.session = s.session
LEFT JOIN appname_ev   a   ON a.session = s.session
LEFT JOIN browser_ev   b   ON b.session = s.session
LEFT JOIN counts_ev    cnt ON cnt.session = s.session
LEFT JOIN first_tab_ev ft  ON ft.session = s.session
LEFT JOIN last_tab_ev  lt  ON lt.session = s.session;

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
    s.username, s.environment, s.app_version, s.pod, s.user_id, s.org_id
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
    s.username, s.environment, s.app_version, s.pod, s.user_id, s.org_id
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
    s.username, s.environment, s.app_version, s.pod, s.user_id, s.org_id
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
    s.username, s.environment, s.app_version, s.pod, s.user_id, s.org_id
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
    s.username, s.environment, s.app_version, s.pod, s.user_id, s.org_id
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
    s.username, s.environment, s.app_version, s.pod, s.user_id, s.org_id
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
    s.username, s.environment, s.app_version, s.pod, s.user_id, s.org_id
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
    s.username, s.environment, s.app_version, s.pod, s.user_id, s.org_id
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
    s.username, s.environment, s.app_version, s.pod, s.user_id, s.org_id
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
WITH nav AS (
    SELECT
        e.session,
        e."time" AS entered_at,
        ev_text(e.details, 'value') AS tab
    FROM public.event_log e
    WHERE e.type = 'navigation' AND ev_text(e.details, 'id') = 'home_tabset'
)
SELECT
    n.session,
    n.tab,
    n.entered_at,
    COALESCE(
        LEAD(n.entered_at) OVER (PARTITION BY n.session ORDER BY n.entered_at),
        s.logout_time
    ) AS left_at,
    EXTRACT(EPOCH FROM (
        COALESCE(
            LEAD(n.entered_at) OVER (PARTITION BY n.session ORDER BY n.entered_at),
            s.logout_time
        ) - n.entered_at
    )) AS seconds
FROM nav n
JOIN public.v_sessions s ON s.session = n.session;

-- =============================================================================
-- v_daily_active -- daily active users/sessions/orgs
-- =============================================================================
-- environment is NULL for legacy rows (see header). n_orgs is NULL-safe
-- (COUNT DISTINCT ignores NULL org_id, which is expected until
-- session_context is flowing).

-- @@
CREATE OR REPLACE VIEW public.v_daily_active AS
SELECT
    date_trunc('day', login_time)::date AS date,
    environment,
    count(DISTINCT username) AS n_users,
    count(DISTINCT session) AS n_sessions,
    count(DISTINCT org_id) AS n_orgs
FROM public.v_sessions
WHERE login_time IS NOT NULL
GROUP BY 1, 2;
