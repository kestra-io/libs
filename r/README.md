# kestra (R)

Send outputs, metrics, logs and assets from R script tasks to Kestra, and read the execution context. Each call prints one `::{...}::` line to stdout, which Kestra reads. Depends only on `jsonlite`.

## Install

```r
install.packages("remotes")
remotes::install_github("kestra-io/libs", subdir = "r", ref = "main")
```

Pin `ref` to a release tag in production flows, so a push to `main` cannot change what runs. Installing on every execution calls the GitHub API (60 unauthenticated requests per hour per IP), so for frequent flows build an image with the package installed and set `containerImage`.

## Usage

```yaml
id: train_model
namespace: company.team

tasks:
  - id: train
    type: io.kestra.plugin.scripts.r.Script
    beforeCommands:
      - Rscript -e 'install.packages("remotes"); remotes::install_github("kestra-io/libs", subdir = "r", ref = "main")'
    script: |
      library(kestra)

      Kestra$outputs(list(accuracy = 0.91, model = "glm"))
      Kestra$counter("rows", 15000, list(source = "s3"))
      Kestra$gauge("queue_size", 3)
      model <- Kestra$timer("fit", function() lm(dist ~ speed, cars))
      Kestra$logger()$warn("3 rows had missing values")

  - id: log
    type: io.kestra.plugin.core.log.Log
    message: "Accuracy: {{ outputs.train.vars.accuracy }}"
```

| Call | Result in Kestra |
|------|------------------|
| `Kestra$outputs(list(...))` | Task outputs under `outputs.<task>.vars`. An empty list sends nothing |
| `Kestra$assets(list(inputs = list(...), outputs = list(...)))` | Input and output assets of the task. Both are optional unnamed lists or data frames, one row per asset, and an empty list sends nothing |
| `Kestra$counter(name, value, tags)` | Counter metric |
| `Kestra$gauge(name, value, tags)` | Gauge metric |
| `Kestra$timer(name, seconds_or_function, tags)` | Timer metric. A function is timed and its result returned. The name and tags are checked before it runs, and no metric is sent if it fails |
| `Kestra$logger()$trace/debug/info/warn/error(...)` | Log line at that level. A vector argument shows its first 1000 values, joined with spaces |
| `Kestra$context(path = NULL)` | The execution context as a list, for example `Kestra$context()$labels$env`. Needs `executionContext: true` on the task. An empty `path` counts as none. Without `path`, a missing file falls back to the base64 `KESTRA_CONTEXT` variable. A directory or an unreadable file fails |

`tags` is optional and must be named, as a list or a named vector. Date-times are sent in UTC, for example `2026-11-16T09:00:00Z`.

Metric tags are sent as strings, logicals as `"true"` or `"false"`, and two tags with the same name fail. Numbers keep 15 significant digits, so send larger integers such as byte counts as strings. Invalid UTF-8 bytes become U+FFFD. Outputs fail on `NaN`, `Inf` and two keys with the same name.

Length-1 vectors are written as single values. Wrap a value in `I()` to keep it as a JSON array, for example `list(ids = I(42))`.
