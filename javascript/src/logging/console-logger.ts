import { KestraFunction, Log, Logger } from '../types';

export default class ConsoleLogger implements Logger {
  constructor(private readonly Kestra: KestraFunction) {}

  trace(...message: any): void {
    const formattedMessage = this._formatMessage(message);
    const logObject = this._log('TRACE', formattedMessage);
    const output = this.Kestra.format(logObject);

    // Use console.trace for trace level
    console.trace(output);
  }

  debug(...message: any): void {
    const formattedMessage = this._formatMessage(message);
    const logObject = this._log('DEBUG', formattedMessage);
    const output = this.Kestra.format(logObject);

    // Use console.debug for debug but also ensure it goes to stdout
    console.debug(output);
  }

  info(...message: any): void {
    const formattedMessage = this._formatMessage(message);
    const logObject = this._log('INFO', formattedMessage);
    const output = this.Kestra.format(logObject);

    // Use console.info for info but also ensure it goes to stdout
    console.info(output);
  }

  warn(...message: any): void {
    const formattedMessage = this._formatMessage(message);
    const logObject = this._log('WARN', formattedMessage);
    const output = this.Kestra.format(logObject);

    // Use console.warn for warnings - this typically goes to stderr
    console.warn(output);
  }

  error(...message: any): void {
    const formattedMessage = this._formatMessage(message);
    const logObject = this._log('ERROR', formattedMessage);
    const output = this.Kestra.format(logObject);

    // Use console.error for errors - this typically goes to stderr
    console.error(output);
  }

  private _formatMessage(message: any[]): string {
    const now = new Date();
    const timestamp = now.toISOString();
    const messageText = message.map((msg) => (typeof msg === 'string' ? msg : JSON.stringify(msg))).join(' ');

    return `${timestamp} - ${messageText}`;
  }

  _log(level: string, message: string): { logs: Log[] } {
    return {
      logs: [
        {
          level: level,
          message: message,
        },
      ],
    };
  }
}
