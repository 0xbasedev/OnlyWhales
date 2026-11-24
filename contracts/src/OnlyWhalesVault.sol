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
///  across relocks. A position whose lock ran out stops counting (and should stop earning) until
///  it is relocked. Three state transitions happen at a moment in time rather than in a
///  transaction: a lock expiring, a staker crossing 1024 days, and a minimum-raise boost taking
///  effect. They are applied lazily the next time the position is touched, and `sync` is
///  permissionless so anyone can apply them for any position at any time.
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
        uint32 raiseCursor; // next entry of `_raises` to apply
        bool elder; // currently in the 1024-day pot
    }

    struct Pool {
        TimeWeightedPot.Pot stakers;
        TimeWeightedPot.Pot elders;
        uint256 totalPrincipal;
        uint256 rewardReserve; // slash distributed to whales and not yet claimed
        uint256 daoOwed; // fees + DAO share of slashes, waiting for `sweepDao`
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

    /// @notice Ceiling on a position's stacked boost. Keeps weight math far from overflow no
    ///         matter how many times the minimum is raised.
    uint256 public constant MAX_BOOST_WAD = 1_000_000e18;

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
    event BecameElder(address indexed wallet, uint8 indexed pool);
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
            _tierURIs[i].current = c.tierURIs[i];
        }
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
        ps.daoOwed += fee;
        ps.totalPrincipal += principal;

        p.amount = principal;
        p.grossUsd = usdValue;
        p.boostWad = WAD;
        p.lockStart = uint40(block.timestamp);
        p.lockEnd = uint40(block.timestamp + lockDuration);
        p.lockDuration = uint40(lockDuration);
        p.raiseCursor = uint32(_maturedRaises());
        _enter(ps, p, wallet, pool);

        pass.mint(wallet);
        _bumpTier(wallet, lockDuration);

        emit Deposited(wallet, pool, gross, fee, principal, usdValue, p.lockEnd);
    }

    // ==================================================================== relock

    /// @notice Start a fresh lock on an existing position. Days staked carry over.
    /// @dev The slash curve restarts at 100%. The new lock can never end before the current one.
    function relock(uint8 pool, uint256 lockDuration) external nonReentrant {
        _checkPool(pool);
        if (lockDuration < MIN_LOCK || lockDuration > MAX_LOCK) revert BadLock();
        _sync(msg.sender, pool);

        Position storage p = _positions[pool][msg.sender];
        if (p.amount == 0) revert NoPosition();
        uint256 newEnd = block.timestamp + lockDuration;
        if (newEnd < p.lockEnd) revert CannotShortenLock();

        Pool storage ps = _pools[pool];
        if (p.weight != 0) {
            // Still locked (sync would have expired it otherwise): bank the time served so far.
            _leave(ps, p);
            p.accrued += uint40(block.timestamp - p.lockStart);
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

    /// @notice Apply everything that happened to a position by the clock alone: boosts from
    ///         minimum raises, lock expiry, and crossing 1024 days. Anyone can call for anyone.
    function sync(address wallet, uint8 pool) external nonReentrant {
        _checkPool(pool);
        _sync(wallet, pool);
    }

    function _sync(address wallet, uint8 pool) private {
        Position storage p = _positions[pool][wallet];
        if (p.amount == 0) return;
        Pool storage ps = _pools[pool];

        // 1. Settle what the stored weight has earned so far.
        bool active = p.weight != 0;
        if (active) {
            uint256 owed = ps.stakers.earned(p.weight, p.vstart, p.snapP, p.snapQ);
            p.snapP = ps.stakers.accP;
            p.snapQ = ps.stakers.accQ;
            if (p.elder) {
                owed += ps.elders.earned(p.weight, p.vstart, p.elderSnapP, p.elderSnapQ);
                p.elderSnapP = ps.elders.accP;
                p.elderSnapQ = ps.elders.accQ;
            }
            if (owed != 0) unclaimed[pool][wallet] += owed;
        }

        // 2. Minimum-raise boosts that took effect since the last touch. An expired position
        //    keeps its boost for the next relock.
        (uint256 boostWad, uint256 cursor) = _boostNow(p);
        bool boosted = boostWad != p.boostWad;
        if (cursor != p.raiseCursor) p.raiseCursor = uint32(cursor);
        if (boosted) {
            p.boostWad = boostWad;
            emit BoostApplied(wallet, pool, boostWad);
        }
        if (!active) return;

        // 3. Lock expiry, re-weigh, or graduation.
        if (block.timestamp >= p.lockEnd) {
            _leave(ps, p);
            p.accrued += p.lockEnd - p.lockStart;
            p.lockStart = p.lockEnd;
            emit LockExpired(wallet, pool, p.accrued);
        } else if (boosted) {
            _leave(ps, p);
            _enter(ps, p, wallet, pool);
        } else if (!p.elder && _stakedSeconds(p, block.timestamp) >= ELDER_SECONDS) {
            p.elder = true;
            ps.elders.join(p.weight, p.vstart);
            p.elderSnapP = ps.elders.accP;
            p.elderSnapQ = ps.elders.accQ;
            emit BecameElder(wallet, pool);
        }
    }

    /// @dev Put a locked position into the pots with its current amount, lock and boost.
    ///      `lockStart` must be `block.timestamp` or the position must still be inside its lock.
    function _enter(Pool storage ps, Position storage p, address wallet, uint8 pool) private {
        uint256 staked = _stakedSeconds(p, block.timestamp);
        p.weight = Math.mulDiv(p.amount * p.lockDuration, p.boostWad, WAD);
        p.vstart = block.timestamp - genesis - staked;
        ps.stakers.join(p.weight, p.vstart);
        p.snapP = ps.stakers.accP;
        p.snapQ = ps.stakers.accQ;
        if (staked >= ELDER_SECONDS) {
            if (!p.elder) emit BecameElder(wallet, pool);
            p.elder = true;
            ps.elders.join(p.weight, p.vstart);
            p.elderSnapP = ps.elders.accP;
            p.elderSnapQ = ps.elders.accQ;
        }
    }

    /// @dev Remove a position's weight from the pots. Caller settles first and resets `weight`.
    function _leave(Pool storage ps, Position storage p) private {
        ps.stakers.leave(p.weight, p.vstart);
        if (p.elder) {
            ps.elders.leave(p.weight, p.vstart);
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
    ///      using days staked at the moment each raise took effect. One iteration per raise the
    ///      position missed; raises are at least 7 days apart, so this is bounded by time, not
    ///      by the number of stakers.
    function _boostNow(Position storage p) private view returns (uint256 boostWad, uint256 cursor) {
        boostWad = p.boostWad;
        cursor = p.raiseCursor;
        uint256 matured = _maturedRaises();
        for (; cursor < matured; ++cursor) {
            Raise memory r = _raises[cursor];
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
            v.earned += ps.stakers.earned(p.weight, p.vstart, p.snapP, p.snapQ);
            if (p.elder) v.earned += ps.elders.earned(p.weight, p.vstart, p.elderSnapP, p.elderSnapQ);
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
        v.elder = v.locked && v.stakedSeconds >= ELDER_SECONDS;
        v.needsSync = v.weight != p.weight || v.elder != p.elder;
    }

    function poolInfo(uint8 pool) external view returns (PoolView memory v) {
        _checkPool(pool);
        Pool storage ps = _pools[pool];
        uint256 t = block.timestamp - genesis;
        v.totalPrincipal = ps.totalPrincipal;
        v.rewardReserve = ps.rewardReserve;
        v.daoOwed = ps.daoOwed;
        v.stakerWeight = ps.stakers.weightAt(t);
        v.elderWeight = ps.elders.weightAt(t);
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
