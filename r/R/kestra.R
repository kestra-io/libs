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
# Built with intToUtf8(), since string literals installed under a C locale lose their UTF-8 mark.
line_terminators <- intToUtf8(c(0x85, 0x2028, 0x2029), multiple = TRUE)
escaped_terminators <- c("\\u0085", "\\u2028", "\\u2029")

Kestra$format <- function(map) {
  json <- jsonlite::toJSON(prepare(map), auto_unbox = TRUE, digits = NA, na = "null", null = "null", POSIXt = "ISO8601", UTC = TRUE)
  for (i in seq_along(line_terminators)) {
    json <- gsub(line_terminators[[i]], escaped_terminators[[i]], json, fixed = TRUE)
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
  env_file <- Sys.getenv("KESTRA_EXECUTION_CONTEXT_FILE")
  file <- if (!is.null(path)) path else if (nzchar(env_file)) env_file else context_file
  is_file <- file_test("-f", file)
  encoded <- Sys.getenv("KESTRA_CONTEXT")
  json <- if (is_file) {
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
  context <- tryCatch(jsonlite::fromJSON(json, simplifyVector = FALSE), error = function(e) NULL)
  if (!is.list(context) || (length(context) > 0 && is.null(names(context)))) {
    stop(sprintf("The execution context in %s is not a JSON object.", if (is_file) file else "KESTRA_CONTEXT"), call. = FALSE)
  }
  if (is.null(path)) {
    cache$context <- context
  }
  context
}

send <- function(map) {
  # Bytes as-is, so a non-UTF-8 locale cannot turn characters into <U+00E9> escapes.
  writeLines(enc2utf8(Kestra$format(map)), con = stdout(), useBytes = TRUE)
  # Kestra reads a pipe, where output is buffered, so flush to deliver each line when it is written.
  flush(stdout())
  invisible(NULL)
}

send_metric <- function(name, type, value, tags) {
  if (!is.character(name) || length(name) != 1 || is.na(name) || !nzchar(name)) {
    stop("Metric name must be a single non-empty string.", call. = FALSE)
  }
  if (inherits(value, "difftime")) {
    value <- as.numeric(value, units = "secs")
  }
  if (!is.numeric(value) || length(value) != 1 || !is.finite(value)) {
    stop(sprintf("Metric '%s' value must be a single finite number.", name), call. = FALSE)
  }

  # Kestra reads tags as a map of strings.
  tags <- if (length(tags) == 0) structure(list(), names = character(0)) else as_object(tags, "tags")
  for (key in names(tags)) {
    tag <- tags[[key]]
    if (!is.atomic(tag) || length(tag) != 1 || is.na(tag)) {
      stop(sprintf("Metric '%s' tag '%s' must be a single value, for example list(env = \"prod\").", name, key), call. = FALSE)
    }
    tags[[key]] <- as.character(tag)
  }
  # unname(), since a named number such as quantile(x, 0.95) would be sent as an object.
  send(list(metrics = list(list(name = name, type = type, value = unname(value), tags = tags))))
}

# Prepares a value for toJSON: named vectors (summary(), coef()) become objects instead of arrays, POSIXlt keeps
# its time zone, and invalid UTF-8 bytes, for example from a latin1 file, become U+FFFD instead of failing.
prepare <- function(x) {
  if (inherits(x, "POSIXlt")) {
    x <- as.POSIXct(x)
  }
  if (is.list(x) && !is.data.frame(x)) {
    x[] <- lapply(x, prepare)
    names(x) <- utf8(names(x))
    return(x)
  }
  if (is.character(x)) {
    x[] <- utf8(x)
  }
  if (is.atomic(x) && !is.null(names(x)) && !inherits(x, "AsIs")) {
    x <- as.list(x)
    names(x) <- utf8(names(x))
  }
  x
}

utf8 <- function(x) {
  if (is.null(x)) {
    return(x)
  }
  # Undeclared strings hold UTF-8 bytes in a UTF-8 or C locale, and enc2utf8() would turn them into <e9> under C.
  is_declared <- Encoding(x) != "unknown" | isTRUE(l10n_info()[["Latin-1"]])
  x[is_declared] <- enc2utf8(x[is_declared])
  is_invalid <- !is.na(x) & !validUTF8(x)
  if (any(is_invalid)) {
    # iconv() converts its replacement to the native encoding, so substitute ASCII SUB, then swap in U+FFFD as bytes.
    x[is_invalid] <- gsub("\x1a", intToUtf8(0xfffd), iconv(x[is_invalid], "UTF-8", "UTF-8", sub = "\x1a"), fixed = TRUE, useBytes = TRUE)
  }
  Encoding(x) <- "UTF-8"
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
