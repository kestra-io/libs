import Kestra from './kestra/kestra';
import type { Logger } from './types';

type LogMethod = (...message: any) => void;

describe('Logger', () => {
  test.each([['TRACE'], ['DEBUG'], ['INFO'], ['WARN'], ['ERROR']])('Simple %s', (type: string) => {
    const logSpy = vi.spyOn(global.console, type.toLowerCase() as any);

    const randomNum = Math.random();
    (Kestra.logger()[type.toLowerCase() as keyof Logger] as LogMethod)(randomNum);

    expect(logSpy).toHaveBeenCalled();
    expect(logSpy).toHaveBeenCalledTimes(1);
    expect(logSpy.mock.calls[0][0]).toContain(type);
    expect(logSpy.mock.calls[0][0]).toContain(randomNum.toString());

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
