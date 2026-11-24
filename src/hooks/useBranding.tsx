import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { defaultBranding, mergeBranding, type Branding } from '../../shared/branding'

type Ctx = { branding: Branding; /** What is published, ignoring any live preview. */ saved: Branding; t: (key: string) => string; refresh: () => Promise<void>; preview: (b: Branding | null) => void }

const BrandingContext = createContext<Ctx>({
  branding: defaultBranding,
  saved: defaultBranding,
  t: (key) => defaultBranding.copy[key] ?? key,
  refresh: async () => {},
  preview: () => {},
})

export function BrandingProvider({ children }: { children: ReactNode }) {
  const [saved, setSaved] = useState<Branding>(defaultBranding)
  const [draft, setDraft] = useState<Branding | null>(null)

  const refresh = useCallback(async () => {
    try {
      const res = await fetch('/api/branding', { headers: { accept: 'application/json' } })
      if (!res.ok) return
      const json = (await res.json()) as { branding: Partial<Branding> | null }
      setSaved(mergeBranding(json.branding))
    } catch {
      // No API (static hosting): the defaults in config/prelaunch.json stand.
    }
  }, [])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const branding = draft ?? saved

  useEffect(() => {
    document.title = branding.siteTitle
    const icon = document.querySelector<HTMLLinkElement>('link[rel="icon"]')
    if (icon) icon.href = branding.favicon || '/favicon.svg'
  }, [branding.siteTitle, branding.favicon])

  const value = useMemo<Ctx>(
    () => ({ branding, saved, t: (key) => branding.copy[key] ?? defaultBranding.copy[key] ?? key, refresh, preview: setDraft }),
    [branding, saved, refresh],
  )
  return <BrandingContext.Provider value={value}>{children}</BrandingContext.Provider>
}

export const useBranding = () => useContext(BrandingContext)
