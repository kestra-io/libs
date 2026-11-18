import { mkdtempSync, rmSync, unlinkSync, writeFileSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

import type { KestraFunction } from '../types';

const CONTEXT = {
  labels: { env: 'prod', team: 'café' },
  inputs: { my_input: 'a\nmultiline "value"', files: [{ name: 'first' }, 2] },
  vars: { my_var: 42 },
};

const startDir = process.cwd();
const dirs: string[] = [];

function emptyDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'kestra-ctx-'));
  dirs.push(dir);
  return dir;
}

function contextDir(json: string): string {
  const dir = emptyDir();
  writeFileSync(join(dir, '.kestra-execution-context.json'), json);
  return dir;
}

// A fresh module per test, since the default context is cached.
async function kestra(): Promise<KestraFunction> {
  vi.resetModules();
  return (await import('./kestra')).default;
}

function errorOf(call: () => unknown): Error & { code?: string } {
  try {
    call();
  } catch (error) {
    return error as Error & { code?: string };
  }
  throw new Error('expected an error');
}

beforeEach(() => {
  delete process.env.KESTRA_CONTEXT;
  delete process.env.KESTRA_EXECUTION_CONTEXT_FILE;
});

afterEach(() => {
  process.chdir(startDir);
});

afterAll(() => {
  dirs.forEach((dir) => rmSync(dir, { recursive: true, force: true }));
});

describe('Context', () => {
  test('is read from the default file once, as UTF-8, and each call returns a new object', async () => {
    process.chdir(contextDir(JSON.stringify(CONTEXT)));
    const Kestra = await kestra();

    expect(Kestra.context()).toEqual(CONTEXT);
    unlinkSync('.kestra-execution-context.json');
    Kestra.context().labels = {};
    expect(Kestra.context().labels.team).toBe('café');
  });

  test('a file wins over KESTRA_CONTEXT, and KESTRA_EXECUTION_CONTEXT_FILE over the default file', async () => {
    process.chdir(contextDir('{"execution":{"id":"default"}}'));
    process.env.KESTRA_CONTEXT = Buffer.from('{"execution":{"id":"from-env"}}').toString('base64');
    expect((await kestra()).context().execution.id).toBe('default');

    process.env.KESTRA_EXECUTION_CONTEXT_FILE = join(
      contextDir('{"execution":{"id":"env-file"}}'),
      '.kestra-execution-context.json'
    );
    expect((await kestra()).context().execution.id).toBe('env-file');
  });

  test('an empty KESTRA_EXECUTION_CONTEXT_FILE means the default file', async () => {
    process.chdir(contextDir('{"execution":{"id":"default"}}'));
    process.env.KESTRA_EXECUTION_CONTEXT_FILE = '';

    expect((await kestra()).context().execution.id).toBe('default');
  });

  test('falls back to the base64 KESTRA_CONTEXT variable without a file', async () => {
    process.chdir(emptyDir());
    process.env.KESTRA_CONTEXT = Buffer.from(JSON.stringify(CONTEXT)).toString('base64');

    expect((await kestra()).context()).toEqual(CONTEXT);
  });

  test('an explicit path is read as given and never cached as the default context', async () => {
    process.chdir(contextDir('{"execution":{"id":"default"}}'));
    const explicit = join(contextDir('{"execution":{"id":"explicit"}}'), '.kestra-execution-context.json');
    const Kestra = await kestra();

    expect(
      [Kestra.context(explicit), Kestra.context(), Kestra.context(explicit)].map((context) => context.execution.id)
    ).toEqual(['explicit', 'default', 'explicit']);
  });

  test('an explicit path never falls back to KESTRA_CONTEXT', async () => {
    process.env.KESTRA_CONTEXT = Buffer.from('{"a":1}').toString('base64');
    const Kestra = await kestra();
    const error = errorOf(() => Kestra.context('typo.json'));

    expect(error.code).toBe('ENOENT');
    expect(error.message).toBe("Kestra execution context file 'typo.json' does not exist.");
  });

  test.each([
    ['a JSON array', '[1, 2]'],
    ['invalid JSON', '{oops'],
    ['null', 'null'],
  ])('a file holding %s names the file', async (_, json) => {
    process.chdir(contextDir(json));
    const Kestra = await kestra();

    expect(() => Kestra.context()).toThrow(
      new SyntaxError('The execution context in .kestra-execution-context.json is not a JSON object.')
    );
  });

  test('a KESTRA_CONTEXT that is not a JSON object names the variable', async () => {
    process.chdir(emptyDir());
    process.env.KESTRA_CONTEXT = Buffer.from('[]').toString('base64');
    const Kestra = await kestra();

    expect(() => Kestra.context()).toThrow(
      new SyntaxError('The execution context in KESTRA_CONTEXT is not a JSON object.')
    );
  });

  test('fails clearly outside Kestra', async () => {
    process.chdir(emptyDir());
    const Kestra = await kestra();
    const error = errorOf(() => Kestra.context());

    expect(error.code).toBe('ENOENT');
    expect(error.message).toContain(
      'The execution context is only available when the script runs inside a Kestra task.'
    );
  });
});
