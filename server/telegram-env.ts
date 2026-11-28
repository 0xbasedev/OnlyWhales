import { createCipheriv, createDecipheriv, createHmac, randomBytes, timingSafeEqual } from 'node:crypto'
import { formatUnits, type Address } from 'viem'
import { vaultAbi } from '../src/abi/vault.js'
import { chainContext, reply, type ChainContext, type Reply, type ServerEnv } from './env.js'
import { blobStore, fileStore, type Store } from './storage.js'
import { emptyState, handleUpdate, sweep, type BotDeps, type BotState, type Tg } from './telegram.js'

// Wiring for the bot: configuration, the Telegram API, the chain, and where members are kept.

export type TelegramConfig = { token: string; secret: string; chatId: string; username: string; apiBase: string }

/**
 * The bot is on when all four are set:
 *   TELEGRAM_BOT_TOKEN     from @BotFather
 *   TELEGRAM_BOT_USERNAME  the bot's username, without @
 *   TELEGRAM_CHAT_ID       the group's id, a negative number
 *   TELEGRAM_SECRET        32 to 256 random characters (A-Z a-z 0-9 _ -). Signs start codes, authenticates
 *                          the webhook and encrypts the members file. Changing it makes that file unreadable.
 */
export function telegramConfig(env: ServerEnv): TelegramConfig | null {
  const token = env.TELEGRAM_BOT_TOKEN?.trim()
  const username = env.TELEGRAM_BOT_USERNAME?.trim().replace(/^@/, '')
  const chatId = env.TELEGRAM_CHAT_ID?.trim()
  const secret = env.TELEGRAM_SECRET?.trim()
  if (!token || !username || !chatId || !secret) return null
  if (!/^[A-Za-z0-9_-]{32,256}$/.test(secret)) throw new Error('TELEGRAM_SECRET must be 32 to 256 characters of A-Z, a-z, 0-9, _ or -.')
  if (!/^[A-Za-z0-9_]{5,32}$/.test(username)) throw new Error('TELEGRAM_BOT_USERNAME is not a valid Telegram username.')
  if (!/^-?\d+$/.test(chatId)) throw new Error('TELEGRAM_CHAT_ID must be the group id, a number such as -1001234567890.')
  return { token, secret, chatId, username, apiBase: env.TELEGRAM_API_URL || 'https://api.telegram.org' }
}

export function telegramApi(config: Pick<TelegramConfig, 'token' | 'apiBase'>): Tg {
  return async (method, params = {}) => {
    const timeout = typeof params.timeout === 'number' ? (params.timeout + 10) * 1000 : 20_000
    const res = await fetch(`${config.apiBase}/bot${config.token}/${method}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(params),
      signal: AbortSignal.timeout(timeout),
    })
    const body = (await res.json().catch(() => ({}))) as { ok?: boolean; result?: unknown; description?: string; error_code?: number }
    if (!body.ok) throw Object.assign(new Error(`${method}: ${body.description ?? res.status}`), { code: body.error_code ?? res.status })
    return body.result
  }
}

// ------------------------------------------------------------------ members file, encrypted

/**
 * The members file ties Telegram accounts to wallets. That tie exists nowhere else, so the file is
 * encrypted (AES-256-GCM, key derived from TELEGRAM_SECRET) before it is written to Blob or disk.
 */
export function sealedState(store: Store, secret: string): BotDeps['state'] {
  const key = createHmac('sha256', secret).update('members-file').digest()
  return {
    async load() {
      const text = await store.get()
      if (!text) return emptyState()
      try {
        const box = JSON.parse(text) as { v: number; iv: string; tag: string; data: string }
        const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(box.iv, 'base64'))
        decipher.setAuthTag(Buffer.from(box.tag, 'base64'))
        const plain = Buffer.concat([decipher.update(Buffer.from(box.data, 'base64')), decipher.final()]).toString('utf8')
        return { ...emptyState(), ...(JSON.parse(plain) as BotState) }
      } catch {
        // Refuse to carry on with an empty list: the next save would wipe every tie.
        throw new Error('The Telegram members file cannot be read. Was TELEGRAM_SECRET changed?')
      }
    },
    async save(state) {
      const iv = randomBytes(12)
      const cipher = createCipheriv('aes-256-gcm', key, iv)
      const data = Buffer.concat([cipher.update(JSON.stringify(state), 'utf8'), cipher.final()])
      const box = { v: 1, iv: iv.toString('base64'), tag: cipher.getAuthTag().toString('base64'), data: data.toString('base64') }
      await store.set(JSON.stringify(box))
    },
  }
}

export function membersStore(env: ServerEnv): Store {
  if (env.BLOB_READ_WRITE_TOKEN) return blobStore(env.BLOB_READ_WRITE_TOKEN, 'onlywhales/telegram-members.json')
  return fileStore(env.TELEGRAM_MEMBERS_FILE || 'data/telegram-members.json')
}

// ------------------------------------------------------------------ the chain

const hasAccessAbi = [
  { type: 'function', name: 'hasAccess', stateMutability: 'view', inputs: [{ name: 'wallet', type: 'address' }], outputs: [{ type: 'bool' }] },
] as const

const fmt = (wei: bigint, max = 4) => Number(formatUnits(wei, 18)).toLocaleString('en-US', { maximumFractionDigits: max })
const pct = (wad: bigint) => `${(Number(wad) / 1e16).toFixed(1)}%`

export function chainReads(ctx: ChainContext, now: () => number = Date.now) {
  const client = ctx.client
  if (!client) throw new Error('No chain client: the vault is not deployed or there is no RPC URL.')
  const hasAccess = (wallet: Address) =>
    client.readContract({ address: ctx.vault, abi: hasAccessAbi, functionName: 'hasAccess', args: [wallet] }) as Promise<boolean>

  const status = async (wallet: Address) => {
    const lines: string[] = []
    for (const [pool, symbol] of [[0, 'USDC'], [1, 'BNB']] as const) {
      const p = (await client.readContract({ address: ctx.vault, abi: vaultAbi, functionName: 'positionOf', args: [wallet, pool] })) as {
        amount: bigint; lockEnd: bigint; locked: boolean; slashWad: bigint; slashAmount: bigint; earned: bigint; elder: boolean
      }
      if (p.amount === 0n && p.earned === 0n) continue
      lines.push(`${symbol} pool`)
      if (p.amount > 0n) lines.push(`  Locked: ${fmt(p.amount)} ${symbol}${p.elder ? ' (elder)' : ''}`)
      if (p.amount > 0n && p.locked) {
        const left = Math.max(0, Number(p.lockEnd) - Math.floor(now() / 1000))
        const days = Math.floor(left / 86400)
        const hours = Math.floor((left % 86400) / 3600)
        const date = new Date(Number(p.lockEnd) * 1000).toISOString().slice(0, 10)
        lines.push(`  Unlocks in ${days}d ${hours}h (${date})`)
        lines.push(`  Leaving now costs ${pct(p.slashWad)} (${fmt(p.slashAmount)} ${symbol})`)
      } else if (p.amount > 0n) lines.push('  Lock ended: you can withdraw in full')
      lines.push(`  Earned, unclaimed: ${fmt(p.earned)} ${symbol}`)
    }
    return lines.length ? lines.join('\n') : null
  }
  return { hasAccess, status }
}

// ------------------------------------------------------------------ entry points

export type BotOverrides = { ctx?: ChainContext; tg?: Tg; state?: BotDeps['state']; now?: () => number }

/** Everything the bot needs, from the environment. Null when the bot or the vault is not configured. */
export function botDepsFromEnv(env: ServerEnv, o: BotOverrides = {}): BotDeps | null {
  const config = telegramConfig(env)
  const ctx = o.ctx ?? chainContext(env)
  if (!config || !ctx.deployed || !ctx.client) return null
  const now = o.now ?? Date.now
  return {
    ...chainReads(ctx, now),
    tg: o.tg ?? telegramApi(config),
    state: o.state ?? sealedState(membersStore(env), config.secret),
    secret: config.secret,
    chatId: config.chatId,
    now,
  }
}

const sameSecret = (a: string, b: string) => {
  const x = Buffer.from(a)
  const y = Buffer.from(b)
  return x.length === y.length && timingSafeEqual(x, y)
}

/**
 * POST /api/telegram: Telegram delivers updates here once the webhook is set
 * (node scripts/telegram-webhook.mjs set https://your-site). The secret header proves the call is from
 * Telegram. A 500 makes Telegram retry and shows the error in getWebhookInfo.
 */
export async function handleTelegramWebhook(headerSecret: string | null, update: unknown, env: ServerEnv, o: BotOverrides = {}): Promise<Reply> {
  const config = telegramConfig(env)
  if (!config) return reply(503, { error: 'The bot is not configured.' })
  if (!headerSecret || !sameSecret(headerSecret, config.secret)) return reply(401, { error: 'Not Telegram.' })
  const deps = botDepsFromEnv(env, o)
  if (!deps) return reply(503, { error: 'The vault is not deployed yet.' })
  try {
    await handleUpdate(update, deps)
    return reply(200, { ok: true })
  } catch (err) {
    console.error('telegram update failed:', (err as Error).message)
    return reply(500, { error: 'Update failed.' })
  }
}

/** The scheduled sweep. Returns the Telegram ids removed. */
export async function runSweep(env: ServerEnv, o: BotOverrides = {}): Promise<string[]> {
  const deps = botDepsFromEnv(env, o)
  if (!deps) return []
  return sweep(deps)
}

/**
 * Local development only (`pnpm dev` with a bot token): long polling instead of a webhook, and a sweep
 * every five minutes (TELEGRAM_DEV_SWEEP_SECONDS to change it). Use a separate test bot: if the bot already has a webhook set, polling is refused
 * and this stops rather than removing the webhook.
 */
export function startPolling(env: ServerEnv, log: (line: string) => void = console.log): () => void {
  let stopped = false
  let deps: BotDeps | null
  try {
    deps = botDepsFromEnv(env)
  } catch (err) {
    log(`telegram bot: ${(err as Error).message}`)
    return () => {}
  }
  if (!deps) {
    log('telegram bot: off (needs TELEGRAM_BOT_TOKEN, TELEGRAM_BOT_USERNAME, TELEGRAM_CHAT_ID, TELEGRAM_SECRET and a deployed vault)')
    return () => {}
  }
  const d = deps
  log(`telegram bot: polling for @${telegramConfig(env)!.username}`)
  void (async () => {
    let offset = 0
    while (!stopped) {
      try {
        const updates = (await d.tg('getUpdates', { offset, timeout: 25, allowed_updates: ['message', 'chat_join_request'] })) as any[]
        for (const u of updates) {
          offset = u.update_id + 1
          await handleUpdate(u, d).catch((err) => log(`telegram update failed: ${err.message}`))
        }
      } catch (err) {
        if ((err as { code?: number }).code === 409) {
          log('telegram bot: this bot has a webhook set, so it cannot poll. Use a separate bot for local dev.')
          return
        }
        if (!stopped) await new Promise((r) => setTimeout(r, 5000))
      }
    }
  })()
  const every = Number(env.TELEGRAM_DEV_SWEEP_SECONDS || 300) * 1000
  const timer = setInterval(() => {
    sweep(d)
      .then((removed) => removed.length && log(`telegram sweep removed ${removed.length}`))
      .catch((err) => log(`telegram sweep failed: ${err.message}`))
  }, every)
  return () => {
    stopped = true
    clearInterval(timer)
  }
}
