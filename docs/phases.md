# Contract phases

## Phase 1. Foundation (DONE in code, awaits Foundry install + audit)

- `LionLedger`. append-only activity log + per-Lion counters
- `LionEvolutionOracle`. earned-level computation + EIP-712 signed proofs
- Tests covering: counter updates, operator gating, subscription deltas, signature verify/replay/expiry
- Deploy script wires all phases together

## Phase 2. Art (in code, needs aesthetic iteration)

- `LionRenderer`. pure-Solidity SVG renderer, four layers
- `LionArt`. ERC-721 with on-chain `tokenURI` via renderer
- EIP-712 mint intent so holder signs once and operator submits
- bitmap hash check prevents the operator from minting different art than the holder approved

## Phase 3. Subscriptions

- `LionSubscription`. ERC-5643-style. USDC routing 90/5/5.
- Holder enables tier from settings → contract registers it
- Subscriber buys → contract mints sub NFT + routes USDC at purchase
- Renewal extends from current expiry or now, whichever is later
- Transferable by default, per-tier flag to lock

## Phase 4. Mainnet evolution flow

- LazyLionAgents site adds Evolve button on Proof of Work tab
- Site calls oracle off-chain → gets signed proof
- Site submits to adapter8004.setMetadata("level", N) on mainnet
- Holder signs the mainnet tx
- Etherscan tx becomes the public proof of evolution

## Phase 5. Indexer + Proof of Work UI

- Subgraph for LionLedger events
- LazyLionAgents site reads subgraph for the activity stream
- Aggregate stats pull from on-chain counters via direct view calls
- Art gallery reads LionArt by mainnet (collection, tokenId)
- Subscription status reads LionSubscription

## What goes on mainnet vs Base

Mainnet:
- Initial adapter8004 registration (one tx per Lion, ever)
- Each opt-in level evolution (one tx per evolution)
- Nothing else

Base:
- Everything else
- Every ledger event
- Every art mint
- Every subscription event

This split keeps mainnet writes high-value (every one is an
intentional act of commitment) and Base writes cheap enough that
holders use the system constantly.
