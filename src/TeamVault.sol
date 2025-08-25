// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ITeamVault} from "./interfaces/ITeamVault.sol";

/// @title TeamVault
/// @notice Holds team funds (native ETH) and funds authorized game contracts
///         (e.g., TimeTicket) on demand using native transfers.
contract TeamVault is ITeamVault, Ownable {
    /// @dev Authorized addresses allowed to call Fund()
    mapping(address => bool) public isFunder;

    /// @notice Emitted when a funder authorization is updated
    event FunderUpdated(address indexed funder, bool allowed);
    /// @notice Emitted when ETH is sent out
    event Transferred(address indexed to, uint256 amount);
    /// @notice Emitted when ETH is received
    event Received(address indexed from, uint256 amount);

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Accept direct ETH transfers
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    /// @notice Deposit ETH into the vault
    function deposit() external payable {
        emit Received(msg.sender, msg.value);
    }

    /// @notice Authorize or revoke a funder
    function setFunder(address funder, bool allowed) external onlyOwner {
        isFunder[funder] = allowed;
        emit FunderUpdated(funder, allowed);
    }

    /// @inheritdoc ITeamVault
    function Fund(uint256 amount) external {
        require(isFunder[msg.sender], "NOT_FUNDER");
        if (address(this).balance < amount) {
            amount = address(this).balance;
        }
        payable(msg.sender).transfer(amount);
        emit Transferred(msg.sender, amount);
    }

    /// @notice Owner can withdraw ETH to a safe destination
    function withdraw(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "ZERO_ADDR");
        require(address(this).balance >= amount, "INSUFFICIENT_BAL");
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "WITHDRAW_FAIL");
        emit Transferred(to, amount);
    }
}
