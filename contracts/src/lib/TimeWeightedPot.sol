// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TimeWeightedPot
/// @notice O(1) pro-rata distribution where each member's share grows linearly with time.
/// @dev A member with static weight `a` who started at time `s` has live weight `a * (t - s)`.
///      The pot's total live weight is `sumA * t - sumAS`, where `sumA = Σa` and `sumAS = Σ a·s`.
///
///      Distributing `x` at time `t` owes member i:
///          x · a_i · (t - s_i) / W(t)  =  a_i · (x·t / W)  -  a_i·s_i · (x / W)
///      so two running sums are enough: `accP += x·t/W` and `accQ += x/W`.
///
///      Rounding always favours the pot: accP rounds down, accQ rounds up, the positive term
///      rounds down and the negative term rounds up. The sum of everything members can claim is
///      therefore never more than what was distributed. Dust stays in the vault.
library TimeWeightedPot {
    uint256 internal constant PRECISION = 1e36;

    struct Pot {
        uint256 sumA;
        uint256 sumAS;
        uint256 accP;
        uint256 accQ;
    }

    function weightAt(Pot storage pot, uint256 t) internal view returns (uint256) {
        return pot.sumA * t - pot.sumAS;
    }

    function join(Pot storage pot, uint256 a, uint256 s) internal {
        pot.sumA += a;
        pot.sumAS += a * s;
    }

    function leave(Pot storage pot, uint256 a, uint256 s) internal {
        pot.sumA -= a;
        pot.sumAS -= a * s;
    }

    /// @dev Caller must have checked `weightAt(t) > 0`.
    function distribute(Pot storage pot, uint256 amount, uint256 t) internal {
        uint256 w = weightAt(pot, t);
        pot.accP += Math.mulDiv(amount * t, PRECISION, w);
        pot.accQ += Math.mulDiv(amount, PRECISION, w, Math.Rounding.Ceil);
    }

    function earned(Pot storage pot, uint256 a, uint256 s, uint256 snapP, uint256 snapQ)
        internal
        view
        returns (uint256)
    {
        uint256 plus = Math.mulDiv(a, pot.accP - snapP, PRECISION);
        uint256 minus = Math.mulDiv(a * s, pot.accQ - snapQ, PRECISION, Math.Rounding.Ceil);
        return plus > minus ? plus - minus : 0;
    }
}
