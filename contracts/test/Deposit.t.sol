// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {OnlyWhalesVault} from "../src/OnlyWhalesVault.sol";

contract DepositTest is Base {
    function test_DepositUSDC_RecordsPositionAndFee() public {
        _depositUSDC(alice, 500_000e18, 365 days);

        OnlyWhalesVault.PositionView memory p = _pos(alice, USDC);
        assertEq(p.amount, 485_000e18, "principal is gross minus 3%");
        assertEq(p.grossUsd, 500_000e18);
        assertEq(p.lockEnd, block.timestamp + 365 days);
        assertEq(p.lockDuration, 365 days);
        assertEq(p.slashWad, WAD, "100% at deposit");
        assertEq(p.boostWad, WAD);
        assertTrue(p.locked);

        OnlyWhalesVault.PoolView memory pool = _pool(USDC);
        assertEq(pool.totalPrincipal, 485_000e18);
        assertEq(pool.daoOwed, 15_000e18);
        assertEq(usdc.balanceOf(address(vault)), 500_000e18);
        assertEq(vault.activeUsd(alice), 500_000e18);
    }

    function test_DepositBNB_UsesOraclePrice() public {
        uint256 value = _depositBNB(alice, 600_000e18, 90 days); // 1000 BNB at $600
        assertApproxEqAbs(value, 1_000 ether, 1);

        OnlyWhalesVault.PositionView memory p = _pos(alice, BNB);
        uint256 fee = (value * 300) / 10_000;
        assertEq(p.amount, value - fee);
        assertApproxEqAbs(p.grossUsd, 600_000e18, 1e3);
        assertEq(_pool(BNB).daoOwed, fee);
        assertEq(address(vault).balance, value);
        assertEq(_pool(USDC).totalPrincipal, 0, "pools are separate");
    }

    function test_FeeGoesToDaoWallet_BothAssets() public {
        _depositUSDC(alice, 400_000e18, 30 days);
        uint256 value = _depositBNB(bob, 300_000e18, 30 days);

        vault.sweepDao(USDC); // permissionless
        vault.sweepDao(BNB);

        assertEq(usdc.balanceOf(dao), 12_000e18, "3% of 400k USDC");
        assertEq(dao.balance, (value * 300) / 10_000, "3% of the BNB");
        assertEq(_pool(USDC).daoOwed, 0);
        assertEq(_pool(BNB).daoOwed, 0);

        vm.expectRevert(OnlyWhalesVault.NothingToClaim.selector);
        vault.sweepDao(USDC);
    }

    function test_MinDeposit_CheckedGross() public {
        usdc.mint(alice, 250_000e18);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(OnlyWhalesVault.BelowMinimum.selector, 250_000e18 - 1, 250_000e18)
        );
        vault.depositUSDC(250_000e18 - 1, 30 days);

        // Exactly the minimum, gross, is accepted even though the principal lands below it.
        vault.depositUSDC(250_000e18, 30 days);
        vm.stopPrank();
        assertEq(_pos(alice, USDC).amount, 242_500e18);
    }

    function test_MinDeposit_BNB() public {
        feed.setAnswer(BNB_PRICE);
        uint256 tooLittle = (249_999e18 * 1e8) / uint256(BNB_PRICE);
        vm.deal(alice, tooLittle);
        vm.prank(alice);
        vm.expectRevert();
        vault.depositBNB{value: tooLittle}(30 days);
    }

    function test_MaxDeposit_CheckedGross() public {
        usdc.mint(alice, 2_000_000e18);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(OnlyWhalesVault.AboveMaximum.selector, 1_000_000e18 + 1, 1_000_000e18)
        );
        vault.depositUSDC(1_000_000e18 + 1, 30 days);
        vault.depositUSDC(1_000_000e18, 30 days);
        vm.stopPrank();
        assertEq(vault.activeUsd(alice), 1_000_000e18);
    }

    function test_MaxDeposit_IsPerWalletAcrossPools() public {
        _depositUSDC(alice, 600_000e18, 30 days);

        feed.setAnswer(BNB_PRICE);
        uint256 value = bnbFor(500_000e18);
        vm.deal(alice, value);
        vm.prank(alice);
        vm.expectRevert();
        vault.depositBNB{value: value}(30 days);

        _depositBNB(alice, 399_000e18, 30 days); // fits under the $1M cap
        assertGt(_pos(alice, BNB).amount, 0);
    }

    function test_MaxDeposit_FreesUpAfterWithdraw() public {
        _depositUSDC(alice, 1_000_000e18, 30 days);
        _skip(30 days);
        _withdraw(alice, USDC);
        assertEq(vault.activeUsd(alice), 0);
        _depositUSDC(alice, 1_000_000e18, 30 days);
    }

    function test_OnePositionPerPool() public {
        _depositUSDC(alice, 300_000e18, 30 days);
        usdc.mint(alice, 300_000e18);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(OnlyWhalesVault.PositionExists.selector);
        vault.depositUSDC(300_000e18, 30 days);
        vm.stopPrank();
    }

    function test_LockBounds() public {
        usdc.mint(alice, 300_000e18);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(OnlyWhalesVault.BadLock.selector);
        vault.depositUSDC(300_000e18, 30 days - 1);
        vm.expectRevert(OnlyWhalesVault.BadLock.selector);
        vault.depositUSDC(300_000e18, 1024 days + 1);
        vault.depositUSDC(300_000e18, 1024 days);
        vm.stopPrank();
    }

    function test_ZeroAmountReverts() public {
        vm.startPrank(alice);
        vm.expectRevert(OnlyWhalesVault.ZeroAmount.selector);
        vault.depositUSDC(0, 30 days);
        vm.expectRevert(OnlyWhalesVault.ZeroAmount.selector);
        vault.depositBNB{value: 0}(30 days);
        vm.stopPrank();
    }

    function test_PlainBnbTransferReverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok, "no receive, no fallback");
    }

    // ---------------------------------------------------------------- oracle

    function _tryBnb() internal {
        uint256 value = bnbFor(300_000e18);
        vm.deal(alice, value);
        vm.prank(alice);
        vault.depositBNB{value: value}(30 days);
    }

    function test_Oracle_StaleReverts() public {
        feed.setAnswer(BNB_PRICE);
        _skip(STALENESS + 1);
        vm.expectRevert(OnlyWhalesVault.OracleStale.selector);
        _tryBnb();
    }

    function test_Oracle_ExactlyAtStalenessLimitIsAccepted() public {
        feed.setAnswer(BNB_PRICE);
        _skip(STALENESS);
        _tryBnb();
        assertGt(_pos(alice, BNB).amount, 0);
    }

    function test_Oracle_ZeroPriceReverts() public {
        feed.setAnswer(0);
        vm.expectRevert(OnlyWhalesVault.OracleBadPrice.selector);
        _tryBnb();
    }

    function test_Oracle_NegativePriceReverts() public {
        feed.setAnswer(-1);
        vm.expectRevert(OnlyWhalesVault.OracleBadPrice.selector);
        _tryBnb();
    }

    function test_Oracle_IncompleteRoundReverts() public {
        feed.setRound(10, BNB_PRICE, block.timestamp, 9); // answer carried over from an older round
        vm.expectRevert(OnlyWhalesVault.OracleIncompleteRound.selector);
        _tryBnb();

        feed.setRound(10, BNB_PRICE, 0, 10); // round not finished
        vm.expectRevert(OnlyWhalesVault.OracleIncompleteRound.selector);
        _tryBnb();
    }

    function test_Oracle_DeadFeedCannotTrapPrincipal() public {
        _depositBNB(alice, 300_000e18, 30 days);
        uint256 principal = _pos(alice, BNB).amount;
        feed.setBroken(true);
        _skip(30 days);

        (uint256 payout,) = _withdraw(alice, BNB);
        assertEq(payout, principal, "withdraw never reads the oracle");
        assertEq(alice.balance, principal);
    }

    function test_BrokenDaoWalletCannotTrapPrincipal() public {
        // The DAO wallet is only ever paid by sweepDao, never inside a user's transaction.
        _depositBNB(alice, 300_000e18, 30 days);
        _depositBNB(bob, 300_000e18, 30 days);
        vm.etch(dao, hex"60006000fd"); // DAO wallet now reverts on receive
        _skip(15 days);
        (uint256 payout, uint256 slashed) = _withdraw(alice, BNB);
        assertGt(slashed, 0);
        assertEq(alice.balance, payout);

        vm.expectRevert(OnlyWhalesVault.TransferFailed.selector);
        vault.sweepDao(BNB);
    }
}
