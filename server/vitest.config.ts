import path from 'path'
import { defineConfig } from 'vitest/config'

// A standalone config (no vite-plugin-ruby) so the suite runs without a Ruby/Vite
// dev server. The frontend's pure logic — message pairing, label derivation — is
// node-environment testable; component tests can add jsdom here later if needed.
export default defineConfig({
  resolve: {
    alias: { '@': path.resolve(__dirname, './app/frontend') },
  },
  test: {
    environment: 'node',
    include: ['app/frontend/**/*.test.ts'],
  },
})
