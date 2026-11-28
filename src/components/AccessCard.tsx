import { useState } from 'react'
import { useSignMessage } from 'wagmi'
import { accessMessage } from '../../shared/messages'
import { useBranding } from '../hooks/useBranding'
import type { WalletState } from '../hooks/useVault'
import { chain, vaultAddress } from '../lib/config'
import { explainError } from '../lib/errors'
import { TIER_NAMES } from '../lib/math'
import { useReveal } from '../lib/motion'

type State = { phase: 'idle' | 'signing' | 'checking' } | { phase: 'open'; invite: string } | { phase: 'error'; error: string }

export function AccessCard({ wallet }: { wallet: WalletState }) {
  const { t } = useBranding()
  const ref = useReveal<HTMLElement>()
  const { signMessageAsync } = useSignMessage()
  const [state, setState] = useState<State>({ phase: 'idle' })

  const tier = wallet.passTier ?? 0
  const busy = state.phase === 'signing' || state.phase === 'checking'

  const open = async () => {
    if (!wallet.address || !vaultAddress) return
    try {
      setState({ phase: 'signing' })
      const timestamp = Math.floor(Date.now() / 1000)
      const message = accessMessage({ wallet: wallet.address, vault: vaultAddress, chainId: chain.id, timestamp })
      const signature = await signMessageAsync({ message })
      setState({ phase: 'checking' })
      const res = await fetch('/api/access', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ wallet: wallet.address, timestamp, signature }),
      })
      const json = (await res.json().catch(() => ({}))) as { invite?: string; error?: string }
      if (!res.ok || !json.invite) throw new Error(json.error || 'The gate did not answer.')
      // Kept in memory only. Reload the page and it is gone.
      setState({ phase: 'open', invite: json.invite })
    } catch (err) {
      setState({ phase: 'error', error: explainError(err) })
    }
  }

  return (
    <section className="section wrap" id="access" ref={ref}>
      <div className="glass pad access" data-reveal>
        <img className={`pass-art ${wallet.hasPass ? '' : 'off'}`} src={`/pass/tier-${tier + 1}.svg`} alt={`Pass artwork, tier ${tier + 1}`} />
        <div>
          <div className="eyebrow">Soulbound pass{wallet.hasPass ? ` · Tier ${tier + 1} · ${TIER_NAMES[tier]}` : ''}</div>
          <h2 className="panel-title" style={{ marginTop: 12 }}>
            {t('access.title')}
          </h2>
          <p className="panel-lead">{t('access.lead')}</p>

          <div className="checks">
            <div>
              <span className={`tick ${wallet.hasPass ? 'yes' : ''}`}>{wallet.hasPass ? '✓' : ''}</span>
              Pass in this wallet. Minted with your first deposit. Cannot be sold, sent or lent.
            </div>
            <div>
              <span className={`tick ${wallet.hasPosition ? 'yes' : ''}`}>{wallet.hasPosition ? '✓' : ''}</span>
              Open position in either pool.
            </div>
          </div>

          {state.phase === 'open' ? (
            <div className="invite">
              {/* A bot link carries a one-time code. Telling the whale what happens next beats showing it. */}
              {state.invite.includes('?start=') ? <span>Opens our bot. Tap Start and it lets you in.</span> : <code>{state.invite}</code>}
              <a className="btn sm primary" href={state.invite} target="_blank" rel="noreferrer noopener">
                Open Telegram
              </a>
            </div>
          ) : (
            <button className="btn primary" disabled={!wallet.hasAccess || busy} onClick={open}>
              {state.phase === 'signing' ? 'Sign in your wallet…' : state.phase === 'checking' ? 'Checking the chain…' : wallet.hasAccess ? t('access.cta') : 'Door is closed'}
            </button>
          )}
          <p className={`hint ${state.phase === 'error' ? 'bad' : ''}`} style={{ marginTop: 14 }} role="status">
            {state.phase === 'error' ? state.error : wallet.hasAccess ? t('access.note') : t('access.locked')}
          </p>
        </div>
      </div>
    </section>
  )
}
