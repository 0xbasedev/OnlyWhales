// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Timelocked
/// @notice Values that change on a delay with no execute step.
/// @dev A queued value simply becomes the value returned by `get` once `block.timestamp >= eta`.
///      Nothing has to be called for it to take effect. Only one change can be pending at a time,
///      and a pending change can be cancelled strictly before its eta.
library Timelocked {
    error ChangePending();
    error NothingPending();
    error NoChange();

    struct Uint {
        uint256 current;
        uint256 pending;
        uint64 eta;
    }

    struct Str {
        string current;
        string pending;
        uint64 eta;
    }

    // ------------------------------------------------------------------ uint

    function get(Uint storage s) internal view returns (uint256) {
        return (s.eta != 0 && block.timestamp >= s.eta) ? s.pending : s.current;
    }

    function hasPending(Uint storage s) internal view returns (bool) {
        return s.eta != 0 && block.timestamp < s.eta;
    }

    function queue(Uint storage s, uint256 value, uint256 delay) internal returns (uint256 old, uint64 eta) {
        if (hasPending(s)) revert ChangePending();
        old = get(s);
        if (value == old) revert NoChange();
        eta = uint64(block.timestamp + delay);
        s.current = old; // fold in any change that already took effect
        s.pending = value;
        s.eta = eta;
    }

    function cancel(Uint storage s) internal returns (uint256 cancelled) {
        if (!hasPending(s)) revert NothingPending();
        cancelled = s.pending;
        s.pending = 0;
        s.eta = 0;
    }

    // ---------------------------------------------------------------- string

    function get(Str storage s) internal view returns (string memory) {
        return (s.eta != 0 && block.timestamp >= s.eta) ? s.pending : s.current;
    }

    function hasPending(Str storage s) internal view returns (bool) {
        return s.eta != 0 && block.timestamp < s.eta;
    }

    function queue(Str storage s, string memory value, uint256 delay) internal returns (uint64 eta) {
        if (hasPending(s)) revert ChangePending();
        if (s.eta != 0) s.current = s.pending; // fold in a change that already took effect
        eta = uint64(block.timestamp + delay);
        s.pending = value;
        s.eta = eta;
    }

    function cancel(Str storage s) internal {
        if (!hasPending(s)) revert NothingPending();
        delete s.pending;
        s.eta = 0;
    }
}
