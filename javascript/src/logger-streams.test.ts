import Kestra from '../src/index';
import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';

describe('Logger Stream Routing', () => {
  let stdoutSpy: any;
  let stderrSpy: any;

  beforeEach(() => {
    // Spy on the actual console methods that route to different streams
    stdoutSpy = vi.spyOn(process.stdout, 'write').mockImplementation(() => true);
    stderrSpy = vi.spyOn(process.stderr, 'write').mockImplementation(() => true);
  });

  afterEach(() => {
    stdoutSpy?.mockRestore();
    stderrSpy?.mockRestore();
  });

  test('DEBUG and INFO messages use stdout', () => {
    // Mock console methods
    const debugSpy = vi.spyOn(console, 'debug').mockImplementation(() => {});
    const infoSpy = vi.spyOn(console, 'info').mockImplementation(() => {});

    const logger = Kestra.logger();
    logger.debug('Debug message');
    logger.info('Info message');

    // Verify console.debug and console.info were called (these typically go to stdout)
    expect(debugSpy).toHaveBeenCalled();
    expect(infoSpy).toHaveBeenCalled();

    debugSpy.mockRestore();
    infoSpy.mockRestore();
  });

  test('WARN and ERROR messages use stderr', () => {
    // Mock console methods
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});

    const logger = Kestra.logger();
    logger.warn('Warning message');
    logger.error('Error message');

    // Verify console.warn and console.error were called (these typically go to stderr)
    expect(warnSpy).toHaveBeenCalled();
    expect(errorSpy).toHaveBeenCalled();

    warnSpy.mockRestore();
    errorSpy.mockRestore();
  });

  test('TRACE messages use stderr with stack trace', () => {
    // Mock console.trace
    const traceSpy = vi.spyOn(console, 'trace').mockImplementation(() => {});

    const logger = Kestra.logger();
    logger.trace('Trace message');

    // Verify console.trace was called (this goes to stderr and includes stack trace)
    expect(traceSpy).toHaveBeenCalled();

    traceSpy.mockRestore();
  });

  test('Messages are properly formatted with Kestra format', () => {
    const consoleSpy = vi.spyOn(console, 'info').mockImplementation(() => {});

    const logger = Kestra.logger();
    logger.info('Test message');

    expect(consoleSpy).toHaveBeenCalledWith(
      expect.stringMatching(/^::{"logs":\[{"level":"INFO","message":".*Test message.*"}\]}::$/)
    );

    consoleSpy.mockRestore();
  });

  test('Messages include timestamps', () => {
    const consoleSpy = vi.spyOn(console, 'info').mockImplementation(() => {});

    const logger = Kestra.logger();
    logger.info('Test message with timestamp');

    expect(consoleSpy).toHaveBeenCalledWith(
      expect.stringMatching(/^::{"logs":\[{"level":"INFO","message":".*\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z - Test message with timestamp.*"}\]}::$/)
    );

    consoleSpy.mockRestore();
  });
});