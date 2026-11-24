// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {OnlyWhalesVault} from "../src/OnlyWhalesVault.sol";
import {WhalePass} from "../src/WhalePass.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

contract PassTest is Base {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    function _id(address who) internal pure returns (uint256) {
        return uint256(uint160(who));
    }

    function test_Mint_OnFirstDeposit() public {
        assertEq(pass.balanceOf(alice), 0);
        usdc.mint(alice, 300_000e18);
        vm.startPrank(alice);
        usdc.approve(address(vault), 300_000e18);
        vm.expectEmit(true, true, true, true, address(pass));
        emit Transfer(address(0), alice, _id(alice));
        vault.depositUSDC(300_000e18, 30 days);
        vm.stopPrank();

        assertEq(pass.balanceOf(alice), 1);
        assertEq(pass.ownerOf(_id(alice)), alice);
        assertEq(pass.totalSupply(), 1);
        assertTrue(pass.locked(_id(alice)));
    }

    function test_Mint_OnlyOncePerWallet() public {
        _depositUSDC(alice, 300_000e18, 30 days);
        _depositBNB(alice, 300_000e18, 30 days);
        _skip(30 days);
        _withdraw(alice, USDC);
        _depositUSDC(alice, 300_000e18, 30 days);
        assertEq(pass.balanceOf(alice), 1);
        assertEq(pass.totalSupply(), 1);
    }

    function test_Mint_OnlyVault() public {
        vm.prank(operator);
        vm.expectRevert(WhalePass.NotVault.selector);
        pass.mint(operator);
        assertEq(pass.vault(), address(vault));
    }

    function test_Soulbound_EveryTransferPathReverts() public {
        _depositUSDC(alice, 300_000e18, 30 days);
        uint256 id = _id(alice);
        vm.startPrank(alice);
        vm.expectRevert(WhalePass.Soulbound.selector);
        pass.transferFrom(alice, bob, id);
        vm.expectRevert(WhalePass.Soulbound.selector);
        pass.safeTransferFrom(alice, bob, id);
        vm.expectRevert(WhalePass.Soulbound.selector);
        pass.safeTransferFrom(alice, bob, id, "");
        vm.expectRevert(WhalePass.Soulbound.selector);
        pass.approve(bob, id);
        vm.expectRevert(WhalePass.Soulbound.selector);
        pass.setApprovalForAll(bob, true);
        vm.stopPrank();

        assertEq(pass.ownerOf(id), alice);
        assertEq(pass.getApproved(id), address(0));
        assertFalse(pass.isApprovedForAll(alice, bob));
    }

    function test_Interfaces() public view {
        assertTrue(pass.supportsInterface(type(IERC721).interfaceId));
        assertTrue(pass.supportsInterface(0x5b5e139f)); // ERC721Metadata
        assertTrue(pass.supportsInterface(0xb45a3c0e)); // ERC-5192 soulbound
        assertTrue(pass.supportsInterface(0x01ffc9a7)); // ERC165
        assertFalse(pass.supportsInterface(0xffffffff));
    }

    function test_NonexistentToken() public {
        vm.expectRevert(WhalePass.NonexistentToken.selector);
        pass.ownerOf(_id(bob));
        vm.expectRevert(WhalePass.NonexistentToken.selector);
        pass.tokenURI(_id(bob));
        vm.expectRevert(WhalePass.NonexistentToken.selector);
        pass.ownerOf(type(uint256).max);
    }

    // ---------------------------------------------------------------- access

    function test_Access_NeedsPassAndOpenPosition() public {
        assertFalse(vault.hasAccess(alice), "no pass, no position");
        _depositUSDC(alice, 300_000e18, 30 days);
        assertTrue(vault.hasAccess(alice));

        _skip(60 days);
        assertTrue(vault.hasAccess(alice), "unlocked but still in the pool");

        _withdraw(alice, USDC);
        assertEq(pass.balanceOf(alice), 1, "pass is forever");
        assertFalse(vault.hasAccess(alice), "but the gate needs a position");

        _depositBNB(alice, 300_000e18, 30 days);
        assertTrue(vault.hasAccess(alice), "either pool counts");
        assertFalse(vault.hasAccess(address(0)));
    }

    function test_Access_SlashedOutLosesAccess() public {
        _depositUSDC(alice, 300_000e18, 365 days);
        _withdraw(alice, USDC);
        assertFalse(vault.hasAccess(alice));
    }

    // ----------------------------------------------------------------- tiers

    function test_Tiers_TenLevels_BySizeAndLock() public view {
        assertEq(vault.tierFor(10_000e18, 30 days), 0);
        assertEq(vault.tierFor(250_000e18, 30 days), 1);
        assertEq(vault.tierFor(250_000e18, 90 days), 2);
        assertEq(vault.tierFor(500_000e18, 180 days), 4);
        assertEq(vault.tierFor(750_000e18, 365 days), 6);
        assertEq(vault.tierFor(1_000_000e18, 730 days), 8);
        assertEq(vault.tierFor(1_000_000e18, 1024 days), 9);
        assertEq(vault.TIER_COUNT(), 10);
    }

    function testFuzz_TierIsMonotonic(uint256 usd, uint256 lock, uint256 moreUsd, uint256 moreLock)
        public
        view
    {
        usd = bound(usd, 10_000e18, 1_000_000e18);
        lock = bound(lock, 30 days, 1024 days);
        moreUsd = bound(moreUsd, usd, 1_000_000e18);
        moreLock = bound(moreLock, lock, 1024 days);
        uint8 tier = vault.tierFor(usd, lock);
        assertLe(tier, 9);
        assertGe(vault.tierFor(moreUsd, moreLock), tier);
    }

    function test_Tier_SetAtDeposit_RisesOnRelock_NeverDrops() public {
        _depositUSDC(alice, 500_000e18, 90 days);
        assertEq(vault.passTier(alice), 3);
        assertEq(pass.tierOf(_id(alice)), 3);

        vm.prank(alice);
        vault.relock(USDC, 1024 days);
        assertEq(vault.passTier(alice), 7);

        _skip(1024 days);
        _withdraw(alice, USDC);
        _depositUSDC(alice, 250_000e18, 30 days);
        assertEq(vault.passTier(alice), 7, "highest tier reached sticks");
    }

    function test_TokenURI_CarriesTierArtwork() public {
        _depositUSDC(alice, 1_000_000e18, 1024 days);
        string memory uri = pass.tokenURI(_id(alice));
        bytes memory prefix = bytes("data:application/json;base64,");
        bytes memory raw = bytes(uri);
        bytes memory b64 = new bytes(raw.length - prefix.length);
        for (uint256 i; i < b64.length; ++i) {
            b64[i] = raw[i + prefix.length];
        }
        string memory json = string(Base64.decode(string(b64)));
        assertEq(vm.parseJsonString(json, ".image"), "ipfs://tier-9");
        assertEq(vm.parseJsonUint(json, ".attributes[0].value"), 10);

        vm.prank(operator);
        vault.queueTierURI(9, "ipfs://leviathan");
        _skip(7 days);
        assertEq(vault.tierURI(9), "ipfs://leviathan");
    }
}
