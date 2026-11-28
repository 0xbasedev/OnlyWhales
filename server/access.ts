import { getAddress, isAddress, isHex, type Address, type Hex } from 'viem'
import { accessMessage, timestampProblem } from '../shared/messages.js'
import { chainContext, reply, type ChainContext, type Reply, type ServerEnv } from './env.js'
import { botLink, makeStartCode } from './telegram.js'
import { telegramConfig } from './telegram-env.js'

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
 * Only then is an invite returned. With the Telegram bot configured, it is a link to the bot carrying a
 * one-time start code for this wallet (server/telegram.ts), so a forwarded link gets nobody in. Without
 * the bot, it is TELEGRAM_INVITE_LINK. Neither is ever in the client bundle or in any error path.
 */
export async function handleAccess(body: unknown, env: ServerEnv, deps: AccessDeps = {}): Promise<Reply> {
  let bot: ReturnType<typeof telegramConfig>
  try {
    bot = telegramConfig(env)
  } catch {
    return reply(503, { error: 'The gate is not configured yet.' })
  }
  const invite = env.TELEGRAM_INVITE_LINK
  const ctx = deps.ctx ?? chainContext(env)
  if ((!bot && !invite) || !ctx.deployed || !ctx.client) return reply(503, { error: 'The gate is not configured yet.' })

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

  if (bot) return reply(200, { invite: botLink(bot.username, makeStartCode(address, bot.secret, now)) })
  return reply(200, { invite })
}
