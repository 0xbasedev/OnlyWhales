// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OnlyWhalesVault} from "../src/OnlyWhalesVault.sol";
import {WhalePass} from "../src/WhalePass.sol";
import {MockUSDC, MockFeed} from "./mocks/Mocks.sol";

abstract contract Base is Test {
    uint8 internal constant USDC = 0;
    uint8 internal constant BNB = 1;
    int256 internal constant BNB_PRICE = 600e8;
    uint256 internal constant STALENESS = 1 hours;
    uint256 internal constant DAY = 1 days;
    uint256 internal constant WAD = 1e18;

    OnlyWhalesVault internal vault;
    WhalePass internal pass;
    MockUSDC internal usdc;
    MockFeed internal feed;

    address internal operator = makeAddr("operator");
    address internal dao = makeAddr("dao");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        usdc = new MockUSDC();
        feed = new MockFeed(8, BNB_PRICE);
        vault = _deploy(300, 250_000e18, 1_000_000e18);
        pass = vault.pass();
    }

    function _deploy(uint256 feeBps, uint256 minUsd, uint256 maxUsd) internal returns (OnlyWhalesVault) {
        string[10] memory uris;
        for (uint256 i; i < 10; ++i) {
            uris[i] = string.concat("ipfs://tier-", vm.toString(i));
        }
        return new OnlyWhalesVault(
            OnlyWhalesVault.Config({
                operator: operator,
                daoWallet: dao,
                usdc: address(usdc),
                bnbUsdFeed: address(feed),
                oracleStaleness: STALENESS,
                depositFeeBps: feeBps,
                minDepositUsd: minUsd,
                maxDepositUsd: maxUsd,
                tierURIs: uris
            })
        );
    }

    function _depositUSDC(address who, uint256 amount, uint256 lock) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        vault.depositUSDC(amount, lock);
        vm.stopPrank();
    }

    /// @dev Deposits BNB worth at least `usd` at a fresh oracle answer.
    function _depositBNB(address who, uint256 usd, uint256 lock) internal returns (uint256 value) {
        feed.setAnswer(BNB_PRICE);
        value = bnbFor(usd);
        vm.deal(who, who.balance + value);
        vm.prank(who);
        vault.depositBNB{value: value}(lock);
    }

    function bnbFor(uint256 usd) internal pure returns (uint256) {
        return (usd * 1e8) / uint256(BNB_PRICE) + 1;
    }

    function _withdraw(address who, uint8 pool) internal returns (uint256 payout, uint256 slashed) {
        vm.prank(who);
        (payout, slashed) = vault.withdraw(pool);
    }

    function _pos(address who, uint8 pool) internal view returns (OnlyWhalesVault.PositionView memory) {
        return vault.positionOf(who, pool);
    }

    function _pool(uint8 pool) internal view returns (OnlyWhalesVault.PoolView memory) {
        return vault.poolInfo(pool);
    }

    function _queue(OnlyWhalesVault.Param param, uint256 value) internal {
        vm.prank(operator);
        vault.queueChange(param, value);
    }

    function _skip(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
    }
}
