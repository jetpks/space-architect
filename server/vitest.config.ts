import path from 'path'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vitest/config'

// A standalone config (no vite-plugin-ruby) so the suite runs without a Ruby/Vite
// dev server. The frontend's pure logic — message pairing, label derivation — is
// node-environment testable; component tests run under jsdom.
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { '@': path.resolve(__dirname, './app/frontend') },
  },
  test: {
    environment: 'jsdom',
    include: ['app/frontend/**/*.test.ts', 'app/frontend/**/*.test.tsx'],
    setupFiles: ['./test/frontend-setup.ts'],
  },
})
