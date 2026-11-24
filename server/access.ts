import { getAddress, isAddress, isHex, type Address, type Hex } from 'viem'
import { accessMessage, timestampProblem } from '../shared/messages.js'
import { chainContext, reply, type ChainContext, type Reply, type ServerEnv } from './env.js'

const hasAccessAbi = [
  {
    type: 'function',
    name: 'hasAccess',
    stateMutability: 'view',
    inputs: [{ name: 'wallet', type: 'address' }],
    outputs: [{ type: 'bool' }],
  },
] as const

export type AccessDeps = { ctx?: ChainContext; now?: () => number }

/**
 * POST /api/access  { wallet, timestamp, signature }
 *
 * 1. The timestamp must be at most five minutes old.
 * 2. The signature must be the wallet's signature over the exact gate message (EOA or ERC-1271).
 * 3. The vault must say the wallet holds the pass and an open position, right now, on-chain.
 * Only then is the invite link read from the server environment and returned. The link is never
 * in the client bundle and never appears in any error path.
 */
export async function handleAccess(body: unknown, env: ServerEnv, deps: AccessDeps = {}): Promise<Reply> {
  const invite = env.TELEGRAM_INVITE_LINK
  const ctx = deps.ctx ?? chainContext(env)
  if (!invite || !ctx.deployed || !ctx.client) return reply(503, { error: 'The gate is not configured yet.' })

  const { wallet, timestamp, signature } = (body ?? {}) as Record<string, unknown>
  if (typeof wallet !== 'string' || !isAddress(wallet)) return reply(400, { error: 'Bad wallet address.' })
  if (typeof signature !== 'string' || !isHex(signature) || signature.length > 20_000) {
    return reply(400, { error: 'Bad signature.' })
  }
  const now = Math.floor((deps.now ?? Date.now)() / 1000)
  const stale = timestampProblem(timestamp, now)
  if (stale) return reply(401, { error: stale })

  const address = getAddress(wallet) as Address
  const message = accessMessage({ wallet: address, vault: ctx.vault, chainId: ctx.chainId, timestamp: timestamp as number })

  let signed = false
  try {
    signed = await ctx.client.verifyMessage({ address, message, signature: signature as Hex })
  } catch {
    signed = false
  }
  if (!signed) return reply(401, { error: 'Signature does not match that wallet.' })

  let allowed: boolean
  try {
    allowed = await ctx.client.readContract({
      address: ctx.vault,
      abi: hasAccessAbi,
      functionName: 'hasAccess',
      args: [address],
    })
  } catch {
    return reply(502, { error: 'Could not reach the chain. Try again.' })
  }
  if (!allowed) return reply(403, { error: 'No pass with an open position. No door.' })

  return reply(200, { invite })
}
