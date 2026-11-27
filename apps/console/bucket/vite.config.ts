/// <reference types="vitest" />

import tailwindcss from '@tailwindcss/vite';
import solidPlugin from 'vite-plugin-solid';
import { defineConfig } from 'vitest/config';

const port = 4201;
const host = 'http://localhost:4240';

// single-spa micro frontend `@shluviza/bucket`. In dev the workspace console
// host (:4240) imports http://localhost:4201/src/mfe.tsx; `server.origin`
// makes the dev server emit absolute asset URLs so chunks resolve against this
// server, not the host. Standalone (`nx serve console-bucket`) proxies /api.
//
// `vite build` builds the standalone SPA into dist/; `vite build --mode mfe`
// builds the module into dist/mfe/entry.js with hashed chunks in
// dist/mfe/assets/.
export default defineConfig(({ command, mode }) => ({
  plugins: [solidPlugin(), tailwindcss()],
  server: {
    port,
    strictPort: true,
    origin: `http://localhost:${port}`,
    cors: { origin: host },
    proxy: { '/api': 'http://127.0.0.1:8095' },
  },
  preview: {
    port,
    strictPort: true,
    proxy: { '/api': 'http://127.0.0.1:8095' },
  },
  build:
    mode === 'mfe'
      ? {
          target: 'esnext',
          outDir: 'dist/mfe',
          emptyOutDir: true,
          lib: { entry: 'src/mfe.tsx', formats: ['es'], fileName: () => 'entry.js' },
          rollupOptions: { output: { chunkFileNames: 'assets/[name]-[hash].js' } },
        }
      : {
          target: 'esnext',
          outDir: 'dist',
          emptyOutDir: true,
        },
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts'],
    watch: false,
  },
  resolve: {
    conditions: command === 'serve' ? ['development', 'browser'] : ['browser'],
  },
}));
