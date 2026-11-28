import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import { apiPlugin } from './server/vite-plugin.js'

export default defineConfig(({ mode }) => {
  // Server-side secrets (TELEGRAM_*, RPC_URL) are read here for the dev API and dev bot only.
  // Only VITE_* values are ever exposed to the browser bundle.
  const env = { ...process.env, ...loadEnv(mode, process.cwd(), '') }
  return {
    plugins: [react(), apiPlugin(env)],
    build: { target: 'es2022', sourcemap: false },
    test: { include: ['server/**/*.test.ts', 'src/**/*.test.ts'], environment: 'node' },
  }
})
