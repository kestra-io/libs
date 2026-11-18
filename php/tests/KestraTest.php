<?php

declare(strict_types=1);

// Each test runs a snippet in a child PHP process, since the library writes to STDOUT. Run with: php tests/KestraTest.php

const LIB = __DIR__ . '/../src/Kestra.php';

/** @return array{0: string, 1: string, 2: int} stdout, stderr and exit code */
function run(string $code, array $env = [], ?string $cwd = null, bool $isStdin = false): array
{
    $script = sys_get_temp_dir() . '/kestra-test-' . bin2hex(random_bytes(6)) . '.php';
    file_put_contents($script, "<?php\nrequire " . var_export(realpath(LIB), true) . ";\nuse Kestra\\Kestra;\n" . $code);
    $base = array_diff_key(getenv(), ['KESTRA_CONTEXT' => 1, 'KESTRA_EXECUTION_CONTEXT_FILE' => 1]);
    $command = $isStdin ? [PHP_BINARY, '-d', 'display_errors=stderr'] : [PHP_BINARY, '-d', 'display_errors=stderr', $script];
    $process = proc_open($command, [0 => $isStdin ? ['file', $script, 'r'] : ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, $cwd ?? sys_get_temp_dir(), $env + $base);
    $out = stream_get_contents($pipes[1]);
    $err = stream_get_contents($pipes[2]);
    $exit = proc_close($process);
    unlink($script);
    return [$out, $err, $exit];
}

/** @return list<array<string, mixed>> the decoded payload of each line, after checking every line has the Kestra format */
function lines(string $out): array
{
    $payloads = [];
    foreach (explode("\n", rtrim($out, "\n")) as $line) {
        check(preg_match('/^::(\{.*})::$/', $line, $match) === 1, "not a Kestra line: $line");
        $payloads[] = json_decode($match[1], true, 512, JSON_THROW_ON_ERROR);
    }
    return $payloads;
}

function check(bool $condition, string $message): void
{
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

function same(mixed $expected, mixed $actual): void
{
    check($expected === $actual, 'expected ' . var_export($expected, true) . ', got ' . var_export($actual, true));
}

function fails(string $code, string $message, array $env = [], ?string $cwd = null): void
{
    [$out, $err, $exit] = run($code, $env, $cwd);
    check($exit !== 0, "expected a failure, got output: $out");
    check(str_contains($err, $message), "expected '$message' in: $err");
}

/** @var list<string> */
$cleanup = [];

function contextDir(string $json): string
{
    global $cleanup;
    $dir = sys_get_temp_dir() . '/kestra-ctx-' . bin2hex(random_bytes(4));
    mkdir($dir);
    file_put_contents("$dir/.kestra-execution-context.json", $json);
    $cleanup[] = $dir;
    return $dir;
}

$tests = [
    'outputs are one line with nested values' => function () {
        [$out] = run("Kestra::outputs(['rows' => 42, 'model' => ['type' => 'lm', 'r2' => 0.65], 'empty' => null]);");
        same([['outputs' => ['rows' => 42, 'model' => ['type' => 'lm', 'r2' => 0.65], 'empty' => null]]], lines($out));
    },

    'zero-fraction floats stay floats' => function () {
        [$out] = run("Kestra::outputs(['ratio' => 1.0]); Kestra::gauge('g', 2.0);");
        check(str_contains($out, '"ratio":1.0') && str_contains($out, '"value":2.0'), $out);
    },

    'a script piped to php on stdin, where STDOUT may be undefined, still sends lines' => function () {
        [$out] = run("Kestra::outputs(['a' => 1]);", [], null, true);
        same([['outputs' => ['a' => 1]]], lines($out));
    },

    'multi-line strings, Java line terminators and non-ASCII stay on one line' => function () {
        [$out] = run('Kestra::outputs(["note" => "a\nb\u{85}c\u{2028}d\u{2029}e caf\u{e9} \u{1F600}"]);');
        same(1, substr_count($out, "\n"));
        check(preg_match('/[^\x20-\x7e\n]/', $out) === 0, "raw non-ASCII in: $out");
        same("a\nb\u{85}c\u{2028}d\u{2029}e caf\u{e9} \u{1F600}", lines($out)[0]['outputs']['note']);
    },

    'outputs must be a non-empty array with string keys' => function () {
        fails('Kestra::outputs([]);', 'Outputs must be a non-empty array with string keys');
        fails('Kestra::outputs([1, 2]);', 'Outputs must be a non-empty array with string keys');
    },

    'values JSON cannot encode fail with a plain sentence' => function () {
        fails("Kestra::outputs(['x' => NAN]);", 'Replace NAN and INF with null.');
        fails("Kestra::outputs(['x' => \"\\xff\"]);", 'Make strings valid UTF-8');
        [, $err] = run("Kestra::outputs(['x' => fopen('php://memory', 'r')]);");
        check(str_contains($err, 'cannot be sent to Kestra as JSON') && !str_contains($err, 'NAN'), $err);
    },

    'metrics have number values, string tags and an object for no tags' => function () {
        [$out] = run(<<<'PHP'
            Kestra::counter('rows', 3, ['source' => 'shop', 'batch' => 7, 'dry' => false, 'ratio' => 0.5]);
            Kestra::gauge('queue', 1.5);
            Kestra::timer('fetch', 2);
            PHP);
        same([
            ['metrics' => [['name' => 'rows', 'type' => 'counter', 'value' => 3, 'tags' => ['source' => 'shop', 'batch' => '7', 'dry' => 'false', 'ratio' => '0.5']]]],
            ['metrics' => [['name' => 'queue', 'type' => 'gauge', 'value' => 1.5, 'tags' => []]]],
            ['metrics' => [['name' => 'fetch', 'type' => 'timer', 'value' => 2, 'tags' => []]]],
        ], lines($out));
        check(str_contains($out, '"tags":{}'), "empty tags must be an object: $out");
    },

    'metrics reject invalid input' => function () {
        fails("Kestra::counter('', 1);", 'Metric name must be a non-empty string.');
        fails("Kestra::counter('rows', '3');", "Metric 'rows' value must be a finite number.");
        fails("Kestra::counter('rows', true);", "Metric 'rows' value must be a finite number.");
        fails("Kestra::gauge('rows', INF);", "Metric 'rows' value must be a finite number.");
        fails("Kestra::counter('rows', 1, ['env' => null]);", "Metric 'rows' tag 'env' must be a single value");
        fails("Kestra::counter('rows', 1, ['env' => ['a']]);", "Metric 'rows' tag 'env' must be a single value");
        fails("Kestra::counter('rows', 1, ['prod', 'eu']);", "Metric 'rows' tags must be an array with string keys");
        fails("Kestra::timer('fetch', NAN);", "Metric 'fetch' value must be a finite number.");
        fails("Kestra::timer('fetch', 'strlen');", "Metric 'fetch' value must be a finite number.");
        fails("Kestra::timer('fetch', '2.5');", "Metric 'fetch' value must be a finite number.");
        fails("Kestra::timer('fetch', true);", "Metric 'fetch' value must be a finite number.");
    },

    'timer times a callable and returns its result' => function () {
        [$out] = run("echo json_encode(Kestra::timer('fit', function () { usleep(50000); return 'model'; }, ['env' => 'qa'])), \"\\n\";");
        [$line, $result] = explode("\n", rtrim($out, "\n"));
        same('"model"', $result);
        $metric = lines($line)[0]['metrics'][0];
        same(['fit', 'timer', ['env' => 'qa']], [$metric['name'], $metric['type'], $metric['tags']]);
        check($metric['value'] > 0.04 && $metric['value'] < 5, 'timer value in seconds: ' . $metric['value']);
    },

    'timer sends nothing when the callable throws' => function () {
        [$out, $err, $exit] = run("Kestra::timer('fit', function () { throw new LogicException('boom'); });");
        same('', $out);
        check($exit !== 0 && str_contains($err, 'boom'), $err);
    },

    'logger maps PSR-3 levels to Kestra levels' => function () {
        [$out] = run(<<<'PHP'
            $log = Kestra::logger();
            foreach (['trace', 'debug', 'info', 'notice', 'warning', 'error', 'critical', 'alert', 'emergency'] as $level) {
                $log->$level($level);
            }
            $log->log('WARNING', 'upper');
            PHP);
        $levels = array_map(fn ($line) => [$line['logs'][0]['level'], $line['logs'][0]['message']], lines($out));
        same([['TRACE', 'trace'], ['DEBUG', 'debug'], ['INFO', 'info'], ['INFO', 'notice'], ['WARN', 'warning'], ['ERROR', 'error'],
            ['ERROR', 'critical'], ['ERROR', 'alert'], ['ERROR', 'emergency'], ['WARN', 'upper']], $levels);
        fails("Kestra::logger()->log('fatal', 'x');", 'Log level must be one of');
    },

    'logger fills placeholders and replaces invalid bytes' => function () {
        [$out] = run(<<<'PHP'
            Kestra::logger()->warning('{count} orders, dry {dry}, missing {nope}', ['count' => 2, 'dry' => true]);
            Kestra::logger()->info("caf\xc3\xa9 \xff a\nb\u{85}c\u{2028}d\u{2029}e");
            PHP);
        check(preg_match('/[^\x20-\x7e\n]/', $out) === 0, "raw non-ASCII in: $out");
        same(['2 orders, dry true, missing {nope}', "caf\u{e9} \u{fffd} a\nb\u{85}c\u{2028}d\u{2029}e"], array_map(fn ($line) => $line['logs'][0]['message'], lines($out)));
    },

    'logger appends a PSR-3 exception from the context' => function () {
        [$out] = run("Kestra::logger()->error('Import failed', ['exception' => new RuntimeException('db down')]);");
        $message = lines($out)[0]['logs'][0]['message'];
        check(str_starts_with($message, "Import failed\nRuntimeException: db down"), $message);
        [$out] = run("Kestra::logger()->error('Failed: {exception}', ['exception' => new RuntimeException('db down')]);");
        same(1, substr_count(lines($out)[0]['logs'][0]['message'], 'db down'));
    },

    'empty asset metadata is sent as an object' => function () {
        [$out] = run("Kestra::assets(['outputs' => [['id' => 'x', 'type' => 'TABLE', 'metadata' => []]]]);");
        check(str_contains($out, '"metadata":{}'), $out);
    },

    'assets are sent as given' => function () {
        [$out] = run("Kestra::assets(['inputs' => [['id' => 'raw.orders']], 'outputs' => [['id' => 'sales.orders', 'type' => 'TABLE', 'metadata' => ['rows' => 120]]]]);");
        same([['assets' => ['inputs' => [['id' => 'raw.orders']], 'outputs' => [['id' => 'sales.orders', 'type' => 'TABLE', 'metadata' => ['rows' => 120]]]]]], lines($out));
        fails('Kestra::assets([]);', 'Assets must be a non-empty array with string keys');
    },

    'context is read from the default file once' => function () {
        $dir = contextDir('{"execution":{"id":"e1"},"labels":{"team":"data"}}');
        [$out] = run(<<<'PHP'
            $first = Kestra::context();
            $first['labels'] = [];
            unlink(Kestra::CONTEXT_FILE);
            echo Kestra::context()['labels']['team'], ' ', Kestra::context()['execution']['id'];
            PHP, [], $dir);
        same('data e1', $out);
    },

    'context from KESTRA_EXECUTION_CONTEXT_FILE, an explicit path or the base64 variable' => function () {
        $dir = contextDir('{"execution":{"id":"from-file"}}');
        [$out] = run("echo Kestra::context()['execution']['id'];", ['KESTRA_EXECUTION_CONTEXT_FILE' => "$dir/.kestra-execution-context.json"]);
        same('from-file', $out);
        [$out] = run("echo Kestra::context(" . var_export("$dir/.kestra-execution-context.json", true) . ")['execution']['id'];");
        same('from-file', $out);
        [$out] = run("echo Kestra::context()['execution']['id'];", ['KESTRA_CONTEXT' => base64_encode('{"execution":{"id":"from-env"}}')]);
        same('from-env', $out);
    },

    'the file wins over the variable, and KESTRA_EXECUTION_CONTEXT_FILE over the default file' => function () {
        $dir = contextDir('{"execution":{"id":"default"}}');
        [$out] = run("echo Kestra::context()['execution']['id'];", ['KESTRA_CONTEXT' => base64_encode('{"execution":{"id":"from-env"}}')], $dir);
        same('default', $out);
        $other = contextDir('{"execution":{"id":"env-file"}}');
        [$out] = run("echo Kestra::context()['execution']['id'];", ['KESTRA_EXECUTION_CONTEXT_FILE' => "$other/.kestra-execution-context.json"], $dir);
        same('env-file', $out);
    },

    'an explicit path is not cached as the default context' => function () {
        $dir = contextDir('{"execution":{"id":"default"}}');
        $other = contextDir('{"execution":{"id":"explicit"}}');
        $explicit = var_export("$other/.kestra-execution-context.json", true);
        [$out] = run("echo Kestra::context($explicit)['execution']['id'], ' ', Kestra::context()['execution']['id'], ' ', Kestra::context($explicit)['execution']['id'];", [], $dir);
        same('explicit default explicit', $out);
    },

    'an explicit path never falls back to the variable' => function () {
        [$out, $err, $exit] = run("Kestra::context('typo.json');", ['KESTRA_CONTEXT' => base64_encode('{"a":1}')]);
        check($exit !== 0, $out);
        check(str_contains($err, "Kestra execution context file 'typo.json' does not exist."), $err);
        check(!str_contains($err, 'KESTRA_CONTEXT'), $err);
    },

    'an empty file variable means the default file' => function () {
        $dir = contextDir('{"execution":{"id":"default"}}');
        [$out] = run("echo Kestra::context()['execution']['id'];", ['KESTRA_EXECUTION_CONTEXT_FILE' => ''], $dir);
        same('default', $out);
    },

    'context that is not a JSON object names the source' => function () {
        fails('Kestra::context();', 'The execution context in .kestra-execution-context.json is not a JSON object.', [], contextDir('[1, 2]'));
        fails('Kestra::context();', 'The execution context in .kestra-execution-context.json is not a JSON object.', [], contextDir('{oops'));
        fails('Kestra::context();', 'The execution context in KESTRA_CONTEXT is not a JSON object.', ['KESTRA_CONTEXT' => base64_encode('[]')]);
        fails('Kestra::context();', 'The execution context in KESTRA_CONTEXT is not a JSON object.', ['KESTRA_CONTEXT' => 'not base64!']);
    },

    'context fails clearly outside Kestra' => function () {
        fails('Kestra::context();', 'The execution context is only available when the script runs inside a Kestra task.');
    },
];

$failed = 0;
foreach ($tests as $name => $test) {
    try {
        $test();
        echo "ok   $name\n";
    } catch (Throwable $e) {
        $failed++;
        echo "FAIL $name: {$e->getMessage()}\n";
    }
}
foreach ($cleanup as $dir) {
    array_map('unlink', glob("$dir/{,.}*.json", GLOB_BRACE) ?: []);
    rmdir($dir);
}
echo count($tests) - $failed, '/', count($tests), " passed\n";
exit($failed === 0 ? 0 : 1);
