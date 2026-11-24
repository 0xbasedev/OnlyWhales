import { handleBrandingGet, handleBrandingPost } from '../server/branding.js'
import { readJson, toResponse } from '../server/http.js'

export async function GET(): Promise<Response> {
  return toResponse(await handleBrandingGet(process.env))
}

export async function POST(request: Request): Promise<Response> {
  return toResponse(await handleBrandingPost(await readJson(request), process.env))
}
