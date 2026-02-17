// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMindstate} from "../../interfaces/IMindstate.sol";

/// @title IMindstateLaunchpad Interface Definitions
/// @notice Core interfaces for the Mindstate launchpad system (V3)

interface IMindstateLaunchFactory {
    struct Launch {
        address token;
        address creator;
        uint256 tokenSupply;
        uint256 redeemCost;
        IMindstate.RedeemMode redeemMode;
        address pool;
        uint256 createdAt;
        string name;
        string symbol;
    }

    event MindstateLaunched(
        address indexed token,
        address indexed creator,
        address indexed pool,
        string name,
        string symbol,
        uint256 tokenSupply,
        uint256 redeemCost,
        IMindstate.RedeemMode redeemMode
    );

    /// @notice Launch a new Mindstate token with V3 liquidity
    function launch(
        string calldata name,
        string calldata symbol,
        uint256 redeemCost,
        IMindstate.RedeemMode redeemMode
    ) external returns (address token, address pool);

    /// @notice Launch with custom supply
    function launchWithSupply(
        string calldata name,
        string calldata symbol,
        uint256 tokenSupply,
        uint256 redeemCost,
        IMindstate.RedeemMode redeemMode
    ) external returns (address token, address pool);

    function getLaunch(address token) external view returns (Launch memory);
    function isLaunch(address token) external view returns (bool);
    function getLaunchCount() external view returns (uint256);
    function getPool(address token) external view returns (address);
    function getCreatorTokens(address creator) external view returns (address[] memory);
    function getCreatorTokenCount(address creator) external view returns (uint256);
}

interface IMindstateVault {
    struct Position {
        uint256[3] tokenIds;
        address creator;
        address pool;
        uint256 totalWethCollected;
        uint256 totalTokenCollected;
    }

    event PositionsRegistered(address indexed token, address indexed creator, address indexed pool, uint256[3] tokenIds);
    event FeesCollected(address indexed token, uint256 wethAmount, uint256 tokenAmount);
    event FeesDistributed(address indexed token, uint256 creatorShare, uint256 burnShare, uint256 platformShare);

    /// @notice Register 3 LP positions for a launched token (called by factory)
    function registerPositions(address token, uint256[3] calldata tokenIds, address creator, address pool) external;

    /// @notice Collect and distribute accumulated fees from all 3 bands
    function collectFees(address token) external;

    /// @notice Get position info for a launched token
    function getPosition(address token) external view returns (Position memory);

    /// @notice Get all 3 V3 LP NFT token IDs for a launched token
    function getTokenIds(address token) external view returns (uint256[3] memory);
}

interface IFeeCollector {
    event FeesReceived(address indexed token, uint256 amount);
    event FeesWithdrawn(address indexed token, address indexed to, uint256 amount);

    function setAuthorizedSource(address source, bool authorized) external;
    function receiveFees(address token, uint256 amount) external;
    function withdraw(address token, address to, uint256 amount) external;
    function withdrawAll(address token, address to) external;
    function getBalance(address token) external view returns (uint256);
}
