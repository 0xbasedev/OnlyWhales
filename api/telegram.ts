import { readJson, toResponse } from '../server/http.js'
import { handleTelegramWebhook } from '../server/telegram-env.js'

// Vercel Function (Node.js runtime). Telegram delivers bot updates here. Set it up once with
// `node --env-file=.env.local scripts/telegram-webhook.mjs set https://your-site`.
export async function POST(request: Request): Promise<Response> {
  const secret = request.headers.get('x-telegram-bot-api-secret-token')
  return toResponse(await handleTelegramWebhook(secret, await readJson(request, 200_000), process.env))
}
