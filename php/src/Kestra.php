<?php

declare(strict_types=1);

namespace Kestra;

/**
 * Sends outputs, metrics, logs and assets from PHP script tasks to Kestra, and reads the execution context.
 * Each send call prints one `::{...}::` line to stdout, which Kestra parses.
 */
final class Kestra
{
    public const CONTEXT_FILE = '.kestra-execution-context.json';

    private static ?Logger $logger = null;
    private static ?string $contextJson = null;
    /** @var resource|null */
    private static $stdout = null;

    /** @param array<string, mixed> $map */
    public static function format(array $map): string
    {
        return self::encode($map, 0);
    }

    /** @param array<string, mixed> $outputs */
    public static function outputs(array $outputs): void
    {
        if ($outputs === [] || array_is_list($outputs)) {
            throw new \InvalidArgumentException("Outputs must be a non-empty array with string keys, for example Kestra::outputs(['rows' => 42]).");
        }
        self::send(['outputs' => $outputs]);
    }

    /** @param array<string, mixed> $assets */
    public static function assets(array $assets): void
    {
        if ($assets === [] || array_is_list($assets)) {
            throw new \InvalidArgumentException("Assets must be a non-empty array with string keys, for example Kestra::assets(['outputs' => [['id' => 'sales.orders', 'type' => 'TABLE']]]).");
        }
        self::send(['assets' => $assets]);
    }

    /** @param array<string, mixed> $tags */
    public static function counter(string $name, mixed $value, array $tags = []): void
    {
        self::sendMetric($name, 'counter', $value, $tags);
    }

    /** @param array<string, mixed> $tags */
    public static function gauge(string $name, mixed $value, array $tags = []): void
    {
        self::sendMetric($name, 'gauge', $value, $tags);
    }

    /**
     * Pass seconds, or a Closure that is timed and whose result is returned. No metric is sent if the Closure throws.
     * Only a Closure is called, so a string is never taken for a function name. Wrap other callables with $callable(...).
     *
     * @param array<string, mixed> $tags
     */
    public static function timer(string $name, int|float|\Closure $secondsOrClosure, array $tags = []): mixed
    {
        if (!$secondsOrClosure instanceof \Closure) {
            self::sendMetric($name, 'timer', $secondsOrClosure, $tags);
            return null;
        }
        $start = hrtime(true);
        $result = $secondsOrClosure();
        self::sendMetric($name, 'timer', (hrtime(true) - $start) / 1e9, $tags);
        return $result;
    }

    /** A logger with the PSR-3 methods, plus trace. */
    public static function logger(): Logger
    {
        return self::$logger ??= new Logger();
    }

    /**
     * The execution context as an array, read from $path, KESTRA_EXECUTION_CONTEXT_FILE or .kestra-execution-context.json
     * (written when the task sets executionContext: true). Without a path, falls back to the base64 KESTRA_CONTEXT variable.
     * The default context is read once. Throws RuntimeException outside a Kestra task.
     *
     * @return array<string, mixed>
     */
    public static function context(?string $path = null): array
    {
        if ($path === null && self::$contextJson !== null) {
            return json_decode(self::$contextJson, true);
        }

        $envFile = (string) getenv('KESTRA_EXECUTION_CONTEXT_FILE');
        $file = $path ?? ($envFile === '' ? self::CONTEXT_FILE : $envFile);
        $encoded = (string) getenv('KESTRA_CONTEXT');
        if (is_file($file)) {
            $source = $file;
            $json = file_get_contents($file);
        } elseif ($path === null && $encoded !== '') {
            $source = 'KESTRA_CONTEXT';
            $json = base64_decode($encoded, true);
        } elseif ($path !== null) {
            throw new \RuntimeException("Kestra execution context file '$file' does not exist.");
        } else {
            throw new \RuntimeException("No Kestra execution context found: '$file' does not exist and the KESTRA_CONTEXT environment variable is not set. "
                . 'The execution context is only available when the script runs inside a Kestra task.');
        }

        // Decoded as objects first, so a JSON array or "{}" vs "[]" is told apart.
        if (!is_string($json) || !(json_decode($json) instanceof \stdClass)) {
            throw new \UnexpectedValueException("The execution context in $source is not a JSON object.");
        }
        if ($path === null) {
            self::$contextJson = $json;
        }
        return json_decode($json, true);
    }

    /** @internal Used by Logger. Invalid bytes in the message become U+FFFD, so a log call never fails. */
    public static function sendLog(string $level, string $message): void
    {
        if (!in_array($level, ['TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR'], true)) {
            throw new \InvalidArgumentException("Log level '$level' is not a Kestra level.");
        }
        self::write(self::encode(['logs' => [['level' => $level, 'message' => $message]]], JSON_INVALID_UTF8_SUBSTITUTE));
    }

    /** @param array<string, mixed> $map */
    private static function encode(array $map, int $flags): string
    {
        // Non-ASCII is escaped, which covers U+0085, U+2028 and U+2029: Java treats them as line terminators.
        return '::' . json_encode($map, $flags | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . '::';
    }

    /** @param array<string, mixed> $map */
    private static function send(array $map): void
    {
        try {
            $line = self::format($map);
        } catch (\JsonException $e) {
            $hint = match ($e->getCode()) {
                JSON_ERROR_INF_OR_NAN => ' Replace NAN and INF with null.',
                JSON_ERROR_UTF8 => ' Make strings valid UTF-8, for example with mb_scrub().',
                default => '',
            };
            throw new \InvalidArgumentException("This value cannot be sent to Kestra as JSON ({$e->getMessage()}).$hint", 0, $e);
        }
        self::write($line);
    }

    private static function write(string $line): void
    {
        // STDOUT is not defined when the script is piped to php on stdin.
        self::$stdout ??= defined('STDOUT') ? STDOUT : fopen('php://stdout', 'w');
        // One write per line, flushed, so Kestra gets each line when it is written and not at exit.
        fwrite(self::$stdout, $line . "\n");
        fflush(self::$stdout);
    }

    /** @param array<string, mixed> $tags */
    private static function sendMetric(string $name, string $type, mixed $value, array $tags): void
    {
        if ($name === '') {
            throw new \InvalidArgumentException('Metric name must be a non-empty string.');
        }
        if (!(is_int($value) || is_float($value)) || !is_finite((float) $value)) {
            throw new \InvalidArgumentException("Metric '$name' value must be a finite number.");
        }
        if ($tags !== [] && array_is_list($tags)) {
            throw new \InvalidArgumentException("Metric '$name' tags must be an array with string keys, for example ['env' => 'prod'].");
        }
        $stringTags = [];
        foreach ($tags as $key => $tag) {
            if (!is_scalar($tag) && !$tag instanceof \Stringable) {
                throw new \InvalidArgumentException("Metric '$name' tag '$key' must be a single value, for example ['env' => 'prod'].");
            }
            // Kestra reads tags as a map of strings.
            $stringTags[(string) $key] = is_bool($tag) ? var_export($tag, true) : (string) $tag;
        }
        // An empty array would be sent as [], and Kestra expects an object.
        self::send(['metrics' => [['name' => $name, 'type' => $type, 'value' => $value, 'tags' => (object) $stringTags]]]);
    }
}

/** Sends log lines to Kestra. Same methods as a PSR-3 LoggerInterface, without the psr/log dependency. */
final class Logger
{
    private const LEVELS = [
        'trace' => 'TRACE',
        'debug' => 'DEBUG',
        'info' => 'INFO',
        'notice' => 'INFO',
        'warning' => 'WARN',
        'error' => 'ERROR',
        'critical' => 'ERROR',
        'alert' => 'ERROR',
        'emergency' => 'ERROR',
    ];

    /** @param array<string, mixed> $context */
    public function log(mixed $level, string|\Stringable $message, array $context = []): void
    {
        $kestraLevel = is_string($level) ? (self::LEVELS[strtolower($level)] ?? null) : null;
        if ($kestraLevel === null) {
            throw new \InvalidArgumentException('Log level must be one of ' . implode(', ', array_keys(self::LEVELS)) . '.');
        }
        $replace = [];
        foreach ($context as $key => $value) {
            if (is_scalar($value) || $value === null || $value instanceof \Stringable) {
                $replace['{' . $key . '}'] = is_bool($value) ? var_export($value, true) : (string) $value;
            }
        }
        Kestra::sendLog($kestraLevel, strtr((string) $message, $replace));
    }

    /** @param array<string, mixed> $context */
    public function trace(string|\Stringable $message, array $context = []): void
    {
        $this->log('trace', $message, $context);
    }

    /** @param array<string, mixed> $context */
    public function debug(string|\Stringable $message, array $context = []): void
    {
        $this->log('debug', $message, $context);
    }

    /** @param array<string, mixed> $context */
    public function info(string|\Stringable $message, array $context = []): void
    {
        $this->log('info', $message, $context);
    }

    /** @param array<string, mixed> $context */
    public function notice(string|\Stringable $message, array $context = []): void
    {
        $this->log('notice', $message, $context);
    }

    /** @param array<string, mixed> $context */
    public function warning(string|\Stringable $message, array $context = []): void
    {
        $this->log('warning', $message, $context);
    }

    /** @param array<string, mixed> $context */
    public function error(string|\Stringable $message, array $context = []): void
    {
        $this->log('error', $message, $context);
    }

    /** @param array<string, mixed> $context */
    public function critical(string|\Stringable $message, array $context = []): void
    {
        $this->log('critical', $message, $context);
    }

    /** @param array<string, mixed> $context */
    public function alert(string|\Stringable $message, array $context = []): void
    {
        $this->log('alert', $message, $context);
    }

    /** @param array<string, mixed> $context */
    public function emergency(string|\Stringable $message, array $context = []): void
    {
        $this->log('emergency', $message, $context);
    }
}
