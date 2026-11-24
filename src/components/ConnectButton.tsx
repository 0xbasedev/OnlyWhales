import { useEffect, useRef, useState } from 'react'
import { useAccount, useConnect, useDisconnect, useSwitchChain } from 'wagmi'
import { chain } from '../lib/config'
import { shortAddr } from '../lib/format'
import { gsap, reducedMotion } from '../lib/motion'

const label = (name: string) => (name === 'Mock Connector' ? 'Local test wallet' : name === 'Injected' ? 'Browser wallet' : name)

export function ConnectButton({ primary = false, text = 'Connect wallet' }: { primary?: boolean; text?: string }) {
  const { address, isConnected, chainId } = useAccount()
  const { connectors, connect, isPending, error } = useConnect()
  const { disconnect } = useDisconnect()
  const { switchChain, isPending: switching } = useSwitchChain()
  const [open, setOpen] = useState(false)
  const wrap = useRef<HTMLDivElement>(null)
  const menu = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    if (menu.current && !reducedMotion()) {
      gsap.fromTo(menu.current, { opacity: 0, y: -8 }, { opacity: 1, y: 0, duration: 0.7, ease: 'power3.out' })
    }
    const close = (e: MouseEvent) => !wrap.current?.contains(e.target as Node) && setOpen(false)
    const esc = (e: KeyboardEvent) => e.key === 'Escape' && setOpen(false)
    document.addEventListener('mousedown', close)
    document.addEventListener('keydown', esc)
    return () => {
      document.removeEventListener('mousedown', close)
      document.removeEventListener('keydown', esc)
    }
  }, [open])

  useEffect(() => {
    if (isConnected) setOpen(false)
  }, [isConnected])

  if (isConnected && chainId !== chain.id) {
    return (
      <button className="btn sm danger" disabled={switching} onClick={() => switchChain({ chainId: chain.id })}>
        Switch to {chain.name}
      </button>
    )
  }

  // EIP-6963 wallets announce themselves by name; hide the generic entry when one did.
  const named = connectors.filter((c) => c.type === 'injected' && c.name !== 'Injected')
  const list = connectors.filter((c) => !(c.name === 'Injected' && named.length > 0))

  return (
    <div ref={wrap} style={{ position: 'relative' }}>
      {isConnected ? (
        <button className="btn sm" onClick={() => setOpen((v) => !v)} aria-expanded={open}>
          <span className="dot ok" />
          <span className="mono">{shortAddr(address)}</span>
        </button>
      ) : (
        <button className={`btn ${primary ? 'primary' : 'sm'}`} onClick={() => setOpen((v) => !v)} aria-expanded={open}>
          {isPending ? 'Check your wallet…' : text}
        </button>
      )}
      {open && (
        <div className="menu" ref={menu} role="menu">
          {isConnected ? (
            <button role="menuitem" onClick={() => disconnect()}>
              Disconnect <span className="faint mono">{shortAddr(address)}</span>
            </button>
          ) : (
            <>
              {list.map((c) => (
                <button key={c.uid} role="menuitem" onClick={() => connect({ connector: c, chainId: chain.id })}>
                  {label(c.name)}
                  <span className="faint">→</span>
                </button>
              ))}
              <div className="menu-note">{error ? error.message.split('\n')[0] : `Connects on ${chain.name}. Nothing is signed yet.`}</div>
            </>
          )}
        </div>
      )}
    </div>
  )
}
