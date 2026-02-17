// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IMindstate
 * @notice Interface for the Mindstate token standard — encrypted AI state published as
 *         a verifiable, time-ordered checkpoint stream with ERC-20 burn-to-redeem access.
 *
 *         Each Mindstate deployment represents a single capsule stream. The publisher
 *         (which may be a human or an autonomous agent) has exclusive authority to
 *         append checkpoints. Token holders burn tokens to redeem access to checkpoints,
 *         eliminating the ability to double-spend access entitlement.
 *
 *         The chain never sees secrets. It only sees commitments, pointers, and
 *         redemption records.
 */
interface IMindstate {
    // -----------------------------------------------------------------------
    //  Enums
    // -----------------------------------------------------------------------

    /// @notice Determines how redemption grants access.
    ///         - PerCheckpoint: each redeem() call burns tokens for ONE specific checkpoint.
    ///         - Universal: one redeem() call burns tokens for access to ALL checkpoints.
    enum RedeemMode {
        PerCheckpoint,
        Universal
    }

    // -----------------------------------------------------------------------
    //  Structs
    // -----------------------------------------------------------------------

    /// @notice Compact on-chain record for a single published checkpoint.
    struct Checkpoint {
        bytes32 predecessorId;    // ID of the prior checkpoint (bytes32(0) for genesis)
        bytes32 stateCommitment;  // Hash of the canonical plaintext capsule
        bytes32 ciphertextHash;   // Hash of the encrypted capsule bytes
        string  ciphertextUri;    // Storage URI of the ciphertext (e.g. IPFS CID, ar:// txId, fil:// CID)
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

    /// @notice Emitted when a consumer burns tokens to redeem access.
    ///         In Universal mode, checkpointId is bytes32(0).
    event Redeemed(
        address indexed account,
        bytes32 indexed checkpointId,
        uint256 cost
    );

    /// @notice Emitted when the publisher assigns or reassigns a tag to a checkpoint.
    event CheckpointTagged(
        bytes32 indexed checkpointId,
        string  tag
    );

    /// @notice Emitted when the publisher updates the ciphertext URI for a checkpoint
    ///         (e.g. after migrating data between storage tiers).
    event CiphertextUriUpdated(
        bytes32 indexed checkpointId,
        string  oldUri,
        string  newUri
    );

    /// @notice Emitted when an address registers or rotates its encryption public key.
    event EncryptionKeyRegistered(
        address indexed account,
        bytes32 encryptionKey
    );

    /// @notice Emitted when the publisher delivers a key envelope on-chain.
    ///         Consumers can scan for this event by their address and checkpoint ID.
    event KeyEnvelopeDelivered(
        address indexed consumer,
        bytes32 indexed checkpointId,
        bytes   wrappedKey,
        bytes24 nonce,
        bytes32 senderPublicKey
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
    ///         If `label` is non-empty, the checkpoint is automatically tagged with
    ///         that label (equivalent to calling tagCheckpoint after publishing).
    ///
    /// @param stateCommitment Hash of the canonical plaintext capsule (binds structure).
    /// @param ciphertextHash  Hash of the encrypted capsule bytes (binds ciphertext).
    /// @param ciphertextUri   Storage URI where the ciphertext is stored (e.g. IPFS CID, ar://, fil://).
    /// @param manifestHash    Hash of the execution manifest (separately verifiable).
    /// @param label           Optional short tag (e.g. "stable", "v2.0"). Pass "" to skip.
    /// @return checkpointId   The content-derived identifier of the new checkpoint.
    function publish(
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
    ///         Only callable by the publisher. Used when migrating data between
    ///         storage backends (e.g. IPFS → Arweave) without re-publishing.
    ///
    ///         The checkpoint ID is NOT affected — it is derived from content
    ///         hashes, not the storage URI. The ciphertextHash remains the
    ///         integrity anchor regardless of where the data is stored.
    ///
    /// @param checkpointId   The checkpoint whose URI to update. Must exist.
    /// @param newCiphertextUri The new storage URI (e.g. "ar://..." or "fil://...").
    function updateCiphertextUri(bytes32 checkpointId, string calldata newCiphertextUri) external;

    // -----------------------------------------------------------------------
    //  Tags
    // -----------------------------------------------------------------------

    /// @notice Assigns or reassigns a tag to a checkpoint. Only callable by the publisher.
    ///         Tags are mutable — the publisher can move a tag (e.g. "stable") to a
    ///         different checkpoint at any time.
    /// @param checkpointId The checkpoint to tag. Must exist.
    /// @param tag          The tag string (e.g. "stable", "v2.0").
    function tagCheckpoint(bytes32 checkpointId, string calldata tag) external;

    /// @notice Resolves a tag to the checkpoint ID it currently points to.
    ///         Returns bytes32(0) if the tag has not been assigned.
    /// @param tag The tag to resolve.
    function resolveTag(string calldata tag) external view returns (bytes32);

    /// @notice Returns the tag assigned to a checkpoint, or "" if none.
    /// @param checkpointId The checkpoint to look up.
    function getCheckpointTag(bytes32 checkpointId) external view returns (string memory);

    // -----------------------------------------------------------------------
    //  Redemption (Burn-to-Access)
    // -----------------------------------------------------------------------

    /// @notice Returns the redemption mode configured for this token.
    function redeemMode() external view returns (RedeemMode);

    /// @notice Returns the number of tokens burned per redemption.
    function redeemCost() external view returns (uint256);

    /// @notice Burns redeemCost tokens from the caller and records a redemption.
    ///
    ///         In PerCheckpoint mode: grants access to the specified checkpoint only.
    ///         The checkpoint must exist. Reverts if already redeemed for this checkpoint.
    ///
    ///         In Universal mode: grants access to ALL checkpoints (past and future).
    ///         The checkpointId parameter is ignored. Reverts if already redeemed.
    ///
    /// @param checkpointId The checkpoint to redeem (ignored in Universal mode).
    function redeem(bytes32 checkpointId) external;

    /// @notice Returns true if the account has redeemed access to the given checkpoint.
    ///
    ///         In PerCheckpoint mode: checks the per-checkpoint redemption record.
    ///         In Universal mode: checks if the account has universal redemption
    ///         (checkpointId is ignored).
    ///
    /// @param account      The address to check.
    /// @param checkpointId The checkpoint to check (ignored in Universal mode).
    function hasRedeemed(address account, bytes32 checkpointId) external view returns (bool);

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

    // -----------------------------------------------------------------------
    //  On-Chain Key Envelope Delivery (Optional)
    // -----------------------------------------------------------------------

    /// @notice Delivers a key envelope on-chain for a redeemed consumer.
    ///         Only callable by the publisher. The consumer must have redeemed
    ///         access to the specified checkpoint (or hold universal redemption).
    ///
    ///         This is an OPTIONAL alternative to off-chain key delivery via
    ///         IPFS/Arweave. The envelope is emitted as an event and stored in
    ///         contract state for direct retrieval.
    ///
    ///         The envelope contains K encrypted via NaCl box (X25519 +
    ///         XSalsa20-Poly1305). It is safe to store on-chain — only the
    ///         consumer holding the matching X25519 private key can unwrap it.
    ///
    /// @param consumer        The consumer's Ethereum address.
    /// @param checkpointId    The checkpoint the key unlocks.
    /// @param wrappedKey      K encrypted via NaCl box (~48 bytes).
    /// @param nonce           24-byte NaCl box nonce.
    /// @param senderPublicKey Publisher's 32-byte X25519 public key.
    function deliverKeyEnvelope(
        address consumer,
        bytes32 checkpointId,
        bytes calldata wrappedKey,
        bytes24 nonce,
        bytes32 senderPublicKey
    ) external;

    /// @notice Returns the on-chain key envelope for a consumer and checkpoint.
    ///         Returns empty values if no envelope has been delivered on-chain.
    /// @param consumer     The consumer's Ethereum address.
    /// @param checkpointId The checkpoint to look up.
    function getKeyEnvelope(
        address consumer,
        bytes32 checkpointId
    ) external view returns (bytes memory wrappedKey, bytes24 nonce, bytes32 senderPublicKey);

    /// @notice Returns true if an on-chain key envelope exists for the consumer
    ///         and checkpoint.
    /// @param consumer     The consumer's Ethereum address.
    /// @param checkpointId The checkpoint to check.
    function hasKeyEnvelope(
        address consumer,
        bytes32 checkpointId
    ) external view returns (bool);
}
