#' Install/update the usage-db answer-layer views
#'
#' @description
#' Applies `inst/sql/usage-db.schema.sql` (indexes, JSON accessor functions,
#' and the `v_*` reporting views the product-usage dashboard queries) against
#' the connection held by `data_storage`. The script is idempotent: it uses
#' `CREATE INDEX IF NOT EXISTS` and `CREATE OR REPLACE FUNCTION`/`VIEW`, so
#' re-running it (e.g. after `event_log`'s JSON shape gains a new field) is
#' expected and safe.
#'
#' Postgres-only. The connecting role must be allowed to create functions and
#' views in the `public` schema. This is meant to be run once, by hand, from
#' the analytics dashboard process (or an admin session) against a
#' `DataStorageSQLFamily`-backed store -- never from the instrumented app
#' itself, which only ever needs to `insert()`.
#'
#' @param data_storage a [`DataStorageSQLFamily`] instance (e.g.
#' [`DataStoragePostgreSQL`]) connected to the usage database.
#'
#' @return The number of SQL statements applied, invisibly.
#'
#' @export
ensure_usage_views <- function(data_storage) {
  checkmate::assert_r6(data_storage, "DataStorageSQLFamily")

  schema_file <- system.file("sql", "usage-db.schema.sql", package = "shiny.telemetry")
  checkmate::assert_file_exists(schema_file)

  statements <- split_sql_statements(readLines(schema_file, warn = FALSE))
  statements <- Filter(is_executable_sql, statements)

  purrr::walk(statements, data_storage$execute)

  n_statements <- length(statements)
  logger::log_info(
    "ensure_usage_views: applied {n_statements} statement(s) from usage-db.schema.sql",
    namespace = "shiny.telemetry"
  )

  invisible(n_statements)
}

#' Split a SQL script into statements on the `-- @@` marker
#'
#' @description
#' `usage-db.schema.sql` is written as multiple standalone statements
#' separated by lines that are exactly `-- @@`, because RPostgres (unlike
#' psql) refuses to run multi-statement strings. This groups the file's
#' lines back into per-statement chunks; the marker lines themselves are
#' dropped.
#'
#' @param lines character vector, one element per line of the SQL file.
#'
#' @return character vector, one element per statement.
#' @noRd
split_sql_statements <- function(lines) {
  marker <- lines == "-- @@"
  chunk_id <- cumsum(marker)
  chunks <- split(lines[!marker], chunk_id[!marker])
  vapply(chunks, paste, character(1), collapse = "\n")
}

#' Is a SQL chunk worth sending to the server
#'
#' @description
#' TRUE if `statement` has at least one line that is not blank and not a
#' `--` comment. Guards against sending a chunk that is only file-header
#' commentary (e.g. the block before the first statement).
#'
#' @param statement single SQL string, possibly multi-line.
#'
#' @return logical scalar.
#' @noRd
is_executable_sql <- function(statement) {
  lines <- trimws(strsplit(statement, "\n", fixed = TRUE)[[1]])
  lines <- lines[nzchar(lines)]
  any(!startsWith(lines, "--"))
}

#' Check whether the usage-db reporting views are installed
#'
#' @description
#' Cheap existence check for `public.v_sessions`, used to decide whether the
#' product-usage tab has anything to query. Returns `FALSE` (rather than
#' raising) on any connection or permission error, since the dashboard
#' should degrade to a status message, not crash.
#'
#' @param data_storage a [`DataStorageSQLFamily`] instance.
#'
#' @return logical scalar.
#' @noRd
usage_views_present <- function(data_storage) {
  result <- tryCatch(
    data_storage$query(
      paste(
        "SELECT 1 FROM information_schema.views",
        "WHERE table_schema = 'public' AND table_name = 'v_sessions'"
      )
    ),
    error = function(e) NULL
  )

  !is.null(result) && nrow(result) > 0
}
