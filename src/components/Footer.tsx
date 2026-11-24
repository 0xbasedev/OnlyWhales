import { useBranding } from '../hooks/useBranding'
import type { VaultState } from '../hooks/useVault'
import { chain, explorer, vaultAddress } from '../lib/config'
import { shortAddr } from '../lib/format'

function Addr({ label, value }: { label: string; value?: string }) {
  return (
    <li>
      {label}{' '}
      {value ? (
        <a className="addr" href={explorer ? `${explorer}/address/${value}` : undefined} target="_blank" rel="noreferrer noopener">
          {shortAddr(value)}
        </a>
      ) : (
        <span className="addr faint">not deployed</span>
      )}
    </li>
  )
}

export function Footer({ vault }: { vault: VaultState }) {
  const { t, branding } = useBranding()
  return (
    <footer className="footer">
      <div className="wrap footer-grid">
        <div>
          <p className="line">{t('footer.line')}</p>
          <p className="hint" style={{ marginTop: 18, maxWidth: 420 }}>
            {t('footer.audit')}
          </p>
        </div>
        <div>
          <h4>Nobody can change</h4>
          <ul>
            <li>The operator address</li>
            <li>The slash curve: 100% to 30%</li>
            <li>The 20/80 and 90/10 splits</li>
            <li>The 1,024-day threshold</li>
            <li>The 7-day delay on every setting</li>
            <li>Fee range 0.5%–3%, entry range $10k–$1M</li>
            <li>No pause. No proxy. No path to your principal.</li>
          </ul>
        </div>
        <div>
          <h4>On {chain.name}</h4>
          <ul>
            <Addr label="Vault" value={vaultAddress} />
            <Addr label="Pass" value={vault.pass} />
            <Addr label="Operator" value={vault.operator} />
            <Addr label="DAO wallet" value={vault.dao} />
          </ul>
          <p className="hint" style={{ marginTop: 18 }}>
            © {branding.siteTitle}
          </p>
        </div>
      </div>
    </footer>
  )
}
