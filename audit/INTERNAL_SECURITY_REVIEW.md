# OnlyWhales: internal security review

| | |
| --- | --- |
| **Type** | Internal, AI-assisted review carried out during development |
| **This is not** | An independent third-party audit. It does not satisfy the "no mainnet deploy without an outside audit" rule and must not be used as `OUTSIDE_AUDIT_REPORT_URL`. |
| **Date** | 2026-11-24 |
| **Reviewed commit** | `e25f226` (first complete version of the contracts) |
| **Fixes landed in** | `b8c9f8a` |
| **Report describes** | `80483fc` (contracts unchanged since `b8c9f8a` apart from formatting) |
| **Compiler** | solc 0.8.28, optimizer 200 runs, via-IR, EVM `cancun` |
| **Dependencies** | OpenZeppelin Contracts 5.6.1 (`SafeERC20`, `ReentrancyGuard`, `Math`, `Base64`, `Strings`) |

## Scope

| File | Lines | SHA-256 (first 16 hex) |
| --- | --- | --- |
| `contracts/src/OnlyWhalesVault.sol` | 908 | `54d631b67221eccf` |
| `contracts/src/WhalePass.sol` | 136 | `6641db22624b3425` |
| `contracts/src/lib/TimeWeightedPot.sol` | 66 | `35f74d90deaa6a70` |
| `contracts/src/lib/Timelocked.sol` | 76 | `c93b2af6338c4244` |

Out of scope: the frontend, the access and branding API (`server/`, `api/`), deploy scripts, and the off-chain Telegram gate.

## Summary

| Severity | Found | Fixed | Open |
| --- | --- | --- | --- |
| Critical | 0 | – | – |
| High | 2 | 2 | 0 |
| Medium | 1 | 1 | 0 |
| Low | 1 | 1 | 0 |
| Informational / accepted | 8 | – | 8 (see "Known behaviour and residual risk") |

The review found no way to take another user's principal, no state in which `withdraw` or `claim` reverts permanently, and no path to insolvency. It found three economic exploits, each confirmed with a passing proof-of-concept test, and one low-severity metadata issue. All four were fixed.

**The most important caveat in this document:** the fixes were written after the review and have not been re-reviewed by an independent party. They are covered by new regression tests and by the fuzz and invariant suites, and one bug in the fix itself was caught that way (see I-0). The fix introduced a new subsystem (per-day expiry buckets). That code deserves the most attention from the outside auditor.

## Method

1. **Adversarial manual review.** A separate reviewer instance, given the source and the specification but not the author's reasoning, was asked for concrete, exploitable problems and required to confirm each with a Foundry proof of concept.
2. **Unit tests** for every rule in the specification (123 tests in 9 suites).
3. **Fuzzing.** 512 runs per fuzz test by default; 5,000 in the `ci` profile.
4. **Stateful invariant testing.** Six random whales depositing, relocking, exiting early, claiming and syncing while an operator moves the minimum and fee and the clock jumps up to 200 days at a time. 64 runs x 96 calls by default; 256 x 200 in the `ci` profile.
5. **Mainnet fork tests** against the real Binance-Peg USDC and the real Chainlink BNB/USD feed.

Not done: static analysis (Slither, Mythril), symbolic execution, formal verification, gas profiling, or any review by a human auditor.

## Findings

### H-1: A lapsed 1,024-day whale could snipe a slash from the sidelines (fixed)

At `e25f226`, relocking an expired position restored its full historical time weight in one transaction and, with 1,024+ days served, put it straight back in the elder pot. A whale could let the lock lapse, sit fully liquid, and relock in the same block as someone else's early exit.

Proof of concept: a $10,000 position with 1,024 days served front-runs a $1M whale's early exit. The slash is $969,336. The sniper receives $775,469 (80%); the $1M staker who had been locked for 200 days receives $0 instead of $697,922. Thirty days later the sniper leaves with no slash.

Fix (`relock`, `_enter`): if a lock has lapsed, the next relock restarts time weight from zero (the day count is kept) and sets `elderAt` at least `ELDER_REJOIN_DELAY` (30 days) into the new lock. Relocking before the lock ends keeps everything.
Tests: `test_LapsedElder_CannotRelockInFrontOfASlash`, `test_LapsedElder_EarnsNothingEvenAFewBlocksLater`, `test_LapsedElder_RejoinsThirtyDaysIntoTheNewLock`, `test_LapsedStaker_TimeWeightRestarts_DayCountDoesNot`, `test_RelockingInTime_KeepsFullWeight`.

### H-2: An expired position kept earning until someone synced it (fixed)

At `e25f226`, lock expiry was only applied when the position was next touched. Until then its weight stayed in the pot and kept growing, and an expired elder held the whole pool in elder phase.

Proof of concept: an elder whose lock ended 370 days earlier, never synced, receives $775,469 of a $969,336 slash while an actively locked $1M staker receives $0.

Fix (`_advance`, `Expiry`, `Checkpoint`): locks end on a UTC day boundary and are recorded in a per-day bucket. The first transaction on or after that day removes the expired weight from both pots and checkpoints the reward accumulators, before any slash is distributed. Expired positions settle against the checkpoint. No keeper is involved.
Tests: `test_ExpiredUnsyncedElder_EarnsNothing_AndDoesNotHoldThePhase`, `test_Expired_KeepsWhatItEarnedBeforeLockEnd_AndNotAWeiMore`, `test_SlashOneSecondBeforeLockEnd_Counts_AtLockEnd_DoesNot`, `test_ManyLocksExpiringOnDifferentDays_AllExitClean`, `test_YearsOfSilence_ThenEverythingStillWorks`, `test_Advance_CatchesUpInChunks_SameResultAsOneGo`.

### M-1: Operator could cycle the minimum to inflate old stakers' weight (fixed)

The minimum can move between $10,000 and $1,000,000 and lowering it never reduces a boost. At `e25f226` the ceiling was 1,000,000x, reachable in about 42 days of raise/lower cycles. Proof of concept: after three cycles a 1,024-day position sits at 1,000,000x and a new position at about 22x, so the old position takes about 99.998% of every slash. A position that was expired and liquid still collected the full boost.

Fix: `MAX_BOOST_WAD` is now 100x, the largest single raise the hard range allows, so cycling buys nothing beyond one maximal raise. A raise only boosts positions that were locked when it took effect (`_boostNow`).
Tests: `test_OperatorCycling_CannotExceedOneHundredX`, `test_Boost_HardCeiling_OneHundredX`, `test_Boost_OnlyPositionsLockedWhenTheRaiseLands`, `test_Boost_RaiseLandingExactlyAtLockEndDoesNotCount`.

Residual: this remains a real operator power. Inside the cap, raising the minimum shifts slash share toward long-standing stakers, by design of the specification.

### L-1: Pass artwork URI was embedded in JSON metadata unescaped (fixed)

A queued URI containing a double quote could rewrite the pass's metadata. Operator-only and behind the 7-day timelock.

Fix (`_checkURI`): URIs are limited to 512 bytes and reject quotes, backslashes and control characters, at construction and when queued.
Test: `test_TierURI_RejectsJsonBreakingCharacters`.

### I-0: Bug introduced by the H-2 fix, caught before commit

The first version of `_advance` removed a day's expired weight with `Pot.leave(a, aS)`, which multiplies its second argument by the weight again. Withdrawals would have reverted with an arithmetic underflow once a lock that did not start at genesis had expired. The unit tests passed because their first depositor started at genesis (start time zero). `testFuzz_PayoutPlusSlashEqualsPrincipal` and the invariant suite both failed on it. Fixed with `removeAggregate`, and `test_ManyLocksExpiringOnDifferentDays_AllExitClean` now covers it directly.

This is recorded because it shows the failure mode an outside audit should look for: a revert in the expiry path is a locked-principal bug.

## What was attacked and held

- **Solvency at extremes.** 100 small slashes one second apart at the boost ceiling, and a pot whose only member joined one second earlier. Total claimable never exceeded `rewardReserve`; the shortfall was rounding dust in the vault's favour.
- **`leave` underflow.** Every join and leave pair uses the stored `weight` and `vstart`.
- **Truncation and overflow.** `uint40`, `uint32`, `uint192`, `uint64` all have headroom. Accumulators use 512-bit `mulDiv`.
- **Raise array and cursor after cancel.** The cursor never passes the matured count; `pop` only removes the pending raise.
- **Minimum above maximum.** Not reachable; each is checked against the other's current and pending value.
- **Timelock boundaries.** `get`, `hasPending`, `cancel` and `_maturedRaises` agree on `<` versus `>=` at the eta.
- **Reentrancy.** Every state-changing function is `nonReentrant` and state is deleted before BNB is sent. A contract that re-enters from its receive hook is bounced on all six entry points.
- **Self-slash recycling across two wallets.** Loses at least 20% plus the fee.
- **Just-in-time fresh deposit before a slash.** Live weight is zero in the same second.
- **Griefing through permissionless `sync`.** Everything `sync` applies favours the position's owner.
- **Pass.** Only the vault mints; every transfer and approval path reverts.
- **Dead oracle or broken DAO wallet.** Neither is touched by `withdraw` or `claim`.

## Invariants under test

| Invariant | Test |
| --- | --- |
| Vault balance == principal + unclaimed rewards + DAO owed, per pool, exactly | `invariant_VaultCoversWhatItOwes` |
| Gross deposited == held + paid out; payout + redistributed slash == principal on every exit | `invariant_Conservation` |
| Sum of positions == pool principal; total claimable <= reward reserve | `invariant_PrincipalAndRewardsReconcile` |
| Settings never leave the hard ranges; operator never changes | `invariant_SettingsInsideHardRanges` |
| At any point every whale can exit and claim and the DAO can sweep, with only dust (< 1e12 wei) left | `invariant_EveryoneCanAlwaysExit` |
| The set of state-changing functions is exactly twelve named functions | `test_WriteSurface_IsExactlyThis` |

Latest results at `80483fc`: 123 passed, 0 failed, 3 skipped (the fork tests, which need `BSC_RPC_URL`). The `ci` profile and the fork tests were last run in full at `b8c9f8a` and passed.

## Known behaviour and residual risk

None of these were treated as defects. An outside auditor and the operator should each form their own view.

1. **Lazy boost and graduation.** A minimum-raise boost and crossing 1,024 days change stored weight only when the position is next touched. Until then the position earns at its old weight. Only the owner is disadvantaged; `sync` is permissionless and views show the new values.
2. **One elder takes the whole 80%.** Per the specification, the moment any locked position has 1,024 days and a seat, stakers below 1,024 days earn nothing in that pool, whatever the elder's size.
3. **Extending a lock re-weights past time.** Relocking to a longer lock multiplies weight for all days already served. It costs a new lock that starts at a 100% slash.
4. **Relocking restarts the slash curve at 100%.**
5. **BNB is paid to `msg.sender` only.** A contract wallet that cannot receive BNB cannot withdraw or claim from the BNB pool. There is no "withdraw to another address" function. Consider adding one, or documenting the requirement.
6. **Operator powers that remain.** Within the timelock and hard ranges the operator can set the minimum equal to the maximum (allowing only one deposit size), move the fee between 0.5% and 3%, redirect future DAO payments, and change pass artwork. None of these touch existing principal.
7. **Catch-up loop.** `_advance` does one storage read per elapsed day. Ten years of silence costs under 12M gas in testing, and `advance(pool, maxDays)` allows it to be done in pieces.
8. **External trust.** Binance-Peg USDC is assumed to be a standard, non-rebasing token with no transfer fee; the vault rejects a deposit that arrives short, but an issuer-side freeze or upgrade of the token is outside the vault's control. The Chainlink feed is used only to value BNB deposits against the limits; the USD value is fixed at deposit time. The feed address and the 600-second staleness limit are immutable, so a retired feed would stop BNB deposits permanently while leaving withdrawals unaffected.

Also noted: rounding dust accumulates in the vault and is not recoverable; the raise history array grows by at most one entry per 7 days; the Telegram invite is a single shared link enforced off-chain.

## Recommendations before mainnet

1. Commission an independent audit, with the per-day expiry buckets, the checkpoint settlement path and the lapse rules named as priority areas.
2. Run Slither and a symbolic tool over the four files.
3. Decide on item 5 above (withdraw to another address) before the audit, since it changes the write surface.
4. Deploy to BSC testnet and run a full lock, lapse, relock and expiry cycle with real wallets.
5. Use a multisig as the operator and as the DAO wallet. The operator address can never be changed.
