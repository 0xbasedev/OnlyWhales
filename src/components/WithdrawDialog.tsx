import { useEffect, useRef } from 'react'
import { createPortal } from 'react-dom'
import { useBranding } from '../hooks/useBranding'
import type { PositionView } from '../hooks/useVault'
import { fmtDate, fmtPct, fmtSpan, fmtToken } from '../lib/format'
import { slashAmount, slashFraction } from '../lib/math'
import { gsap, reducedMotion } from '../lib/motion'

const HOLD_SECONDS = 3

/**
 * Leaving early is the one irreversible mistake this app allows, so the dialog is built to slow
 * it down: the exact loss is the biggest thing on screen, staying is the bright button, and
 * leaving takes a three-second hold.
 */
export function WithdrawDialog({
  position,
  symbol,
  now,
  busy,
  onConfirm,
  onClose,
}: {
  position: PositionView
  symbol: string
  now: number
  busy: boolean
  onConfirm: () => void
  onClose: () => void
}) {
  const { t } = useBranding()
  const scrim = useRef<HTMLDivElement>(null)
  const card = useRef<HTMLDivElement>(null)
  const fill = useRef<HTMLElement>(null)
  const hold = useRef<gsap.core.Tween | null>(null)

  const lockStart = Number(position.lockStart)
  const lockEnd = Number(position.lockEnd)
  const locked = now < lockEnd
  const loss = slashAmount(position.amount, lockStart, lockEnd, now)
  const receive = position.amount - loss
  const fraction = slashFraction(lockStart, lockEnd, now)

  // The card re-renders every second for the live numbers; the entrance must run only once.
  const close = useRef(onClose)
  close.current = onClose
  const confirm = useRef(onConfirm)
  confirm.current = onConfirm

  useEffect(() => {
    if (!reducedMotion()) {
      gsap.fromTo(scrim.current, { opacity: 0 }, { opacity: 1, duration: 0.9, ease: 'power2.out' })
      gsap.fromTo(card.current, { opacity: 0, y: 26, scale: 0.985 }, { opacity: 1, y: 0, scale: 1, duration: 1.1, ease: 'power3.out' })
    }
    const esc = (e: KeyboardEvent) => e.key === 'Escape' && close.current()
    document.addEventListener('keydown', esc)
    const prev = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      document.removeEventListener('keydown', esc)
      document.body.style.overflow = prev
    }
  }, [])

  const press = () => {
    if (busy || !fill.current) return
    hold.current?.kill()
    hold.current = gsap.to(fill.current, { scaleX: 1, duration: HOLD_SECONDS, ease: 'none', onComplete: () => confirm.current() })
  }
  const release = () => {
    if (!fill.current || (hold.current && hold.current.progress() === 1)) return
    hold.current?.kill()
    hold.current = gsap.to(fill.current, { scaleX: 0, duration: 0.9, ease: 'power2.out' })
  }

  return createPortal(
    <div className="scrim" ref={scrim} onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal glass" ref={card} role="dialog" aria-modal="true" aria-labelledby="wd-title">
        {locked ? (
          <>
            <h3 id="wd-title">{t('withdraw.title')}</h3>
            <p className="muted" style={{ marginTop: 10 }}>
              {t('withdraw.body')}
            </p>
            <div className="loss">
              <div className="k">You lose, right now ({fmtPct(fraction)})</div>
              <div className="v">−{fmtToken(loss, symbol)}</div>
            </div>
            <div className="rows" style={{ marginTop: 14 }}>
              <div className="row">
                <span className="k">Your position</span>
                <span className="v">{fmtToken(position.amount, symbol, 6)}</span>
              </div>
              <div className="row">
                <span className="k">You walk away with</span>
                <span className="v">{fmtToken(receive, symbol, 6)}</span>
              </div>
              <div className="row">
                <span className="k">Wait {fmtSpan(lockEnd - now)}</span>
                <span className="v ok">lose nothing on {fmtDate(lockEnd)}</span>
              </div>
            </div>
            <div className="modal-actions">
              <button className="btn primary block" onClick={onClose} autoFocus>
                {t('withdraw.cancel')}
              </button>
              <button
                className="btn danger block hold"
                disabled={busy}
                onPointerDown={press}
                onPointerUp={release}
                onPointerLeave={release}
                onKeyDown={(e) => (e.key === ' ' || e.key === 'Enter') && !e.repeat && press()}
                onKeyUp={release}
                aria-label={`${t('withdraw.confirm')}: hold for ${HOLD_SECONDS} seconds to lose ${fmtToken(loss, symbol, 6)}`}
              >
                <i ref={fill} />
                {busy ? 'Leaving…' : `${t('withdraw.confirm')} · −${fmtToken(loss, symbol)}`}
              </button>
            </div>
          </>
        ) : (
          <>
            <h3 id="wd-title">{t('withdraw.safeTitle')}</h3>
            <p className="muted" style={{ marginTop: 10 }}>
              {t('withdraw.safeBody')}
            </p>
            <div className="rows" style={{ marginTop: 22 }}>
              <div className="row">
                <span className="k">Slash</span>
                <span className="v ok">0%</span>
              </div>
              <div className="row">
                <span className="k">You receive</span>
                <span className="v">{fmtToken(position.amount, symbol, 6)}</span>
              </div>
            </div>
            <div className="modal-actions">
              <button className="btn primary block" disabled={busy} onClick={onConfirm} autoFocus>
                {busy ? 'Withdrawing…' : `Withdraw ${fmtToken(position.amount, symbol)}`}
              </button>
              <button className="btn quiet block" onClick={onClose}>
                Not yet
              </button>
            </div>
          </>
        )}
      </div>
    </div>,
    document.body,
  )
}
