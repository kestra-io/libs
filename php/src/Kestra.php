<?php

declare(strict_types=1);

namespace Kestra;

use Kestra\Logging\KestraLogger;
use RuntimeException;

/**
 * Main Kestra class for emitting outputs, metrics, assets, logs, and accessing execution context.
 */
class Kestra
{
    private static ?KestraLogger $logger = null;

    /**
     * @var callable|null Injectable sink for testing stdout emissions without buffering.
     */
    private static $outputHandler = null;

    /**
     * Formats an array or object as a JSON string wrapped in Kestra's "::" delimiter protocol.
     *
     * @param array<string, mixed>|object $data
     * @return string
     */
    public static function format(array|object $data): string
    {
        $json = json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);

        // Escape Unicode line and paragraph separators (\u0085, \u2028, \u2029)
        $json = preg_replace_callback('/[\x{0085}\x{2028}\x{2029}]/u', static function (array $matches): string {
            return sprintf('\\u%04x', mb_ord($matches[0], 'UTF-8'));
        }, $json);

        return '::' . $json . '::';
    }

    /**
     * Sends formatted data to standard output.
     *
     * @param array<string, mixed>|object $data
     */
    public static function send(array|object $data): void
    {
        $formatted = self::format($data);

        if (self::$outputHandler !== null) {
            (self::$outputHandler)($formatted);
            return;
        }

        echo $formatted . PHP_EOL;
    }

    /**
     * Emits key-value outputs to Kestra.
     *
     * @param array<string, mixed> $outputs
     */
    public static function outputs(array $outputs): void
    {
        self::send(['outputs' => $outputs]);
    }

    /**
     * Emits asset metadata to Kestra.
     *
     * @param array<string, mixed> $assets
     */
    public static function assets(array $assets): void
    {
        self::send(['assets' => $assets]);
    }

    /**
     * Emits a metric to Kestra.
     *
     * @param string $name
     * @param string $type
     * @param int|float $value
     * @param array<string, mixed> $tags
     */
    public static function metric(string $name, string $type, int|float $value, array $tags = []): void
    {
        self::send([
            'metrics' => [
                [
                    'name' => $name,
                    'type' => $type,
                    'value' => $value,
                    'tags' => (object)$tags,
                ],
            ],
        ]);
    }

    /**
     * Emits a counter metric.
     *
     * @param string $name
     * @param int|float $value
     * @param array<string, mixed> $tags
     */
    public static function counter(string $name, int|float $value, array $tags = []): void
    {
        self::metric($name, 'counter', $value, $tags);
    }

    /**
     * Measures duration or emits an elapsed time metric in seconds.
     *
     * If $duration is a callable, it executes the callable, measures elapsed time,
     * and sends the resulting duration in seconds.
     *
     * @param string $name
     * @param float|int|callable $duration
     * @param array<string, mixed> $tags
     */
    public static function timer(string $name, float|int|callable $duration, array $tags = []): void
    {
        if (is_callable($duration)) {
            $start = hrtime(true);
            $duration();
            $elapsedSeconds = (hrtime(true) - $start) / 1e9;
            self::metric($name, 'timer', $elapsedSeconds, $tags);
            return;
        }

        self::metric($name, 'timer', $duration, $tags);
    }

    /**
     * Emits a gauge metric.
     *
     * @param string $name
     * @param int|float $value
     * @param array<string, mixed> $tags
     */
    public static function gauge(string $name, int|float $value, array $tags = []): void
    {
        self::metric($name, 'gauge', $value, $tags);
    }

    /**
     * Returns the singleton logger instance.
     */
    public static function logger(): KestraLogger
    {
        if (self::$logger === null) {
            self::$logger = new KestraLogger();
        }

        return self::$logger;
    }

    /**
     * Reads the execution context injected by Kestra into the task working directory.
     *
     * Reads from the specified path, from KESTRA_EXECUTION_CONTEXT_FILE,
     * from `.kestra-execution-context.json`, or falls back to base64-encoded KESTRA_CONTEXT.
     *
     * @param string|null $path
     * @return array<string, mixed>
     * @throws RuntimeException
     */
    public static function context(?string $path = null): array
    {
        $filePath = $path ?? (getenv('KESTRA_EXECUTION_CONTEXT_FILE') ?: '.kestra-execution-context.json');

        if (file_exists($filePath)) {
            $raw = file_get_contents($filePath);
            if ($raw !== false) {
                return json_decode($raw, true, 512, JSON_THROW_ON_ERROR);
            }
        }

        $envContext = getenv('KESTRA_CONTEXT');
        if ($envContext !== false && $envContext !== '') {
            $decoded = base64_decode($envContext, true);
            if ($decoded !== false) {
                return json_decode($decoded, true, 512, JSON_THROW_ON_ERROR);
            }
        }

        throw new RuntimeException(
            sprintf(
                "No Kestra execution context found: '%s' does not exist and KESTRA_CONTEXT is not set.",
                $filePath
            )
        );
    }

    /**
     * Sets a custom output handler (primarily for tests).
     *
     * @param callable|null $handler
     */
    public static function setOutputHandler(?callable $handler): void
    {
        self::$outputHandler = $handler;
    }

    /**
     * Resets the singleton logger instance.
     */
    public static function resetLogger(): void
    {
        self::$logger = null;
    }
}
