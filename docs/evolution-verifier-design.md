# LionEvolutionVerifier. design (mainnet)

The missing piece for go-live #6 (the Evolve flow). This documents the
contract precisely BEFORE implementation, because it does cross-chain
EIP-712 verification and one wrong byte in the domain reconstruction
produces a contract that compiles, passes naive tests, and then rejects
every real proof in production. Build from this spec; do not improvise the
domain.

## What it does

A Lion holder earns a level off-chain (computed by `LionEvolutionOracle`
on Base from `LionLedger` counters). To crystallize that level onto the
mainnet identity, the holder submits an oracle-signed EIP-712 proof. The
verifier:

1. Reconstructs the exact digest the oracle signed.
2. Recovers the signer from the signature and checks it equals the trusted
   oracle signer address.
3. Checks the proof has not expired and its nonce has not been used.
4. Commits the new level (writes to adapter8004, or stores level locally
   and exposes it. see "Commit target" below).

## THE cross-chain trap (read this twice)

The oracle signs with `_hashTypedDataV4`, which binds the signature to the
oracle's OWN EIP-712 domain:

- name:    `"LionEvolutionOracle"`
- version: `"1"`
- chainId: **Base** (8453), the chain the oracle is deployed on
- verifyingContract: the oracle's **Base** address

The verifier runs on **Ethereum mainnet** (chainId 1). It therefore CANNOT
use OpenZeppelin `EIP712` / `_hashTypedDataV4`, because that would build the
domain with mainnet's chainId and the verifier's own address. wrong domain,
every recover fails.

The verifier must reconstruct the oracle's Base domain separator manually:

```solidity
bytes32 constant DOMAIN_TYPEHASH = keccak256(
  "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
);

// Set at construction from the oracle's deployment facts on Base:
uint256 immutable ORACLE_CHAIN_ID;        // 8453 (Base mainnet) or 84532 (sepolia)
address immutable ORACLE_ADDRESS;         // oracle's address on Base

bytes32 domainSeparator = keccak256(abi.encode(
  DOMAIN_TYPEHASH,
  keccak256(bytes("LionEvolutionOracle")),
  keccak256(bytes("1")),
  ORACLE_CHAIN_ID,
  ORACLE_ADDRESS
));
```

These are constructor inputs, not the verifier's own chain/address.

## The struct hash (must match the oracle exactly)

```solidity
bytes32 constant EVOLUTION_PROOF_TYPEHASH = keccak256(
  "EvolutionProof(address mainnetCollection,uint256 tokenId,address holder,uint8 level,uint64 validUntil,uint256 nonce)"
);

bytes32 structHash = keccak256(abi.encode(
  EVOLUTION_PROOF_TYPEHASH,
  mainnetCollection,
  tokenId,
  holder,
  level,        // uint8
  validUntil,   // uint64
  nonce         // uint256
));

bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
address recovered = ECDSA.recover(digest, signature);
require(recovered == oracleSigner && recovered != address(0), "bad sig");
```

Field order and types are copied verbatim from
`LionEvolutionOracle.EVOLUTION_PROOF_TYPEHASH`. If the oracle's typehash
ever changes, this must change in lockstep, ideally pin both to a shared
constant or a version byte.

## State the verifier owns

- `address oracleSigner` (mutable, owner-rotated, mirrors the oracle's
  `signer`; rotate together).
- `mapping(bytes32 => bool) usedDigests` OR `mapping(address => mapping(uint256 => bool)) usedNonces`
  for replay protection ON MAINNET. The oracle's nonce makes each digest
  unique, but the verifier is the one committing state, so it must reject a
  digest/nonce it has already consumed. Prefer `usedDigests[digest]` since
  the digest already encodes (collection, token, holder, level, validUntil,
  nonce). one mapping, simplest.
- `mapping(address => mapping(uint256 => uint8)) committedLevel`
  (collection -> tokenId -> level) if the verifier stores level itself.

## Commit target. open decision

Two options, pick before building:

A. **Verifier stores the level.** adapter8004 is external and we may not
   control a `setMetadata` path that gates on a verifier. The verifier
   holds `committedLevel[collection][tokenId]` and the site reads it. The
   README's "no new mainnet contracts" stance is already being revisited by
   shipping this verifier, so owning the level here is consistent and
   removes the dependency on adapter8004's write ABI.

B. **Verifier calls adapter8004.setMetadata.** Only viable if adapter8004
   exposes a write the verifier is authorized to call, and if its ABI is
   `setMetadata(uint256, string, bytes)` (the site's hardcoded selector
   `0x2a14b58b`). Requires confirming the real adapter ABI and access
   control. higher integration risk.

Recommendation: **A** for a clean, self-contained, testable contract.
the verifier becomes the source of truth for committed level, the site
reads `committedLevel`, and adapter8004 stays untouched. Revisit B only if
a hard requirement says the level must live in adapter8004 storage.

## Function surface (option A)

```solidity
function evolve(
  address mainnetCollection,
  uint256 tokenId,
  uint8 level,
  uint64 validUntil,
  uint256 nonce,
  bytes calldata signature
) external {
  require(block.timestamp <= validUntil, "expired");
  bytes32 digest = _digest(mainnetCollection, tokenId, msg.sender, level, validUntil, nonce);
  require(!usedDigests[digest], "used");
  address rec = ECDSA.recover(digest, signature);
  require(rec == oracleSigner && rec != address(0), "bad sig");
  require(level > committedLevel[mainnetCollection][tokenId], "not an increase");
  usedDigests[digest] = true;
  committedLevel[mainnetCollection][tokenId] = level;
  emit Evolved(mainnetCollection, tokenId, msg.sender, level, nonce);
}
```

Note `holder` in the digest is bound to `msg.sender`: the proof was issued
for a specific holder, and only that holder can submit it. This prevents a
third party from front-running someone's proof.

## Tests to write (forge)

1. Happy path: oracle-key signs a proof against the BASE domain, verifier
   built with the oracle's Base chainId+address recovers and commits.
2. Wrong domain: a proof signed against the verifier's OWN
   (mainnet/self) domain must FAIL. this is the regression test that
   catches the cross-chain trap.
3. Wrong signer key fails.
4. Expired (`block.timestamp > validUntil`) fails.
5. Replay: same proof twice. second fails on `usedDigests`.
6. Non-increasing level fails.
7. holder != msg.sender fails (front-run protection).
8. Signer rotation: owner rotates `oracleSigner`, old-key proofs fail,
   new-key proofs pass.

The test harness can reuse `vm.sign` with a known key and build the digest
with the SAME manual domain reconstruction, then assert the verifier
accepts it. and separately build one with OZ EIP712 on a self-domain to
prove it is rejected.

## Build conditions

- New file `src/LionEvolutionVerifier.sol`, tests in
  `test/LionEvolutionVerifier.t.sol`.
- Public contracts repo, enforced CI (`Forge build + test`), PR-gated.
- After merge + deploy on mainnet, the site flips go-live #6: set the
  verifier address, point `EvolveButton` at `verifier.evolve(...)` via viem
  `encodeFunctionData` (replacing the thrown `encodeSetMetadata` stub), and
  enable `FEATURE_EVOLVE_BUTTON` + `FEATURE_EVOLVE_REAL_TX`.
