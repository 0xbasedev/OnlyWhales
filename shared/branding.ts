import prelaunch from '../config/prelaunch.json' with { type: 'json' }

export type Branding = {
  siteTitle: string
  logo: string | null
  favicon: string | null
  copy: Record<string, string>
}

export const defaultBranding: Branding = prelaunch.branding as Branding
export const copyKeys = Object.keys(defaultBranding.copy)

export const LIMITS = {
  siteTitle: 80,
  copy: 600,
  image: 400_000, // characters of data URL, roughly 300 KB of image
  payload: 1_500_000,
}

const IMAGE_DATA_URL = /^data:image\/(png|jpeg|webp|gif|svg\+xml|x-icon|vnd\.microsoft\.icon);base64,[A-Za-z0-9+/=]+$/

/** Validates an operator-submitted branding object. Returns a clean copy or an error string. */
export function sanitizeBranding(input: unknown): { ok: true; value: Branding } | { ok: false; error: string } {
  if (!input || typeof input !== 'object') return { ok: false, error: 'Branding must be an object.' }
  const raw = input as Record<string, unknown>

  const siteTitle = typeof raw.siteTitle === 'string' ? raw.siteTitle.trim() : ''
  if (!siteTitle || siteTitle.length > LIMITS.siteTitle) {
    return { ok: false, error: `Site title must be 1-${LIMITS.siteTitle} characters.` }
  }

  const images: Record<'logo' | 'favicon', string | null> = { logo: null, favicon: null }
  for (const key of ['logo', 'favicon'] as const) {
    const v = raw[key]
    if (v == null || v === '') continue
    if (typeof v !== 'string' || v.length > LIMITS.image || !IMAGE_DATA_URL.test(v)) {
      return { ok: false, error: `${key} must be a PNG, JPEG, WebP, GIF, SVG or ICO under 300 KB.` }
    }
    images[key] = v
  }

  const copy: Record<string, string> = {}
  const rawCopy = (raw.copy && typeof raw.copy === 'object' ? raw.copy : {}) as Record<string, unknown>
  for (const key of copyKeys) {
    const v = rawCopy[key]
    if (v == null) continue
    if (typeof v !== 'string' || v.length > LIMITS.copy) {
      return { ok: false, error: `Copy "${key}" must be text under ${LIMITS.copy} characters.` }
    }
    if (v !== defaultBranding.copy[key]) copy[key] = v
  }

  return { ok: true, value: { siteTitle, ...images, copy } }
}

/** Layer saved overrides on top of the defaults that ship in config/prelaunch.json. */
export function mergeBranding(saved: Partial<Branding> | null | undefined): Branding {
  if (!saved) return defaultBranding
  return {
    siteTitle: saved.siteTitle || defaultBranding.siteTitle,
    logo: saved.logo ?? defaultBranding.logo,
    favicon: saved.favicon ?? defaultBranding.favicon,
    copy: { ...defaultBranding.copy, ...(saved.copy ?? {}) },
  }
}
