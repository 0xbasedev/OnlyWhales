import { useRef } from 'react'
import { ELDER_DAYS, MAX_LOCK_DAYS, MIN_LOCK_DAYS } from '../lib/config'
import { lockMultiplier } from '../lib/math'
import { gsap, reducedMotion } from '../lib/motion'
import { Glide } from './Bits'

const PRESETS = [30, 90, 180, 365, 730, 1024]

export function LockSlider({
  days,
  onChange,
  min = MIN_LOCK_DAYS,
  disabled,
}: {
  days: number
  onChange: (days: number) => void
  /** Relocks cannot end before the current lock, so the floor moves up. */
  min?: number
  disabled?: boolean
}) {
  const proxy = useRef({ d: days })
  const fill = ((days - min) / Math.max(1, MAX_LOCK_DAYS - min)) * 100

  // Presets travel there slowly instead of jumping.
  const glideTo = (target: number) => {
    gsap.killTweensOf(proxy.current)
    if (reducedMotion()) return onChange(target)
    proxy.current.d = days
    gsap.to(proxy.current, { d: target, duration: 1.4, ease: 'power2.inOut', onUpdate: () => onChange(Math.round(proxy.current.d)) })
  }

  return (
    <div>
      <div className="lock-read">
        <div className="days">
          {days.toLocaleString('en-US')}
          <small>days locked</small>
        </div>
        <div className="mult">
          <b>
            ×<Glide value={lockMultiplier(days)} format={(n) => n.toFixed(1)} duration={1.2} />
          </b>
          <span>weight vs a 30-day lock</span>
        </div>
      </div>
      <input
        className="range"
        type="range"
        min={min}
        max={MAX_LOCK_DAYS}
        step={1}
        value={days}
        disabled={disabled}
        aria-label="Lock length in days"
        style={{ ['--fill' as string]: `${fill}%` }}
        onChange={(e) => {
          gsap.killTweensOf(proxy.current)
          onChange(Number(e.target.value))
        }}
      />
      <div className="field-foot">
        <div className="chips">
          {PRESETS.filter((p) => p >= min).map((p) => (
            <button key={p} type="button" className={`chip ${days === p ? (p === ELDER_DAYS ? 'gold' : 'on') : ''}`} disabled={disabled} onClick={() => glideTo(p)}>
              {p === ELDER_DAYS ? '1,024 · max' : `${p}d`}
            </button>
          ))}
        </div>
      </div>
    </div>
  )
}
