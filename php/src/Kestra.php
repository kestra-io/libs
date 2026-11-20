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
    /** @var array<string, mixed>|null */
    private static ?array $context = null;
    /** @var resource|null */
    private static $stdout = null;

    /** @param array<string, mixed> $map */
    public static function format(array $map): string
    {
        return self::encode($map, 0);
    }

    /** @param array<string, mixed> $outputs Empty outputs send nothing. */
    public static function outputs(array $outputs): void
    {
        if ($outputs === []) {
            return;
        }
        if (array_is_list($outputs)) {
            throw new \InvalidArgumentException("Outputs must be an array with string keys, for example Kestra::outputs(['rows' => 42]).");
        }
        self::send(['outputs' => $outputs]);
    }

    /** @param array<string, mixed> $assets Lists of inputs and outputs. Empty assets send nothing. */
    public static function assets(array $assets): void
    {
        foreach ($assets as $key => $value) {
            if ($key !== 'inputs' && $key !== 'outputs') {
                throw new \InvalidArgumentException("Assets hold only inputs and outputs, not '$key'.");
            }
            if (!is_array($value) || !array_is_list($value)) {
                throw new \InvalidArgumentException("Asset $key must be a list, for example [['id' => 'sales.orders', 'type' => 'TABLE']].");
            }
        }
        if ($assets === []) {
            return;
        }
        // Asset metadata is a map in Kestra, and PHP sends an empty array as [].
        foreach ($assets['outputs'] ?? [] as $i => $asset) {
            if (is_array($asset) && ($asset['metadata'] ?? null) === []) {
                $assets['outputs'][$i]['metadata'] = new \stdClass();
            }
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
    public static function timer(string $name, mixed $secondsOrClosure, array $tags = []): mixed
    {
        if (!$secondsOrClosure instanceof \Closure) {
            self::sendMetric($name, 'timer', $secondsOrClosure, $tags);
            return null;
        }
        // Checked before the Closure runs, so a typo does not cost a long run.
        self::metricTags($name, $tags);
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
     * The default context is read once. An empty $path counts as none. Only a missing file falls back: a directory or an
     * unreadable file throws RuntimeException, as does a missing context outside a Kestra task.
     *
     * @return array<string, mixed>
     */
    public static function context(?string $path = null): array
    {
        if ($path === '') {
            $path = null;
        }
        if ($path === null && self::$context !== null) {
            return self::$context;
        }

        $envFile = (string) getenv('KESTRA_EXECUTION_CONTEXT_FILE');
        $file = $path ?? ($envFile === '' ? self::CONTEXT_FILE : $envFile);
        $encoded = (string) getenv('KESTRA_CONTEXT');
        if (file_exists($file)) {
            $source = $file;
            // file_get_contents() returns an empty string for a directory.
            $json = is_dir($file) ? false : @file_get_contents($file);
            if ($json === false) {
                $reason = is_dir($file) ? 'it is a directory' : (error_get_last()['message'] ?? 'it is not readable');
                throw new \RuntimeException("Kestra execution context file '$file' cannot be read: $reason.");
            }
        } elseif ($path === null && $encoded !== '') {
            $source = 'KESTRA_CONTEXT';
            $json = base64_decode($encoded, true);
            if ($json === false) {
                throw new \UnexpectedValueException('The KESTRA_CONTEXT environment variable is not valid base64.');
            }
        } elseif ($path !== null) {
            throw new \RuntimeException("Kestra execution context file '$file' does not exist.");
        } else {
            throw new \RuntimeException("No Kestra execution context found: '$file' does not exist and the KESTRA_CONTEXT environment variable is not set. "
                . 'The execution context is only available when the script runs inside a Kestra task.');
        }

        // Decoded as objects first, so a JSON array or "{}" vs "[]" is told apart.
        try {
            $decoded = json_decode($json, false, 512, JSON_THROW_ON_ERROR);
        } catch (\JsonException $e) {
            throw new \UnexpectedValueException("The execution context in $source is not valid JSON ({$e->getMessage()}).", 0, $e);
        }
        if (!$decoded instanceof \stdClass) {
            throw new \UnexpectedValueException("The execution context in $source is not a JSON object.");
        }
        $context = json_decode($json, true);
        if ($path === null) {
            self::$context = $context;
        }
        return $context;
    }

    /** @internal Used by Logger. Invalid bytes in the message become U+FFFD, so a log call never fails. */
    public static function sendLog(string $level, string $message): void
    {
        self::write(self::encode(['logs' => [['level' => $level, 'message' => $message]]], JSON_INVALID_UTF8_SUBSTITUTE));
    }

    /** @param array<string, mixed> $map */
    private static function encode(array $map, int $flags): string
    {
        // Non-ASCII is escaped, which covers U+0085, U+2028 and U+2029: Java treats them as line terminators.
        return '::' . json_encode($map, $flags | JSON_UNESCAPED_SLASHES | JSON_PRESERVE_ZERO_FRACTION | JSON_THROW_ON_ERROR) . '::';
    }

    /** @param array<string, mixed> $map */
    private static function send(array $map): void
    {
        try {
            $line = self::format(self::jsonValue($map, 0));
        } catch (\JsonException $e) {
            $reason = match ($e->getCode()) {
                JSON_ERROR_INF_OR_NAN => 'replace NAN and INF with null.',
                JSON_ERROR_UTF8 => 'make strings valid UTF-8, for example with mb_scrub().',
                JSON_ERROR_DEPTH, JSON_ERROR_RECURSION => 'it is nested more than 512 levels deep or contains itself.',
                JSON_ERROR_UNSUPPORTED_TYPE => 'a resource such as a file handle cannot be sent, pass its contents instead.',
                default => $e->getMessage() . '.',
            };
            throw new \InvalidArgumentException("This value cannot be sent to Kestra as JSON: $reason", 0, $e);
        }
        self::write($line);
    }

    /** A copy with dates as ISO 8601 text, also inside a stdClass, so the caller's value is never changed, even through a reference. */
    private static function jsonValue(mixed $value, int $depth): mixed
    {
        if ($value instanceof \DateTimeInterface) {
            return $value->format($value->format('u') === '000000' ? 'Y-m-d\TH:i:sP' : 'Y-m-d\TH:i:s.uP');
        }
        if (!is_array($value) && !$value instanceof \stdClass) {
            return $value;
        }
        // json_encode() stops at the same depth, and a reference to the array itself never ends.
        if ($depth > 512) {
            throw new \JsonException('', JSON_ERROR_DEPTH);
        }
        $copy = [];
        foreach (is_array($value) ? $value : get_object_vars($value) as $key => $item) {
            $copy[$key] = self::jsonValue($item, $depth + 1);
        }
        // Still an object, so an empty one is sent as {}.
        return is_array($value) ? $copy : (object) $copy;
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
        $stringTags = self::metricTags($name, $tags);
        if (!(is_int($value) || is_float($value)) || !is_finite((float) $value)) {
            throw new \InvalidArgumentException("Metric '$name' value must be a finite number.");
        }
        // An empty array would be sent as [], and Kestra expects an object.
        self::send(['metrics' => [['name' => $name, 'type' => $type, 'value' => $value, 'tags' => (object) $stringTags]]]);
    }

    /**
     * Checks the name and returns the tags as strings, since Kestra reads tags as a map of strings.
     *
     * @param array<string, mixed> $tags
     * @return array<string, string>
     */
    private static function metricTags(string $name, array $tags): array
    {
        if ($name === '') {
            throw new \InvalidArgumentException('Metric name must be a non-empty string.');
        }
        if ($tags !== [] && array_is_list($tags)) {
            throw new \InvalidArgumentException("Metric '$name' tags must be an array with string keys, for example ['env' => 'prod'].");
        }
        $stringTags = [];
        foreach ($tags as $key => $tag) {
            if (!is_scalar($tag) && !$tag instanceof \Stringable) {
                throw new \InvalidArgumentException("Metric '$name' tag '$key' must be a single value, for example ['env' => 'prod'].");
            }
            $stringTags[(string) $key] = is_bool($tag) ? var_export($tag, true) : (string) $tag;
        }
        return $stringTags;
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
                $replace['{' . $key . '}'] = is_bool($value) ? var_export($value, true) : self::text($value);
            }
        }
        $message = self::text($message);
        $text = strtr($message, $replace);
        // PSR-3 passes exceptions under the "exception" key.
        if (($context['exception'] ?? null) instanceof \Throwable && !str_contains($message, '{exception}')) {
            $text .= "\n" . self::text($context['exception']);
        }
        Kestra::sendLog($kestraLevel, $text);
    }

    /** A __toString() can throw, or return a non-string, and a log call must not fail. */
    private static function text(mixed $value): string
    {
        try {
            return (string) $value;
        } catch (\Throwable) {
            return '[object ' . get_debug_type($value) . ']';
        }
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
