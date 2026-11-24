// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {OnlyWhalesVault} from "../src/OnlyWhalesVault.sol";
import {Timelocked} from "../src/lib/Timelocked.sol";

contract TimelockTest is Base {
    OnlyWhalesVault.Param internal constant FEE = OnlyWhalesVault.Param.DepositFee;
    OnlyWhalesVault.Param internal constant MIN = OnlyWhalesVault.Param.MinDeposit;
    OnlyWhalesVault.Param internal constant MAX = OnlyWhalesVault.Param.MaxDeposit;
    OnlyWhalesVault.Param internal constant DAO = OnlyWhalesVault.Param.DaoWallet;

    event ChangeQueued(OnlyWhalesVault.Param indexed param, uint256 oldValue, uint256 newValue, uint256 eta);
    event ChangeCancelled(OnlyWhalesVault.Param indexed param, uint256 cancelledValue);

    function test_TimelockIsSevenDaysConstant() public view {
        assertEq(vault.TIMELOCK(), 7 days);
    }

    function test_Queue_EmitsEvent_AndShowsPending() public {
        vm.expectEmit(true, false, false, true);
        emit ChangeQueued(FEE, 300, 100, block.timestamp + 7 days);
        _queue(FEE, 100);

        (uint256 value, uint256 eta) = vault.pendingChange(FEE);
        assertEq(value, 100);
        assertEq(eta, block.timestamp + 7 days);
        assertEq(vault.depositFeeBps(), 300, "nothing changes yet");
    }

    function test_OldValueOneSecondBefore_NewValueAtExactlySevenDays_NoExecuteCall() public {
        uint256 queuedAt = block.timestamp;
        _queue(FEE, 100);

        vm.warp(queuedAt + 7 days - 1);
        assertEq(vault.depositFeeBps(), 300);
        _depositUSDC(alice, 300_000e18, 30 days);
        assertEq(_pos(alice, USDC).amount, 291_000e18, "still charged 3%");

        vm.warp(queuedAt + 7 days);
        // No transaction from the operator, or anyone, between the two deposits.
        assertEq(vault.depositFeeBps(), 100);
        _depositUSDC(bob, 300_000e18, 30 days);
        assertEq(_pos(bob, USDC).amount, 297_000e18, "now charged 1%");

        (uint256 value, uint256 eta) = vault.pendingChange(FEE);
        assertEq(value, 0);
        assertEq(eta, 0, "no longer pending");
    }

    function test_MinAndMax_TakeEffectAtSevenDays() public {
        uint256 queuedAt = block.timestamp;
        _queue(MIN, 50_000e18);
        _queue(MAX, 500_000e18);

        vm.warp(queuedAt + 7 days - 1);
        assertEq(vault.minDepositUsd(), 250_000e18);
        assertEq(vault.maxDepositUsd(), 1_000_000e18);

        vm.warp(queuedAt + 7 days);
        assertEq(vault.minDepositUsd(), 50_000e18);
        assertEq(vault.maxDepositUsd(), 500_000e18);
        _depositUSDC(alice, 50_000e18, 30 days);

        usdc.mint(bob, 600_000e18);
        vm.startPrank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert();
        vault.depositUSDC(600_000e18, 30 days);
        vm.stopPrank();
    }

    function test_DaoWallet_ChangesAfterSevenDays() public {
        address newDao = makeAddr("newDao");
        _depositUSDC(alice, 300_000e18, 30 days);
        uint256 queuedAt = block.timestamp;
        _queue(DAO, uint256(uint160(newDao)));

        vm.warp(queuedAt + 7 days - 1);
        assertEq(vault.daoWallet(), dao);
        vault.sweepDao(USDC);
        assertEq(usdc.balanceOf(dao), 9_000e18);

        vm.warp(queuedAt + 7 days);
        assertEq(vault.daoWallet(), newDao);
        _depositUSDC(bob, 300_000e18, 30 days);
        vault.sweepDao(USDC);
        assertEq(usdc.balanceOf(newDao), 9_000e18);
        assertEq(usdc.balanceOf(dao), 9_000e18);
    }

    function test_Cancel_Works() public {
        _queue(FEE, 100);
        _skip(7 days - 1);
        vm.expectEmit(true, false, false, true);
        emit ChangeCancelled(FEE, 100);
        vm.prank(operator);
        vault.cancelChange(FEE);

        _skip(30 days);
        assertEq(vault.depositFeeBps(), 300, "cancelled change never lands");
        (, uint256 eta) = vault.pendingChange(FEE);
        assertEq(eta, 0);

        _queue(FEE, 200); // and the slot is free again
        _skip(7 days);
        assertEq(vault.depositFeeBps(), 200);
    }

    function test_Cancel_TooLateOnceInEffect() public {
        _queue(FEE, 100);
        _skip(7 days);
        vm.prank(operator);
        vm.expectRevert(Timelocked.NothingPending.selector);
        vault.cancelChange(FEE);
        assertEq(vault.depositFeeBps(), 100);
    }

    function test_Cancel_NothingPendingReverts() public {
        vm.prank(operator);
        vm.expectRevert(Timelocked.NothingPending.selector);
        vault.cancelChange(MIN);
    }

    function test_OnePendingChangePerSetting() public {
        _queue(FEE, 100);
        vm.prank(operator);
        vm.expectRevert(Timelocked.ChangePending.selector);
        vault.queueChange(FEE, 200);
    }

    function test_QueueSameValueReverts() public {
        vm.prank(operator);
        vm.expectRevert(Timelocked.NoChange.selector);
        vault.queueChange(FEE, 300);
    }

    function test_SequentialChanges_EachWaitsItsOwnSevenDays() public {
        _queue(FEE, 100);
        _skip(7 days);
        _queue(FEE, 250);
        assertEq(vault.depositFeeBps(), 100, "first change stays live while the second counts down");
        _skip(7 days - 1);
        assertEq(vault.depositFeeBps(), 100);
        _skip(1);
        assertEq(vault.depositFeeBps(), 250);
    }

    // ----------------------------------------------------------- hard ranges

    function test_Range_Fee() public {
        vm.startPrank(operator);
        vm.expectRevert(OnlyWhalesVault.OutOfRange.selector);
        vault.queueChange(FEE, 49);
        vm.expectRevert(OnlyWhalesVault.OutOfRange.selector);
        vault.queueChange(FEE, 301);
        vault.queueChange(FEE, 50);
        vm.stopPrank();
    }

    function test_Range_MinAndMax() public {
        vm.startPrank(operator);
        vm.expectRevert(OnlyWhalesVault.OutOfRange.selector);
        vault.queueChange(MIN, 10_000e18 - 1);
        vm.expectRevert(OnlyWhalesVault.OutOfRange.selector);
        vault.queueChange(MAX, 1_000_000e18 + 1);
        vm.expectRevert(OnlyWhalesVault.OutOfRange.selector);
        vault.queueChange(MIN, 1_000_000e18 + 1);
        vm.expectRevert(OnlyWhalesVault.OutOfRange.selector);
        vault.queueChange(MAX, 10_000e18 - 1);
        vault.queueChange(MIN, 10_000e18);
        vm.stopPrank();
    }

    function test_Range_MinNeverAboveMax() public {
        vm.startPrank(operator);
        vm.expectRevert(OnlyWhalesVault.MinAboveMax.selector);
        vault.queueChange(MAX, 200_000e18); // below the live $250k minimum

        vault.queueChange(MAX, 300_000e18); // pending
        vm.expectRevert(OnlyWhalesVault.MinAboveMax.selector);
        vault.queueChange(MIN, 400_000e18); // would exceed the pending maximum
        vault.queueChange(MIN, 300_000e18);
        vm.stopPrank();

        _skip(7 days);
        assertEq(vault.minDepositUsd(), vault.maxDepositUsd());
    }

    function test_Range_DaoWalletNotZero() public {
        vm.startPrank(operator);
        vm.expectRevert(OnlyWhalesVault.ZeroAddress.selector);
        vault.queueChange(DAO, 0);
        vm.expectRevert(OnlyWhalesVault.ZeroAddress.selector);
        vault.queueChange(DAO, uint256(type(uint160).max) + 1);
        vm.stopPrank();
    }

    function test_Constructor_EnforcesRanges() public {
        vm.expectRevert(OnlyWhalesVault.OutOfRange.selector);
        _deploy(301, 250_000e18, 1_000_000e18);
        vm.expectRevert(OnlyWhalesVault.OutOfRange.selector);
        _deploy(300, 9_999e18, 1_000_000e18);
        vm.expectRevert(OnlyWhalesVault.OutOfRange.selector);
        _deploy(300, 250_000e18, 1_000_001e18);
        vm.expectRevert(OnlyWhalesVault.MinAboveMax.selector);
        _deploy(300, 500_000e18, 400_000e18);
    }

    function testFuzz_FeeAlwaysInsideRange(uint256 value) public {
        vm.prank(operator);
        try vault.queueChange(FEE, value) {
            _skip(7 days);
        } catch {}
        assertGe(vault.depositFeeBps(), 50);
        assertLe(vault.depositFeeBps(), 300);
    }

    // ---------------------------------------------------------- only operator

    function test_OnlyOperator() public {
        vm.startPrank(alice);
        vm.expectRevert(OnlyWhalesVault.NotOperator.selector);
        vault.queueChange(FEE, 100);
        vm.expectRevert(OnlyWhalesVault.NotOperator.selector);
        vault.cancelChange(FEE);
        vm.expectRevert(OnlyWhalesVault.NotOperator.selector);
        vault.queueTierURI(0, "x");
        vm.expectRevert(OnlyWhalesVault.NotOperator.selector);
        vault.cancelTierURI(0);
        vm.stopPrank();
    }

    function test_DaoWalletHasNoPowers() public {
        vm.prank(dao);
        vm.expectRevert(OnlyWhalesVault.NotOperator.selector);
        vault.queueChange(FEE, 100);
    }

    // -------------------------------------------------------------- tier art

    function test_TierURI_Timelocked() public {
        uint256 queuedAt = block.timestamp;
        vm.prank(operator);
        vault.queueTierURI(3, "ipfs://new-art");

        (string memory pending, uint256 eta) = vault.pendingTierURI(3);
        assertEq(pending, "ipfs://new-art");
        assertEq(eta, queuedAt + 7 days);

        vm.warp(queuedAt + 7 days - 1);
        assertEq(vault.tierURI(3), "ipfs://tier-3");
        vm.warp(queuedAt + 7 days);
        assertEq(vault.tierURI(3), "ipfs://new-art");

        vm.prank(operator);
        vault.queueTierURI(3, "ipfs://newer-art");
        assertEq(vault.tierURI(3), "ipfs://new-art");
        vm.prank(operator);
        vault.cancelTierURI(3);
        _skip(8 days);
        assertEq(vault.tierURI(3), "ipfs://new-art");
    }

    function test_TierURI_BadTier() public {
        vm.prank(operator);
        vm.expectRevert(OnlyWhalesVault.BadTier.selector);
        vault.queueTierURI(10, "x");
    }
}
