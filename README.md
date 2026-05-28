# Lazy Lion Contracts

Smart contracts for the Lazy Lion Agents system. Sibling repo to
[`LazyLionAgents`](../LazyLionAgents) which holds the Next.js site, the
swarm engine, and the MCP server.

## Architecture

```
                MAINNET (sovereign identity)
   ┌────────────────────────────────────────────┐
   │  Lazy Lions ERC-721    0x8943C7…7E0        │
   │  adapter8004           0xde152A…336        │
   │    └── per-Lion metadata: name, tagline,   │
   │        target bitmap, reveal seq, level    │
   │        ▲                                   │
   │        │ evolve() — holder pays gas        │
   │        │ to crystallize earned levels      │
   └────────┼───────────────────────────────────┘
            │
            │ oracle-signed proof
            │ "Lion #X earned level N"
            ▼
                BASE (high-frequency activity)
   ┌────────────────────────────────────────────┐
   │  LionLedger          append-only log       │
   │  LionEvolutionOracle reads ledger, signs   │
   │                     proofs for mainnet     │
   │  LionRenderer       pure on-chain SVG      │
   │  LionArt   ERC-721  mints art from state   │
   │  LionSubscription   ERC-5643 paid tiers    │
   └────────────────────────────────────────────┘
```

The Lion lives on Ethereum mainnet. Its **ledger** lives on Base, where
every action — picks, journals, swarm verdicts, art mints, subscription
events — costs cents to record. When a holder wants to crystallize an
achievement onto the Lion itself, they pull a signed proof from the
Base `LionEvolutionOracle` and pay mainnet gas to commit it via
adapter8004's `setMetadata`.

This split keeps three properties:

1. **Sovereignty.** The Lion never depends on a bridge. The mainnet
   binding is always the source of truth for identity and rank.
2. **Cheap activity.** Holders use the system constantly without
   thinking about gas. Base writes are sub-cent.
3. **Earned value.** Mainnet evolution is opt-in and costs gas, which
   makes each evolution a real commitment that buyers can verify.

## Contracts

| Contract | Chain | Purpose |
|---|---|---|
| `LionLedger` | Base | Append-only activity log + per-Lion counters |
| `LionEvolutionOracle` | Base | Reads ledger counters, signs proofs for mainnet evolution |
| `LionRenderer` | Base | Pure-Solidity SVG renderer. Stateless. Composable. |
| `LionArt` | Base | ERC-721 art mints. `tokenURI` returns on-chain SVG via renderer. |
| `LionSubscription` | Base | ERC-5643 paid subscription tiers per agent. |

The mainnet side reuses the existing adapter8004 deployment. No new
mainnet contracts.

## Setup

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install deps
forge install OpenZeppelin/openzeppelin-contracts --no-commit

# Build
forge build

# Test
forge test -vvv
```

## Deploy

```bash
# Base mainnet
forge script script/Deploy.s.sol \
  --rpc-url $BASE_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY
```

## Status

Phase 1 (foundation): `LionLedger`, `LionEvolutionOracle` complete + tested.
Phase 2: `LionRenderer` SVG output, `LionArt` mints.
Phase 3: `LionSubscription` with USDC routing.

See `docs/phases.md` for the rolling plan.
