import { describe, expect, it } from 'vitest'
import { verifyMessage, type Address } from 'viem'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { accessMessage } from '../shared/messages.js'
import { handleAccess } from './access.js'
import type { ChainContext } from './env.js'
import type { Store } from './storage.js'
import { CODE_TTL_SECONDS, botLink, emptyState, handleUpdate, makeStartCode, readStartCode, sweep, type BotDeps, type BotState } from './telegram.js'
import { handleTelegramWebhook, sealedState, telegramConfig } from './telegram-env.js'

const SECRET = 'test-secret-0123456789abcdefghijklmnopqrstuvwxyz'
const CHAT = '-1001234'
const A = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8' as Address
const B = '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC' as Address
const T0 = 1_800_000_000_000

const memoryStore = (): Store & { raw: () => string | null } => {
  let value: string | null = null
  return { get: async () => value, set: async (v) => void (value = v), raw: () => value }
}

/** A bot wired to a fake Telegram, a fake vault and an in-memory store. */
function setup(opts: { access?: Address[]; saved?: BotState } = {}) {
  const access = new Set(opts.access ?? [A])
  const calls: Array<{ method: string } & Record<string, any>> = []
  let now = T0
  let down = false
  let state: BotState = opts.saved ?? emptyState()
  const deps: BotDeps = {
    secret: SECRET,
    chatId: CHAT,
    now: () => now,
    tg: async (method, params = {}) => {
      calls.push({ method, ...params })
      return method === 'createChatInviteLink' ? { invite_link: 'https://t.me/+join' } : true
    },
    hasAccess: async (w) => {
      if (down) throw new Error('rpc down')
      return access.has(w)
    },
    status: async (w) => (access.has(w) ? `Position for ${w}` : null),
    state: { load: async () => structuredClone(state), save: async (s) => void (state = structuredClone(s)) },
  }
  const code = (w: Address) => makeStartCode(w, SECRET, Math.floor(now / 1000))
  const dm = (id: number, text: string) => handleUpdate({ message: { chat: { type: 'private', id }, from: { id }, text } }, deps)
  const join = (id: number, chatId = Number(CHAT)) => handleUpdate({ chat_join_request: { chat: { id: chatId }, from: { id }, user_chat_id: id } }, deps)
  const said = (id: number) => calls.filter((c) => c.method === 'sendMessage' && c.chat_id === id).map((c) => c.text as string)
  const did = (method: string) => calls.filter((c) => c.method === method)
  return {
    deps, calls, code, dm, join, said, did, access,
    state: () => state,
    tick: (ms: number) => void (now += ms),
    setDown: (v: boolean) => void (down = v),
  }
}

describe('start codes', () => {
  const now = Math.floor(T0 / 1000)

  it('fit a Telegram start parameter and carry the wallet', () => {
    const code = makeStartCode(A, SECRET, now)
    expect(code).toMatch(/^[A-Za-z0-9_-]{48}$/)
    expect(readStartCode(code, SECRET, now)?.wallet).toBe(A)
    expect(botLink('OnlyWhalesBot', code)).toBe(`https://t.me/OnlyWhalesBot?start=${code}`)
  })

  it('expire after 10 minutes', () => {
    const code = makeStartCode(A, SECRET, now)
    expect(readStartCode(code, SECRET, now + CODE_TTL_SECONDS)).not.toBeNull()
    expect(readStartCode(code, SECRET, now + CODE_TTL_SECONDS + 1)).toBeNull()
  })

  it('cannot be forged or edited', () => {
    const code = makeStartCode(A, SECRET, now)
    expect(readStartCode(code, 'another-secret-0123456789abcdefghijklmnop', now)).toBeNull()
    const raw = Buffer.from(code, 'base64url')
    Buffer.from(B.slice(2), 'hex').copy(raw, 0) // swap in another wallet, keep the old signature
    expect(readStartCode(raw.toString('base64url'), SECRET, now)).toBeNull()
    expect(readStartCode('A'.repeat(48), SECRET, now)).toBeNull()
    expect(readStartCode('not a code', SECRET, now)).toBeNull()
  })
})

describe('the bot', () => {
  it('ties the account to the wallet and sends a join link that only asks to join', async () => {
    const t = setup()
    await t.dm(111, `/start ${t.code(A)}`)
    expect(t.state().members['111'].wallet).toBe(A)
    const [invite] = t.did('createChatInviteLink')
    expect(invite.chat_id).toBe(CHAT)
    expect(invite.creates_join_request).toBe(true)
    expect(t.said(111)[0]).toContain('https://t.me/+join')
  })

  it('accepts a code once', async () => {
    const t = setup()
    const code = t.code(A)
    await t.dm(111, `/start ${code}`)
    await t.dm(222, `/start ${code}`)
    expect(t.state().members['222']).toBeUndefined()
    expect(t.said(222)[0]).toMatch(/used up or expired/)
  })

  it('refuses an expired or made-up code', async () => {
    const t = setup()
    const code = t.code(A)
    t.tick((CODE_TTL_SECONDS + 1) * 1000)
    await t.dm(111, `/start ${code}`)
    await t.dm(111, `/start ${'A'.repeat(48)}`)
    expect(t.state().members).toEqual({})
    expect(t.did('createChatInviteLink')).toHaveLength(0)
  })

  it('refuses a wallet that lost access between signing and Start', async () => {
    const t = setup()
    const code = t.code(A)
    t.access.clear()
    await t.dm(111, `/start ${code}`)
    expect(t.state().members).toEqual({})
    expect(t.said(111)[0]).toMatch(/No door/)
  })

  it('does not spend the code when the chain cannot be read', async () => {
    const t = setup()
    const code = t.code(A)
    t.setDown(true)
    await t.dm(111, `/start ${code}`)
    expect(t.said(111)[0]).toMatch(/cannot reach the chain/)
    t.setDown(false)
    await t.dm(111, `/start ${code}`)
    expect(t.state().members['111'].wallet).toBe(A)
  })

  it('approves a join request from a tied account with access', async () => {
    const t = setup()
    await t.dm(111, `/start ${t.code(A)}`)
    await t.join(111)
    expect(t.did('approveChatJoinRequest').map((c) => c.user_id)).toEqual([111])
  })

  it('declines anyone else, even holding a forwarded link', async () => {
    const t = setup()
    await t.dm(111, `/start ${t.code(A)}`)
    await t.join(999)
    expect(t.did('declineChatJoinRequest').map((c) => c.user_id)).toEqual([999])
    expect(t.did('approveChatJoinRequest')).toHaveLength(0)
    expect(t.said(999)[0]).toMatch(/could not let you in/)
  })

  it('declines when the chain cannot be read, and ignores other groups', async () => {
    const t = setup()
    await t.dm(111, `/start ${t.code(A)}`)
    await t.join(111, -42)
    expect(t.did('approveChatJoinRequest')).toHaveLength(0)
    expect(t.did('declineChatJoinRequest')).toHaveLength(0)
    t.setDown(true)
    await t.join(111)
    expect(t.did('approveChatJoinRequest')).toHaveLength(0)
  })

  it('one wallet, one seat: a second account bumps the first', async () => {
    const t = setup()
    await t.dm(111, `/start ${t.code(A)}`)
    t.tick(1000) // a code is fixed per wallet and second, so the second one comes a second later
    await t.dm(222, `/start ${t.code(A)}`)
    expect(Object.keys(t.state().members)).toEqual(['222'])
    expect(t.did('banChatMember').map((c) => c.user_id)).toEqual([111])
  })

  it('/status answers a member and turns away a stranger', async () => {
    const t = setup()
    await t.dm(111, `/start ${t.code(A)}`)
    await t.dm(111, '/status')
    expect(t.said(111).at(-1)).toBe(`Position for ${A}`)
    await t.dm(999, '/status')
    expect(t.said(999)[0]).toMatch(/do not know you yet/)
  })

  it('never answers in the group', async () => {
    const t = setup()
    await handleUpdate({ message: { chat: { type: 'supergroup', id: Number(CHAT) }, from: { id: 111 }, text: '/status' } }, t.deps)
    await handleUpdate({ message: { chat: { type: 'supergroup', id: Number(CHAT) }, from: { id: 111 }, text: '/start x' } }, t.deps)
    expect(t.calls).toHaveLength(0)
  })
})

describe('the sweep', () => {
  it('removes members who lost access and lets them come back later', async () => {
    const t = setup({ access: [A, B] })
    await t.dm(111, `/start ${t.code(A)}`)
    await t.dm(222, `/start ${t.code(B)}`)
    t.access.delete(A)
    expect(await sweep(t.deps)).toEqual(['111'])
    expect(t.did('banChatMember').map((c) => c.user_id)).toEqual([111])
    expect(t.did('unbanChatMember').map((c) => [c.user_id, c.only_if_banned])).toEqual([[111, true]])
    expect(Object.keys(t.state().members)).toEqual(['222'])
    expect(t.said(111).at(-1)).toMatch(/seat in the pool is too/)
  })

  it('removes nobody when the chain cannot be read', async () => {
    const t = setup()
    await t.dm(111, `/start ${t.code(A)}`)
    t.setDown(true)
    expect(await sweep(t.deps)).toEqual([])
    expect(t.did('banChatMember')).toHaveLength(0)
  })

  it('forgets used codes once they expire', async () => {
    const t = setup()
    await t.dm(111, `/start ${t.code(A)}`)
    expect(Object.keys(t.state().used)).toHaveLength(1)
    t.tick((CODE_TTL_SECONDS + 1) * 1000)
    await sweep(t.deps)
    expect(t.state().used).toEqual({})
  })
})

describe('the members file', () => {
  it('is encrypted at rest and round-trips', async () => {
    const store = memoryStore()
    const sealed = sealedState(store, SECRET)
    await sealed.save({ members: { '111': { wallet: A, since: 1 } }, used: {} })
    expect(store.raw()).not.toContain(A.slice(2, 10))
    expect(store.raw()).not.toContain('111')
    expect((await sealed.load()).members['111'].wallet).toBe(A)
  })

  it('refuses to load with the wrong secret instead of starting empty', async () => {
    const store = memoryStore()
    await sealedState(store, SECRET).save({ members: { '111': { wallet: A, since: 1 } }, used: {} })
    await expect(sealedState(store, 'another-secret-0123456789abcdefghijklmnop').load()).rejects.toThrow(/TELEGRAM_SECRET/)
  })

  it('starts empty when there is no file yet', async () => {
    expect(await sealedState(memoryStore(), SECRET).load()).toEqual(emptyState())
  })
})

describe('configuration and endpoints', () => {
  const env = { TELEGRAM_BOT_TOKEN: '1:abc', TELEGRAM_BOT_USERNAME: '@OnlyWhalesBot', TELEGRAM_CHAT_ID: CHAT, TELEGRAM_SECRET: SECRET }

  it('is off until all four values are set, and refuses a weak secret', () => {
    expect(telegramConfig({})).toBeNull()
    expect(telegramConfig({ ...env, TELEGRAM_CHAT_ID: '' })).toBeNull()
    expect(telegramConfig(env)?.username).toBe('OnlyWhalesBot')
    expect(() => telegramConfig({ ...env, TELEGRAM_SECRET: 'short' })).toThrow(/32 to 256/)
  })

  it('the webhook refuses calls without Telegram\'s secret header', async () => {
    const t = setup()
    const ctx = { chainId: 56, vault: A, deployed: true, client: {} } as unknown as ChainContext
    const o = { ctx, tg: t.deps.tg, state: t.deps.state }
    expect((await handleTelegramWebhook(null, {}, env, o)).status).toBe(401)
    expect((await handleTelegramWebhook('wrong', {}, env, o)).status).toBe(401)
    expect((await handleTelegramWebhook(SECRET, {}, {}, o)).status).toBe(503)
    expect((await handleTelegramWebhook(SECRET, { update_id: 1 }, env, o)).status).toBe(200)
  })

  it('/api/access returns a one-time bot link for this wallet when the bot is on', async () => {
    const whale = privateKeyToAccount(generatePrivateKey())
    const now = Math.floor(T0 / 1000)
    const ctx: ChainContext = {
      chainId: 56,
      vault: B,
      deployed: true,
      client: { verifyMessage: (args: any) => verifyMessage(args), readContract: async () => true } as any,
    }
    const message = accessMessage({ wallet: whale.address, vault: B, chainId: 56, timestamp: now })
    const body = { wallet: whale.address, timestamp: now, signature: await whale.signMessage({ message }) }
    const res = await handleAccess(body, { ...env, TELEGRAM_INVITE_LINK: 'https://t.me/+shared' }, { ctx, now: () => T0 })
    expect(res.status).toBe(200)
    const invite = String(res.body.invite)
    expect(invite).toMatch(/^https:\/\/t\.me\/OnlyWhalesBot\?start=/)
    expect(readStartCode(invite.split('start=')[1], SECRET, now)?.wallet).toBe(whale.address)
  })
})
