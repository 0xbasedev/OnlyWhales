import { useRef } from 'react'
import { useAccount } from 'wagmi'
import { useBranding } from '../hooks/useBranding'
import type { VaultState } from '../hooks/useVault'
import { fmtUsd, toNumber } from '../lib/format'
import { gsap, reducedMotion, useGSAP } from '../lib/motion'
import { ConnectButton } from './ConnectButton'
import { Glide } from './Bits'

/** The last two words of the tagline get the italic treatment. */
function Tagline({ text }: { text: string }) {
  const words = text.split(' ')
  const accentFrom = Math.max(0, words.length - 2)
  return (
    <h1 aria-label={text}>
      {words.map((w, i) => (
        <span key={i} aria-hidden>
          <span className="w">{i >= accentFrom ? <em>{w}</em> : w}</span>{' '}
        </span>
      ))}
    </h1>
  )
}

export function Hero({ vault }: { vault: VaultState }) {
  const { t } = useBranding()
  const { isConnected } = useAccount()
  const ref = useRef<HTMLElement>(null)

  useGSAP(
    () => {
      if (reducedMotion()) return
      const tl = gsap.timeline({ defaults: { ease: 'power3.out' }, delay: 0.25 })
      tl.from('.eyebrow', { opacity: 0, y: 14, duration: 1.6 })
        .from('.hero h1 .w', { opacity: 0, y: 46, duration: 2.2, stagger: 0.16 }, '-=1.1')
        .from('.hero-sub', { opacity: 0, y: 18, duration: 1.8 }, '-=1.5')
        .from('.hero-cta > *', { opacity: 0, y: 14, duration: 1.6, stagger: 0.18, clearProps: 'transform' }, '-=1.3')
        .from('.ledger', { opacity: 0, y: 26, duration: 2 }, '-=1.2')
    },
    { scope: ref, dependencies: [t('hero.tagline')] },
  )

  const usdc = vault.pools[0] ? toNumber(vault.pools[0].totalPrincipal) : 0
  const bnb = vault.pools[1] ? toNumber(vault.pools[1].totalPrincipal) : 0

  return (
    <section className="hero wrap" ref={ref}>
      <div className="eyebrow">{t('hero.eyebrow')}</div>
      <Tagline text={t('hero.tagline')} />
      <p className="hero-sub">{t('hero.subline')}</p>
      <div className="hero-cta">
        {isConnected ? (
          <a className="btn primary" href="#pool">
            {t('hero.ctaConnected')}
          </a>
        ) : (
          <ConnectButton primary text={t('hero.cta')} />
        )}
        <a className="btn quiet" href="#rules">
          {t('hero.secondary')}
        </a>
      </div>

      <div className="ledger glass">
        <div>
          <div className="k">USDC in the pool</div>
          <div className="v">
            <Glide value={usdc} format={(n) => Math.round(n).toLocaleString('en-US')} />
            <small>USDC</small>
          </div>
        </div>
        <div>
          <div className="k">BNB in the pool</div>
          <div className="v">
            <Glide value={bnb} format={(n) => n.toLocaleString('en-US', { maximumFractionDigits: 2 })} />
            <small>BNB</small>
          </div>
        </div>
        <div>
          <div className="k">Entry, per wallet</div>
          <div className="v">
            {fmtUsd(vault.minUsd)}
            <small>to {fmtUsd(vault.maxUsd)}</small>
          </div>
        </div>
        <div>
          <div className="k">Deposit fee</div>
          <div className="v">
            {(vault.feeBps / 100).toString()}%<small>buys the pass</small>
          </div>
        </div>
      </div>
    </section>
  )
}
