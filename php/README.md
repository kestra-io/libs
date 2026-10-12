# Kestra PHP Client

This PHP library provides functionality to interact with the Kestra engine from PHP script tasks, enabling output passing, custom metrics, structured logging, asset tracking, and execution context access.

---

## Installation

Install using [Composer](https://getcomposer.org/):

```bash
composer require kestra-io/libs
```

Requires PHP 8.1 or higher.

---

## Usage

### Outputs

Send key-value outputs back to the Kestra server:

```php
use Kestra\Kestra;

Kestra::outputs([
    'result_count' => 150,
    'status' => 'COMPLETED',
    'metadata' => [
        'processed_by' => 'php-worker-1'
    ]
]);
```

### Metrics

Send custom metrics (counters, timers, gauges) to Kestra:

#### Counters
```php
// Simple counter
Kestra::counter('items_processed', 100);

// Counter with tags
Kestra::counter('api_requests', 1, ['endpoint' => '/users', 'status' => '200']);
```

#### Timers
```php
// Explicit duration in seconds
Kestra::timer('batch_duration', 12.45, ['batch_id' => 'b102']);

// Measure execution time of a callable automatically
Kestra::timer('database_sync', function () {
    // perform long-running operation
    usleep(50000);
}, ['table' => 'orders']);
```

#### Gauges
```php
Kestra::gauge('memory_usage_mb', 256.4, ['node' => 'worker-01']);
```

### Assets

Track data assets and pipeline artifacts:

```php
Kestra::assets([
    'inputs' => [
        ['id' => 'raw_orders', 'type' => 'FILE']
    ],
    'outputs' => [
        ['id' => 'cleaned_orders_table', 'type' => 'TABLE', 'metadata' => ['rows' => 5000]]
    ]
]);
```

### Logging

Send structured logs captured at the appropriate log level by Kestra:

```php
use Kestra\Kestra;

$logger = Kestra::logger();

$logger->trace('Detailed trace event');
$logger->debug('Debugging connection parameters');
$logger->info('Processing started for batch 42');
$logger->warn('Rate limit approaching threshold');
$logger->error('Failed to parse incoming payload');

// Log multiple messages at once
$logger->info('Step 1 complete', 'Step 2 complete');
```

### Execution Context

Access execution metadata injected by Kestra:

```php
use Kestra\Kestra;

$context = Kestra::context();

$flowId = $context['flow']['id'] ?? null;
$executionId = $context['execution']['id'] ?? null;
$inputs = $context['inputs'] ?? [];
```

---

## Testing

Run tests using PHPUnit:

```bash
composer install
vendor/bin/phpunit
```
