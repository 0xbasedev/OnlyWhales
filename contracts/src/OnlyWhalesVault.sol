// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {Timelocked} from "./lib/Timelocked.sol";
import {TimeWeightedPot} from "./lib/TimeWeightedPot.sol";
import {WhalePass} from "./WhalePass.sol";

/// @title OnlyWhalesVault
/// @notice Lock USDC or BNB. Leave early and you get slashed; the slash pays the whales who stayed.
///
/// @dev Design rules, all enforced by construction:
///  - No pause, no proxy, no owner transfer, no renounce. The operator address is immutable.
///  - No function moves principal anywhere except back to its depositor (minus the slash they
///    chose to take by leaving early). The operator has no path to user funds.
///  - Operator-tunable settings live inside hard-coded ranges and only change through a 7-day
///    timelock that takes effect by itself. There is no execute call.
///  - USDC and BNB are separate pools. A slash in one asset is paid out in that asset.
///  - Withdrawals never read the oracle and never push funds to the DAO wallet, so neither a dead
///    price feed nor a broken DAO address can trap principal.
///
///  Time accounting. "Days staked" counts locked time only: time elapsed inside a lock, summed
///  across relocks. Locks end on a UTC day boundary.
///
///  Lock expiry is exact and needs no keeper. Every lock end is recorded in a per-day bucket; the
///  first transaction on or after that day removes the expired weight from the pots and
///  checkpoints the reward accumulators, before any slash is distributed. An expired position
///  earns up to its lock end and not one wei after, whether or not anyone ever syncs it.
///
///  Letting a lock lapse has a price, so nobody can sit liquid and jump back in front of a slash:
///   - time weight in the pot restarts from zero on the next relock (the day count is kept), and
///   - a whale with 1024+ days rejoins the elder pot only 30 days into the new lock.
///  Relocking before the lock ends keeps everything.
///
///  Two transitions are applied lazily, the next time the position is touched: a staker crossing
///  1024 days and a minimum-raise boost taking effect. `sync` is permissionless, and both only
///  ever help the position's owner.
contract OnlyWhalesVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Timelocked for Timelocked.Uint;
    using Timelocked for Timelocked.Str;
    using TimeWeightedPot for TimeWeightedPot.Pot;

    // ===================================================================== types

    enum Param {
        DepositFee,
        MinDeposit,
        MaxDeposit,
        DaoWallet
    }

    struct Config {
        address operator;
        address daoWallet;
        address usdc;
        address bnbUsdFeed;
        uint256 oracleStaleness;
        uint256 depositFeeBps;
        uint256 minDepositUsd;
        uint256 maxDepositUsd;
        string[10] tierURIs;
    }

    struct Position {
        uint256 amount; // principal, net of the deposit fee
        uint256 weight; // amount * lockDuration * boost; zero while the lock is expired
        uint256 vstart; // virtual start (seconds since genesis) such that staked time = now - vstart
        uint256 boostWad; // stacked minimum-raise boost, 1e18 = 1x
        uint256 snapP;
        uint256 snapQ;
        uint256 elderSnapP;
        uint256 elderSnapQ;
        uint256 grossUsd; // USD value counted against the per-wallet maximum
        uint40 lockStart;
        uint40 lockEnd;
        uint40 lockDuration;
        uint40 accrued; // locked seconds completed in earlier locks
        uint40 elderAt; // earliest moment this position may join the 1024-day pot
        uint32 raiseCursor; // next entry of `_raises` to apply
        bool elder; // currently in the 1024-day pot
    }

    /// @dev Weight that leaves the pots when the locks ending on a given day expire.
    struct Expiry {
        uint256 a;
        uint256 aS;
        uint256 elderA;
        uint256 elderAS;
    }

    /// @dev Reward accumulators as they stood at a day boundary on which locks expired.
    struct Checkpoint {
        uint256 accP;
        uint256 accQ;
        uint256 elderAccP;
        uint256 elderAccQ;
    }

    struct Pool {
        TimeWeightedPot.Pot stakers;
        TimeWeightedPot.Pot elders;
        uint256 totalPrincipal;
        uint256 rewardReserve; // slash distributed to whales and not yet claimed
        uint256 daoOwed; // fees + DAO share of slashes, waiting for `sweepDao`
        uint256 lastDay; // last UTC day whose expiries have been processed
        mapping(uint256 day => Expiry) expiries;
        mapping(uint256 day => Checkpoint) checkpoints;
    }

    struct Raise {
        uint64 eta;
        uint192 ratioWad; // newMin / oldMin, 1e18 = 1x
    }

    struct PositionView {
        uint256 amount;
        uint256 grossUsd;
        uint256 lockStart;
        uint256 lockEnd;
        uint256 lockDuration;
        uint256 stakedSeconds;
        uint256 boostWad;
        uint256 weight;
        uint256 slashWad;
        uint256 slashAmount;
        uint256 earned;
        uint256 elderAt;
        bool locked;
        bool elder;
        bool needsSync;
    }

    struct PoolView {
        uint256 totalPrincipal;
        uint256 rewardReserve;
        uint256 daoOwed;
        uint256 stakerWeight;
        uint256 elderWeight;
        bool elderPhase;
    }

    // ================================================================= constants

    uint8 public constant POOL_USDC = 0;
    uint8 public constant POOL_BNB = 1;

    /// @notice Delay on every operator change. Not configurable.
    uint256 public constant TIMELOCK = 7 days;

    uint256 public constant FEE_BPS_MIN = 50; // 0.5%
    uint256 public constant FEE_BPS_MAX = 300; // 3%
    uint256 public constant DEPOSIT_USD_MIN = 10_000e18;
    uint256 public constant DEPOSIT_USD_MAX = 1_000_000e18;

    uint256 public constant MIN_LOCK = 30 days;
    uint256 public constant MAX_LOCK = 1024 days;
    /// @notice Locked time needed to join the pot that takes 80% of every slash.
    uint256 public constant ELDER_SECONDS = 1024 days;

    /// @notice Early-exit slash: 100% at lock start, linear to 30% at lock end, 0% after.
    uint256 public constant SLASH_START_WAD = 1e18;
    uint256 public constant SLASH_END_WAD = 0.3e18;

    /// @notice 20% of every slash goes to the DAO, 80% to the whales.
    uint256 public constant SLASH_DAO_BPS = 2_000;
    /// @notice Before anyone has 1024 days, the whale 80% splits 90% stakers / 10% DAO.
    uint256 public constant PRE_ELDER_DAO_BPS = 1_000;

    /// @notice A whale with 1024+ days who let a lock lapse rejoins the elder pot this long
    ///         into the new lock.
    uint256 public constant ELDER_REJOIN_DELAY = 30 days;

    /// @notice Ceiling on a position's stacked boost: 100x, the largest single raise the hard
    ///         range allows ($10k to $1M). Cycling the minimum up and down cannot go past it.
    uint256 public constant MAX_BOOST_WAD = (DEPOSIT_USD_MAX / DEPOSIT_USD_MIN) * 1e18;

    uint256 public constant TIER_COUNT = 10;

    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;

    // ================================================================ immutables

    /// @notice The only privileged address. Cannot be changed or renounced.
    address public immutable operator;
    IERC20 public immutable usdc;
    AggregatorV3Interface public immutable bnbUsdFeed;
    uint8 public immutable bnbUsdFeedDecimals;
    /// @notice Maximum age of a BNB/USD answer accepted for a deposit.
    uint256 public immutable oracleStaleness;
    WhalePass public immutable pass;
    uint256 public immutable genesis;

    // =================================================================== storage

    mapping(Param => Timelocked.Uint) private _params;
    Timelocked.Str[10] private _tierURIs;
    Raise[] private _raises;

    mapping(uint8 pool => Pool) private _pools;
    mapping(uint8 pool => mapping(address wallet => Position)) private _positions;
    /// @notice Slash share already settled to a wallet and waiting to be claimed. Never slashed.
    mapping(uint8 pool => mapping(address wallet => uint256)) public unclaimed;
    /// @notice USD value (at deposit time) of a wallet's open positions, across both pools.
    mapping(address wallet => uint256) public activeUsd;
    /// @notice Highest pass tier a wallet has reached.
    mapping(address wallet => uint8) public passTier;

    // ==================================================================== events

    event Deposited(
        address indexed wallet,
        uint8 indexed pool,
        uint256 gross,
        uint256 fee,
        uint256 principal,
        uint256 usdValue,
        uint256 lockEnd
    );
    event Relocked(address indexed wallet, uint8 indexed pool, uint256 lockEnd, uint256 stakedSeconds);
    event Withdrawn(address indexed wallet, uint8 indexed pool, uint256 principal, uint256 payout, uint256 slashed);
    event SlashDistributed(uint8 indexed pool, uint256 toDao, uint256 toStakers, uint256 toElders);
    event Claimed(address indexed wallet, uint8 indexed pool, uint256 amount);
    event DaoSwept(uint8 indexed pool, address indexed to, uint256 amount);
    event LockExpired(address indexed wallet, uint8 indexed pool, uint256 stakedSeconds);
    event JoinedElders(address indexed wallet, uint8 indexed pool);
    event BoostApplied(address indexed wallet, uint8 indexed pool, uint256 boostWad);
    event PassTierChanged(address indexed wallet, uint8 tier);

    event ChangeQueued(Param indexed param, uint256 oldValue, uint256 newValue, uint256 eta);
    event ChangeCancelled(Param indexed param, uint256 cancelledValue);
    event TierURIQueued(uint8 indexed tier, string uri, uint256 eta);
    event TierURICancelled(uint8 indexed tier);

    // ==================================================================== errors

    error NotOperator();
    error ZeroAddress();
    error OutOfRange();
    error MinAboveMax();
    error BadPool();
    error BadTier();
    error BadURI();
    error BadLock();
    error ZeroAmount();
    error PositionExists();
    error NoPosition();
    error BelowMinimum(uint256 usdValue, uint256 minimum);
    error AboveMaximum(uint256 walletUsd, uint256 maximum);
    error CannotShortenLock();
    error NothingToClaim();
    error UnexpectedTokenAmount();
    error TransferFailed();
    error OracleBadPrice();
    error OracleIncompleteRound();
    error OracleStale();

    // =============================================================== constructor

    constructor(Config memory c) {
        if (c.operator == address(0) || c.daoWallet == address(0)) revert ZeroAddress();
        if (c.usdc == address(0) || c.bnbUsdFeed == address(0)) revert ZeroAddress();
        if (c.oracleStaleness == 0) revert OutOfRange();
        if (c.depositFeeBps < FEE_BPS_MIN || c.depositFeeBps > FEE_BPS_MAX) revert OutOfRange();
        if (c.minDepositUsd < DEPOSIT_USD_MIN || c.maxDepositUsd > DEPOSIT_USD_MAX) revert OutOfRange();
        if (c.minDepositUsd > c.maxDepositUsd) revert MinAboveMax();

        operator = c.operator;
        usdc = IERC20(c.usdc);
        bnbUsdFeed = AggregatorV3Interface(c.bnbUsdFeed);
        bnbUsdFeedDecimals = AggregatorV3Interface(c.bnbUsdFeed).decimals();
        oracleStaleness = c.oracleStaleness;
        genesis = block.timestamp;
        pass = new WhalePass();

        _params[Param.DepositFee].current = c.depositFeeBps;
        _params[Param.MinDeposit].current = c.minDepositUsd;
        _params[Param.MaxDeposit].current = c.maxDepositUsd;
        _params[Param.DaoWallet].current = uint256(uint160(c.daoWallet));
        for (uint256 i; i < TIER_COUNT; ++i) {
            _checkURI(c.tierURIs[i]);
            _tierURIs[i].current = c.tierURIs[i];
        }
        _pools[POOL_USDC].lastDay = block.timestamp / 1 days;
        _pools[POOL_BNB].lastDay = block.timestamp / 1 days;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    // =================================================================== deposit

    /// @notice Open a USDC position. `amount` is gross; the fee comes out of it.
    function depositUSDC(uint256 amount, uint256 lockDuration) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        if (usdc.balanceOf(address(this)) - before != amount) revert UnexpectedTokenAmount();
        // Binance-Peg USDC has 18 decimals and is valued at exactly $1.
        _deposit(POOL_USDC, msg.sender, amount, amount, lockDuration);
    }

    /// @notice Open a BNB position. `msg.value` is gross; the fee comes out of it.
    function depositBNB(uint256 lockDuration) external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        uint256 usdValue = (msg.value * bnbUsdPrice()) / (10 ** bnbUsdFeedDecimals);
        _deposit(POOL_BNB, msg.sender, msg.value, usdValue, lockDuration);
    }

    function _deposit(uint8 pool, address wallet, uint256 gross, uint256 usdValue, uint256 lockDuration) private {
        if (lockDuration < MIN_LOCK || lockDuration > MAX_LOCK) revert BadLock();
        Position storage p = _positions[pool][wallet];
        if (p.amount != 0) revert PositionExists();

        uint256 minimum = minDepositUsd();
        if (usdValue < minimum) revert BelowMinimum(usdValue, minimum);
        uint256 walletUsd = activeUsd[wallet] + usdValue;
        uint256 maximum = maxDepositUsd();
        if (walletUsd > maximum) revert AboveMaximum(walletUsd, maximum);
        activeUsd[wallet] = walletUsd;

        uint256 fee = (gross * depositFeeBps()) / BPS;
        uint256 principal = gross - fee;

        Pool storage ps = _pools[pool];
        _advance(ps, type(uint256).max);
        ps.daoOwed += fee;
        ps.totalPrincipal += principal;

        p.amount = principal;
        p.grossUsd = usdValue;
        p.boostWad = WAD;
        p.lockStart = uint40(block.timestamp);
        p.lockEnd = uint40(_lockEnd(lockDuration));
        p.lockDuration = uint40(lockDuration);
        p.vstart = block.timestamp - genesis;
        p.elderAt = uint40(block.timestamp + ELDER_SECONDS);
        p.raiseCursor = uint32(_maturedRaises());
        _enter(ps, p, wallet, pool);

        pass.mint(wallet);
        _bumpTier(wallet, lockDuration);

        emit Deposited(wallet, pool, gross, fee, principal, usdValue, p.lockEnd);
    }

    // ==================================================================== relock

    /// @notice Start a fresh lock on an existing position. Days staked carry over.
    /// @dev The slash curve restarts at 100%. The new lock can never end before the current one.
    ///      Relock while still locked and nothing is lost. Relock after the lock lapsed and time
    ///      weight restarts from zero, and a 1024-day whale waits 30 days to rejoin the elder pot.
    function relock(uint8 pool, uint256 lockDuration) external nonReentrant {
        _checkPool(pool);
        if (lockDuration < MIN_LOCK || lockDuration > MAX_LOCK) revert BadLock();
        _sync(msg.sender, pool);

        Position storage p = _positions[pool][msg.sender];
        if (p.amount == 0) revert NoPosition();
        uint256 newEnd = _lockEnd(lockDuration);
        if (newEnd < p.lockEnd) revert CannotShortenLock();

        Pool storage ps = _pools[pool];
        if (p.weight != 0) {
            // Still locked: bank the time served. `vstart` and `elderAt` carry over untouched.
            _leave(ps, p);
            p.accrued += uint40(block.timestamp - p.lockStart);
        } else {
            // Lapsed: the day count is kept, the time weight and elder seat are not.
            p.vstart = block.timestamp - genesis;
            uint256 remaining = p.accrued >= ELDER_SECONDS ? 0 : ELDER_SECONDS - p.accrued;
            if (remaining < ELDER_REJOIN_DELAY) remaining = ELDER_REJOIN_DELAY;
            p.elderAt = uint40(block.timestamp + remaining);
        }
        p.lockStart = uint40(block.timestamp);
        p.lockEnd = uint40(newEnd);
        p.lockDuration = uint40(lockDuration);
        _enter(ps, p, msg.sender, pool);

        _bumpTier(msg.sender, lockDuration);
        emit Relocked(msg.sender, pool, newEnd, p.accrued);
    }

    // ================================================================== withdraw

    /// @notice Close the position. Before the lock ends this costs the live slash percentage.
    function withdraw(uint8 pool) external nonReentrant returns (uint256 payout, uint256 slashed) {
        _checkPool(pool);
        _sync(msg.sender, pool);

        Position storage p = _positions[pool][msg.sender];
        uint256 amount = p.amount;
        if (amount == 0) revert NoPosition();

        slashed = Math.mulDiv(amount, _slashWad(p), WAD, Math.Rounding.Ceil);
        payout = amount - slashed;

        Pool storage ps = _pools[pool];
        if (p.weight != 0) _leave(ps, p);
        ps.totalPrincipal -= amount;
        activeUsd[msg.sender] -= p.grossUsd;
        delete _positions[pool][msg.sender];

        // The leaver is already out of both pots, so none of this comes back to them.
        if (slashed != 0) _distributeSlash(pool, ps, slashed);

        emit Withdrawn(msg.sender, pool, amount, payout, slashed);
        _send(pool, msg.sender, payout);
    }

    function _distributeSlash(uint8 pool, Pool storage ps, uint256 slashed) private {
        uint256 t = block.timestamp - genesis;
        uint256 toDao = (slashed * SLASH_DAO_BPS) / BPS;
        uint256 rest = slashed - toDao;
        uint256 toStakers;
        uint256 toElders;

        if (ps.elders.weightAt(t) != 0) {
            toElders = rest;
            ps.elders.distribute(rest, t);
        } else if (ps.stakers.weightAt(t) != 0) {
            uint256 daoCut = (rest * PRE_ELDER_DAO_BPS) / BPS;
            toStakers = rest - daoCut;
            toDao += daoCut;
            ps.stakers.distribute(toStakers, t);
        } else {
            // Nobody left to pay.
            toDao += rest;
        }

        ps.daoOwed += toDao;
        ps.rewardReserve += toStakers + toElders;
        emit SlashDistributed(pool, toDao, toStakers, toElders);
    }

    // ===================================================================== claim

    /// @notice Claim earned slash share. Works with or without an open position.
    function claim(uint8 pool) external nonReentrant returns (uint256 amount) {
        _checkPool(pool);
        _sync(msg.sender, pool);
        amount = unclaimed[pool][msg.sender];
        if (amount == 0) revert NothingToClaim();
        unclaimed[pool][msg.sender] = 0;
        _pools[pool].rewardReserve -= amount;
        emit Claimed(msg.sender, pool, amount);
        _send(pool, msg.sender, amount);
    }

    /// @notice Send accrued fees and DAO slash share to the DAO wallet. Anyone can call.
    function sweepDao(uint8 pool) external nonReentrant returns (uint256 amount) {
        _checkPool(pool);
        Pool storage ps = _pools[pool];
        amount = ps.daoOwed;
        if (amount == 0) revert NothingToClaim();
        ps.daoOwed = 0;
        address to = daoWallet();
        emit DaoSwept(pool, to, amount);
        _send(pool, to, amount);
    }

    // ====================================================================== sync

    /// @notice Apply what the clock did to a position: boosts from minimum raises, crossing
    ///         1024 days, and tidying up after a lock expired. Anyone can call for anyone.
    function sync(address wallet, uint8 pool) external nonReentrant {
        _checkPool(pool);
        _sync(wallet, pool);
    }

    /// @notice Process expired locks for up to `maxDays` days. Every other function does this
    ///         in full by itself; this exists so a pool that sat untouched for years can be
    ///         caught up in several small transactions instead of one large one.
    function advance(uint8 pool, uint256 maxDays) external nonReentrant {
        _checkPool(pool);
        _advance(_pools[pool], maxDays);
    }

    /// @dev Walk forward day by day. On each day that had locks ending, checkpoint the reward
    ///      accumulators and take the expired weight out of the pots. No slash is ever
    ///      distributed before this has run up to today, so the accumulators seen here are
    ///      exactly what they were at that day boundary. One storage read per quiet day.
    function _advance(Pool storage ps, uint256 maxDays) private {
        uint256 today = block.timestamp / 1 days;
        uint256 day = ps.lastDay;
        if (day >= today) return;
        uint256 end = today - day > maxDays ? day + maxDays : today;
        while (day < end) {
            unchecked {
                ++day;
            }
            Expiry storage e = ps.expiries[day];
            uint256 a = e.a;
            if (a == 0) continue;
            ps.checkpoints[day] = Checkpoint({
                accP: ps.stakers.accP,
                accQ: ps.stakers.accQ,
                elderAccP: ps.elders.accP,
                elderAccQ: ps.elders.accQ
            });
            ps.stakers.removeAggregate(a, e.aS);
            if (e.elderA != 0) ps.elders.removeAggregate(e.elderA, e.elderAS);
            delete ps.expiries[day];
        }
        ps.lastDay = day;
    }

    function _sync(address wallet, uint8 pool) private {
        Pool storage ps = _pools[pool];
        _advance(ps, type(uint256).max);
        Position storage p = _positions[pool][wallet];
        if (p.amount == 0) return;

        // 1. Settle what the stored weight earned, up to now or up to its lock end.
        bool active = p.weight != 0;
        if (active) {
            uint256 owed = _earned(ps, p, true);
            if (owed != 0) unclaimed[pool][wallet] += owed;
        }

        // 2. Minimum-raise boosts that took effect since the last touch.
        (uint256 boostWad, uint256 cursor) = _boostNow(p);
        bool boosted = boostWad != p.boostWad;
        if (cursor != p.raiseCursor) p.raiseCursor = uint32(cursor);
        if (boosted) {
            p.boostWad = boostWad;
            emit BoostApplied(wallet, pool, boostWad);
        }
        if (!active) return;

        // 3. Expired, re-weighed, or graduated.
        if (block.timestamp >= p.lockEnd) {
            // `_advance` already removed this weight from the pots at the day boundary.
            p.weight = 0;
            p.elder = false;
            p.accrued += p.lockEnd - p.lockStart;
            p.lockStart = p.lockEnd;
            emit LockExpired(wallet, pool, p.accrued);
        } else if (boosted) {
            _leave(ps, p);
            _enter(ps, p, wallet, pool);
        } else if (!p.elder && block.timestamp >= p.elderAt) {
            _joinElders(ps, p, wallet, pool);
        }
    }

    /// @dev Earnings of the stored weight since its snapshots. For a position past its lock end
    ///      the accumulators are read from the checkpoint taken at that day boundary (or are
    ///      still unchanged since then, if the day has not been processed yet).
    function _earned(Pool storage ps, Position storage p, bool write) private returns (uint256 owed) {
        (uint256 accP, uint256 accQ, uint256 elderAccP, uint256 elderAccQ) = _accumulatorsFor(ps, p);
        owed = TimeWeightedPot.earned(p.weight, p.vstart, accP, accQ, p.snapP, p.snapQ);
        if (p.elder) owed += TimeWeightedPot.earned(p.weight, p.vstart, elderAccP, elderAccQ, p.elderSnapP, p.elderSnapQ);
        if (write) {
            p.snapP = accP;
            p.snapQ = accQ;
            if (p.elder) {
                p.elderSnapP = elderAccP;
                p.elderSnapQ = elderAccQ;
            }
        }
    }

    function _accumulatorsFor(Pool storage ps, Position storage p)
        private
        view
        returns (uint256, uint256, uint256, uint256)
    {
        uint256 endDay = p.lockEnd / 1 days;
        if (endDay <= ps.lastDay) {
            Checkpoint storage c = ps.checkpoints[endDay];
            return (c.accP, c.accQ, c.elderAccP, c.elderAccQ);
        }
        return (ps.stakers.accP, ps.stakers.accQ, ps.elders.accP, ps.elders.accQ);
    }

    /// @dev Put a locked position into the pots with its current amount, lock and boost.
    ///      Caller has set the lock fields, `vstart` and `elderAt`.
    function _enter(Pool storage ps, Position storage p, address wallet, uint8 pool) private {
        uint256 w = Math.mulDiv(p.amount * p.lockDuration, p.boostWad, WAD);
        p.weight = w;
        ps.stakers.join(w, p.vstart);
        p.snapP = ps.stakers.accP;
        p.snapQ = ps.stakers.accQ;
        Expiry storage e = ps.expiries[p.lockEnd / 1 days];
        e.a += w;
        e.aS += w * p.vstart;
        if (block.timestamp >= p.elderAt) _joinElders(ps, p, wallet, pool);
    }

    function _joinElders(Pool storage ps, Position storage p, address wallet, uint8 pool) private {
        p.elder = true;
        ps.elders.join(p.weight, p.vstart);
        p.elderSnapP = ps.elders.accP;
        p.elderSnapQ = ps.elders.accQ;
        Expiry storage e = ps.expiries[p.lockEnd / 1 days];
        e.elderA += p.weight;
        e.elderAS += p.weight * p.vstart;
        emit JoinedElders(wallet, pool);
    }

    /// @dev Take a still-locked position out of the pots and out of its expiry bucket.
    ///      Caller settles first.
    function _leave(Pool storage ps, Position storage p) private {
        uint256 w = p.weight;
        uint256 wS = w * p.vstart;
        Expiry storage e = ps.expiries[p.lockEnd / 1 days];
        ps.stakers.leave(w, p.vstart);
        e.a -= w;
        e.aS -= wS;
        if (p.elder) {
            ps.elders.leave(w, p.vstart);
            e.elderA -= w;
            e.elderAS -= wS;
            p.elder = false;
        }
        p.weight = 0;
    }

    function _bumpTier(address wallet, uint256 lockDuration) private {
        uint8 tier = tierFor(activeUsd[wallet], lockDuration);
        if (tier > passTier[wallet]) {
            passTier[wallet] = tier;
            emit PassTierChanged(wallet, tier);
        }
    }

    function _send(uint8 pool, address to, uint256 amount) private {
        if (amount == 0) return;
        if (pool == POOL_USDC) {
            usdc.safeTransfer(to, amount);
        } else {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        }
    }

    function _checkPool(uint8 pool) private pure {
        if (pool > POOL_BNB) revert BadPool();
    }

    /// @dev Locks end at the first UTC midnight on or after `now + lockDuration`.
    function _lockEnd(uint256 lockDuration) private view returns (uint256) {
        return ((block.timestamp + lockDuration + 1 days - 1) / 1 days) * 1 days;
    }

    /// @dev Artwork URIs are embedded in the pass's JSON metadata, so no quotes, backslashes
    ///      or control characters.
    function _checkURI(string memory uri) private pure {
        bytes memory b = bytes(uri);
        if (b.length > 512) revert BadURI();
        for (uint256 i; i < b.length; ++i) {
            if (b[i] < 0x20 || b[i] == 0x22 || b[i] == 0x5c || b[i] == 0x7f) revert BadURI();
        }
    }

    // ============================================================ time and boost

    /// @dev Locked seconds served as of `t`. Stops counting at `lockEnd`.
    function _stakedSeconds(Position storage p, uint256 t) private view returns (uint256) {
        if (t <= p.lockStart) return p.accrued;
        uint256 end = t < p.lockEnd ? t : p.lockEnd;
        return uint256(p.accrued) + end - p.lockStart;
    }

    function _slashWad(Position storage p) private view returns (uint256) {
        if (block.timestamp >= p.lockEnd) return 0;
        uint256 elapsed = block.timestamp - p.lockStart;
        uint256 duration = uint256(p.lockEnd) - p.lockStart;
        return SLASH_START_WAD - ((SLASH_START_WAD - SLASH_END_WAD) * elapsed) / duration;
    }

    /// @dev Number of raises that have taken effect. At most one raise (the last) can be pending.
    function _maturedRaises() private view returns (uint256 n) {
        n = _raises.length;
        if (n != 0 && _raises[n - 1].eta > block.timestamp) --n;
    }

    /// @dev Boost after applying every matured raise the position has not seen yet:
    ///        boost *= 1 + (newMin/oldMin - 1) * min(stakedDays / 1024, 1)
    ///      using days staked at the moment each raise took effect. Only a position that was
    ///      locked at that moment is boosted. One iteration per raise the position missed;
    ///      raises are at least 7 days apart, so this is bounded by time, not by stakers.
    function _boostNow(Position storage p) private view returns (uint256 boostWad, uint256 cursor) {
        boostWad = p.boostWad;
        cursor = p.raiseCursor;
        uint256 matured = _maturedRaises();
        for (; cursor < matured; ++cursor) {
            Raise memory r = _raises[cursor];
            if (r.eta >= p.lockEnd) continue; // not locked when it landed
            uint256 staked = _stakedSeconds(p, r.eta);
            if (staked > ELDER_SECONDS) staked = ELDER_SECONDS;
            uint256 factor = WAD + ((uint256(r.ratioWad) - WAD) * staked) / ELDER_SECONDS;
            boostWad = (boostWad * factor) / WAD;
            if (boostWad > MAX_BOOST_WAD) boostWad = MAX_BOOST_WAD;
        }
    }

    // ==================================================================== oracle

    /// @notice BNB/USD from Chainlink. Reverts on a non-positive, incomplete or stale answer.
    function bnbUsdPrice() public view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = bnbUsdFeed.latestRoundData();
        if (answer <= 0) revert OracleBadPrice();
        if (updatedAt == 0 || answeredInRound < roundId) revert OracleIncompleteRound();
        if (block.timestamp > updatedAt && block.timestamp - updatedAt > oracleStaleness) revert OracleStale();
        return uint256(answer);
    }

    // ================================================================== operator

    /// @notice Queue a settings change. It takes effect by itself 7 days later.
    function queueChange(Param param, uint256 value) external onlyOperator {
        if (param == Param.DepositFee) {
            if (value < FEE_BPS_MIN || value > FEE_BPS_MAX) revert OutOfRange();
        } else if (param == Param.MinDeposit) {
            if (value < DEPOSIT_USD_MIN || value > DEPOSIT_USD_MAX) revert OutOfRange();
            Timelocked.Uint storage max = _params[Param.MaxDeposit];
            if (value > max.get() || (max.hasPending() && value > max.pending)) revert MinAboveMax();
        } else if (param == Param.MaxDeposit) {
            if (value < DEPOSIT_USD_MIN || value > DEPOSIT_USD_MAX) revert OutOfRange();
            Timelocked.Uint storage min = _params[Param.MinDeposit];
            if (value < min.get() || (min.hasPending() && value < min.pending)) revert MinAboveMax();
        } else {
            if (value == 0 || value > type(uint160).max) revert ZeroAddress();
        }

        (uint256 old, uint64 eta) = _params[param].queue(value, TIMELOCK);
        if (param == Param.MinDeposit && value > old) {
            // Recorded now, applied to positions only once `eta` has passed.
            _raises.push(Raise({eta: eta, ratioWad: uint192((value * WAD) / old)}));
        }
        emit ChangeQueued(param, old, value, eta);
    }

    /// @notice Cancel a queued change. Only possible before it has taken effect.
    function cancelChange(Param param) external onlyOperator {
        uint256 cancelled = _params[param].cancel();
        if (param == Param.MinDeposit) {
            uint256 n = _raises.length;
            if (n != 0 && _raises[n - 1].eta > block.timestamp) _raises.pop();
        }
        emit ChangeCancelled(param, cancelled);
    }

    /// @notice Queue new artwork for a pass tier. Same 7-day timelock.
    function queueTierURI(uint8 tier, string calldata uri) external onlyOperator {
        if (tier >= TIER_COUNT) revert BadTier();
        _checkURI(uri);
        uint64 eta = _tierURIs[tier].queue(uri, TIMELOCK);
        emit TierURIQueued(tier, uri, eta);
    }

    function cancelTierURI(uint8 tier) external onlyOperator {
        if (tier >= TIER_COUNT) revert BadTier();
        _tierURIs[tier].cancel();
        emit TierURICancelled(tier);
    }

    // ===================================================================== views

    function depositFeeBps() public view returns (uint256) {
        return _params[Param.DepositFee].get();
    }

    function minDepositUsd() public view returns (uint256) {
        return _params[Param.MinDeposit].get();
    }

    function maxDepositUsd() public view returns (uint256) {
        return _params[Param.MaxDeposit].get();
    }

    function daoWallet() public view returns (address) {
        return address(uint160(_params[Param.DaoWallet].get()));
    }

    /// @notice A queued change that has not taken effect yet. `eta` is zero if there is none.
    function pendingChange(Param param) external view returns (uint256 value, uint256 eta) {
        Timelocked.Uint storage s = _params[param];
        if (s.hasPending()) return (s.pending, s.eta);
    }

    function tierURI(uint8 tier) external view returns (string memory) {
        if (tier >= TIER_COUNT) revert BadTier();
        return _tierURIs[tier].get();
    }

    function pendingTierURI(uint8 tier) external view returns (string memory uri, uint256 eta) {
        if (tier >= TIER_COUNT) revert BadTier();
        Timelocked.Str storage s = _tierURIs[tier];
        if (s.hasPending()) return (s.pending, s.eta);
    }

    /// @notice Pass tier (0-9) for a deposit size and lock length: five size bands plus six lock bands.
    function tierFor(uint256 usdValue, uint256 lockDuration) public pure returns (uint8) {
        uint8 size = usdValue >= 1_000_000e18
            ? 4
            : usdValue >= 750_000e18 ? 3 : usdValue >= 500_000e18 ? 2 : usdValue >= 250_000e18 ? 1 : 0;
        uint8 lock = lockDuration >= 1024 days
            ? 5
            : lockDuration >= 730 days
                ? 4
                : lockDuration >= 365 days ? 3 : lockDuration >= 180 days ? 2 : lockDuration >= 90 days ? 1 : 0;
        return size + lock;
    }

    /// @notice Telegram gate: holds the pass and has an open position in either pool.
    function hasAccess(address wallet) external view returns (bool) {
        if (wallet == address(0)) return false;
        return pass.balanceOf(wallet) != 0
            && (_positions[POOL_USDC][wallet].amount != 0 || _positions[POOL_BNB][wallet].amount != 0);
    }

    /// @notice Live view of a position, as if `sync` had just been called.
    function positionOf(address wallet, uint8 pool) external view returns (PositionView memory v) {
        _checkPool(pool);
        Position storage p = _positions[pool][wallet];
        Pool storage ps = _pools[pool];

        v.earned = unclaimed[pool][wallet];
        if (p.amount == 0) return v;

        if (p.weight != 0) {
            (uint256 accP, uint256 accQ, uint256 elderAccP, uint256 elderAccQ) = _accumulatorsFor(ps, p);
            v.earned += TimeWeightedPot.earned(p.weight, p.vstart, accP, accQ, p.snapP, p.snapQ);
            if (p.elder) {
                v.earned +=
                    TimeWeightedPot.earned(p.weight, p.vstart, elderAccP, elderAccQ, p.elderSnapP, p.elderSnapQ);
            }
        }

        (uint256 boostWad,) = _boostNow(p);
        v.amount = p.amount;
        v.grossUsd = p.grossUsd;
        v.lockStart = p.lockStart;
        v.lockEnd = p.lockEnd;
        v.lockDuration = p.lockDuration;
        v.stakedSeconds = _stakedSeconds(p, block.timestamp);
        v.boostWad = boostWad;
        v.locked = block.timestamp < p.lockEnd;
        v.weight = v.locked ? Math.mulDiv(p.amount * p.lockDuration, boostWad, WAD) : 0;
        v.slashWad = _slashWad(p);
        v.slashAmount = Math.mulDiv(p.amount, v.slashWad, WAD, Math.Rounding.Ceil);
        v.elder = v.locked && block.timestamp >= p.elderAt;
        v.elderAt = p.elderAt;
        // True when a sync would raise this position's weight or seat it in the elder pot.
        v.needsSync = v.locked && (v.weight != p.weight || v.elder != p.elder);
    }

    function poolInfo(uint8 pool) external view returns (PoolView memory v) {
        _checkPool(pool);
        Pool storage ps = _pools[pool];
        v.totalPrincipal = ps.totalPrincipal;
        v.rewardReserve = ps.rewardReserve;
        v.daoOwed = ps.daoOwed;

        // Pot sums as they will be once expired days are processed.
        uint256 a = ps.stakers.sumA;
        uint256 aS = ps.stakers.sumAS;
        uint256 elderA = ps.elders.sumA;
        uint256 elderAS = ps.elders.sumAS;
        uint256 today = block.timestamp / 1 days;
        for (uint256 day = ps.lastDay + 1; day <= today; ++day) {
            Expiry storage e = ps.expiries[day];
            if (e.a == 0) continue;
            a -= e.a;
            aS -= e.aS;
            elderA -= e.elderA;
            elderAS -= e.elderAS;
        }
        uint256 t = block.timestamp - genesis;
        v.stakerWeight = a * t - aS;
        v.elderWeight = elderA * t - elderAS;
        v.elderPhase = v.elderWeight != 0;
    }

    function raiseCount() external view returns (uint256) {
        return _raises.length;
    }

    function raiseAt(uint256 index) external view returns (uint256 eta, uint256 ratioWad) {
        Raise memory r = _raises[index];
        return (r.eta, r.ratioWad);
    }
}
