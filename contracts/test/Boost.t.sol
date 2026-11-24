// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {OnlyWhalesVault} from "../src/OnlyWhalesVault.sol";

/// boost = 1 + (newMin/oldMin - 1) * min(daysStaked/1024, 1)
contract BoostTest is Base {
    OnlyWhalesVault.Param internal constant MIN = OnlyWhalesVault.Param.MinDeposit;
    uint256 internal constant PRINCIPAL = 291_000e18;

    function setUp() public override {
        super.setUp();
        // Start with a $200k minimum so a 5x raise ($1M) fits inside the hard range.
        vault = _deploy(300, 200_000e18, 1_000_000e18);
        pass = vault.pass();
    }

    /// Alice ends up locked with exactly `stakedDays` served when the raise takes effect.
    function _stakeThenRaise(uint256 stakedDays, uint256 newMin) internal {
        _depositUSDC(alice, 300_000e18, 1024 days);
        if (stakedDays >= 1024) {
            _skip(1000 days);
            vm.prank(alice);
            vault.relock(USDC, 1024 days);
            _skip((stakedDays - 1000) * DAY - 7 days);
        } else {
            _skip(stakedDays * DAY - 7 days);
        }
        _queue(MIN, newMin);
        _skip(7 days);
    }

    function test_Boost_FullyCommitted_FiveXRaiseGivesFiveX() public {
        _stakeThenRaise(1024, 1_000_000e18);
        OnlyWhalesVault.PositionView memory p = _pos(alice, USDC);
        assertEq(p.stakedSeconds, 1024 days);
        assertEq(p.boostWad, 5e18);
        assertEq(p.weight, PRINCIPAL * 1024 days * 5);
    }

    function test_Boost_IsCappedAtFullCommitment() public {
        _stakeThenRaise(1500, 1_000_000e18);
        assertEq(_pos(alice, USDC).boostWad, 5e18, "min(days/1024, 1)");
    }

    function test_Boost_Partial_512DaysGivesThreeX() public {
        _stakeThenRaise(512, 1_000_000e18);
        OnlyWhalesVault.PositionView memory p = _pos(alice, USDC);
        assertEq(p.stakedSeconds, 512 days);
        assertEq(p.boostWad, 3e18);
        assertEq(p.weight, PRINCIPAL * 1024 days * 3);
    }

    function test_Boost_Partial_256Days() public {
        _stakeThenRaise(256, 400_000e18); // 2x raise, quarter committed: 1 + 1 * 0.25
        assertEq(_pos(alice, USDC).boostWad, 1.25e18);
    }

    function test_Boost_AppliesTheMomentTheRaiseTakesEffect_NoCall() public {
        _depositUSDC(alice, 300_000e18, 1024 days);
        _skip(505 days);
        uint256 queuedAt = block.timestamp;
        _queue(MIN, 1_000_000e18);

        vm.warp(queuedAt + 7 days - 1);
        assertEq(_pos(alice, USDC).boostWad, 1e18, "one second early: no boost");
        assertEq(_pos(alice, USDC).weight, PRINCIPAL * 1024 days);

        vm.warp(queuedAt + 7 days);
        assertEq(_pos(alice, USDC).boostWad, 3e18, "at the eta: boosted, nothing was called");
        assertEq(_pos(alice, USDC).weight, PRINCIPAL * 1024 days * 3);
        assertTrue(_pos(alice, USDC).needsSync);
    }

    function test_Boost_Stacks() public {
        _depositUSDC(alice, 300_000e18, 1024 days);
        _skip(256 days - 7 days);
        _queue(MIN, 400_000e18); // 2x at day 256 -> 1.25x
        _skip(7 days);
        assertEq(_pos(alice, USDC).boostWad, 1.25e18);

        _skip(256 days - 7 days);
        _queue(MIN, 800_000e18); // 2x at day 512 -> 1.5x
        _skip(7 days);
        assertEq(_pos(alice, USDC).boostWad, 1.875e18, "1.25 * 1.5");

        vault.sync(alice, USDC);
        assertEq(_pos(alice, USDC).boostWad, 1.875e18, "stored after sync");
        assertEq(_pos(alice, USDC).weight, (PRINCIPAL * 1024 days * 1875) / 1000);
        assertFalse(_pos(alice, USDC).needsSync);
    }

    function test_Boost_LoweringNeverReducesWeight() public {
        _stakeThenRaise(512, 1_000_000e18);
        vault.sync(alice, USDC);
        uint256 weightBefore = _pos(alice, USDC).weight;

        _queue(MIN, 10_000e18); // 100x lower
        _skip(7 days);
        vault.sync(alice, USDC);
        assertEq(vault.minDepositUsd(), 10_000e18);
        assertEq(_pos(alice, USDC).boostWad, 3e18);
        assertEq(_pos(alice, USDC).weight, weightBefore);
        assertEq(vault.raiseCount(), 1, "a lowering is not recorded as a raise");
    }

    function test_Boost_LowerThenRaiseStacksOnTop() public {
        _stakeThenRaise(512, 400_000e18); // 2x at 512 days -> 1.5x
        _queue(MIN, 200_000e18);
        _skip(7 days);
        _queue(MIN, 400_000e18); // 2x again at 526 days
        _skip(7 days);
        uint256 expected = (1.5e18 * (1e18 + (1e18 * 526) / 1024)) / 1e18;
        assertApproxEqAbs(_pos(alice, USDC).boostWad, expected, 10);
    }

    function test_Boost_CancelledRaiseGivesNothing() public {
        _depositUSDC(alice, 300_000e18, 1024 days);
        _skip(500 days);
        _queue(MIN, 1_000_000e18);
        assertEq(vault.raiseCount(), 1);
        _skip(6 days);
        vm.prank(operator);
        vault.cancelChange(MIN);
        assertEq(vault.raiseCount(), 0);
        _skip(30 days);
        vault.sync(alice, USDC);
        assertEq(_pos(alice, USDC).boostWad, 1e18);
        assertEq(vault.minDepositUsd(), 200_000e18);
    }

    function test_Boost_OnlyExistingStakers() public {
        _queue(MIN, 400_000e18);
        _skip(7 days);
        _depositUSDC(alice, 400_000e18, 365 days); // arrives after the raise took effect
        _skip(100 days);
        vault.sync(alice, USDC);
        assertEq(_pos(alice, USDC).boostWad, 1e18);
    }

    function test_Boost_DepositDuringCountdownGetsProRata() public {
        _queue(MIN, 400_000e18);
        _skip(7 days - 1024); // 1024 seconds staked when the raise lands
        _depositUSDC(alice, 300_000e18, 365 days);
        _skip(10 days);
        assertEq(_pos(alice, USDC).boostWad, 1e18 + uint256(1e18 * 1024) / 1024 days);
    }

    function test_Boost_ChangesTheSlashSplit() public {
        // Same deposit, same lock, same day. Bob arrives after the raise so only Alice is boosted.
        _depositUSDC(alice, 300_000e18, 1024 days);
        _skip(512 days - 7 days);
        _queue(MIN, 300_000e18); // 1.5x raise at 512 days -> alice boost 1.25x
        _skip(7 days);
        vault.sync(alice, USDC);
        assertEq(_pos(alice, USDC).boostWad, 1.25e18);

        vm.prank(alice);
        vault.relock(USDC, 1024 days);
        _depositUSDC(bob, 300_000e18, 1024 days);
        _skip(100 days);
        _depositUSDC(carol, 300_000e18, 30 days);
        _withdraw(carol, USDC);

        // weight = amount * lock * boost * daysStaked: alice 1.25 * 612, bob 1 * 100
        uint256 pot = _pool(USDC).rewardReserve;
        uint256 a = 1.25e18 * 612;
        uint256 b = 1e18 * 100;
        assertApproxEqAbs(_pos(alice, USDC).earned, (pot * a) / (a + b), 1e9);
        assertApproxEqAbs(_pos(bob, USDC).earned, (pot * b) / (a + b), 1e9);
    }

    function test_Boost_SurvivesExpiryAndRelock() public {
        _depositUSDC(alice, 300_000e18, 600 days);
        _skip(512 days - 7 days);
        _queue(MIN, 400_000e18); // lands at day 512, while still locked
        _skip(7 days + 200 days); // lock ran out at day 600
        assertEq(_pos(alice, USDC).boostWad, 1.5e18);
        assertEq(_pos(alice, USDC).weight, 0);

        vm.prank(alice);
        vault.relock(USDC, 100 days);
        assertEq(_pos(alice, USDC).weight, (PRINCIPAL * 100 days * 15) / 10);
    }

    function test_Boost_OnlyPositionsLockedWhenTheRaiseLands() public {
        _depositUSDC(alice, 300_000e18, 512 days);
        _skip(512 days); // expired, sitting liquid
        _queue(MIN, 1_000_000e18);
        _skip(7 days);
        vault.sync(alice, USDC);
        assertEq(_pos(alice, USDC).boostWad, 1e18, "idle positions bank no boost");

        vm.prank(alice);
        vault.relock(USDC, 100 days);
        assertEq(_pos(alice, USDC).boostWad, 1e18);
    }

    function test_Boost_RaiseLandingExactlyAtLockEndDoesNotCount() public {
        _depositUSDC(alice, 300_000e18, 512 days);
        _skip(512 days - 7 days);
        _queue(MIN, 400_000e18); // eta == lockEnd
        _skip(7 days);
        assertEq(_pos(alice, USDC).boostWad, 1e18);
    }

    function test_Boost_HardCeiling_OneHundredX() public {
        // Cycling the minimum up and down buys nothing past the largest single raise ($10k -> $1M).
        vault = _deploy(300, 10_000e18, 1_000_000e18);
        _depositUSDC(alice, 300_000e18, 1024 days);
        _skip(1000 days);
        vm.prank(alice);
        vault.relock(USDC, 1024 days);
        _skip(30 days);
        for (uint256 i; i < 6; ++i) {
            _queue(MIN, 1_000_000e18); // 100x
            _skip(7 days);
            _queue(MIN, 10_000e18);
            _skip(7 days);
        }
        assertEq(vault.MAX_BOOST_WAD(), 100e18);
        assertEq(_pos(alice, USDC).boostWad, 100e18);
        vault.sync(alice, USDC);
        _skip(1024 days);
        (uint256 payout,) = _withdraw(alice, USDC);
        assertEq(payout, PRINCIPAL, "principal is always withdrawable");
    }

    function testFuzz_BoostFormula(uint256 stakedDays, uint256 newMin) public {
        stakedDays = bound(stakedDays, 8, 1023);
        newMin = bound(newMin, 200_001e18, 1_000_000e18);
        _stakeThenRaise(stakedDays, newMin);
        uint256 ratio = (newMin * 1e18) / 200_000e18;
        uint256 expected = 1e18 + ((ratio - 1e18) * stakedDays) / 1024;
        assertApproxEqAbs(_pos(alice, USDC).boostWad, expected, 1);
        assertGe(_pos(alice, USDC).boostWad, 1e18);
        assertLe(_pos(alice, USDC).boostWad, ratio);
    }
}
