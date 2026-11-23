import Kestra from './kestra/kestra';
import type { Logger } from './types';

type LogMethod = (...message: any) => void;

describe('Logger', () => {
  // console.trace would prefix "Trace: " and add a stack, so TRACE goes through console.debug.
  test.each([
    ['TRACE', 'debug'],
    ['DEBUG', 'debug'],
    ['INFO', 'info'],
    ['WARN', 'warn'],
    ['ERROR', 'error'],
  ])('Simple %s', (type: string, consoleMethod: string) => {
    const logSpy = vi.spyOn(global.console, consoleMethod as any);

    const randomNum = Math.random();
    (Kestra.logger()[type.toLowerCase() as keyof Logger] as LogMethod)(randomNum);

    expect(logSpy).toHaveBeenCalledTimes(1);
    expect(logSpy.mock.calls[0]).toEqual([`::{"logs":[{"level":"${type}","message":${randomNum}}]}::`]);

    logSpy.mockRestore();
  });

  test('never fails on a value JSON cannot hold, and logs it as text', () => {
    const logSpy = vi.spyOn(global.console, 'info');
    const loop: any[] = [1];
    loop.push(loop);
    const throwing = {
      toJSON() {
        throw new Error('boom');
      },
    };
    function* endless() {
      while (true) {
        yield 1;
      }
    }

    Kestra.logger().info('text', 10n, loop, throwing, endless());

    const parsed = JSON.parse(logSpy.mock.calls[0][0].replace(/^::|::$/g, ''));
    expect(parsed.logs.map((log: { message: string }) => log.message)).toEqual([
      'text',
      '10n',
      '<ref *1> [ 1, [Circular *1] ]',
      '{ toJSON: [Function: toJSON] }',
      'Object [Generator] {}',
    ]);

    logSpy.mockRestore();
  });

  test('Multiple INFO', () => {
    const logSpy = vi.spyOn(global.console, 'info');

    Kestra.logger().info('test1', 'test2');

    expect(logSpy).toHaveBeenCalled();
    expect(logSpy).toHaveBeenCalledTimes(1);
    expect(logSpy.mock.calls[0][0]).toContain('INFO');
    expect(logSpy.mock.calls[0][0]).toContain('test1');
    expect(logSpy.mock.calls[0][0]).toContain('test2');

    logSpy.mockRestore();
  });
});

describe('Metrics', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('Counter', () => {
    test('should send counter metric', () => {
      const consoleSpy = vi.spyOn(global.console, 'log');

      Kestra.counter('test_counter', 5);

      expect(consoleSpy).toHaveBeenCalledTimes(1);
      const call = consoleSpy.mock.calls[0][0];
      expect(call).toContain('::');

      const jsonContent = call.replace(/^::|::$/g, '');
      const parsed = JSON.parse(jsonContent);
      expect(parsed).toEqual({
        metrics: [
          {
            name: 'test_counter',
            type: 'counter',
            value: 5,
            tags: {},
          },
        ],
      });

      consoleSpy.mockRestore();
    });

    test('should send counter metric with tags', () => {
      const consoleSpy = vi.spyOn(global.console, 'log');
      const tags = { environment: 'test', service: 'api' };

      Kestra.counter('test_counter', 10, tags);

      expect(consoleSpy).toHaveBeenCalledTimes(1);
      const call = consoleSpy.mock.calls[0][0];
      const jsonContent = call.replace(/^::|::$/g, '');
      const parsed = JSON.parse(jsonContent);
      expect(parsed).toEqual({
        metrics: [
          {
            name: 'test_counter',
            type: 'counter',
            value: 10,
            tags: tags,
          },
        ],
      });

      consoleSpy.mockRestore();
    });
  });

  describe('Timer', () => {
    test('should send timer metric with number', () => {
      const consoleSpy = vi.spyOn(global.console, 'log');

      Kestra.timer('test_timer', 1000);

      expect(consoleSpy).toHaveBeenCalledTimes(1);
      const call = consoleSpy.mock.calls[0][0];
      const jsonContent = call.replace(/^::|::$/g, '');
      const parsed = JSON.parse(jsonContent);
      expect(parsed).toEqual({
        metrics: [
          {
            name: 'test_timer',
            type: 'timer',
            value: 1000,
            tags: {},
          },
        ],
      });

      consoleSpy.mockRestore();
    });

    test('should send timer metric with function', async () => {
      const consoleSpy = vi.spyOn(global.console, 'log');

      Kestra.timer('test_timer', (callback) => {
        setTimeout(callback, 10);
      });

      // Wait for the async operation to complete
      await new Promise((resolve) => setTimeout(resolve, 20));

      expect(consoleSpy).toHaveBeenCalledTimes(1);
      const call = consoleSpy.mock.calls[0][0];
      const jsonContent = call.replace(/^::|::$/g, '');
      const parsed = JSON.parse(jsonContent);
      expect(parsed.metrics[0].name).toBe('test_timer');
      expect(parsed.metrics[0].type).toBe('timer');
      expect(typeof parsed.metrics[0].value).toBe('number');
      expect(parsed.metrics[0].value).toBeGreaterThan(0);

      consoleSpy.mockRestore();
    });
  });

  describe('Tags', () => {
    test('sends number, boolean and bigint tag values as strings', () => {
      const consoleSpy = vi.spyOn(global.console, 'log');

      Kestra.counter('tagged', 1, { port: 8080, ratio: 0.5, enabled: true, big: 10n, env: 'prod' });

      expect(consoleSpy.mock.calls[0][0]).toBe(
        '::{"metrics":[{"name":"tagged","type":"counter","value":1,"tags":{"port":"8080","ratio":"0.5","enabled":"true","big":"10","env":"prod"}}]}::'
      );

      consoleSpy.mockRestore();
    });
  });

  test('timer returns what the function returns', () => {
    const consoleSpy = vi.spyOn(global.console, 'log');

    const result = Kestra.timer('returning', (callback) => {
      callback();
      return 42;
    });

    expect(result).toBe(42);
    expect(consoleSpy).toHaveBeenCalledTimes(1);

    consoleSpy.mockRestore();
  });

  test('timer sends no metric when the function throws', () => {
    const consoleSpy = vi.spyOn(global.console, 'log');

    expect(() =>
      Kestra.timer('failing', () => {
        throw new Error('boom');
      })
    ).toThrow('boom');
    expect(consoleSpy).not.toHaveBeenCalled();

    consoleSpy.mockRestore();
  });

  describe('Gauge', () => {
    test('should send gauge metric', () => {
      const consoleSpy = vi.spyOn(global.console, 'log');

      Kestra.gauge('test_gauge', 42.5);

      expect(consoleSpy).toHaveBeenCalledTimes(1);
      const call = consoleSpy.mock.calls[0][0];
      expect(call).toContain('::');

      const jsonContent = call.replace(/^::|::$/g, '');
      const parsed = JSON.parse(jsonContent);
      expect(parsed).toEqual({
        metrics: [
          {
            name: 'test_gauge',
            type: 'gauge',
            value: 42.5,
            tags: {},
          },
        ],
      });

      consoleSpy.mockRestore();
    });

    test('should send gauge metric with tags', () => {
      const consoleSpy = vi.spyOn(global.console, 'log');
      const tags = { instance: 'server-1', region: 'us-east-1' };

      Kestra.gauge('memory_usage', 75.3, tags);

      expect(consoleSpy).toHaveBeenCalledTimes(1);
      const call = consoleSpy.mock.calls[0][0];
      const jsonContent = call.replace(/^::|::$/g, '');
      const parsed = JSON.parse(jsonContent);
      expect(parsed).toEqual({
        metrics: [
          {
            name: 'memory_usage',
            type: 'gauge',
            value: 75.3,
            tags: tags,
          },
        ],
      });

      consoleSpy.mockRestore();
    });

    test('should send gauge metric with integer value', () => {
      const consoleSpy = vi.spyOn(global.console, 'log');

      Kestra.gauge('active_connections', 150);

      expect(consoleSpy).toHaveBeenCalledTimes(1);
      const call = consoleSpy.mock.calls[0][0];
      const jsonContent = call.replace(/^::|::$/g, '');
      const parsed = JSON.parse(jsonContent);
      expect(parsed).toEqual({
        metrics: [
          {
            name: 'active_connections',
            type: 'gauge',
            value: 150,
            tags: {},
          },
        ],
      });

      consoleSpy.mockRestore();
    });

    test('should send gauge metric with zero value', () => {
      const consoleSpy = vi.spyOn(global.console, 'log');

      Kestra.gauge('queue_size', 0);

      expect(consoleSpy).toHaveBeenCalledTimes(1);
      const call = consoleSpy.mock.calls[0][0];
      const jsonContent = call.replace(/^::|::$/g, '');
      const parsed = JSON.parse(jsonContent);
      expect(parsed).toEqual({
        metrics: [
          {
            name: 'queue_size',
            type: 'gauge',
            value: 0,
            tags: {},
          },
        ],
      });

      consoleSpy.mockRestore();
    });

    test('should send gauge metric with negative value', () => {
      const consoleSpy = vi.spyOn(global.console, 'log');

      Kestra.gauge('temperature', -5.2);

      expect(consoleSpy).toHaveBeenCalledTimes(1);
      const call = consoleSpy.mock.calls[0][0];
      const jsonContent = call.replace(/^::|::$/g, '');
      const parsed = JSON.parse(jsonContent);
      expect(parsed).toEqual({
        metrics: [
          {
            name: 'temperature',
            type: 'gauge',
            value: -5.2,
            tags: {},
          },
        ],
      });

      consoleSpy.mockRestore();
    });
  });
});

describe('Assets', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('Simple send', () => {
    test('should send an asset', () => {
      const consoleSpy = vi.spyOn(global.console, 'log');

      Kestra.assets({
        inputs: [
          {
            id: 'input_asset',
            type: 'INPUT_ASSET_TYPE',
          },
        ],
        outputs: [
          {
            id: 'test_asset',
            type: 'VM',
            metadata: {
              owner: 'team_a',
            },
          },
        ],
      });

      expect(consoleSpy).toHaveBeenCalledTimes(1);
      const call = consoleSpy.mock.calls[0][0];
      expect(call).toContain('::');

      const jsonContent = call.replace(/^::|::$/g, '');
      const parsed = JSON.parse(jsonContent);
      expect(parsed).toEqual({
        assets: {
          inputs: [
            {
              id: 'input_asset',
              type: 'INPUT_ASSET_TYPE',
            },
          ],
          outputs: [
            {
              id: 'test_asset',
              type: 'VM',
              metadata: {
                owner: 'team_a',
              },
            },
          ],
        },
      });

      consoleSpy.mockRestore();
    });
  });
});

describe('Outputs', () => {
  test('sends dates as ISO text and keeps NaN as null', () => {
    const consoleSpy = vi.spyOn(global.console, 'log');

    Kestra.outputs({ date: new Date(0), nan: NaN });

    expect(consoleSpy.mock.calls[0][0]).toBe('::{"outputs":{"date":"1970-01-01T00:00:00.000Z","nan":null}}::');

    consoleSpy.mockRestore();
  });

  test('rejects a value that contains itself with a plain sentence', () => {
    const loop: Record<string, unknown> = {};
    loop.self = loop;

    expect(() => Kestra.outputs({ loop })).toThrow(
      new TypeError('This value cannot be sent to Kestra as JSON: it contains itself, pass a copy without the loop.')
    );
  });

  test('rethrows what a toJSON method throws', () => {
    for (const thrown of [null, 'text', { reason: 'no json' }, new RangeError('bad')]) {
      let caught: unknown = 'nothing thrown';
      try {
        Kestra.outputs({
          a: {
            toJSON: () => {
              throw thrown;
            },
          },
        });
      } catch (error) {
        caught = error;
      }
      expect(caught).toBe(thrown);
    }
  });

  test('rejects a value JSON cannot hold with a plain sentence', () => {
    expect(() => Kestra.outputs({ big: 10n })).toThrow(
      new TypeError(
        'This value cannot be sent to Kestra as JSON: pass strings, numbers, booleans, null, arrays, objects or dates.'
      )
    );
  });
});
