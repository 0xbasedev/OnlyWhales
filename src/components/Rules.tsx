import { useBranding } from '../hooks/useBranding'
import type { VaultState } from '../hooks/useVault'
import { fmtUsd } from '../lib/format'
import { useReveal } from '../lib/motion'
import { SlashCurve } from './SlashCurve'

export function Rules({ vault }: { vault: VaultState }) {
  const { t } = useBranding()
  // {min}, {max} and {fee} in the copy always show the live on-chain values.
  const live = (text: string) =>
    text.replaceAll('{min}', fmtUsd(vault.minUsd)).replaceAll('{max}', fmtUsd(vault.maxUsd)).replaceAll('{fee}', `${vault.feeBps / 100}%`)
  const ref = useReveal<HTMLElement>()
  return (
    <section className="section wrap" id="rules" ref={ref}>
      <div className="section-head" data-reveal>
        <div className="eyebrow">The rules</div>
        <h2>{t('rules.title')}</h2>
        <p>{t('rules.lead')}</p>
      </div>

      <div className="rules">
        {[1, 2, 3].map((n) => (
          <article key={n} className="rule glass shine pad" data-reveal>
            <div className="n">{String(n).padStart(2, '0')}</div>
            <h3>{t(`rules.${n}.title`)}</h3>
            <p>{live(t(`rules.${n}.body`))}</p>
          </article>
        ))}
      </div>

      <div className="split">
        <div className="glass pad" data-reveal>
          <h3>What leaving early costs</h3>
          <p className="bar-note">A straight line from everything to 30%. Then nothing.</p>
          <SlashCurve />
        </div>
        <div className="glass pad" data-reveal>
          <h3>Where a slash goes</h3>
          <p className="bar-note">Until someone has 1,024 days:</p>
          <div className="bar" aria-label="72% to stakers, 28% to the DAO">
            <span className="whales" style={{ width: '72%' }}>
              72% stakers
            </span>
            <span className="dao" style={{ width: '28%' }}>
              28% DAO
            </span>
          </div>
          <p className="bar-note">Weighted by days staked × amount × lock length. After the first whale crosses 1,024 days:</p>
          <div className="bar" aria-label="80% to 1024-day whales, 20% to the DAO">
            <span className="whales" style={{ width: '80%', background: 'linear-gradient(180deg,#f3e2b8,#e8cc92)' }}>
              80% to the 1,024-day whales
            </span>
            <span className="dao" style={{ width: '20%' }}>
              20% DAO
            </span>
          </div>
          <p className="bar-note">What you earn is never slashed and you can claim it any time.</p>
        </div>
      </div>
    </section>
  )
}
