#' UI for the "Product usage" dashboard tab
#'
#' @description
#' Body content for the `product_usage` tab: an environment picker and
#' overview value-box row, a CSV download button, then one
#' `shiny.semantic::segment()` per question group (Who/What/How/When/Where/
#' How long/Funnels). Every plot and table carries a heading with a
#' [`pu_hover()`] info icon describing what it shows and why it matters;
#' text for those icons comes from [`pu_metric_catalog()`]. Wired into the
#' dashboard by `analytics_ui()`.
#'
#' @return A [`shiny::tagList()`].
#' @keywords internal
#' @noRd
product_usage_ui <- function() {
  overview <- shiny.semantic::segment(
    class = "centered-and-margined full-width",
    title = "Product usage overview",
    shiny::uiOutput("usage_status"),
    shiny::div(
      class = "ui form", style = "max-width: 260px; margin-bottom: 1em;",
      shiny::div(
        class = "field",
        shiny::tags$label("Environment"),
        shiny::uiOutput("usage_environment_picker")
      )
    ),
    shiny::div(
      class = "ui grid",
      shiny::div(
        class = "row",
        semantic.dashboard::valueBoxOutput("usage_n_users", 5),
        semantic.dashboard::valueBoxOutput("usage_n_sessions", 5),
        semantic.dashboard::valueBoxOutput("usage_n_orgs", 5)
      ),
      shiny::div(
        class = "row",
        semantic.dashboard::valueBoxOutput("usage_median_session_min", 5),
        semantic.dashboard::valueBoxOutput("usage_n_models", 5),
        semantic.dashboard::valueBoxOutput("usage_n_exports", 5)
      )
    ),
    shiny::div(
      render_download_button(
        "usage_download_features", "Download feature events (CSV)",
        style = "margin-top: 1em;"
      ),
      pu_hover("usage_download_features")
    )
  )

  who <- shiny.semantic::segment(
    class = "centered-and-margined full-width",
    title = "Who",
    shiny::tags$h4("Daily active sessions", pu_hover("usage_daily_active_plot")),
    plotly::plotlyOutput("usage_daily_active_plot"),
    shiny::tags$h4("Users per org", pu_hover("usage_users_per_org_table")),
    DT::dataTableOutput("usage_users_per_org_table"),
    shiny::tags$h4("Sessions (pod id for log lookup)", pu_hover("usage_recent_sessions_table")),
    DT::dataTableOutput("usage_recent_sessions_table"),
    shiny::tags$h4("Week-over-week retention", pu_hover("usage_retention_plot")),
    plotly::plotlyOutput("usage_retention_plot")
  )

  what <- shiny.semantic::segment(
    class = "centered-and-margined full-width",
    title = "What",
    shiny::tags$h4("Feature adoption", pu_hover("usage_feature_adoption_plot")),
    plotly::plotlyOutput("usage_feature_adoption_plot"),
    shiny::tags$h4("Model type mix", pu_hover("usage_model_type_plot")),
    plotly::plotlyOutput("usage_model_type_plot"),
    shiny::tags$h4("Export format mix", pu_hover("usage_export_format_plot")),
    plotly::plotlyOutput("usage_export_format_plot"),
    shiny::tags$h4("Analysis export rate", pu_hover("usage_analysis_export_rate")),
    shiny::uiOutput("usage_analysis_export_rate"),
    shiny::tags$h4("Most requested downloads", pu_hover("usage_download_mix_table")),
    DT::dataTableOutput("usage_download_mix_table")
  )

  how <- shiny.semantic::segment(
    class = "centered-and-margined full-width",
    title = "How",
    shiny::tags$h4("Error rate per feature", pu_hover("usage_error_rate_table")),
    DT::dataTableOutput("usage_error_rate_table"),
    shiny::tags$h4("Median model duration by target-count bucket", pu_hover("usage_model_duration_plot")),
    plotly::plotlyOutput("usage_model_duration_plot"),
    shiny::tags$h4("Average model complexity", pu_hover("usage_model_complexity")),
    shiny::uiOutput("usage_model_complexity"),
    shiny::tags$h4("QC exclusion rate", pu_hover("usage_qc_exclusion_table")),
    DT::dataTableOutput("usage_qc_exclusion_table")
  )

  when <- shiny.semantic::segment(
    class = "centered-and-margined full-width",
    title = "When",
    shiny::tags$h4("Time to first model", pu_hover("usage_time_to_first_model")),
    shiny::uiOutput("usage_time_to_first_model"),
    shiny::tags$h4("Median session length", pu_hover("usage_session_length_plot")),
    plotly::plotlyOutput("usage_session_length_plot"),
    shiny::tags$h4("Sessions by weekday and hour", pu_hover("usage_weekday_hour_plot")),
    plotly::plotlyOutput("usage_weekday_hour_plot")
  )

  where <- shiny.semantic::segment(
    class = "centered-and-margined full-width",
    title = "Where",
    shiny::tags$h4("Total time spent per tab", pu_hover("usage_time_per_tab_plot")),
    plotly::plotlyOutput("usage_time_per_tab_plot"),
    shiny::tags$h4("First tab vs last tab", pu_hover("usage_first_last_tab_table")),
    DT::dataTableOutput("usage_first_last_tab_table")
  )

  how_long <- shiny.semantic::segment(
    class = "centered-and-margined full-width",
    title = "How long",
    shiny::tags$h4("Heatmap run duration by sample-count bucket", pu_hover("usage_heatmap_duration_plot")),
    plotly::plotlyOutput("usage_heatmap_duration_plot"),
    shiny::tags$h4("Pathway run duration by database", pu_hover("usage_pathway_duration_plot")),
    plotly::plotlyOutput("usage_pathway_duration_plot"),
    shiny::tags$h4("Tour completion", pu_hover("usage_tour_completion_table")),
    DT::dataTableOutput("usage_tour_completion_table")
  )

  funnels <- shiny.semantic::segment(
    class = "centered-and-margined full-width",
    title = "Funnels",
    shiny::tags$h4("Tab funnel", pu_hover("usage_tab_funnel_plot")),
    plotly::plotlyOutput("usage_tab_funnel_plot"),
    shiny::tags$h4("Analysis funnel", pu_hover("usage_analysis_funnel_plot")),
    plotly::plotlyOutput("usage_analysis_funnel_plot"),
    shiny::tags$h4("Tour funnel", pu_hover("usage_tour_funnel_plot")),
    plotly::plotlyOutput("usage_tour_funnel_plot")
  )

  shiny::tagList(overview, who, what, how, when, where, how_long, funnels)
}

#' Run a product-usage query without letting a single failure blank the tab
#' @noRd
safe_pu_query <- function(fn, ...) {
  tryCatch(
    fn(...),
    error = function(e) {
      logger::log_warn(
        "product usage query failed: {conditionMessage(e)}", namespace = "shiny.telemetry"
      )
      dplyr::tibble()
    }
  )
}

#' Pull a scalar out of a 1-row summary tibble, 0 if empty/NA
#' @noRd
overview_value <- function(data, col) {
  if (nrow(data) == 0) {
    return(0)
  }
  val <- data[[col]][1]
  if (is.na(val)) 0 else val
}

#' Server logic for the "Product usage" dashboard tab
#'
#' @description
#' Renders the value boxes, plots and tables in `product_usage_ui()` from
#' the `v_*` usage-db views. If the views are not installed (see
#' [`ensure_usage_views()`]), renders a status message and returns without
#' registering any other output. Every metric query is wrapped so a single
#' failing query shows an empty state rather than breaking the tab.
#'
#' @param input,output,session standard Shiny server arguments.
#' @param data_storage a [`DataStorageSQLFamily`] instance backing the
#' dashboard (the same one passed to `prepare_admin_panel_components()`).
#'
#' @return `NULL`, invisibly. Called for side effects (registers outputs).
#' @keywords internal
#' @noRd
product_usage_server <- function(input, output, session, data_storage) {
  views_ok <- usage_views_present(data_storage)

  if (!views_ok) {
    output$usage_status <- shiny::renderUI({
      shiny::tags$div(
        class = "ui warning message",
        paste(
          "Usage views are not installed. Run",
          "shiny.telemetry::ensure_usage_views(data_storage) with a role",
          "that can create views."
        )
      )
    })
    return(invisible(NULL))
  }

  output$usage_environment_picker <- shiny::renderUI({
    envs <- tryCatch(
      data_storage$query(
        "SELECT DISTINCT environment FROM v_sessions WHERE environment IS NOT NULL ORDER BY 1"
      )[["environment"]],
      error = function(e) character(0)
    )
    shiny.semantic::selectInput(
      "usage_environment", label = NULL, choices = c("All", envs), selected = "All"
    )
  })

  env <- shiny::reactive({
    if (identical(input$usage_environment, "All")) NULL else input$usage_environment
  })

  # One reactive per metric function: shares the date window + environment
  # filter every query needs.
  usage_reactive <- function(fn) {
    shiny::reactive({
      shiny::req(input$date_from, input$date_to)
      safe_pu_query(fn, data_storage, input$date_from, input$date_to, env())
    })
  }

  overview_data <- usage_reactive(pu_overview_totals)

  daily_active_data <- usage_reactive(pu_daily_active)
  users_per_org_data <- usage_reactive(pu_users_per_org)
  recent_sessions_data <- usage_reactive(pu_recent_sessions)
  retention_data <- usage_reactive(pu_weekly_retention)

  feature_adoption_data <- usage_reactive(pu_feature_adoption)
  model_type_data <- usage_reactive(pu_model_type_mix)
  export_format_data <- usage_reactive(pu_export_format_mix)
  analysis_export_rate_data <- usage_reactive(pu_analysis_export_rate)
  download_mix_data <- usage_reactive(pu_download_mix)

  feature_error_rate_data <- usage_reactive(pu_feature_error_rate)
  model_duration_data <- usage_reactive(pu_model_duration_by_target_bucket)
  model_complexity_data <- usage_reactive(pu_model_complexity)
  qc_exclusion_data <- usage_reactive(pu_qc_exclusion_rate)

  time_to_first_model_data <- usage_reactive(pu_time_to_first_model)
  session_length_data <- usage_reactive(pu_session_length_by_env)
  weekday_hour_data <- usage_reactive(pu_sessions_by_weekday_hour)

  time_per_tab_data <- usage_reactive(pu_time_per_tab)
  tab_first_last_data <- usage_reactive(pu_tab_first_last)

  heatmap_duration_data <- usage_reactive(pu_heatmap_duration_by_sample_bucket)
  pathway_duration_data <- usage_reactive(pu_pathway_duration_by_database)
  tour_completion_data <- usage_reactive(pu_tour_completion_rate)

  tab_funnel_data <- usage_reactive(pu_tab_funnel)
  analysis_funnel_data <- usage_reactive(pu_analysis_funnel)
  tour_funnel_data <- usage_reactive(pu_tour_funnel)

  # -- Overview value boxes -------------------------------------------------

  output$usage_n_users <- semantic.dashboard::renderValueBox({
    semantic.dashboard::valueBox(
      value = overview_value(overview_data(), "n_users"),
      subtitle = shiny::tagList("Users", pu_hover("usage_n_users")),
      icon = semantic.dashboard::icon("user"), color = "blue", width = 16
    )
  })

  output$usage_n_sessions <- semantic.dashboard::renderValueBox({
    semantic.dashboard::valueBox(
      value = overview_value(overview_data(), "n_sessions"),
      subtitle = shiny::tagList("Sessions", pu_hover("usage_n_sessions")),
      icon = semantic.dashboard::icon("history"), color = "teal", width = 16
    )
  })

  output$usage_n_orgs <- semantic.dashboard::renderValueBox({
    semantic.dashboard::valueBox(
      value = overview_value(overview_data(), "n_orgs"),
      subtitle = shiny::tagList("Orgs", pu_hover("usage_n_orgs")),
      icon = semantic.dashboard::icon("sitemap"), color = "violet", width = 16
    )
  })

  output$usage_median_session_min <- semantic.dashboard::renderValueBox({
    minutes <- round(overview_value(overview_data(), "median_session_s") / 60, 1)
    semantic.dashboard::valueBox(
      value = minutes,
      subtitle = shiny::tagList("Median session (min)", pu_hover("usage_median_session_min")),
      icon = semantic.dashboard::icon("clock outline"), color = "orange", width = 16
    )
  })

  output$usage_n_models <- semantic.dashboard::renderValueBox({
    semantic.dashboard::valueBox(
      value = overview_value(overview_data(), "n_models"),
      subtitle = shiny::tagList("Models run", pu_hover("usage_n_models")),
      icon = semantic.dashboard::icon("chart line"), color = "green", width = 16
    )
  })

  output$usage_n_exports <- semantic.dashboard::renderValueBox({
    semantic.dashboard::valueBox(
      value = overview_value(overview_data(), "n_exports"),
      subtitle = shiny::tagList("Exports", pu_hover("usage_n_exports")),
      icon = semantic.dashboard::icon("download"), color = "grey", width = 16
    )
  })

  # -- Who --------------------------------------------------------------

  output$usage_daily_active_plot <- plotly::renderPlotly({
    d <- daily_active_data()
    shiny::validate(shiny::need(nrow(d) > 0, "No data in this window"))
    plotly::plot_ly(
      d, x = ~date, y = ~n_sessions, color = ~environment,
      type = "scatter", mode = "lines+markers"
    ) %>%
      plotly::layout(
        title = "Daily active sessions", xaxis = list(title = ""),
        yaxis = list(title = "Sessions")
      )
  })

  output$usage_users_per_org_table <- DT::renderDataTable({
    d <- users_per_org_data()
    shiny::validate(shiny::need(nrow(d) > 0, "No data in this window"))
    DT::datatable(d, options = list(pageLength = 10, dom = "tp"))
  })

  output$usage_recent_sessions_table <- DT::renderDataTable({
    d <- recent_sessions_data()
    shiny::validate(shiny::need(nrow(d) > 0, "No sessions in this window"))
    DT::datatable(d, options = list(pageLength = 10, dom = "ftp", order = list(list(0, "desc"))), rownames = FALSE)
  })

  output$usage_retention_plot <- plotly::renderPlotly({
    d <- retention_data()
    shiny::validate(shiny::need(nrow(d) > 0, "No data in this window"))
    plotly::plot_ly(d, x = ~week, y = ~active_this_week, type = "bar", name = "Active this week") %>%
      plotly::add_trace(y = ~active_next_week_too, name = "Active next week too") %>%
      plotly::layout(
        title = "Week-over-week retention", barmode = "group",
        xaxis = list(title = ""), yaxis = list(title = "Users")
      )
  })

  # -- What ---------------------------------------------------------------

  output$usage_feature_adoption_plot <- plotly::renderPlotly({
    d <- feature_adoption_data()
    shiny::validate(shiny::need(nrow(d) > 0, "No data in this window"))
    plotly::plot_ly(d, x = ~pct_sessions, y = ~feature, type = "bar", orientation = "h") %>%
      plotly::layout(
        title = "Feature adoption (% of sessions)",
        xaxis = list(title = "% of sessions"),
        yaxis = list(title = "", categoryorder = "total ascending")
      )
  })

  output$usage_model_type_plot <- plotly::renderPlotly({
    d <- model_type_data()
    shiny::validate(shiny::need(nrow(d) > 0, "No data in this window"))
    plotly::plot_ly(d, x = ~model_type, y = ~n_runs, type = "bar") %>%
      plotly::layout(title = "Model type mix", xaxis = list(title = ""), yaxis = list(title = "Runs"))
  })

  output$usage_export_format_plot <- plotly::renderPlotly({
    d <- export_format_data()
    shiny::validate(shiny::need(nrow(d) > 0, "No data in this window"))
    plotly::plot_ly(d, x = ~fmt, y = ~n, type = "bar") %>%
      plotly::layout(title = "Export format mix", xaxis = list(title = ""), yaxis = list(title = "Exports"))
  })

  output$usage_analysis_export_rate <- shiny::renderUI({
    d <- analysis_export_rate_data()
    shiny::validate(shiny::need(nrow(d) > 0 && d$n_opened[1] > 0, "No data in this window"))
    shiny::tags$p(sprintf(
      "%s of %s opened analyses reached export (%s%%).",
      d$n_exported[1], d$n_opened[1], d$pct_exported[1]
    ))
  })

  output$usage_download_mix_table <- DT::renderDataTable({
    d <- download_mix_data()
    shiny::validate(shiny::need(nrow(d) > 0, "No data in this window"))
    DT::datatable(d, options = list(pageLength = 10, dom = "tp"))
  })

  # -- How ------------------------------------------------------------------

  output$usage_error_rate_table <- DT::renderDataTable({
    d <- feature_error_rate_data()
    shiny::validate(shiny::need(nrow(d) > 0, "No data in this window"))
    DT::datatable(d, options = list(pageLength = 10, dom = "tp"))
  })

  output$usage_model_duration_plot <- plotly::renderPlotly({
    d <- model_duration_data()
    shiny::validate(shiny::need(nrow(d) > 0, "No data in this window"))
    d$bucket_label <- factor(d$bucket_label, levels = d$bucket_label[order(d$bucket)])
    plotly::plot_ly(d, x = ~bucket_label, y = ~median_ms, type = "bar") %>%
      plotly::layout(
        title = "Median model duration by target-count bucket",
        xaxis = list(title = "Targets in model", type = "category"), yaxis = list(title = "Median ms")
      )
  })

  output$usage_model_complexity <- shiny::renderUI({
    d <- model_complexity_data()
    shiny::validate(shiny::need(nrow(d) > 0 && !is.na(d$avg_covariates[1]), "No data in this window"))
    shiny::tags$p(sprintf(
      "Average model: %.1f covariates, %.1f interactions, %.1f ratios.",
      d$avg_covariates[1], d$avg_interactions[1], d$avg_ratios[1]
    ))
  })

  output$usage_qc_exclusion_table <- DT::renderDataTable({
    d <- qc_exclusion_data()
    shiny::validate(shiny::need(nrow(d) > 0, "No data in this window"))
    DT::datatable(d, options = list(pageLength = 10, dom = "tp"))
  })

  # -- When -----------------------------------------------------------------

  output$usage_time_to_first_model <- shiny::renderUI({
    d <- time_to_first_model_data()
    shiny::validate(shiny::need(
      nrow(d) > 0 && !is.na(d$median_seconds_to_first_model[1]), "No data in this window"
    ))
    shiny::tags$p(sprintf(
      "Median time from login to first model run: %.1f minutes.",
      d$median_seconds_to_first_model[1] / 60
    ))
  })

  output$usage_session_length_plot <- plotly::renderPlotly({
    d <- session_length_data()
    shiny::validate(shiny::need(nrow(d) > 0, "No data in this window"))
    d <- dplyr::mutate(d, median_duration_min = .data$median_duration_s / 60)
    plotly::plot_ly(d, x = ~environment, y = ~median_duration_min, type = "bar") %>%
      plotly::layout(
        title = "Median session length", xaxis = list(title = ""),
        yaxis = list(title = "Minutes")
      )
  })

  output$usage_weekday_hour_plot <- plotly::renderPlotly({
    d <- weekday_hour_data()
    shiny::validate(shiny::need(nrow(d) > 0, "No data in this window"))
    plotly::plot_ly(d, x = ~hour, y = ~weekday, z = ~n_sessions, type = "heatmap") %>%
      plotly::layout(
        title = "Sessions by weekday and hour",
        xaxis = list(title = "Hour of day"), yaxis = list(title = "ISO weekday (1 = Mon)")
      )
  })

  # -- Where ------------------------------------------------------------

  output$usage_time_per_tab_plot <- plotly::renderPlotly({
    d <- time_per_tab_data()
    shiny::validate(shiny::need(nrow(d) > 0, "No data in this window"))
    plotly::plot_ly(d, x = ~tab, y = ~total_seconds, type = "bar") %>%
      plotly::layout(
        title = "Total time spent per tab", xaxis = list(title = ""),
        yaxis = list(title = "Seconds")
      )
  })

  output$usage_first_last_tab_table <- DT::renderDataTable({
    d <- tab_first_last_data()
    shiny::validate(shiny::need(nrow(d) > 0, "No data in this window"))
    DT::datatable(d, options = list(pageLength = 10, dom = "tp"))
  })

  # -- How long ---------------------------------------------------------

  output$usage_heatmap_duration_plot <- plotly::renderPlotly({
    d <- heatmap_duration_data()
    shiny::validate(shiny::need(nrow(d) > 0, "No data in this window"))
    d$bucket_label <- factor(d$bucket_label, levels = d$bucket_label[order(d$sample_bucket)])
    plotly::plot_ly(d, x = ~bucket_label, y = ~median_ms, type = "bar") %>%
      plotly::layout(
        title = "Heatmap run duration by sample-count bucket",
        xaxis = list(title = "Samples in heatmap", type = "category"), yaxis = list(title = "Median ms")
      )
  })

  output$usage_pathway_duration_plot <- plotly::renderPlotly({
    d <- pathway_duration_data()
    shiny::validate(shiny::need(nrow(d) > 0, "No data in this window"))
    plotly::plot_ly(d, x = ~database, y = ~median_ms, type = "bar") %>%
      plotly::layout(
        title = "Pathway run duration by database", xaxis = list(title = ""),
        yaxis = list(title = "Median ms")
      )
  })

  output$usage_tour_completion_table <- DT::renderDataTable({
    d <- tour_completion_data()
    shiny::validate(shiny::need(nrow(d) > 0, "No data in this window"))
    DT::datatable(d, options = list(pageLength = 10, dom = "tp"))
  })

  # -- Funnels --------------------------------------------------------------

  output$usage_tab_funnel_plot <- plotly::renderPlotly({
    d <- tab_funnel_data()
    shiny::validate(shiny::need(nrow(d) > 0 && d$n_upload[1] > 0, "No data in this window"))
    stages <- c("Upload", "QC", "Stats", "Export")
    plotly::plot_ly(
      x = stages, y = c(d$n_upload[1], d$n_qc[1], d$n_stats[1], d$n_download[1]), type = "bar"
    ) %>%
      plotly::layout(
        title = "Tab funnel", xaxis = list(title = "", categoryorder = "array", categoryarray = stages),
        yaxis = list(title = "Sessions")
      )
  })

  output$usage_analysis_funnel_plot <- plotly::renderPlotly({
    d <- analysis_funnel_data()
    shiny::validate(shiny::need(nrow(d) > 0 && d$n_opened[1] > 0, "No data in this window"))
    stages <- c("Opened", "Modeled", "Exported")
    plotly::plot_ly(
      x = stages, y = c(d$n_opened[1], d$n_modeled[1], d$n_exported[1]), type = "bar"
    ) %>%
      plotly::layout(
        title = "Analysis funnel", xaxis = list(title = "", categoryorder = "array", categoryarray = stages),
        yaxis = list(title = "Analyses")
      )
  })

  output$usage_tour_funnel_plot <- plotly::renderPlotly({
    d <- tour_funnel_data()
    total <- if (nrow(d) > 0) d$n_offered[1] + d$n_started[1] + d$n_completed[1] else 0
    shiny::validate(shiny::need(total > 0, "No data in this window"))
    stages <- c("Offered", "Started", "Completed")
    plotly::plot_ly(
      x = stages, y = c(d$n_offered[1], d$n_started[1], d$n_completed[1]), type = "bar"
    ) %>%
      plotly::layout(
        title = "Tour funnel", xaxis = list(title = "", categoryorder = "array", categoryarray = stages),
        yaxis = list(title = "Tours")
      )
  })

  # -- CSV download -----------------------------------------------------

  output$usage_download_features <- shiny::downloadHandler(
    filename = function() {
      sprintf("usage_feature_events_%s_%s.csv", input$date_from, input$date_to)
    },
    content = function(file) {
      shiny::req(input$date_from, input$date_to)
      d <- safe_pu_query(
        pu_feature_events_export, data_storage, input$date_from, input$date_to, env()
      )
      utils::write.csv(d, file, row.names = FALSE)
    }
  )

  invisible(NULL)
}
