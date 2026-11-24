import { Link } from 'react-router-dom'
import { useAccount } from 'wagmi'
import { useBranding } from '../hooks/useBranding'
import type { VaultState } from '../hooks/useVault'
import { ConnectButton } from './ConnectButton'
import { Logo } from './Bits'

export function Nav({ vault, owner = false }: { vault: VaultState; owner?: boolean }) {
  const { branding } = useBranding()
  const { address } = useAccount()
  const isOperator = !!address && !!vault.operator && address.toLowerCase() === vault.operator.toLowerCase()
  return (
    <header className="nav">
      <div className="wrap">
        <div className="nav-inner glass">
          <Link to="/" className="brand">
            <Logo />
            <span>{branding.siteTitle}</span>
          </Link>
          <nav className="nav-links">
            {owner ? (
              <Link to="/">Back to the pool</Link>
            ) : (
              <>
                <a className="hide-sm" href="#rules">
                  Rules
                </a>
                <a className="hide-sm" href="#pool">
                  Pool
                </a>
                <a className="hide-sm" href="#access">
                  Telegram
                </a>
                {isOperator && <Link to="/owner">Operator</Link>}
              </>
            )}
            <ConnectButton />
          </nav>
        </div>
      </div>
    </header>
  )
}
