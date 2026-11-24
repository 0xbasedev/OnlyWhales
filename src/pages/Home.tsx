import { useBranding } from '../hooks/useBranding'
import { useNow } from '../hooks/useNow'
import { useVault, useWallet } from '../hooks/useVault'
import { useReveal } from '../lib/motion'
import { AccessCard } from '../components/AccessCard'
import { DepositPanel } from '../components/DepositPanel'
import { Footer } from '../components/Footer'
import { Hero } from '../components/Hero'
import { Nav } from '../components/Nav'
import { PositionCard } from '../components/PositionCard'
import { Rules } from '../components/Rules'
import type { PoolId } from '../lib/config'

export function Home() {
  const { t } = useBranding()
  const vault = useVault()
  const wallet = useWallet(vault.usdc)
  const now = useNow()
  const poolRef = useReveal<HTMLElement>()
  const open = ([0, 1] as PoolId[]).filter((id) => (wallet.positions[id]?.amount ?? 0n) > 0n)
  // Earnings stay claimable after a position is closed.
  const leftovers = ([0, 1] as PoolId[]).filter((id) => !open.includes(id) && (wallet.positions[id]?.earned ?? 0n) > 0n)

  return (
    <>
      <Nav vault={vault} />
      {!vault.live && (
        <div className="banner" role="status" style={{ position: 'absolute', top: 96, left: 0, right: 0, zIndex: 5 }}>
          <span className="dot" /> {t('prelaunch.banner')}
        </div>
      )}
      <main>
        <Hero vault={vault} />
        <Rules vault={vault} />

        <section className="section wrap" id="pool" ref={poolRef}>
          <div className="section-head" data-reveal>
            <div className="eyebrow">The pool</div>
            <h2>{t('positions.title')}</h2>
          </div>
          <div className="pool-grid">
            <DepositPanel vault={vault} wallet={wallet} />
            <div className="stack">
              {open.map((id) => (
                <PositionCard key={id} pool={id} position={wallet.positions[id]!} now={now} />
              ))}
              {leftovers.map((id) => (
                <PositionCard key={`left-${id}`} pool={id} position={wallet.positions[id]!} now={now} closed />
              ))}
              {open.length === 0 && leftovers.length === 0 && (
                <div className="glass pad empty" data-reveal>
                  <div className="big">{wallet.isConnected ? t('positions.empty') : 'Connect a wallet to see your water.'}</div>
                  <div>One position per pool. USDC and BNB never mix.</div>
                </div>
              )}
            </div>
          </div>
        </section>

        <AccessCard wallet={wallet} />
      </main>
      <Footer vault={vault} />
    </>
  )
}
