import { useRef } from 'react'
import gsap from 'gsap'
import { ScrollTrigger } from 'gsap/ScrollTrigger'
import { useGSAP } from '@gsap/react'

gsap.registerPlugin(ScrollTrigger, useGSAP)
// House style: slow, soft, transform and opacity only.
gsap.defaults({ ease: 'power2.out', duration: 1.6 })

export { gsap, useGSAP, ScrollTrigger }

export const reducedMotion = () =>
  typeof window !== 'undefined' && window.matchMedia('(prefers-reduced-motion: reduce)').matches

/** Children marked data-reveal rise and fade in, slowly, once, as the block scrolls into view. */
export function useReveal<T extends HTMLElement>() {
  const ref = useRef<T>(null)
  useGSAP(
    () => {
      if (reducedMotion()) return
      const items = gsap.utils.toArray<HTMLElement>('[data-reveal]', ref.current)
      if (!items.length) return
      gsap.set(items, { opacity: 0, y: 28 })
      ScrollTrigger.batch(items, {
        start: 'top 88%',
        once: true,
        onEnter: (batch) => gsap.to(batch, { opacity: 1, y: 0, duration: 1.8, stagger: 0.16, ease: 'power3.out', overwrite: true }),
      })
    },
    { scope: ref },
  )
  return ref
}
