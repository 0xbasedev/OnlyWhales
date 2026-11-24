import { isAddress, zeroAddress, type Address } from 'viem'
import { bsc, bscTestnet, foundry } from 'viem/chains'
import prelaunch from '../../config/prelaunch.json'

const chains = { 56: bsc, 97: bscTestnet, 31337: foundry } as const

export const chainId = (Number(import.meta.env.VITE_CHAIN_ID) || prelaunch.network.chainId) as keyof typeof chains
export const chain = chains[chainId] ?? bsc
export const isLocalChain = chain.id === 31337

const rawVault = import.meta.env.VITE_VAULT_ADDRESS
/** Undefined until the vault is deployed. The site then runs in look-don't-touch mode. */
export const vaultAddress: Address | undefined =
  rawVault && isAddress(rawVault) && rawVault !== zeroAddress ? rawVault : undefined
export const isLive = !!vaultAddress
export const rpcUrl = import.meta.env.VITE_RPC_URL || undefined
export const wcProjectId = import.meta.env.VITE_WC_PROJECT_ID || undefined

export const explorer = chain.blockExplorers?.default.url

// Mirrors of the vault's immutable constants. Display only; the contract is the authority.
export const DAY = 86_400
export const MIN_LOCK_DAYS = 30
export const MAX_LOCK_DAYS = 1024
export const ELDER_DAYS = 1024
export const TIMELOCK_SECONDS = 7 * DAY
export const HARD = { feeBps: [50, 300], depositUsd: [10_000, 1_000_000] } as const

export const POOLS = [
  { id: 0, symbol: 'USDC', name: 'Binance-Peg USDC', decimals: 18 },
  { id: 1, symbol: 'BNB', name: 'BNB', decimals: 18 },
] as const
export type PoolId = 0 | 1

export const defaults = {
  feeBps: prelaunch.settings.depositFeeBps,
  minUsd: prelaunch.settings.minDepositUsd,
  maxUsd: prelaunch.settings.maxDepositUsd,
}
