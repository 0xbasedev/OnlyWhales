// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OnlyWhalesVault} from "../src/OnlyWhalesVault.sol";

/// @notice Runs against real BSC state: the real Binance-Peg USDC and the real Chainlink feed.
///         Skipped unless BSC_RPC_URL is set:  BSC_RPC_URL=https://... forge test --mc ForkTest
contract ForkTest is Test {
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address internal constant FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;

    OnlyWhalesVault internal vault;
    address internal whale = makeAddr("forkWhale");
    bool internal live;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        live = true;

        string[10] memory uris;
        vault = new OnlyWhalesVault(
            OnlyWhalesVault.Config({
                operator: makeAddr("operator"),
                daoWallet: makeAddr("dao"),
                usdc: USDC,
                bnbUsdFeed: FEED,
                oracleStaleness: 600,
                depositFeeBps: 300,
                minDepositUsd: 250_000e18,
                maxDepositUsd: 1_000_000e18,
                tierURIs: uris
            })
        );
    }

    function test_Fork_RealFeedIsFreshAndSane() public {
        if (!live) return vm.skip(true);
        assertEq(vault.bnbUsdFeedDecimals(), 8);
        uint256 price = vault.bnbUsdPrice(); // reverts if older than 10 minutes
        assertGt(price, 10e8);
        assertLt(price, 100_000e8);
    }

    function test_Fork_RealUsdc_DepositAndCleanExit() public {
        if (!live) return vm.skip(true);
        deal(USDC, whale, 300_000e18);
        vm.startPrank(whale);
        IERC20(USDC).approve(address(vault), 300_000e18);
        vault.depositUSDC(300_000e18, 30 days);
        assertEq(vault.positionOf(whale, 0).amount, 291_000e18);
        assertTrue(vault.hasAccess(whale));

        vm.warp(block.timestamp + 30 days);
        (uint256 payout, uint256 slashed) = vault.withdraw(0);
        vm.stopPrank();
        assertEq(payout, 291_000e18);
        assertEq(slashed, 0);
        assertEq(IERC20(USDC).balanceOf(whale), 291_000e18);
    }

    function test_Fork_RealBnb_DepositAtLivePrice() public {
        if (!live) return vm.skip(true);
        uint256 price = vault.bnbUsdPrice();
        uint256 value = (300_000e18 * 1e8) / price + 1;
        vm.deal(whale, value);
        vm.prank(whale);
        vault.depositBNB{value: value}(90 days);
        assertApproxEqRel(vault.positionOf(whale, 1).grossUsd, 300_000e18, 1e12);

        vm.prank(whale);
        (uint256 payout, uint256 slashed) = vault.withdraw(1);
        assertEq(payout, 0, "100% at deposit");
        assertEq(slashed, value - (value * 300) / 10_000);
    }
}
