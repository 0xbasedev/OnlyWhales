import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError } from 'viem'

// Vault custom errors, in words a person would use.
const HUMAN: Record<string, string> = {
  BelowMinimum: 'Below the minimum deposit.',
  AboveMaximum: 'Over the per-wallet maximum.',
  PositionExists: 'You already have a position in this pool. Relock it instead.',
  NoPosition: 'No position in this pool.',
  BadLock: 'Lock must be between 30 and 1,024 days.',
  CannotShortenLock: 'A relock cannot end before your current lock does.',
  NothingToClaim: 'Nothing to claim yet.',
  OracleStale: 'The BNB price feed is stale. Try again in a minute.',
  OracleBadPrice: 'The BNB price feed returned a bad price. Try again shortly.',
  OracleIncompleteRound: 'The BNB price feed is mid-update. Try again in a minute.',
  NotOperator: 'Only the operator wallet can do that.',
  OutOfRange: 'Outside the hard-coded range.',
  MinAboveMax: 'Minimum would end up above the maximum.',
  ChangePending: 'A change is already counting down for this setting. Cancel it first.',
  NothingPending: 'Nothing is pending for this setting.',
  NoChange: 'That is already the current value.',
  TransferFailed: 'The transfer was refused by the receiving wallet.',
  ERC20InsufficientBalance: 'Not enough USDC.',
  ERC20InsufficientAllowance: 'Approve USDC first.',
}

export function explainError(err: unknown): string {
  if (err instanceof BaseError) {
    if (err.walk((e) => e instanceof UserRejectedRequestError)) return 'Cancelled in wallet.'
    const revert = err.walk((e) => e instanceof ContractFunctionRevertedError)
    if (revert instanceof ContractFunctionRevertedError) {
      const name = revert.data?.errorName
      if (name && HUMAN[name]) return HUMAN[name]
      if (name) return name
    }
    if (/insufficient funds/i.test(err.message)) return 'Not enough BNB for the amount plus gas.'
    return err.shortMessage || 'Transaction failed.'
  }
  return err instanceof Error ? err.message : 'Something went wrong.'
}
