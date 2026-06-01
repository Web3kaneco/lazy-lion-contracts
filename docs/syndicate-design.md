# LionSyndicate. design (Base)

The on-chain financial layer for grouping Lions. A leader bundles member
Lions into a syndicate that sells one combined subscription, and the
revenue splits across the member holders. Written before implementation
because this moves real money across potentially many parties, and the
consent and split mechanics are where a revenue contract goes wrong.

## What it is, and what it is NOT

It IS: a Base contract where a leader registers a syndicate, member Lions
join WITH their holders' on-chain consent, a buyer pays one bundle price,
and the payment splits across the member holders plus the platform and
treasury. Cross-holder by design: members can be Lions owned by different
people, which is exactly why consent and the split must be trustless.

It is NOT: the soft collaboration groups (those are off-chain, free, and
control knowledge/debate flow only, lib/collaboration-groups.ts). A
collaboration group is the everyday "work together" tool; a syndicate is
what you create when you want to SELL the group's combined output. Most
groups never become syndicates.

## The decisions, settled

1. **Cross-holder.** Members may belong to different holders. A solo holder
   bundling their own 50 Lions is just the case where every member shares
   one owner. The contract treats each member identically.

2. **Membership is by Lion (token), payout follows the token.** A member is
   a (mainnetCollection, tokenId) pair. Revenue for a member routes to
   whoever HOLDS that token at payout time, read fresh, not to a stored
   address. So if a member Lion is sold, the new owner inherits the revenue
   share automatically. same principle as the agent identity following the
   token. (See "Payout address resolution" for how a Base contract learns
   a mainnet holder.)

3. **Signature-verified consent to join.** Because joining commits
   someone's asset to a revenue arrangement, consent is an EIP-712
   signature the contract itself recovers and checks. never operator
   attestation, never an unauthorized add. A leader proposes a member; the
   member is inert until a valid consent signature is submitted. A member's
   holder can `leaveSyndicate` at any time.

   CRITICAL DESIGN POINT for the future: the contract recovers the signer
   and checks it is authorized for that member Lion, but it does NOT assume
   the signer is a human. In v1 the holder (a human wallet) signs. The day
   agents safely hold their own keys (the deferred custody capability), an
   AGENT can sign its own consent with ZERO contract change, because the
   verifier only cares that the recovered signer is authorized, not whether
   it is a person. This is what makes the autonomous agent-to-agent
   syndicate (v2) a drop-in rather than a rewrite. Build the signature
   path now precisely so that future is not blocked.

4. **Equal split across members in v1.** Revenue, after platform+treasury,
   splits equally across the active member Lions, matching
   computeRevenueSplit in lib/syndicates.ts. A configurable weighted split
   is a v2 (note it, do not build it).

## Revenue split, reusing the proven pattern

LionSubscription already solved the hard part: split a payment across
recipients where ONE bad recipient must not block the others. It collects
the full amount, then `_payOrDefer`s each share. a failing transfer credits
`unclaimed[recipient]` and the recipient pulls later via `claim()`. The
syndicate reuses this exactly, extended from 3 fixed recipients to N
members:

```
platformCut  = total * PLATFORM_BPS / TOTAL_BPS   // 5%
treasuryCut  = total * TREASURY_BPS / TOTAL_BPS    // 5%
memberPool   = total - platformCut - treasuryCut   // 90%
perMember    = memberPool / activeMemberCount       // equal split
remainder    = memberPool - perMember*activeMemberCount  // dust to member[0]
```

Same constants, same pull-payment safety, same `_externalSafeTransfer`
self-call try/catch. The only new logic is iterating members and resolving
each member's current payout address.

## Payout address resolution. the cross-chain subtlety

The member is a mainnet Lion (collection, tokenId), but this contract runs
on Base and pays USDC on Base. A Base contract cannot read mainnet
`ownerOf` directly. Two honest options:

A. **Stored payout address per member, updated by the operator** (same
   model LionSubscription already uses: `updateHolderPayee`, operator
   verifies the new holder off-chain after a sale and updates). Simple,
   already proven in this codebase, but relies on the trusted operator to
   keep payees current after a Lion sale.

B. **Member's holder sets their own Base payout address at consent time.**
   When a holder calls `acceptMembership`, they pass the Base address that
   should receive their share. Self-sovereign, no operator trust for
   payouts, but the holder must update it themselves if they sell.

Recommendation: **B for the payout address (holder sets it at consent),
with the operator able to update a stale payee as a fallback** (mirroring
updateHolderPayee). This keeps payouts self-sovereign by default while
preserving the existing safety valve. Decide before build.

## State

```solidity
struct Member {
    address mainnetCollection;
    uint256 mainnetTokenId;
    address payout;        // Base address that receives this member's share
    bool active;           // accepted and not left
}

struct Syndicate {
    address leader;        // forms + configures
    uint128 bundlePrice;   // USDC per period (6 decimals)
    uint64  periodSeconds;
    bool    enabled;
    uint32  memberCount;   // active members
}

mapping(uint256 => Syndicate) public syndicates;          // syndicateId -> config
mapping(uint256 => Member[]) internal _members;            // syndicateId -> members
mapping(address => uint256) public unclaimed;              // pull-payment
```

## Function surface

```
createSyndicate(bundlePrice, periodSeconds) -> syndicateId   // leader
proposeMember(syndicateId, collection, tokenId)             // leader proposes
acceptMembership(syndicateId, memberIndex, payoutAddress)   // member's holder consents
leaveSyndicate(syndicateId, memberIndex)                    // member's holder exits
setEnabled(syndicateId, bool)                               // leader
subscribe(syndicateId, periods, maxCost) -> subscriptionId  // buyer; splits revenue
renew(subscriptionId, periods, maxCost)                     // buyer
claim()                                                     // pull deferred payout
```

Subscribe mirrors LionSubscription: ERC-5643-style expirable sub NFT, the
buyer is `msg.sender`, slippage guard via `maxCost`, ledger event
best-effort. The difference is `_collectAndSplitAcrossMembers` instead of
the fixed 3-way split.

## Consent integrity (the security core)

- `proposeMember` only records an intent; it grants nothing. The member is
  inactive until a valid consent signature is accepted.
- Consent is EIP-712. The signed struct binds the syndicate, the member
  Lion (collection, tokenId), the payout address, and a nonce, so a
  signature authorizes exactly one membership and cannot be replayed or
  retargeted. The contract recovers the signer and checks it against the
  authorized signer for that Lion.
- AUTHORIZED SIGNER. who is allowed to consent for a member Lion. In v1
  this is the holder's wallet. Because a Base contract cannot read mainnet
  `ownerOf`, the authorized signer is established the same way the rest of
  the system handles cross-chain ownership: the consenting holder's address
  is provided and the operator attests it currently holds the Lion at
  consent time (the same trust assumption as onboarding and
  updateHolderPayee). The SIGNATURE is trustless; the operator's only role
  is attesting the signer holds the mainnet Lion, not authorizing the join
  itself. This cleanly separates "who may sign" (needs the mainnet
  ownership fact) from "did they sign" (pure on-chain recovery).
- FUTURE (v2, agent-signed): when agents hold their own keys, the agent's
  key becomes the authorized signer for its own Lion and signs its own
  consent. No contract change. the recovery logic is identical. Deferred
  only because agent key custody is deferred.
- A buyer cannot subscribe to a syndicate with zero active members (no one
  to pay; revert).
- Leaving sets the member inactive and re-divides future revenue among the
  remaining active members. it does not claw back past payouts.

## Tests to write (forge)

1. create + propose + accept: member becomes active, memberCount increments.
2. subscribe splits 90% across N members equally, 5%/5% platform/treasury.
3. remainder dust goes to member[0], total paid == total collected.
4. a member with a reverting payout does not block others. their share
   lands in unclaimed, claimable later.
5. leave: future subscribe re-divides among remaining; left member gets 0.
6. subscribe with zero active members reverts.
7. only the leader can propose/enable; only the member's holder (operator-
   attested) can accept/leave.
8. maxCost slippage guard reverts when price exceeds it.
9. payout follows a re-pointed payee (operator fallback update).

## After merge

Deploy on Base, wire lib/syndicates.ts to read/write the contract (it is
currently the off-chain mock), and the site's syndicate UI flips from the
"coming soon" disabled button to a real subscribe. The off-chain
`computeRevenueSplit` becomes the contract's on-chain split, and the
off-chain table becomes a mirror/index like subscriptions.

Build conditions: new src/LionSyndicate.sol + test/LionSyndicate.t.sol,
public contracts repo, enforced CI (Forge build + test), PR-gated. No
admin-merge; CI green confirmed before merge.
