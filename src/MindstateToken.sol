// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IMindstate} from "./interfaces/IMindstate.sol";

/**
 * @title MindstateToken
 * @notice Reference implementation of the Mindstate standard.
 *
 *         Each instance represents a single capsule stream backed by an ERC-20 token.
 *         - The publisher has exclusive authority to append checkpoints.
 *         - Token balances represent access entitlement, not authorship.
 *         - The chain stores commitments and pointers. Secrets never go on-chain.
 *
 *         Designed for deployment via EIP-1167 minimal proxy clones (see MindstateFactory).
 *         Uses OpenZeppelin's Initializable + ERC20Upgradeable for the clone-compatible
 *         initialization pattern.
 */
contract MindstateToken is Initializable, ERC20Upgradeable, IMindstate {
    // -----------------------------------------------------------------------
    //  Storage
    // -----------------------------------------------------------------------

    /// @dev Address with exclusive publishing authority.
    address private _publisher;

    /// @dev Minimum token balance required for consumption access.
    uint256 private _minBalance;

    /// @dev Content-derived ID of the most recent checkpoint.
    bytes32 private _head;

    /// @dev Total number of published checkpoints.
    uint256 private _checkpointCount;

    /// @dev checkpointId => Checkpoint metadata.
    mapping(bytes32 => Checkpoint) private _checkpoints;

    /// @dev Sequential index => checkpointId, for enumeration.
    bytes32[] private _checkpointIds;

    /// @dev address => registered X25519 encryption public key.
    mapping(address => bytes32) private _encryptionKeys;

    // -----------------------------------------------------------------------
    //  Modifiers
    // -----------------------------------------------------------------------

    modifier onlyPublisher() {
        _checkPublisher();
        _;
    }

    function _checkPublisher() internal view {
        require(msg.sender == _publisher, "Mindstate: caller is not the publisher");
    }

    // -----------------------------------------------------------------------
    //  Constructor (disables initializers on the implementation contract)
    // -----------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // -----------------------------------------------------------------------
    //  Initialization
    // -----------------------------------------------------------------------

    /**
     * @notice Initializes the Mindstate token. Called once after clone deployment.
     * @param publisher_   Address of the initial publisher.
     * @param name_        ERC-20 token name (e.g. "Agent Alpha Access").
     * @param symbol_      ERC-20 token symbol (e.g. "ALPHA").
     * @param totalSupply_ Total supply minted to the publisher.
     * @param minBalance_  Minimum balance for consumption access.
     */
    function initialize(
        address publisher_,
        string calldata name_,
        string calldata symbol_,
        uint256 totalSupply_,
        uint256 minBalance_
    ) external initializer {
        require(publisher_ != address(0), "Mindstate: publisher is zero address");

        __ERC20_init(name_, symbol_);

        _publisher = publisher_;
        _minBalance = minBalance_;

        if (totalSupply_ > 0) {
            _mint(publisher_, totalSupply_);
        }
    }

    // -----------------------------------------------------------------------
    //  Publisher
    // -----------------------------------------------------------------------

    /// @inheritdoc IMindstate
    function publisher() external view override returns (address) {
        return _publisher;
    }

    /// @inheritdoc IMindstate
    function transferPublisher(address newPublisher) external override onlyPublisher {
        require(newPublisher != address(0), "Mindstate: new publisher is zero address");
        address previous = _publisher;
        _publisher = newPublisher;
        emit PublisherTransferred(previous, newPublisher);
    }

    // -----------------------------------------------------------------------
    //  Checkpoint Chain
    // -----------------------------------------------------------------------

    /// @inheritdoc IMindstate
    function head() external view override returns (bytes32) {
        return _head;
    }

    /// @inheritdoc IMindstate
    function checkpointCount() external view override returns (uint256) {
        return _checkpointCount;
    }

    /// @inheritdoc IMindstate
    function getCheckpoint(bytes32 checkpointId) external view override returns (Checkpoint memory) {
        return _checkpoints[checkpointId];
    }

    /// @inheritdoc IMindstate
    function getCheckpointIdAtIndex(uint256 index) external view override returns (bytes32) {
        require(index < _checkpointCount, "Mindstate: index out of bounds");
        return _checkpointIds[index];
    }

    // -----------------------------------------------------------------------
    //  Publishing
    // -----------------------------------------------------------------------

    /// @inheritdoc IMindstate
    function publish(
        bytes32 stateCommitment,
        bytes32 ciphertextHash,
        string calldata ciphertextUri,
        bytes32 manifestHash
    ) external override onlyPublisher returns (bytes32 checkpointId) {
        // Cache the current head as predecessor before any mutations
        bytes32 predecessorId = _head;

        // Derive a content-addressed checkpoint ID
        checkpointId = keccak256(
            abi.encodePacked(
                predecessorId,
                stateCommitment,
                ciphertextHash,
                manifestHash,
                block.timestamp,
                block.number
            )
        );

        // Defensive: prevent ID collision (astronomically unlikely)
        require(
            _checkpoints[checkpointId].publishedAt == 0,
            "Mindstate: checkpoint ID collision"
        );

        // Store checkpoint metadata
        _checkpoints[checkpointId] = Checkpoint({
            predecessorId:   predecessorId,
            stateCommitment: stateCommitment,
            ciphertextHash:  ciphertextHash,
            ciphertextUri:   ciphertextUri,
            manifestHash:    manifestHash,
            publishedAt:     uint64(block.timestamp),
            blockNumber:     uint64(block.number)
        });

        // Update sequential index and head pointer
        uint256 index = _checkpointCount;
        _checkpointIds.push(checkpointId);
        _checkpointCount = index + 1;
        _head = checkpointId;

        emit CheckpointPublished(
            checkpointId,
            predecessorId,
            index,
            stateCommitment,
            ciphertextHash,
            ciphertextUri,
            manifestHash,
            uint64(block.timestamp),
            uint64(block.number)
        );
    }

    // -----------------------------------------------------------------------
    //  Access Control
    // -----------------------------------------------------------------------

    /// @inheritdoc IMindstate
    function minBalance() external view override returns (uint256) {
        return _minBalance;
    }

    /// @inheritdoc IMindstate
    function hasAccess(address account) external view override returns (bool) {
        return balanceOf(account) >= _minBalance;
    }

    // -----------------------------------------------------------------------
    //  Encryption Key Registry
    // -----------------------------------------------------------------------

    /// @inheritdoc IMindstate
    function registerEncryptionKey(bytes32 encryptionPublicKey) external override {
        require(encryptionPublicKey != bytes32(0), "Mindstate: empty encryption key");
        _encryptionKeys[msg.sender] = encryptionPublicKey;
        emit EncryptionKeyRegistered(msg.sender, encryptionPublicKey);
    }

    /// @inheritdoc IMindstate
    function getEncryptionKey(address account) external view override returns (bytes32) {
        return _encryptionKeys[account];
    }
}
