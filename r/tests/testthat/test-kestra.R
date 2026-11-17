emitted <- function(expr) capture.output(expr)

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

test_that("outputs must be a named list", {
  expect_error(Kestra$outputs(list(1, 2)), "outputs must be a non-empty named list")
  expect_error(Kestra$outputs(list()), "outputs must be a non-empty named list")
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
  expect_gte(payload$metrics$value, 0.2)
})

test_that("logger emits the level and joins the message parts", {
  expect_identical(
    emitted(Kestra$logger()$warn("3 rows ", "had missing values")),
    '::{"logs":[{"level":"WARN","message":"3 rows had missing values"}]}::'
  )
})

test_that("logger always sends one string, even for vectors or no arguments", {
  expect_identical(
    emitted(Kestra$logger()$info("rows: ", c(1, 2))),
    '::{"logs":[{"level":"INFO","message":"rows: 1rows: 2"}]}::'
  )
  expect_identical(emitted(Kestra$logger()$info()), '::{"logs":[{"level":"INFO","message":""}]}::')
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
  expect_error(Kestra$assets(list()), "assets must be a non-empty named list")
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
    expect_error(Kestra$context(tempfile()), "No Kestra execution context found")
  })
})

test_that("the context fails clearly outside Kestra", {
  with_context_file(function(file) {
    Sys.setenv(KESTRA_EXECUTION_CONTEXT_FILE = tempfile())
    expect_error(Kestra$context(), "No Kestra execution context found")
  })
})
