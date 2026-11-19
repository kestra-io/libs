import groovy.json.JsonException
import groovy.json.JsonOutput
import groovy.json.JsonSlurperClassic

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.Paths
import java.time.temporal.TemporalAccessor

/**
 * Sends outputs, metrics, logs and assets from Groovy script tasks to Kestra, and reads the execution context.
 * Each send call prints one `::{...}::` line to stdout, which Kestra parses. One file, Groovy 3 and later.
 */
class Kestra {
    static final String CONTEXT_FILE = '.kestra-execution-context.json'
    private static final Logger LOGGER = new Logger()
    private static String contextJson

    /** Returns the `::{...}::` line for a map, without sending it. */
    static String format(Map map) {
        Object prepared
        try {
            prepared = prepare(map)
        } catch (StackOverflowError ignored) {
            throw new IllegalArgumentException('This value cannot be sent to Kestra as JSON: it is nested too deep or contains itself.')
        }
        // JsonOutput escapes all non-ASCII, which covers U+0085, U+2028 and U+2029: Java reads them as line terminators.
        '::' + JsonOutput.toJson(prepared) + '::'
    }

    static void outputs(Map outputs) {
        if (!outputs) {
            throw new IllegalArgumentException('Outputs must be a non-empty map, for example Kestra.outputs(rows: 42).')
        }
        send([outputs: outputs])
    }

    static void assets(Map assets) {
        if (!assets) {
            throw new IllegalArgumentException("Assets must be a non-empty map, for example Kestra.assets(outputs: [[id: 'sales.orders', type: 'TABLE']]).")
        }
        send([assets: assets])
    }

    static void counter(String name, Object value, Map tags = [:]) { sendMetric(name, 'counter', value, tags) }

    static void gauge(String name, Object value, Map tags = [:]) { sendMetric(name, 'gauge', value, tags) }

    static void timer(String name, Number seconds, Map tags = [:]) { sendMetric(name, 'timer', seconds, tags) }

    /** Times the closure and returns its result. No metric is sent if it throws. */
    static <T> T timer(String name, Map tags = [:], Closure<T> closure) {
        long start = System.nanoTime()
        T result = closure.call()
        sendMetric(name, 'timer', (System.nanoTime() - start) / 1e9d, tags)
        result
    }

    static Logger getLogger() { LOGGER }

    /**
     * The execution context, read from path, KESTRA_EXECUTION_CONTEXT_FILE or .kestra-execution-context.json (written when
     * the task sets executionContext: true). Without a path, or with an empty one, falls back to the base64 KESTRA_CONTEXT
     * variable. The default context is read once, and each call returns a new map the caller may change.
     *
     * @throws FileNotFoundException when no context is found, and the read error when the file cannot be read
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
                json = new String(Files.readAllBytes(Paths.get(file)), StandardCharsets.UTF_8)
            } catch (NoSuchFileException ignored) {
                // Only a missing file falls back. A directory or an unreadable file is a misconfiguration to report.
                if (isExplicit) {
                    throw new FileNotFoundException("Kestra execution context file '$file' does not exist.")
                }
                if (!encoded) {
                    throw new FileNotFoundException("No Kestra execution context found: '$file' does not exist and the KESTRA_CONTEXT " +
                        'environment variable is not set. The execution context is only available when the script runs inside a Kestra task.')
                }
                try {
                    json = new String(Base64.decoder.decode(encoded), StandardCharsets.UTF_8)
                } catch (IllegalArgumentException e) {
                    throw new IllegalArgumentException('The KESTRA_CONTEXT environment variable is not valid base64.', e)
                }
                source = 'KESTRA_CONTEXT'
            }
        }
        Object context
        try {
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

    static void send(Map map) {
        String line = format(map)
        // One write per line, flushed, so Kestra gets each line when it is written and not at exit.
        synchronized (System.out) {
            System.out.print(line + '\n')
            System.out.flush()
        }
    }

    private static void sendMetric(String name, String type, Object value, Map tags) {
        if (!name) {
            throw new IllegalArgumentException('Metric name must be a non-empty string.')
        }
        if (!isFinite(value)) {
            throw new IllegalArgumentException("Metric '$name' value must be a finite number.")
        }
        Map<String, String> stringTags = [:]
        (tags ?: [:]).each { key, tag ->
            if (tag == null || tag instanceof Map || tag instanceof Collection || tag.getClass().isArray()) {
                throw new IllegalArgumentException("Metric '$name' tag '$key' must be a single value, for example [env: 'prod'].")
            }
            // Kestra reads tags as a map of strings.
            stringTags[key.toString()] = tag.toString()
        }
        send([metrics: [[name: name, type: type, value: value, tags: stringTags]]])
    }

    private static boolean isFinite(Object value) {
        if (value instanceof Double || value instanceof Float) {
            double number = (value as Number).doubleValue()
            return !Double.isNaN(number) && !Double.isInfinite(number)
        }
        value instanceof Number
    }

    // Copies the value as maps with string keys, lists, strings, numbers, booleans and nulls, which JsonOutput writes as is.
    private static Object prepare(Object value) {
        // instanceof, not switch: Groovy's switch also matches a Class value against its own type.
        if (value == null || value instanceof Boolean || value instanceof String) {
            return value
        }
        if (value instanceof Number) {
            if (!isFinite(value)) {
                throw new IllegalArgumentException('This value cannot be sent to Kestra as JSON. Replace NaN and Infinity with null.')
            }
            return value
        }
        if (value instanceof CharSequence || value instanceof Character || value instanceof Enum || value instanceof TemporalAccessor
            || value instanceof UUID || value instanceof URI || value instanceof URL || value instanceof File || value instanceof Path) {
            return value.toString()
        }
        if (value instanceof Date) {
            return ((Date) value).toInstant().toString()
        }
        if (value instanceof Map) {
            Map<String, Object> copy = [:]
            ((Map) value).each { key, item ->
                String text = String.valueOf(key)
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

    /** SLF4J-style logger: `{}` placeholders, and a Throwable as the last argument is appended with its stack trace. */
    static class Logger {
        void trace(Object message, Object... args) { log('TRACE', message, args) }

        void debug(Object message, Object... args) { log('DEBUG', message, args) }

        void info(Object message, Object... args) { log('INFO', message, args) }

        void warn(Object message, Object... args) { log('WARN', message, args) }

        void error(Object message, Object... args) { log('ERROR', message, args) }

        private static void log(String level, Object message, Object[] args) {
            // A single null value reaches varargs as a null array.
            List<Object> values = args == null ? [null] : args as List
            Throwable error = values && values.last() instanceof Throwable ? values.last() as Throwable : null
            String text = String.valueOf(message)
            StringBuilder builder = new StringBuilder()
            int start = 0
            int used = 0
            int index
            while ((index = text.indexOf('{}', start)) >= 0 && used < values.size()) {
                builder.append(text, start, index).append(String.valueOf(values[used++]))
                start = index + 2
            }
            builder.append(text.substring(start))
            if (error != null && used < values.size()) {
                StringWriter trace = new StringWriter()
                error.printStackTrace(new PrintWriter(trace))
                builder.append('\n').append(trace.toString().trim())
            }
            send([logs: [[level: level, message: builder.toString()]]])
        }
    }
}
