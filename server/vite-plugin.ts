import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Plugin } from 'vite'
import { handleAccess } from './access.js'
import { handleBrandingGet, handleBrandingPost } from './branding.js'
import type { Reply, ServerEnv } from './env.js'
import { startPolling } from './telegram-env.js'

function readBody(req: IncomingMessage, max = 2_000_000): Promise<unknown> {
  return new Promise((resolve) => {
    let size = 0
    const chunks: Buffer[] = []
    req.on('data', (chunk: Buffer) => {
      size += chunk.length
      if (size <= max) chunks.push(chunk)
    })
    req.on('end', () => {
      if (size > max) return resolve(null)
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')))
      } catch {
        resolve(null)
      }
    })
    req.on('error', () => resolve(null))
  })
}

/** Serves /api/* from the same handlers Vercel runs, for `vite dev` and `vite preview`. */
export function apiPlugin(env: ServerEnv): Plugin {
  const middleware = async (req: IncomingMessage, res: ServerResponse, next: () => void) => {
    const path = (req.url || '').split('?')[0]
    let out: Reply | null = null
    if (path === '/api/access' && req.method === 'POST') out = await handleAccess(await readBody(req, 50_000), env)
    else if (path === '/api/branding' && req.method === 'GET') out = await handleBrandingGet(env)
    else if (path === '/api/branding' && req.method === 'POST') out = await handleBrandingPost(await readBody(req), env)
    if (!out) return next()
    res.statusCode = out.status
    res.setHeader('content-type', 'application/json; charset=utf-8')
    res.setHeader('cache-control', 'no-store')
    res.end(JSON.stringify(out.body))
  }
  return {
    name: 'onlywhales-api',
    configureServer: (server) => {
      server.middlewares.use(middleware)
      // Telegram cannot reach localhost, so in dev the bot polls instead of using the webhook.
      if (env.TELEGRAM_BOT_TOKEN && env.TELEGRAM_POLL !== 'off') {
        const stop = startPolling(env, (line) => server.config.logger.info(line))
        server.httpServer?.once('close', stop)
      }
    },
    configurePreviewServer: (server) => void server.middlewares.use(middleware),
  }
}
