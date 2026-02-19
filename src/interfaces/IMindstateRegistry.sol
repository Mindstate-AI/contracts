// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IMindstateRegistry
 * @notice Interface for the standalone Mindstate checkpoint registry — encrypted
 *         AI state published as a verifiable, time-ordered checkpoint stream
 *         WITHOUT an ERC-20 token or burn-to-redeem access model.
 *
 *         This contract provides the same cryptographic guarantees as the
 *         tokenized ERC-3251 path (append-only checkpoint chain, tamper-evident
 *         lineage, on-chain commitments, encryption key registry, optional
 *         on-chain key delivery) but replaces the token-based access layer with
 *         a simple publisher-managed allowlist.
 *
 *         Use this when you want verifiable encrypted state without markets.
 *
 *         Access tiers (configured per stream by the publisher):
 *           - Open:       Anyone can receive key envelopes.
 *           - Allowlist:  Only publisher-approved readers can receive key envelopes.
 */
interface IMindstateRegistry {
    // -----------------------------------------------------------------------
    //  Enums
    // -----------------------------------------------------------------------

    /// @notice Determines who can receive key envelopes for a stream.
    enum AccessMode {
        Open,       // Any address can be delivered a key envelope.
        Allowlist   // Only addresses on the publisher's allowlist.
    }

    // -----------------------------------------------------------------------
    //  Structs
    // -----------------------------------------------------------------------

    /// @notice On-chain record for a single published checkpoint.
    struct Checkpoint {
        bytes32 predecessorId;
        bytes32 stateCommitment;
        bytes32 ciphertextHash;
        string  ciphertextUri;
        bytes32 manifestHash;
        uint64  publishedAt;
        uint64  blockNumber;
    }

    /// @notice Metadata for a registered stream.
    struct StreamInfo {
        address publisher;
        AccessMode accessMode;
        bytes32 head;
        uint256 checkpointCount;
        string  name;
    }

    // -----------------------------------------------------------------------
    //  Events
    // -----------------------------------------------------------------------

    /// @notice Emitted when a new stream is created.
    event StreamCreated(
        bytes32 indexed streamId,
        address indexed publisher,
        string  name,
        AccessMode accessMode
    );

    /// @notice Emitted when a checkpoint is published.
    event CheckpointPublished(
        bytes32 indexed streamId,
        bytes32 indexed checkpointId,
        bytes32 indexed predecessorId,
        uint256 index,
        bytes32 stateCommitment,
        bytes32 ciphertextHash,
        string  ciphertextUri,
        bytes32 manifestHash,
        uint64  timestamp,
        uint64  blockNumber
    );

    /// @notice Emitted when a tag is assigned or reassigned.
    event CheckpointTagged(
        bytes32 indexed streamId,
        bytes32 indexed checkpointId,
        string  tag
    );

    /// @notice Emitted when a ciphertext URI is updated (storage migration).
    event CiphertextUriUpdated(
        bytes32 indexed streamId,
        bytes32 indexed checkpointId,
        string  oldUri,
        string  newUri
    );

    /// @notice Emitted when an encryption public key is registered.
    event EncryptionKeyRegistered(
        address indexed account,
        bytes32 encryptionKey
    );

    /// @notice Emitted when the publisher delivers a key envelope on-chain.
    event KeyEnvelopeDelivered(
        bytes32 indexed streamId,
        address indexed consumer,
        bytes32 indexed checkpointId,
        bytes   wrappedKey,
        bytes24 nonce,
        bytes32 senderPublicKey
    );

    /// @notice Emitted when a reader is added to a stream's allowlist.
    event ReaderAdded(bytes32 indexed streamId, address indexed reader);

    /// @notice Emitted when a reader is removed from a stream's allowlist.
    event ReaderRemoved(bytes32 indexed streamId, address indexed reader);

    /// @notice Emitted when publisher authority is transferred for a stream.
    event PublisherTransferred(
        bytes32 indexed streamId,
        address indexed previousPublisher,
        address indexed newPublisher
    );

    // -----------------------------------------------------------------------
    //  Stream Management
    // -----------------------------------------------------------------------

    /// @notice Creates a new checkpoint stream. The caller becomes the publisher.
    /// @param name       Human-readable stream name.
    /// @param accessMode Access model: Open (0) or Allowlist (1).
    /// @return streamId  Deterministic stream identifier.
    function createStream(
        string calldata name,
        AccessMode accessMode
    ) external returns (bytes32 streamId);

    /// @notice Returns the metadata for a stream.
    function getStream(bytes32 streamId) external view returns (StreamInfo memory);

    /// @notice Returns the total number of streams created.
    function streamCount() external view returns (uint256);

    /// @notice Returns the stream ID at a given index.
    function getStreamIdAtIndex(uint256 index) external view returns (bytes32);

    /// @notice Returns all stream IDs created by a publisher.
    function getPublisherStreams(address publisher_) external view returns (bytes32[] memory);

    /// @notice Transfers publisher authority for a stream.
    function transferPublisher(bytes32 streamId, address newPublisher) external;

    // -----------------------------------------------------------------------
    //  Checkpoint Chain
    // -----------------------------------------------------------------------

    /// @notice Returns the head checkpoint ID for a stream.
    function head(bytes32 streamId) external view returns (bytes32);

    /// @notice Returns the total number of checkpoints in a stream.
    function checkpointCount(bytes32 streamId) external view returns (uint256);

    /// @notice Returns checkpoint metadata.
    function getCheckpoint(bytes32 streamId, bytes32 checkpointId)
        external view returns (Checkpoint memory);

    /// @notice Returns the checkpoint ID at a sequential index within a stream.
    function getCheckpointIdAtIndex(bytes32 streamId, uint256 index)
        external view returns (bytes32);

    // -----------------------------------------------------------------------
    //  Publishing
    // -----------------------------------------------------------------------

    /// @notice Publishes a new checkpoint to a stream.
    function publish(
        bytes32 streamId,
        bytes32 stateCommitment,
        bytes32 ciphertextHash,
        string calldata ciphertextUri,
        bytes32 manifestHash,
        string calldata label
    ) external returns (bytes32 checkpointId);

    // -----------------------------------------------------------------------
    //  Storage Migration
    // -----------------------------------------------------------------------

    /// @notice Updates the ciphertext URI for an existing checkpoint.
    function updateCiphertextUri(
        bytes32 streamId,
        bytes32 checkpointId,
        string calldata newCiphertextUri
    ) external;

    // -----------------------------------------------------------------------
    //  Tags
    // -----------------------------------------------------------------------

    /// @notice Assigns or reassigns a tag to a checkpoint within a stream.
    function tagCheckpoint(bytes32 streamId, bytes32 checkpointId, string calldata tag) external;

    /// @notice Resolves a tag to a checkpoint ID within a stream.
    function resolveTag(bytes32 streamId, string calldata tag)
        external view returns (bytes32);

    /// @notice Returns the tag for a checkpoint within a stream.
    function getCheckpointTag(bytes32 streamId, bytes32 checkpointId)
        external view returns (string memory);

    // -----------------------------------------------------------------------
    //  Access Control (Allowlist)
    // -----------------------------------------------------------------------

    /// @notice Adds a reader to a stream's allowlist. Only callable by the publisher.
    function addReader(bytes32 streamId, address reader) external;

    /// @notice Removes a reader from a stream's allowlist. Only callable by the publisher.
    function removeReader(bytes32 streamId, address reader) external;

    /// @notice Batch-adds readers to a stream's allowlist. Only callable by the publisher.
    function addReaders(bytes32 streamId, address[] calldata readers) external;

    /// @notice Returns true if the address is an approved reader for the stream.
    function isReader(bytes32 streamId, address account) external view returns (bool);

    // -----------------------------------------------------------------------
    //  Encryption Key Registry
    // -----------------------------------------------------------------------

    /// @notice Registers or rotates the caller's X25519 encryption public key.
    function registerEncryptionKey(bytes32 encryptionPublicKey) external;

    /// @notice Returns the registered encryption public key for an address.
    function getEncryptionKey(address account) external view returns (bytes32);

    // -----------------------------------------------------------------------
    //  On-Chain Key Envelope Delivery
    // -----------------------------------------------------------------------

    /// @notice Delivers a key envelope on-chain for an authorized consumer.
    function deliverKeyEnvelope(
        bytes32 streamId,
        address consumer,
        bytes32 checkpointId,
        bytes calldata wrappedKey,
        bytes24 nonce,
        bytes32 senderPublicKey
    ) external;

    /// @notice Returns the on-chain key envelope.
    function getKeyEnvelope(
        bytes32 streamId,
        address consumer,
        bytes32 checkpointId
    ) external view returns (bytes memory wrappedKey, bytes24 nonce, bytes32 senderPublicKey);

    /// @notice Returns true if an on-chain key envelope exists.
    function hasKeyEnvelope(
        bytes32 streamId,
        address consumer,
        bytes32 checkpointId
    ) external view returns (bool);
}
