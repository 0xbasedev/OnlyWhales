import { useCallback, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useAccount, usePublicClient, useWriteContract } from 'wagmi'
import type { Abi, Address } from 'viem'
import { chain } from '../lib/config'
import { explainError } from '../lib/errors'

export type TxState =
  | { phase: 'idle' }
  | { phase: 'checking' | 'wallet' | 'mining'; label: string }
  | { phase: 'done'; label: string }
  | { phase: 'error'; label: string; error: string }

type Request = { address: Address; abi: Abi; functionName: string; args?: readonly unknown[]; value?: bigint }

/**
 * One transaction at a time: simulate (so a revert is explained before the wallet opens),
 * ask the wallet, wait for the receipt, refresh every on-chain read.
 */
export function useTx() {
  const [state, setState] = useState<TxState>({ phase: 'idle' })
  const { address } = useAccount()
  const client = usePublicClient({ chainId: chain.id })
  const { writeContractAsync } = useWriteContract()
  const queryClient = useQueryClient()

  const run = useCallback(
    async (label: string, request: Request): Promise<boolean> => {
      if (!client || !address) return false
      try {
        setState({ phase: 'checking', label })
        await client.simulateContract({ ...request, account: address } as never)
        setState({ phase: 'wallet', label })
        const hash = await writeContractAsync({ ...request, chainId: chain.id } as never)
        setState({ phase: 'mining', label })
        const receipt = await client.waitForTransactionReceipt({ hash })
        if (receipt.status !== 'success') throw new Error('Transaction reverted.')
        await queryClient.invalidateQueries()
        setState({ phase: 'done', label })
        return true
      } catch (err) {
        setState({ phase: 'error', label, error: explainError(err) })
        return false
      }
    },
    [address, client, queryClient, writeContractAsync],
  )

  const busy = state.phase === 'checking' || state.phase === 'wallet' || state.phase === 'mining'
  return { state, run, busy, reset: () => setState({ phase: 'idle' }) }
}

export function txMessage(state: TxState): { text: string; tone: '' | 'err' | 'done' } {
  switch (state.phase) {
    case 'checking':
      return { text: `${state.label}: checking…`, tone: '' }
    case 'wallet':
      return { text: `${state.label}: confirm in your wallet.`, tone: '' }
    case 'mining':
      return { text: `${state.label}: waiting for the chain…`, tone: '' }
    case 'done':
      return { text: `${state.label}: done.`, tone: 'done' }
    case 'error':
      return { text: state.error, tone: 'err' }
    default:
      return { text: '', tone: '' }
  }
}
