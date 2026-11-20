# The package writes UTF-8 bytes, which capture.output() returns unmarked in a C locale.
emitted <- function(expr) {
  lines <- capture.output(expr)
  Encoding(lines) <- "UTF-8"
  lines
}

test_that("outputs are one line with unboxed scalars, full precision and nulls", {
  line <- emitted(Kestra$outputs(list(accuracy = 0.912345678, model = "glm", missing = NA, tags = I("a"))))

  expect_identical(line, '::{"outputs":{"accuracy":0.912345678,"model":"glm","missing":null,"tags":["a"]}}::')
})

test_that("multi-line strings and Java line terminators stay on one line", {
  line <- emitted(Kestra$outputs(list(text = "a\nb\u2028c\u2029d\u0085e")))

  expect_length(line, 1)
  expect_identical(line, '::{"outputs":{"text":"a\\nb\\u2028c\\u2029d\\u0085e"}}::')
})

test_that("date-times are sent in UTC and non-ASCII text round-trips", {
  when <- as.POSIXct("2026-11-16 10:00:00", tz = "Europe/Paris")

  expect_identical(emitted(Kestra$outputs(list(when = when))), '::{"outputs":{"when":"2026-11-16T09:00:00Z"}}::')
  expect_identical(emitted(Kestra$outputs(list(name = "caf\u00e9"))), enc2utf8('::{"outputs":{"name":"caf\u00e9"}}::'))
})

test_that("outputs must be a named list, and an empty one sends nothing", {
  expect_error(Kestra$outputs(list(1, 2)), "Outputs must be a named list")
  expect_identical(emitted(Kestra$outputs(list())), character(0))
})

test_that("two keys that read the same fail instead of sending both", {
  expect_error(Kestra$outputs(list(a = 1, a = 2)), "two keys read as 'a'", fixed = TRUE)
  expect_error(Kestra$outputs(list(x = list(b = 1, b = 2))), "two keys read as 'b'", fixed = TRUE)
  expect_error(Kestra$outputs(list(x = c(b = 1, b = 2))), "two keys read as 'b'", fixed = TRUE)
})

test_that("NaN, Inf and values JSON cannot carry fail with a plain sentence", {
  expect_error(Kestra$outputs(list(x = NaN)), "Replace NaN and Inf with NA.", fixed = TRUE)
  expect_error(Kestra$outputs(list(x = c(1, -Inf))), "Replace NaN and Inf with NA.", fixed = TRUE)
  expect_error(Kestra$outputs(list(x = data.frame(a = Inf))), "Replace NaN and Inf with NA.", fixed = TRUE)
  expect_error(Kestra$outputs(list(x = sum)), "function is not a list, vector, data frame or date", fixed = TRUE)
  expect_error(Kestra$outputs(list(x = new.env())), "environment is not a list, vector, data frame or date", fixed = TRUE)
  expect_identical(emitted(Kestra$outputs(list(day = as.Date("2026-11-16")))), '::{"outputs":{"day":"2026-11-16"}}::')
})

test_that("metrics default to empty tags and accept named vectors as tags", {
  expect_identical(
    emitted(Kestra$counter("rows", 15000)),
    '::{"metrics":[{"name":"rows","type":"counter","value":15000,"tags":{}}]}::'
  )
  expect_identical(
    emitted(Kestra$gauge("queue", 3, c(env = "prod"))),
    '::{"metrics":[{"name":"queue","type":"gauge","value":3,"tags":{"env":"prod"}}]}::'
  )
})

test_that("empty tags are allowed", {
  expect_identical(
    emitted(Kestra$counter("rows", 1, list())),
    '::{"metrics":[{"name":"rows","type":"counter","value":1,"tags":{}}]}::'
  )
})

test_that("two tags with the same name fail instead of sending one", {
  expect_error(Kestra$counter("rows", 1, list(env = "a", env = "b")), "Metric 'rows' has two tags named 'env'.", fixed = TRUE)
})

test_that("metrics reject invalid names and values", {
  expect_error(Kestra$counter("", 1), "Metric name must be a single non-empty string")
  expect_error(Kestra$counter("rows", c(1, 2)), "Metric 'rows' value must be a single finite number")
  expect_error(Kestra$gauge("rows", NaN), "Metric 'rows' value must be a single finite number")
})

test_that("timer measures a function and returns its result", {
  result <- NULL
  line <- emitted(result <- Kestra$timer("fit", function() {
    Sys.sleep(0.2)
    42
  }))

  expect_identical(result, 42)
  payload <- jsonlite::fromJSON(sub("^::(.*)::$", "\\1", line))
  expect_identical(payload$metrics$type, "timer")
  # proc.time() can read slightly under the slept time.
  expect_gt(payload$metrics$value, 0.15)
})

test_that("timer checks the name and tags before running the function", {
  is_run <- FALSE
  expect_error(Kestra$timer("fit", function() is_run <<- TRUE, list("prod")), "Metric 'fit' tags must be a named list")
  expect_error(Kestra$timer("", function() is_run <<- TRUE), "Metric name must be a single non-empty string")
  expect_false(is_run)
})

test_that("timer sends nothing when the function fails", {
  expect_identical(emitted(try(Kestra$timer("fit", function() stop("boom")), silent = TRUE)), character(0))
})

test_that("logger never fails on values paste() cannot read, such as an environment that contains itself", {
  env <- new.env()
  env$self <- env
  expect_identical(
    emitted(Kestra$logger()$info("values: ", env, " ", sum)),
    '::{"logs":[{"level":"INFO","message":"values: <environment> <function>"}]}::'
  )
})

test_that("logger shows the first 1000 values of a long vector", {
  message <- jsonlite::fromJSON(sub("^::(.*)::$", "\\1", emitted(Kestra$logger()$info(seq_len(1500)))))$logs$message
  expect_identical(message, paste(paste(1:1000, collapse = " "), "... and 500 more"))
})

test_that("logger emits the level and joins the message parts", {
  expect_identical(
    emitted(Kestra$logger()$warn("3 rows ", "had missing values")),
    '::{"logs":[{"level":"WARN","message":"3 rows had missing values"}]}::'
  )
})

test_that("logger always sends one string, even for vectors or no arguments", {
  expect_identical(
    emitted(Kestra$logger()$info("ids ", c("x", "y", "z"), " done")),
    '::{"logs":[{"level":"INFO","message":"ids x y z done"}]}::'
  )
  expect_identical(emitted(Kestra$logger()$info()), '::{"logs":[{"level":"INFO","message":""}]}::')
})

test_that("named vectors keep their names at any depth", {
  line <- emitted(Kestra$outputs(list(stats = c(mean = 1.2, sd = 0.3), top = c(a = 1), nested = list(q = c(p50 = 2)), ids = c(1, 2))))

  expect_identical(line, '::{"outputs":{"stats":{"mean":1.2,"sd":0.3},"top":{"a":1},"nested":{"q":{"p50":2}},"ids":[1,2]}}::')
})

test_that("POSIXlt keeps its time zone and invalid UTF-8 becomes U+FFFD", {
  when <- as.POSIXlt("2026-11-16 10:00:00", tz = "Europe/Paris")

  expect_identical(emitted(Kestra$outputs(list(when = when))), '::{"outputs":{"when":"2026-11-16T09:00:00Z"}}::')
  expect_identical(emitted(Kestra$outputs(list(name = "caf\xe9"))), enc2utf8('::{"outputs":{"name":"caf\ufffd"}}::'))
})

test_that("metric values are plain numbers and tags are strings", {
  line <- emitted(Kestra$gauge("p95", quantile(c(1, 5, 9), 0.95), list(shard = 2, primary = TRUE, rows = 1e5)))
  expect_identical(line, '::{"metrics":[{"name":"p95","type":"gauge","value":8.6,"tags":{"shard":"2","primary":"true","rows":"100000"}}]}::')

  expect_identical(
    emitted(Kestra$timer("fit", as.difftime(2, units = "mins"))),
    '::{"metrics":[{"name":"fit","type":"timer","value":120,"tags":{}}]}::'
  )
  expect_error(Kestra$gauge("q", 1, list(env = c("a", "b"))), "tag 'env' must be a single value")
  expect_error(Kestra$gauge("q", 1, list(env = NA)), "tag 'env' must be a single value")
  expect_error(Kestra$gauge("q", 1, list(env = list(a = 1))), "tag 'env' must be a single value")
})

test_that("assets are sent as a named list", {
  line <- emitted(Kestra$assets(list(
    inputs = list(list(id = "raw.orders")),
    outputs = list(list(id = "sales.orders", type = "TABLE", metadata = list(owner = "team_a")))
  )))

  expect_identical(line, paste0(
    '::{"assets":{"inputs":[{"id":"raw.orders"}],',
    '"outputs":[{"id":"sales.orders","type":"TABLE","metadata":{"owner":"team_a"}}]}}::'
  ))
  expect_identical(emitted(Kestra$assets(list(outputs = list()))), '::{"assets":{"outputs":[]}}::')
  expect_identical(emitted(Kestra$assets(list())), character(0))
  expect_identical(
    emitted(Kestra$assets(list(outputs = data.frame(id = "a", type = "TABLE")))),
    '::{"assets":{"outputs":[{"id":"a","type":"TABLE"}]}}::'
  )
})

test_that("assets hold only inputs and outputs lists", {
  expect_error(Kestra$assets(list(output = list())), "Assets hold only inputs and outputs, not 'output'.", fixed = TRUE)
  expect_error(Kestra$assets(list(inputs = list(id = "raw.orders"))), "Asset inputs must be an unnamed list", fixed = TRUE)
  expect_error(Kestra$assets(list(inputs = "raw.orders")), "Asset inputs must be an unnamed list", fixed = TRUE)
})

context_json <- '{"labels":{"env":"prod"},"inputs":{"text":"a\\nb caf\\u00e9","files":[{"name":"first"},2]}}'

with_context_file <- function(code) {
  file <- tempfile(fileext = ".json")
  writeLines(context_json, file)
  old <- Sys.getenv(c("KESTRA_EXECUTION_CONTEXT_FILE", "KESTRA_CONTEXT"), unset = NA)
  on.exit({
    Sys.unsetenv(names(old)[is.na(old)])
    if (any(!is.na(old))) do.call(Sys.setenv, as.list(old[!is.na(old)]))
    rm(list = ls(cache), envir = cache)
  })
  Sys.setenv(KESTRA_EXECUTION_CONTEXT_FILE = file)
  Sys.unsetenv("KESTRA_CONTEXT")
  rm(list = ls(cache), envir = cache)
  code(file)
}

test_that("the context is read from KESTRA_EXECUTION_CONTEXT_FILE once", {
  with_context_file(function(file) {
    context <- Kestra$context()
    expect_identical(context$labels$env, "prod")
    expect_identical(context$inputs$text, "a\nb caf\u00e9")
    expect_identical(context$inputs$files[[1]]$name, "first")

    unlink(file)
    expect_identical(Kestra$context(), context)
  })
})

test_that("the context is read from an explicit path or base64 KESTRA_CONTEXT", {
  with_context_file(function(file) {
    expect_identical(Kestra$context(file)$labels$env, "prod")

    Sys.setenv(KESTRA_EXECUTION_CONTEXT_FILE = tempfile(), KESTRA_CONTEXT = jsonlite::base64_enc('{"vars":{"n":42}}'))
    expect_identical(Kestra$context()$vars$n, 42L)
  })
})

test_that("an explicit path never falls back to KESTRA_CONTEXT", {
  with_context_file(function(file) {
    Sys.setenv(KESTRA_CONTEXT = jsonlite::base64_enc('{"vars":{"n":42}}'))
    typo <- tempfile()
    error <- expect_error(Kestra$context(typo), typo, fixed = TRUE)
    expect_false(grepl("KESTRA_CONTEXT", conditionMessage(error), fixed = TRUE))
  })
})

test_that("an empty KESTRA_EXECUTION_CONTEXT_FILE means the default file", {
  with_context_file(function(file) {
    dir <- tempfile()
    dir.create(dir)
    file.copy(file, file.path(dir, ".kestra-execution-context.json"))
    Sys.setenv(KESTRA_EXECUTION_CONTEXT_FILE = "")
    old <- setwd(dir)
    on.exit(setwd(old), add = TRUE)

    expect_identical(Kestra$context()$labels$env, "prod")
  })
})

test_that("an empty path means the default lookup", {
  with_context_file(function(file) {
    expect_identical(Kestra$context("")$labels$env, "prod")
  })
})

test_that("only a missing file falls back: a directory fails with its read error", {
  with_context_file(function(file) {
    Sys.setenv(KESTRA_EXECUTION_CONTEXT_FILE = tempdir(), KESTRA_CONTEXT = jsonlite::base64_enc('{"vars":{"n":42}}'))
    expect_error(Kestra$context(), sprintf("Kestra execution context file '%s' cannot be read: it is a directory.", tempdir()), fixed = TRUE)
  })
})

test_that("a context that is not JSON or not an object names the source", {
  for (content in c("", "{")) {
    file <- tempfile()
    cat(content, file = file)
    expect_error(Kestra$context(file), sprintf("The execution context in %s is not valid JSON.", file), fixed = TRUE)
  }
  for (content in c("null", "[1]", "[]", "1")) {
    file <- tempfile()
    cat(content, file = file)
    expect_error(Kestra$context(file), sprintf("The execution context in %s is not a JSON object.", file), fixed = TRUE)
  }
})

test_that("KESTRA_CONTEXT that is not base64 fails with its own message", {
  with_context_file(function(file) {
    Sys.setenv(KESTRA_EXECUTION_CONTEXT_FILE = tempfile(), KESTRA_CONTEXT = "not base64!")
    expect_error(Kestra$context(), "The KESTRA_CONTEXT environment variable is not valid base64.", fixed = TRUE)
  })
})

test_that("the context fails clearly outside Kestra", {
  with_context_file(function(file) {
    Sys.setenv(KESTRA_EXECUTION_CONTEXT_FILE = tempfile())
    expect_error(Kestra$context(), "No Kestra execution context found")
  })
})
