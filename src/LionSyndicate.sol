// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title LionSyndicate
/// @notice On-chain financial grouping for Lions. A leader bundles member
///         Lions into a syndicate that sells one combined subscription; the
///         revenue splits across the member holders. Cross-holder by design.
///
/// @dev Consent is SIGNATURE-VERIFIED (EIP-712). A member is inert until a
///      valid consent signature is submitted. The contract recovers the
///      signer and checks it against the authorized signer for that Lion.
///      The signer is NOT assumed to be human: in v1 the holder signs; when
///      agents safely hold keys, an agent signs its own consent with no
///      contract change, because recovery only cares that the signer is
///      authorized.
///
///      Cross-chain ownership: this runs on Base, member Lions live on
///      mainnet. The "authorized signer" for a member (the address whose
///      signature counts) is set by the operator at proposal time, attesting
///      that address currently holds the mainnet Lion. the SAME trust model
///      as onboarding/updateHolderPayee. The signature itself is trustless;
///      the operator only attests who may sign.
///
///      Revenue split reuses LionSubscription's proven pull-payment pattern:
///      collect the full amount, then pay-or-defer each share so one bad
///      recipient cannot block the rest; deferred funds are pulled via
///      claim(). Extended from 3 fixed recipients to N members.
contract LionSyndicate is ERC721, Ownable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    // --- Constants ---------------------------------------------------

    uint16 public constant PLATFORM_BPS = 500; // 5%
    uint16 public constant TREASURY_BPS = 500; // 5%
    uint16 public constant TOTAL_BPS = 10000; // members get the remaining 90%

    bytes32 private constant MEMBERSHIP_CONSENT_TYPEHASH = keccak256(
        "MembershipConsent(uint256 syndicateId,address mainnetCollection,uint256 mainnetTokenId,address payout,uint256 nonce)"
    );

    // --- Types -------------------------------------------------------

    struct Member {
        address mainnetCollection;
        uint256 mainnetTokenId;
        /// Address allowed to sign consent for this member (the holder in v1).
        /// Set by the operator at proposal, attesting mainnet ownership.
        address authorizedSigner;
        /// Base address that receives this member's revenue share.
        address payout;
        bool active;
    }

    struct Syndicate {
        address leader;
        uint128 bundlePrice; // USDC per period (6 decimals)
        uint64 periodSeconds;
        bool enabled;
        uint32 activeMembers;
    }

    struct Subscription {
        uint256 syndicateId;
        uint64 startedAt;
        uint64 expiresAt;
    }

    // --- Storage -----------------------------------------------------

    IERC20 public immutable paymentToken;
    address public platformRecipient;
    address public treasuryRecipient;
    address public operator;

    uint256 private _nextSyndicateId = 1;
    uint256 private _nextSubId = 1;

    mapping(uint256 => Syndicate) public syndicates;
    mapping(uint256 => Member[]) private _members;
    mapping(uint256 => Subscription) public subs;
    mapping(address => uint256) public unclaimed;
    /// Per (authorizedSigner) consent nonce, prevents signature replay.
    mapping(address => uint256) public consentNonce;

    // --- Events ------------------------------------------------------

    event SyndicateCreated(uint256 indexed syndicateId, address indexed leader, uint128 bundlePrice, uint64 periodSeconds);
    event MemberProposed(uint256 indexed syndicateId, uint256 indexed memberIndex, address mainnetCollection, uint256 mainnetTokenId);
    event MemberAccepted(uint256 indexed syndicateId, uint256 indexed memberIndex, address payout);
    event MemberLeft(uint256 indexed syndicateId, uint256 indexed memberIndex);
    event SyndicateEnabled(uint256 indexed syndicateId, bool enabled);
    event SubscriptionPurchased(uint256 indexed subscriptionId, address indexed subscriber, uint256 indexed syndicateId, uint64 expiresAt, uint256 amountPaid);
    event SubscriptionRenewed(uint256 indexed subscriptionId, uint64 newExpiresAt, uint256 amountPaid);
    event PayoutDeferred(address indexed recipient, uint256 amount, string reason);

    // --- Errors ------------------------------------------------------

    error NotLeader();
    error NotOperator();
    error InvalidPeriods();
    error InvalidRecipient();
    error BadMemberIndex();
    error AlreadyActive();
    error NotActive();
    error InvalidSignature();
    error NoActiveMembers();
    error NotEnabled();
    error CostExceedsMax(uint256 actual, uint256 max);
    error UnknownSubscription();

    // --- Construction ------------------------------------------------

    constructor(
        address initialOwner,
        IERC20 paymentToken_,
        address platformRecipient_,
        address treasuryRecipient_,
        address initialOperator
    )
        ERC721("Lazy Lion Syndicate", "LLSYN")
        Ownable(initialOwner)
        EIP712("LionSyndicate", "1")
    {
        paymentToken = paymentToken_;
        platformRecipient = platformRecipient_;
        treasuryRecipient = treasuryRecipient_;
        operator = initialOperator;
    }

    // --- Owner controls ----------------------------------------------

    function setPlatformRecipient(address r) external onlyOwner {
        if (r == address(0)) revert InvalidRecipient();
        platformRecipient = r;
    }

    function setTreasuryRecipient(address r) external onlyOwner {
        if (r == address(0)) revert InvalidRecipient();
        treasuryRecipient = r;
    }

    function setOperator(address o) external onlyOwner {
        operator = o;
    }

    // --- Syndicate lifecycle -----------------------------------------

    function createSyndicate(uint128 bundlePrice, uint64 periodSeconds)
        external
        returns (uint256 syndicateId)
    {
        if (periodSeconds == 0) revert InvalidPeriods();
        syndicateId = _nextSyndicateId++;
        syndicates[syndicateId] = Syndicate({
            leader: msg.sender,
            bundlePrice: bundlePrice,
            periodSeconds: periodSeconds,
            enabled: false,
            activeMembers: 0
        });
        emit SyndicateCreated(syndicateId, msg.sender, bundlePrice, periodSeconds);
    }

    function setEnabled(uint256 syndicateId, bool enabled) external {
        Syndicate storage s = syndicates[syndicateId];
        if (msg.sender != s.leader) revert NotLeader();
        s.enabled = enabled;
        emit SyndicateEnabled(syndicateId, enabled);
    }

    /// @notice Leader proposes a member Lion. The operator must supply the
    ///         authorizedSigner: the address attested to hold the mainnet
    ///         Lion, whose signature will count as consent. Member is
    ///         inactive until that signer consents.
    /// @dev Operator-gated because establishing "who may sign" requires the
    ///      cross-chain mainnet-ownership fact this contract cannot read.
    function proposeMember(
        uint256 syndicateId,
        address mainnetCollection,
        uint256 mainnetTokenId,
        address authorizedSigner
    ) external returns (uint256 memberIndex) {
        if (msg.sender != operator) revert NotOperator();
        if (authorizedSigner == address(0)) revert InvalidRecipient();
        // Leader must exist.
        if (syndicates[syndicateId].leader == address(0)) revert BadMemberIndex();

        Member[] storage ms = _members[syndicateId];
        memberIndex = ms.length;
        ms.push(
            Member({
                mainnetCollection: mainnetCollection,
                mainnetTokenId: mainnetTokenId,
                authorizedSigner: authorizedSigner,
                payout: address(0),
                active: false
            })
        );
        emit MemberProposed(syndicateId, memberIndex, mainnetCollection, mainnetTokenId);
    }

    /// @notice Accept a proposed membership with the authorized signer's
    ///         EIP-712 signature. Anyone may submit the signature (a relayer,
    ///         the operator, the holder), but it is only valid if signed by
    ///         the member's authorizedSigner over the exact terms.
    function acceptMembership(
        uint256 syndicateId,
        uint256 memberIndex,
        address payout,
        bytes calldata signature
    ) external {
        Member[] storage ms = _members[syndicateId];
        if (memberIndex >= ms.length) revert BadMemberIndex();
        Member storage m = ms[memberIndex];
        if (m.active) revert AlreadyActive();
        if (payout == address(0)) revert InvalidRecipient();

        uint256 nonce = consentNonce[m.authorizedSigner];
        bytes32 structHash = keccak256(
            abi.encode(
                MEMBERSHIP_CONSENT_TYPEHASH,
                syndicateId,
                m.mainnetCollection,
                m.mainnetTokenId,
                payout,
                nonce
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = ECDSA.recover(digest, signature);
        if (recovered != m.authorizedSigner || recovered == address(0)) {
            revert InvalidSignature();
        }

        // Consume the nonce so this signature cannot be replayed.
        consentNonce[m.authorizedSigner] = nonce + 1;
        m.payout = payout;
        m.active = true;
        syndicates[syndicateId].activeMembers += 1;
        emit MemberAccepted(syndicateId, memberIndex, payout);
    }

    /// @notice A member's holder leaves. callable by the authorized signer.
    ///         Future subscriptions re-divide among remaining members; past
    ///         payouts are not clawed back.
    function leaveSyndicate(uint256 syndicateId, uint256 memberIndex) external {
        Member[] storage ms = _members[syndicateId];
        if (memberIndex >= ms.length) revert BadMemberIndex();
        Member storage m = ms[memberIndex];
        if (!m.active) revert NotActive();
        if (msg.sender != m.authorizedSigner) revert InvalidSignature();
        m.active = false;
        syndicates[syndicateId].activeMembers -= 1;
        emit MemberLeft(syndicateId, memberIndex);
    }

    /// @notice Operator may re-point a stale payout after a Lion sale, the
    ///         same safety valve as LionSubscription.updateHolderPayee.
    function updateMemberPayout(
        uint256 syndicateId,
        uint256 memberIndex,
        address newAuthorizedSigner,
        address newPayout
    ) external {
        if (msg.sender != operator) revert NotOperator();
        Member[] storage ms = _members[syndicateId];
        if (memberIndex >= ms.length) revert BadMemberIndex();
        if (newAuthorizedSigner == address(0) || newPayout == address(0)) {
            revert InvalidRecipient();
        }
        Member storage m = ms[memberIndex];
        m.authorizedSigner = newAuthorizedSigner;
        m.payout = newPayout;
    }

    // --- Subscribe / renew -------------------------------------------

    function subscribe(
        uint256 syndicateId,
        uint256 periods,
        uint256 maxCostExpected
    ) external nonReentrant returns (uint256 subscriptionId) {
        if (periods == 0) revert InvalidPeriods();
        Syndicate storage s = syndicates[syndicateId];
        if (!s.enabled) revert NotEnabled();
        if (s.activeMembers == 0) revert NoActiveMembers();

        uint256 totalCost = uint256(s.bundlePrice) * periods;
        if (totalCost > maxCostExpected) {
            revert CostExceedsMax(totalCost, maxCostExpected);
        }
        _collectAndSplit(syndicateId, msg.sender, totalCost);

        uint64 duration = uint64(uint256(s.periodSeconds) * periods);
        subscriptionId = _nextSubId++;
        subs[subscriptionId] = Subscription({
            syndicateId: syndicateId,
            startedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp) + duration
        });
        _safeMint(msg.sender, subscriptionId);
        emit SubscriptionPurchased(
            subscriptionId, msg.sender, syndicateId, subs[subscriptionId].expiresAt, totalCost
        );
    }

    function renew(
        uint256 subscriptionId,
        uint256 periods,
        uint256 maxCostExpected
    ) external nonReentrant {
        if (periods == 0) revert InvalidPeriods();
        Subscription storage sub = subs[subscriptionId];
        if (sub.expiresAt == 0) revert UnknownSubscription();
        Syndicate storage s = syndicates[sub.syndicateId];
        if (!s.enabled) revert NotEnabled();
        if (s.activeMembers == 0) revert NoActiveMembers();

        uint256 totalCost = uint256(s.bundlePrice) * periods;
        if (totalCost > maxCostExpected) {
            revert CostExceedsMax(totalCost, maxCostExpected);
        }
        _collectAndSplit(sub.syndicateId, msg.sender, totalCost);

        uint64 base = sub.expiresAt > uint64(block.timestamp)
            ? sub.expiresAt
            : uint64(block.timestamp);
        sub.expiresAt = base + uint64(uint256(s.periodSeconds) * periods);
        emit SubscriptionRenewed(subscriptionId, sub.expiresAt, totalCost);
    }

    function isActive(uint256 subscriptionId) external view returns (bool) {
        return subs[subscriptionId].expiresAt > block.timestamp;
    }

    function expiresAt(uint256 subscriptionId) external view returns (uint64) {
        return subs[subscriptionId].expiresAt;
    }

    function memberCount(uint256 syndicateId) external view returns (uint256) {
        return _members[syndicateId].length;
    }

    function memberAt(uint256 syndicateId, uint256 i)
        external
        view
        returns (Member memory)
    {
        return _members[syndicateId][i];
    }

    // --- Revenue split (pull-payment, reused pattern) ----------------

    function _collectAndSplit(
        uint256 syndicateId,
        address payer,
        uint256 total
    ) internal {
        uint256 platformCut = (total * PLATFORM_BPS) / TOTAL_BPS;
        uint256 treasuryCut = (total * TREASURY_BPS) / TOTAL_BPS;
        uint256 memberPool = total - platformCut - treasuryCut;

        paymentToken.safeTransferFrom(payer, address(this), total);

        if (platformCut > 0) _payOrDefer(platformRecipient, platformCut);
        if (treasuryCut > 0) _payOrDefer(treasuryRecipient, treasuryCut);

        Member[] storage ms = _members[syndicateId];
        uint32 active = syndicates[syndicateId].activeMembers;
        // active > 0 guaranteed by callers (subscribe/renew check it).
        uint256 perMember = memberPool / active;
        uint256 distributed = 0;
        uint256 firstActive = type(uint256).max;

        for (uint256 i = 0; i < ms.length; i++) {
            if (!ms[i].active) continue;
            if (firstActive == type(uint256).max) firstActive = i;
            _payOrDefer(ms[i].payout, perMember);
            distributed += perMember;
        }
        // Dust (memberPool not evenly divisible) goes to the first active
        // member, so the full amount is always distributed.
        uint256 dust = memberPool - distributed;
        if (dust > 0 && firstActive != type(uint256).max) {
            _payOrDefer(ms[firstActive].payout, dust);
        }
    }

    function _payOrDefer(address recipient, uint256 amount) internal {
        if (recipient == address(0)) {
            unclaimed[address(this)] += amount;
            emit PayoutDeferred(address(0), amount, "zero address");
            return;
        }
        try this._externalSafeTransfer(recipient, amount) {
            // paid
        } catch {
            unclaimed[recipient] += amount;
            emit PayoutDeferred(recipient, amount, "recipient rejected");
        }
    }

    /// @dev External so try/catch works. Restricted to self-call.
    function _externalSafeTransfer(address to, uint256 amount) external {
        require(msg.sender == address(this), "self-call only");
        paymentToken.safeTransfer(to, amount);
    }

    function claim() external nonReentrant {
        uint256 amount = unclaimed[msg.sender];
        if (amount == 0) return;
        unclaimed[msg.sender] = 0;
        paymentToken.safeTransfer(msg.sender, amount);
    }

    function sweepZeroAddress(address to) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();
        uint256 amount = unclaimed[address(this)];
        unclaimed[address(this)] = 0;
        if (amount > 0) paymentToken.safeTransfer(to, amount);
    }

    /// @notice EIP-712 digest helper so an off-chain signer can compute the
    ///         message to sign for a given consent.
    function consentDigest(
        uint256 syndicateId,
        address mainnetCollection,
        uint256 mainnetTokenId,
        address payout,
        uint256 nonce
    ) external view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    MEMBERSHIP_CONSENT_TYPEHASH,
                    syndicateId,
                    mainnetCollection,
                    mainnetTokenId,
                    payout,
                    nonce
                )
            )
        );
    }
}
