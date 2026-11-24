import { useEffect, useMemo, useState } from 'react'
import { formatUnits, isAddress, parseUnits } from 'viem'
import { useAccount, useReadContracts, useSignMessage } from 'wagmi'
import { vaultAbi } from '../abi/vault'
import { brandingMessage } from '../../shared/messages'
import { copyKeys, defaultBranding, LIMITS, type Branding } from '../../shared/branding'
import prelaunch from '../../config/prelaunch.json'
import { useBranding } from '../hooks/useBranding'
import { useNow } from '../hooks/useNow'
import { useTx } from '../hooks/useTx'
import { useVault, type Pending } from '../hooks/useVault'
import { chain, HARD, POOLS, vaultAddress } from '../lib/config'
import { explainError } from '../lib/errors'
import { fmtCountdown, fmtDateTime, fmtToken, fmtUsd, shortAddr } from '../lib/format'
import { TIER_NAMES } from '../lib/math'
import { ConnectButton } from '../components/ConnectButton'
import { Footer } from '../components/Footer'
import { Nav } from '../components/Nav'
import { TxLine } from '../components/Bits'

const same = (a?: string, b?: string) => !!a && !!b && a.toLowerCase() === b.toLowerCase()

// ------------------------------------------------------------------ on-chain settings

type SettingDef = {
  param: 0 | 1 | 2 | 3
  title: string
  range: string
  placeholder: string
  show: (raw: bigint) => string
  /** Returns the on-chain value, or a string explaining what is wrong with the input. */
  parse: (text: string) => bigint | string
  note?: string
}

const usdSetting = (param: 1 | 2, title: string, note?: string): SettingDef => ({
  param,
  title,
  note,
  range: `Hard range ${fmtUsd(HARD.depositUsd[0])} – ${fmtUsd(HARD.depositUsd[1])}`,
  placeholder: 'USD, e.g. 500000',
  show: (raw) => fmtUsd(Number(formatUnits(raw, 18))),
  parse: (text) => {
    const n = Number(text.replace(/[$,\s]/g, ''))
    if (!Number.isFinite(n) || n <= 0) return 'Enter a dollar amount.'
    if (n < HARD.depositUsd[0] || n > HARD.depositUsd[1]) return 'Outside the hard range. The contract will refuse it.'
    return parseUnits(String(n), 18)
  },
})

const SETTINGS: SettingDef[] = [
  {
    param: 0,
    title: 'Deposit fee',
    range: 'Hard range 0.5% – 3%',
    placeholder: 'percent, e.g. 2.5',
    show: (raw) => `${Number(raw) / 100}%`,
    parse: (text) => {
      const pct = Number(text.replace(/[%\s]/g, ''))
      const bps = Math.round(pct * 100)
      if (!Number.isFinite(pct) || text.trim() === '') return 'Enter a percentage.'
      if (bps < HARD.feeBps[0] || bps > HARD.feeBps[1]) return 'Outside the hard range. The contract will refuse it.'
      return BigInt(bps)
    },
  },
  usdSetting(1, 'Minimum deposit per wallet', 'Raising it boosts every locked whale the moment it lands. Lowering it takes nothing back.'),
  usdSetting(2, 'Maximum deposit per wallet'),
  {
    param: 3,
    title: 'DAO wallet',
    range: 'Receives fees and the DAO share of slashes. Has no powers.',
    placeholder: '0x…',
    show: (raw) => `0x${raw.toString(16).padStart(40, '0')}`,
    parse: (text) => (isAddress(text.trim()) && BigInt(text.trim()) !== 0n ? BigInt(text.trim()) : 'Enter a wallet address.'),
  },
]

function Setting({ def, current, pending, now, canAct }: { def: SettingDef; current?: bigint; pending: Pending; now: number; canAct: boolean }) {
  const tx = useTx()
  const [text, setText] = useState('')
  const parsed = text.trim() ? def.parse(text) : null
  const problem = typeof parsed === 'string' ? parsed : parsed !== null && parsed === current ? 'That is already the current value.' : null
  const value = typeof parsed === 'bigint' ? parsed : null

  const send = (label: string, functionName: 'queueChange' | 'cancelChange', args: readonly unknown[]) =>
    vaultAddress ? tx.run(label, { address: vaultAddress, abi: vaultAbi, functionName, args }) : Promise.resolve(false)

  return (
    <div className="setting">
      <div>
        <h3>{def.title}</h3>
        <div className="now">{current !== undefined ? def.show(current) : '—'}</div>
        <div className="range-note">{def.range}</div>
        {def.note && <div className="range-note">{def.note}</div>}
      </div>
      {!pending && (
        <form
          className="setting-form"
          onSubmit={async (e) => {
            e.preventDefault()
            if (value !== null && !problem && (await send(`Queue ${def.title.toLowerCase()}`, 'queueChange', [def.param, value]))) setText('')
          }}
        >
          <input className="input" placeholder={def.placeholder} value={text} onChange={(e) => setText(e.target.value)} aria-label={`New ${def.title}`} disabled={!canAct} />
          <button className="btn sm primary" disabled={!canAct || value === null || !!problem || tx.busy}>
            Queue · 7 days
          </button>
        </form>
      )}
      {pending && (
        <div className="pending">
          <div>
            <div className="auto">Changing to</div>
            <div className="to">{def.show(pending.value)}</div>
          </div>
          <div>
            <div className="count" aria-live="off">
              {fmtCountdown(pending.eta - now)}
            </div>
            <div className="auto">Takes effect automatically · {fmtDateTime(pending.eta)}</div>
          </div>
          <button className="btn sm" disabled={!canAct || tx.busy} onClick={() => send(`Cancel ${def.title.toLowerCase()}`, 'cancelChange', [def.param])}>
            Cancel change
          </button>
        </div>
      )}
      {(problem || tx.state.phase !== 'idle') && (
        <div style={{ gridColumn: '1 / -1' }}>{problem ? <div className="status err">{problem}</div> : <TxLine state={tx.state} />}</div>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------- pass artwork

function TierArt({ now, canAct }: { now: number; canAct: boolean }) {
  const tx = useTx()
  const tiers = Array.from({ length: 10 }, (_, i) => i)
  const base = { address: vaultAddress!, abi: vaultAbi, chainId: chain.id } as const
  const q = useReadContracts({
    allowFailure: true,
    contracts: tiers.flatMap((i) => [
      { ...base, functionName: 'tierURI', args: [i] } as const,
      { ...base, functionName: 'pendingTierURI', args: [i] } as const,
    ]),
    query: { enabled: !!vaultAddress, refetchInterval: 30_000 },
  })
  const [drafts, setDrafts] = useState<Record<number, string>>({})

  return (
    <details className="fold">
      <summary>Pass artwork · 10 tiers · same 7-day delay</summary>
      {tiers.map((i) => {
        const current = q.data?.[i * 2]?.result as string | undefined
        const pend = q.data?.[i * 2 + 1]?.result as readonly [string, bigint] | undefined
        const pending = pend && pend[1] > 0n ? { uri: pend[0], eta: Number(pend[1]) } : null
        const draft = drafts[i] ?? ''
        const bad = /["\\]/.test(draft) || draft.length > 512
        return (
          <div className="setting" key={i}>
            <div>
              <h3>
                Tier {i + 1} · {TIER_NAMES[i]}
              </h3>
              <div className="range-note mono" style={{ overflowWrap: 'anywhere' }}>
                {current || 'no artwork set'}
              </div>
            </div>
            {pending ? (
              <div className="pending">
                <div>
                  <div className="auto">Changing to</div>
                  <div className="to">{pending.uri}</div>
                </div>
                <div>
                  <div className="count">{fmtCountdown(pending.eta - now)}</div>
                  <div className="auto">Takes effect automatically</div>
                </div>
                <button className="btn sm" disabled={!canAct || tx.busy} onClick={() => tx.run('Cancel artwork', { address: vaultAddress!, abi: vaultAbi, functionName: 'cancelTierURI', args: [i] })}>
                  Cancel change
                </button>
              </div>
            ) : (
              <form
                className="setting-form"
                onSubmit={async (e) => {
                  e.preventDefault()
                  if (await tx.run('Queue artwork', { address: vaultAddress!, abi: vaultAbi, functionName: 'queueTierURI', args: [i, draft.trim()] })) setDrafts((d) => ({ ...d, [i]: '' }))
                }}
              >
                <input className="input" placeholder="ipfs://… or https://…" value={draft} onChange={(e) => setDrafts((d) => ({ ...d, [i]: e.target.value }))} aria-label={`Artwork URI for tier ${i + 1}`} disabled={!canAct} />
                <button className="btn sm" disabled={!canAct || !draft.trim() || bad || tx.busy}>
                  Queue · 7 days
                </button>
              </form>
            )}
          </div>
        )
      })}
      <TxLine state={tx.state} />
    </details>
  )
}

// -------------------------------------------------------------------------- branding

function readImage(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(String(reader.result))
    reader.onerror = () => reject(new Error('Could not read that file.'))
    reader.readAsDataURL(file)
  })
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

function BrandingEditor({ operator }: { operator: `0x${string}` }) {
  const { saved, refresh, preview } = useBranding()
  const { signMessageAsync } = useSignMessage()
  const [draft, setDraft] = useState<Branding>(saved)
  const [status, setStatus] = useState<{ tone: '' | 'err' | 'done'; text: string }>({ tone: '', text: '' })
  const [busy, setBusy] = useState(false)

  // Show edits on the live page as they are typed; drop the preview when leaving.
  useEffect(() => {
    preview(draft)
  }, [draft, preview])
  useEffect(() => {
    return () => preview(null)
  }, [preview])

  const dirty = useMemo(() => JSON.stringify(draft) !== JSON.stringify(saved), [draft, saved])
  const setCopy = (key: string, value: string) => setDraft((d) => ({ ...d, copy: { ...d.copy, [key]: value } }))

  const upload = (key: 'logo' | 'favicon') => async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    e.target.value = ''
    if (!file) return
    try {
      const url = await readImage(file)
      if (url.length > LIMITS.image) throw new Error('Too large. Keep it under 300 KB.')
      setDraft((d) => ({ ...d, [key]: url }))
      setStatus({ tone: '', text: '' })
    } catch (err) {
      setStatus({ tone: 'err', text: explainError(err) })
    }
  }

  const save = async () => {
    try {
      setBusy(true)
      setStatus({ tone: '', text: 'Sign in your wallet. Free, off-chain.' })
      const payload = JSON.stringify(draft)
      const timestamp = Math.floor(Date.now() / 1000)
      const message = brandingMessage({ wallet: operator, vault: vaultAddress ?? '0x0000000000000000000000000000000000000000', chainId: chain.id, timestamp, digest: await sha256Hex(payload) })
      const signature = await signMessageAsync({ message })
      const res = await fetch('/api/branding', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ wallet: operator, timestamp, signature, payload }),
      })
      const json = (await res.json().catch(() => ({}))) as { error?: string }
      if (!res.ok) throw new Error(json.error || 'Save failed.')
      await refresh()
      setStatus({ tone: 'done', text: 'Live. No timelock on words.' })
    } catch (err) {
      setStatus({ tone: 'err', text: explainError(err) })
    } finally {
      setBusy(false)
    }
  }

  const groups = useMemo(() => {
    const out: Record<string, string[]> = {}
    for (const key of copyKeys) (out[key.split('.')[0]] ??= []).push(key)
    return Object.entries(out)
  }, [])

  return (
    <div className="glass pad">
      <h2 className="panel-title">Branding</h2>
      <p className="panel-lead">
        Off-chain. Goes live the moment you sign. Signing costs nothing. Write {'{min}'}, {'{max}'} and {'{fee}'} in the rules and the page fills in the live on-chain values.
      </p>

      <div className="copy-grid" style={{ marginTop: 26 }}>
        <label>
          site title
          <input className="input" style={{ width: '100%', fontFamily: 'var(--sans)' }} maxLength={LIMITS.siteTitle} value={draft.siteTitle} onChange={(e) => setDraft((d) => ({ ...d, siteTitle: e.target.value }))} />
        </label>
        <div />
        {(['logo', 'favicon'] as const).map((key) => (
          <div className="label" key={key}>
            {key}
            <div className="upload">
              <div className="thumb">{draft[key] ? <img src={draft[key]!} alt="" /> : <span className="faint">—</span>}</div>
              <label className="btn sm" style={{ cursor: 'pointer' }}>
                Upload
                <input type="file" accept="image/png,image/jpeg,image/webp,image/gif,image/svg+xml,image/x-icon" hidden onChange={upload(key)} />
              </label>
              {draft[key] && (
                <button className="btn sm quiet" onClick={() => setDraft((d) => ({ ...d, [key]: null }))}>
                  Use default
                </button>
              )}
            </div>
          </div>
        ))}
      </div>

      {groups.map(([group, keys]) => (
        <details className="fold" key={group} style={{ marginTop: 18 }} open={group === 'hero'}>
          <summary>
            Copy · {group} ({keys.length})
          </summary>
          <div className="copy-grid" style={{ marginTop: 12 }}>
            {keys.map((key) => (
              <label key={key}>
                {key}
                <textarea className="input" rows={2} maxLength={LIMITS.copy} value={draft.copy[key] ?? ''} onChange={(e) => setCopy(key, e.target.value)} />
              </label>
            ))}
          </div>
        </details>
      ))}

      <div className="actions">
        <button className="btn quiet sm" disabled={busy} onClick={() => setDraft({ ...defaultBranding })}>
          Reset to defaults
        </button>
        <button className="btn primary" disabled={!dirty || busy || !draft.siteTitle.trim()} onClick={save}>
          {busy ? 'Publishing…' : dirty ? 'Sign and publish' : 'Nothing to publish'}
        </button>
      </div>
      <div className={`status ${status.tone}`} role="status">
        {status.text}
      </div>
    </div>
  )
}

// ------------------------------------------------------------------------------ page

export function Owner() {
  const vault = useVault()
  const { address, isConnected } = useAccount()
  const now = useNow()
  const sweep = useTx()

  // Before deployment the operator is whoever config/prelaunch.json names.
  const operator = (vault.live ? vault.operator : (prelaunch.operator as `0x${string}`)) as `0x${string}` | undefined
  const isOperator = same(address, operator)

  const raw = useReadContracts({
    allowFailure: true,
    contracts: [
      { address: vaultAddress!, abi: vaultAbi, chainId: chain.id, functionName: 'depositFeeBps' },
      { address: vaultAddress!, abi: vaultAbi, chainId: chain.id, functionName: 'minDepositUsd' },
      { address: vaultAddress!, abi: vaultAbi, chainId: chain.id, functionName: 'maxDepositUsd' },
      { address: vaultAddress!, abi: vaultAbi, chainId: chain.id, functionName: 'daoWallet' },
    ],
    query: { enabled: vault.live, refetchInterval: 15_000 },
  })
  const current = (i: number): bigint | undefined => {
    const r = raw.data?.[i]?.result
    return r === undefined ? undefined : typeof r === 'string' ? BigInt(r) : (r as bigint)
  }

  let gate: string | null = null
  if (!isConnected) gate = 'Connect the operator wallet.'
  else if (vault.live && vault.loading) gate = 'Reading the vault…'
  else if (!isOperator) gate = 'Not your pool.'

  return (
    <>
      <Nav vault={vault} owner />
      <main className="owner wrap">
        <div className="section-head">
          <div className="eyebrow">Operator</div>
          <h2>The short list of things you can touch.</h2>
          <p>
            Four settings and some artwork, each inside a range the contract will not let you leave, each on a seven-day delay everyone can see. You cannot pause it, upgrade it, hand it over, or reach a
            single deposit.
          </p>
        </div>

        {gate ? (
          <div className="glass pad empty">
            <div className="big">{gate}</div>
            {isConnected && !isOperator && operator && (
              <div>
                This page answers to <span className="mono">{shortAddr(operator)}</span>. You are <span className="mono">{shortAddr(address)}</span>.
              </div>
            )}
            {!isConnected && <ConnectButton primary />}
          </div>
        ) : (
          <div className="stack">
            <div className="glass pad">
              <h2 className="panel-title">On-chain settings</h2>
              <p className="panel-lead">
                {vault.live
                  ? 'Queue a change and it takes effect by itself seven days later. There is no second transaction. You can cancel until it lands.'
                  : 'The vault is not deployed yet. Launch values come from config/prelaunch.json; this panel wakes up once VITE_VAULT_ADDRESS is set.'}
              </p>
              <div style={{ marginTop: 10 }}>
                {SETTINGS.map((def) => (
                  <Setting key={def.param} def={def} current={current(def.param)} pending={vault.pending[def.param]} now={now} canAct={vault.live} />
                ))}
              </div>
              {vault.live && <TierArt now={now} canAct />}
            </div>

            {vault.live && (
              <div className="glass pad">
                <h2 className="panel-title">DAO balance</h2>
                <p className="panel-lead">
                  Fees and the DAO share of slashes wait in the vault until someone sends them on. Anyone can press this; it only ever pays <span className="mono">{shortAddr(vault.dao)}</span>.
                </p>
                <div className="pos-grid">
                  {POOLS.map((p) => {
                    const owed = vault.pools[p.id]?.daoOwed ?? 0n
                    return (
                      <div className="stat" key={p.id}>
                        <div className="k">{p.symbol} waiting</div>
                        <div className="v">{fmtToken(owed, p.symbol, 6)}</div>
                        <button
                          className="btn sm"
                          style={{ marginTop: 12 }}
                          disabled={owed === 0n || sweep.busy}
                          onClick={() => sweep.run(`Send ${p.symbol} to DAO`, { address: vaultAddress!, abi: vaultAbi, functionName: 'sweepDao', args: [p.id] })}
                        >
                          Send to DAO wallet
                        </button>
                      </div>
                    )
                  })}
                </div>
                <TxLine state={sweep.state} />
              </div>
            )}

            <BrandingEditor operator={address!} />
          </div>
        )}
      </main>
      <Footer vault={vault} />
    </>
  )
}
