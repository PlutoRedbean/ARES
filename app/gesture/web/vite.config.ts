import { defineConfig } from 'vitest/config';

export default defineConfig({
  server: {
    host: '127.0.0.1',
    port: 5173,
    strictPort: false,
    watch: {
      usePolling: true,
      interval: 300,
      ignored: ['**/shots/**', '**/dist/**', '**/*.tmpdir/**', '**/.chrome-profile/**'],
    },
  },
  preview: {
    host: '127.0.0.1',
    port: 4173,
    strictPort: false,
  },
  build: {
    target: 'es2022',
    sourcemap: false,
    chunkSizeWarningLimit: 1200,
  },
  test: {
    environment: 'node',
    include: ['tests/**/*.test.ts'],
  },
});
