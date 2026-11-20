import { inspect } from 'util';

import { KestraFunction, Log, Logger } from '../types';

export default class ConsoleLogger implements Logger {
  constructor(private readonly Kestra: KestraFunction) {}

  // console.trace prefixes "Trace: " and appends a stack, so Kestra would not match the line.
  trace(...message: any): void {
    console.debug(this._line('TRACE', message));
  }

  debug(...message: any): void {
    console.debug(this._line('DEBUG', message));
  }

  info(...message: any): void {
    console.info(this._line('INFO', message));
  }

  warn(...message: any): void {
    console.warn(this._line('WARN', message));
  }

  error(...message: any): void {
    console.error(this._line('ERROR', message));
  }

  _log(level: string, message: string | string[]): { logs: Log[] } {
    return {
      logs: (Array.isArray(message) ? message : [message]).map((value: string) => {
        return {
          level: level,
          message: value,
        };
      }),
    };
  }

  // Values JSON cannot hold (BigInt, a value that contains itself, a throwing toJSON) are logged as inspected text.
  _line(level: string, message: any[]): string {
    try {
      return this.Kestra.format(this._log(level, message));
    } catch {
      return this.Kestra.format(this._log(level, message.map(toText)));
    }
  }
}

function toText(value: unknown): string {
  if (typeof value === 'string') {
    return value;
  }
  try {
    return inspect(value);
  } catch {
    return '[value that cannot be printed]';
  }
}
