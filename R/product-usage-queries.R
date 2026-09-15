# Product-usage metric queries.
#
# One function per questions.md item, over the v_* views from ensure_usage_views().
# Signature: (data_storage, date_from, date_to, environment = NULL); NULL = all.

#' Build the 3 positional params ($1 date_from, $2 date_to, $3 environment)
#' shared by every product-usage query.
#' @noRd
pu_params <- function(date_from, date_to, environment = NULL) {
  list(
    as.character(date_from),
    as.character(date_to),
    if (is.null(environment)) NA_character_ else environment
  )
}

# -- Overview (supports the top value-box row, not a numbered catalog question) --

#' Overview totals for the value-box row: users, sessions, orgs, median
#' session length, models run, exports.
#' @keywords internal
#' @noRd
pu_overview_totals <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT
        count(DISTINCT s.username) AS n_users,
        count(DISTINCT s.session) AS n_sessions,
        count(DISTINCT s.org_id) AS n_orgs,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY s.duration_s) AS median_session_s,
        (SELECT count(*) FROM v_model_runs m
           WHERE m."time" >= $1::date AND m."time" < ($2::date + 1)
             AND ($3::text IS NULL OR m.environment = $3)) AS n_models,
        (SELECT count(*) FROM v_exports x
           WHERE x."time" >= $1::date AND x."time" < ($2::date + 1)
             AND ($3::text IS NULL OR x.environment = $3)) AS n_exports
    FROM v_sessions s
    WHERE s.login_time >= $1::date AND s.login_time < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

#' Raw `v_feature_events` rows for the window/environment, for the CSV
#' download button (not a numbered catalog question).
#' @keywords internal
#' @noRd
pu_feature_events_export <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT *
    FROM v_feature_events s
    WHERE s."time" >= $1::date AND s."time" < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    ORDER BY s."time"
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

# -- Who ----------------------------------------------------------------

#' Q3: daily active users/sessions/orgs by environment
#' @keywords internal
#' @noRd
pu_daily_active <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT s.date, s.environment, s.n_users, s.n_sessions, s.n_orgs
    FROM v_daily_active s
    WHERE s.date >= $1::date AND s.date < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    ORDER BY 1, 2
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

#' Q2: distinct users per org
#' @keywords internal
#' @noRd
pu_users_per_org <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT s.org_id, count(DISTINCT s.user_id) AS n_users
    FROM v_sessions s
    WHERE s.org_id IS NOT NULL
      AND s.login_time >= $1::date AND s.login_time < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    GROUP BY 1
    ORDER BY 2 DESC
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

#' Recent sessions with the pod id, for log lookup (not a catalog question)
#' @keywords internal
#' @noRd
pu_recent_sessions <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT s.login_time, s.username, s.environment, s.app_version, s.pod,
           round(s.duration_s / 60.0, 1) AS minutes, s.n_events, s.n_errors
    FROM v_sessions s
    WHERE s.login_time >= $1::date AND s.login_time < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    ORDER BY s.login_time DESC
    LIMIT 500
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

#' Q4: week-over-week retention
#' @keywords internal
#' @noRd
pu_weekly_retention <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    WITH weekly AS (
        SELECT DISTINCT s.username, date_trunc('week', s.login_time)::date AS week
        FROM v_sessions s
        WHERE s.username IS NOT NULL
          AND s.login_time >= $1::date AND s.login_time < ($2::date + 1)
          AND ($3::text IS NULL OR s.environment = $3)
    )
    SELECT w1.week,
           count(DISTINCT w1.username) AS active_this_week,
           count(DISTINCT w2.username) AS active_next_week_too
    FROM weekly w1
    LEFT JOIN weekly w2
        ON w2.username = w1.username AND w2.week = w1.week + interval '7 days'
    GROUP BY 1
    ORDER BY 1
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

# -- What (feature adoption) ---------------------------------------------

#' Feature adoption: share of sessions with >= 1 event per feature
#' (generalises catalog Q5, which only checked model_run)
#' @keywords internal
#' @noRd
pu_feature_adoption <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    WITH sessions_in_window AS (
        SELECT s.session
        FROM v_sessions s
        WHERE s.login_time >= $1::date AND s.login_time < ($2::date + 1)
          AND ($3::text IS NULL OR s.environment = $3)
    ),
    feature_sessions AS (
        SELECT DISTINCT fe.session, fe.feature
        FROM v_feature_events fe
        JOIN sessions_in_window w ON w.session = fe.session
    )
    SELECT fs.feature,
           count(DISTINCT fs.session) AS n_sessions_with_feature,
           (SELECT count(*) FROM sessions_in_window) AS n_sessions_total,
           round(
             100.0 * count(DISTINCT fs.session)
               / NULLIF((SELECT count(*) FROM sessions_in_window), 0), 1
           ) AS pct_sessions
    FROM feature_sessions fs
    GROUP BY 1
    ORDER BY 4 DESC
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

#' Q6: model type mix
#' @keywords internal
#' @noRd
pu_model_type_mix <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT s.model_type, count(*) AS n_runs
    FROM v_model_runs s
    WHERE s."time" >= $1::date AND s."time" < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    GROUP BY 1
    ORDER BY 2 DESC
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

#' Q7: export format mix
#' @keywords internal
#' @noRd
pu_export_format_mix <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT fmt, count(*) AS n
    FROM v_exports s, unnest(s.formats) AS fmt
    WHERE s."time" >= $1::date AND s."time" < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    GROUP BY 1
    ORDER BY 2 DESC
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

#' Q8: share of opened analyses that reach export
#' @keywords internal
#' @noRd
pu_analysis_export_rate <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    WITH opened AS (
        SELECT DISTINCT s.analysis_id
        FROM v_analysis_opened s
        WHERE s.analysis_id IS NOT NULL
          AND s."time" >= $1::date AND s."time" < ($2::date + 1)
          AND ($3::text IS NULL OR s.environment = $3)
    ),
    exported AS (
        SELECT DISTINCT s.analysis_id
        FROM v_exports s
        WHERE s.analysis_id IS NOT NULL
          AND s."time" >= $1::date AND s."time" < ($2::date + 1)
          AND ($3::text IS NULL OR s.environment = $3)
    )
    SELECT
        count(*) AS n_opened,
        count(*) FILTER (WHERE o.analysis_id IN (SELECT analysis_id FROM exported)) AS n_exported,
        round(
          100.0 * count(*) FILTER (WHERE o.analysis_id IN (SELECT analysis_id FROM exported))
            / NULLIF(count(*), 0), 1
        ) AS pct_exported
    FROM opened o
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

#' Q11: most requested downloads
#' @keywords internal
#' @noRd
pu_download_mix <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT s.what, count(*) AS n
    FROM v_downloads s
    WHERE s."time" >= $1::date AND s."time" < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    GROUP BY 1
    ORDER BY 2 DESC
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

# -- How (reliability, complexity) ---------------------------------------

#' Q12: error rate per analytical feature
#' @keywords internal
#' @noRd
pu_feature_error_rate <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT s.feature, count(*) AS n,
           count(*) FILTER (WHERE s.status = 'error') AS n_error,
           round(100.0 * count(*) FILTER (WHERE s.status = 'error') / NULLIF(count(*), 0), 1) AS pct_error
    FROM v_feature_events s
    WHERE s.status IS NOT NULL
      AND s."time" >= $1::date AND s."time" < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    GROUP BY 1
    ORDER BY 4 DESC
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

#' Q13: median model duration by target-count bucket
#' @keywords internal
#' @noRd
pu_model_duration_by_target_bucket <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT width_bucket(s.n_targets, 0, 5000, 10) AS bucket,
           ((width_bucket(s.n_targets, 0, 5000, 10) - 1) * 500)::text || '-' ||
             (width_bucket(s.n_targets, 0, 5000, 10) * 500)::text AS bucket_label,
           min(s.n_targets) AS min_targets, max(s.n_targets) AS max_targets,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY s.duration_ms) AS median_ms,
           count(*) AS n
    FROM v_model_runs s
    WHERE s.n_targets IS NOT NULL AND s.duration_ms IS NOT NULL
      AND s."time" >= $1::date AND s."time" < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    GROUP BY 1, 2
    ORDER BY 1
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

#' Q16: average model complexity (covariates, interactions, ratios)
#' @keywords internal
#' @noRd
pu_model_complexity <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT avg(s.n_covariates) AS avg_covariates,
           avg(s.n_interactions) AS avg_interactions,
           avg(s.n_ratios) AS avg_ratios
    FROM v_model_runs s
    WHERE s."time" >= $1::date AND s."time" < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

#' Q10: QC exclusion rate by kind, method and action
#' @keywords internal
#' @noRd
pu_qc_exclusion_rate <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT s.kind, s.method, s.action,
           avg(s.n_excluded::numeric / NULLIF(s.n_total, 0)) AS avg_exclusion_rate,
           count(*) AS n_events
    FROM v_qc_exclusions s
    WHERE s."time" >= $1::date AND s."time" < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    GROUP BY 1, 2, 3
    ORDER BY 4 DESC
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

# -- When -----------------------------------------------------------------

#' Q18: median time from login to first model run
#' @keywords internal
#' @noRd
pu_time_to_first_model <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    WITH first_model AS (
        SELECT session, min("time") AS first_time
        FROM v_model_runs
        GROUP BY session
    )
    SELECT percentile_cont(0.5) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (m.first_time - s.login_time))
    ) AS median_seconds_to_first_model
    FROM v_sessions s
    JOIN first_model m ON m.session = s.session
    WHERE s.login_time IS NOT NULL
      AND s.login_time >= $1::date AND s.login_time < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

#' Q19: median session length per environment
#' @keywords internal
#' @noRd
pu_session_length_by_env <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT s.environment,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY s.duration_s) AS median_duration_s,
           count(*) AS n
    FROM v_sessions s
    WHERE s.duration_s IS NOT NULL
      AND s.login_time >= $1::date AND s.login_time < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    GROUP BY 1
    ORDER BY 1
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

#' Q20: sessions by weekday and hour
#' @keywords internal
#' @noRd
pu_sessions_by_weekday_hour <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT EXTRACT(ISODOW FROM s.login_time) AS weekday,
           EXTRACT(HOUR FROM s.login_time) AS hour,
           count(*) AS n_sessions
    FROM v_sessions s
    WHERE s.login_time IS NOT NULL
      AND s.login_time >= $1::date AND s.login_time < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    GROUP BY 1, 2
    ORDER BY 1, 2
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

# -- Where ------------------------------------------------------------------

#' Q21: time spent per tab (v_time_on_tab has no environment column, so this
#' joins v_sessions for the filter)
#' @keywords internal
#' @noRd
pu_time_per_tab <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT t.tab,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY t.seconds) AS median_seconds,
           sum(t.seconds) AS total_seconds,
           count(*) AS n_visits
    FROM v_time_on_tab t
    JOIN v_sessions s ON s.session = t.session
    WHERE t.seconds IS NOT NULL
      AND t.entered_at >= $1::date AND t.entered_at < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    GROUP BY 1
    ORDER BY 3 DESC
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

#' Q22: first tab vs last tab per session (drop-off proxy)
#' @keywords internal
#' @noRd
pu_tab_first_last <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT s.first_tab, s.last_tab, count(*) AS n
    FROM v_sessions s
    WHERE s.login_time >= $1::date AND s.login_time < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    GROUP BY 1, 2
    ORDER BY 3 DESC
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

# -- How long ---------------------------------------------------------------

#' Q24: heatmap run duration by sample-count bucket (button-triggered runs
#' only, i.e. not the tab_return auto re-run)
#' @keywords internal
#' @noRd
pu_heatmap_duration_by_sample_bucket <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT width_bucket(s.n_samples, 0, 10000, 20) AS sample_bucket,
           ((width_bucket(s.n_samples, 0, 10000, 20) - 1) * 500)::text || '-' ||
             (width_bucket(s.n_samples, 0, 10000, 20) * 500)::text AS bucket_label,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY s.duration_ms) AS median_ms,
           count(*) AS n
    FROM v_heatmap_runs s
    WHERE s.duration_ms IS NOT NULL
      AND (s.trigger = 'button' OR s.trigger IS NULL)
      AND s."time" >= $1::date AND s."time" < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    GROUP BY 1, 2
    ORDER BY 1
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

#' Q25: pathway run duration by database
#' @keywords internal
#' @noRd
pu_pathway_duration_by_database <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT s.database,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY s.duration_ms) AS median_ms,
           count(*) AS n
    FROM v_pathway_runs s
    WHERE s."time" >= $1::date AND s."time" < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    GROUP BY 1
    ORDER BY 1
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

#' Q26: tour completion rate
#' @keywords internal
#' @noRd
pu_tour_completion_rate <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT s.tour,
           count(*) FILTER (WHERE s.action = 'started') AS n_started,
           count(*) FILTER (WHERE s.action = 'completed') AS n_completed,
           round(100.0 * count(*) FILTER (WHERE s.action = 'completed')
               / NULLIF(count(*) FILTER (WHERE s.action = 'started'), 0), 1) AS pct_completed
    FROM v_tours s
    WHERE s."time" >= $1::date AND s."time" < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    GROUP BY 1
    ORDER BY 1
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

# -- Funnels ------------------------------------------------------------

#' Q27: tab-based drop-off funnel, upload -> QC -> stats -> export
#' @keywords internal
#' @noRd
pu_tab_funnel <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    WITH tabs AS (
        SELECT t.session,
               bool_or(t.tab = 'upload_v2') AS visited_upload,
               bool_or(t.tab IN ('qc', 'qcSample', 'qcTarget')) AS visited_qc,  -- 'qc' on 1.x rows
               bool_or(t.tab = 'stats_tests') AS visited_stats,
               bool_or(t.tab = 'download') AS visited_download
        FROM v_time_on_tab t
        JOIN v_sessions s ON s.session = t.session
        WHERE t.entered_at >= $1::date AND t.entered_at < ($2::date + 1)
          AND ($3::text IS NULL OR s.environment = $3)
        GROUP BY t.session
    )
    SELECT
        count(*) FILTER (WHERE visited_upload) AS n_upload,
        count(*) FILTER (WHERE visited_upload AND visited_qc) AS n_qc,
        count(*) FILTER (WHERE visited_upload AND visited_qc AND visited_stats) AS n_stats,
        count(*) FILTER (WHERE visited_upload AND visited_qc AND visited_stats AND visited_download) AS n_download
    FROM tabs
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

#' Q28: feature funnel by analysis, opened -> modeled -> exported
#' @keywords internal
#' @noRd
pu_analysis_funnel <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    WITH per_analysis AS (
        SELECT fe.analysis_id,
               bool_or(fe.feature = 'analysis_opened') AS opened,
               bool_or(fe.feature = 'model_run') AS modeled,
               bool_or(fe.feature = 'export') AS exported
        FROM v_feature_events fe
        JOIN v_sessions s ON s.session = fe.session
        WHERE fe.analysis_id IS NOT NULL
          AND fe."time" >= $1::date AND fe."time" < ($2::date + 1)
          AND ($3::text IS NULL OR s.environment = $3)
        GROUP BY fe.analysis_id
    )
    SELECT
        count(*) FILTER (WHERE opened) AS n_opened,
        count(*) FILTER (WHERE opened AND modeled) AS n_modeled,
        count(*) FILTER (WHERE opened AND modeled AND exported) AS n_exported
    FROM per_analysis
    )",
    params = pu_params(date_from, date_to, environment)
  )
}

#' Q30: tour funnel, offered -> started -> completed
#' @keywords internal
#' @noRd
pu_tour_funnel <- function(data_storage, date_from, date_to, environment = NULL) {
  data_storage$query(
    r"(
    SELECT
        count(*) FILTER (WHERE s.action = 'offered') AS n_offered,
        count(*) FILTER (WHERE s.action = 'started') AS n_started,
        count(*) FILTER (WHERE s.action = 'completed') AS n_completed
    FROM v_tours s
    WHERE s."time" >= $1::date AND s."time" < ($2::date + 1)
      AND ($3::text IS NULL OR s.environment = $3)
    )",
    params = pu_params(date_from, date_to, environment)
  )
}
