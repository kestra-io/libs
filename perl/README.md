# Kestra (Perl)

Send outputs, metrics, logs and assets from Perl script tasks to Kestra, and read the execution context. Each call prints one `::{...}::` line to stdout, which Kestra reads. A single module that uses only core modules, for Perl 5.26 and later.

## Install

The module is not on CPAN yet. Download the file in `beforeCommands`:

```bash
curl -fsSLo Kestra.pm https://raw.githubusercontent.com/kestra-io/libs/main/perl/lib/Kestra.pm
```

Pin a release tag instead of `main` in production flows, so a push to `main` cannot change what runs.

## Usage

```yaml
id: import_orders
namespace: company.team

tasks:
  - id: import
    type: io.kestra.plugin.scripts.perl.Script
    beforeCommands:
      - curl -fsSLo Kestra.pm https://raw.githubusercontent.com/kestra-io/libs/main/perl/lib/Kestra.pm
    script: |
      use lib '.';
      use Kestra;

      my @orders = Kestra->timer('fetch', sub { (1 .. 120) });
      Kestra->outputs({ count => scalar @orders, status => 'ok' });
      Kestra->counter('orders', scalar @orders, { source => 'shop' });
      Kestra->gauge('queue_size', 3);
      Kestra->logger->warn('2 orders had no customer');

  - id: log
    type: io.kestra.plugin.core.log.Log
    message: "Imported {{ outputs.import.vars.count }} orders"
```

| Call | Result in Kestra |
|------|------------------|
| `Kestra->outputs(\%outputs)` | Task outputs under `outputs.<task>.vars` |
| `Kestra->assets({ inputs => [...], outputs => [...] })` | Input and output assets of the task |
| `Kestra->counter($name, $value, \%tags)` | Counter metric |
| `Kestra->gauge($name, $value, \%tags)` | Gauge metric |
| `Kestra->timer($name, $seconds, \%tags)` or `Kestra->timer($name, sub { ... })` | Timer metric. A code reference is timed and its result returned |
| `Kestra->logger->trace/debug/info/warn/error/fatal(@message)` | Log line at that level. Arguments are joined like `print` joins them, and `fatal` is sent as ERROR |
| `Kestra->context($path)` | The execution context as a hash reference, for example `Kestra->context->{labels}`. Needs `executionContext: true` on the task. Without `$path`, falls back to the base64 `KESTRA_CONTEXT` variable. A `$path` that does not exist dies |

Tags are optional and sent as strings. Byte strings are read as UTF-8, so a script without `use utf8` still sends `café`. Invalid UTF-8 in a log message becomes U+FFFD, and in outputs it dies with a plain message. A scalar is sent as a JSON number only while Perl holds it as a number: `'42'` and a number that was used as a string are sent as `"42"`, so write `0 + $value` to send a number. Booleans are `JSON::PP::true`, `JSON::PP::false`, `\1` or `\0`.
