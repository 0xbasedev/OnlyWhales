import { DAY, ELDER_DAYS, MIN_LOCK_DAYS } from './config'

export const WAD = 10n ** 18n

/** Early-exit slash as a fraction: 1.0 at lock start, linear to 0.3 at lock end, 0 after. */
export function slashFraction(lockStart: number, lockEnd: number, now: number): number {
  if (now >= lockEnd || lockEnd <= lockStart) return 0
  const elapsed = Math.max(0, now - lockStart)
  return 1 - (0.7 * elapsed) / (lockEnd - lockStart)
}

/** Same as the vault: ceil(amount * slashWad / 1e18), using the vault's integer slash curve. */
export function slashAmount(amount: bigint, lockStart: number, lockEnd: number, now: number): bigint {
  if (now >= lockEnd || lockEnd <= lockStart) return 0n
  const elapsed = BigInt(Math.max(0, now - lockStart))
  const slashWad = WAD - (7n * 10n ** 17n * elapsed) / BigInt(lockEnd - lockStart)
  return (amount * slashWad + WAD - 1n) / WAD
}

/** Weight relative to the shortest lock. Weight in the pot is amount x lock x days staked. */
export const lockMultiplier = (days: number) => days / MIN_LOCK_DAYS

export const elderProgress = (stakedSeconds: number) => Math.min(1, stakedSeconds / (ELDER_DAYS * DAY))

export const TIER_NAMES = [
  'Krill',
  'Sardine',
  'Dolphin',
  'Orca',
  'Humpback',
  'Cachalot',
  'Fin Whale',
  'Blue Whale',
  'Leviathan',
  'Kraken',
] as const

/** Mirror of OnlyWhalesVault.tierFor: five size bands plus six lock bands, 0-9. */
export function tierFor(usd: number, lockDays: number): number {
  const size = usd >= 1_000_000 ? 4 : usd >= 750_000 ? 3 : usd >= 500_000 ? 2 : usd >= 250_000 ? 1 : 0
  const lock = lockDays >= 1024 ? 5 : lockDays >= 730 ? 4 : lockDays >= 365 ? 3 : lockDays >= 180 ? 2 : lockDays >= 90 ? 1 : 0
  return size + lock
}
