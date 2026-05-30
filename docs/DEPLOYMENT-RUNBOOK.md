# Deployment runbook. Lazy Lion contracts (Base) + verifier (mainnet)

Step-by-step to deploy the on-chain pieces and capture the addresses the
site/oracle need. Run in this order; later steps depend on addresses from
earlier ones. Every address you capture goes into the site/oracle env (see
the env table at the bottom).

## 0. Prerequisites

- Foundry installed (`forge --version`).
- A funded deployer wallet on **Base** (for the Base contracts) and on
  **Ethereum mainnet** (for the verifier). Hardware wallet or a key you
  control; this wallet becomes the initial owner unless you pass another.
- RPC URLs: a Base RPC and a mainnet RPC (Alchemy/QuickNode recommended
  over public endpoints for reliability).
- The oracle signer address (the wallet whose key the off-chain oracle
  service holds. NOT the deployer). Generate it where the oracle service
  will run; only its address goes on chain.
- BaseScan + Etherscan API keys for verification.

Set env for the session:
```bash
export BASE_RPC_URL=https://...            # Base mainnet RPC
export MAINNET_RPC_URL=https://...         # Ethereum mainnet RPC
export DEPLOYER_PK=0x...                   # deployer private key (or use --ledger)
export OWNER=0x...                         # initial owner (often deployer)
export ORACLE_SIGNER=0x...                 # oracle signer ADDRESS (key off-chain)
export BASESCAN_API_KEY=...
export ETHERSCAN_API_KEY=...
```

## 1. Base. LionLedger

The append-only activity log. Operators write to it; everything else reads.

```bash
forge create src/LionLedger.sol:LionLedger \
  --rpc-url "$BASE_RPC_URL" --private-key "$DEPLOYER_PK" \
  --verify --etherscan-api-key "$BASESCAN_API_KEY" \
  --constructor-args "$OWNER"
```
Capture: **LION_LEDGER_ADDRESS** and its **deploy block** (BaseScan -> the
creation tx -> block number). The deploy block bounds log scans later.

Authorize the operator wallet (the LazyLionAgents backend) to write:
```bash
cast send "$LION_LEDGER_ADDRESS" "setOperator(address,bool)" "$OPERATOR" true \
  --rpc-url "$BASE_RPC_URL" --private-key "$DEPLOYER_PK"
```

## 2. Base. LionEvolutionOracle

Reads ledger counters, computes earned level, signs EIP-712 proofs.

```bash
forge create src/LionEvolutionOracle.sol:LionEvolutionOracle \
  --rpc-url "$BASE_RPC_URL" --private-key "$DEPLOYER_PK" \
  --verify --etherscan-api-key "$BASESCAN_API_KEY" \
  --constructor-args "$OWNER" "$LION_LEDGER_ADDRESS" "$ORACLE_SIGNER"
```
Capture: **LION_EVOLUTION_ORACLE_ADDRESS**. Confirm `signer()` returns
`$ORACLE_SIGNER`:
```bash
cast call "$LION_EVOLUTION_ORACLE_ADDRESS" "signer()(address)" --rpc-url "$BASE_RPC_URL"
```

## 3. Base. LionRenderer + LionArt

```bash
forge create src/LionRenderer.sol:LionRenderer \
  --rpc-url "$BASE_RPC_URL" --private-key "$DEPLOYER_PK" \
  --verify --etherscan-api-key "$BASESCAN_API_KEY"
# capture LION_RENDERER_ADDRESS

forge create src/LionArt.sol:LionArt \
  --rpc-url "$BASE_RPC_URL" --private-key "$DEPLOYER_PK" \
  --verify --etherscan-api-key "$BASESCAN_API_KEY" \
  --constructor-args "$OWNER" "$LION_RENDERER_ADDRESS" "$LION_LEDGER_ADDRESS"
# capture LION_ART_ADDRESS
```
Authorize LionArt to write art-minted events to the ledger:
```bash
cast send "$LION_LEDGER_ADDRESS" "setOperator(address,bool)" "$LION_ART_ADDRESS" true \
  --rpc-url "$BASE_RPC_URL" --private-key "$DEPLOYER_PK"
```

## 4. Base. LionSubscription (ERC-5643)

Check the constructor args in `src/LionSubscription.sol` before running
(owner, payment token = USDC on Base, the ledger). USDC on Base is
`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`.

```bash
forge create src/LionSubscription.sol:LionSubscription \
  --rpc-url "$BASE_RPC_URL" --private-key "$DEPLOYER_PK" \
  --verify --etherscan-api-key "$BASESCAN_API_KEY" \
  --constructor-args "$OWNER" 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 "$LION_LEDGER_ADDRESS"
```
Capture: **LION_SUBSCRIPTION_ADDRESS** and its **deploy block** (this is
`LION_SUBSCRIPTION_FROM_BLOCK`, which bounds the indexer's log scan. without
it the indexer scans from block 0 and is slow).

Authorize it to write subscription events to the ledger:
```bash
cast send "$LION_LEDGER_ADDRESS" "setOperator(address,bool)" "$LION_SUBSCRIPTION_ADDRESS" true \
  --rpc-url "$BASE_RPC_URL" --private-key "$DEPLOYER_PK"
```

## 5. Mainnet. LionEvolutionVerifier

THE cross-chain piece. It verifies the oracle's Base-domain signature on
mainnet, so its constructor needs the oracle's BASE chainId and address.

- Base mainnet chainId = **8453** (Base sepolia = 84532).
- oracleAddress = the `LION_EVOLUTION_ORACLE_ADDRESS` from step 2.

```bash
forge create src/LionEvolutionVerifier.sol:LionEvolutionVerifier \
  --rpc-url "$MAINNET_RPC_URL" --private-key "$DEPLOYER_PK" \
  --verify --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --constructor-args "$OWNER" "$ORACLE_SIGNER" 8453 "$LION_EVOLUTION_ORACLE_ADDRESS"
```
Capture: **LION_EVOLUTION_VERIFIER_ADDRESS**.

Smoke test the domain is right (this catches the #1 cross-chain mistake):
sign a proof with the oracle service and call `isValidProof(...)` on the
verifier. it must return true. If it returns false, the chainId or oracle
address in the constructor is wrong; redeploy with corrected args.

## 6. Signer rotation discipline

The oracle's `signer` (Base) and the verifier's `oracleSigner` (mainnet)
MUST stay in lockstep. To rotate:
1. `proposeSigner` on the oracle (Base, timelocked), then `applySigner`
   after the delay.
2. `setOracleSigner` on the verifier (mainnet, immediate).
Do both in the same maintenance window; a mismatch means proofs signed by
one are rejected by the other.

## Address capture table (fill in, then set env)

| Address | From step | Env var (site unless noted) |
|---|---|---|
| LionLedger | 1 | `LION_LEDGER_ADDRESS` |
| LionLedger deploy block | 1 | (for indexers if needed) |
| LionEvolutionOracle | 2 | `LION_EVOLUTION_ORACLE_ADDRESS` (oracle service) |
| LionRenderer | 3 | `LION_RENDERER_ADDRESS` |
| LionArt | 3 | `LION_ART_ADDRESS` |
| LionSubscription | 4 | `LION_SUBSCRIPTION_ADDRESS` |
| LionSubscription deploy block | 4 | `LION_SUBSCRIPTION_FROM_BLOCK` |
| LionEvolutionVerifier | 5 | `LION_EVOLUTION_VERIFIER_ADDRESS` |

See `docs/SITE-CONFIG-RUNBOOK.md` (LazyLionAgents repo) for wiring these
into the site + oracle env and flipping the feature flags.
