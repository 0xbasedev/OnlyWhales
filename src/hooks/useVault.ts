import { erc20Abi, formatUnits, zeroAddress, type Address } from 'viem'
import { useAccount, useBalance, useReadContracts } from 'wagmi'
import { vaultAbi } from '../abi/vault'
import { chain, defaults, isLive, vaultAddress } from '../lib/config'

const vault = { address: vaultAddress ?? zeroAddress, abi: vaultAbi, chainId: chain.id } as const
const REFRESH = 15_000

export type PoolView = {
  totalPrincipal: bigint
  rewardReserve: bigint
  daoOwed: bigint
  stakerWeight: bigint
  elderWeight: bigint
  elderPhase: boolean
}

export type PositionView = {
  amount: bigint
  grossUsd: bigint
  lockStart: bigint
  lockEnd: bigint
  lockDuration: bigint
  stakedSeconds: bigint
  boostWad: bigint
  weight: bigint
  slashWad: bigint
  slashAmount: bigint
  earned: bigint
  elderAt: bigint
  locked: boolean
  elder: boolean
  needsSync: boolean
}

export type Pending = { value: bigint; eta: number } | null

/** Pool-wide state. Before launch it returns the defaults from config/prelaunch.json. */
export function useVault() {
  const q = useReadContracts({
    allowFailure: true,
    contracts: [
      { ...vault, functionName: 'depositFeeBps' },
      { ...vault, functionName: 'minDepositUsd' },
      { ...vault, functionName: 'maxDepositUsd' },
      { ...vault, functionName: 'daoWallet' },
      { ...vault, functionName: 'operator' },
      { ...vault, functionName: 'usdc' },
      { ...vault, functionName: 'pass' },
      { ...vault, functionName: 'bnbUsdPrice' },
      { ...vault, functionName: 'poolInfo', args: [0] },
      { ...vault, functionName: 'poolInfo', args: [1] },
      { ...vault, functionName: 'pendingChange', args: [0] },
      { ...vault, functionName: 'pendingChange', args: [1] },
      { ...vault, functionName: 'pendingChange', args: [2] },
      { ...vault, functionName: 'pendingChange', args: [3] },
    ],
    query: { enabled: isLive, refetchInterval: REFRESH },
  })
  const d = q.data
  const pend = (i: 10 | 11 | 12 | 13): Pending => {
    const r = d?.[i]?.result
    return r && r[1] > 0n ? { value: r[0], eta: Number(r[1]) } : null
  }
  const price = d?.[7]?.result

  return {
    live: isLive,
    loading: isLive && q.isLoading,
    unreachable: isLive && q.isFetched && d?.[0]?.status !== 'success',
    feeBps: d?.[0]?.result !== undefined ? Number(d[0].result) : defaults.feeBps,
    minUsd: d?.[1]?.result !== undefined ? Number(formatUnits(d[1].result, 18)) : defaults.minUsd,
    maxUsd: d?.[2]?.result !== undefined ? Number(formatUnits(d[2].result, 18)) : defaults.maxUsd,
    dao: d?.[3]?.result as Address | undefined,
    operator: d?.[4]?.result as Address | undefined,
    usdc: d?.[5]?.result as Address | undefined,
    pass: d?.[6]?.result as Address | undefined,
    /** BNB price in USD, or undefined if the feed is stale or unreachable. */
    bnbPrice: price !== undefined ? Number(formatUnits(price, 8)) : undefined,
    pools: [d?.[8]?.result as PoolView | undefined, d?.[9]?.result as PoolView | undefined] as const,
    pending: [pend(10), pend(11), pend(12), pend(13)] as const,
    refetch: q.refetch,
  }
}

export type VaultState = ReturnType<typeof useVault>

/** Everything about the connected wallet. */
export function useWallet(usdc?: Address) {
  const { address, isConnected, chainId } = useAccount()
  const who = address ?? zeroAddress
  const on = isLive && !!address

  const q = useReadContracts({
    allowFailure: true,
    contracts: [
      { ...vault, functionName: 'positionOf', args: [who, 0] },
      { ...vault, functionName: 'positionOf', args: [who, 1] },
      { ...vault, functionName: 'activeUsd', args: [who] },
      { ...vault, functionName: 'passTier', args: [who] },
      { ...vault, functionName: 'hasAccess', args: [who] },
      { address: usdc ?? zeroAddress, abi: erc20Abi, chainId: chain.id, functionName: 'balanceOf', args: [who] },
      { address: usdc ?? zeroAddress, abi: erc20Abi, chainId: chain.id, functionName: 'allowance', args: [who, vault.address] },
    ],
    query: { enabled: on && !!usdc, refetchInterval: REFRESH },
  })
  const bnb = useBalance({ address, chainId: chain.id, query: { enabled: on, refetchInterval: REFRESH } })
  const d = q.data

  const positions = [d?.[0]?.result as PositionView | undefined, d?.[1]?.result as PositionView | undefined] as const
  const hasPosition = positions.some((p) => p && p.amount > 0n)

  return {
    address,
    isConnected,
    wrongChain: isConnected && chainId !== chain.id,
    loading: on && q.isLoading,
    positions,
    hasPosition,
    activeUsd: d?.[2]?.result !== undefined ? Number(formatUnits(d[2].result, 18)) : 0,
    passTier: d?.[3]?.result,
    hasAccess: d?.[4]?.result ?? false,
    /** The pass is minted with the first deposit and never burned. */
    hasPass: hasPosition || (d?.[3]?.result ?? 0) > 0 || (d?.[4]?.result ?? false),
    usdcBalance: d?.[5]?.result ?? 0n,
    usdcAllowance: d?.[6]?.result ?? 0n,
    bnbBalance: bnb.data?.value ?? 0n,
  }
}

export type WalletState = ReturnType<typeof useWallet>
