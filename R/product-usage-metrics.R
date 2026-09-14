# Metric registry for the "Product usage" tab and its "Methodology" tab.
#
# One row per output id in product-usage-panel.R. This is the single source
# of truth for hover text (pu_hover()) and the methodology tables
# (product_usage_methods_ui()), so a metric's description is written once.
# `method` must describe what the matching pu_* query in
# product-usage-queries.R actually does, not a paraphrase of the catalog
# question.

#' Build one catalog row
#' @noRd
pu_row <- function(output_id, group, title, what, value, method, caveats = "", question = "") {
  dplyr::tibble(
    output_id = output_id,
    group = group,
    title = title,
    what = what,
    value = value,
    method = method,
    caveats = caveats,
    question = question
  )
}

#' Metric registry for the "Product usage" tab
#'
#' @description
#' One row per output id in `product_usage_ui()`/`product_usage_server()`
#' (32 rows total: 23 plots/tables/text metrics, 6 value boxes, the
#' environment picker, the CSV download button and the views-status
#' message). Backs both the hover text built by [`pu_hover()`] and the
#' tables in [`product_usage_methods_ui()`].
#'
#' @return A [`dplyr::tibble()`] with columns `output_id`, `group`, `title`,
#' `what`, `value`, `method`, `caveats`, `question`.
#' @keywords internal
#' @noRd
pu_metric_catalog <- function() {
  dplyr::bind_rows(
    # -- Overview -----------------------------------------------------------
    pu_row(
      "usage_status", "Overview", "Usage views status",
      "Shows whether the usage-db reporting views are installed on the connected database.",
      "Tells whoever opens this tab if the dashboard has anything to query at all.",
      paste(
        "Calls usage_views_present(data_storage) once when the tab loads, which checks",
        "information_schema.views for public.v_sessions. If the view is missing, this",
        "message is the only thing rendered and no other query on this tab runs."
      )
    ),
    pu_row(
      "usage_environment_picker", "Overview", "Environment filter",
      "A dropdown listing every distinct environment value seen in v_sessions, plus an All option.",
      "Lets you scope every metric on the tab to one deployment (for example TEST or PROD) or view them combined.",
      paste(
        "Populated from SELECT DISTINCT environment FROM v_sessions WHERE environment IS NOT NULL.",
        "Selecting a value other than All passes it as the $3 environment parameter to every",
        "pu_* query. Selecting All passes NULL, which every query treats as no environment filter."
      ),
      caveats = paste(
        "Legacy rows written before the app_name format change have NULL environment and are",
        "excluded from this list entirely. Selecting All is the only way to include them."
      )
    ),
    pu_row(
      "usage_n_users", "Overview", "Users",
      "Count of distinct usernames that logged in during the selected window.",
      "Headline count of how many people used the app in the period.",
      paste(
        "pu_overview_totals runs count(DISTINCT s.username) from v_sessions, filtered to",
        "s.login_time in the selected date window and s.environment matching the picker (or",
        "unfiltered when All is selected)."
      ),
      caveats = "username is the email address from the login event, so this count carries PII."
    ),
    pu_row(
      "usage_n_sessions", "Overview", "Sessions",
      "Count of distinct session tokens in the selected window.",
      "Headline count of how many app sessions occurred, distinct from the user count.",
      paste(
        "pu_overview_totals runs count(DISTINCT s.session) from v_sessions with the same",
        "login_time and environment filters as Users."
      )
    ),
    pu_row(
      "usage_n_orgs", "Overview", "Orgs",
      "Count of distinct organizations represented in the selected window.",
      "Headline count of how many customer orgs were active.",
      paste(
        "pu_overview_totals runs count(DISTINCT s.org_id) from v_sessions with the same",
        "filters. org_id comes only from the session_context event."
      ),
      caveats = paste(
        "org_id is NULL until session_context is flowing (the cloudUtils app_name rollout).",
        "Until then this box reads 0 or undercounts."
      )
    ),
    pu_row(
      "usage_median_session_min", "Overview", "Median session (min)",
      "Median session duration, converted from seconds to minutes and rounded to one decimal.",
      "Typical time a user spends in a single session.",
      paste(
        "pu_overview_totals runs percentile_cont(0.5) WITHIN GROUP (ORDER BY s.duration_s) from",
        "v_sessions in the window. duration_s is logout_time minus login_time. The server divides",
        "the result by 60 for display."
      ),
      caveats = "Sessions with no logout (pod killed or still active) have duration_s NULL and drop out of the median."
    ),
    pu_row(
      "usage_n_models", "Overview", "Models run",
      "Count of model_run events in the selected window.",
      "Headline count of statistical model runs.",
      paste(
        "pu_overview_totals runs a correlated subquery, count(*) FROM v_model_runs filtered on",
        "time and environment, independent of the v_sessions row set."
      )
    ),
    pu_row(
      "usage_n_exports", "Overview", "Exports",
      "Count of export events in the selected window.",
      "Headline count of data and report exports.",
      paste(
        "pu_overview_totals runs a correlated subquery, count(*) FROM v_exports filtered on",
        "time and environment."
      )
    ),
    pu_row(
      "usage_download_features", "Overview", "Download feature events (CSV)",
      "Downloads every v_feature_events row in the selected window and environment as a CSV file.",
      "Lets an analyst inspect or archive the raw per-event rows behind the dashboard's aggregates.",
      paste(
        "pu_feature_events_export selects * from v_feature_events with the same time and",
        "environment filters as every other query, ordered by time, and writes it with",
        "utils::write.csv."
      ),
      caveats = paste(
        "v_feature_events only covers analytical/product events (analysis_opened, model_run,",
        "heatmap_run, pathway_run, export, qc_exclusion, kg_opened, download, tour,",
        "analysis_shared, analysis_cloned, analysis_deleted). Login, logout, navigation, browser",
        "and error rows are not in this export."
      )
    ),

    # -- Who ------------------------------------------------------------------
    pu_row(
      "usage_daily_active_plot", "Who", "Daily active sessions",
      "Line plot of daily session counts, one line per environment.",
      "Shows the day-to-day usage trend and whether it differs by environment.",
      paste(
        "pu_daily_active reads v_daily_active (one row per date x environment, built by grouping",
        "v_sessions by day), filtered to the selected date range and environment, plotting date",
        "vs n_sessions colored by environment."
      ),
      caveats = "environment is NULL on legacy sessions written before the app_name format change; those show as their own blank-colored series.",
      question = "Q3"
    ),
    pu_row(
      "usage_users_per_org_table", "Who", "Users per org",
      "Table of distinct user counts, one row per organization.",
      "Shows which orgs are most active by user count.",
      paste(
        "pu_users_per_org counts DISTINCT s.user_id per s.org_id from v_sessions, filtered to",
        "org_id IS NOT NULL, the date window on login_time, and environment, ordered by user",
        "count descending."
      ),
      caveats = "user_id and org_id come only from session_context; sessions without it are excluded entirely, not shown as an unknown bucket.",
      question = "Q2"
    ),
    pu_row(
      "usage_retention_plot", "Who", "Week-over-week retention",
      "Grouped bar chart of users active in a given week versus the subset also active the following week.",
      "Shows how many users come back week over week.",
      paste(
        "pu_weekly_retention buckets distinct usernames by date_trunc('week', login_time) in the",
        "window and environment, then self-joins each week to the week exactly 7 days later on",
        "matching username to count carryover."
      ),
      caveats = "The last week in any selected window always shows a low or zero active_next_week_too, since the following week can fall outside the window.",
      question = "Q4"
    ),

    # -- What -------------------------------------------------------------
    pu_row(
      "usage_feature_adoption_plot", "What", "Feature adoption (% of sessions)",
      "Horizontal bar chart of the percentage of sessions that used each feature at least once.",
      "Shows which features reach the broadest share of sessions.",
      paste(
        "pu_feature_adoption counts sessions in the window from v_sessions, then for each",
        "distinct feature in v_feature_events joins to that session set and counts sessions with",
        "at least one such event. pct_sessions is that count over the total session count,",
        "rounded to one decimal; the denominator is total sessions in the window, not total events."
      ),
      caveats = "Generalizes catalog Q5 (which only checked model_run) to every feature type in v_feature_events.",
      question = "Q5"
    ),
    pu_row(
      "usage_model_type_plot", "What", "Model type mix",
      "Bar chart of model_run counts grouped by model type.",
      "Shows which kinds of statistical models are run most.",
      paste(
        "pu_model_type_mix counts v_model_runs rows grouped by model_type, filtered to the date",
        "window on event time and environment."
      ),
      question = "Q6"
    ),
    pu_row(
      "usage_export_format_plot", "What", "Export format mix",
      "Bar chart of export counts grouped by output format.",
      "Shows which export file formats are most requested.",
      paste(
        "pu_export_format_mix unnests the formats array column of v_exports (one export event",
        "can list multiple formats) and counts rows per format, filtered to the date window and",
        "environment."
      ),
      caveats = "An export event with 3 formats contributes 3 rows here, so this counts format instances, not export events.",
      question = "Q7"
    ),
    pu_row(
      "usage_analysis_export_rate", "What", "Analysis export rate",
      "One sentence stating how many opened analyses in the window reached export, and the percentage.",
      "Shows what share of opened analyses are actually taken through to an export.",
      paste(
        "pu_analysis_export_rate builds two distinct analysis_id sets from v_analysis_opened and",
        "v_exports in the window and environment, counts opened analyses, counts how many of",
        "those ids also appear in the exported set, and rounds the ratio to one decimal percent.",
        "The denominator is n_opened."
      ),
      caveats = "Both sides key on analysis_id; a feature event with no analysis_id (attribution failed, or it happened before any analysis_opened event in the session) never contributes to either side.",
      question = "Q8"
    ),
    pu_row(
      "usage_download_mix_table", "What", "Most requested downloads",
      "Table of download counts grouped by what was downloaded.",
      "Shows which specific download items (for example templates or sample files) are requested most.",
      paste(
        "pu_download_mix counts v_downloads rows grouped by the what slug, filtered to the date",
        "window and environment, ordered by count descending."
      ),
      question = "Q11"
    ),

    # -- How --------------------------------------------------------------
    pu_row(
      "usage_error_rate_table", "How", "Error rate per feature",
      "Table of event count, error count and error percentage, one row per feature.",
      "Shows which analytical features fail most often.",
      paste(
        "pu_feature_error_rate counts v_feature_events rows per feature where status IS NOT NULL,",
        "counts the subset with status = 'error', and computes pct_error as that count over the",
        "total, filtered to the date window and environment."
      ),
      caveats = "Only model_run, heatmap_run, pathway_run, export and analysis_opened carry a status field; every other feature always has status NULL and is excluded by the WHERE clause, so it never appears in this table.",
      question = "Q12"
    ),
    pu_row(
      "usage_model_duration_plot", "How", "Median model duration by target-count bucket",
      "Bar chart of median model run duration in ms, grouped into 10 buckets of 500 targets each, from 0 to 5000.",
      "Shows how model runtime scales with the number of targets modeled.",
      paste(
        "pu_model_duration_by_target_bucket uses width_bucket(n_targets, 0, 5000, 10) to assign",
        "each v_model_runs row to a 500-target-wide bucket, then takes percentile_cont(0.5) of",
        "duration_ms per bucket, filtered to rows with non-null n_targets and duration_ms, the",
        "date window and environment."
      ),
      question = "Q13"
    ),
    pu_row(
      "usage_model_complexity", "How", "Average model complexity",
      "One sentence giving the average number of covariates, interactions and ratios per model run.",
      "Shows how complex a typical model is.",
      paste(
        "pu_model_complexity takes avg(n_covariates), avg(n_interactions) and avg(n_ratios)",
        "across v_model_runs in the date window and environment."
      ),
      question = "Q16"
    ),
    pu_row(
      "usage_qc_exclusion_table", "How", "QC exclusion rate",
      "Table of average exclusion rate and event count, one row per kind, method and action combination.",
      "Shows how often, and by what method, samples or targets get excluded during QC.",
      paste(
        "pu_qc_exclusion_rate averages n_excluded/n_total per (kind, method, action) group in",
        "v_qc_exclusions, filtered to the date window and environment, ordered by event count",
        "descending."
      ),
      caveats = "action = 'recompute' rows are target-side detectability recomputations that fire automatically, including on project load. They describe state, not a user exclusion decision, and can inflate event counts for that action.",
      question = "Q10"
    ),

    # -- When -----------------------------------------------------------------
    pu_row(
      "usage_time_to_first_model", "When", "Time to first model",
      "One sentence giving the median minutes from login to the first model run in a session.",
      "Shows how quickly a new session gets to running its first model.",
      paste(
        "pu_time_to_first_model finds each session's earliest v_model_runs time, joins it to that",
        "session's login_time from v_sessions, and takes percentile_cont(0.5) of the elapsed",
        "seconds, filtered to the date window and environment on login_time."
      ),
      caveats = "Sessions with no model run at all never enter the numerator, since the join to the first-model subquery is inner.",
      question = "Q18"
    ),
    pu_row(
      "usage_session_length_plot", "When", "Median session length",
      "Bar chart of median session duration in minutes, one bar per environment.",
      "Shows whether typical session length differs by environment.",
      paste(
        "pu_session_length_by_env takes percentile_cont(0.5) of duration_s per environment from",
        "v_sessions where duration_s IS NOT NULL, filtered to the date window and environment.",
        "The server converts seconds to minutes before plotting."
      ),
      caveats = "Sessions with no logout have duration_s NULL and are excluded, the same caveat as the median-session value box.",
      question = "Q19"
    ),
    pu_row(
      "usage_weekday_hour_plot", "When", "Sessions by weekday and hour",
      "Heatmap of session counts by ISO weekday (1 = Monday) and hour of day.",
      "Shows when during the week usage peaks.",
      paste(
        "pu_sessions_by_weekday_hour groups v_sessions by EXTRACT(ISODOW FROM login_time) and",
        "EXTRACT(HOUR FROM login_time), counting rows, filtered to the date window and",
        "environment on login_time."
      ),
      question = "Q20"
    ),

    # -- Where ------------------------------------------------------------
    pu_row(
      "usage_time_per_tab_plot", "Where", "Total time spent per tab",
      "Bar chart of total seconds spent on each top-level tab, summed across all visits.",
      "Shows which tabs absorb the most user time overall.",
      paste(
        "pu_time_per_tab reads v_time_on_tab (dwell time per navigation to home_tabset), joins",
        "v_sessions only to apply the environment filter since v_time_on_tab has no environment",
        "column of its own, and sums and medians seconds per tab, filtered to entered_at in the",
        "date window and rows with non-null seconds."
      ),
      caveats = "A tab visit whose session has no logout and no later navigation has seconds = NULL and is excluded, so an unfinished session's last tab is undercounted.",
      question = "Q21"
    ),
    pu_row(
      "usage_first_last_tab_table", "Where", "First tab vs last tab",
      "Table of session counts, one row per first-tab and last-tab combination.",
      "Shows where sessions start and where they end, as a drop-off proxy.",
      paste(
        "pu_tab_first_last counts v_sessions rows grouped by first_tab and last_tab, filtered to",
        "the date window and environment on login_time, ordered by count descending."
      ),
      caveats = "first_tab/last_tab come from the earliest/latest navigation event with id = home_tabset in the session; a session with no such navigation has both as NULL.",
      question = "Q22"
    ),

    # -- How long -----------------------------------------------------------
    pu_row(
      "usage_heatmap_duration_plot", "How long", "Heatmap run duration by sample-count bucket",
      "Bar chart of median heatmap run duration in ms, grouped into 10 buckets of 50 samples each, from 0 to 500.",
      "Shows how heatmap runtime scales with sample count.",
      paste(
        "pu_heatmap_duration_by_sample_bucket buckets v_heatmap_runs by",
        "width_bucket(n_samples, 0, 500, 10) and takes percentile_cont(0.5) of duration_ms per",
        "bucket, restricted to trigger = 'button' or trigger IS NULL, non-null duration_ms, the",
        "date window and environment."
      ),
      caveats = "trigger = 'tab_return' (NAS auto-rerunning the heatmap when the user returns to the tab) is excluded, so this counts user-initiated runs only, not passive re-renders.",
      question = "Q24"
    ),
    pu_row(
      "usage_pathway_duration_plot", "How long", "Pathway run duration by database",
      "Bar chart of median pathway run duration in ms, one bar per pathway database.",
      "Shows which pathway databases are slower to compute against.",
      paste(
        "pu_pathway_duration_by_database takes percentile_cont(0.5) of duration_ms per database",
        "from v_pathway_runs, filtered to the date window and environment."
      ),
      caveats = "pathway_run is one fgsea computation, not one click; the reactive recomputes when the comparison, ranking or database changes, so counts here reflect computations, not user actions.",
      question = "Q25"
    ),
    pu_row(
      "usage_tour_completion_table", "How long", "Tour completion",
      "Table of started count, completed count and completion percentage, one row per tour.",
      "Shows how often each guided tour is finished once started.",
      paste(
        "pu_tour_completion_rate counts v_tours rows filtered on action = 'started' and",
        "action = 'completed' per tour, computing pct_completed as completed over started,",
        "filtered to the date window and environment."
      ),
      question = "Q26"
    ),

    # -- Funnels ----------------------------------------------------------
    pu_row(
      "usage_tab_funnel_plot", "Funnels", "Tab funnel",
      "Bar chart of session counts reaching each stage: Upload, QC, Stats, Export, each stage requiring every prior stage.",
      "Shows where sessions drop off across the main tab sequence.",
      paste(
        "pu_tab_funnel aggregates v_time_on_tab per session (joined to v_sessions for the",
        "environment filter) into boolean flags for whether the session ever visited upload_v2,",
        "qc/qcSample/qcTarget, stats_tests or download, then counts sessions meeting each flag",
        "and every prior flag, filtered to entered_at in the date window."
      ),
      caveats = "'qc' is the 1.x QC tab id and 'qcSample'/'qcTarget' are the 2.x ids; the query already unions all three, so the funnel is version-agnostic.",
      question = "Q27"
    ),
    pu_row(
      "usage_analysis_funnel_plot", "Funnels", "Analysis funnel",
      "Bar chart of analysis counts reaching each stage: Opened, Modeled, Exported.",
      "Shows what share of opened analyses get modeled and then exported.",
      paste(
        "pu_analysis_funnel groups v_feature_events by analysis_id, flags whether",
        "analysis_opened/model_run/export ever occurred for that analysis, then counts analyses",
        "meeting each flag and every prior flag, filtered to feature-event time in the date",
        "window and analysis_id IS NOT NULL."
      ),
      question = "Q28"
    ),
    pu_row(
      "usage_tour_funnel_plot", "Funnels", "Tour funnel",
      "Bar chart of tour event counts at each stage: Offered, Started, Completed.",
      "Shows where users drop out of a guided tour.",
      paste(
        "pu_tour_funnel counts v_tours rows by action ('offered', 'started', 'completed')",
        "independently, filtered to the date window and environment."
      ),
      caveats = "Unlike the tab and analysis funnels, these three counts are independent, not a strict funnel where later stages are subsets of earlier ones; a completed tour is not guaranteed to have a matching offered/started row for the same tour instance.",
      question = "Q30"
    )
  )
}

#' Small info icon carrying a metric's hover description
#'
#' @description
#' Looks up `output_id` in [`pu_metric_catalog()`] and returns a Fomantic UI
#' info icon whose `what` + `value` text shows as a pure-CSS tooltip
#' (`data-tooltip`), so the description is written once in the catalog and
#' reused everywhere it is shown.
#'
#' @param output_id character scalar, must match one `output_id` in
#' [`pu_metric_catalog()`].
#'
#' @return A [`shiny::tags$i()`] tag.
#' @keywords internal
#' @noRd
pu_hover <- function(output_id) {
  catalog <- pu_metric_catalog()
  row <- catalog[catalog$output_id == output_id, ]
  stopifnot(nrow(row) == 1)

  # The tooltip attributes sit on a wrapper span, not on the icon: Fomantic
  # draws the tooltip arrow with `[data-tooltip]:before { content: '' }`,
  # which replaces the glyph an `i.icon` also renders through `:before`.
  shiny::tags$span(
    `data-tooltip` = paste(row$what, row$value),
    `data-position` = "top left",
    `data-variation` = "wide",
    style = "margin-left: 0.3em; cursor: help;",
    shiny::tags$i(class = "info circle icon", style = "color: #767676;")
  )
}

#' One catalog row's "Catalog ref" cell for the methodology table
#' @noRd
pu_catalog_ref <- function(question) {
  if (nzchar(question)) question else "Overview"
}

#' Static methodology table for one metric group
#'
#' @param rows the subset of [`pu_metric_catalog()`] for one `group`.
#'
#' @return An [`htmltools::tags$table()`].
#' @noRd
pu_methods_table <- function(rows) {
  header <- htmltools::tags$tr(
    htmltools::tags$th("Metric"),
    htmltools::tags$th("What it shows"),
    htmltools::tags$th("Why it matters"),
    htmltools::tags$th("How it is computed"),
    htmltools::tags$th("Caveats"),
    htmltools::tags$th("Catalog ref")
  )

  body_rows <- lapply(seq_len(nrow(rows)), function(i) {
    htmltools::tags$tr(
      htmltools::tags$td(rows$title[i]),
      htmltools::tags$td(rows$what[i]),
      htmltools::tags$td(rows$value[i]),
      htmltools::tags$td(rows$method[i]),
      htmltools::tags$td(if (nzchar(rows$caveats[i])) rows$caveats[i] else "None"),
      htmltools::tags$td(pu_catalog_ref(rows$question[i]))
    )
  })

  htmltools::tags$table(
    class = "ui very basic compact table",
    htmltools::tags$thead(header),
    htmltools::tags$tbody(body_rows)
  )
}

#' "Reading the data" segment: global data notes from the usage-db README
#' @noRd
pu_reading_the_data_segment <- function() {
  shiny.semantic::segment(
    class = "centered-and-margined full-width",
    title = "Reading the data",
    shiny::tags$ul(
      shiny::tags$li(paste(
        "Built-in events (login, logout, navigation, input, error, browser) wrap every JSON",
        "value in a one-element array. New domain events use plain scalars. Every metric on",
        "this tab reads through accessor functions that handle both shapes."
      )),
      shiny::tags$li(paste(
        "app_name has three shapes: a bare 'nulisa-analysis-software' (oldest), an",
        "'App:...; User Session:<pod>' form, and the current 'nas/<ENVIRONMENT>/<version>' form.",
        "Only the current form carries a parseable environment. Rows written before this",
        "change have environment = NULL in every view and cannot be backfilled."
      )),
      shiny::tags$li(paste(
        "A session's logout_time is NULL both when its pod was killed (no graceful",
        "onSessionEnded) and when the session is still active inside the query window. The two",
        "cannot be told apart from event_log alone."
      )),
      shiny::tags$li(paste(
        "error fields are fixed slugs (for example invalid_interactions, prep_failed,",
        "fgsea_failed, export_failed), never the R condition message, so they never leak a",
        "covariate or sample name."
      )),
      shiny::tags$li(paste(
        "The 1.x QC tab id is 'qc'; 2.x splits it into 'qcSample' and 'qcTarget'. Tab-based",
        "metrics that need to treat QC as one stage union all three ids."
      )),
      shiny::tags$li(paste(
        "login.details.username is the user's email address, exposed as PII in v_sessions.",
        "Newer events carry opaque user_id/org_id from session_context instead."
      )),
      shiny::tags$li(paste(
        "Each metric's date window filters on the timestamp its source view is keyed on:",
        "session login time for session-grain metrics, event time for feature-event metrics.",
        "The 'How it is computed' column below states which for each metric."
      ))
    )
  )
}

#' "Sources" segment: where the SQL and catalog for every metric live
#' @noRd
pu_sources_segment <- function() {
  shiny.semantic::segment(
    class = "centered-and-margined full-width",
    title = "Sources",
    shiny::tags$p(paste(
      "Every metric above reads one or more of the v_* views defined in",
      "inst/sql/usage-db.schema.sql: v_events, v_sessions, v_analysis_opened, v_model_runs,",
      "v_heatmap_runs, v_pathway_runs, v_qc_exclusions, v_exports, v_downloads, v_tours,",
      "v_feature_events, v_time_on_tab and v_daily_active."
    )),
    shiny::tags$p(
      "The SQL for every metric lives in R/product-usage-queries.R, one pu_* function per row above."
    ),
    shiny::tags$p(
      "The product/management question catalog each metric answers lives in questions.md."
    )
  )
}

#' UI for the "Methodology" tab
#'
#' @description
#' Static documentation body: no server code, no reactivity, no database
#' access. One [`shiny.semantic::segment()`] per metric group in
#' [`pu_metric_catalog()`] order, a "Reading the data" segment first and a
#' "Sources" segment last. Wired into the dashboard by `analytics_ui()`.
#'
#' @return A [`shiny::tagList()`].
#' @keywords internal
#' @noRd
product_usage_methods_ui <- function() {
  catalog <- pu_metric_catalog()
  groups <- unique(catalog$group)

  group_segments <- lapply(groups, function(g) {
    shiny.semantic::segment(
      class = "centered-and-margined full-width",
      title = g,
      pu_methods_table(catalog[catalog$group == g, ])
    )
  })

  shiny::tagList(
    pu_reading_the_data_segment(),
    group_segments,
    pu_sources_segment()
  )
}
