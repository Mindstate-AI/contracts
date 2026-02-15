// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IMindstate
 * @notice Interface for the Mindstate token standard — encrypted AI state published as
 *         a verifiable, time-ordered checkpoint stream with ERC-20 access entitlement.
 *
 *         Each Mindstate deployment represents a single capsule stream. The publisher
 *         (which may be a human or an autonomous agent) has exclusive authority to
 *         append checkpoints. Token holders have no authority over content — they hold
 *         fungible access entitlement that determines who can request decryption keys
 *         off-chain.
 *
 *         The chain never sees secrets. It only sees commitments, pointers, and
 *         entitlements.
 */
interface IMindstate {
    // -----------------------------------------------------------------------
    //  Structs
    // -----------------------------------------------------------------------

    /// @notice Compact on-chain record for a single published checkpoint.
    struct Checkpoint {
        bytes32 predecessorId;    // ID of the prior checkpoint (bytes32(0) for genesis)
        bytes32 stateCommitment;  // Hash of the canonical plaintext capsule
        bytes32 ciphertextHash;   // Hash of the encrypted capsule bytes
        string  ciphertextUri;    // Content address of the ciphertext (e.g. IPFS CID)
        bytes32 manifestHash;     // Hash of the execution manifest (separately addressable)
        uint64  publishedAt;      // block.timestamp when published
        uint64  blockNumber;      // block.number when published
    }

    // -----------------------------------------------------------------------
    //  Events
    // -----------------------------------------------------------------------

    /// @notice Emitted when the publisher appends a new checkpoint to the stream.
    event CheckpointPublished(
        bytes32 indexed checkpointId,
        bytes32 indexed predecessorId,
        uint256 indexed index,
        bytes32 stateCommitment,
        bytes32 ciphertextHash,
        string  ciphertextUri,
        bytes32 manifestHash,
        uint64  timestamp,
        uint64  blockNumber
    );

    /// @notice Emitted when an address registers or rotates its encryption public key.
    event EncryptionKeyRegistered(
        address indexed account,
        bytes32 encryptionKey
    );

    /// @notice Emitted when publisher authority is transferred.
    event PublisherTransferred(
        address indexed previousPublisher,
        address indexed newPublisher
    );

    // -----------------------------------------------------------------------
    //  Publisher
    // -----------------------------------------------------------------------

    /// @notice Returns the address that has exclusive publishing authority.
    function publisher() external view returns (address);

    /// @notice Transfers publisher authority. Only callable by the current publisher.
    /// @param newPublisher The address that will become the new publisher.
    function transferPublisher(address newPublisher) external;

    // -----------------------------------------------------------------------
    //  Checkpoint Chain
    // -----------------------------------------------------------------------

    /// @notice Returns the content-derived ID of the most recent checkpoint.
    ///         Returns bytes32(0) if no checkpoints have been published.
    function head() external view returns (bytes32);

    /// @notice Returns the total number of checkpoints published to this stream.
    function checkpointCount() external view returns (uint256);

    /// @notice Resolves a checkpoint ID to its full on-chain metadata.
    /// @param checkpointId The content-derived identifier of the checkpoint.
    function getCheckpoint(bytes32 checkpointId) external view returns (Checkpoint memory);

    /// @notice Returns the checkpoint ID at a given sequential index (0-based).
    /// @param index The sequential index of the checkpoint.
    function getCheckpointIdAtIndex(uint256 index) external view returns (bytes32);

    // -----------------------------------------------------------------------
    //  Publishing
    // -----------------------------------------------------------------------

    /// @notice Publishes a new checkpoint. Only callable by the publisher.
    ///
    ///         The checkpoint ID is derived deterministically from the content and
    ///         context: keccak256(predecessorId, stateCommitment, ciphertextHash,
    ///         manifestHash, block.timestamp, block.number).
    ///
    /// @param stateCommitment Hash of the canonical plaintext capsule (binds structure).
    /// @param ciphertextHash  Hash of the encrypted capsule bytes (binds ciphertext).
    /// @param ciphertextUri   Content address where the ciphertext is stored (e.g. IPFS CID).
    /// @param manifestHash    Hash of the execution manifest (separately verifiable).
    /// @return checkpointId   The content-derived identifier of the new checkpoint.
    function publish(
        bytes32 stateCommitment,
        bytes32 ciphertextHash,
        string calldata ciphertextUri,
        bytes32 manifestHash
    ) external returns (bytes32 checkpointId);

    // -----------------------------------------------------------------------
    //  Access Control
    // -----------------------------------------------------------------------

    /// @notice Returns the minimum token balance required for consumption access.
    function minBalance() external view returns (uint256);

    /// @notice Returns true if the account holds at least minBalance tokens.
    /// @param account The address to check.
    function hasAccess(address account) external view returns (bool);

    // -----------------------------------------------------------------------
    //  Encryption Key Registry
    // -----------------------------------------------------------------------

    /// @notice Registers or rotates the caller's X25519 encryption public key.
    ///         This key is independent of the Ethereum signing key and is used
    ///         by key delivery services to wrap decryption keys.
    /// @param encryptionPublicKey The 32-byte X25519 public key.
    function registerEncryptionKey(bytes32 encryptionPublicKey) external;

    /// @notice Returns the registered encryption public key for an address.
    ///         Returns bytes32(0) if no key has been registered.
    /// @param account The address to look up.
    function getEncryptionKey(address account) external view returns (bytes32);
}
