<?php

declare(strict_types=1);

namespace Kestra\Tests;

use Kestra\Kestra;
use PHPUnit\Framework\TestCase;

class KestraLoggerTest extends TestCase
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

    /**
     * @dataProvider logLevelsProvider
     */
    public function testLogLevels(string $method, string $expectedLevel): void
    {
        Kestra::logger()->$method('Sample message for ' . $expectedLevel);

        $parsed = $this->getLastParsed();
        $this->assertSame([
            'logs' => [
                [
                    'level' => $expectedLevel,
                    'message' => 'Sample message for ' . $expectedLevel,
                ],
            ],
        ], $parsed);
    }

    public static function logLevelsProvider(): array
    {
        return [
            ['trace', 'TRACE'],
            ['debug', 'DEBUG'],
            ['info', 'INFO'],
            ['warn', 'WARN'],
            ['warning', 'WARN'],
            ['error', 'ERROR'],
        ];
    }

    public function testMultipleMessages(): void
    {
        Kestra::logger()->info('First step', 'Second step', 'Third step');

        $parsed = $this->getLastParsed();
        $this->assertSame([
            'logs' => [
                ['level' => 'INFO', 'message' => 'First step'],
                ['level' => 'INFO', 'message' => 'Second step'],
                ['level' => 'INFO', 'message' => 'Third step'],
            ],
        ], $parsed);
    }
}
