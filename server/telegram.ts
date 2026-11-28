import { createHmac, timingSafeEqual } from 'node:crypto'
import { getAddress, type Address } from 'viem'

// The OnlyWhales Telegram bot: the bouncer for the group.
//
// 1. /api/access checks the signature and hasAccess(wallet), then returns a link to this bot carrying a
//    start code: the wallet and an expiry, signed with TELEGRAM_SECRET. Valid for 10 minutes, usable once.
// 2. The whale taps Start. The bot ties that Telegram account to the wallet and sends a join link.
// 3. The join link only asks to join. The bot approves accounts tied to a wallet the vault says has
//    access, and declines everyone else. A forwarded link gets nobody in.
// 4. On a schedule, the bot re-checks every member. A wallet without access loses its seat and can come
//    back by depositing again.
// 5. One wallet, one seat. /status in a private chat shows the member their own position.
//
// The bot only removes accounts it let in itself, never anyone else in the group. If the chain cannot be
// read, it admits nobody and removes nobody. Everything outside this file is passed in, so it is tested
// without a network.

export const CODE_TTL_SECONDS = 600

export type Member = { wallet: Address; since: number }
/** members: Telegram user id -> wallet. used: start code id -> its expiry (seconds), to refuse reuse. */
export type BotState = { members: Record<string, Member>; used: Record<string, number> }
export const emptyState = (): BotState => ({ members: {}, used: {} })

export type Tg = (method: string, params?: Record<string, unknown>) => Promise<any>

export type BotDeps = {
  tg: Tg
  /** The vault's own hasAccess(wallet): a pass and an open position. Throws if the chain cannot be read. */
  hasAccess: (wallet: Address) => Promise<boolean>
  /** Text for /status, or null when the wallet has no position. */
  status: (wallet: Address) => Promise<string | null>
  state: { load(): Promise<BotState>; save(state: BotState): Promise<void> }
  secret: string
  chatId: string
  now: () => number // milliseconds
}

export const COPY = {
  welcome: (link: string) =>
    `Welcome to the 3% Club.\n\nTap to ask to join the pool. I'll let you straight in. The link is yours alone and expires in 10 minutes:\n${link}`,
  badCode: 'That code is used up or expired. Go back to the OnlyWhales site and press the button again.',
  noAccess: 'No pass with an open position. No door.',
  hello: 'I guard the OnlyWhales pool. Deposit on the site, then press the button there to get in.\n\n/status shows your position.',
  notMember: 'I do not know you yet. Open the door from the OnlyWhales site first.',
  declined: 'I could not let you in: your Telegram account is not tied to a wallet with a pass and an open position. Press the button on the OnlyWhales site.',
  removed: 'Your position is closed, so your seat in the pool is too. Deposit again and the door reopens.',
  replaced: 'This wallet was just tied to another Telegram account, so this one lost its seat. One wallet, one seat.',
  chainDown: 'I cannot reach the chain right now. Try again in a minute.',
}

// ------------------------------------------------------------------ start codes

const keyFor = (secret: string, label: string) => createHmac('sha256', secret).update(label).digest()
const CODE_BYTES = 20 + 4 + 12 // wallet, expiry, truncated HMAC: 48 base64url characters, under Telegram's 64

/** A start code for `wallet`, valid for 10 minutes. Only the holder of TELEGRAM_SECRET can make one. */
export function makeStartCode(wallet: Address, secret: string, nowSeconds: number): string {
  const payload = Buffer.alloc(24)
  Buffer.from(wallet.slice(2), 'hex').copy(payload, 0)
  payload.writeUInt32BE(nowSeconds + CODE_TTL_SECONDS, 20)
  const mac = createHmac('sha256', keyFor(secret, 'start-code')).update(payload).digest().subarray(0, 12)
  return Buffer.concat([payload, mac]).toString('base64url')
}

/** The wallet a start code was made for, or null if it is forged, malformed or expired. */
export function readStartCode(code: string, secret: string, nowSeconds: number) {
  if (!/^[A-Za-z0-9_-]{48}$/.test(code)) return null
  const raw = Buffer.from(code, 'base64url')
  if (raw.length !== CODE_BYTES) return null
  const payload = raw.subarray(0, 24)
  const mac = raw.subarray(24)
  const expected = createHmac('sha256', keyFor(secret, 'start-code')).update(payload).digest().subarray(0, 12)
  if (!timingSafeEqual(mac, expected)) return null
  const expires = payload.readUInt32BE(20)
  if (expires < nowSeconds) return null
  return { wallet: getAddress(`0x${payload.subarray(0, 20).toString('hex')}`) as Address, expires, id: mac.toString('hex') }
}

export const botLink = (username: string, code: string) => `https://t.me/${username}?start=${code}`

// ------------------------------------------------------------------ the bot

const seconds = (d: BotDeps) => Math.floor(d.now() / 1000)

async function say(d: BotDeps, chatId: number | string, text: string) {
  try {
    await d.tg('sendMessage', { chat_id: Number(chatId), text, link_preview_options: { is_disabled: true } })
  } catch {
    // They may have blocked the bot. Nothing else depends on this message arriving.
  }
}

/** Out of the group, free to come back later: a short ban, lifted at once. */
async function remove(d: BotDeps, state: BotState, userId: string, why: string) {
  delete state.members[userId]
  try {
    await d.tg('banChatMember', { chat_id: d.chatId, user_id: Number(userId), until_date: seconds(d) + 60 })
    await d.tg('unbanChatMember', { chat_id: d.chatId, user_id: Number(userId), only_if_banned: true })
  } catch {
    // Not in the group, or already gone.
  }
  await say(d, userId, why)
}

function prune(state: BotState, nowSeconds: number) {
  for (const [id, expires] of Object.entries(state.used)) if (expires < nowSeconds) delete state.used[id]
}

async function onStart(d: BotDeps, userId: string, code: string | undefined) {
  if (!code) return say(d, userId, COPY.hello)
  const now = seconds(d)
  const parsed = readStartCode(code, d.secret, now)
  const state = await d.state.load()
  if (!parsed || state.used[parsed.id]) return say(d, userId, COPY.badCode)

  let allowed: boolean
  try {
    allowed = await d.hasAccess(parsed.wallet)
  } catch {
    return say(d, userId, COPY.chainDown) // the code is not spent, so they can try again
  }
  prune(state, now)
  state.used[parsed.id] = parsed.expires
  if (!allowed) {
    await d.state.save(state)
    return say(d, userId, COPY.noAccess)
  }

  const holder = Object.keys(state.members).find((id) => state.members[id].wallet === parsed.wallet)
  if (holder && holder !== userId) await remove(d, state, holder, COPY.replaced)
  state.members[userId] = { wallet: parsed.wallet, since: now }
  await d.state.save(state)

  const invite = await d.tg('createChatInviteLink', {
    chat_id: d.chatId,
    creates_join_request: true,
    expire_date: now + CODE_TTL_SECONDS,
    name: `${parsed.wallet.slice(0, 6)}…${parsed.wallet.slice(-4)}`,
  })
  return say(d, userId, COPY.welcome(invite.invite_link))
}

async function onJoinRequest(d: BotDeps, req: any) {
  if (String(req?.chat?.id) !== String(d.chatId)) return
  const userId = String(req.from.id)
  const member = (await d.state.load()).members[userId]
  let ok = false
  try {
    ok = !!member && (await d.hasAccess(member.wallet))
  } catch {
    ok = false // cannot check, so do not admit
  }
  await d.tg(ok ? 'approveChatJoinRequest' : 'declineChatJoinRequest', { chat_id: d.chatId, user_id: Number(userId) })
  if (!ok) await say(d, req.user_chat_id ?? userId, COPY.declined)
}

async function onStatus(d: BotDeps, userId: string) {
  const member = (await d.state.load()).members[userId]
  if (!member) return say(d, userId, COPY.notMember)
  try {
    return say(d, userId, (await d.status(member.wallet)) ?? COPY.noAccess)
  } catch {
    return say(d, userId, COPY.chainDown)
  }
}

/** Feed every Telegram update here. Acts only on private messages and on join requests to the group. */
export async function handleUpdate(update: any, d: BotDeps): Promise<void> {
  if (update?.chat_join_request) return onJoinRequest(d, update.chat_join_request)
  const m = update?.message
  if (!m || m.chat?.type !== 'private' || typeof m.text !== 'string' || !m.from) return // never reads or answers the group
  const userId = String(m.from.id)
  const [command, arg] = m.text.trim().split(/\s+/)
  const name = command.split('@')[0]
  if (name === '/start') return onStart(d, userId, arg)
  if (name === '/status') return onStatus(d, userId)
  return say(d, userId, COPY.hello)
}

/** Removes every member whose wallet no longer has access. A wallet that cannot be read is left alone. */
export async function sweep(d: BotDeps): Promise<string[]> {
  const state = await d.state.load()
  const removed: string[] = []
  for (const userId of Object.keys(state.members)) {
    let has: boolean
    try {
      has = await d.hasAccess(state.members[userId].wallet)
    } catch {
      continue
    }
    if (!has) {
      await remove(d, state, userId, COPY.removed)
      removed.push(userId)
    }
  }
  prune(state, seconds(d))
  await d.state.save(state)
  return removed
}
