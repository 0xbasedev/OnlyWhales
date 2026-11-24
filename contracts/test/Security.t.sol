// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {OnlyWhalesVault} from "../src/OnlyWhalesVault.sol";
import {ReentrantWhale} from "./mocks/Mocks.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract SecurityTest is Base {
    // ------------------------------------------------- the whole write surface

    /// Every state-changing function the vault has. If someone adds a pause, an upgrade hook,
    /// an owner transfer or a rescue function, this test fails until the list is edited by hand.
    function test_WriteSurface_IsExactlyThis() public view {
        string[11] memory allowed = [
            "depositUSDC",
            "depositBNB",
            "relock",
            "withdraw",
            "claim",
            "sweepDao",
            "sync",
            "queueChange",
            "cancelChange",
            "queueTierURI",
            "cancelTierURI"
        ];
        string memory artifact = vm.readFile("out/OnlyWhalesVault.sol/OnlyWhalesVault.json");
        uint256 writes;
        for (uint256 i;; ++i) {
            string memory at = string.concat(".abi[", vm.toString(i), "]");
            if (!vm.keyExistsJson(artifact, at)) break;
            if (keccak256(bytes(vm.parseJsonString(artifact, string.concat(at, ".type")))) != keccak256("function")) {
                assertFalse(
                    keccak256(bytes(vm.parseJsonString(artifact, string.concat(at, ".type")))) == keccak256("fallback"),
                    "no fallback"
                );
                assertFalse(
                    keccak256(bytes(vm.parseJsonString(artifact, string.concat(at, ".type")))) == keccak256("receive"),
                    "no receive"
                );
                continue;
            }
            string memory mut = vm.parseJsonString(artifact, string.concat(at, ".stateMutability"));
            if (keccak256(bytes(mut)) == keccak256("view") || keccak256(bytes(mut)) == keccak256("pure")) continue;
            string memory fn = vm.parseJsonString(artifact, string.concat(at, ".name"));
            bool found;
            for (uint256 j; j < allowed.length; ++j) {
                if (keccak256(bytes(fn)) == keccak256(bytes(allowed[j]))) found = true;
            }
            assertTrue(found, string.concat("unexpected state-changing function: ", fn));
            ++writes;
        }
        assertEq(writes, allowed.length);
    }

    function test_NoPauseExists() public {
        string[14] memory sigs = [
            "pause()",
            "unpause()",
            "paused()",
            "setPaused(bool)",
            "togglePause()",
            "freeze()",
            "emergencyStop()",
            "shutdown()",
            "kill()",
            "pauseDeposits()",
            "pauseWithdrawals()",
            "setDepositsEnabled(bool)",
            "setWithdrawalsEnabled(bool)",
            "emergencyPause()"
        ];
        _assertNoneExist(sigs);
    }

    function test_NoPause_DepositsAndExitsWorkWhateverTheOperatorDoes() public {
        _depositUSDC(alice, 300_000e18, 30 days);
        // Operator throws everything it has.
        vm.startPrank(operator);
        vault.queueChange(OnlyWhalesVault.Param.DepositFee, 50);
        vault.queueChange(OnlyWhalesVault.Param.MaxDeposit, 250_000e18);
        vault.queueChange(OnlyWhalesVault.Param.DaoWallet, uint256(uint160(operator)));
        vm.stopPrank();
        _skip(30 days);

        _depositUSDC(bob, 250_000e18, 30 days);
        (uint256 payout,) = _withdraw(alice, USDC);
        assertEq(payout, 291_000e18);
    }

    function test_NoProxy_NoUpgrade() public {
        string[14] memory sigs = [
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "implementation()",
            "proxiableUUID()",
            "admin()",
            "changeAdmin(address)",
            "initialize()",
            "initialize(address)",
            "setImplementation(address)",
            "migrate(address)",
            "selfDestruct()",
            "destroy()",
            "delegate(address,bytes)",
            "execute(address,uint256,bytes)"
        ];
        _assertNoneExist(sigs);
        // EIP-1967 implementation, admin and beacon slots are empty.
        assertEq(vm.load(address(vault), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc), 0);
        assertEq(vm.load(address(vault), 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103), 0);
        assertEq(vm.load(address(vault), 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50), 0);
    }

    function test_OperatorIsImmutable() public {
        string[14] memory sigs = [
            "transferOwnership(address)",
            "renounceOwnership()",
            "acceptOwnership()",
            "owner()",
            "pendingOwner()",
            "setOperator(address)",
            "transferOperator(address)",
            "renounceOperator()",
            "queueOperator(address)",
            "setOwner(address)",
            "grantRole(bytes32,address)",
            "revokeRole(bytes32,address)",
            "renounceRole(bytes32,address)",
            "setGovernance(address)"
        ];
        _assertNoneExist(sigs);
        assertEq(vault.operator(), operator);

        // Immutables live in bytecode, not storage: no storage slot holds the operator address.
        for (uint256 slot; slot < 64; ++slot) {
            assertTrue(vm.load(address(vault), bytes32(slot)) != bytes32(uint256(uint160(operator))));
        }

        // The DAO-wallet setting is a different thing and cannot be used to move the operator.
        _queue(OnlyWhalesVault.Param.DaoWallet, uint256(uint160(alice)));
        _skip(7 days);
        assertEq(vault.operator(), operator);
        vm.prank(alice);
        vm.expectRevert(OnlyWhalesVault.NotOperator.selector);
        vault.queueChange(OnlyWhalesVault.Param.DepositFee, 100);
    }

    function test_NoFunctionTouchesPrincipal() public {
        string[14] memory sigs = [
            "emergencyWithdraw()",
            "emergencyWithdraw(address)",
            "rescue(address,uint256)",
            "rescueTokens(address,uint256)",
            "recoverERC20(address,uint256)",
            "sweep(address)",
            "skim(address)",
            "withdrawTo(address,uint256)",
            "withdrawFor(address,uint8)",
            "adminWithdraw(uint256)",
            "drain()",
            "seize(address)",
            "slash(address,uint8)",
            "setSlash(uint256)"
        ];
        _assertNoneExist(sigs);

        _depositUSDC(alice, 300_000e18, 30 days);
        _depositBNB(bob, 300_000e18, 30 days);
        uint256 bobPrincipal = _pos(bob, BNB).amount;

        // The operator has no position, so the user functions give it nothing.
        vm.startPrank(operator);
        vm.expectRevert(OnlyWhalesVault.NoPosition.selector);
        vault.withdraw(USDC);
        vm.expectRevert(OnlyWhalesVault.NothingToClaim.selector);
        vault.claim(BNB);
        vm.stopPrank();

        // Sweeping only ever moves the fee, never principal.
        vault.sweepDao(USDC);
        vault.sweepDao(BNB);
        assertEq(usdc.balanceOf(address(vault)), 291_000e18);
        assertEq(address(vault).balance, bobPrincipal);

        _skip(30 days);
        (uint256 a,) = _withdraw(alice, USDC);
        (uint256 b,) = _withdraw(bob, BNB);
        assertEq(a, 291_000e18);
        assertEq(b, bobPrincipal);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(address(vault).balance, 0);
    }

    function test_ImmutableConstants() public view {
        assertEq(vault.TIMELOCK(), 7 days);
        assertEq(vault.FEE_BPS_MIN(), 50);
        assertEq(vault.FEE_BPS_MAX(), 300);
        assertEq(vault.DEPOSIT_USD_MIN(), 10_000e18);
        assertEq(vault.DEPOSIT_USD_MAX(), 1_000_000e18);
        assertEq(vault.SLASH_START_WAD(), 1e18);
        assertEq(vault.SLASH_END_WAD(), 0.3e18);
        assertEq(vault.SLASH_DAO_BPS(), 2_000);
        assertEq(vault.PRE_ELDER_DAO_BPS(), 1_000);
        assertEq(vault.ELDER_SECONDS(), 1024 days);
        assertEq(address(vault.usdc()), address(usdc));
        assertEq(address(vault.bnbUsdFeed()), address(feed));
        assertEq(vault.oracleStaleness(), STALENESS);
    }

    function _assertNoneExist(string[14] memory sigs) internal {
        for (uint256 i; i < sigs.length; ++i) {
            vm.prank(operator);
            (bool ok,) = address(vault).call(abi.encodeWithSignature(sigs[i]));
            assertFalse(ok, string.concat("vault answers ", sigs[i]));
        }
    }

    // ------------------------------------------------------------ reentrancy

    function test_Reentrancy_WithdrawIsGuarded() public {
        ReentrantWhale whale = new ReentrantWhale(vault);
        feed.setAnswer(BNB_PRICE);
        uint256 value = bnbFor(300_000e18);
        vm.deal(address(this), value);
        whale.deposit{value: value}(30 days);
        _depositBNB(bob, 300_000e18, 365 days);
        _skip(15 days);

        uint256 principal = _pos(address(whale), BNB).amount;
        uint256 slashWad = _pos(address(whale), BNB).slashWad;
        whale.withdraw();

        assertEq(whale.attempts(), 6);
        assertEq(whale.blocked(), 6, "every re-entry bounced");
        assertEq(whale.lastError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(_pos(address(whale), BNB).amount, 0);
        assertApproxEqAbs(address(whale).balance, principal - (principal * slashWad) / 1e18, 1, "paid exactly once");

        OnlyWhalesVault.PoolView memory pool = _pool(BNB);
        assertEq(address(vault).balance, pool.totalPrincipal + pool.rewardReserve + pool.daoOwed);
    }

    function test_Reentrancy_ClaimIsGuarded() public {
        ReentrantWhale whale = new ReentrantWhale(vault);
        feed.setAnswer(BNB_PRICE);
        uint256 value = bnbFor(300_000e18);
        vm.deal(address(this), value);
        whale.deposit{value: value}(365 days);
        _skip(1 days);
        _depositBNB(bob, 300_000e18, 30 days);
        _skip(1 days);
        _withdraw(bob, BNB);

        uint256 owed = _pos(address(whale), BNB).earned;
        assertGt(owed, 0);
        whale.claim();
        assertEq(whale.blocked(), whale.attempts());
        assertEq(address(whale).balance, owed, "claimed exactly once");
        assertEq(_pos(address(whale), BNB).earned, 0);
    }
}
