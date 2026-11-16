#' Send outputs, metrics and logs to Kestra
#'
#' Each function prints one `::{...}::` line to stdout, which Kestra parses
#' into task outputs, metrics or logs.
#'
#' @examples
#' Kestra$outputs(list(accuracy = 0.91))
#' Kestra$counter("rows", 15000, list(source = "s3"))
#' model <- Kestra$timer("fit", function() lm(dist ~ speed, cars))
#' Kestra$logger()$warn("3 rows had missing values")
#' @importFrom jsonlite toJSON
#' @export
Kestra <- new.env(parent = emptyenv())

Kestra$format <- function(map) {
  json <- jsonlite::toJSON(map, auto_unbox = TRUE, digits = NA, na = "null", null = "null", POSIXt = "ISO8601", UTC = TRUE)
  # Kestra matches one line, and Java treats U+0085, U+2028 and U+2029 as line terminators.
  for (char in c("\u0085", "\u2028", "\u2029")) {
    json <- gsub(char, sprintf("\\u%04x", utf8ToInt(char)), json, fixed = TRUE)
  }
  paste0("::", json, "::")
}

Kestra$outputs <- function(outputs) {
  send(list(outputs = as_object(outputs, "outputs")))
}

Kestra$counter <- function(name, value, tags = NULL) {
  send_metric(name, "counter", value, tags)
}

Kestra$gauge <- function(name, value, tags = NULL) {
  send_metric(name, "gauge", value, tags)
}

# `duration` is seconds, or a no-argument function that is timed and whose result is returned.
Kestra$timer <- function(name, duration, tags = NULL) {
  if (!is.function(duration)) {
    return(send_metric(name, "timer", duration, tags))
  }

  start <- proc.time()[["elapsed"]]
  result <- duration()
  send_metric(name, "timer", proc.time()[["elapsed"]] - start, tags)
  invisible(result)
}

Kestra$logger <- function() {
  log_at <- function(level) {
    function(...) send(list(logs = list(list(level = level, message = paste0(..., collapse = "")))))
  }

  list(
    trace = log_at("TRACE"),
    debug = log_at("DEBUG"),
    info = log_at("INFO"),
    warn = log_at("WARN"),
    error = log_at("ERROR")
  )
}

send <- function(map) {
  # Bytes as-is, so a non-UTF-8 locale cannot turn characters into <U+00E9> escapes.
  writeLines(enc2utf8(Kestra$format(map)), con = stdout(), useBytes = TRUE)
  invisible(NULL)
}

send_metric <- function(name, type, value, tags) {
  if (!is.character(name) || length(name) != 1 || is.na(name) || !nzchar(name)) {
    stop("Metric name must be a single non-empty string.", call. = FALSE)
  }
  if (!is.numeric(value) || length(value) != 1 || !is.finite(value)) {
    stop(sprintf("Metric '%s' value must be a single finite number.", name), call. = FALSE)
  }

  tags <- if (length(tags) == 0) structure(list(), names = character(0)) else as_object(tags, "tags")
  send(list(metrics = list(list(name = name, type = type, value = value, tags = tags))))
}

# Unnamed lists would serialize as JSON arrays, so require a name on every element.
as_object <- function(x, what) {
  keys <- names(x)
  if (length(x) == 0 || is.null(keys) || any(is.na(keys) | keys == "")) {
    stop(sprintf("%s must be a non-empty named list, for example list(key = \"value\").", what), call. = FALSE)
  }
  as.list(x)
}
