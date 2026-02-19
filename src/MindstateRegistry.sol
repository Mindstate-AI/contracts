// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMindstateRegistry} from "./interfaces/IMindstateRegistry.sol";

/**
 * @title MindstateRegistry
 * @notice Standalone checkpoint ledger for encrypted AI state — no ERC-20, no
 *         token supply, no burn-to-redeem.
 *
 *         A single deployment hosts multiple independent streams. Each stream has
 *         its own publisher, checkpoint chain, tag namespace, and access control.
 *
 *         This contract offers the same cryptographic guarantees as the tokenized
 *         MindstateToken (ERC-3251): append-only immutable checkpoints, content-
 *         derived IDs, hash-linked lineage, on-chain commitments, encryption key
 *         registry, and optional on-chain key envelope delivery.
 *
 *         What it removes: ERC-20 token, supply management, burn-to-redeem, and
 *         all DeFi surface area. Access control is a simple publisher-managed
 *         allowlist (or fully open).
 *
 *         Designed as a singleton — deploy once, create unlimited streams.
 */
contract MindstateRegistry is IMindstateRegistry {
    // -----------------------------------------------------------------------
    //  Storage
    // -----------------------------------------------------------------------

    struct StreamState {
        address publisher;
        AccessMode accessMode;
        bytes32 head;
        uint256 checkpointCount;
        string  name;
        bytes32[] checkpointIds;
        mapping(bytes32 => Checkpoint) checkpoints;
        mapping(string => bytes32) tags;
        mapping(bytes32 => string) checkpointTags;
        mapping(address => bool) readers;
    }

    /// @dev streamId => stream state.
    mapping(bytes32 => StreamState) private _streams;

    /// @dev All stream IDs in creation order.
    bytes32[] private _streamIds;

    /// @dev publisher => list of their stream IDs.
    mapping(address => bytes32[]) private _publisherStreams;

    /// @dev Global nonce for deterministic stream ID derivation.
    uint256 private _nonce;

    /// @dev Global encryption key registry (shared across all streams).
    mapping(address => bytes32) private _encryptionKeys;

    /// @dev On-chain key envelope storage: streamId => consumer => checkpointId => envelope.
    struct StoredKeyEnvelope {
        bytes   wrappedKey;
        bytes24 nonce;
        bytes32 senderPublicKey;
    }
    mapping(bytes32 => mapping(address => mapping(bytes32 => StoredKeyEnvelope))) private _keyEnvelopes;

    // -----------------------------------------------------------------------
    //  Modifiers
    // -----------------------------------------------------------------------

    modifier onlyStreamPublisher(bytes32 streamId) {
        require(
            msg.sender == _streams[streamId].publisher,
            "MindstateRegistry: caller is not the stream publisher"
        );
        _;
    }

    modifier streamExists(bytes32 streamId) {
        require(
            _streams[streamId].publisher != address(0),
            "MindstateRegistry: stream does not exist"
        );
        _;
    }

    // -----------------------------------------------------------------------
    //  Stream Management
    // -----------------------------------------------------------------------

    /// @inheritdoc IMindstateRegistry
    function createStream(
        string calldata name,
        AccessMode accessMode
    ) external returns (bytes32 streamId) {
        streamId = keccak256(
            abi.encodePacked(msg.sender, block.chainid, _nonce++)
        );

        StreamState storage s = _streams[streamId];
        require(s.publisher == address(0), "MindstateRegistry: stream ID collision");

        s.publisher = msg.sender;
        s.accessMode = accessMode;
        s.name = name;

        _streamIds.push(streamId);
        _publisherStreams[msg.sender].push(streamId);

        emit StreamCreated(streamId, msg.sender, name, accessMode);
    }

    /// @inheritdoc IMindstateRegistry
    function getStream(bytes32 streamId) external view returns (StreamInfo memory) {
        StreamState storage s = _streams[streamId];
        return StreamInfo({
            publisher: s.publisher,
            accessMode: s.accessMode,
            head: s.head,
            checkpointCount: s.checkpointCount,
            name: s.name
        });
    }

    /// @inheritdoc IMindstateRegistry
    function streamCount() external view returns (uint256) {
        return _streamIds.length;
    }

    /// @inheritdoc IMindstateRegistry
    function getStreamIdAtIndex(uint256 index) external view returns (bytes32) {
        require(index < _streamIds.length, "MindstateRegistry: index out of bounds");
        return _streamIds[index];
    }

    /// @inheritdoc IMindstateRegistry
    function getPublisherStreams(address publisher_) external view returns (bytes32[] memory) {
        return _publisherStreams[publisher_];
    }

    /// @inheritdoc IMindstateRegistry
    function transferPublisher(
        bytes32 streamId,
        address newPublisher
    ) external streamExists(streamId) onlyStreamPublisher(streamId) {
        require(newPublisher != address(0), "MindstateRegistry: new publisher is zero address");
        address previous = _streams[streamId].publisher;
        _streams[streamId].publisher = newPublisher;
        _publisherStreams[newPublisher].push(streamId);
        emit PublisherTransferred(streamId, previous, newPublisher);
    }

    // -----------------------------------------------------------------------
    //  Checkpoint Chain
    // -----------------------------------------------------------------------

    /// @inheritdoc IMindstateRegistry
    function head(bytes32 streamId) external view returns (bytes32) {
        return _streams[streamId].head;
    }

    /// @inheritdoc IMindstateRegistry
    function checkpointCount(bytes32 streamId) external view returns (uint256) {
        return _streams[streamId].checkpointCount;
    }

    /// @inheritdoc IMindstateRegistry
    function getCheckpoint(
        bytes32 streamId,
        bytes32 checkpointId
    ) external view returns (Checkpoint memory) {
        return _streams[streamId].checkpoints[checkpointId];
    }

    /// @inheritdoc IMindstateRegistry
    function getCheckpointIdAtIndex(
        bytes32 streamId,
        uint256 index
    ) external view returns (bytes32) {
        require(
            index < _streams[streamId].checkpointCount,
            "MindstateRegistry: index out of bounds"
        );
        return _streams[streamId].checkpointIds[index];
    }

    // -----------------------------------------------------------------------
    //  Publishing
    // -----------------------------------------------------------------------

    /// @inheritdoc IMindstateRegistry
    function publish(
        bytes32 streamId,
        bytes32 stateCommitment,
        bytes32 ciphertextHash,
        string calldata ciphertextUri,
        bytes32 manifestHash,
        string calldata label
    ) external streamExists(streamId) onlyStreamPublisher(streamId) returns (bytes32 checkpointId) {
        checkpointId = _appendCheckpoint(
            streamId, stateCommitment, ciphertextHash, ciphertextUri, manifestHash
        );

        if (bytes(label).length > 0) {
            _setTag(streamId, checkpointId, label);
        }
    }

    function _appendCheckpoint(
        bytes32 streamId,
        bytes32 stateCommitment,
        bytes32 ciphertextHash,
        string calldata ciphertextUri,
        bytes32 manifestHash
    ) internal returns (bytes32 checkpointId) {
        StreamState storage s = _streams[streamId];
        bytes32 predecessorId = s.head;

        checkpointId = keccak256(
            abi.encodePacked(
                streamId,
                predecessorId,
                stateCommitment,
                ciphertextHash,
                manifestHash,
                block.timestamp,
                block.number
            )
        );

        require(
            s.checkpoints[checkpointId].publishedAt == 0,
            "MindstateRegistry: checkpoint ID collision"
        );

        s.checkpoints[checkpointId] = Checkpoint({
            predecessorId:   predecessorId,
            stateCommitment: stateCommitment,
            ciphertextHash:  ciphertextHash,
            ciphertextUri:   ciphertextUri,
            manifestHash:    manifestHash,
            publishedAt:     uint64(block.timestamp),
            blockNumber:     uint64(block.number)
        });

        uint256 index = s.checkpointCount;
        s.checkpointIds.push(checkpointId);
        s.checkpointCount = index + 1;
        s.head = checkpointId;

        emit CheckpointPublished(
            streamId,
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
    //  Storage Migration
    // -----------------------------------------------------------------------

    /// @inheritdoc IMindstateRegistry
    function updateCiphertextUri(
        bytes32 streamId,
        bytes32 checkpointId,
        string calldata newCiphertextUri
    ) external streamExists(streamId) onlyStreamPublisher(streamId) {
        StreamState storage s = _streams[streamId];
        require(
            s.checkpoints[checkpointId].publishedAt != 0,
            "MindstateRegistry: checkpoint does not exist"
        );
        require(bytes(newCiphertextUri).length > 0, "MindstateRegistry: URI must not be empty");

        string memory oldUri = s.checkpoints[checkpointId].ciphertextUri;
        s.checkpoints[checkpointId].ciphertextUri = newCiphertextUri;

        emit CiphertextUriUpdated(streamId, checkpointId, oldUri, newCiphertextUri);
    }

    // -----------------------------------------------------------------------
    //  Tags
    // -----------------------------------------------------------------------

    /// @inheritdoc IMindstateRegistry
    function tagCheckpoint(
        bytes32 streamId,
        bytes32 checkpointId,
        string calldata tag
    ) external streamExists(streamId) onlyStreamPublisher(streamId) {
        require(
            _streams[streamId].checkpoints[checkpointId].publishedAt != 0,
            "MindstateRegistry: checkpoint does not exist"
        );
        require(bytes(tag).length > 0, "MindstateRegistry: tag must not be empty");
        _setTag(streamId, checkpointId, tag);
    }

    /// @inheritdoc IMindstateRegistry
    function resolveTag(bytes32 streamId, string calldata tag) external view returns (bytes32) {
        return _streams[streamId].tags[tag];
    }

    /// @inheritdoc IMindstateRegistry
    function getCheckpointTag(
        bytes32 streamId,
        bytes32 checkpointId
    ) external view returns (string memory) {
        return _streams[streamId].checkpointTags[checkpointId];
    }

    function _setTag(bytes32 streamId, bytes32 checkpointId, string memory tag) internal {
        StreamState storage s = _streams[streamId];

        bytes32 oldCheckpoint = s.tags[tag];
        if (oldCheckpoint != bytes32(0)) {
            delete s.checkpointTags[oldCheckpoint];
        }

        string memory oldTag = s.checkpointTags[checkpointId];
        if (bytes(oldTag).length > 0) {
            delete s.tags[oldTag];
        }

        s.tags[tag] = checkpointId;
        s.checkpointTags[checkpointId] = tag;

        emit CheckpointTagged(streamId, checkpointId, tag);
    }

    // -----------------------------------------------------------------------
    //  Access Control (Allowlist)
    // -----------------------------------------------------------------------

    /// @inheritdoc IMindstateRegistry
    function addReader(
        bytes32 streamId,
        address reader
    ) external streamExists(streamId) onlyStreamPublisher(streamId) {
        require(reader != address(0), "MindstateRegistry: reader is zero address");
        _streams[streamId].readers[reader] = true;
        emit ReaderAdded(streamId, reader);
    }

    /// @inheritdoc IMindstateRegistry
    function removeReader(
        bytes32 streamId,
        address reader
    ) external streamExists(streamId) onlyStreamPublisher(streamId) {
        _streams[streamId].readers[reader] = false;
        emit ReaderRemoved(streamId, reader);
    }

    /// @inheritdoc IMindstateRegistry
    function addReaders(
        bytes32 streamId,
        address[] calldata readers
    ) external streamExists(streamId) onlyStreamPublisher(streamId) {
        for (uint256 i = 0; i < readers.length; i++) {
            require(readers[i] != address(0), "MindstateRegistry: reader is zero address");
            _streams[streamId].readers[readers[i]] = true;
            emit ReaderAdded(streamId, readers[i]);
        }
    }

    /// @inheritdoc IMindstateRegistry
    function isReader(bytes32 streamId, address account) external view returns (bool) {
        StreamState storage s = _streams[streamId];
        if (s.accessMode == AccessMode.Open) return true;
        if (account == s.publisher) return true;
        return s.readers[account];
    }

    // -----------------------------------------------------------------------
    //  Encryption Key Registry (Global)
    // -----------------------------------------------------------------------

    /// @inheritdoc IMindstateRegistry
    function registerEncryptionKey(bytes32 encryptionPublicKey) external {
        require(encryptionPublicKey != bytes32(0), "MindstateRegistry: empty encryption key");
        _encryptionKeys[msg.sender] = encryptionPublicKey;
        emit EncryptionKeyRegistered(msg.sender, encryptionPublicKey);
    }

    /// @inheritdoc IMindstateRegistry
    function getEncryptionKey(address account) external view returns (bytes32) {
        return _encryptionKeys[account];
    }

    // -----------------------------------------------------------------------
    //  On-Chain Key Envelope Delivery
    // -----------------------------------------------------------------------

    /// @inheritdoc IMindstateRegistry
    function deliverKeyEnvelope(
        bytes32 streamId,
        address consumer,
        bytes32 checkpointId,
        bytes calldata wrappedKey,
        bytes24 nonce,
        bytes32 senderPublicKey
    ) external streamExists(streamId) onlyStreamPublisher(streamId) {
        require(wrappedKey.length > 0, "MindstateRegistry: empty wrapped key");
        require(wrappedKey.length <= 128, "MindstateRegistry: wrappedKey too large");
        require(senderPublicKey != bytes32(0), "MindstateRegistry: empty sender public key");
        require(
            _streams[streamId].checkpoints[checkpointId].publishedAt != 0,
            "MindstateRegistry: checkpoint does not exist"
        );
        require(
            _keyEnvelopes[streamId][consumer][checkpointId].wrappedKey.length == 0,
            "MindstateRegistry: key envelope already delivered"
        );

        // Enforce access control
        StreamState storage s = _streams[streamId];
        if (s.accessMode == AccessMode.Allowlist) {
            require(
                s.readers[consumer] || consumer == s.publisher,
                "MindstateRegistry: consumer is not an approved reader"
            );
        }

        _keyEnvelopes[streamId][consumer][checkpointId] = StoredKeyEnvelope({
            wrappedKey: wrappedKey,
            nonce: nonce,
            senderPublicKey: senderPublicKey
        });

        emit KeyEnvelopeDelivered(streamId, consumer, checkpointId, wrappedKey, nonce, senderPublicKey);
    }

    /// @inheritdoc IMindstateRegistry
    function getKeyEnvelope(
        bytes32 streamId,
        address consumer,
        bytes32 checkpointId
    ) external view returns (bytes memory wrappedKey, bytes24 nonce, bytes32 senderPublicKey) {
        StoredKeyEnvelope storage env = _keyEnvelopes[streamId][consumer][checkpointId];
        return (env.wrappedKey, env.nonce, env.senderPublicKey);
    }

    /// @inheritdoc IMindstateRegistry
    function hasKeyEnvelope(
        bytes32 streamId,
        address consumer,
        bytes32 checkpointId
    ) external view returns (bool) {
        return _keyEnvelopes[streamId][consumer][checkpointId].wrappedKey.length > 0;
    }
}
