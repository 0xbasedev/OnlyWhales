// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface IWhalePassSource {
    function passTier(address wallet) external view returns (uint8);
    function tierURI(uint8 tier) external view returns (string memory);
}

/// @title WhalePass
/// @notice Soulbound membership pass. One per wallet, minted by the vault on first deposit.
/// @dev Token id is the holder's address, so a pass can never belong to anyone else.
///      Every transfer and approval path reverts. There is no burn.
contract WhalePass is IERC721Metadata {
    error Soulbound();
    error NotVault();
    error NonexistentToken();
    error ZeroAddress();

    /// @notice ERC-5192: emitted once at mint. Passes are permanently locked.
    event Locked(uint256 tokenId);

    string public constant name = "OnlyWhales Pass";
    string public constant symbol = "WHALE";

    /// @notice The vault that mints passes and supplies tier + artwork.
    address public immutable vault;

    uint256 public totalSupply;
    mapping(address => bool) private _holds;

    constructor() {
        vault = msg.sender;
    }

    // ------------------------------------------------------------------ mint

    /// @notice Mint the pass for `to`. Vault only. No-op if `to` already holds one.
    function mint(address to) external returns (bool minted) {
        if (msg.sender != vault) revert NotVault();
        if (to == address(0)) revert ZeroAddress();
        if (_holds[to]) return false;
        _holds[to] = true;
        unchecked {
            ++totalSupply;
        }
        uint256 tokenId = uint256(uint160(to));
        emit Transfer(address(0), to, tokenId);
        emit Locked(tokenId);
        return true;
    }

    // ----------------------------------------------------------------- views

    function tokenIdOf(address wallet) public pure returns (uint256) {
        return uint256(uint160(wallet));
    }

    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert ZeroAddress();
        return _holds[owner] ? 1 : 0;
    }

    function ownerOf(uint256 tokenId) public view returns (address owner) {
        if (tokenId > type(uint160).max) revert NonexistentToken();
        owner = address(uint160(tokenId));
        if (!_holds[owner]) revert NonexistentToken();
    }

    /// @notice ERC-5192: every pass is locked forever.
    function locked(uint256 tokenId) external view returns (bool) {
        ownerOf(tokenId);
        return true;
    }

    function tierOf(uint256 tokenId) public view returns (uint8) {
        return IWhalePassSource(vault).passTier(ownerOf(tokenId));
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        uint8 tier = tierOf(tokenId);
        string memory tierLabel = Strings.toString(uint256(tier) + 1);
        bytes memory json = abi.encodePacked(
            '{"name":"OnlyWhales Pass \\u2014 Tier ',
            tierLabel,
            '","description":"Soulbound. Non-transferable. Opens the pool gate while you hold a position.",',
            '"image":"',
            IWhalePassSource(vault).tierURI(tier),
            '","attributes":[{"trait_type":"Tier","value":',
            tierLabel,
            '},{"trait_type":"Transferable","value":"Never"}]}'
        );
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)));
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        ownerOf(tokenId);
        return address(0);
    }

    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC721).interfaceId
            || interfaceId == type(IERC721Metadata).interfaceId || interfaceId == 0xb45a3c0e; // ERC-5192
    }

    // ------------------------------------------------- soulbound: all revert

    function approve(address, uint256) external pure {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) external pure {
        revert Soulbound();
    }

    function transferFrom(address, address, uint256) external pure {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256) external pure {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) external pure {
        revert Soulbound();
    }
}
