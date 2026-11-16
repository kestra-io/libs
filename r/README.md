# kestra (R)

Send outputs, metrics and logs from R script tasks to Kestra. Each call prints one `::{...}::` line to stdout, which Kestra reads. Depends only on `jsonlite`.

## Install

```r
install.packages("remotes")
remotes::install_github("kestra-io/libs", subdir = "r")
```

## Usage

```yaml
id: train_model
namespace: company.team

tasks:
  - id: train
    type: io.kestra.plugin.scripts.r.Script
    beforeCommands:
      - Rscript -e 'install.packages("remotes"); remotes::install_github("kestra-io/libs", subdir = "r")'
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
| `Kestra$outputs(list(...))` | Task outputs under `outputs.<task>.vars` |
| `Kestra$counter(name, value, tags)` | Counter metric |
| `Kestra$gauge(name, value, tags)` | Gauge metric |
| `Kestra$timer(name, seconds_or_function, tags)` | Timer metric. A function is timed and its result returned |
| `Kestra$logger()$trace/debug/info/warn/error(...)` | Log line at that level |

`tags` is optional and must be named, as a list or a named vector.

Length-1 vectors are written as single values. Wrap a value in `I()` to keep it as a JSON array, for example `list(ids = I(42))`.
