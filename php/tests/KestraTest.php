<?php

declare(strict_types=1);

namespace Kestra\Tests;

use Kestra\Kestra;
use PHPUnit\Framework\TestCase;
use RuntimeException;

class KestraTest extends TestCase
{
    private array $capturedOutputs = [];

    protected function setUp(): void
    {
        parent::setUp();
        $this->capturedOutputs = [];
        Kestra::setOutputHandler(function (string $output): void {
            $this->capturedOutputs[] = $output;
        });
        Kestra::resetLogger();
    }

    protected function tearDown(): void
    {
        Kestra::setOutputHandler(null);
        Kestra::resetLogger();
        parent::tearDown();
    }

    private function getLastParsed(): array
    {
        $this->assertNotEmpty($this->capturedOutputs, 'No output was captured');
        $raw = end($this->capturedOutputs);
        $this->assertStringStartsWith('::', $raw);
        $this->assertStringEndsWith('::', $raw);
        $json = substr($raw, 2, -2);
        return json_decode($json, true, 512, JSON_THROW_ON_ERROR);
    }

    public function testOutputs(): void
    {
        Kestra::outputs([
            'my_string' => 'hello',
            'my_number' => 42,
            'my_nested' => ['a' => 1, 'b' => true],
        ]);

        $parsed = $this->getLastParsed();
        $this->assertSame([
            'outputs' => [
                'my_string' => 'hello',
                'my_number' => 42,
                'my_nested' => ['a' => 1, 'b' => true],
            ],
        ], $parsed);
    }

    public function testAssets(): void
    {
        Kestra::assets([
            'inputs' => [
                ['id' => 'input_1', 'type' => 'FILE'],
            ],
            'outputs' => [
                ['id' => 'output_1', 'type' => 'TABLE'],
            ],
        ]);

        $parsed = $this->getLastParsed();
        $this->assertSame([
            'assets' => [
                'inputs' => [
                    ['id' => 'input_1', 'type' => 'FILE'],
                ],
                'outputs' => [
                    ['id' => 'output_1', 'type' => 'TABLE'],
                ],
            ],
        ], $parsed);
    }

    public function testCounterWithoutTags(): void
    {
        Kestra::counter('requests_total', 10);

        $parsed = $this->getLastParsed();
        $this->assertSame([
            'metrics' => [
                [
                    'name' => 'requests_total',
                    'type' => 'counter',
                    'value' => 10,
                    'tags' => [],
                ],
            ],
        ], $parsed);
    }

    public function testCounterWithTags(): void
    {
        Kestra::counter('errors_total', 1, ['env' => 'prod', 'service' => 'api']);

        $parsed = $this->getLastParsed();
        $this->assertSame([
            'metrics' => [
                [
                    'name' => 'errors_total',
                    'type' => 'counter',
                    'value' => 1,
                    'tags' => ['env' => 'prod', 'service' => 'api'],
                ],
            ],
        ], $parsed);
    }

    public function testTimerNumeric(): void
    {
        Kestra::timer('db_query_time', 1.45, ['query' => 'select']);

        $parsed = $this->getLastParsed();
        $this->assertSame([
            'metrics' => [
                [
                    'name' => 'db_query_time',
                    'type' => 'timer',
                    'value' => 1.45,
                    'tags' => ['query' => 'select'],
                ],
            ],
        ], $parsed);
    }

    public function testTimerCallable(): void
    {
        Kestra::timer('operation_time', static function (): void {
            usleep(5000); // 5ms
        });

        $parsed = $this->getLastParsed();
        $this->assertSame('operation_time', $parsed['metrics'][0]['name']);
        $this->assertSame('timer', $parsed['metrics'][0]['type']);
        $this->assertGreaterThan(0.0, $parsed['metrics'][0]['value']);
    }

    public function testGauge(): void
    {
        Kestra::gauge('memory_mb', 256.5, ['host' => 'srv-1']);

        $parsed = $this->getLastParsed();
        $this->assertSame([
            'metrics' => [
                [
                    'name' => 'memory_mb',
                    'type' => 'gauge',
                    'value' => 256.5,
                    'tags' => ['host' => 'srv-1'],
                ],
            ],
        ], $parsed);
    }

    public function testGaugeZeroAndNegative(): void
    {
        Kestra::gauge('temperature', 0);
        $parsed = $this->getLastParsed();
        $this->assertSame(0, $parsed['metrics'][0]['value']);

        Kestra::gauge('temperature', -15.4);
        $parsed2 = $this->getLastParsed();
        $this->assertSame(-15.4, $parsed2['metrics'][0]['value']);
    }

    public function testUnicodeLineSeparatorsEscaped(): void
    {
        $payload = ['msg' => "line1\u{2028}line2\u{2029}line3\u{0085}line4"];
        $formatted = Kestra::format($payload);

        $this->assertStringContainsString('\\u2028', $formatted);
        $this->assertStringContainsString('\\u2029', $formatted);
        $this->assertStringContainsString('\\u0085', $formatted);
    }

    public function testContextFromFile(): void
    {
        $tmpFile = tempnam(sys_get_temp_dir(), 'kestra_ctx_');
        file_put_contents($tmpFile, json_encode(['flowId' => 'my-flow', 'executionId' => 'exec-123']));

        try {
            $context = Kestra::context($tmpFile);
            $this->assertSame(['flowId' => 'my-flow', 'executionId' => 'exec-123'], $context);
        } finally {
            @unlink($tmpFile);
        }
    }

    public function testContextFromEnv(): void
    {
        $encoded = base64_encode(json_encode(['user' => 'admin']));
        putenv("KESTRA_CONTEXT={$encoded}");

        try {
            $context = Kestra::context('/non/existent/path/never_created.json');
            $this->assertSame(['user' => 'admin'], $context);
        } finally {
            putenv('KESTRA_CONTEXT');
        }
    }

    public function testContextThrowsWhenMissing(): void
    {
        putenv('KESTRA_CONTEXT');
        putenv('KESTRA_EXECUTION_CONTEXT_FILE');

        $this->expectException(RuntimeException::class);
        $this->expectExceptionMessage('No Kestra execution context found');

        Kestra::context('/non/existent/context.json');
    }
}
