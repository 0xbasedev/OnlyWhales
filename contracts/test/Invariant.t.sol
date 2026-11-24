// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {OnlyWhalesVault} from "../src/OnlyWhalesVault.sol";
import {MockUSDC, MockFeed} from "./mocks/Mocks.sol";

/// @dev Random whales depositing, relocking, bailing early, claiming, plus an operator moving the
///      minimum up and down and the clock jumping around.
contract Handler is Test {
    OnlyWhalesVault public vault;
    MockUSDC public usdc;
    MockFeed public feed;
    address public operator;
    address public dao;
    address[] public actors;

    // ghost accounting, per pool
    uint256[2] public grossIn;
    uint256[2] public paidOut; // principal payouts + claims + DAO sweeps
    uint256 public withdrawals;
    uint256 public slashedWithdrawals;
    bool public brokeConservation;

    bytes32 private constant WITHDRAWN = keccak256("Withdrawn(address,uint8,uint256,uint256,uint256)");
    bytes32 private constant SLASH_DISTRIBUTED = keccak256("SlashDistributed(uint8,uint256,uint256,uint256)");

    constructor(OnlyWhalesVault vault_, MockUSDC usdc_, MockFeed feed_, address operator_, address dao_) {
        vault = vault_;
        usdc = usdc_;
        feed = feed_;
        operator = operator_;
        dao = dao_;
        for (uint256 i; i < 6; ++i) {
            actors.push(makeAddr(string.concat("whale", vm.toString(i))));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function depositUSDC(uint256 seed, uint256 amount, uint256 lock) external {
        address who = _actor(seed);
        amount = bound(amount, vault.minDepositUsd(), vault.maxDepositUsd());
        lock = bound(lock, 30 days, 1024 days);
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        try vault.depositUSDC(amount, lock) {
            grossIn[0] += amount;
        } catch {}
        vm.stopPrank();
    }

    function depositBNB(uint256 seed, uint256 usd, uint256 lock, uint256 price) external {
        address who = _actor(seed);
        price = bound(price, 50e8, 5_000e8);
        feed.setAnswer(int256(price));
        usd = bound(usd, vault.minDepositUsd(), vault.maxDepositUsd());
        lock = bound(lock, 30 days, 1024 days);
        uint256 value = (usd * 1e8) / price + 1;
        vm.deal(who, who.balance + value);
        vm.prank(who);
        try vault.depositBNB{value: value}(lock) {
            grossIn[1] += value;
        } catch {}
    }

    function relock(uint256 seed, uint8 pool, uint256 lock) external {
        lock = bound(lock, 30 days, 1024 days);
        vm.prank(_actor(seed));
        try vault.relock(pool % 2, lock) {} catch {}
    }

    function withdraw(uint256 seed, uint8 pool) external {
        pool = pool % 2;
        address who = _actor(seed);
        uint256 principal = vault.positionOf(who, pool).amount;
        vm.recordLogs();
        vm.prank(who);
        try vault.withdraw(pool) returns (uint256 payout, uint256 slashed) {
            paidOut[pool] += payout;
            ++withdrawals;
            if (slashed != 0) ++slashedWithdrawals;
            // payout + redistributed slash == principal, checked on every single exit
            uint256 redistributed;
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].topics[0] == SLASH_DISTRIBUTED) {
                    (uint256 toDao, uint256 toStakers, uint256 toElders) =
                        abi.decode(logs[i].data, (uint256, uint256, uint256));
                    redistributed = toDao + toStakers + toElders;
                }
            }
            if (payout + slashed != principal || redistributed != slashed) brokeConservation = true;
        } catch {
            vm.getRecordedLogs();
        }
    }

    function claim(uint256 seed, uint8 pool) external {
        pool = pool % 2;
        vm.prank(_actor(seed));
        try vault.claim(pool) returns (uint256 amount) {
            paidOut[pool] += amount;
        } catch {}
    }

    function sync(uint256 seed, uint8 pool) external {
        vault.sync(_actor(seed), pool % 2);
    }

    function sweepDao(uint8 pool) external {
        pool = pool % 2;
        try vault.sweepDao(pool) returns (uint256 amount) {
            paidOut[pool] += amount;
        } catch {}
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1, 200 days);
        vm.warp(block.timestamp + secs);
    }

    function operatorMovesMinimum(uint256 value) external {
        value = bound(value, 10_000e18, vault.maxDepositUsd());
        vm.prank(operator);
        try vault.queueChange(OnlyWhalesVault.Param.MinDeposit, value) {} catch {}
    }

    function operatorMovesFee(uint256 value) external {
        value = bound(value, 50, 300);
        vm.prank(operator);
        try vault.queueChange(OnlyWhalesVault.Param.DepositFee, value) {} catch {}
    }

    function operatorCancels(uint8 param) external {
        vm.prank(operator);
        try vault.cancelChange(OnlyWhalesVault.Param(param % 4)) {} catch {}
    }
}

contract InvariantTest is Test {
    OnlyWhalesVault internal vault;
    MockUSDC internal usdc;
    MockFeed internal feed;
    Handler internal handler;
    address internal operator = makeAddr("operator");
    address internal dao = makeAddr("dao");

    function setUp() public {
        vm.warp(1_750_000_000);
        usdc = new MockUSDC();
        feed = new MockFeed(8, 600e8);
        string[10] memory uris;
        vault = new OnlyWhalesVault(
            OnlyWhalesVault.Config({
                operator: operator,
                daoWallet: dao,
                usdc: address(usdc),
                bnbUsdFeed: address(feed),
                oracleStaleness: 1 hours,
                depositFeeBps: 300,
                minDepositUsd: 250_000e18,
                maxDepositUsd: 1_000_000e18,
                tierURIs: uris
            })
        );
        handler = new Handler(vault, usdc, feed, operator, dao);
        targetContract(address(handler));
    }

    function _held(uint8 pool) internal view returns (uint256) {
        return pool == 0 ? usdc.balanceOf(address(vault)) : address(vault).balance;
    }

    /// The vault holds exactly principal + unclaimed whale rewards + what the DAO is owed.
    function invariant_VaultCoversWhatItOwes() public view {
        for (uint8 pool; pool < 2; ++pool) {
            OnlyWhalesVault.PoolView memory p = vault.poolInfo(pool);
            assertEq(_held(pool), p.totalPrincipal + p.rewardReserve + p.daoOwed);
        }
    }

    /// Money in == money still held + money paid out. Nothing appears, nothing vanishes.
    function invariant_Conservation() public view {
        for (uint8 pool; pool < 2; ++pool) {
            assertEq(handler.grossIn(pool), _held(pool) + handler.paidOut(pool));
        }
        assertFalse(handler.brokeConservation(), "payout + redistributed slash != principal");
    }

    /// Sum of positions is the pool's principal, and all claimable rewards fit in the reserve.
    function invariant_PrincipalAndRewardsReconcile() public view {
        for (uint8 pool; pool < 2; ++pool) {
            uint256 principal;
            uint256 claimable;
            for (uint256 i; i < handler.actorCount(); ++i) {
                OnlyWhalesVault.PositionView memory v = vault.positionOf(handler.actors(i), pool);
                principal += v.amount;
                claimable += v.earned;
            }
            OnlyWhalesVault.PoolView memory p = vault.poolInfo(pool);
            assertEq(principal, p.totalPrincipal);
            assertLe(claimable, p.rewardReserve);
        }
    }

    /// Operator settings never leave the hard-coded ranges.
    function invariant_SettingsInsideHardRanges() public view {
        assertGe(vault.depositFeeBps(), 50);
        assertLe(vault.depositFeeBps(), 300);
        assertGe(vault.minDepositUsd(), 10_000e18);
        assertLe(vault.maxDepositUsd(), 1_000_000e18);
        assertLe(vault.minDepositUsd(), vault.maxDepositUsd());
        assertEq(vault.operator(), operator);
    }

    /// At any point, everyone can sync, leave, claim and the DAO can sweep. Nothing reverts and
    /// the vault never runs short. What is left is rounding dust only.
    function invariant_EveryoneCanAlwaysExit() public {
        uint256 snap = vm.snapshotState();
        for (uint8 pool; pool < 2; ++pool) {
            uint256 dust;
            for (uint256 i; i < handler.actorCount(); ++i) {
                address who = handler.actors(i);
                OnlyWhalesVault.PositionView memory v = vault.positionOf(who, pool);
                if (v.amount != 0) {
                    vm.prank(who);
                    (uint256 payout, uint256 slashed) = vault.withdraw(pool);
                    assertEq(payout + slashed, v.amount);
                }
            }
            for (uint256 i; i < handler.actorCount(); ++i) {
                address who = handler.actors(i);
                if (vault.positionOf(who, pool).earned != 0) {
                    vm.prank(who);
                    vault.claim(pool);
                }
            }
            if (vault.poolInfo(pool).daoOwed != 0) vault.sweepDao(pool);

            OnlyWhalesVault.PoolView memory p = vault.poolInfo(pool);
            assertEq(p.totalPrincipal, 0);
            assertEq(p.daoOwed, 0);
            dust = _held(pool);
            assertEq(dust, p.rewardReserve, "only undistributed rounding dust remains");
            assertLt(dust, 1e12, "dust stays negligible");
        }
        vm.revertToState(snap);
    }

    /// Printed with -vv so a run can be checked for real coverage, not just green ticks.
    function afterInvariant() public view {
        console.log("deposited USDC / BNB (wei):", handler.grossIn(0), handler.grossIn(1));
        console.log("exits / of which slashed:", handler.withdrawals(), handler.slashedWithdrawals());
        console.log("raises recorded:", vault.raiseCount());
    }
}
