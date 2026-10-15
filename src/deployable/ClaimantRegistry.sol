// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Append-only claimant index, owned by one fixed custody/accounting contract.
/// @dev Constructed by the registrar itself; owner/operator cannot replace provenance.
contract ClaimantRegistry {
    error UnauthorizedRegistrar();
    error InvalidClaimant();

    address public immutable registrar;
    address[] internal _accounts;
    mapping(address => bool) internal _seen;

    event ClaimantRecorded(address indexed account, uint256 indexed index);

    constructor() {
        registrar = msg.sender;
    }

    function record(address account) external {
        if (msg.sender != registrar) revert UnauthorizedRegistrar();
        if (account == address(0)) revert InvalidClaimant();
        if (_seen[account]) return;

        _seen[account] = true;
        uint256 index = _accounts.length;
        _accounts.push(account);
        emit ClaimantRecorded(account, index);
    }

    function count() external view returns (uint256) {
        return _accounts.length;
    }

    function at(uint256 index) external view returns (address) {
        return _accounts[index];
    }

    function contains(address account) external view returns (bool) {
        return _seen[account];
    }
}
