// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ITeamVault
/// @notice Minimal interface for the TeamVault contract that holds team funds
///         and can fund authorized game contracts (e.g., TimeTicket) using
///         native ETH.
interface ITeamVault {
    /// @notice Fund the caller with the specified native amount.
    /// @dev Caller must be authorized by the vault owner via setFunder.
    /// @param amount The amount of native ETH to send to msg.sender
    function Fund(uint256 amount) external;
}
