import { federation } from '@module-federation/vite';
import tailwindcss from '@tailwindcss/vite';
import solidPlugin from 'vite-plugin-solid';
import { defineConfig } from 'vite';

// One remote per packages/cloud domain. Point a remote elsewhere at build or
// dev time with VITE_<NAME>_REMOTE, e.g. VITE_BUCKET_REMOTE=https://cdn/bucket/remoteEntry.js.
const remotes = {
  bucket: process.env.VITE_BUCKET_REMOTE ?? 'http://localhost:4201/remoteEntry.js',
};

export default defineConfig(({ command }) => ({
  plugins: [
    solidPlugin(),
    tailwindcss(),
    federation({
      name: 'console',
      remotes: Object.fromEntries(
        Object.entries(remotes).map(([name, entry]) => [name, { type: 'module', name, entry }]),
      ),
      shared: {},
      dts: false,
    }),
  ],
  // The host shows the entry URL when a remote fails to load.
  define: {
    'import.meta.env.VITE_BUCKET_REMOTE': JSON.stringify(remotes.bucket),
  },
  server: {
    port: 4200,
    strictPort: true,
    // Remotes fetch /api relative to the page, so the host's proxy serves them all.
    proxy: { '/api': 'http://127.0.0.1:8095' },
  },
  preview: {
    port: 4200,
    strictPort: true,
    proxy: { '/api': 'http://127.0.0.1:8095' },
  },
  build: {
    target: 'esnext',
    outDir: 'dist',
    emptyOutDir: true,
  },
  resolve: {
    conditions: command === 'serve' ? ['development', 'browser'] : ['browser'],
  },
}));
