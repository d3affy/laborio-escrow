// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Read-only surface for Escrow contracts and UI to query factory controls
interface IFactoryConfig {
    function nextEscrowId() external view returns (uint256);
    function paused() external view returns (bool);
    function fundPaused() external view returns (bool);
    function arbitrator() external view returns (address);
    function isTokenAllowed(address token) external view returns (bool);
}
