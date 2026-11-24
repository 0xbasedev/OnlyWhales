// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {OnlyWhalesVault} from "../src/OnlyWhalesVault.sol";
import {MockUSDC, MockFeed} from "../test/mocks/Mocks.sol";

/// @notice Local anvil only: mock USDC + mock BNB/USD feed + vault, with funded test whales.
///         The first anvil account is the operator, the second is the DAO wallet.
contract DeployLocal is Script {
    function run() external {
        require(block.chainid == 31337, "DeployLocal: anvil only");
        address operator = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
        address dao = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        address[3] memory whales = [
            operator,
            0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC,
            0x90F79bf6EB2c4f870365E785982E1f101E93b906
        ];

        vm.startBroadcast();
        MockUSDC usdc = new MockUSDC();
        MockFeed feed = new MockFeed(8, 600e8);
        string[10] memory uris;
        OnlyWhalesVault vault = new OnlyWhalesVault(
            OnlyWhalesVault.Config({
                operator: operator,
                daoWallet: dao,
                usdc: address(usdc),
                bnbUsdFeed: address(feed),
                oracleStaleness: 3650 days, // the mock feed never updates by itself
                depositFeeBps: 300,
                minDepositUsd: 250_000e18,
                maxDepositUsd: 1_000_000e18,
                tierURIs: uris
            })
        );
        for (uint256 i; i < whales.length; ++i) {
            usdc.mint(whales[i], 5_000_000e18);
        }
        vm.stopBroadcast();

        console.log("VAULT", address(vault));
        console.log("USDC", address(usdc));
        console.log("FEED", address(feed));
    }
}
