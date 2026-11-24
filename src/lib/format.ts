import { formatUnits } from 'viem'

const usd0 = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 })
const compact = new Intl.NumberFormat('en-US', { notation: 'compact', maximumFractionDigits: 2 })

export const fmtUsd = (n: number) => usd0.format(n)
export const fmtCompact = (n: number) => compact.format(n)

/** Token amount with sensible precision: 291,000 USDC, 484.2301 BNB. */
export function fmtToken(value: bigint, symbol?: string, maxDp?: number): string {
  const n = Number(formatUnits(value, 18))
  const dp = maxDp ?? (symbol === 'BNB' ? 4 : 2)
  const text = n.toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits: n !== 0 && Math.abs(n) < 1 ? 6 : dp })
  return symbol ? `${text} ${symbol}` : text
}

export const toNumber = (value: bigint, decimals = 18) => Number(formatUnits(value, decimals))

export const fmtPct = (fraction: number, dp = 2) => `${(fraction * 100).toFixed(dp)}%`

export const fmtDate = (unix: number) =>
  new Date(unix * 1000).toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric' })

export const fmtDateTime = (unix: number) =>
  new Date(unix * 1000).toLocaleString('en-US', { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })

/** 6d 23h 59m 12s. Used for live countdowns. */
export function fmtCountdown(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds))
  const d = Math.floor(s / 86_400)
  const h = Math.floor((s % 86_400) / 3600)
  const m = Math.floor((s % 3600) / 60)
  const pad = (v: number) => String(v).padStart(2, '0')
  return `${d}d ${pad(h)}h ${pad(m)}m ${pad(s % 60)}s`
}

/** "412 days" / "3 days" / "5 hours": coarse, for prose. */
export function fmtSpan(seconds: number): string {
  const s = Math.max(0, seconds)
  if (s >= 2 * 86_400) return `${Math.floor(s / 86_400).toLocaleString('en-US')} days`
  if (s >= 86_400) return '1 day'
  if (s >= 3600) return `${Math.floor(s / 3600)} hours`
  return `${Math.max(1, Math.floor(s / 60))} minutes`
}

export const shortAddr = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : '')
