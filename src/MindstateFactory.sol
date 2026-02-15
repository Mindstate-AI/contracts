// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MindstateToken} from "./MindstateToken.sol";
import {IMindstate} from "./interfaces/IMindstate.sol";

/**
 * @title MindstateFactory
 * @notice Deploys new Mindstate token instances using EIP-1167 minimal proxy clones.
 *
 *         Each clone delegates to a canonical MindstateToken implementation, reducing
 *         deployment gas from ~2M to ~100K. The factory also maintains an on-chain
 *         registry of all deployments for indexing and discovery.
 */
contract MindstateFactory {
    using Clones for address;

    // -----------------------------------------------------------------------
    //  State
    // -----------------------------------------------------------------------

    /// @notice Address of the canonical MindstateToken implementation contract.
    address public immutable IMPLEMENTATION;

    /// @dev All tokens deployed through this factory, in order.
    address[] private _deployments;

    /// @dev publisher address => list of tokens they created.
    mapping(address => address[]) private _publisherTokens;

    // -----------------------------------------------------------------------
    //  Events
    // -----------------------------------------------------------------------

    /// @notice Emitted when a new Mindstate token is created via this factory.
    event MindstateCreated(
        address indexed token,
        address indexed publisher,
        string  name,
        string  symbol,
        uint256 totalSupply,
        uint256 redeemCost,
        IMindstate.RedeemMode redeemMode
    );

    // -----------------------------------------------------------------------
    //  Constructor
    // -----------------------------------------------------------------------

    /**
     * @param implementation_ Address of a deployed MindstateToken to use as the
     *                        implementation for all clones. Must not be address(0).
     */
    constructor(address implementation_) {
        require(implementation_ != address(0), "MindstateFactory: zero implementation");
        IMPLEMENTATION = implementation_;
    }

    // -----------------------------------------------------------------------
    //  Factory
    // -----------------------------------------------------------------------

    /**
     * @notice Creates a new Mindstate token as an EIP-1167 minimal proxy clone.
     *         The caller becomes the publisher of the new token.
     *
     * @param name        ERC-20 token name (e.g. "Agent Alpha Access").
     * @param symbol      ERC-20 token symbol (e.g. "ALPHA").
     * @param totalSupply Total supply minted to the publisher (caller).
     * @param redeemCost  Number of tokens burned per redemption.
     * @param redeemMode  Redemption mode: PerCheckpoint (0) or Universal (1).
     * @return token      Address of the newly created Mindstate token.
     */
    function create(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        uint256 redeemCost,
        IMindstate.RedeemMode redeemMode
    ) external returns (address token) {
        token = IMPLEMENTATION.clone();
        MindstateToken(token).initialize(
            msg.sender, name, symbol, totalSupply, redeemCost, redeemMode
        );

        _deployments.push(token);
        _publisherTokens[msg.sender].push(token);

        emit MindstateCreated(token, msg.sender, name, symbol, totalSupply, redeemCost, redeemMode);
    }

    /**
     * @notice Creates a new Mindstate token at a deterministic address using CREATE2.
     *         Useful when the token address needs to be known before deployment.
     *
     * @param name        ERC-20 token name.
     * @param symbol      ERC-20 token symbol.
     * @param totalSupply Total supply minted to the publisher (caller).
     * @param redeemCost  Number of tokens burned per redemption.
     * @param redeemMode  Redemption mode: PerCheckpoint (0) or Universal (1).
     * @param salt        Salt for deterministic address derivation.
     * @return token      Address of the newly created Mindstate token.
     */
    function createDeterministic(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        uint256 redeemCost,
        IMindstate.RedeemMode redeemMode,
        bytes32 salt
    ) external returns (address token) {
        token = IMPLEMENTATION.cloneDeterministic(salt);
        MindstateToken(token).initialize(
            msg.sender, name, symbol, totalSupply, redeemCost, redeemMode
        );

        _deployments.push(token);
        _publisherTokens[msg.sender].push(token);

        emit MindstateCreated(token, msg.sender, name, symbol, totalSupply, redeemCost, redeemMode);
    }

    /**
     * @notice Predicts the address of a deterministic clone before deployment.
     * @param salt The salt that will be used for createDeterministic.
     * @return predicted The address the clone would be deployed to.
     */
    function predictDeterministicAddress(bytes32 salt) external view returns (address predicted) {
        return IMPLEMENTATION.predictDeterministicAddress(salt);
    }

    // -----------------------------------------------------------------------
    //  Registry Queries
    // -----------------------------------------------------------------------

    /// @notice Returns the total number of Mindstate tokens deployed through this factory.
    function deploymentCount() external view returns (uint256) {
        return _deployments.length;
    }

    /// @notice Returns the token address at a given deployment index.
    function getDeployment(uint256 index) external view returns (address) {
        return _deployments[index];
    }

    /// @notice Returns all tokens created by a specific publisher.
    function getPublisherTokens(address publisherAddr) external view returns (address[] memory) {
        return _publisherTokens[publisherAddr];
    }
}
