// The exact text wallets sign. Imported by both the browser and the server so the two can
// never drift apart. The server always rebuilds the message from its own vault address and
// chain id; nothing the client sends about those is trusted.

export const SIGNATURE_TTL_SECONDS = 300 // five minutes
export const CLOCK_SKEW_SECONDS = 60

export type MessageContext = {
  wallet: string
  vault: string
  chainId: number
  timestamp: number
}

export function accessMessage({ wallet, vault, chainId, timestamp }: MessageContext): string {
  return [
    'OnlyWhales: open the pool gate.',
    '',
    `Wallet: ${wallet}`,
    `Vault: ${vault}`,
    `Chain: ${chainId}`,
    `Timestamp: ${timestamp}`,
    '',
    'Signing is free and moves nothing. Expires in 5 minutes.',
  ].join('\n')
}

export function brandingMessage(ctx: MessageContext & { digest: string }): string {
  return [
    'OnlyWhales: publish site branding.',
    '',
    `Operator: ${ctx.wallet}`,
    `Vault: ${ctx.vault}`,
    `Chain: ${ctx.chainId}`,
    `Content SHA-256: ${ctx.digest}`,
    `Timestamp: ${ctx.timestamp}`,
    '',
    'Off-chain only. Signing is free and moves nothing. Expires in 5 minutes.',
  ].join('\n')
}

/** Why a timestamp is unusable, or null if it is inside the window. */
export function timestampProblem(timestamp: unknown, nowSeconds: number): string | null {
  if (typeof timestamp !== 'number' || !Number.isSafeInteger(timestamp) || timestamp <= 0) {
    return 'Bad timestamp.'
  }
  if (timestamp > nowSeconds + CLOCK_SKEW_SECONDS) return 'Timestamp is in the future.'
  if (nowSeconds - timestamp > SIGNATURE_TTL_SECONDS) return 'Signature expired. Sign again.'
  return null
}
