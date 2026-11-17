#' Send outputs, metrics, logs and assets to Kestra, and read the execution context
#'
#' Each send function prints one `::{...}::` line to stdout, which Kestra parses
#' into task outputs, metrics, logs or assets.
#'
#' `Kestra$context(path = NULL)` returns the execution context as a list, read
#' from `path`, the `KESTRA_EXECUTION_CONTEXT_FILE` environment variable or
#' `.kestra-execution-context.json` (written when the task sets
#' `executionContext: true`). Without `path`, it falls back to the base64-encoded
#' `KESTRA_CONTEXT` environment variable. The default context is read once and
#' cached. It fails outside a Kestra task.
#'
#' @examples
#' Kestra$outputs(list(accuracy = 0.91))
#' Kestra$assets(list(outputs = list(list(id = "sales.orders", type = "TABLE"))))
#' Kestra$counter("rows", 15000, list(source = "s3"))
#' model <- Kestra$timer("fit", function() lm(dist ~ speed, cars))
#' Kestra$logger()$warn("3 rows had missing values")
#' @importFrom jsonlite toJSON fromJSON base64_dec
#' @export
Kestra <- new.env(parent = emptyenv())

# Kestra matches one line, and Java treats these as line terminators.
line_terminators <- c("\u0085" = "\\u0085", "\u2028" = "\\u2028", "\u2029" = "\\u2029")

Kestra$format <- function(map) {
  json <- jsonlite::toJSON(name_vectors(map), auto_unbox = TRUE, digits = NA, na = "null", null = "null", POSIXt = "ISO8601", UTC = TRUE)
  for (char in names(line_terminators)) {
    json <- gsub(char, line_terminators[[char]], json, fixed = TRUE)
  }
  paste0("::", json, "::")
}

Kestra$outputs <- function(outputs) {
  send(list(outputs = as_object(outputs, "outputs")))
}

Kestra$assets <- function(assets) {
  send(list(assets = as_object(assets, "assets")))
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

log_at <- function(level) {
  # Each argument is collapsed first, so a vector prints like cat() does instead of recycling the other arguments.
  function(...) {
    message <- paste0(vapply(list(...), paste, character(1), collapse = " "), collapse = "")
    send(list(logs = list(list(level = level, message = message))))
  }
}

logger <- list(
  trace = log_at("TRACE"),
  debug = log_at("DEBUG"),
  info = log_at("INFO"),
  warn = log_at("WARN"),
  error = log_at("ERROR")
)

Kestra$logger <- function() logger

context_file <- ".kestra-execution-context.json"
cache <- new.env(parent = emptyenv())

Kestra$context <- function(path = NULL) {
  if (is.null(path) && !is.null(cache$context)) {
    return(cache$context)
  }
  file <- if (is.null(path)) Sys.getenv("KESTRA_EXECUTION_CONTEXT_FILE", context_file) else path
  encoded <- Sys.getenv("KESTRA_CONTEXT")
  json <- if (file.exists(file)) {
    readChar(file, file.size(file), useBytes = TRUE)
  } else if (is.null(path) && nzchar(encoded)) {
    rawToChar(jsonlite::base64_dec(encoded))
  } else {
    stop(sprintf(paste(
      "No Kestra execution context found: '%s' does not exist and the KESTRA_CONTEXT environment variable is not set.",
      "The execution context is only available when the script runs inside a Kestra task."
    ), file), call. = FALSE)
  }
  Encoding(json) <- "UTF-8"
  context <- jsonlite::fromJSON(json, simplifyVector = FALSE)
  if (is.null(path)) {
    cache$context <- context
  }
  context
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

# toJSON writes named vectors as arrays, which drops names such as those from summary() or coef(), so make them objects.
name_vectors <- function(x) {
  if (is.list(x) && !is.data.frame(x)) {
    x[] <- lapply(x, name_vectors)
    return(x)
  }
  if (is.atomic(x) && !is.null(names(x)) && !inherits(x, "AsIs")) {
    return(as.list(x))
  }
  x
}

# Unnamed lists would serialize as JSON arrays, so require a name on every element.
as_object <- function(x, what) {
  keys <- names(x)
  if (length(x) == 0 || is.null(keys) || any(is.na(keys) | keys == "")) {
    stop(sprintf("%s must be a non-empty named list, for example list(key = \"value\").", what), call. = FALSE)
  }
  as.list(x)
}
