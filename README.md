<img src="dithered-lassie.png" alt="Mindstate" width="400" />

# Mindstate Contracts

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-^0.8.24-363636?logo=solidity)](https://soliditylang.org)
[![Built with Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C)](https://book.getfoundry.sh)
[![GitHub stars](https://img.shields.io/github/stars/Mindstate-AI/contracts)](https://github.com/Mindstate-AI/contracts)

Encrypted AI state on-chain. Verifiable checkpoints. Burn-to-redeem access.

---

[mindstate.dev](https://mindstate.dev) · [Twitter](https://x.com/mindstatecoin) · [Telegram](https://t.me/mindstatedev) · [GitHub](https://github.com/Mindstate-AI)

## Overview

Mindstate is a standard for **portable, encrypted AI state** published as a verifiable, time-ordered checkpoint stream with ERC-20 burn-to-redeem access control.

The chain never sees secrets — only commitments, pointers, and redemption records.

Each Mindstate deployment represents a **capsule stream**. A publisher (human or autonomous agent) has exclusive authority to append checkpoints. Token holders burn tokens to redeem access, eliminating double-spend of access entitlements.

## Architecture

```
┌─────────────────────┐     EIP-1167 Clone      ┌────────────────────┐
│  MindstateFactory   │ ──────────────────────▶  │  MindstateToken    │
│  (or LaunchFactory) │                          │  (proxy instance)  │
└─────────────────────┘                          └────────────────────┘
                                                          │
                                                          ▼
                                                 ┌────────────────────┐
                                                 │  IMindstate        │
                                                 │  - publish()       │
                                                 │  - redeem()        │
                                                 │  - registerKey()   │
                                                 └────────────────────┘
```

## Contracts

| Contract | Description |
|---|---|
| **`MindstateToken`** | Reference implementation of the Mindstate standard. Each instance is a capsule stream backed by an ERC-20 token with checkpoint publishing, burn-to-redeem access, tagging, encryption key registry, and storage migration. Deployed as EIP-1167 minimal proxy clones. |
| **`MindstateFactory`** | Deploys MindstateToken clones via `create()` or `createDeterministic()` (CREATE2). Maintains an on-chain registry of all deployments for indexing and discovery. |
| **`IMindstate`** | Interface defining the full Mindstate standard — checkpoint chain, publishing, redemption, tags, encryption keys, storage migration, and optional on-chain key envelope delivery. |
| **`MindstateLaunchFactory`** | Creates new Mindstate token launches with Uniswap V3 liquidity. Deploys a clone, creates a V3 pool (token/WETH, 1% fee tier), seeds single-sided liquidity, and transfers the LP NFT to the vault. |
| **`MindstateVault`** | Holds Uniswap V3 LP NFT positions permanently. Anyone can trigger fee collection — fees are split 60% creator / 25% burn / 15% platform. |
| **`FeeCollector`** | Collects and manages platform fees from launchpad trading activity. |

## Key Concepts

### Checkpoint Stream

Each token maintains a hash-linked chain of checkpoints. A checkpoint stores:

- **`stateCommitment`** — hash of the canonical plaintext capsule
- **`ciphertextHash`** — hash of the encrypted capsule bytes
- **`ciphertextUri`** — storage pointer (IPFS, Arweave, Filecoin)
- **`manifestHash`** — hash of the execution manifest
- **`predecessorId`** — link to the previous checkpoint

### Burn-to-Redeem

Two redemption modes:

- **PerCheckpoint** — each `redeem()` burns tokens for access to one specific checkpoint
- **Universal** — a single `redeem()` burns tokens for access to all checkpoints (past and future)

### Encryption Key Registry

Users register X25519 public keys on-chain. Key delivery services use these to wrap decryption keys for redeemed consumers.

### On-Chain Key Envelope Delivery (Optional)

Publishers can deliver wrapped decryption keys directly through the contract via `deliverKeyEnvelope()`. The key envelope contains K encrypted with NaCl box (X25519 + XSalsa20-Poly1305) — it is cryptographically safe to store on-chain because only the consumer holding the matching X25519 private key can unwrap it. The wrapped key is indistinguishable from random noise to all other observers.

This is an **optional** alternative to off-chain delivery via IPFS/Arweave. On L2s like Base where gas is negligible (~$0.001 per envelope), on-chain delivery is recommended for its simplicity:

- **Guaranteed availability** — envelopes are permanent on-chain, no IPFS pinning required
- **Simple discovery** — consumers read from the contract or scan `KeyEnvelopeDelivered` events
- **Atomic fulfillment** — delivery is recorded immutably, no separate index to publish
- **Same security** — the NaCl box encryption is identical regardless of transport

The contract enforces that only the publisher can deliver envelopes and that the consumer has already redeemed access.

### Security Model

The contract never stores secrets. All on-chain data is either:

- **Hashes** — `stateCommitment`, `ciphertextHash`, `manifestHash` (commitments, not content)
- **Pointers** — `ciphertextUri` (where to find encrypted data, not the data itself)
- **Public keys** — X25519 encryption keys (safe by definition — knowing a public key does not reveal the private key)
- **Encrypted envelopes** — NaCl box output (indistinguishable from random noise without the private key)
- **Records** — redemption state, publisher address, tags (metadata, not secrets)

An attacker with full read access to all on-chain state learns nothing about the encrypted content or decryption keys.

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Install

```bash
git clone https://github.com/Mindstate-AI/contracts.git
cd contracts
forge install
```

### Build

```bash
forge build
```

### Test

```bash
forge test
```

## License

MIT
