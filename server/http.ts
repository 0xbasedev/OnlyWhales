import type { Reply } from './env.js'

const HEADERS = { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' }

export function toResponse({ status, body }: Reply): Response {
  return new Response(JSON.stringify(body), { status, headers: HEADERS })
}

/** Parse a JSON request body with a hard size cap. Returns null if it is not usable JSON. */
export async function readJson(request: Request, maxBytes = 2_000_000): Promise<unknown> {
  const text = await request.text()
  if (text.length > maxBytes) return null
  try {
    return JSON.parse(text)
  } catch {
    return null
  }
}
