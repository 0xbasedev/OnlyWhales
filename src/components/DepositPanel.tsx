import { useEffect, useMemo, useState } from 'react'
import { erc20Abi, parseUnits } from 'viem'
import { vaultAbi } from '../abi/vault'
import { useBranding } from '../hooks/useBranding'
import { useTx } from '../hooks/useTx'
import type { VaultState, WalletState } from '../hooks/useVault'
import { DAY, POOLS, vaultAddress, type PoolId } from '../lib/config'
import { fmtDate, fmtToken, fmtUsd, toNumber } from '../lib/format'
import { TIER_NAMES, tierFor } from '../lib/math'
import { useNow } from '../hooks/useNow'
import { ConnectButton } from './ConnectButton'
import { LockSlider } from './LockSlider'
import { Row, TxLine } from './Bits'

const GAS_RESERVE = 10n ** 16n // keep 0.01 BNB for gas

function parseAmount(text: string): bigint {
  const clean = text.replace(/,/g, '').trim()
  if (!/^\d*\.?\d{0,18}$/.test(clean) || clean === '' || clean === '.') return 0n
  try {
    return parseUnits(clean, 18)
  } catch {
    return 0n
  }
}

export function DepositPanel({ vault, wallet }: { vault: VaultState; wallet: WalletState }) {
  const { t } = useBranding()
  const now = useNow(30_000)
  const [pool, setPool] = useState<PoolId>(0)
  const [text, setText] = useState('')
  const [days, setDays] = useState(365)
  const tx = useTx()

  // Start on a pool the wallet can actually deposit into.
  const has0 = (wallet.positions[0]?.amount ?? 0n) > 0n
  const has1 = (wallet.positions[1]?.amount ?? 0n) > 0n
  useEffect(() => {
    if (has0 && !has1) setPool(1)
    else if (has1 && !has0) setPool(0)
  }, [has0, has1])

  const asset = POOLS[pool]
  const amount = parseAmount(text)
  const price = pool === 0 ? 1 : vault.bnbPrice
  const usd = price ? toNumber(amount) * price : 0
  const room = Math.max(0, vault.maxUsd - wallet.activeUsd)
  const balance = pool === 0 ? wallet.usdcBalance : wallet.bnbBalance
  const existing = wallet.positions[pool]?.amount ? true : false

  const fee = (amount * BigInt(vault.feeBps)) / 10_000n
  const principal = amount - fee
  const unlock = Math.ceil((now + days * DAY) / DAY) * DAY
  const tier = tierFor(wallet.activeUsd + usd, days)

  // The first thing wrong, in the order a person would fix it.
  const problem = useMemo(() => {
    if (!vault.live) return { text: 'Not live yet.', hard: true }
    if (vault.unreachable) return { text: 'Cannot reach the vault. Check your connection.', hard: true }
    if (existing) return { text: `You already have a ${asset.symbol} position. One per pool. Relock it instead.`, hard: true }
    if (pool === 1 && !vault.bnbPrice) return { text: 'BNB price feed is stale. Deposits in BNB resume when it updates.', hard: true }
    if (room < vault.minUsd) return { text: `This wallet is at its ${fmtUsd(vault.maxUsd)} cap.`, hard: true }
    if (amount === 0n) return null
    if (usd < vault.minUsd) return { text: `Minimum is ${fmtUsd(vault.minUsd)}. You are ${fmtUsd(vault.minUsd - usd)} short of the door.`, hard: false }
    if (usd > room) return { text: `Over the cap. This wallet has ${fmtUsd(room)} of room left.`, hard: false }
    if (wallet.isConnected && amount + (pool === 1 ? GAS_RESERVE : 0n) > balance) return { text: `Not enough ${asset.symbol} in this wallet.`, hard: false }
    return null
  }, [vault.live, vault.unreachable, vault.bnbPrice, vault.minUsd, vault.maxUsd, existing, asset.symbol, pool, room, amount, usd, wallet.isConnected, balance])

  const needsApproval = pool === 0 && amount > 0n && wallet.usdcAllowance < amount
  const ready = wallet.isConnected && !wallet.wrongChain && !problem && amount > 0n

  const setUsd = (target: number) => {
    if (!price) return
    setText(pool === 0 ? String(Math.round(target)) : (target / price).toFixed(4))
  }

  const submit = async () => {
    if (!vaultAddress || !ready) return
    if (needsApproval && vault.usdc) {
      await tx.run('Approve USDC', { address: vault.usdc, abi: erc20Abi, functionName: 'approve', args: [vaultAddress, amount] })
      return
    }
    const ok =
      pool === 0
        ? await tx.run('Deposit', { address: vaultAddress, abi: vaultAbi, functionName: 'depositUSDC', args: [amount, BigInt(days * DAY)] })
        : await tx.run('Deposit', { address: vaultAddress, abi: vaultAbi, functionName: 'depositBNB', args: [BigInt(days * DAY)], value: amount })
    if (ok) setText('')
  }

  const cta = !amount
    ? 'Enter an amount'
    : problem
      ? problem.hard
        ? 'Unavailable'
        : 'Fix the amount'
      : needsApproval
        ? `1 of 2 · ${t('deposit.approve')}`
        : `${t('deposit.cta')} · ${fmtToken(amount, asset.symbol)}`

  return (
    <div className="glass pad" data-reveal>
      <h2 className="panel-title">{t('deposit.title')}</h2>
      <p className="panel-lead">{t('deposit.lead')}</p>

      <div className="field">
        <div className="seg" role="group" aria-label="Asset">
          {POOLS.map((p) => (
            <button key={p.id} type="button" aria-pressed={pool === p.id} onClick={() => (setPool(p.id), setText(''), tx.reset())}>
              <span>{p.symbol}</span>
              <span className="s">
                {wallet.isConnected ? `${fmtToken(p.id === 0 ? wallet.usdcBalance : wallet.bnbBalance)} in wallet` : p.id === 0 ? 'valued at $1' : vault.bnbPrice ? `${fmtUsd(vault.bnbPrice)} · Chainlink` : 'Chainlink price'}
              </span>
            </button>
          ))}
        </div>
      </div>

      <div className="field">
        <div className="field-head">
          <span>Amount</span>
          <span className="mono">{amount > 0n && price ? `≈ ${fmtUsd(usd)}` : `${fmtUsd(vault.minUsd)} – ${fmtUsd(vault.maxUsd)}`}</span>
        </div>
        <div className={`amount ${problem && !problem.hard && amount > 0n ? 'bad' : ''}`}>
          <input
            inputMode="decimal"
            placeholder="0"
            value={text}
            aria-label={`Amount in ${asset.symbol}`}
            aria-invalid={!!problem && amount > 0n}
            onChange={(e) => {
              const v = e.target.value.replace(/[^\d.,]/g, '')
              setText(v)
              if (tx.state.phase !== 'idle') tx.reset()
            }}
          />
          <span className="unit">{asset.symbol}</span>
        </div>
        <div className="field-foot">
          <span className={`hint ${problem ? 'bad' : ''}`} role={problem ? 'alert' : undefined}>
            {problem?.text ?? 'Checked before the fee comes out.'}
          </span>
          <div className="chips">
            {/* a hair over the minimum so a moving BNB price cannot bounce the deposit */}
            <button type="button" className="chip" disabled={!price} onClick={() => setUsd(vault.minUsd * (pool === 1 ? 1.003 : 1))}>
              Min
            </button>
            <button type="button" className="chip" disabled={!price || room <= 0} onClick={() => setUsd(room * (pool === 1 ? 0.997 : 1))}>
              Max
            </button>
          </div>
        </div>
      </div>

      <div className="field">
        <div className="field-head">
          <span>Lock</span>
          <span>{t('deposit.lockHint')}</span>
        </div>
        <LockSlider days={days} onChange={setDays} />
      </div>

      <div className="rows">
        <Row k={`${vault.feeBps / 100}%`} note={t('deposit.feeNote')}>
          <span className="muted">−{fmtToken(fee, asset.symbol)}</span>
        </Row>
        <Row k="Goes into the pool">{fmtToken(principal, asset.symbol)}</Row>
        <Row k="Unlocks" note="00:00 UTC">
          {fmtDate(unlock)}
        </Row>
        <Row k="Leave on day one">
          <span className="danger">lose 100%</span>
        </Row>
        <Row k="Pass tier">
          <span className="gold">
            {tier + 1} · {TIER_NAMES[tier]}
          </span>
        </Row>
      </div>

      <div className="cta-block">
        {!wallet.isConnected || wallet.wrongChain ? (
          <ConnectButton primary text={vault.live ? 'Connect wallet to deposit' : 'Connect wallet'} />
        ) : (
          <button className="btn primary block" disabled={!ready || tx.busy} onClick={submit}>
            {tx.busy ? 'Working…' : cta}
          </button>
        )}
        <TxLine state={tx.state} />
        <p className="hint">{t('deposit.disclaimer')}</p>
      </div>
    </div>
  )
}
