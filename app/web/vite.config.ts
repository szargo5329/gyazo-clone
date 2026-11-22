/// <reference types="vitest/config" />
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// Dev server proxies API routes to the local FastAPI (docker compose or uvicorn on :8000).
// In production the API serves the built files itself (D-002), so there is no proxy.
const api = 'http://localhost:8000'

export default defineConfig({
  plugins: [react()],
  server: {
    proxy: { '/upload': api, '/i': api, '/api': api },
  },
  test: {
    environment: 'node',
  },
})
