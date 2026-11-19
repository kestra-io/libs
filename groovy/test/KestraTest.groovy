// Run from the groovy directory: groovy test/KestraTest.groovy
import java.nio.charset.StandardCharsets
import java.nio.file.Files

tests = [:]
failures = 0

void test(String name, Closure body) { tests[name] = body }

// Runs the closure with stdout captured, and returns what it wrote.
String capture(Closure body) {
    PrintStream real = System.out
    ByteArrayOutputStream bytes = new ByteArrayOutputStream()
    System.setOut(new PrintStream(bytes, true, 'UTF-8'))
    try {
        body()
    } finally {
        System.setOut(real)
    }
    bytes.toString('UTF-8')
}

Throwable errorOf(Closure body) {
    try {
        body()
    } catch (Throwable e) {
        return e
    }
    throw new AssertionError('expected an error')
}

File tempDir() { Files.createTempDirectory('kestra-ctx-').toFile() }

File write(File dir, String name, String content) {
    File file = new File(dir, name)
    file.setText(content, 'UTF-8')
    file
}

// Runs a script in a new JVM with the given directory and environment, since a JVM cannot change its own.
String run(File dir, Map<String, String> env, String script) {
    File source = write(tempDir(), 'probe.groovy', script)
    String groovy = System.getProperty('os.name').toLowerCase().contains('win') ? 'groovy.bat' : 'groovy'
    ProcessBuilder builder = new ProcessBuilder(groovy, '-cp', new File('.').canonicalPath, source.path).directory(dir).redirectErrorStream(true)
    builder.environment().remove('KESTRA_CONTEXT')
    builder.environment().remove('KESTRA_EXECUTION_CONTEXT_FILE')
    builder.environment().putAll(env)
    Process process = builder.start()
    String output = process.inputStream.getText('UTF-8').readLines().findAll { !it.startsWith('WARNING') }.join('\n')
    process.waitFor()
    output
}

String base64(String text) { text.getBytes(StandardCharsets.UTF_8).encodeBase64().toString() }

test('outputs send one line with nested values, and non-ASCII and line terminators escaped') {
    String line = capture {
        Kestra.outputs(rows: 42, ratio: 0.1, ok: true, nested: [list: [1, 'two', [a: false]]], text: "café a\nb \u0085   \"q\"", none: null)
    }
    assert line == '::{"outputs":{"rows":42,"ratio":0.1,"ok":true,"nested":{"list":[1,"two",{"a":false}]},' +
        '"text":"caf\\u00e9 a\\nb \\u0085\\u2028\\u2029 \\"q\\"","none":null}}::\n'
}

test('everyday values become JSON values') {
    def date = java.time.LocalDate.of(2026, 1, 2)
    String line = Kestra.format([
        gstring: "row ${1}", ch: 'x' as char, day: java.time.DayOfWeek.MONDAY, date: date, instant: new Date(0),
        big: 2G ** 70, decimal: 1.10G, set: [3] as Set, array: [1, 2] as int[], iterator: [4].iterator(),
        uuid: UUID.fromString('00000000-0000-0000-0000-000000000001'), file: new File('/data/a.csv'), compare: 3 > 1, (1): 'one',
    ])
    assert line == '::{"gstring":"row 1","ch":"x","day":"MONDAY","date":"2026-01-02","instant":"1970-01-01T00:00:00Z",' +
        '"big":1180591620717411303424,"decimal":1.10,"set":[3],"array":[1,2],"iterator":[4],' +
        '"uuid":"00000000-0000-0000-0000-000000000001","file":"/data/a.csv","compare":true,"1":"one"}::'
}

test('outputs refuse values Kestra cannot read') {
    Map loop = [:]
    loop.self = loop
    [
        [[v: Double.NaN], 'Replace NaN and Infinity with null'],
        [[v: Float.POSITIVE_INFINITY], 'Replace NaN and Infinity with null'],
        [[v: new Object()], 'java.lang.Object is not a map, list, string, number, boolean or date'],
        [[v: String], 'java.lang.Class is not a map'],
        [[v: { 1 }], 'is not a map, list, string, number, boolean or date'],
        [[v: [(1): 'a', '1': 'b']], "two keys read as '1'"],
        [[v: ["a${1}": 'x', a1: 'y']], "two keys read as 'a1'"],
        [[loop: loop], 'nested too deep or contains itself'],
    ].each { value, message ->
        Throwable error = errorOf { Kestra.outputs(value) }
        assert error instanceof IllegalArgumentException && error.message.contains(message)
    }
    assert errorOf { Kestra.outputs([:]) }.message == 'Outputs must be a non-empty map, for example Kestra.outputs(rows: 42).'
    assert capture { errorOf { Kestra.outputs(v: Double.NaN) } } == ''
}

test('metrics send numbers and string tags, and empty tags as {}') {
    String lines = capture {
        Kestra.counter('rows', 3, [source: 'shop', retried: false, shard: 2, (1): 'x'])
        Kestra.gauge('size', 2.5G)
        Kestra.timer('fetch', 1.25)
    }
    assert lines == '::{"metrics":[{"name":"rows","type":"counter","value":3,"tags":{"source":"shop","retried":"false","shard":"2","1":"x"}}]}::\n' +
        '::{"metrics":[{"name":"size","type":"gauge","value":2.5,"tags":{}}]}::\n' +
        '::{"metrics":[{"name":"fetch","type":"timer","value":1.25,"tags":{}}]}::\n'
}

test('metrics refuse values Kestra would drop') {
    assert errorOf { Kestra.counter('', 1) }.message == 'Metric name must be a non-empty string.'
    ['3', Double.NaN, Double.NEGATIVE_INFINITY, true, null].each { value ->
        assert errorOf { Kestra.counter('rows', value) }.message == "Metric 'rows' value must be a finite number."
    }
    assert errorOf { Kestra.counter('rows', 1, [env: ['a']]) }.message == "Metric 'rows' tag 'env' must be a single value, for example [env: 'prod']."
    assert errorOf { Kestra.counter('rows', 1, [env: null]) }.message == "Metric 'rows' tag 'env' must be a single value, for example [env: 'prod']."
}

test('a timed closure returns its result, and sends no metric when it throws') {
    def result
    String line = capture { result = Kestra.timer('fetch', [env: 'qa']) { Thread.sleep(20); [1, 2] } }
    assert result == [1, 2]
    def matcher = line =~ /^::\{"metrics":\[\{"name":"fetch","type":"timer","value":([0-9.E-]+),"tags":\{"env":"qa"\}\}\]\}::\n$/
    assert matcher.matches() && (matcher.group(1) as double) >= 0.015
    assert capture { assert errorOf { Kestra.timer('fetch') { throw new IllegalStateException('boom') } }.message == 'boom' } == ''
}

test('logger levels, placeholders and a trailing exception') {
    String lines = capture {
        Kestra.logger.trace('t')
        Kestra.logger.debug('{} rows in {}', 3, 'orders')
        Kestra.logger.info('{} and {}', null)
        Kestra.logger.warn('100% {}')
        Kestra.logger.error('failed {}', 'x', new IllegalStateException('boom'))
    }
    List<String> rows = lines.readLines()
    assert rows[0..3] == [
        '::{"logs":[{"level":"TRACE","message":"t"}]}::',
        '::{"logs":[{"level":"DEBUG","message":"3 rows in orders"}]}::',
        '::{"logs":[{"level":"INFO","message":"null and {}"}]}::',
        '::{"logs":[{"level":"WARN","message":"100% {}"}]}::',
    ]
    assert rows.size() == 5 && rows[4].startsWith('::{"logs":[{"level":"ERROR","message":"failed x\\njava.lang.IllegalStateException: boom\\n\\tat ')
}

test('assets keep empty lists and empty metadata') {
    String line = capture { Kestra.assets(inputs: [], outputs: [[id: 'sales.orders', type: 'TABLE', metadata: [:]]]) }
    assert line == '::{"assets":{"inputs":[],"outputs":[{"id":"sales.orders","type":"TABLE","metadata":{}}]}}::\n'
}

String CONTEXT = '{"labels":{"team":"caf\\u00e9"},"inputs":{"rows":42,"list":[1,null],"big":12345678901234567890},"execution":{"id":"default"}}'
String PRINT_CONTEXT = 'def c = Kestra.context(); c.labels = null; println Kestra.context().labels.team + " " + Kestra.context().execution.id'

test('context is read from the default file once, and each call returns a new map') {
    File dir = tempDir()
    write(dir, Kestra.CONTEXT_FILE, CONTEXT)
    assert run(dir, [:], 'println Kestra.context().labels.team; new File(Kestra.CONTEXT_FILE).delete(); ' + PRINT_CONTEXT) == 'café\ncafé default'
}

test('a file wins over KESTRA_CONTEXT, and KESTRA_EXECUTION_CONTEXT_FILE over the default file') {
    File dir = tempDir()
    write(dir, Kestra.CONTEXT_FILE, '{"execution":{"id":"default"}}')
    File envFile = write(tempDir(), 'ctx.json', '{"execution":{"id":"env-file"}}')
    String script = 'println Kestra.context().execution.id'
    assert run(dir, [KESTRA_CONTEXT: base64('{"execution":{"id":"env"}}')], script) == 'default'
    assert run(dir, [KESTRA_EXECUTION_CONTEXT_FILE: envFile.path], script) == 'env-file'
    assert run(dir, [KESTRA_EXECUTION_CONTEXT_FILE: ''], script) == 'default'
}

test('falls back to the base64 KESTRA_CONTEXT variable without a file, also for an empty path') {
    assert run(tempDir(), [KESTRA_CONTEXT: base64(CONTEXT)], 'println Kestra.context().labels.team + " " + Kestra.context("").inputs.rows + " " + Kestra.context().inputs.big') == 'café 42 12345678901234567890'
}

test('an explicit path is read as given, never cached and never falls back') {
    File dir = tempDir()
    write(dir, Kestra.CONTEXT_FILE, '{"execution":{"id":"default"}}')
    write(dir, 'explicit.json', '{"execution":{"id":"explicit"}}')
    assert run(dir, [KESTRA_CONTEXT: base64('{"a":1}')],
        'println([Kestra.context("explicit.json"), Kestra.context(), Kestra.context("explicit.json")]*.execution.id); ' +
        'try { Kestra.context("typo.json") } catch (FileNotFoundException e) { println e.message }') ==
        "[explicit, default, explicit]\nKestra execution context file 'typo.json' does not exist."
}

test('context errors name their cause') {
    String print = 'try { Kestra.context() } catch (e) { println e.class.simpleName + ": " + e.message }'
    File dir = tempDir()
    write(dir, Kestra.CONTEXT_FILE, '[1, 2]')
    assert run(dir, [:], print) == 'IllegalArgumentException: The execution context in .kestra-execution-context.json is not a JSON object.'
    write(dir, Kestra.CONTEXT_FILE, '{"a":')
    assert run(dir, [:], print).startsWith('IllegalArgumentException: The execution context in .kestra-execution-context.json is not valid JSON: ')
    assert run(tempDir(), [KESTRA_CONTEXT: '{"a":1}'], print) == 'IllegalArgumentException: The KESTRA_CONTEXT environment variable is not valid base64.'
    assert run(tempDir(), [KESTRA_CONTEXT: base64('[]')], print) == 'IllegalArgumentException: The execution context in KESTRA_CONTEXT is not a JSON object.'
    assert run(tempDir(), [KESTRA_EXECUTION_CONTEXT_FILE: tempDir().path, KESTRA_CONTEXT: base64('{"a":1}')], print) == 'IOException: Is a directory'
    assert run(tempDir(), [:], print) == "FileNotFoundException: No Kestra execution context found: '.kestra-execution-context.json' does not exist " +
        'and the KESTRA_CONTEXT environment variable is not set. The execution context is only available when the script runs inside a Kestra task.'
}

tests.each { name, body ->
    try {
        body()
        println "ok - $name"
    } catch (Throwable e) {
        failures++
        println "not ok - $name\n    $e"
    }
}
println "${tests.size()} tests, $failures failed"
System.exit(failures ? 1 : 0)
