import fs from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import jsonPlugin from '@rollup/plugin-json';
import tsPlugin from '@rollup/plugin-typescript';
import cjsPlugin from '@rollup/plugin-commonjs';
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
      sourceMap: false,
    }),
    createLibBuildConfig({
      format: 'cjs',
      extension: 'js',
      entrypoints,
      outDir: 'dist',
      minify: true,
      sourceMap: false,
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

function createLibBuildConfig({ format, extension, entrypoints, outDir, minify, sourceMap }) {
  const isEsm = format === 'esm';

  return {
    plugins: [
      jsonPlugin(),
      tsPlugin({
        exclude: [...testPatterns],
        compilerOptions: {
          sourceMap,
          inlineSources: sourceMap,
          removeComments: !sourceMap,
          declaration: false,
        },
      }),
      !isEsm && cjsPlugin(),
      minify &&
        terserPlugin({
          ecma: 2020,
        }),
      transformDefaultExportsPlugin(outDir),
    ].filter(Boolean),
    input: mapInputFiles(entrypoints),
    output: {
      format,
      dir: outDir,
      preserveModules: isEsm,
      sourcemap: sourceMap,
      exports: 'default',
      ...getFilenames(extension),
    },
  };
}

function createTypeDeclarationConfig({ format, entrypoints, outDir, dtsExtension }) {
  const isEsm = format === 'esm';

  return {
    plugins: [
      jsonPlugin(),
      dtsPlugin({
        compilerOptions: {
          sourceMap: true,
          inlineSources: true,
          removeComments: false,
          declaration: true,
        },
      }),
      transformDefaultExportsPlugin(outDir),
    ],
    input: mapInputFiles(entrypoints),
    output: {
      format,
      dir: outDir,
      preserveModules: isEsm,
      preserveModulesRoot: 'src',
      generatedCode: 'es2015',
      exports: 'default',
      ...getFilenames(dtsExtension),
    },
  };
}

function clearDist() {
  const distPath = join(directoryName, 'dist');
  if (fs.existsSync(distPath)) {
    fs.rmSync(distPath, { recursive: true, force: true });
  }
}

function transformDefaultExportsPlugin(outDir) {
  return {
    name: 'fix-default-exports',
    writeBundle: (options, bundle) => {
      for (const [fileName, file] of Object.entries(bundle)) {
        if (file.type !== 'chunk') {
          continue;
        }

        const filePath = join(outDir, fileName);
        const code = fs.readFileSync(filePath, 'utf-8');

        let transformedCode = '';

        if (fileName.endsWith('.mjs') || fileName.endsWith('.js')) {
          transformedCode = code.replace(/export\{(\w+) as default\};/g, 'export default $1;');
        } else if (fileName.endsWith('.d.mts')) {
          transformedCode = code.replace(/export \{ (\w+) as default \};/g, 'export default $1;');
        } else if (fileName.endsWith('.d.ts')) {
          transformedCode = code.replace(/export \{ (\w+) as default \};/g, 'export = $1;');
        }

        fs.writeFileSync(filePath, transformedCode, 'utf-8');
      }
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
