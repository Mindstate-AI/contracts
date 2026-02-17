// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title FeeCollector
/// @notice Collects and manages platform fees from the Mindstate launchpad.
/// @dev Fees accumulate here from trading activity and can be withdrawn by the owner.
contract FeeCollector is Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice Track total fees collected per token
    mapping(address => uint256) public totalFeesCollected;

    /// @notice Track total fees withdrawn per token
    mapping(address => uint256) public totalFeesWithdrawn;

    /// @notice Authorized fee sources (e.g. MindstateHook)
    mapping(address => bool) public authorizedSources;

    // ============ Events ============

    event FeesReceived(address indexed token, uint256 amount);
    event FeesWithdrawn(address indexed token, address indexed to, uint256 amount);
    event AuthorizedSourceUpdated(address indexed source, bool authorized);

    // ============ Constructor ============

    constructor(address _owner) Ownable(_owner) {}

    // ============ Admin ============

    /// @notice Set authorized fee source
    /// @param source Address of the fee source (e.g. MindstateHook)
    /// @param authorized Whether the source is authorized
    function setAuthorizedSource(address source, bool authorized) external onlyOwner {
        require(source != address(0), "Invalid source");
        authorizedSources[source] = authorized;
        emit AuthorizedSourceUpdated(source, authorized);
    }

    /// @notice Receive fees (called by authorized sources only)
    /// @param token The token address
    /// @param amount Amount of fees received
    function receiveFees(address token, uint256 amount) external {
        require(authorizedSources[msg.sender], "Not authorized");
        totalFeesCollected[token] += amount;
        emit FeesReceived(token, amount);
    }

    // ============ Withdrawals ============

    /// @notice Withdraw a specific amount of fees
    /// @param token Token to withdraw
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be > 0");

        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= amount, "Insufficient balance");

        totalFeesWithdrawn[token] += amount;
        IERC20(token).safeTransfer(to, amount);

        emit FeesWithdrawn(token, to, amount);
    }

    /// @notice Withdraw all fees for a token
    /// @param token Token to withdraw
    /// @param to Recipient address
    function withdrawAll(address token, address to) external onlyOwner {
        require(to != address(0), "Invalid recipient");

        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No balance");

        totalFeesWithdrawn[token] += balance;
        IERC20(token).safeTransfer(to, balance);

        emit FeesWithdrawn(token, to, balance);
    }

    // ============ Views ============

    /// @notice Get current fee balance for a token
    function getBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Emergency rescue for stuck tokens
    function emergencyRescue(address token, address to) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(to, balance);
        }
    }
}
