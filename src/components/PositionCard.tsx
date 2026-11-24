import { useEffect, useRef, useState } from 'react'
import { useAccount } from 'wagmi'
import { vaultAbi } from '../abi/vault'
import { useBranding } from '../hooks/useBranding'
import { useTx } from '../hooks/useTx'
import type { PositionView } from '../hooks/useVault'
import { DAY, ELDER_DAYS, MAX_LOCK_DAYS, MIN_LOCK_DAYS, POOLS, vaultAddress, type PoolId } from '../lib/config'
import { fmtDate, fmtPct, fmtSpan, fmtToken, fmtUsd, toNumber } from '../lib/format'
import { elderProgress, lockMultiplier, slashAmount, slashFraction } from '../lib/math'
import { gsap, reducedMotion } from '../lib/motion'
import { LockSlider } from './LockSlider'
import { SlashCurve } from './SlashCurve'
import { TxLine } from './Bits'
import { WithdrawDialog } from './WithdrawDialog'

export function PositionCard({ pool, position, now, closed = false }: { pool: PoolId; position: PositionView; now: number; closed?: boolean }) {
  const { t } = useBranding()
  const { address } = useAccount()
  const tx = useTx()
  const symbol = POOLS[pool].symbol
  const [relockOpen, setRelockOpen] = useState(false)
  const [withdrawOpen, setWithdrawOpen] = useState(false)
  const track = useRef<HTMLElement>(null)

  const lockStart = Number(position.lockStart)
  const lockEnd = Number(position.lockEnd)
  const locked = now < lockEnd
  const fraction = slashFraction(lockStart, lockEnd, now)
  const loss = slashAmount(position.amount, lockStart, lockEnd, now)
  const lockProgress = lockEnd > lockStart ? (now - lockStart) / (lockEnd - lockStart) : 1

  // Days staked only count while locked; tick locally between chain refreshes.
  const staked = Number(position.stakedSeconds)
  const progress = elderProgress(staked)
  const boost = toNumber(position.boostWad)
  const lockDays = Math.round(Number(position.lockDuration) / DAY)
  const hasEarned = position.earned > 0n
  const elderAt = Number(position.elderAt)
  const waitingForSeat = locked && !position.elder && staked >= ELDER_DAYS * DAY

  // A relock may not end before the current lock does.
  const relockFloor = locked ? Math.min(MAX_LOCK_DAYS, Math.max(MIN_LOCK_DAYS, Math.ceil((lockEnd - now) / DAY))) : MIN_LOCK_DAYS
  const [relockDays, setRelockDays] = useState(Math.max(relockFloor, 365))
  useEffect(() => {
    setRelockDays((d) => Math.max(d, relockFloor))
  }, [relockFloor])

  useEffect(() => {
    if (!track.current) return
    if (reducedMotion()) gsap.set(track.current, { scaleX: progress })
    else gsap.to(track.current, { scaleX: progress, duration: 2.4, ease: 'power3.out' })
  }, [progress])

  const call = (label: string, functionName: 'claim' | 'withdraw' | 'relock' | 'sync', args: readonly unknown[]) =>
    vaultAddress ? tx.run(label, { address: vaultAddress, abi: vaultAbi, functionName, args }) : Promise.resolve(false)

  if (closed) {
    return (
      <article className="glass pad" data-reveal>
        <div className="eyebrow">{symbol} pool · position closed</div>
        <div className="earn" style={{ marginTop: 16 }}>
          <div>
            <div className="k">Still yours to claim</div>
            <div className="v">{fmtToken(position.earned, symbol, 6)}</div>
          </div>
          <button className="btn sm primary" disabled={tx.busy} onClick={() => call('Claim', 'claim', [pool])}>
            {t('positions.claim')}
          </button>
        </div>
        <TxLine state={tx.state} />
      </article>
    )
  }

  return (
    <article className="glass shine pad" data-reveal>
      <div className="pos-head">
        <div>
          <div className="eyebrow">{symbol} pool</div>
          <div className="pos-amt" style={{ marginTop: 10 }}>
            {fmtToken(position.amount)}
            <small>{symbol}</small>
          </div>
          <div className="hint" style={{ marginTop: 4 }}>
            {fmtUsd(toNumber(position.grossUsd))} at deposit, before the fee
          </div>
        </div>
        <div className="chips" style={{ justifyContent: 'flex-end' }}>
          {position.elder ? (
            <span className="chip gold">
              <span className="dot" />
              1,024-day whale
            </span>
          ) : locked ? (
            <span className="chip on">
              <span className="dot" />
              Locked
            </span>
          ) : (
            <span className="chip">Unlocked · not earning</span>
          )}
        </div>
      </div>

      <div className="pos-grid">
        <div className={`stat ${locked ? 'hot' : 'cool'}`}>
          <div className="k">Leaving now costs</div>
          <div className={`v ${locked ? 'danger' : 'ok'}`}>{locked ? fmtPct(fraction, 3) : '0%'}</div>
          <div className="s">{locked ? `−${fmtToken(loss, symbol)}` : 'Lock is over. Walk out clean.'}</div>
        </div>
        <div className="stat">
          <div className="k">{locked ? 'Unlocks' : 'Unlocked since'}</div>
          <div className="v">{fmtDate(lockEnd)}</div>
          <div className="s">{locked ? `in ${fmtSpan(lockEnd - now)}` : 'Relock to start earning again'}</div>
        </div>
        <div className="stat">
          <div className="k">Lock weight</div>
          <div className="v">×{lockMultiplier(lockDays).toFixed(1)}</div>
          <div className="s">{lockDays.toLocaleString('en-US')}-day lock</div>
        </div>
        <div className="stat">
          <div className="k">Minimum-raise boost</div>
          <div className="v">×{boost.toFixed(boost >= 10 ? 1 : 2)}</div>
          <div className="s">{boost > 1 ? 'Stacked. Never goes down.' : 'Grows when the minimum is raised'}</div>
        </div>
      </div>

      {locked && <SlashCurve progress={lockProgress} unlockLabel={fmtDate(lockEnd)} />}

      <div className="progress">
        <div className="progress-head">
          <span>Road to 1,024 days</span>
          <span className="mono">
            {Math.floor(staked / DAY).toLocaleString('en-US')} / 1,024 · {fmtPct(progress, 1)}
          </span>
        </div>
        <div className="track" role="progressbar" aria-valuemin={0} aria-valuemax={ELDER_DAYS} aria-valuenow={Math.floor(staked / DAY)}>
          <i ref={track} style={{ transform: 'scaleX(0)' }} />
        </div>
        <div className="hint" style={{ marginTop: 10 }}>
          {position.elder
            ? 'You split 80% of every slash in this pool with the other 1,024-day whales.'
            : waitingForSeat
              ? `1,024 days done. Your seat in the 80% pot opens ${fmtDate(elderAt)}.`
              : locked
                ? `${fmtSpan(ELDER_DAYS * DAY - staked)} of locked time to go. Only locked days count.`
                : 'Paused. Days only count while you are locked.'}
        </div>
      </div>

      <div className="earn">
        <div>
          <div className="k">Earned from other people leaving</div>
          <div className="v">{fmtToken(position.earned, symbol, 6)}</div>
        </div>
        <button className={`btn sm ${hasEarned ? 'primary' : ''}`} disabled={!hasEarned || tx.busy} onClick={() => call('Claim', 'claim', [pool])}>
          {hasEarned ? t('positions.claim') : 'Nothing yet'}
        </button>
      </div>

      {position.needsSync && (
        <div className="notice warn">
          <span>{position.elder ? 'You crossed 1,024 days. Take your seat in the 80% pot.' : 'A minimum raise boosted your weight. Lock it in.'}</span>
          <button className="btn sm" disabled={tx.busy} onClick={() => call('Sync', 'sync', [address, pool])}>
            Apply now
          </button>
        </div>
      )}
      {!locked && (
        <div className="notice">
          <span>Your lock ended. You earn nothing until you relock, and the longer you wait the more time weight you give up.</span>
        </div>
      )}
      {locked && lockEnd - now < 14 * DAY && (
        <div className="notice warn">
          <span>
            Unlocks in {fmtSpan(lockEnd - now)}. Relock before then to keep your time weight{staked >= ELDER_DAYS * DAY ? ' and your elder seat' : ''}.
          </span>
        </div>
      )}

      <div className="actions">
        <button className={`btn sm ${!locked ? 'primary' : ''}`} onClick={() => setRelockOpen((v) => !v)} aria-expanded={relockOpen}>
          {relockOpen ? 'Close' : t('positions.relock')}
        </button>
        {/* Leaving early is deliberately the quietest control on the card. */}
        <button className={`btn sm ${locked ? 'quiet' : ''}`} onClick={() => setWithdrawOpen(true)}>
          {locked ? t('positions.withdrawEarly') : t('positions.withdraw')}
        </button>
      </div>

      {relockOpen && (
        <div className="relock">
          <LockSlider days={relockDays} onChange={setRelockDays} min={relockFloor} disabled={tx.busy} />
          <p className="hint" style={{ margin: '14px 0' }}>
            New unlock: {fmtDate(Math.ceil((now + relockDays * DAY) / DAY) * DAY)}. Your {Math.floor(staked / DAY).toLocaleString('en-US')} days carry over.{' '}
            <span className="danger">The exit price goes back to 100% and counts down again.</span>
          </p>
          <button
            className="btn primary block"
            disabled={tx.busy}
            onClick={async () => (await call('Relock', 'relock', [pool, BigInt(relockDays * DAY)])) && setRelockOpen(false)}
          >
            Relock for {relockDays.toLocaleString('en-US')} days
          </button>
        </div>
      )}
      <TxLine state={tx.state} />

      {withdrawOpen && (
        <WithdrawDialog
          position={position}
          symbol={symbol}
          now={now}
          busy={tx.busy}
          onClose={() => setWithdrawOpen(false)}
          onConfirm={async () => {
            await call('Withdraw', 'withdraw', [pool])
            setWithdrawOpen(false)
          }}
        />
      )}
    </article>
  )
}
