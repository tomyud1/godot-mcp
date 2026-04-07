import { defineConfig } from 'vitest/config';
import { resolve } from 'node:path';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    include: ['src/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'lcov', 'html'],
      exclude: [
        'node_modules/',
        'dist/',
        'coverage/',
        'visualizer/',
        'scripts/',
        '**/*.test.ts',
        '**/*.config.ts',
        '**/*.config.mjs',
        'src/tests/',
      ],
      all: true,
      statements: 70,
      branches: 70,
      functions: 70,
      lines: 70,
    },
  },
  resolve: {
    alias: {
      '@': resolve(__dirname, './src'),
    },
  },
});
