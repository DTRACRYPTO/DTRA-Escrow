# DTRA Hedera Escrow Contracts

A next-generation **multi-asset escrow system** built on **Hedera Smart Contract Service (HSCS)**.  
Supports **HBAR**, **HTS-mapped ERC-20 tokens** (e.g. DTRA, wBTC, wETH), and cross-chain **BTC/ETH hash-time-locked contracts (HTLCs)**.  

Designed for the **DTRA Marketplace**, ICO token sale, and general-purpose decentralized commerce.

---

## ✨ Features

- **Multi-asset support**
  - Native **HBAR**
  - Any **HTS-mapped ERC-20** (DTRA, bridged wBTC/wETH, etc.)
- **Cross-chain HTLC release**
  - Atomic settlement with BTC or ETH using the same preimage/secret.
- **Oracle-assisted release**
  - N-of-M oracle quorum approval via **EIP-712 signatures**.
- **Fairness incentives**
  - Optional HBAR **micro-bonds** (seller performance / buyer dispute).
- **Deterministic deployment**
  - `CREATE2` factory generates escrow addresses tied to `offerId` (pre-computable → QR/invoice).
- **Safety**
  - Reentrancy guards, single-use settlement, capped fees (≤20%).
  - Circuit-breaker (`pause`) controlled by factory owner.
- **HTS integration**
  - Contracts self-associate to HTS tokens on deploy.
  - Optional dissociation cleanup after settlement.

---

## 📂 Repo Structure


