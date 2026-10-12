<?php

declare(strict_types=1);

namespace Kestra\Logging;

use Kestra\Kestra;

/**
 * Logger for Kestra tasks that emits structured log records using Kestra's delimiter protocol:
 * ::{"logs":[{"level":"INFO","message":"..."}]}::
 */
class KestraLogger
{
    /**
     * Logs a message with TRACE level.
     *
     * @param string ...$messages
     */
    public function trace(string ...$messages): void
    {
        $this->log('TRACE', $messages);
    }

    /**
     * Logs a message with DEBUG level.
     *
     * @param string ...$messages
     */
    public function debug(string ...$messages): void
    {
        $this->log('DEBUG', $messages);
    }

    /**
     * Logs a message with INFO level.
     *
     * @param string ...$messages
     */
    public function info(string ...$messages): void
    {
        $this->log('INFO', $messages);
    }

    /**
     * Logs a message with WARN level.
     *
     * @param string ...$messages
     */
    public function warn(string ...$messages): void
    {
        $this->log('WARN', $messages);
    }

    /**
     * Alias for warn().
     *
     * @param string ...$messages
     */
    public function warning(string ...$messages): void
    {
        $this->warn(...$messages);
    }

    /**
     * Logs a message with ERROR level.
     *
     * @param string ...$messages
     */
    public function error(string ...$messages): void
    {
        $this->log('ERROR', $messages);
    }

    /**
     * Dispatches logs with the specified level.
     *
     * @param string $level
     * @param array<int, string> $messages
     */
    public function log(string $level, array $messages): void
    {
        $records = [];
        foreach ($messages as $message) {
            $records[] = [
                'level' => strtoupper($level),
                'message' => $message,
            ];
        }

        Kestra::send(['logs' => $records]);
    }
}
