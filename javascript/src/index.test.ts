import { Kestra, Logger } from './kestra';

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
