import { createPublicClient, http, isAddress, type Address, type PublicClient } from 'viem'
import prelaunch from '../config/prelaunch.json' with { type: 'json' }

export type ServerEnv = Record<string, string | undefined>

export type ChainContext = {
  chainId: number
  /** Zero address until the vault is deployed. */
  vault: Address
  deployed: boolean
  client: Pick<PublicClient, 'verifyMessage' | 'readContract'> | null
}

const ZERO = '0x0000000000000000000000000000000000000000' as Address

const DEFAULT_RPC: Record<number, string> = {
  56: 'https://bsc-dataseed.binance.org',
  97: 'https://data-seed-prebsc-1-s1.binance.org:8545',
  31337: 'http://127.0.0.1:8545',
}

/** Server-side view of the deployment. Reads the same VITE_* values the frontend is built with. */
export function chainContext(env: ServerEnv): ChainContext {
  const chainId = Number(env.VITE_CHAIN_ID || prelaunch.network.chainId)
  const address = env.VITE_VAULT_ADDRESS
  const deployed = !!address && isAddress(address) && address !== ZERO
  const rpc = env.RPC_URL || env.VITE_RPC_URL || DEFAULT_RPC[chainId]
  return {
    chainId,
    vault: deployed ? (address as Address) : ZERO,
    deployed,
    client: deployed && rpc ? (createPublicClient({ transport: http(rpc) }) as ChainContext['client']) : null,
  }
}

export const configuredOperator = prelaunch.operator as Address

export type Reply = { status: number; body: Record<string, unknown> }
export const reply = (status: number, body: Record<string, unknown>): Reply => ({ status, body })
