// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {OnlyWhalesVault} from "../src/OnlyWhalesVault.sol";

/// @notice Deploys the vault from config/prelaunch.json.
/// @dev    forge script contracts/script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
///
///         Mainnet is refused unless OUTSIDE_AUDIT_REPORT_URL is set. That is a speed bump, not a
///         substitute for the audit: do not point it at something that is not one.
contract Deploy is Script {
    uint256 internal constant BSC_MAINNET = 56;

    function run() external returns (OnlyWhalesVault vault) {
        string memory json = vm.readFile("config/prelaunch.json");
        uint256 chainId = vm.parseJsonUint(json, ".network.chainId");
        require(block.chainid == chainId, "Deploy: connected chain does not match config/prelaunch.json");

        if (block.chainid == BSC_MAINNET) {
            string memory audit = vm.envOr("OUTSIDE_AUDIT_REPORT_URL", string(""));
            require(bytes(audit).length != 0, "Deploy: no mainnet deploy without an outside audit");
            console.log("Audit report:", audit);
        }

        OnlyWhalesVault.Config memory c;
        c.operator = vm.parseJsonAddress(json, ".operator");
        c.daoWallet = vm.parseJsonAddress(json, ".daoWallet");
        c.usdc = vm.parseJsonAddress(json, ".network.usdc");
        c.bnbUsdFeed = vm.parseJsonAddress(json, ".network.bnbUsdFeed");
        c.oracleStaleness = vm.parseJsonUint(json, ".network.oracleStalenessSeconds");
        c.depositFeeBps = vm.parseJsonUint(json, ".settings.depositFeeBps");
        c.minDepositUsd = vm.parseJsonUint(json, ".settings.minDepositUsd") * 1e18;
        c.maxDepositUsd = vm.parseJsonUint(json, ".settings.maxDepositUsd") * 1e18;
        string[] memory uris = vm.parseJsonStringArray(json, ".tierURIs");
        require(uris.length == 10, "Deploy: need exactly 10 tier URIs");
        for (uint256 i; i < 10; ++i) {
            c.tierURIs[i] = uris[i];
        }
        require(c.operator != address(0) && c.daoWallet != address(0), "Deploy: set operator and daoWallet");

        vm.startBroadcast();
        vault = new OnlyWhalesVault(c);
        vm.stopBroadcast();

        console.log("OnlyWhalesVault:", address(vault));
        console.log("WhalePass:      ", address(vault.pass()));
        console.log("Operator (immutable):", vault.operator());
        console.log("DAO wallet:", vault.daoWallet());
        console.log("BNB/USD right now (feed decimals):", vault.bnbUsdPrice());
    }
}
