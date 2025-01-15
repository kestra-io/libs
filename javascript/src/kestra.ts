import { Log } from './types';

export function Kestra() {}

Kestra.format = (map: Record<string, any>) => {
  return '::' + JSON.stringify(map) + '::';
};

Kestra._send = (map: Record<string, any>) => {
  console.log(Kestra.format(map));
};

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

Kestra.counter = (name: string, value: any, tags: any) => {
  Kestra._metrics(name, 'counter', value, tags);
};

Kestra.timer = (name: string, duration: number | ((func: () => void) => void), tags: any) => {
  if (typeof duration === 'function') {
    const start = new Date();
    duration(() => {
      Kestra._metrics(name, 'timer', (new Date().getTime() - start.getTime()) / 1000, tags);
    });
  } else {
    Kestra._metrics(name, 'timer', duration, tags);
  }
};

Kestra.logger = () => {
  return new Logger();
};

export class Logger {
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

  trace(...message: any): void {
    console.trace(Kestra.format(this._log('TRACE', message)));
  }

  debug(...message: any): void {
    console.debug(Kestra.format(this._log('DEBUG', message)));
  }

  info(...message: any): void {
    console.info(Kestra.format(this._log('INFO', message)));
  }

  warn(...message: any): void {
    console.warn(Kestra.format(this._log('WARN', message)));
  }

  error(...message: any): void {
    console.error(Kestra.format(this._log('ERROR', message)));
  }
}
