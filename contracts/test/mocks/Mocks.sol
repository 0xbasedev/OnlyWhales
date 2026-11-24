// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {OnlyWhalesVault} from "../../src/OnlyWhalesVault.sol";

contract MockUSDC is ERC20("Binance-Peg USD Coin", "USDC") {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFeed {
    uint8 public immutable decimals;
    uint80 public roundId;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public answeredInRound;
    bool public broken;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        setAnswer(answer_);
    }

    function setAnswer(int256 answer_) public {
        roundId += 1;
        answer = answer_;
        updatedAt = block.timestamp;
        answeredInRound = roundId;
    }

    function setRound(uint80 roundId_, int256 answer_, uint256 updatedAt_, uint80 answeredInRound_) external {
        roundId = roundId_;
        answer = answer_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function setBroken(bool broken_) external {
        broken = broken_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "feed down");
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}

/// @dev Deposits BNB, then tries to re-enter the vault from its receive hook.
contract ReentrantWhale {
    OnlyWhalesVault public immutable vault;
    uint256 public attempts;
    uint256 public blocked;
    bytes4 public lastError;

    constructor(OnlyWhalesVault vault_) {
        vault = vault_;
    }

    function deposit(uint256 lock) external payable {
        vault.depositBNB{value: msg.value}(lock);
    }

    function withdraw() external {
        vault.withdraw(1);
    }

    function claim() external {
        vault.claim(1);
    }

    receive() external payable {
        bytes[5] memory calls = [
            abi.encodeCall(vault.withdraw, (1)),
            abi.encodeCall(vault.claim, (1)),
            abi.encodeCall(vault.sync, (address(this), 1)),
            abi.encodeCall(vault.sweepDao, (1)),
            abi.encodeCall(vault.relock, (1, 30 days))
        ];
        for (uint256 i; i < calls.length; ++i) {
            attempts++;
            (bool ok, bytes memory ret) = address(vault).call(calls[i]);
            if (!ok) {
                blocked++;
                lastError = bytes4(ret);
            }
        }
        attempts++;
        (bool ok2, bytes memory ret2) =
            address(vault).call{value: msg.value}(abi.encodeCall(vault.depositBNB, (30 days)));
        if (!ok2) {
            blocked++;
            lastError = bytes4(ret2);
        }
    }
}

contract RejectingWallet {
    receive() external payable {
        revert("no thanks");
    }
}
