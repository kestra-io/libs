import fs from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import tsPlugin from '@rollup/plugin-typescript';
import terserPlugin from '@rollup/plugin-terser';
import dtsPlugin from 'rollup-plugin-dts';

const directoryName = dirname(fileURLToPath(import.meta.url));
const testPatterns = ['**/*.spec.ts', '**/*.test.ts'];

export default () => {
  clearDist();

  const entrypoints = fs
    .readdirSync(join(directoryName, 'src'))
    .filter((filename) => filename.endsWith('index.ts'))
    .map((filename) => `./src/${filename}`);

  return [
    createLibBuildConfig({
      format: 'esm',
      extension: 'mjs',
      entrypoints,
      outDir: 'dist',
      minify: true,
    }),
    createLibBuildConfig({
      format: 'cjs',
      extension: 'js',
      entrypoints,
      outDir: 'dist',
      minify: true,
    }),
    createTypeDeclarationConfig({
      format: 'esm',
      entrypoints,
      outDir: 'dist',
      dtsExtension: 'd.mts',
    }),
    createTypeDeclarationConfig({
      format: 'cjs',
      entrypoints,
      outDir: 'dist',
      dtsExtension: 'd.ts',
    }),
  ];
};

function createLibBuildConfig({ format, extension, entrypoints, outDir, minify }) {
  return {
    input: mapInputFiles(entrypoints),
    plugins: [
      tsPlugin({
        exclude: [...testPatterns],
        compilerOptions: {
          sourceMap: false,
          removeComments: true,
          noEmit: true,
          emitDeclarationOnly: true,
        },
      }),
      minify &&
        terserPlugin({
          ecma: 2020,
        }),
    ],
    output: {
      format,
      dir: outDir,
      preserveModules: format === 'esm',
      ...getFilenames(extension),
    },
  };
}

function createTypeDeclarationConfig({ format, entrypoints, outDir, dtsExtension }) {
  return {
    input: mapInputFiles(entrypoints),
    plugins: [dtsPlugin()],
    output: {
      format,
      dir: outDir,
      generatedCode: 'es2015',
      ...getFilenames(dtsExtension),
      preserveModules: true,
      preserveModulesRoot: 'src',
    },
  };
}

function mapInputFiles(srcFilepaths) {
  const entries = srcFilepaths.map((filepath) => [
    // Omits the ./src/ and file extensions from the filepath so it's left with the filename e.g. "index"
    filepath.replace(/^(\.\/)?src\//, '').replace(/\.[cm]?(js|ts)$/, ''),
    // constructs the full absolute path to the project e.g. /path/to/project/libs/javascript/src/index.ts
    join(directoryName, filepath),
  ]);

  return Object.fromEntries(entries);
}

function getFilenames(extension) {
  return {
    entryFileNames: `[name].${extension}`,
    chunkFileNames: `_chunk/[name]-[hash].${extension}`,
  };
}

function clearDist() {
  const distPath = join(directoryName, 'dist');
  if (fs.existsSync(distPath)) {
    fs.rmSync(distPath, { recursive: true, force: true });
  }
}
