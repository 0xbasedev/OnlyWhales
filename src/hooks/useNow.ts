import { useEffect, useRef, useState } from 'react'
import { useBlock } from 'wagmi'
import { chain, isLive } from '../lib/config'

/**
 * Current time in seconds, ticking once a second, on the chain's clock rather than the
 * visitor's. Lock ends, slash percentages and timelock countdowns are all decided by block
 * timestamps, so a laptop clock that is five minutes off must not change what the page says.
 */
export function useNow(intervalMs = 1000): number {
  const block = useBlock({ chainId: chain.id, query: { enabled: isLive, refetchInterval: 20_000 } })
  // Largest (block time - local time) seen. Blocks are always a little in the past, so the
  // maximum is the tightest estimate of the real offset.
  const offset = useRef<number | null>(null)
  const stamp = block.data?.timestamp
  if (stamp !== undefined) {
    const seen = Number(stamp) - Math.floor(Date.now() / 1000)
    if (offset.current === null || seen > offset.current) offset.current = seen
  }
  const read = () => {
    const local = Math.floor(Date.now() / 1000)
    // Ignore ordinary block lag; only correct for a clock that is genuinely off.
    return offset.current !== null && Math.abs(offset.current) > 30 ? local + offset.current : local
  }
  const [now, setNow] = useState(read)
  useEffect(() => {
    setNow(read())
    const id = setInterval(() => setNow(read()), intervalMs)
    return () => clearInterval(id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [intervalMs, stamp])
  return now
}
