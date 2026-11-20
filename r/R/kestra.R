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
  if (length(outputs) == 0) {
    return(invisible(NULL))
  }
  send(list(outputs = as_object(outputs, "Outputs")))
}

Kestra$assets <- function(assets) {
  if (length(assets) == 0) {
    return(invisible(NULL))
  }
  assets <- as_object(assets, "Assets")
  for (key in names(assets)) {
    if (!key %in% c("inputs", "outputs")) {
      stop(sprintf("Assets hold only inputs and outputs, not '%s'.", key), call. = FALSE)
    }
    # toJSON sends a data frame as a list of rows.
    if (!is.data.frame(assets[[key]]) && (!is.list(assets[[key]]) || !is.null(names(assets[[key]])))) {
      stop(sprintf("Asset %s must be an unnamed list, for example list(list(id = \"sales.orders\", type = \"TABLE\")).", key), call. = FALSE)
    }
  }
  send(list(assets = assets))
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

  # Checked before the function runs, so a typo does not cost a long run.
  tags <- metric_tags(name, tags)
  start <- proc.time()[["elapsed"]]
  result <- duration()
  send_metric(name, "timer", proc.time()[["elapsed"]] - start, tags)
  invisible(result)
}

log_at <- function(level) {
  # Each argument is collapsed first, so a vector prints like cat() does instead of recycling the other arguments.
  function(...) {
    message <- paste0(vapply(list(...), log_text, character(1)), collapse = "")
    send(list(logs = list(list(level = level, message = message))))
  }
}

max_log_values <- 1000

# A log call never fails: values paste() cannot read, such as environments and functions, are shown by their class.
log_text <- function(x) {
  extra <- length(x) - max_log_values
  text <- tryCatch({
    if (extra > 0) x <- x[seq_len(max_log_values)]
    paste(x, collapse = " ")
  }, error = function(e) NULL)
  if (!is.character(text) || length(text) != 1) {
    return(sprintf("<%s>", class(x)[[1]]))
  }
  if (extra > 0) sprintf("%s ... and %d more", text, extra) else text
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
  if (identical(path, "")) {
    path <- NULL
  }
  if (is.null(path) && !is.null(cache$context)) {
    return(cache$context)
  }
  env_file <- Sys.getenv("KESTRA_EXECUTION_CONTEXT_FILE")
  file <- if (!is.null(path)) path else if (nzchar(env_file)) env_file else context_file
  # Only a missing file falls back: a directory or an unreadable file is reported.
  is_file <- file.exists(file)
  encoded <- gsub("[[:space:]]", "", Sys.getenv("KESTRA_CONTEXT"))
  json <- if (is_file) {
    read_context_file(file)
  } else if (is.null(path) && nzchar(encoded)) {
    if (nchar(encoded) %% 4 != 0 || !grepl("^[A-Za-z0-9+/]*={0,2}$", encoded)) {
      stop("The KESTRA_CONTEXT environment variable is not valid base64.", call. = FALSE)
    }
    rawToChar(jsonlite::base64_dec(encoded))
  } else if (!is.null(path)) {
    stop(sprintf("Kestra execution context file '%s' does not exist.", path), call. = FALSE)
  } else {
    stop(sprintf(paste(
      "No Kestra execution context found: '%s' does not exist and the KESTRA_CONTEXT environment variable is not set.",
      "The execution context is only available when the script runs inside a Kestra task."
    ), file), call. = FALSE)
  }
  Encoding(json) <- "UTF-8"
  source <- if (is_file) file else "KESTRA_CONTEXT"
  context <- tryCatch(jsonlite::fromJSON(json, simplifyVector = FALSE), error = function(e) {
    stop(sprintf("The execution context in %s is not valid JSON.", source), call. = FALSE)
  })
  # An empty JSON array reads as an empty list too.
  if (!is.list(context) || !grepl("^[[:space:]]*[{]", json)) {
    stop(sprintf("The execution context in %s is not a JSON object.", source), call. = FALSE)
  }
  if (is.null(path)) {
    cache$context <- context
  }
  context
}

read_context_file <- function(file) {
  fail <- function(e) {
    stop(sprintf("Kestra execution context file '%s' cannot be read: %s", file, conditionMessage(e)), call. = FALSE)
  }
  if (dir.exists(file)) {
    stop(sprintf("Kestra execution context file '%s' cannot be read: it is a directory.", file), call. = FALSE)
  }
  tryCatch(readChar(file, file.size(file), useBytes = TRUE), warning = fail, error = fail)
}

send <- function(map) {
  # Bytes as-is, so a non-UTF-8 locale cannot turn characters into <U+00E9> escapes.
  writeLines(enc2utf8(Kestra$format(map)), con = stdout(), useBytes = TRUE)
  # Kestra reads a pipe, where output is buffered, so flush to deliver each line when it is written.
  flush(stdout())
  invisible(NULL)
}

send_metric <- function(name, type, value, tags) {
  tags <- metric_tags(name, tags)
  if (inherits(value, "difftime")) {
    value <- as.numeric(value, units = "secs")
  }
  if (!is.numeric(value) || length(value) != 1 || !is.finite(value)) {
    stop(sprintf("Metric '%s' value must be a single finite number.", name), call. = FALSE)
  }
  # unname(), since a named number such as quantile(x, 0.95) would be sent as an object.
  send(list(metrics = list(list(name = name, type = type, value = unname(value), tags = tags))))
}

# Checks the name and returns the tags as a named list of strings, which is how Kestra reads them.
metric_tags <- function(name, tags) {
  if (!is.character(name) || length(name) != 1 || is.na(name) || !nzchar(name)) {
    stop("Metric name must be a single non-empty string.", call. = FALSE)
  }
  if (length(tags) == 0) {
    return(structure(list(), names = character(0)))
  }
  tags <- as_object(tags, sprintf("Metric '%s' tags", name))
  names(tags) <- utf8(names(tags))
  duplicate <- anyDuplicated(names(tags))
  if (duplicate > 0) {
    stop(sprintf("Metric '%s' has two tags named '%s'.", name, names(tags)[[duplicate]]), call. = FALSE)
  }
  for (key in names(tags)) {
    tag <- tags[[key]]
    if (!is.atomic(tag) || length(tag) != 1 || is.na(tag)) {
      stop(sprintf("Metric '%s' tag '%s' must be a single value, for example list(env = \"prod\").", name, key), call. = FALSE)
    }
    tags[[key]] <- if (is.logical(tag)) {
      if (tag) "true" else "false"
    } else if (is.numeric(tag) && !is.object(tag)) {
      # as.character() would send 100000 as "1e+05".
      format(tag, digits = 15, scientific = FALSE, trim = TRUE)
    } else {
      as.character(tag)
    }
  }
  tags
}

# Prepares a value for toJSON: named vectors (summary(), coef()) become objects instead of arrays, POSIXlt keeps
# its time zone, and invalid UTF-8 bytes, for example from a latin1 file, become U+FFFD instead of failing.
prepare <- function(x) {
  if (inherits(x, "POSIXlt")) {
    x <- as.POSIXct(x)
  }
  if (!is.null(x) && !is.atomic(x) && !is.list(x)) {
    stop(sprintf(
      "This value cannot be sent to Kestra as JSON: %s is not a list, vector, data frame or date. Convert it first, for example with as.character().",
      class(x)[[1]]
    ), call. = FALSE)
  }
  if (is.data.frame(x)) {
    lapply(x, check_finite)
    return(x)
  }
  if (is.list(x)) {
    x[] <- lapply(x, prepare)
    names(x) <- utf8(names(x))
    check_keys(names(x))
    return(x)
  }
  check_finite(x)
  if (is.character(x)) {
    x[] <- utf8(x)
  }
  if (is.atomic(x) && !is.null(names(x)) && !inherits(x, "AsIs")) {
    x <- as.list(x)
    names(x) <- utf8(names(x))
    check_keys(names(x))
  }
  x
}

# toJSON would send NaN and Inf as strings, which a reader takes for text.
check_finite <- function(x) {
  if (is.double(x) && any(is.nan(x) | is.infinite(x))) {
    stop("This value cannot be sent to Kestra as JSON. Replace NaN and Inf with NA.", call. = FALSE)
  }
}

# toJSON would write both keys, and a reader keeps only one of them.
check_keys <- function(keys) {
  keys <- keys[!is.na(keys) & nzchar(keys)]
  duplicate <- anyDuplicated(keys)
  if (duplicate > 0) {
    stop(sprintf("This value cannot be sent to Kestra as JSON: two keys read as '%s'.", keys[[duplicate]]), call. = FALSE)
  }
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
  if (is.null(keys) || any(is.na(keys) | keys == "")) {
    stop(sprintf("%s must be a named list, for example list(key = \"value\").", what), call. = FALSE)
  }
  as.list(x)
}
