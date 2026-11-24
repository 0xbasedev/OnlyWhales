import { handleAccess } from '../server/access.js'
import { readJson, toResponse } from '../server/http.js'

// Vercel Function (Node.js runtime). The invite link comes from TELEGRAM_INVITE_LINK.
export async function POST(request: Request): Promise<Response> {
  return toResponse(await handleAccess(await readJson(request, 50_000), process.env))
}
