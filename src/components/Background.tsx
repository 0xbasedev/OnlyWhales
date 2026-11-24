import { useRef } from 'react'
import { gsap, reducedMotion, useGSAP } from '../lib/motion'

/** Deep water: three slow lights and a surface line. Transform-only, half a minute per drift. */
export function Background() {
  const ref = useRef<HTMLDivElement>(null)
  useGSAP(
    () => {
      if (reducedMotion()) return
      gsap.to('.bg-orb.a', { xPercent: 10, yPercent: 8, duration: 34, ease: 'sine.inOut', yoyo: true, repeat: -1 })
      gsap.to('.bg-orb.b', { xPercent: -12, yPercent: -6, duration: 41, ease: 'sine.inOut', yoyo: true, repeat: -1 })
      gsap.to('.bg-orb.c', { xPercent: 6, yPercent: -10, duration: 47, ease: 'sine.inOut', yoyo: true, repeat: -1 })
      gsap.to('.bg-waves', { xPercent: -50, duration: 90, ease: 'none', repeat: -1 })
    },
    { scope: ref },
  )
  const wave = (y: number, amp: number) => {
    let d = `M0 ${y}`
    for (let x = 0; x < 2400; x += 300) d += ` q75 ${-amp} 150 0 t150 0`
    return d
  }
  return (
    <div className="bg" ref={ref} aria-hidden>
      <div className="bg-orb a" />
      <div className="bg-orb b" />
      <div className="bg-orb c" />
      <svg className="bg-waves" viewBox="0 0 2400 400" preserveAspectRatio="none">
        <path d={wave(120, 14)} fill="none" stroke="rgba(143,227,245,.16)" strokeWidth="1" />
        <path d={wave(190, 20)} fill="none" stroke="rgba(143,227,245,.09)" strokeWidth="1" />
        <path d={wave(280, 26)} fill="none" stroke="rgba(143,227,245,.05)" strokeWidth="1" />
      </svg>
      <div className="bg-grain" />
      <div className="bg-vignette" />
    </div>
  )
}
