/// <reference types="vitest" />

import { federation } from '@module-federation/vite';
import tailwindcss from '@tailwindcss/vite';
import solidPlugin from 'vite-plugin-solid';
import { defineConfig } from 'vitest/config';

const port = 4201;

// Remote `bucket`. The host loads http://localhost:4201/remoteEntry.js and
// calls `mount(el, props)` on an exposed module, so nothing is shared at the
// framework level: each side may upgrade (or replace) Solid on its own.
//
// `server.origin` makes the dev server emit absolute asset URLs; without it,
// chunks requested from inside the host would resolve against the host's
// origin. Standalone (`nx serve console-bucket`) proxies /api like the host.
export default defineConfig(({ command }) => ({
  plugins: [
    solidPlugin(),
    tailwindcss(),
    federation({
      name: 'bucket',
      filename: 'remoteEntry.js',
      exposes: {
        './Page': './src/expose/page.ts',
        './Widget': './src/expose/widget.ts',
      },
      shared: {},
      dts: false,
    }),
  ],
  server: {
    port,
    strictPort: true,
    origin: `http://localhost:${port}`,
    proxy: { '/api': 'http://127.0.0.1:8095' },
  },
  preview: {
    port,
    strictPort: true,
    proxy: { '/api': 'http://127.0.0.1:8095' },
  },
  build: {
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
