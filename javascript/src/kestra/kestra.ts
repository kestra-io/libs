import { existsSync, readFileSync, statSync } from 'fs';

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
  const text: string = JSON.stringify(map).replace(/[\u0085\u2028\u2029]/g, (match: string) => {
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
        tags: tags || {},
      },
    ],
  });
};

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
 * @param duration - The duration in seconds or a function to measure the duration.
 * @param tags - Additional metadata tags for the timer.
 */
Kestra.timer = (name: string, duration: number | ((func: () => void) => void), tags: any) => {
  // Check if duration is a function to execute for measuring time
  if (typeof duration === 'function') {
    const start = new Date();
    // Execute the function and calculate elapsed time
    duration(() => {
      const elapsedTime = (new Date().getTime() - start.getTime()) / 1000;
      Kestra._metrics(name, 'timer', elapsedTime, tags);
    });
  } else {
    // Directly use the provided duration value
    Kestra._metrics(name, 'timer', duration, tags);
  }
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
 * @param path - The context file to read instead of the default lookup.
 * @returns The execution context.
 * @throws An error with code `ENOENT` when no context is found, and a `SyntaxError` when it is not a JSON object.
 */
Kestra.context = (path?: string): Record<string, any> => {
  if (path === undefined && contextJson !== undefined) {
    return JSON.parse(contextJson);
  }

  const file = path ?? (process.env.KESTRA_EXECUTION_CONTEXT_FILE || CONTEXT_FILE);
  const encoded = process.env.KESTRA_CONTEXT ?? '';
  let json: string;
  let source: string;
  if (existsSync(file) && statSync(file).isFile()) {
    json = readFileSync(file, 'utf8');
    source = file;
  } else if (path === undefined && encoded !== '') {
    json = Buffer.from(encoded, 'base64').toString('utf8');
    source = 'KESTRA_CONTEXT';
  } else if (path !== undefined) {
    throw Object.assign(new Error(`Kestra execution context file '${file}' does not exist.`), { code: 'ENOENT' });
  } else {
    throw Object.assign(
      new Error(
        `No Kestra execution context found: '${file}' does not exist and the KESTRA_CONTEXT environment variable is not set. ` +
          'The execution context is only available when the script runs inside a Kestra task.'
      ),
      { code: 'ENOENT' }
    );
  }

  let context: unknown;
  try {
    context = JSON.parse(json);
  } catch {
    context = undefined;
  }
  if (context === null || typeof context !== 'object' || Array.isArray(context)) {
    throw new SyntaxError(`The execution context in ${source} is not a JSON object.`);
  }
  if (path === undefined) {
    contextJson = json;
  }
  return context as Record<string, any>;
};

export default Kestra;
