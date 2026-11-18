# Kestra (PHP)

Send outputs, metrics, logs and assets from PHP script tasks to Kestra. Each call prints one `::{...}::` line to stdout, which Kestra reads. A single file with no dependencies, for PHP 8.1 and later.

## Install

The library is not on Packagist yet. Download the file in `beforeCommands`:

```bash
curl -fsSLo Kestra.php https://raw.githubusercontent.com/kestra-io/libs/main/php/src/Kestra.php
```

Pin a release tag instead of `main` in production flows, so a push to `main` cannot change what runs.

## Usage

```yaml
id: import_orders
namespace: company.team

tasks:
  - id: import
    type: io.kestra.plugin.scripts.php.Script
    beforeCommands:
      - curl -fsSLo Kestra.php https://raw.githubusercontent.com/kestra-io/libs/main/php/src/Kestra.php
    script: |
      <?php
      require 'Kestra.php';
      use Kestra\Kestra;

      $orders = Kestra::timer('fetch', fn () => range(1, 120));
      Kestra::outputs(['count' => count($orders), 'status' => 'ok']);
      Kestra::counter('orders', count($orders), ['source' => 'shop']);
      Kestra::gauge('queue_size', 3);
      Kestra::logger()->warning('{count} orders had no customer', ['count' => 2]);

  - id: log
    type: io.kestra.plugin.core.log.Log
    message: "Imported {{ outputs.import.vars.count }} orders"
```

| Call | Result in Kestra |
|------|------------------|
| `Kestra::outputs(array $outputs)` | Task outputs under `outputs.<task>.vars` |
| `Kestra::assets(['inputs' => [...], 'outputs' => [...]])` | Input and output assets of the task |
| `Kestra::counter($name, $value, $tags = [])` | Counter metric |
| `Kestra::gauge($name, $value, $tags = [])` | Gauge metric |
| `Kestra::timer($name, $seconds, $tags = [])` or `Kestra::timer($name, fn () => ...)` | Timer metric. A Closure is timed and its result returned |
| `Kestra::logger()->trace/debug/info/notice/warning/error/critical/alert/emergency($message, $context = [])` | Log line at that level. `notice` is sent as INFO, `critical`, `alert` and `emergency` as ERROR |
| `Kestra::context(?string $path = null)` | The execution context as an array, for example `Kestra::context()['labels']`. Needs `executionContext: true` on the task. Without `$path`, falls back to the base64 `KESTRA_CONTEXT` variable. A `$path` that does not exist throws |

Metric tags are sent as strings, and invalid bytes in a log message become U+FFFD. The logger has the PSR-3 methods and fills `{placeholders}` from `$context`, but does not implement `Psr\Log\LoggerInterface`, so the library needs no dependency. PHP cannot tell an empty list from an empty map, so an empty array is sent as `[]`. Pass `new \stdClass()` where Kestra or a downstream task expects an empty map. Empty asset `metadata` is sent as `{}` already. Objects are sent as their public properties unless they implement `JsonSerializable`, so format a `DateTime` with `format()` first.
