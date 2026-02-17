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
 *         - Consumers burn tokens to redeem access (burn-to-redeem model).
 *         - The chain stores commitments, pointers, and redemption records.
 *           Secrets never go on-chain.
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

    /// @dev Redemption mode (packed with _publisher in the same storage slot).
    RedeemMode private _redeemMode;

    /// @dev Number of tokens burned per redemption.
    uint256 private _redeemCost;

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

    /// @dev On-chain key envelope storage: consumer => checkpointId => envelope data.
    struct StoredKeyEnvelope {
        bytes   wrappedKey;       // K encrypted via NaCl box (~48 bytes)
        bytes24 nonce;            // NaCl box nonce (24 bytes)
        bytes32 senderPublicKey;  // Publisher's X25519 public key (32 bytes)
    }
    mapping(address => mapping(bytes32 => StoredKeyEnvelope)) private _keyEnvelopes;

    /// @dev Universal redemptions: address => has redeemed universally.
    mapping(address => bool) private _universalRedemptions;

    /// @dev Per-checkpoint redemptions: address => checkpointId => has redeemed.
    mapping(address => mapping(bytes32 => bool)) private _checkpointRedemptions;

    /// @dev Tag name => checkpoint ID.
    mapping(string => bytes32) private _tags;

    /// @dev Checkpoint ID => tag name.
    mapping(bytes32 => string) private _checkpointTags;

    // -----------------------------------------------------------------------
    //  Modifiers
    // -----------------------------------------------------------------------

    modifier onlyPublisher() {
        _checkPublisher();
        _;
    }

    function _checkPublisher() private view {
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
     * @param redeemCost_  Number of tokens burned per redemption. A value of 0 is
     *                     valid and allows free redemption (no tokens burned).
     * @param redeemMode_  Redemption mode: PerCheckpoint (0) or Universal (1).
     */
    function initialize(
        address publisher_,
        string calldata name_,
        string calldata symbol_,
        uint256 totalSupply_,
        uint256 redeemCost_,
        RedeemMode redeemMode_
    ) external initializer {
        require(publisher_ != address(0), "Mindstate: publisher is zero address");

        __ERC20_init(name_, symbol_);

        _publisher = publisher_;
        _redeemMode = redeemMode_;
        _redeemCost = redeemCost_;

        if (totalSupply_ > 0) {
            _mint(publisher_, totalSupply_);
        }
    }

    /**
     * @notice Initializes the Mindstate token for launchpad deployment.
     *         Identical to initialize(), but mints supply to a specified recipient
     *         (e.g. a virtual AMM hook) instead of the publisher. The publisher
     *         retains exclusive checkpoint authority.
     *
     * @param publisher_   Address of the initial publisher (checkpoint authority).
     * @param mintTo_      Address to receive the minted supply (e.g. hook address).
     * @param name_        ERC-20 token name.
     * @param symbol_      ERC-20 token symbol.
     * @param totalSupply_ Total supply minted to mintTo_.
     * @param redeemCost_  Number of tokens burned per redemption. A value of 0 is
     *                     valid and allows free redemption (no tokens burned).
     * @param redeemMode_  Redemption mode: PerCheckpoint (0) or Universal (1).
     */
    function initializeForLaunch(
        address publisher_,
        address mintTo_,
        string calldata name_,
        string calldata symbol_,
        uint256 totalSupply_,
        uint256 redeemCost_,
        RedeemMode redeemMode_
    ) external initializer {
        require(publisher_ != address(0), "Mindstate: publisher is zero address");
        require(mintTo_ != address(0), "Mindstate: mintTo is zero address");

        __ERC20_init(name_, symbol_);

        _publisher = publisher_;
        _redeemMode = redeemMode_;
        _redeemCost = redeemCost_;

        if (totalSupply_ > 0) {
            _mint(mintTo_, totalSupply_);
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
        bytes32 manifestHash,
        string calldata label
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

        // Auto-tag if label is non-empty
        if (bytes(label).length > 0) {
            _setTag(checkpointId, label);
        }
    }

    // -----------------------------------------------------------------------
    //  Storage Migration
    // -----------------------------------------------------------------------

    /// @inheritdoc IMindstate
    function updateCiphertextUri(
        bytes32 checkpointId,
        string calldata newCiphertextUri
    ) external override onlyPublisher {
        require(
            _checkpoints[checkpointId].publishedAt != 0,
            "Mindstate: checkpoint does not exist"
        );
        require(bytes(newCiphertextUri).length > 0, "Mindstate: URI must not be empty");

        string memory oldUri = _checkpoints[checkpointId].ciphertextUri;
        _checkpoints[checkpointId].ciphertextUri = newCiphertextUri;

        emit CiphertextUriUpdated(checkpointId, oldUri, newCiphertextUri);
    }

    // -----------------------------------------------------------------------
    //  Tags
    // -----------------------------------------------------------------------

    /// @inheritdoc IMindstate
    function tagCheckpoint(bytes32 checkpointId, string calldata tag) external override onlyPublisher {
        require(
            _checkpoints[checkpointId].publishedAt != 0,
            "Mindstate: checkpoint does not exist"
        );
        require(bytes(tag).length > 0, "Mindstate: tag must not be empty");

        _setTag(checkpointId, tag);
    }

    /// @inheritdoc IMindstate
    function resolveTag(string calldata tag) external view override returns (bytes32) {
        return _tags[tag];
    }

    /// @inheritdoc IMindstate
    function getCheckpointTag(bytes32 checkpointId) external view override returns (string memory) {
        return _checkpointTags[checkpointId];
    }

    /**
     * @dev Internal helper to assign a tag to a checkpoint.
     *      Handles clearing the old tag if the checkpoint already had one,
     *      and clearing the old checkpoint if the tag was previously assigned elsewhere.
     */
    function _setTag(bytes32 checkpointId, string memory tag) internal {
        // If this tag was previously assigned to another checkpoint, clear the reverse lookup
        bytes32 oldCheckpoint = _tags[tag];
        if (oldCheckpoint != bytes32(0)) {
            delete _checkpointTags[oldCheckpoint];
        }

        // If this checkpoint previously had a different tag, clear the forward lookup
        string memory oldTag = _checkpointTags[checkpointId];
        if (bytes(oldTag).length > 0) {
            delete _tags[oldTag];
        }

        // Set both directions
        _tags[tag] = checkpointId;
        _checkpointTags[checkpointId] = tag;

        emit CheckpointTagged(checkpointId, tag);
    }

    // -----------------------------------------------------------------------
    //  Redemption (Burn-to-Access)
    // -----------------------------------------------------------------------

    /// @inheritdoc IMindstate
    function redeemMode() external view override returns (RedeemMode) {
        return _redeemMode;
    }

    /// @inheritdoc IMindstate
    function redeemCost() external view override returns (uint256) {
        return _redeemCost;
    }

    /// @inheritdoc IMindstate
    function redeem(bytes32 checkpointId) external override {
        if (_redeemMode == RedeemMode.Universal) {
            require(!_universalRedemptions[msg.sender], "Mindstate: already redeemed");

            _burn(msg.sender, _redeemCost);
            _universalRedemptions[msg.sender] = true;

            emit Redeemed(msg.sender, bytes32(0), _redeemCost);
        } else {
            require(
                _checkpoints[checkpointId].publishedAt != 0,
                "Mindstate: checkpoint does not exist"
            );
            require(
                !_checkpointRedemptions[msg.sender][checkpointId],
                "Mindstate: already redeemed for this checkpoint"
            );

            _burn(msg.sender, _redeemCost);
            _checkpointRedemptions[msg.sender][checkpointId] = true;

            emit Redeemed(msg.sender, checkpointId, _redeemCost);
        }
    }

    /// @inheritdoc IMindstate
    function hasRedeemed(address account, bytes32 checkpointId) external view override returns (bool) {
        if (_redeemMode == RedeemMode.Universal) {
            return _universalRedemptions[account];
        } else {
            return _checkpointRedemptions[account][checkpointId];
        }
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

    // -----------------------------------------------------------------------
    //  On-Chain Key Envelope Delivery
    // -----------------------------------------------------------------------

    /// @inheritdoc IMindstate
    function deliverKeyEnvelope(
        address consumer,
        bytes32 checkpointId,
        bytes calldata wrappedKey,
        bytes24 nonce,
        bytes32 senderPublicKey
    ) external override onlyPublisher {
        require(wrappedKey.length > 0, "Mindstate: empty wrapped key");
        require(wrappedKey.length <= 128, "Mindstate: wrappedKey too large");
        require(senderPublicKey != bytes32(0), "Mindstate: empty sender public key");
        require(
            _checkpoints[checkpointId].publishedAt != 0,
            "Mindstate: checkpoint does not exist"
        );
        require(
            _keyEnvelopes[consumer][checkpointId].wrappedKey.length == 0,
            "Mindstate: key envelope already delivered"
        );

        // Verify consumer has redeemed access
        if (_redeemMode == RedeemMode.Universal) {
            require(
                _universalRedemptions[consumer],
                "Mindstate: consumer has not redeemed"
            );
        } else {
            require(
                _checkpointRedemptions[consumer][checkpointId],
                "Mindstate: consumer has not redeemed this checkpoint"
            );
        }

        _keyEnvelopes[consumer][checkpointId] = StoredKeyEnvelope({
            wrappedKey: wrappedKey,
            nonce: nonce,
            senderPublicKey: senderPublicKey
        });

        emit KeyEnvelopeDelivered(consumer, checkpointId, wrappedKey, nonce, senderPublicKey);
    }

    /// @inheritdoc IMindstate
    function getKeyEnvelope(
        address consumer,
        bytes32 checkpointId
    ) external view override returns (bytes memory wrappedKey, bytes24 nonce, bytes32 senderPublicKey) {
        StoredKeyEnvelope storage env = _keyEnvelopes[consumer][checkpointId];
        return (env.wrappedKey, env.nonce, env.senderPublicKey);
    }

    /// @inheritdoc IMindstate
    function hasKeyEnvelope(
        address consumer,
        bytes32 checkpointId
    ) external view override returns (bool) {
        return _keyEnvelopes[consumer][checkpointId].wrappedKey.length > 0;
    }
}
