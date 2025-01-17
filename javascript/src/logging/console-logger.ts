import { KestraFunction, Log, Logger } from '../types';

export default class ConsoleLogger implements Logger {
  constructor(private readonly Kestra: KestraFunction) {}

  trace(...message: any): void {
    console.trace(this.Kestra.format(this._log('TRACE', message)));
  }

  debug(...message: any): void {
    console.debug(this.Kestra.format(this._log('DEBUG', message)));
  }

  info(...message: any): void {
    console.info(this.Kestra.format(this._log('INFO', message)));
  }

  warn(...message: any): void {
    console.warn(this.Kestra.format(this._log('WARN', message)));
  }

  error(...message: any): void {
    console.error(this.Kestra.format(this._log('ERROR', message)));
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
}
