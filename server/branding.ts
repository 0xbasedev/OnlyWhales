import { createHash } from 'node:crypto'
import { getAddress, isAddress, isHex, verifyMessage, type Address, type Hex } from 'viem'
import { brandingMessage, timestampProblem } from '../shared/messages.js'
import { LIMITS, sanitizeBranding } from '../shared/branding.js'
import { chainContext, configuredOperator, reply, type ChainContext, type Reply, type ServerEnv } from './env.js'
import { storeFromEnv, type Store } from './storage.js'

const operatorAbi = [
  { type: 'function', name: 'operator', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
] as const

export type BrandingDeps = { ctx?: ChainContext; store?: Store; now?: () => number }

/** GET /api/branding: the saved overrides, or null when the defaults are in use. */
export async function handleBrandingGet(env: ServerEnv, deps: BrandingDeps = {}): Promise<Reply> {
  const store = deps.store ?? storeFromEnv(env)
  try {
    const raw = await store.get()
    return reply(200, { branding: raw ? JSON.parse(raw) : null })
  } catch {
    return reply(200, { branding: null })
  }
}

/**
 * POST /api/branding  { wallet, timestamp, signature, payload }
 *
 * `payload` is the branding JSON as a string. The operator signs its SHA-256, so what gets saved
 * is exactly what was signed. The signer must be the vault's immutable operator (read on-chain;
 * before deployment, the operator named in config/prelaunch.json). Takes effect immediately:
 * this is site copy, not a contract setting.
 */
export async function handleBrandingPost(body: unknown, env: ServerEnv, deps: BrandingDeps = {}): Promise<Reply> {
  const ctx = deps.ctx ?? chainContext(env)
  const { wallet, timestamp, signature, payload } = (body ?? {}) as Record<string, unknown>

  if (typeof wallet !== 'string' || !isAddress(wallet)) return reply(400, { error: 'Bad wallet address.' })
  if (typeof signature !== 'string' || !isHex(signature) || signature.length > 20_000) {
    return reply(400, { error: 'Bad signature.' })
  }
  if (typeof payload !== 'string' || payload.length > LIMITS.payload) {
    return reply(413, { error: 'Branding payload is missing or too large.' })
  }
  const now = Math.floor((deps.now ?? Date.now)() / 1000)
  const stale = timestampProblem(timestamp, now)
  if (stale) return reply(401, { error: stale })

  let operator: Address
  if (ctx.deployed && ctx.client) {
    try {
      operator = await ctx.client.readContract({ address: ctx.vault, abi: operatorAbi, functionName: 'operator' })
    } catch {
      return reply(502, { error: 'Could not reach the chain. Try again.' })
    }
  } else {
    operator = configuredOperator
  }
  const address = getAddress(wallet) as Address
  if (!isAddress(operator) || BigInt(operator) === 0n || getAddress(operator) !== address) {
    return reply(403, { error: 'Not the operator wallet.' })
  }

  const digest = createHash('sha256').update(payload).digest('hex')
  const message = brandingMessage({ wallet: address, vault: ctx.vault, chainId: ctx.chainId, timestamp: timestamp as number, digest })
  let signed = false
  try {
    signed = ctx.client
      ? await ctx.client.verifyMessage({ address, message, signature: signature as Hex })
      : await verifyMessage({ address, message, signature: signature as Hex })
  } catch {
    signed = false
  }
  if (!signed) return reply(401, { error: 'Signature does not match the operator wallet.' })

  let parsed: unknown
  try {
    parsed = JSON.parse(payload)
  } catch {
    return reply(400, { error: 'Payload is not valid JSON.' })
  }
  const clean = sanitizeBranding(parsed)
  if (!clean.ok) return reply(400, { error: clean.error })

  const store = deps.store ?? storeFromEnv(env)
  try {
    await store.set(JSON.stringify(clean.value))
  } catch {
    return reply(500, { error: 'Could not save. Storage is not writable on this host.' })
  }
  return reply(200, { branding: clean.value })
}
