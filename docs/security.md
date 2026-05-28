# Security model + KMS migration plan

## Trust boundary

The Lazy Lion contract system has two trusted keys that must be
protected like crown jewels:

1. **Oracle signer**. the wallet whose ECDSA signature mainnet
   adapter8004 trusts when a holder evolves their Lion. Compromise
   means an attacker can sign fake "earned level 100" proofs for any
   Lion and the mainnet adapter accepts them.

2. **Operator**. the wallet that submits ledger writes and mints art
   on behalf of authenticated holders. Compromise means an attacker
   can spam ledger events (inflating earned-level scores for any Lion)
   and submit mint transactions for any holder-signed intent they can
   replay. The signed-intent system means the attacker can't mint
   *different* art than the holder authorized, but they can submit
   stale/old intents.

Owner key. controls timelock-protected operations. Important but
slower to exploit because of the 24h delay.

## v0 key custody

Both keys live in env vars on the LazyLionAgents backend host:

- `LION_OPERATOR_PRIVATE_KEY`. used by `lib/lion-ledger-client.ts` to
  sign ledger writes
- Oracle signer key. used by the off-chain oracle service (NOT in
  this repo yet; see "Oracle service" below)

**This is acceptable for testnet and early mainnet beta but is not
production-grade.** A VPS compromise hands the attacker both keys.

## Production KMS migration (Phase 2)

Migrate both keys to a Key Management Service. Two reasonable options:

### Option A. AWS KMS

Keys live in KMS. Application code calls `Sign` API to get a signature
over a digest. Private key bytes never leave the HSM.

```ts
// Sketch. replaces operatorWallet() in lib/lion-ledger-client.ts
import { KMSClient, SignCommand } from "@aws-sdk/client-kms";

async function kmsSign(digest: Buffer): Promise<Hex> {
  const client = new KMSClient({ region: "us-east-1" });
  const res = await client.send(new SignCommand({
    KeyId: process.env.LION_OPERATOR_KMS_KEY_ID!,
    Message: digest,
    MessageType: "DIGEST",
    SigningAlgorithm: "ECDSA_SHA_256",
  }));
  return formatKmsSignature(res.Signature!); // re-encode to 65-byte ETH sig
}
```

The viem `walletClient` lets you swap in a custom signer via
`createWalletClient({ account: toAccount({ ... sign: kmsSign }) })`.

### Option B. Turnkey

Purpose-built for Web3 key custody. Simpler API, runs in TEEs, no
ECDSA recovery byte gymnastics.

```ts
import { TurnkeySigner } from "@turnkey/ethers";
const signer = new TurnkeySigner({ ... });
const wallet = createWalletClient({
  account: signer,
  chain: base,
  transport: http(),
});
```

## Oracle service architecture

The oracle signer is owned by an off-chain "oracle service" that:

1. Listens to LionLedger events on Base (via subgraph or RPC)
2. Recomputes earned levels when counters change
3. Exposes a REST endpoint: `POST /oracle/sign-evolution` that:
   - Takes (mainnetCollection, tokenId, holder, nonce)
   - Reads the current earnedLevel from the LionEvolutionOracle
   - Computes the EIP-712 digest
   - Signs with the KMS-held signer key
   - Returns (level, validUntil, signature)

This service has not been built yet. It lands when we're ready to
ship Phase 4 (mainnet evolution). For now the
LionEvolutionOracle's `verifyProof` exists to validate signatures
produced manually in tests.

## Owner key custody

A multisig (Safe) on Base is recommended for the owner role. 2-of-3
or 3-of-5. Single-EOA owner is the lowest-friction setup for
testnet but a known weakness on mainnet.

## Operational rules

- **Never** check private keys into git, even for testnet
- Operator + oracle keys must be unique per environment
- Key rotation should happen quarterly minimum
- After any suspected compromise: revoke operator via `setOperator(op, false)`,
  rotate signer via `proposeSigner` + 24h wait + `applySigner`

## Audit findings rolled up

See main audit findings list in the project root. All HIGH and MED
items addressed in code as of the security pass. HIGH-4 (KMS
migration) is operational and lives here as Phase 2 work.
