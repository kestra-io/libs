import groovy.json.JsonException
import groovy.json.JsonLexer
import groovy.json.JsonOutput
import groovy.json.JsonSlurperClassic
import groovy.json.JsonToken

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.nio.file.AccessDeniedException
import java.nio.file.Files
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.Paths
import java.time.Duration
import java.time.temporal.TemporalAccessor
import java.time.temporal.TemporalAmount

import static groovy.json.JsonTokenType.CLOSE_BRACKET
import static groovy.json.JsonTokenType.CLOSE_CURLY
import static groovy.json.JsonTokenType.OPEN_BRACKET
import static groovy.json.JsonTokenType.OPEN_CURLY

/**
 * Sends outputs, metrics, logs and assets from Groovy script tasks to Kestra, and reads the execution context.
 * Each send call prints one `::{...}::` line to stdout, which Kestra parses. One file, Groovy 3 and later.
 */
class Kestra {
    static final String CONTEXT_FILE = '.kestra-execution-context.json'
    private static final int MAX_DEPTH = 512
    private static final Logger LOGGER = new Logger()
    private static String contextJson

    /** Returns the `::{...}::` line for a map, without sending it. */
    static String format(Object map) {
        if (!(map instanceof Map)) {
            throw new IllegalArgumentException('Kestra lines hold a map, for example Kestra.format(outputs: [rows: 42]).')
        }
        Object prepared
        try {
            prepared = prepare(map)
        } catch (StackOverflowError ignored) {
            throw new IllegalArgumentException('This value cannot be sent to Kestra as JSON: it is nested too deep or contains itself.')
        }
        // JsonOutput escapes all non-ASCII, which covers U+0085, U+2028 and U+2029: Java reads them as line terminators.
        '::' + JsonOutput.toJson(prepared) + '::'
    }

    /** An empty map sends nothing, as in Python, so outputs built in a loop over no rows do not fail the task. */
    static void outputs(Object outputs) {
        if (!(outputs instanceof Map)) {
            throw new IllegalArgumentException('Outputs must be a map, for example Kestra.outputs(rows: 42).')
        }
        if (outputs) {
            send([outputs: outputs])
        }
    }

    /** Takes inputs and outputs lists. An empty map sends nothing. */
    static void assets(Object assets) {
        if (!(assets instanceof Map)) {
            throw new IllegalArgumentException("Assets must be a map, for example Kestra.assets(outputs: [[id: 'sales.orders', type: 'TABLE']]).")
        }
        ((Map) assets).each { key, value ->
            // String.valueOf, as a GString key never equals the String 'outputs'.
            if (!(String.valueOf(key) in ['inputs', 'outputs'])) {
                throw new IllegalArgumentException("Assets hold only inputs and outputs, not '$key'.")
            }
            // Collection, not Iterable: a Path is Iterable and would be sent as one string.
            if (!(value instanceof Collection || value instanceof Iterator || value?.getClass()?.isArray())) {
                throw new IllegalArgumentException("Asset $key must be a list, for example [[id: 'sales.orders', type: 'TABLE']].")
            }
        }
        if (assets) {
            send([assets: assets])
        }
    }

    static void counter(String name, Object value, Object tags = [:]) { sendMetric(name, 'counter', value, tags) }

    static void gauge(String name, Object value, Object tags = [:]) { sendMetric(name, 'gauge', value, tags) }

    /** Sends a timer in seconds, or for a Duration such as Duration.between(start, Instant.now()). */
    static void timer(String name, Object seconds, Object tags = [:]) {
        sendMetric(name, 'timer', seconds instanceof Duration ? ((Duration) seconds).toNanos() / 1e9d : seconds, tags)
    }

    // Groovy passes named arguments, as in counter('rows', 3, env: 'qa'), as a first Map.
    static void counter(Map tags, String name, Object value) { counter(name, value, tags) }

    static void gauge(Map tags, String name, Object value) { gauge(name, value, tags) }

    static void timer(Map tags, String name, Object seconds) { timer(name, seconds, tags) }

    static <T> T timer(Map tags, String name, Closure<T> closure) { timer(name, tags, closure) }

    /** Times the closure and returns its result. No metric is sent if it throws. */
    static <T> T timer(String name, Map tags = [:], Closure<T> closure) {
        // Checked first, so a bad name or tag does not fail after the closure has done its work.
        Map<String, String> stringTags = metricTags(name, tags)
        long start = System.nanoTime()
        T result = closure.call()
        send([metrics: [[name: name, type: 'timer', value: (System.nanoTime() - start) / 1e9d, tags: stringTags]]])
        result
    }

    static Logger getLogger() { LOGGER }

    /**
     * The execution context, read from path, KESTRA_EXECUTION_CONTEXT_FILE or .kestra-execution-context.json (written when
     * the task sets executionContext: true). Without a path, or with an empty one, falls back to the base64 KESTRA_CONTEXT
     * variable. The default context is read once, and each call returns a new map the caller may change.
     *
     * @throws FileNotFoundException when no context is found
     * @throws IOException when the context file is a directory or cannot be read
     * @throws IllegalArgumentException when KESTRA_CONTEXT is not base64, or the context is not a JSON object
     */
    static Map<String, Object> context(String path = null) {
        boolean isExplicit = path
        String json = isExplicit ? null : contextJson
        String source = null
        if (json == null) {
            String file = isExplicit ? path : (System.getenv('KESTRA_EXECUTION_CONTEXT_FILE') ?: CONTEXT_FILE)
            String encoded = (System.getenv('KESTRA_CONTEXT') ?: '').replaceAll(/\s/, '')
            source = file
            try {
                json = utf8(Files.readAllBytes(Paths.get(file)), file)
            } catch (NoSuchFileException ignored) {
                if (isExplicit) {
                    throw new FileNotFoundException("Kestra execution context file '$file' does not exist.")
                }
                if (!encoded) {
                    throw new FileNotFoundException("No Kestra execution context found: '$file' does not exist and the KESTRA_CONTEXT " +
                        'environment variable is not set. The execution context is only available when the script runs inside a Kestra task.')
                }
                byte[] bytes
                try {
                    bytes = Base64.decoder.decode(encoded)
                } catch (IllegalArgumentException e) {
                    throw new IllegalArgumentException('The KESTRA_CONTEXT environment variable is not valid base64.', e)
                }
                source = 'KESTRA_CONTEXT'
                json = utf8(bytes, source)
            } catch (IOException e) {
                // Only a missing file falls back. A directory or an unreadable file is a misconfiguration to report.
                String reason = e instanceof AccessDeniedException ? 'permission denied' : e.message
                throw new IOException("Kestra execution context file '$file' cannot be read ($reason). Check the path and its permissions.", e)
            }
        }
        Object context
        try {
            checkStructure(json)
            // The other JsonSlurper parsers overflow integers past Long silently.
            context = new JsonSlurperClassic().parseText(json)
        } catch (JsonException | IllegalArgumentException e) {
            throw new IllegalArgumentException("The execution context in $source is not valid JSON: ${e.message}", e)
        }
        if (!(context instanceof Map)) {
            throw new IllegalArgumentException("The execution context in $source is not a JSON object.")
        }
        if (!isExplicit) {
            contextJson = json
        }
        context as Map<String, Object>
    }

    // JsonSlurper reads the first value and ignores what follows, and overflows the stack on deep nesting.
    private static void checkStructure(String json) {
        JsonLexer lexer = new JsonLexer(new StringReader(json))
        int depth = 0
        boolean isDone = false
        for (JsonToken token = lexer.nextToken(); token != null; token = lexer.nextToken()) {
            if (isDone) {
                throw new JsonException("unexpected text after the JSON value at line ${token.startLine} column ${token.startColumn}.")
            }
            if (token.type == OPEN_CURLY || token.type == OPEN_BRACKET) {
                if (++depth > MAX_DEPTH) {
                    throw new JsonException('it is nested too deep.')
                }
            } else if (token.type == CLOSE_CURLY || token.type == CLOSE_BRACKET) {
                depth--
            }
            isDone = depth == 0
        }
    }

    private static String utf8(byte[] bytes, String source) {
        try {
            StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString()
        } catch (CharacterCodingException e) {
            throw new IllegalArgumentException("The execution context in $source is not valid JSON: it is not valid UTF-8.", e)
        }
    }

    private static void send(Map map) {
        String line = format(map)
        // One write per line, flushed, so Kestra gets each line when it is written and not at exit.
        synchronized (System.out) {
            System.out.print(line + '\n')
            System.out.flush()
        }
    }

    private static void sendMetric(String name, String type, Object value, Object tags) {
        Map<String, String> stringTags = metricTags(name, tags)
        if (!isFinite(value)) {
            throw new IllegalArgumentException("Metric '$name' value must be a finite number.")
        }
        send([metrics: [[name: name, type: type, value: value, tags: stringTags]]])
    }

    private static Map<String, String> metricTags(String name, Object tags) {
        if (!name) {
            throw new IllegalArgumentException('Metric name must be a non-empty string.')
        }
        if (tags != null && !(tags instanceof Map)) {
            throw new IllegalArgumentException("Metric '$name' tags must be a map, for example [env: 'prod'].")
        }
        Map<String, String> stringTags = [:]
        ((Map) tags ?: [:]).each { key, tag ->
            String text = keyText(key)
            if (stringTags.containsKey(text)) {
                throw new IllegalArgumentException("Metric '$name' has two tags named '$text'.")
            }
            if (tag == null || tag instanceof Map || tag instanceof Iterable || tag.getClass().isArray()) {
                throw new IllegalArgumentException("Metric '$name' tag '$text' must be a single value, for example [env: 'prod'].")
            }
            // Kestra reads tags as a map of strings. Numbers keep their text, as str() does in Python.
            stringTags[text] = tag instanceof Number ? tag.toString() : prepare(tag).toString()
        }
        stringTags
    }

    // Kestra reads a metric value as a double, so a BigInteger or BigDecimal past the double range would read as Infinity.
    private static boolean isFinite(Object value) {
        if (!(value instanceof Number)) {
            return false
        }
        double number = ((Number) value).doubleValue()
        !Double.isNaN(number) && !Double.isInfinite(number)
    }

    // Copies the value as maps with string keys, lists, strings, numbers, booleans and nulls, which JsonOutput writes as is.
    private static Object prepare(Object value) {
        // instanceof, not switch: Groovy's switch also matches a Class value against its own type.
        if (value == null || value instanceof Boolean || value instanceof String) {
            return value
        }
        if (value instanceof Double || value instanceof Float) {
            if (!isFinite(value)) {
                throw new IllegalArgumentException('This value cannot be sent to Kestra as JSON: replace NaN and Infinity with null.')
            }
            return value
        }
        // Kestra reads a decimal number as a double, while an integer of any size keeps its value, as in Python.
        if (value instanceof BigDecimal && !isFinite(value)) {
            throw new IllegalArgumentException('This value cannot be sent to Kestra as JSON: a number is past the double range and would read as Infinity.')
        }
        if (value instanceof Number) {
            return value
        }
        if (value instanceof CharSequence || value instanceof Character || value instanceof Enum || value instanceof TemporalAccessor
            || value instanceof TemporalAmount || value instanceof UUID || value instanceof URI || value instanceof URL || value instanceof File || value instanceof Path) {
            return value.toString()
        }
        // A SQL DATE or TIME holds a local value, which a UTC instant would shift outside UTC.
        if (value instanceof java.sql.Date) {
            return ((java.sql.Date) value).toLocalDate().toString()
        }
        if (value instanceof java.sql.Time) {
            return ((java.sql.Time) value).toLocalTime().toString()
        }
        if (value instanceof Date) {
            return ((Date) value).toInstant().toString()
        }
        if (value instanceof Map) {
            Map<String, Object> copy = [:]
            ((Map) value).each { key, item ->
                String text = keyText(key)
                // 1 and '1', or a GString and an equal String, are distinct keys that read as the same JSON key.
                if (copy.containsKey(text)) {
                    throw new IllegalArgumentException("This value cannot be sent to Kestra as JSON: two keys read as '$text'.")
                }
                copy[text] = prepare(item)
            }
            return copy
        }
        if (value instanceof Iterable || value instanceof Iterator || value.getClass().isArray()) {
            List<Object> list = []
            for (Object item : (value instanceof Iterator ? value : value as List)) {
                list << prepare(item)
            }
            return list
        }
        throw new IllegalArgumentException("This value cannot be sent to Kestra as JSON: ${value.getClass().name} is not a map, list, string, number, " +
            'boolean or date. Convert it first, for example with toString().')
    }

    private static String keyText(Object key) {
        if (key == null || key instanceof CharSequence || key instanceof Number || key instanceof Boolean || key instanceof Character || key instanceof Enum) {
            return String.valueOf(key)
        }
        throw new IllegalArgumentException("This value cannot be sent to Kestra as JSON: a key must be a string, number or boolean, not ${key.getClass().name}.")
    }

    /** SLF4J-style logger: `{}` placeholders, and a Throwable as the last argument is appended with its stack trace. Never throws on its values. */
    static class Logger {
        void trace(Object message, Object... args) { log('TRACE', message, args) }

        void debug(Object message, Object... args) { log('DEBUG', message, args) }

        void info(Object message, Object... args) { log('INFO', message, args) }

        void warn(Object message, Object... args) { log('WARN', message, args) }

        void error(Object message, Object... args) { log('ERROR', message, args) }

        private static void log(String level, Object message, Object[] args) {
            // A single null value reaches varargs as a null array.
            List<Object> values = args == null ? [null] : args as List
            // As in SLF4J, a trailing Throwable is always the exception, never a placeholder value.
            Throwable error = values && values.last() instanceof Throwable ? values.remove(values.size() - 1) as Throwable : null
            String pattern = text(message)
            StringBuilder builder = new StringBuilder()
            int start = 0
            int used = 0
            int index
            while ((index = pattern.indexOf('{}', start)) >= 0 && used < values.size()) {
                builder.append(pattern, start, index).append(text(values[used++]))
                start = index + 2
            }
            builder.append(pattern.substring(start))
            if (error != null) {
                StringWriter trace = new StringWriter()
                try {
                    error.printStackTrace(new PrintWriter(trace))
                    builder.append('\n').append(trace.toString().trim())
                } catch (Exception ignored) {
                    builder.append('\n').append(error.getClass().name).append(': [FAILED getMessage()]')
                }
            }
            send([logs: [[level: level, message: builder.toString()]]])
        }

        private static String text(Object value) {
            try {
                // A toString() can return null, and lists that contain each other overflow the stack.
                String text = String.valueOf(value)
                return text == null ? 'null' : text
            } catch (Exception | StackOverflowError ignored) {
                return '[FAILED toString()]'
            }
        }
    }
}
