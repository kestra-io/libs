import { readFileSync } from 'fs';

import ConsoleLogger from '../logging/console-logger';
import { KestraFunction, Logger } from '../types';

const Kestra: KestraFunction = function () {} as KestraFunction;

const CONTEXT_FILE = '.kestra-execution-context.json';
let contextJson: string | undefined;

/**
 * Formats a map object as a string by converting it to a JSON string
 * and surrounding it with "::" delimiters.
 *
 * @param map - The map object to format.
 * @returns The formatted string.
 */
Kestra.format = (map: Record<string, any>): string => {
  let json: string;
  try {
    json = JSON.stringify(map);
  } catch (error) {
    // JSON.stringify throws a TypeError. Anything else came from a toJSON method and is rethrown as is.
    if (!(error instanceof TypeError)) {
      throw error;
    }
    const isCircular = /circular/i.test(error.message);
    throw new TypeError(
      isCircular
        ? 'This value cannot be sent to Kestra as JSON: it contains itself, pass a copy without the loop.'
        : 'This value cannot be sent to Kestra as JSON: pass strings, numbers, booleans, null, arrays, objects or dates.',
      { cause: error }
    );
  }
  const text: string = json.replace(/[\u0085\u2028\u2029]/g, (match: string) => {
    return '\\u' + match.charCodeAt(0).toString(16).padStart(4, '0');
  });
  return '::' + text + '::';
};

/**
 * Sends a log message to the standard output.
 *
 * @param map - The map object containing the log data.
 */
Kestra._send = (map: Record<string, any>) => {
  console.log(Kestra.format(map));
};

/**
 * Sends a metric to the standard output.
 *
 * @param name - The name of the metric.
 * @param type - The type of the metric.
 * @param value - The value of the metric.
 * @param tags - The tags of the metric.
 */
Kestra._metrics = (name: string, type: string, value: any, tags: any) => {
  Kestra._send({
    metrics: [
      {
        name: name,
        type: type,
        value: value,
        tags: stringTags(tags),
      },
    ],
  });
};

// Kestra drops a metric whose tag values are not strings.
function stringTags(tags: any): any {
  if (tags === null || typeof tags !== 'object' || Array.isArray(tags)) {
    return tags || {};
  }
  return Object.fromEntries(
    Object.entries(tags).map(([key, value]) => [
      key,
      ['number', 'boolean', 'bigint'].includes(typeof value) ? String(value) : value,
    ])
  );
}

Kestra.outputs = (outputs: any) => {
  Kestra._send({
    outputs: outputs,
  });
};

Kestra.assets = (assets: any) => {
  Kestra._send({
    assets,
  });
};

/**
 * Sends a counter metric to the standard output.
 *
 * @param name - The name of the metric.
 * @param value - The value of the metric.
 * @param tags - The tags of the metric.
 */
Kestra.counter = (name: string, value: any, tags: any) => {
  Kestra._metrics(name, 'counter', value, tags);
};

/**
 * Measures the duration of a timer and sends the metric.
 *
 * @param name - The name of the timer.
 * @param duration - The duration in seconds, or a function that receives a callback to call when the timed work ends.
 * @param tags - Additional metadata tags for the timer.
 * @returns What the function returns, or undefined when a duration is given.
 */
Kestra.timer = <T>(name: string, duration: number | ((callback: () => void) => T), tags?: any): T | undefined => {
  if (typeof duration === 'function') {
    const start = new Date();
    return duration(() => {
      const elapsedTime = (new Date().getTime() - start.getTime()) / 1000;
      Kestra._metrics(name, 'timer', elapsedTime, tags);
    });
  }
  Kestra._metrics(name, 'timer', duration, tags);
  return undefined;
};

/**
 * Sends a gauge metric to the standard output.
 *
 * @param name - The name of the gauge.
 * @param value - The value of the gauge.
 * @param tags - The tags of the gauge.
 */
Kestra.gauge = (name: string, value: number, tags: any) => {
  Kestra._metrics(name, 'gauge', value, tags);
};

/**
 * Provides an instance of the Logger.
 *
 * @returns A Logger instance.
 */
Kestra.logger = (): Logger => {
  return new ConsoleLogger(Kestra);
};

/**
 * Returns the execution context, read from `path`, `KESTRA_EXECUTION_CONTEXT_FILE` or `.kestra-execution-context.json`
 * (written when the task sets `executionContext: true`). Without `path`, falls back to the base64 `KESTRA_CONTEXT` variable.
 * The default context is read once, and each call returns a new object the caller may change.
 *
 * @param path - The context file to read instead of the default lookup. An empty path means the default lookup.
 * @returns The execution context.
 * @throws An error with code `ENOENT` when no context is found, the read error when the file cannot be read, and a
 *   `SyntaxError` when `KESTRA_CONTEXT` is not base64 or the context is not a JSON object.
 */
Kestra.context = (path?: string | null): Record<string, any> => {
  // An empty path means the default lookup, as in the other libraries.
  const isExplicit = Boolean(path);
  if (!isExplicit && contextJson !== undefined) {
    return JSON.parse(contextJson);
  }

  const file = path || process.env.KESTRA_EXECUTION_CONTEXT_FILE || CONTEXT_FILE;
  const encoded = (process.env.KESTRA_CONTEXT ?? '').replace(/\s/g, '');
  let json: string;
  let source = file;
  try {
    json = readFileSync(file, 'utf8');
  } catch (error) {
    // Only a missing file falls back. A directory or an unreadable file is a misconfiguration to report.
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
      throw error;
    }
    if (isExplicit) {
      throw Object.assign(new Error(`Kestra execution context file '${file}' does not exist.`), { code: 'ENOENT' });
    }
    if (encoded === '') {
      throw Object.assign(
        new Error(
          `No Kestra execution context found: '${file}' does not exist and the KESTRA_CONTEXT environment variable is not set. ` +
            'The execution context is only available when the script runs inside a Kestra task.'
        ),
        { code: 'ENOENT' }
      );
    }
    // Buffer skips characters that are not base64 instead of failing.
    if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) {
      throw new SyntaxError('The KESTRA_CONTEXT environment variable is not valid base64.');
    }
    json = Buffer.from(encoded, 'base64').toString('utf8');
    source = 'KESTRA_CONTEXT';
  }

  let context: unknown;
  try {
    context = JSON.parse(json);
  } catch (error) {
    throw new SyntaxError(`The execution context in ${source} is not valid JSON: ${(error as Error).message}`, {
      cause: error,
    });
  }
  if (context === null || typeof context !== 'object' || Array.isArray(context)) {
    throw new SyntaxError(`The execution context in ${source} is not a JSON object.`);
  }
  if (!isExplicit) {
    contextJson = json;
  }
  return context as Record<string, any>;
};

export default Kestra;
