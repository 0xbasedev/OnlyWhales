import { describe, expect, it } from 'vitest'
import { verifyMessage, type Address } from 'viem'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { createHash } from 'node:crypto'
import { accessMessage, brandingMessage } from '../shared/messages.js'
import { defaultBranding } from '../shared/branding.js'
import { handleAccess } from './access.js'
import { handleBrandingGet, handleBrandingPost } from './branding.js'
import type { ChainContext } from './env.js'
import type { Store } from './storage.js'

const VAULT = '0x00000000000000000000000000000000000000A1' as Address
const LINK = 'https://t.me/+super-secret-invite'
const NOW = 1_800_000_000
const env = { TELEGRAM_INVITE_LINK: LINK }
const now = () => NOW * 1000

const whale = privateKeyToAccount(generatePrivateKey())
const stranger = privateKeyToAccount(generatePrivateKey())

function ctx(opts: { access?: Address[]; operator?: Address; down?: boolean } = {}): ChainContext {
  return {
    chainId: 56,
    vault: VAULT,
    deployed: true,
    client: {
      verifyMessage: (args: any) => verifyMessage(args),
      readContract: async ({ functionName, args }: any) => {
        if (opts.down) throw new Error('rpc down')
        if (functionName === 'operator') return opts.operator
        return (opts.access ?? []).includes(args[0])
      },
    } as any,
  }
}

async function signedAccess(account = whale, timestamp = NOW, overrides: Partial<{ vault: Address; chainId: number }> = {}) {
  const message = accessMessage({ wallet: account.address, vault: VAULT, chainId: 56, timestamp, ...overrides })
  return { wallet: account.address, timestamp, signature: await account.signMessage({ message }) }
}

describe('POST /api/access', () => {
  it('returns the invite for a fresh signature from a wallet with access', async () => {
    const res = await handleAccess(await signedAccess(), env, { ctx: ctx({ access: [whale.address] }), now })
    expect(res).toEqual({ status: 200, body: { invite: LINK } })
  })

  it('accepts a signature right at the five minute edge and rejects one second later', async () => {
    const deps = { ctx: ctx({ access: [whale.address] }), now }
    expect((await handleAccess(await signedAccess(whale, NOW - 300), env, deps)).status).toBe(200)
    const late = await handleAccess(await signedAccess(whale, NOW - 301), env, deps)
    expect(late.status).toBe(401)
    expect(JSON.stringify(late.body)).not.toContain(LINK)
  })

  it('rejects timestamps from the future', async () => {
    const res = await handleAccess(await signedAccess(whale, NOW + 3600), env, { ctx: ctx({ access: [whale.address] }), now })
    expect(res.status).toBe(401)
  })

  it('rejects a signature made by a different wallet', async () => {
    const body = { ...(await signedAccess(stranger)), wallet: whale.address }
    const res = await handleAccess(body, env, { ctx: ctx({ access: [whale.address] }), now })
    expect(res.status).toBe(401)
    expect(JSON.stringify(res.body)).not.toContain(LINK)
  })

  it('rejects a signature over a different timestamp, vault or chain', async () => {
    const deps = { ctx: ctx({ access: [whale.address] }), now }
    const good = await signedAccess()
    expect((await handleAccess({ ...good, timestamp: NOW - 10 }, env, deps)).status).toBe(401)
    const otherVault = await signedAccess(whale, NOW, { vault: '0x00000000000000000000000000000000000000B2' })
    expect((await handleAccess(otherVault, env, deps)).status).toBe(401)
    const otherChain = await signedAccess(whale, NOW, { chainId: 97 })
    expect((await handleAccess(otherChain, env, deps)).status).toBe(401)
  })

  it('refuses a valid signer the vault does not recognise', async () => {
    const res = await handleAccess(await signedAccess(stranger), env, { ctx: ctx({ access: [whale.address] }), now })
    expect(res.status).toBe(403)
    expect(JSON.stringify(res.body)).not.toContain(LINK)
  })

  it('never leaks the link on malformed input, RPC failure or missing config', async () => {
    const deps = { ctx: ctx({ access: [whale.address] }), now }
    const cases = [
      await handleAccess(null, env, deps),
      await handleAccess({}, env, deps),
      await handleAccess({ wallet: 'nope', timestamp: NOW, signature: '0x00' }, env, deps),
      await handleAccess({ wallet: whale.address, timestamp: '1', signature: '0x00' }, env, deps),
      await handleAccess({ wallet: whale.address, timestamp: NOW, signature: 'zz' }, env, deps),
      await handleAccess(await signedAccess(), env, { ctx: ctx({ down: true }), now }),
      await handleAccess(await signedAccess(), {}, deps),
      await handleAccess(await signedAccess(), env, { ctx: { ...ctx(), deployed: false }, now }),
    ]
    for (const res of cases) {
      expect(res.status).toBeGreaterThanOrEqual(400)
      expect(JSON.stringify(res.body)).not.toContain('t.me')
    }
  })
})

describe('/api/branding', () => {
  const memory = (): Store & { value: string | null } => ({
    value: null,
    async get() {
      return this.value
    },
    async set(v: string) {
      this.value = v
    },
  })

  async function signedBranding(account: typeof whale, branding: unknown, timestamp = NOW) {
    const payload = JSON.stringify(branding)
    const digest = createHash('sha256').update(payload).digest('hex')
    const message = brandingMessage({ wallet: account.address, vault: VAULT, chainId: 56, timestamp, digest })
    return { wallet: account.address, timestamp, payload, signature: await account.signMessage({ message }) }
  }

  const edit = { ...defaultBranding, siteTitle: 'OnlyKrakens', copy: { ...defaultBranding.copy, 'hero.cta': 'Dive' } }

  it('saves instantly when signed by the on-chain operator and serves it back', async () => {
    const store = memory()
    const deps = { ctx: ctx({ operator: whale.address }), store, now }
    const res = await handleBrandingPost(await signedBranding(whale, edit), {}, deps)
    expect(res.status).toBe(200)
    const saved = (await handleBrandingGet({}, deps)).body.branding as any
    expect(saved.siteTitle).toBe('OnlyKrakens')
    expect(saved.copy).toEqual({ 'hero.cta': 'Dive' }) // only overrides are stored
  })

  it('rejects anyone who is not the operator', async () => {
    const store = memory()
    const res = await handleBrandingPost(await signedBranding(stranger, edit), {}, { ctx: ctx({ operator: whale.address }), store, now })
    expect(res.status).toBe(403)
    expect(store.value).toBeNull()
  })

  it('rejects a payload that was changed after signing, and stale signatures', async () => {
    const store = memory()
    const deps = { ctx: ctx({ operator: whale.address }), store, now }
    const body = await signedBranding(whale, edit)
    const tampered = { ...body, payload: body.payload.replace('OnlyKrakens', 'OnlyRugs') }
    expect((await handleBrandingPost(tampered, {}, deps)).status).toBe(401)
    expect((await handleBrandingPost(await signedBranding(whale, edit, NOW - 301), {}, deps)).status).toBe(401)
    expect(store.value).toBeNull()
  })

  it('rejects script-shaped or oversized content', async () => {
    const deps = { ctx: ctx({ operator: whale.address }), store: memory(), now }
    const badLogo = { ...edit, logo: 'data:text/html;base64,PHNjcmlwdD4=' }
    expect((await handleBrandingPost(await signedBranding(whale, badLogo), {}, deps)).status).toBe(400)
    const longCopy = { ...edit, copy: { 'hero.cta': 'x'.repeat(601) } }
    expect((await handleBrandingPost(await signedBranding(whale, longCopy), {}, deps)).status).toBe(400)
    const noTitle = { ...edit, siteTitle: '' }
    expect((await handleBrandingPost(await signedBranding(whale, noTitle), {}, deps)).status).toBe(400)
  })

  it('drops unknown copy keys instead of storing them', async () => {
    const store = memory()
    const deps = { ctx: ctx({ operator: whale.address }), store, now }
    const extra = { ...edit, copy: { 'hero.cta': 'Dive', 'not.a.key': 'nope' } }
    await handleBrandingPost(await signedBranding(whale, extra), {}, deps)
    expect(JSON.parse(store.value!).copy).toEqual({ 'hero.cta': 'Dive' })
  })
})
