// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {OnlyWhalesVault} from "../src/OnlyWhalesVault.sol";

/// @notice Attacks found in review, kept as tests so they stay dead.
contract RegressionTest is Base {
    uint256 internal constant DUST = 1e9;

    function setUp() public override {
        super.setUp();
        vault = _deploy(300, 10_000e18, 1_000_000e18); // cheapest possible attacker position
        pass = vault.pass();
    }

    // ------------------------------------------------ sniping a slash from the sidelines

    /// A whale with 1024 days lets the lock lapse, sits liquid, and relocks in the same block as
    /// someone else's exit to take the whole 80%. Must earn nothing.
    function test_LapsedElder_CannotRelockInFrontOfASlash() public {
        _depositUSDC(alice, 10_000e18, 1024 days);
        _skip(1024 days); // alice: 1024 days served, lock over, free to leave
        _depositUSDC(bob, 1_000_000e18, 1024 days);
        _skip(200 days);
        _depositUSDC(carol, 1_000_000e18, 30 days);
        _skip(1 days);

        vm.prank(alice);
        vault.relock(USDC, 30 days); // front-run
        (, uint256 slashed) = _withdraw(carol, USDC);

        assertFalse(_pool(USDC).elderPhase, "one relock does not flip the pool");
        assertEq(_pos(alice, USDC).earned, 0, "sniper gets nothing");
        assertApproxEqAbs(_pos(bob, USDC).earned, (slashed * 72) / 100, DUST, "the whale who stayed gets it");
    }

    function test_LapsedElder_EarnsNothingEvenAFewBlocksLater() public {
        _depositUSDC(alice, 10_000e18, 1024 days);
        _skip(1024 days);
        _depositUSDC(bob, 1_000_000e18, 1024 days);
        _skip(200 days);
        vm.prank(alice);
        vault.relock(USDC, 30 days);
        _skip(1 hours);
        _depositUSDC(carol, 1_000_000e18, 30 days);
        (, uint256 slashed) = _withdraw(carol, USDC);

        // Not an elder yet, and an hour of time weight on $10k against 200 days on $1M.
        assertFalse(_pool(USDC).elderPhase);
        assertLt(_pos(alice, USDC).earned, slashed / 1_000_000);
    }

    function test_LapsedElder_RejoinsThirtyDaysIntoTheNewLock() public {
        _depositUSDC(alice, 10_000e18, 1024 days);
        _skip(1024 days);
        vm.prank(alice);
        vault.relock(USDC, 90 days);
        assertEq(_pos(alice, USDC).elderAt, block.timestamp + 30 days);

        _skip(30 days - 1);
        vault.sync(alice, USDC);
        assertFalse(_pool(USDC).elderPhase);
        _skip(1);
        vault.sync(alice, USDC);
        assertTrue(_pool(USDC).elderPhase);

        // Relocking in time from here on keeps the seat.
        vm.prank(alice);
        vault.relock(USDC, 90 days);
        assertTrue(_pos(alice, USDC).elder);
        assertTrue(_pool(USDC).elderPhase);
    }

    function test_LapsedStaker_TimeWeightRestarts_DayCountDoesNot() public {
        _depositUSDC(alice, 300_000e18, 100 days);
        _depositUSDC(bob, 300_000e18, 365 days);
        _skip(150 days); // alice lapsed 50 days ago
        vm.prank(alice);
        vault.relock(USDC, 365 days);
        assertEq(_pos(alice, USDC).stakedSeconds, 100 days, "day count kept");

        _depositUSDC(carol, 300_000e18, 30 days);
        (, uint256 slashed) = _withdraw(carol, USDC);
        assertEq(_pos(alice, USDC).earned, 0, "time weight restarted this block");
        assertApproxEqAbs(_pos(bob, USDC).earned, (slashed * 72) / 100, DUST);
    }

    function test_RelockingInTime_KeepsFullWeight() public {
        _depositUSDC(alice, 300_000e18, 100 days);
        _depositUSDC(bob, 300_000e18, 100 days);
        _skip(99 days);
        vm.prank(alice);
        vault.relock(USDC, 100 days);
        vm.prank(bob);
        vault.relock(USDC, 100 days);
        _depositUSDC(carol, 300_000e18, 30 days);
        _withdraw(carol, USDC);
        assertGt(_pos(alice, USDC).earned, 0);
        assertEq(_pos(alice, USDC).earned, _pos(bob, USDC).earned);
    }

    // --------------------------------------------- earning after the lock has run out

    /// An elder whose lock ended 370 days ago and who was never synced. Must not earn, and must
    /// not hold the pool in elder phase.
    function test_ExpiredUnsyncedElder_EarnsNothing_AndDoesNotHoldThePhase() public {
        _depositUSDC(alice, 10_000e18, 1024 days);
        _skip(1000 days);
        vm.prank(alice);
        vault.relock(USDC, 54 days); // in time: keeps everything, elder at day 1024
        _skip(24 days);
        vault.sync(alice, USDC);
        assertTrue(_pool(USDC).elderPhase);

        _depositUSDC(bob, 1_000_000e18, 1024 days);
        _skip(30 days + 370 days); // alice's lock ended 370 days ago; nobody touches her
        assertFalse(_pool(USDC).elderPhase, "phase ends with her lock, without a transaction");

        _depositUSDC(carol, 1_000_000e18, 30 days);
        (, uint256 slashed) = _withdraw(carol, USDC);
        assertEq(_pos(alice, USDC).earned, 0);
        assertApproxEqAbs(_pos(bob, USDC).earned, (slashed * 72) / 100, DUST);

        (uint256 payout,) = _withdraw(alice, USDC);
        assertEq(payout, 9_700e18);
        vm.prank(alice);
        vm.expectRevert(OnlyWhalesVault.NothingToClaim.selector);
        vault.claim(USDC);
    }

    function test_Expired_KeepsWhatItEarnedBeforeLockEnd_AndNotAWeiMore() public {
        _depositUSDC(alice, 300_000e18, 30 days);
        _depositUSDC(bob, 300_000e18, 365 days);
        _skip(20 days);
        _depositUSDC(carol, 300_000e18, 30 days);
        _withdraw(carol, USDC); // slash #1: alice still locked
        uint256 earnedWhileLocked = _pos(alice, USDC).earned;
        assertGt(earnedWhileLocked, 0);
        uint256 bobAfterFirst = _pos(bob, USDC).earned;

        _skip(20 days); // alice expired at day 30, never synced
        _depositUSDC(carol, 300_000e18, 30 days);
        _withdraw(carol, USDC); // slash #2
        _skip(300 days);
        _depositUSDC(carol, 300_000e18, 30 days);
        _withdraw(carol, USDC); // slash #3

        assertEq(_pos(alice, USDC).earned, earnedWhileLocked, "frozen at lock end");
        assertGt(_pos(bob, USDC).earned, bobAfterFirst * 2, "the whale still locked takes the later slashes");

        vault.sync(alice, USDC);
        assertEq(_pos(alice, USDC).earned, earnedWhileLocked, "syncing late changes nothing");
        vm.prank(alice);
        assertEq(vault.claim(USDC), earnedWhileLocked);

        OnlyWhalesVault.PoolView memory pool = _pool(USDC);
        assertEq(usdc.balanceOf(address(vault)), pool.totalPrincipal + pool.rewardReserve + pool.daoOwed);
    }

    function test_SlashOneSecondBeforeLockEnd_Counts_AtLockEnd_DoesNot() public {
        _depositUSDC(alice, 300_000e18, 30 days);
        _depositUSDC(bob, 300_000e18, 365 days);
        _skip(1 days);
        _depositUSDC(carol, 300_000e18, 30 days);
        _depositUSDC(dave, 300_000e18, 30 days);
        _skip(29 days - 1);
        _withdraw(carol, USDC);
        uint256 before = _pos(alice, USDC).earned;
        assertGt(before, 0);
        _skip(1); // alice's lock end, to the second
        _withdraw(dave, USDC);
        assertEq(_pos(alice, USDC).earned, before);
    }

    // ------------------------------------------------------------- day buckets

    function test_LocksEndOnUtcMidnight() public {
        _skip(5 hours + 17);
        _depositUSDC(alice, 300_000e18, 30 days);
        OnlyWhalesVault.PositionView memory p = _pos(alice, USDC);
        assertEq(p.lockEnd % 1 days, 0);
        assertGe(p.lockEnd - p.lockStart, 30 days);
        assertLt(p.lockEnd - p.lockStart, 31 days);
        assertEq(p.lockDuration, 30 days, "weight uses the lock you asked for");
    }

    function test_YearsOfSilence_ThenEverythingStillWorks() public {
        _depositUSDC(alice, 300_000e18, 30 days);
        _depositUSDC(bob, 300_000e18, 1024 days);
        _skip(3650 days); // ten years, zero transactions

        uint256 gasBefore = gasleft();
        (uint256 payout,) = _withdraw(alice, USDC);
        uint256 used = gasBefore - gasleft();
        assertEq(payout, 291_000e18);
        assertLt(used, 12_000_000, "catching up a decade fits comfortably in one BSC block");

        (uint256 bobPayout,) = _withdraw(bob, USDC);
        assertEq(bobPayout, 291_000e18);
    }

    function test_ManyLocksExpiringOnDifferentDays_AllExitClean() public {
        _skip(7 days); // nobody starts at genesis
        address[4] memory whales = [alice, bob, carol, dave];
        for (uint256 i; i < 4; ++i) {
            _skip(3 days);
            _depositUSDC(whales[i], 300_000e18, (40 + 25 * i) * 1 days);
            _depositBNB(whales[i], 300_000e18, (200 - 30 * i) * 1 days);
        }
        _skip(400 days);
        assertEq(_pool(USDC).stakerWeight, 0);
        assertEq(_pool(BNB).stakerWeight, 0);
        for (uint256 i; i < 4; ++i) {
            (uint256 payout, uint256 slashed) = _withdraw(whales[i], USDC);
            assertEq(payout, 291_000e18);
            assertEq(slashed, 0);
            (, slashed) = _withdraw(whales[i], BNB);
            assertEq(slashed, 0);
        }
        assertEq(_pool(USDC).totalPrincipal, 0);
        assertEq(_pool(BNB).totalPrincipal, 0);
    }

    function test_Advance_CatchesUpInChunks_SameResultAsOneGo() public {
        _depositUSDC(alice, 300_000e18, 30 days);
        _depositUSDC(bob, 300_000e18, 400 days);
        _skip(20 days);
        _depositUSDC(carol, 300_000e18, 30 days);
        _withdraw(carol, USDC);
        uint256 aliceEarned = _pos(alice, USDC).earned;
        _skip(500 days);

        vm.prank(dave); // anyone
        vault.advance(USDC, 100);
        assertEq(_pos(alice, USDC).earned, aliceEarned, "mid catch-up views stay correct");
        vault.advance(USDC, 100);
        vault.advance(USDC, 0);
        vault.advance(USDC, 1_000_000);
        assertEq(_pos(alice, USDC).earned, aliceEarned);
        assertEq(_pool(USDC).stakerWeight, 0, "everyone has expired");

        (uint256 payout,) = _withdraw(bob, USDC);
        assertEq(payout, 291_000e18);
    }

    // ---------------------------------------------------- operator boost cycling

    function test_OperatorCycling_CannotExceedOneHundredX() public {
        _depositUSDC(alice, 500_000e18, 1024 days);
        _skip(1000 days);
        vm.prank(alice);
        vault.relock(USDC, 1024 days);
        _skip(24 days);
        for (uint256 i; i < 3; ++i) {
            _queue(OnlyWhalesVault.Param.MinDeposit, 1_000_000e18);
            _skip(7 days);
            _queue(OnlyWhalesVault.Param.MinDeposit, 10_000e18);
            _skip(7 days);
        }
        assertEq(_pos(alice, USDC).boostWad, 100e18);
    }

    // -------------------------------------------------------------- pass metadata

    function test_TierURI_RejectsJsonBreakingCharacters() public {
        vm.startPrank(operator);
        vm.expectRevert(OnlyWhalesVault.BadURI.selector);
        vault.queueTierURI(0, 'ipfs://x","name":"hijacked');
        vm.expectRevert(OnlyWhalesVault.BadURI.selector);
        vault.queueTierURI(0, "ipfs://x\\y");
        vm.expectRevert(OnlyWhalesVault.BadURI.selector);
        vault.queueTierURI(0, "ipfs://x\ny");
        vault.queueTierURI(0, "https://example.com/art/tier-1.svg?v=2");
        vm.stopPrank();
    }
}
