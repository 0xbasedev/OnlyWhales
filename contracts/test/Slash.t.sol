// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {OnlyWhalesVault} from "../src/OnlyWhalesVault.sol";

contract SlashTest is Base {
    uint256 internal constant DUST = 1e9; // wei of rounding tolerated, always in the vault's favour

    // ------------------------------------------------------------ slash curve

    function test_Slash_AtStart_Is100Percent() public {
        _depositUSDC(alice, 300_000e18, 100 days);
        (uint256 payout, uint256 slashed) = _withdraw(alice, USDC);
        assertEq(payout, 0);
        assertEq(slashed, 291_000e18);
        assertEq(usdc.balanceOf(alice), 0);
    }

    function test_Slash_AtMiddle_Is65Percent() public {
        _depositUSDC(alice, 300_000e18, 100 days);
        _skip(50 days);
        assertEq(_pos(alice, USDC).slashWad, 0.65e18);
        (uint256 payout, uint256 slashed) = _withdraw(alice, USDC);
        assertEq(slashed, (291_000e18 * 65) / 100);
        assertEq(payout, (291_000e18 * 35) / 100);
    }

    function test_Slash_OneSecondBeforeEnd_IsJustOver30Percent() public {
        _depositUSDC(alice, 300_000e18, 100 days);
        _skip(100 days - 1);
        uint256 slashWad = _pos(alice, USDC).slashWad;
        assertGt(slashWad, 0.3e18);
        assertLt(slashWad, 0.3e18 + 1e12);
        (, uint256 slashed) = _withdraw(alice, USDC);
        assertApproxEqRel(slashed, (291_000e18 * 30) / 100, 1e12);
    }

    function test_Slash_AtLockEnd_IsZero() public {
        _depositUSDC(alice, 300_000e18, 100 days);
        _skip(100 days);
        assertEq(_pos(alice, USDC).slashWad, 0);
        (uint256 payout, uint256 slashed) = _withdraw(alice, USDC);
        assertEq(slashed, 0);
        assertEq(payout, 291_000e18);
        assertEq(usdc.balanceOf(alice), 291_000e18);
    }

    function test_Slash_AfterUnlock_IsZero() public {
        _depositBNB(alice, 300_000e18, 30 days);
        uint256 principal = _pos(alice, BNB).amount;
        _skip(400 days);
        (uint256 payout, uint256 slashed) = _withdraw(alice, BNB);
        assertEq(slashed, 0);
        assertEq(payout, principal);
    }

    function testFuzz_SlashCurve_BoundedAndLinear(uint256 lock, uint256 elapsed) public {
        lock = bound(lock, 30 days, 1024 days);
        elapsed = bound(elapsed, 0, lock - 1);
        _depositUSDC(alice, 300_000e18, lock);
        _skip(elapsed);
        uint256 slashWad = _pos(alice, USDC).slashWad;
        assertLe(slashWad, 1e18);
        assertGt(slashWad, 0.3e18);
        assertApproxEqAbs(slashWad, 1e18 - (0.7e18 * elapsed) / lock, 1);
    }

    function test_WithdrawWithoutPositionReverts() public {
        vm.prank(alice);
        vm.expectRevert(OnlyWhalesVault.NoPosition.selector);
        vault.withdraw(USDC);
        vm.prank(alice);
        vm.expectRevert(OnlyWhalesVault.BadPool.selector);
        vault.withdraw(2);
    }

    // ------------------------------------- phase one: nobody has 1024 days yet

    function test_PhaseOne_TwentyToDao_ThenNinetyTenSplit() public {
        _depositUSDC(alice, 300_000e18, 100 days);
        _skip(10 days);
        _depositUSDC(bob, 300_000e18, 100 days);
        uint256 daoBefore = _pool(USDC).daoOwed;

        _skip(50 days);
        (, uint256 slashed) = _withdraw(bob, USDC);
        assertEq(slashed, (291_000e18 * 65) / 100);

        // 20% DAO, then the remaining 80% splits 90/10: stakers get 72%, DAO ends up with 28%.
        uint256 toStakers = (slashed * 72) / 100;
        assertEq(_pool(USDC).daoOwed - daoBefore, slashed - toStakers);
        assertEq(_pool(USDC).rewardReserve, toStakers);
        assertApproxEqAbs(_pos(alice, USDC).earned, toStakers, DUST);
        assertLe(_pos(alice, USDC).earned, toStakers);

        vm.prank(alice);
        uint256 claimed = vault.claim(USDC);
        assertEq(usdc.balanceOf(alice), claimed);
        assertApproxEqAbs(claimed, toStakers, DUST);
    }

    function test_PhaseOne_WeightIsTimeStakedTimesAmountTimesLock() public {
        _depositUSDC(alice, 300_000e18, 100 days); // day 0
        _skip(10 days);
        _depositUSDC(bob, 500_000e18, 200 days); // day 10
        _skip(10 days);
        _depositUSDC(carol, 250_000e18, 30 days); // day 20
        _skip(10 days); // day 30: carol leaves 10 days into a 30 day lock

        uint256 weightA = uint256(291_000e18) * 100 days * 30 days;
        uint256 weightB = uint256(485_000e18) * 200 days * 20 days;

        (, uint256 slashed) = _withdraw(carol, USDC);
        uint256 toStakers = _pool(USDC).rewardReserve;
        assertEq(toStakers, slashed - (slashed * 20) / 100 - ((slashed - (slashed * 20) / 100) * 10) / 100);

        uint256 expectA = (toStakers * weightA) / (weightA + weightB);
        uint256 expectB = (toStakers * weightB) / (weightA + weightB);
        assertApproxEqAbs(_pos(alice, USDC).earned, expectA, DUST);
        assertApproxEqAbs(_pos(bob, USDC).earned, expectB, DUST);
        assertLe(_pos(alice, USDC).earned + _pos(bob, USDC).earned, toStakers, "never pays more than the pot");
        assertEq(_pos(carol, USDC).earned, 0, "the leaver gets none of their own slash");
    }

    function test_EmptyPool_WholeSlashGoesToDao() public {
        _depositUSDC(alice, 300_000e18, 100 days);
        uint256 daoBefore = _pool(USDC).daoOwed;
        _skip(50 days);
        (, uint256 slashed) = _withdraw(alice, USDC);
        assertEq(_pool(USDC).daoOwed - daoBefore, slashed);
        assertEq(_pool(USDC).rewardReserve, 0);
    }

    function test_PoolsAreSeparate() public {
        _depositUSDC(alice, 300_000e18, 100 days);
        _depositBNB(bob, 300_000e18, 100 days);
        _depositBNB(carol, 300_000e18, 100 days);
        _skip(20 days);
        _withdraw(carol, BNB);

        assertEq(_pos(alice, USDC).earned, 0, "a BNB slash never pays the USDC pool");
        assertGt(_pos(bob, BNB).earned, 0);
        assertEq(_pool(USDC).rewardReserve, 0);
    }

    // ------------------------------------ rewards are never slashed, always claimable

    function test_EarnedSlashShare_IsNeverSlashed() public {
        _depositUSDC(alice, 300_000e18, 100 days);
        _skip(1 days);
        _depositUSDC(bob, 300_000e18, 100 days);
        _skip(20 days);
        _withdraw(bob, USDC);
        uint256 earnedBefore = _pos(alice, USDC).earned;
        assertGt(earnedBefore, 0);

        // Alice rage-quits early. Her principal is slashed, her earnings are not.
        (uint256 payout, uint256 slashed) = _withdraw(alice, USDC);
        assertGt(slashed, 0);
        assertEq(payout + slashed, 291_000e18);
        assertEq(_pos(alice, USDC).earned, earnedBefore, "earnings survive the exit untouched");

        vm.prank(alice);
        assertEq(vault.claim(USDC), earnedBefore);
        assertEq(usdc.balanceOf(alice), payout + earnedBefore);

        vm.prank(alice);
        vm.expectRevert(OnlyWhalesVault.NothingToClaim.selector);
        vault.claim(USDC);
    }

    function test_Claim_AnyTime_WhileLocked() public {
        _depositBNB(alice, 300_000e18, 1024 days);
        _skip(1 days);
        _depositBNB(bob, 300_000e18, 30 days);
        _skip(1 days);
        _withdraw(bob, BNB);

        uint256 owed = _pos(alice, BNB).earned;
        uint256 principal = _pos(alice, BNB).amount;
        vm.prank(alice);
        vault.claim(BNB);
        assertEq(alice.balance, owed);
        assertEq(_pos(alice, BNB).amount, principal, "claiming does not touch the position");
    }

    // ----------------------------------------------------------- lock expiry

    function test_ExpiredLock_StopsEarningOnceSynced() public {
        _depositUSDC(alice, 300_000e18, 30 days);
        _depositUSDC(bob, 300_000e18, 365 days);
        _skip(60 days);

        OnlyWhalesVault.PositionView memory a = _pos(alice, USDC);
        assertFalse(a.locked);
        assertEq(a.weight, 0, "view already shows no weight");
        assertTrue(a.needsSync);
        assertEq(a.stakedSeconds, 30 days, "days stop counting at lock end");

        vm.prank(carol); // anyone can sync anyone
        vault.sync(alice, USDC);
        assertFalse(_pos(alice, USDC).needsSync);

        _depositUSDC(carol, 300_000e18, 30 days);
        _skip(1);
        (, uint256 slashed) = _withdraw(carol, USDC);
        assertEq(_pos(alice, USDC).earned, 0, "expired lock earns nothing");
        assertApproxEqAbs(_pos(bob, USDC).earned, (slashed * 72) / 100, DUST);

        (uint256 payout,) = _withdraw(alice, USDC);
        assertEq(payout, 291_000e18, "and leaves for free");
    }

    // ---------------------------------------------------------------- relock

    function test_Relock_ContinuesCumulativeDays() public {
        _depositUSDC(alice, 300_000e18, 100 days);
        _skip(60 days);
        vm.prank(alice);
        vault.relock(USDC, 200 days);

        OnlyWhalesVault.PositionView memory p = _pos(alice, USDC);
        assertEq(p.stakedSeconds, 60 days);
        assertEq(p.lockEnd, block.timestamp + 200 days);
        assertEq(p.slashWad, WAD, "a new lock restarts the slash curve at 100%");

        _skip(40 days);
        assertEq(_pos(alice, USDC).stakedSeconds, 100 days);
    }

    function test_Relock_AfterExpiry_GapDoesNotCount() public {
        _depositUSDC(alice, 300_000e18, 30 days);
        _skip(90 days); // 60 days idle after the lock ran out
        vm.prank(alice);
        vault.relock(USDC, 30 days);
        assertEq(_pos(alice, USDC).stakedSeconds, 30 days);
        _skip(10 days);
        assertEq(_pos(alice, USDC).stakedSeconds, 40 days);
    }

    function test_Relock_CannotShorten() public {
        _depositUSDC(alice, 300_000e18, 365 days);
        _skip(10 days);
        vm.prank(alice);
        vm.expectRevert(OnlyWhalesVault.CannotShortenLock.selector);
        vault.relock(USDC, 30 days);
    }

    function test_Relock_RequiresPositionAndValidLock() public {
        vm.prank(alice);
        vm.expectRevert(OnlyWhalesVault.NoPosition.selector);
        vault.relock(USDC, 30 days);
        _depositUSDC(alice, 300_000e18, 30 days);
        vm.prank(alice);
        vm.expectRevert(OnlyWhalesVault.BadLock.selector);
        vault.relock(USDC, 1025 days);
    }

    function test_Relock_KeepsEarningsAndWeightContinuity() public {
        _depositUSDC(alice, 300_000e18, 100 days);
        _depositUSDC(bob, 300_000e18, 100 days);
        _skip(50 days);
        // Same amount, same days staked. Alice doubles her lock, so she should take 2/3.
        vm.prank(alice);
        vault.relock(USDC, 200 days);
        _depositUSDC(carol, 300_000e18, 30 days);
        _withdraw(carol, USDC);

        uint256 pot = _pool(USDC).rewardReserve;
        assertApproxEqAbs(_pos(alice, USDC).earned, (pot * 2) / 3, DUST);
        assertApproxEqAbs(_pos(bob, USDC).earned, pot / 3, DUST);
    }

    // ------------------------------------------- phase two: the 1024-day pot

    function _aliceReaches1024() internal {
        _depositUSDC(alice, 300_000e18, 600 days);
        _skip(500 days);
        vm.prank(alice);
        vault.relock(USDC, 600 days); // locked until day 1100
        _skip(524 days); // day 1024
    }

    function test_Relock_PathTo1024Days() public {
        _aliceReaches1024();
        OnlyWhalesVault.PositionView memory p = _pos(alice, USDC);
        assertEq(p.stakedSeconds, 1024 days);
        assertTrue(p.elder);
        assertTrue(p.needsSync);
        assertFalse(_pool(USDC).elderPhase, "phase flips when the first elder is synced in");

        vault.sync(alice, USDC);
        assertTrue(_pool(USDC).elderPhase);
        assertFalse(_pos(alice, USDC).needsSync);
    }

    function test_OneSecondShortOf1024_IsNotElder() public {
        _depositUSDC(alice, 300_000e18, 600 days);
        _skip(500 days);
        vm.prank(alice);
        vault.relock(USDC, 600 days);
        _skip(524 days - 1);
        vault.sync(alice, USDC);
        assertFalse(_pos(alice, USDC).elder);
        assertFalse(_pool(USDC).elderPhase);
    }

    function test_PhaseTwo_EightyToElders_TwentyToDao() public {
        _aliceReaches1024();
        vault.sync(alice, USDC);
        _depositUSDC(bob, 300_000e18, 100 days); // staker, not an elder
        _skip(5 days);
        _depositUSDC(carol, 300_000e18, 30 days);
        uint256 daoBefore = _pool(USDC).daoOwed;
        _skip(1 days);

        (, uint256 slashed) = _withdraw(carol, USDC);
        uint256 toDao = (slashed * 20) / 100;
        assertEq(_pool(USDC).daoOwed - daoBefore, toDao, "DAO gets exactly 20%");
        assertEq(_pool(USDC).rewardReserve, slashed - toDao, "elders get exactly 80%");
        assertApproxEqAbs(_pos(alice, USDC).earned, slashed - toDao, DUST);
        assertEq(_pos(bob, USDC).earned, 0, "under 1024 days earns nothing in phase two");
    }

    function test_PhaseTwo_EldersSplitByWeight() public {
        _depositUSDC(alice, 300_000e18, 1024 days);
        _depositUSDC(bob, 600_000e18, 1024 days);
        _skip(1000 days);
        vm.prank(alice);
        vault.relock(USDC, 100 days);
        vm.prank(bob);
        vault.relock(USDC, 100 days);
        _skip(24 days);
        vault.sync(alice, USDC);
        vault.sync(bob, USDC);

        _depositUSDC(carol, 300_000e18, 30 days);
        (, uint256 slashed) = _withdraw(carol, USDC);
        uint256 pot = slashed - (slashed * 20) / 100;
        assertApproxEqAbs(_pos(alice, USDC).earned, pot / 3, DUST);
        assertApproxEqAbs(_pos(bob, USDC).earned, (pot * 2) / 3, DUST);
    }

    function test_MaxLock_ExpiresAt1024_ThenRelockJoinsElders() public {
        _depositUSDC(alice, 300_000e18, 1024 days);
        _skip(1024 days);
        vault.sync(alice, USDC);
        OnlyWhalesVault.PositionView memory p = _pos(alice, USDC);
        assertEq(p.stakedSeconds, 1024 days);
        assertFalse(p.elder, "an expired lock is not in the pot");
        assertFalse(_pool(USDC).elderPhase);

        vm.prank(alice);
        vault.relock(USDC, 30 days);
        assertTrue(_pos(alice, USDC).elder);
        assertTrue(_pool(USDC).elderPhase);
    }

    function test_PhaseTwo_FallsBackWhenLastElderLeaves() public {
        _aliceReaches1024();
        vault.sync(alice, USDC);
        _depositUSDC(bob, 300_000e18, 365 days);
        _skip(76 days); // alice's lock ends at day 1100
        _withdraw(alice, USDC);
        assertFalse(_pool(USDC).elderPhase);

        _depositUSDC(carol, 300_000e18, 30 days);
        (, uint256 slashed) = _withdraw(carol, USDC);
        assertApproxEqAbs(_pos(bob, USDC).earned, (slashed * 72) / 100, DUST);
    }

    // ------------------------------------------------------------------ fuzz

    /// payout + redistributed slash == principal, to the wei.
    function testFuzz_PayoutPlusSlashEqualsPrincipal(uint256 amount, uint256 lock, uint256 elapsed, bool bnb)
        public
    {
        amount = bound(amount, 250_000e18, 999_999e18);
        lock = bound(lock, 30 days, 1024 days);
        elapsed = bound(elapsed, 0, lock + 10 days);
        uint8 pool = bnb ? BNB : USDC;

        if (bnb) {
            _depositBNB(bob, 400_000e18, 500 days);
            _skip(3 days);
            _depositBNB(alice, amount, lock);
        } else {
            _depositUSDC(bob, 400_000e18, 500 days);
            _skip(3 days);
            _depositUSDC(alice, amount, lock);
        }
        _skip(elapsed);

        uint256 principal = _pos(alice, pool).amount;
        OnlyWhalesVault.PoolView memory before = _pool(pool);
        uint256 vaultBefore = bnb ? address(vault).balance : usdc.balanceOf(address(vault));

        (uint256 payout, uint256 slashed) = _withdraw(alice, pool);

        OnlyWhalesVault.PoolView memory aft = _pool(pool);
        uint256 vaultAfter = bnb ? address(vault).balance : usdc.balanceOf(address(vault));
        uint256 redistributed = (aft.daoOwed - before.daoOwed) + (aft.rewardReserve - before.rewardReserve);

        assertEq(payout + slashed, principal, "payout + slash == principal");
        assertEq(redistributed, slashed, "every slashed wei is assigned to the DAO or the whales");
        assertEq(vaultBefore - vaultAfter, payout, "only the payout leaves the vault");
        assertEq(before.totalPrincipal - aft.totalPrincipal, principal);
        assertLe(_pos(bob, pool).earned, aft.rewardReserve, "claims never exceed the reserve");
        assertEq(vaultAfter, aft.totalPrincipal + aft.rewardReserve + aft.daoOwed, "vault covers what it owes");
        if (elapsed >= lock) assertEq(slashed, 0);
    }
}
