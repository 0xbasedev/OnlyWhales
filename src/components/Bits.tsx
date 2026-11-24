import { useEffect, useRef, type ReactNode } from 'react'
import { gsap, reducedMotion } from '../lib/motion'
import { useBranding } from '../hooks/useBranding'
import { txMessage, type TxState } from '../hooks/useTx'

/** A number that glides to its new value instead of snapping. */
export function Glide({ value, format, duration = 1.6 }: { value: number; format: (n: number) => string; duration?: number }) {
  const ref = useRef<HTMLSpanElement>(null)
  const shown = useRef({ n: value })
  const fmt = useRef(format)
  fmt.current = format

  useEffect(() => {
    const el = ref.current
    if (!el) return
    if (reducedMotion() || !Number.isFinite(value)) {
      shown.current.n = value
      el.textContent = fmt.current(value)
      return
    }
    const tween = gsap.to(shown.current, {
      n: value,
      duration,
      ease: 'power2.out',
      onUpdate: () => {
        el.textContent = fmt.current(shown.current.n)
      },
    })
    return () => void tween.kill()
  }, [value, duration])

  return <span ref={ref}>{format(shown.current.n)}</span>
}

export function Mark({ size = 28 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" fill="none" aria-hidden>
      <rect width="64" height="64" rx="16" fill="#08131b" />
      <path
        d="M32 46c0-7-1.4-11.6-8.6-15.8C17 26.4 10.6 27 6.4 30.2c5.8 0 10.6 2.6 14.2 7C24.4 42 28.6 44 32 46Zm0 0c0-7 1.4-11.6 8.6-15.8C47 26.4 53.4 27 57.6 30.2c-5.8 0-10.6 2.6-14.2 7C39.6 42 35.4 44 32 46Z"
        fill="#8fe3f5"
      />
      <path d="M14 52c6-3 12-3 18 0s12 3 18 0" stroke="#8fe3f5" strokeOpacity=".45" strokeWidth="2.4" strokeLinecap="round" />
    </svg>
  )
}

export function Logo() {
  const { branding } = useBranding()
  return branding.logo ? <img src={branding.logo} alt="" /> : <Mark />
}

export function TxLine({ state }: { state: TxState }) {
  const { text, tone } = txMessage(state)
  return (
    <div className={`status ${tone}`} role="status" aria-live="polite">
      {text}
    </div>
  )
}

export function Row({ k, note, children }: { k: string; note?: string; children: ReactNode }) {
  return (
    <div className="row">
      <span className="k">
        {k} {note && <i>{note}</i>}
      </span>
      <span className="v">{children}</span>
    </div>
  )
}
