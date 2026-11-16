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
